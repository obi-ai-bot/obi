//! The phone relay (docs/runner-api.md, "obid only: the phone relay"; spec sphere-api.md section
//! 9): how a paired phone reaches obid through the owner's own Obysphere, with no port open on the
//! Mac and no tunnel. While obid is a member of a Sphere and a phone is paired through it (or
//! invited to), obid keeps one WebSocket on its relay as its member Obi. Each phone's frames come
//! in behind the 32 bytes of its device id (the SHA-256 of its relay token); obid opens the phone's
//! sealed envelopes (crate::relay::envelope) and hands each request inside to the gateway's own
//! router, in process, so pairing, device tokens and the allowlist are the gateway's, unchanged.
//! The answer goes back sealed, a frame at a time: each phone's frames wait in a lane of their
//! own, and the lanes take turns under the Sphere's limits, so no phone holds up another.
//!
//! What obid keeps for it: `home/keys/relay.json` (0600), the relay's id and the Mac's X25519 key,
//! made when the first phone is invited; and, in `home/gateway-devices.json`, each relay-paired
//! device's relay token digest (crate::gateway). The relay tokens themselves are only in the QR.

pub mod envelope;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime};

use axum::Router;
use axum::body::Body;
use axum::extract::Request;
use axum::http::{HeaderName, HeaderValue, Method, StatusCode};
use axum::response::IntoResponse as _;
use base64::Engine as _;
use futures_util::{SinkExt as _, StreamExt as _};
use obi_protocol::client::{Client, ClientError};
use serde_json::{Map, Value, json};
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore};
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tower::ServiceExt as _;

use crate::api::Shared;
use crate::gateway::{RelayInvite, Relayed};
use crate::sphere::Link;
use crate::sphere::channel::{Frame, Kind};
use envelope::{MacKey, Opener, Sealer};

/// A `ping` this often (sphere-api.md 9.3: 2 minutes of silence closes a socket).
const PING_EVERY: Duration = Duration::from_secs(30);
/// Nothing heard for this long, not even a `pong`: the socket is gone.
const SILENCE: Duration = Duration::from_secs(75);
/// The longest wait before connecting again.
const BACKOFF_MAX: Duration = Duration::from_secs(60);
/// A new socket with a new token this long before the old token ends, so phones see nothing.
const RENEW_BEFORE: i64 = 45;
/// The longest a renewal waits for the old socket's `pong`, and for it to close.
const RENEWING: Duration = Duration::from_secs(10);
/// How often the devices the Sphere knows are checked against the paired ones (expiries).
const CHECK_EVERY: Duration = Duration::from_secs(60);
/// The most body one data frame carries.
const CHUNK: usize = 65_536;
/// The most requests one phone has open at once.
const STREAMS: usize = 32;
/// The largest request a phone may send (the gateway's), and the most its unfinished requests hold.
const BODY: usize = 4 << 20;
/// The most frames that wait to go to one phone: its answers wait for room, and its refusals
/// past it are dropped.
const LANE: usize = 64;
/// The most frames sent before the socket is read again.
const BURST: usize = 64;
/// Under the Sphere's 4,800 frames and 64 MiB a minute for a Mac's socket, with room to spare.
const FRAMES_A_MINUTE: usize = 4_000;
const BYTES_A_MINUTE: usize = 56 << 20;
/// What the Mac's X25519 key is known by in crate::secrets: it never leaves obid.
const KEY_SECRET: &str = "relay-key";
/// The sealed `reset` on stream 0 that tells a phone its session is over.
const OVER: &str = "The session is over: send a new hello.";

/// The relay's id and the Mac's key, from `home/keys/relay.json`.
struct Kept {
    relay: String,
    key: MacKey,
    /// The key's public half, base64url: the QR's `key`.
    public: String,
}

/// One phone's session: its envelopes' keys, its requests under way, and its lane's room.
struct Live {
    epoch: u64,
    sealer: Sealer,
    opener: Opener,
    last_stream: u32,
    streams: HashMap<u32, Stream>,
    room: Arc<Semaphore>,
}

enum Stream {
    /// The request so far: its head, and the body until its `end`.
    Asking {
        head: Value,
        body: Vec<u8>,
    },
    Answering(tokio::task::AbortHandle),
}

impl Drop for Live {
    /// A session that ends takes its answers with it: an event stream stops at once.
    fn drop(&mut self) {
        for stream in self.streams.values() {
            if let Stream::Answering(task) = stream {
                task.abort();
            }
        }
    }
}

/// A frame for a phone, sealed only when it goes out, so counters go in the order sent; it holds
/// its room in the phone's lane until then.
struct Out {
    device: String,
    epoch: u64,
    frame: Frame,
    _room: Option<OwnedSemaphorePermit>,
}

impl Out {
    /// Its bytes on the socket: the device id, the envelope's own and the frame's.
    fn len(&self) -> usize {
        32 + envelope::OVERHEAD + 5 + self.frame.payload.len()
    }
}

/// What waits to go out: a lane per phone, and the lanes' turns.
#[derive(Default)]
struct Lanes {
    lanes: HashMap<String, VecDeque<Out>>,
    turns: VecDeque<String>,
}

impl Lanes {
    fn push(&mut self, out: Out) {
        if !self.lanes.contains_key(&out.device) {
            self.turns.push_back(out.device.clone());
        }
        self.lanes
            .entry(out.device.clone())
            .or_default()
            .push_back(out);
    }

    /// The next lane's first frame that fits in the socket's minute now, each lane in turn; or
    /// when one will.
    fn next(&mut self, pace: &mut Pace, now: Instant) -> Result<Option<Out>, Instant> {
        let mut soonest: Option<Instant> = None;
        for _ in 0..self.turns.len() {
            let Some(device) = self.turns.pop_front() else {
                break;
            };
            let Some(lane) = self.lanes.get_mut(&device) else {
                continue;
            };
            let Some(len) = lane.front().map(Out::len) else {
                self.lanes.remove(&device);
                continue;
            };
            self.turns.push_back(device);
            match pace.when(len, now) {
                None => {
                    pace.record(len, now);
                    return Ok(lane.pop_front());
                }
                Some(at) => soonest = Some(soonest.map_or(at, |s| s.min(at))),
            }
        }
        soonest.map_or(Ok(None), Err)
    }

    /// Only the lanes of the devices `keep` keeps.
    fn retain(&mut self, keep: impl Fn(&str) -> bool) {
        self.lanes.retain(|device, _| keep(device));
        let lanes = &self.lanes;
        self.turns.retain(|device| lanes.contains_key(device));
    }
}

pub struct Relay {
    file: PathBuf,
    kept: Mutex<Option<Arc<Kept>>>,
    sessions: Mutex<HashMap<String, Live>>,
    epochs: AtomicU64,
    lanes: Mutex<Lanes>,
    /// A frame waits in a lane.
    queued: Notify,
    /// A phone was invited, paired or forgotten: the Sphere's devices are checked now.
    wake: Notify,
    /// Whether the relay's socket is open now.
    up: AtomicBool,
    running: AtomicBool,
}

/// Marks the socket up while it lives.
struct Up<'a>(&'a AtomicBool);

impl Drop for Up<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Relaxed);
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

fn sha256_hex(text: &str) -> String {
    hex::encode(obi_protocol::keys::sha256(text.as_bytes()))
}

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn random(bytes: usize) -> String {
    let mut buffer = vec![0u8; bytes];
    getrandom::fill(&mut buffer).expect("the system's random source works");
    b64url(&buffer)
}

impl Relay {
    pub fn open(home: &Path) -> Arc<Relay> {
        let relay = Relay {
            file: home.join("keys").join("relay.json"),
            kept: Mutex::new(None),
            sessions: Mutex::new(HashMap::new()),
            epochs: AtomicU64::new(0),
            lanes: Mutex::new(Lanes::default()),
            queued: Notify::new(),
            wake: Notify::new(),
            up: AtomicBool::new(false),
            running: AtomicBool::new(false),
        };
        if let Some(kept) = relay.load() {
            *lock(&relay.kept) = Some(Arc::new(kept));
        }
        Arc::new(relay)
    }

    fn load(&self) -> Option<Kept> {
        let bytes = std::fs::read(&self.file).ok()?;
        let kept: Value = serde_json::from_slice(&bytes).ok()?;
        let seed = hex::decode(kept["key"].as_str()?).ok()?;
        let key = MacKey::from_bytes(&seed).ok()?;
        crate::secrets::known().learn_forms(KEY_SECRET, &[kept["key"].as_str()?.as_bytes(), &seed]);
        Some(Kept {
            relay: kept["relay"].as_str()?.to_owned(),
            public: b64url(&key.public()),
            key,
        })
    }

    /// The relay's id and the Mac's key, made and kept the first time.
    fn kept(&self) -> Result<Arc<Kept>, String> {
        let mut kept = self.kept.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(kept) = kept.as_ref() {
            return Ok(kept.clone());
        }
        let (key, seed) = MacKey::generate().map_err(str::to_owned)?;
        let relay = random(32);
        let text = json!({"relay": relay, "key": hex::encode(seed)}).to_string();
        crate::store::make_private_dir(self.file.parent().expect("a folder"))
            .and_then(|()| crate::store::write_private(&self.file, text.as_bytes()))
            .map_err(|e| format!("obid couldn't keep its relay key: {e}"))?;
        crate::secrets::known().learn_forms(KEY_SECRET, &[hex::encode(seed).as_bytes(), &seed]);
        let made = Arc::new(Kept {
            relay,
            public: b64url(&key.public()),
            key,
        });
        *kept = Some(made.clone());
        Ok(made)
    }

    /// A relay token for a phone about to pair, its digest registered with the Sphere first so the
    /// phone's first call can come through; `None` when obid is a member of no Sphere.
    pub async fn invite(&self, link: &Link) -> Result<Option<RelayInvite>, (StatusCode, String)> {
        let Some(client) = link.relay_client() else {
            return Ok(None);
        };
        let kept = self
            .kept()
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
        let refused = |e: ClientError| {
            link.relay_refused(&e);
            let status = if matches!(e, ClientError::Unreachable(_)) {
                StatusCode::GATEWAY_TIMEOUT
            } else {
                StatusCode::BAD_GATEWAY
            };
            let message = match &e {
                ClientError::Refused { status: 429, .. } => {
                    "Your Obysphere relays 16 phones for this Mac at most: revoke one first.".into()
                }
                _ => format!("obid couldn't reach your Obysphere's relay: {e}"),
            };
            (status, message)
        };
        let (access, _) = link.relay_token().await.map_err(refused)?;
        let token = random(32);
        client
            .put_relay(&access, &kept.relay)
            .await
            .map_err(refused)?;
        client
            .put_relay_device(&access, &kept.relay, &sha256_hex(&token))
            .await
            .map_err(refused)?;
        Ok(Some(RelayInvite {
            sphere: client.base().to_owned(),
            relay: kept.relay.clone(),
            token,
            key: kept.public.clone(),
        }))
    }

    /// The Sphere's devices are checked against the paired ones now.
    pub fn wake(&self) {
        self.wake.notify_one();
    }

    /// Waits, `at_most`, for the relay's socket to be open: a phone that comes before it is
    /// closed with `4008` and waits 30 seconds (sphere-api.md 9.3), so an invitation waits first.
    pub async fn ready(&self, at_most: Duration) {
        let until = Instant::now() + at_most;
        while !self.up.load(Ordering::Relaxed) && Instant::now() < until {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    /// The device `device` (its relay token's digest) is forgotten: its session ends now.
    pub fn forget(&self, device: &str) {
        self.end(device);
        self.wake();
    }

    /// `device`'s session ends, and what waited to go to it with it.
    fn end(&self, device: &str) {
        lock(&self.sessions).remove(device);
        lock(&self.lanes).retain(|d| d != device);
    }

    fn keep_only(&self, devices: &HashSet<String>) {
        lock(&self.sessions).retain(|device, _| devices.contains(device));
        lock(&self.lanes).retain(|d| devices.contains(d));
    }

    fn seal(&self, out: &Out) -> Option<Vec<u8>> {
        let mut sessions = lock(&self.sessions);
        let live = sessions
            .get_mut(&out.device)
            .filter(|l| l.epoch == out.epoch)?;
        Some(live.sealer.seal(&out.frame.encode()))
    }

    /// Puts a frame in its phone's lane, once there's room: false when its session is over.
    async fn push(&self, device: &str, epoch: u64, frame: Frame) -> bool {
        let room = lock(&self.sessions)
            .get(device)
            .filter(|l| l.epoch == epoch)
            .map(|l| l.room.clone());
        let Some(Ok(room)) = (match room {
            Some(room) => Some(room.acquire_owned().await),
            None => None,
        }) else {
            return false;
        };
        lock(&self.lanes).push(Out {
            device: device.to_owned(),
            epoch,
            frame,
            _room: Some(room),
        });
        self.queued.notify_one();
        true
    }

    /// Answers `stream` with `status` at once, when the phone's lane has room; else nothing.
    fn refuse(&self, live: &Live, device: &str, stream: u32, status: u16, message: &str) {
        let Ok(room) = live.room.clone().try_acquire_many_owned(3) else {
            return;
        };
        let head = json!({"status": status, "headers": {"content-type": "application/json"}});
        let mut lanes = lock(&self.lanes);
        let mut room = Some(room);
        for (kind, payload) in [
            (Kind::Open, head.to_string().into_bytes()),
            (
                Kind::Data,
                json!({"error": message}).to_string().into_bytes(),
            ),
            (Kind::End, Vec::new()),
        ] {
            lanes.push(Out {
                device: device.to_owned(),
                epoch: live.epoch,
                frame: Frame::new(stream, kind, payload),
                // The room goes when the last of the three does.
                _room: if kind == Kind::End { room.take() } else { None },
            });
        }
        drop(lanes);
        self.queued.notify_one();
    }

    /// The phone's hello starts its session, replacing any before: the welcome to send.
    fn start(&self, device: &str, hello: &[u8]) -> Option<Vec<u8>> {
        let kept = lock(&self.kept).clone()?;
        match kept.key.welcome(hello) {
            Ok(session) => {
                let epoch = self.epochs.fetch_add(1, Ordering::Relaxed);
                self.end(device);
                lock(&self.sessions).insert(
                    device.to_owned(),
                    Live {
                        epoch,
                        sealer: session.sealer,
                        opener: session.opener,
                        last_stream: 0,
                        streams: HashMap::new(),
                        room: Arc::new(Semaphore::new(LANE)),
                    },
                );
                Some(session.welcome)
            }
            Err(why) => {
                tracing::debug!("the phone relay dropped a hello: {why}");
                None
            }
        }
    }

    /// One sealed envelope from `device`: opened, and what it carries taken in. When one before
    /// it went missing, the session is over: the sealed `reset` that tells the phone so, to send.
    fn take(
        &self,
        shared: &Arc<Shared>,
        gateway: &Router,
        device: &str,
        envelope: &[u8],
    ) -> Option<Vec<u8>> {
        let mut sessions = lock(&self.sessions);
        let live = sessions.get_mut(device)?;
        let plain = match live.opener.open(envelope) {
            Ok(plain) => plain,
            Err(why) if why == envelope::GAP => {
                let mut live = sessions.remove(device)?;
                drop(sessions);
                lock(&self.lanes).retain(|d| d != device);
                tracing::info!("the phone relay ended a session: {why}");
                return Some(
                    live.sealer
                        .seal(&Frame::new(0, Kind::Reset, OVER.as_bytes().to_vec()).encode()),
                );
            }
            Err(why) => {
                tracing::debug!("the phone relay dropped an envelope: {why}");
                return None;
            }
        };
        let frame = Frame::decode(&plain)?;
        let stream = frame.stream;
        match frame.kind {
            Kind::Open => {
                // A stream is new, its id above every earlier one's: never one of before again.
                if stream <= live.last_stream {
                    return None;
                }
                live.last_stream = stream;
                let Some(head) = frame.value().filter(Value::is_object) else {
                    self.refuse(live, device, stream, 400, "That request can't be read.");
                    return None;
                };
                if live.streams.len() >= STREAMS {
                    self.refuse(live, device, stream, 429, "Too many requests at once.");
                    return None;
                }
                live.streams.insert(
                    stream,
                    Stream::Asking {
                        head,
                        body: Vec::new(),
                    },
                );
            }
            Kind::Data => {
                // What a phone's requests hold here before they're whole: 4 MiB in all.
                let held: usize = live
                    .streams
                    .values()
                    .map(|s| match s {
                        Stream::Asking { body, .. } => body.len(),
                        Stream::Answering(_) => 0,
                    })
                    .sum();
                if let Some(Stream::Asking { body, .. }) = live.streams.get_mut(&stream) {
                    if held + frame.payload.len() > BODY {
                        live.streams.remove(&stream);
                        self.refuse(live, device, stream, 413, "That request is too large.");
                        return None;
                    }
                    body.extend_from_slice(&frame.payload);
                }
            }
            Kind::End => {
                if let Some(Stream::Asking { head, body }) = live.streams.remove(&stream) {
                    let task = tokio::spawn(answer(
                        shared.clone(),
                        gateway.clone(),
                        device.to_owned(),
                        live.epoch,
                        stream,
                        head,
                        body,
                    ));
                    live.streams
                        .insert(stream, Stream::Answering(task.abort_handle()));
                }
            }
            Kind::Reset => {
                if let Some(Stream::Answering(task)) = live.streams.remove(&stream) {
                    task.abort();
                }
            }
        }
        None
    }

    /// The answer on `stream` is all out: it no longer counts.
    fn done(&self, device: &str, epoch: u64, stream: u32) {
        let mut sessions = lock(&self.sessions);
        if let Some(live) = sessions.get_mut(device).filter(|l| l.epoch == epoch) {
            live.streams.remove(&stream);
        }
    }
}

/// The request a sealed `open` frame and its body ask for, marked as come through the relay.
fn request(head: &Value, body: Vec<u8>, device: &str) -> Option<Request> {
    let method = Method::from_bytes(head["method"].as_str()?.as_bytes()).ok()?;
    let path = head["path"].as_str().filter(|p| p.starts_with('/'))?;
    let mut request = Request::builder().method(method).uri(path);
    for (name, value) in head["headers"].as_object().into_iter().flatten() {
        if let (Ok(name), Some(Ok(value))) = (
            HeaderName::from_bytes(name.as_bytes()),
            value.as_str().map(HeaderValue::from_str),
        ) {
            request = request.header(name, value);
        }
    }
    request
        .extension(Relayed(device.to_owned()))
        .body(Body::from(body))
        .ok()
}

/// Answers one request through the gateway's router, and sends the answer back on its stream:
/// its status and headers, its body a chunk at a time (an event stream as it comes), its end.
/// Each frame waits for room in the phone's lane, so a phone that's slow to take them only slows
/// its own answers.
async fn answer(
    shared: Arc<Shared>,
    gateway: Router,
    device: String,
    epoch: u64,
    stream: u32,
    head: Value,
    body: Vec<u8>,
) {
    let relay = &shared.relay;
    let send = |kind: Kind, payload: Vec<u8>| {
        relay.push(&device, epoch, Frame::new(stream, kind, payload))
    };
    let response = match request(&head, body, &device) {
        Some(request) => match gateway.oneshot(request).await {
            Ok(response) => response,
            Err(never) => match never {},
        },
        None => (
            StatusCode::BAD_REQUEST,
            axum::Json(json!({"error": "That request can't be read."})),
        )
            .into_response(),
    };
    let (parts, body) = response.into_parts();
    let headers: Map<String, Value> = parts
        .headers
        .iter()
        .filter_map(|(name, value)| Some((name.to_string(), json!(value.to_str().ok()?))))
        .collect();
    let head = json!({"status": parts.status.as_u16(), "headers": headers});
    if !send(Kind::Open, head.to_string().into_bytes()).await {
        return;
    }
    let mut data = body.into_data_stream();
    while let Some(chunk) = data.next().await {
        let Ok(bytes) = chunk else {
            send(Kind::Reset, b"The answer broke off.".to_vec()).await;
            relay.done(&device, epoch, stream);
            return;
        };
        for piece in bytes.chunks(CHUNK) {
            if !send(Kind::Data, piece.to_vec()).await {
                return;
            }
        }
    }
    send(Kind::End, Vec::new()).await;
    relay.done(&device, epoch, stream);
}

/// At most [`FRAMES_A_MINUTE`] frames and [`BYTES_A_MINUTE`] bytes in any minute: a sliding
/// minute, so never more in the Sphere's own.
#[derive(Default)]
struct Pace {
    sent: VecDeque<(Instant, usize)>,
    bytes: usize,
}

impl Pace {
    /// When `len` more bytes fit: `None` now.
    fn when(&mut self, len: usize, now: Instant) -> Option<Instant> {
        while let Some((at, n)) = self.sent.front().copied() {
            if now.duration_since(at) < Duration::from_secs(60) {
                break;
            }
            self.sent.pop_front();
            self.bytes -= n;
        }
        if self.sent.len() < FRAMES_A_MINUTE && self.bytes + len <= BYTES_A_MINUTE {
            return None;
        }
        Some(self.sent.front().map_or(now, |(at, _)| *at) + Duration::from_secs(60))
    }

    fn record(&mut self, len: usize, now: Instant) {
        self.sent.push_back((now, len));
        self.bytes += len;
    }

    async fn wait(&mut self, len: usize) {
        loop {
            let now = Instant::now();
            match self.when(len, now) {
                None => return self.record(len, now),
                Some(at) => tokio::time::sleep_until(at).await,
            }
        }
    }
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Why a connection ended, how long to wait before the next (the backoff when `None`), and
/// whether its socket had opened (then the backoff starts again).
struct Ended {
    why: String,
    wait: Option<Duration>,
    opened: bool,
}

fn again(why: impl Into<String>) -> Ended {
    Ended {
        why: why.into(),
        wait: None,
        opened: false,
    }
}

fn dropped<E>(_: E) -> Ended {
    again("the relay's socket dropped")
}

fn refused(link: &Link, error: ClientError) -> Ended {
    link.relay_refused(&error);
    again(error.to_string())
}

/// What there is to relay: the Sphere, the relay, and the devices it must know.
struct Want {
    client: Client,
    kept: Arc<Kept>,
    devices: HashSet<String>,
}

fn want(shared: &Shared) -> Option<Want> {
    let client = shared.link.relay_client()?;
    let kept = shared
        .relay
        .kept
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()?;
    Some(Want {
        client,
        kept,
        devices: shared.gateway.relay_devices(SystemTime::now()),
    })
}

/// The Sphere's devices made the paired ones: the relay is put, then each missing device, and
/// each forgotten one deleted (its socket closes).
async fn sync(shared: &Shared, want: &Want, token: &str) -> Result<(), Ended> {
    let relay = &want.kept.relay;
    let known: HashSet<String> = want
        .client
        .put_relay(token, relay)
        .await
        .map_err(|e| refused(&shared.link, e))?
        .into_iter()
        .collect();
    for device in want.devices.difference(&known) {
        want.client
            .put_relay_device(token, relay, device)
            .await
            .map_err(|e| refused(&shared.link, e))?;
    }
    for device in known.difference(&want.devices) {
        want.client
            .delete_relay_device(token, relay, device)
            .await
            .map_err(|e| refused(&shared.link, e))?;
    }
    Ok(())
}

async fn socket(shared: &Shared, want: &Want, token: &str) -> Result<Ws, Ended> {
    let base = want.client.base();
    let base = match base.split_once("://") {
        Some(("https", rest)) => format!("wss://{rest}"),
        Some(("http", rest)) => format!("ws://{rest}"),
        _ => return Err(again("the Sphere's address isn't one a socket can use")),
    };
    let mut request = format!("{base}/v0.1/relay/{}", want.kept.relay)
        .into_client_request()
        .map_err(|e| again(e.to_string()))?;
    let bearer = format!("Bearer {token}")
        .parse()
        .map_err(|_| again("the token isn't a header value"))?;
    request.headers_mut().insert("Authorization", bearer);
    let config = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(envelope::MAX + 64))
        .max_frame_size(Some(envelope::MAX + 64));
    match tokio_tungstenite::connect_async_with_config(request, Some(config), false).await {
        Ok((ws, _)) => Ok(ws),
        Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
            let status = response.status().as_u16();
            if status == 401 {
                shared.link.relay_refused(&ClientError::Refused {
                    status,
                    code: "unauthorized".into(),
                    message: String::new(),
                });
            }
            let wait = response
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.trim().parse().ok())
                .map(Duration::from_secs);
            Err(Ended {
                why: format!("the Sphere refused the relay's socket ({status})"),
                wait,
                opened: false,
            })
        }
        Err(e) => Err(again(format!("the Sphere couldn't be reached: {e}"))),
    }
}

/// Sends `envelope` to the phone `device` (hex) behind its 32 bytes, now.
async fn put(ws: &mut Ws, device: &str, envelope: Vec<u8>) -> Result<(), Ended> {
    let Ok(mut frame) = hex::decode(device) else {
        return Ok(());
    };
    frame.extend_from_slice(&envelope);
    ws.send(Message::Binary(frame.into()))
        .await
        .map_err(dropped)
}

/// [`put`], once it fits in the socket's minute.
async fn send(ws: &mut Ws, pace: &mut Pace, device: &str, envelope: Vec<u8>) -> Result<(), Ended> {
    pace.wait(32 + envelope.len()).await;
    put(ws, device, envelope).await
}

async fn ping(ws: &mut Ws, pace: &mut Pace, pings: &mut u32) -> Result<(), Ended> {
    pace.wait(4).await;
    ws.send(Message::Text("ping".into()))
        .await
        .map_err(dropped)?;
    *pings += 1;
    Ok(())
}

/// What one message from the socket asks for.
enum Heard {
    Nothing,
    /// An envelope to send that phone now: a welcome, or the `reset` ending its session.
    Send(String, Vec<u8>),
    Pong,
}

/// One message from the socket, or why the socket ended.
fn heard(shared: &Arc<Shared>, gateway: &Router, message: Message) -> Result<Heard, Ended> {
    let relay = &shared.relay;
    match message {
        Message::Binary(bytes) if bytes.len() > 32 => {
            let device = hex::encode(&bytes[..32]);
            let envelope = &bytes[32..];
            // A hello's second byte is 1; a sealed envelope's is 3.
            let reply = if envelope.get(1) == Some(&1) {
                // Only a phone paired or invited through this relay starts a session: not one the
                // Sphere makes up, nor one that was forgotten.
                let known = shared
                    .gateway
                    .relay_devices(SystemTime::now())
                    .contains(&device);
                known.then(|| relay.start(&device, envelope)).flatten()
            } else {
                relay.take(shared, gateway, &device, envelope)
            };
            return Ok(reply.map_or(Heard::Nothing, |envelope| Heard::Send(device, envelope)));
        }
        Message::Text(text) if text.as_str() == "pong" => return Ok(Heard::Pong),
        Message::Text(text) => {
            let said: Value = serde_json::from_str(text.as_str()).unwrap_or_default();
            if said["peer"] == "left"
                && let Some(device) = said["device"].as_str()
            {
                relay.end(device);
            }
        }
        Message::Close(frame) => {
            let code = frame.as_ref().map_or(1005, |f| u16::from(f.code));
            return Err(Ended {
                why: format!("the Sphere closed the relay's socket ({code})"),
                // An expired token: a new one at once. Past the minute's budget: a minute.
                wait: match code {
                    4007 => Some(Duration::ZERO),
                    4009 => Some(Duration::from_secs(60)),
                    _ => None,
                },
                opened: false,
            });
        }
        _ => {}
    }
    Ok(Heard::Nothing)
}

/// Keeps the relay's socket while there's a phone to relay for, again after a drop.
pub fn spawn(shared: Arc<Shared>, gateway: Router) {
    if !shared.relay.running.swap(true, Ordering::Relaxed) {
        tokio::spawn(run(shared, gateway));
    }
}

async fn run(shared: Arc<Shared>, gateway: Router) {
    let mut stopping = shared.stopping.clone();
    let mut backoff = Duration::from_secs(1);
    // The devices the Sphere was last told of.
    let mut synced: Option<HashSet<String>> = None;
    loop {
        if *stopping.borrow() {
            return;
        }
        let ended = match want(&shared) {
            Some(want) if !want.devices.is_empty() => {
                connection(&shared, &gateway, want, &mut synced).await
            }
            // No phone left: the Sphere forgets the last ones' tokens, then nothing until one is.
            Some(want) if synced.as_ref() != Some(&want.devices) => {
                match shared.link.relay_token().await {
                    Ok((token, _)) => sync(&shared, &want, &token)
                        .await
                        .map(|()| synced = Some(want.devices)),
                    Err(e) => Err(refused(&shared.link, e)),
                }
            }
            _ => {
                tokio::select! {
                    () = shared.relay.wake.notified() => {}
                    () = tokio::time::sleep(CHECK_EVERY) => {}
                    _ = stopping.changed() => {}
                }
                continue;
            }
        };
        match ended {
            Ok(()) => backoff = Duration::from_secs(1),
            Err(ended) => {
                if ended.opened {
                    backoff = Duration::from_secs(1);
                }
                tracing::warn!("the phone relay: {}", ended.why);
                let wait = ended.wait.unwrap_or(backoff);
                tokio::select! {
                    () = tokio::time::sleep(wait) => {}
                    _ = stopping.changed() => {}
                }
                backoff = (backoff * 2).min(BACKOFF_MAX);
            }
        }
    }
}

fn renewal(ends: i64) -> Instant {
    let left = ends - obi_protocol::time::now() - RENEW_BEFORE;
    Instant::now() + Duration::from_secs(left.max(1) as u64)
}

/// One socket, from opening it until it ends or there's no phone left to relay for.
async fn connection(
    shared: &Arc<Shared>,
    gateway: &Router,
    want: Want,
    synced: &mut Option<HashSet<String>>,
) -> Result<(), Ended> {
    let relay = &shared.relay;
    let (token, ends) = shared
        .link
        .relay_token()
        .await
        .map_err(|e| refused(&shared.link, e))?;
    sync(shared, &want, &token).await?;
    *synced = Some(want.devices.clone());
    let ws = socket(shared, &want, &token).await?;
    relay.up.store(true, Ordering::Relaxed);
    let _up = Up(&relay.up);
    tracing::info!("the phone relay is connected");
    serve(shared, gateway, &want, ws, token, ends, synced)
        .await
        .map_err(|ended| Ended {
            opened: true,
            ..ended
        })
}

async fn serve(
    shared: &Arc<Shared>,
    gateway: &Router,
    want: &Want,
    mut ws: Ws,
    mut token: String,
    ends: i64,
    synced: &mut Option<HashSet<String>>,
) -> Result<(), Ended> {
    let relay = &shared.relay;
    let mut pace = Pace::default();
    let mut ping_every = tokio::time::interval(PING_EVERY);
    let mut check = tokio::time::interval(CHECK_EVERY);
    let mut last_heard = Instant::now();
    // The pings the Sphere hasn't answered yet.
    let mut pings = 0u32;
    let mut stopping = shared.stopping.clone();
    let mut renew_at = renewal(ends);
    loop {
        // What may go now goes, the phones' lanes in turn.
        let mut wait = None;
        for sent in 0..=BURST {
            if sent == BURST {
                wait = Some(Instant::now());
                break;
            }
            let next = lock(&relay.lanes).next(&mut pace, Instant::now());
            match next {
                Ok(Some(out)) => {
                    if let Some(sealed) = relay.seal(&out) {
                        put(&mut ws, &out.device, sealed).await?;
                    }
                }
                Ok(None) => break,
                Err(at) => {
                    wait = Some(at);
                    break;
                }
            }
        }
        tokio::select! {
            message = ws.next() => {
                let Some(Ok(message)) = message else {
                    return Err(again("the relay's socket dropped"));
                };
                last_heard = Instant::now();
                match heard(shared, gateway, message)? {
                    Heard::Send(device, envelope) => send(&mut ws, &mut pace, &device, envelope).await?,
                    Heard::Pong => pings = pings.saturating_sub(1),
                    Heard::Nothing => {}
                }
            }
            () = relay.queued.notified() => {}
            () = tokio::time::sleep_until(wait.unwrap_or_else(Instant::now)), if wait.is_some() => {}
            _ = ping_every.tick() => {
                if last_heard.elapsed() > SILENCE {
                    return Err(again("the relay's socket went silent"));
                }
                ping(&mut ws, &mut pace, &mut pings).await?;
            }
            _ = async {
                tokio::select! {
                    () = relay.wake.notified() => {}
                    _ = check.tick() => {}
                }
            } => {
                // obid left its Sphere: nothing to relay for any more.
                if shared.link.relay_client().is_none() {
                    let _ = ws.close(None).await;
                    return Ok(());
                }
                let devices = shared.gateway.relay_devices(SystemTime::now());
                relay.keep_only(&devices);
                if synced.as_ref() != Some(&devices) {
                    let now = Want { devices: devices.clone(), client: want.client.clone(), kept: want.kept.clone() };
                    sync(shared, &now, &token).await?;
                    *synced = Some(devices.clone());
                }
                if devices.is_empty() {
                    let _ = ws.close(None).await;
                    return Ok(());
                }
            }
            () = tokio::time::sleep_until(renew_at) => {
                let (new_token, new_ends) = shared.link.relay_token().await.map_err(|e| refused(&shared.link, e))?;
                if new_token == token {
                    renew_at = Instant::now() + Duration::from_secs(5);
                    continue;
                }
                ws = renew(shared, gateway, want, ws, &new_token, &mut pace, &mut pings).await?;
                token = new_token;
                renew_at = renewal(new_ends);
                last_heard = Instant::now();
            }
            _ = stopping.changed() => {
                let _ = ws.close(None).await;
                return Ok(());
            }
        }
    }
}

/// A new socket with a new token in place of `old`, with nothing lost or out of order either way,
/// so no session sees a gap: a `pong` on the old socket says the Sphere has had everything sent
/// on it; then the new one replaces it (the Sphere closes the old with `4003`), and what the phones
/// sent to the old one before that is read first. What that asks to send goes on the new one.
async fn renew(
    shared: &Arc<Shared>,
    gateway: &Router,
    want: &Want,
    mut old: Ws,
    token: &str,
    pace: &mut Pace,
    pings: &mut u32,
) -> Result<Ws, Ended> {
    let mut later = Vec::new();
    ping(&mut old, pace, pings).await?;
    let until = Instant::now() + RENEWING;
    while *pings > 0 {
        let Ok(Some(Ok(message))) = tokio::time::timeout_at(until, old.next()).await else {
            return Err(again("the relay's socket didn't answer before its renewal"));
        };
        match heard(shared, gateway, message)? {
            Heard::Send(device, envelope) => later.push((device, envelope)),
            Heard::Pong => *pings -= 1,
            Heard::Nothing => {}
        }
    }
    let mut new = socket(shared, want, token).await?;
    let until = Instant::now() + RENEWING;
    while let Ok(Some(Ok(message))) = tokio::time::timeout_at(until, old.next()).await {
        match heard(shared, gateway, message) {
            Ok(Heard::Send(device, envelope)) => later.push((device, envelope)),
            Ok(_) => {}
            Err(_) => break,
        }
    }
    for (device, envelope) in later {
        send(&mut new, pace, &device, envelope).await?;
    }
    Ok(new)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn out(device: &str, payload: usize) -> Out {
        Out {
            device: device.into(),
            epoch: 0,
            frame: Frame::new(1, Kind::Data, vec![0; payload]),
            _room: None,
        }
    }

    /// One phone's long answer doesn't hold up another's: the lanes take turns, and a frame that
    /// fits in the minute goes before one of another lane's that doesn't.
    #[test]
    fn the_phones_lanes_take_turns() {
        let now = Instant::now();
        let mut pace = Pace::default();
        let mut lanes = Lanes::default();
        for _ in 0..10 {
            lanes.push(out("a", CHUNK));
        }
        lanes.push(out("b", 10));
        lanes.push(out("b", 10));
        let order: Vec<String> = (0..5)
            .map(|_| lanes.next(&mut pace, now).unwrap().unwrap().device)
            .collect();
        assert_eq!(order, ["a", "b", "a", "b", "a"]);
        // The minute is nearly full: a's chunks wait, b's small frame goes.
        let mut pace = Pace::default();
        pace.record(BYTES_A_MINUTE - 100, now);
        lanes.push(out("b", 10));
        assert_eq!(lanes.next(&mut pace, now).unwrap().unwrap().device, "b");
        let at = lanes.next(&mut pace, now).err().unwrap();
        assert_eq!(at, now + Duration::from_secs(60));
        // A forgotten phone's lane goes with it.
        lanes.retain(|d| d != "a");
        assert!(lanes.next(&mut Pace::default(), now).unwrap().is_none());
    }
}
