//! The phone relay (docs/runner-api.md, "obid only: the phone relay"; spec sphere-api.md section
//! 9): how a paired phone reaches obid through the owner's own Obysphere, with no port open on the
//! Mac and no tunnel. While obid is a member of a Sphere and a phone is paired through it (or
//! invited to), obid keeps one WebSocket on its relay as its member Obi. Each phone's frames come
//! in behind the 32 bytes of its device id (the SHA-256 of its relay token); obid opens the phone's
//! sealed envelopes (crate::relay::envelope) and hands each request inside to the gateway's own
//! router, in process, so pairing, device tokens and the allowlist are the gateway's, unchanged.
//! The answer goes back sealed, a frame at a time, paced under the Sphere's limits.
//!
//! What obid keeps for it: `home/keys/relay.json` (0600), the relay's id and the Mac's X25519 key,
//! made when the first phone is invited; and, in `home/gateway-devices.json`, each relay-paired
//! device's relay token digest (crate::gateway). The relay tokens themselves are only in the QR.

pub mod envelope;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
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
use tokio::sync::{Notify, mpsc};
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
/// How often the devices the Sphere knows are checked against the paired ones (expiries).
const CHECK_EVERY: Duration = Duration::from_secs(60);
/// The most body one data frame carries.
const CHUNK: usize = 65_536;
/// The most requests one phone has open at once.
const STREAMS: usize = 32;
/// The largest request a phone may send (the gateway's), and the most its unfinished requests hold.
const BODY: usize = 4 << 20;
/// Under the Sphere's 4,800 frames and 64 MiB a minute for a Mac's socket, with room to spare.
const FRAMES_A_MINUTE: usize = 4_000;
const BYTES_A_MINUTE: usize = 56 << 20;
/// What the Mac's X25519 key is known by in crate::secrets: it never leaves obid.
const KEY_SECRET: &str = "relay-key";

/// The relay's id and the Mac's key, from `home/keys/relay.json`.
struct Kept {
    relay: String,
    key: MacKey,
    /// The key's public half, base64url: the QR's `key`.
    public: String,
}

/// One phone's session: its envelopes' keys and its requests under way.
struct Live {
    epoch: u64,
    sealer: Sealer,
    opener: Opener,
    last_stream: u32,
    streams: HashMap<u32, Stream>,
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

/// A frame for a phone, sealed only when it goes out, so counters go in the order sent.
struct Out {
    device: String,
    epoch: u64,
    frame: Frame,
}

pub struct Relay {
    file: PathBuf,
    kept: Mutex<Option<Arc<Kept>>>,
    sessions: Mutex<HashMap<String, Live>>,
    epochs: AtomicU64,
    /// A phone was invited, paired or forgotten: the Sphere's devices are checked now.
    wake: Notify,
    /// Whether the relay's socket is open now.
    up: AtomicBool,
    out: mpsc::Sender<Out>,
    out_rx: Mutex<Option<mpsc::Receiver<Out>>>,
}

/// Marks the socket up while it lives.
struct Up<'a>(&'a AtomicBool);

impl Drop for Up<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Relaxed);
    }
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
        let (out, out_rx) = mpsc::channel(256);
        let relay = Relay {
            file: home.join("keys").join("relay.json"),
            kept: Mutex::new(None),
            sessions: Mutex::new(HashMap::new()),
            epochs: AtomicU64::new(0),
            wake: Notify::new(),
            up: AtomicBool::new(false),
            out,
            out_rx: Mutex::new(Some(out_rx)),
        };
        if let Some(kept) = relay.load() {
            *relay.kept.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(kept));
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
        self.sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(device);
        self.wake();
    }

    fn keep_only(&self, devices: &HashSet<String>) {
        self.sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|device, _| devices.contains(device));
    }

    fn seal(&self, out: &Out) -> Option<Vec<u8>> {
        let mut sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        let live = sessions
            .get_mut(&out.device)
            .filter(|l| l.epoch == out.epoch)?;
        Some(live.sealer.seal(&out.frame.encode()))
    }

    /// The phone's hello starts its session, replacing any before: the welcome to send.
    fn start(&self, device: &str, hello: &[u8]) -> Option<Vec<u8>> {
        let kept = self
            .kept
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()?;
        match kept.key.welcome(hello) {
            Ok(session) => {
                let epoch = self.epochs.fetch_add(1, Ordering::Relaxed);
                self.sessions
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(
                        device.to_owned(),
                        Live {
                            epoch,
                            sealer: session.sealer,
                            opener: session.opener,
                            last_stream: 0,
                            streams: HashMap::new(),
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

    /// One sealed envelope from `device`: opened, and what it carries taken in.
    fn take(&self, shared: &Arc<Shared>, gateway: &Router, device: &str, envelope: &[u8]) {
        let mut sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        let Some(live) = sessions.get_mut(device) else {
            return;
        };
        let frame = match live.opener.open(envelope) {
            Ok(plain) => Frame::decode(&plain),
            Err(why) => {
                tracing::debug!("the phone relay dropped an envelope: {why}");
                return;
            }
        };
        let Some(frame) = frame else {
            return;
        };
        let epoch = live.epoch;
        let stream = frame.stream;
        let refuse = |status: u16, message: &str| {
            let out = self.out.clone();
            let device = device.to_owned();
            let message = json!({"error": message}).to_string();
            tokio::spawn(async move {
                for (kind, payload) in [
                    (
                        Kind::Open,
                        json!({"status": status, "headers": {"content-type": "application/json"}})
                            .to_string()
                            .into_bytes(),
                    ),
                    (Kind::Data, message.into_bytes()),
                    (Kind::End, Vec::new()),
                ] {
                    let frame = Frame::new(stream, kind, payload);
                    if out
                        .send(Out {
                            device: device.clone(),
                            epoch,
                            frame,
                        })
                        .await
                        .is_err()
                    {
                        return;
                    }
                }
            });
        };
        match frame.kind {
            Kind::Open => {
                // A stream is new, its id above every earlier one's: never one of before again.
                if stream <= live.last_stream {
                    return;
                }
                live.last_stream = stream;
                let Some(head) = frame.value().filter(Value::is_object) else {
                    return refuse(400, "That request can't be read.");
                };
                if live.streams.len() >= STREAMS {
                    return refuse(429, "Too many requests at once.");
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
                        return refuse(413, "That request is too large.");
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
                        epoch,
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
    }

    /// The answer on `stream` is all out: it no longer counts.
    fn done(&self, device: &str, epoch: u64, stream: u32) {
        let mut sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
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
async fn answer(
    shared: Arc<Shared>,
    gateway: Router,
    device: String,
    epoch: u64,
    stream: u32,
    head: Value,
    body: Vec<u8>,
) {
    let out = shared.relay.out.clone();
    let send = |kind: Kind, payload: Vec<u8>| {
        let frame = Frame::new(stream, kind, payload);
        out.send(Out {
            device: device.clone(),
            epoch,
            frame,
        })
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
    if send(Kind::Open, head.to_string().into_bytes())
        .await
        .is_err()
    {
        return;
    }
    let mut data = body.into_data_stream();
    while let Some(chunk) = data.next().await {
        let Ok(bytes) = chunk else {
            let _ = send(Kind::Reset, b"The answer broke off.".to_vec()).await;
            shared.relay.done(&device, epoch, stream);
            return;
        };
        for piece in bytes.chunks(CHUNK) {
            if send(Kind::Data, piece.to_vec()).await.is_err() {
                return;
            }
        }
    }
    let _ = send(Kind::End, Vec::new()).await;
    shared.relay.done(&device, epoch, stream);
}

/// At most [`FRAMES_A_MINUTE`] frames and [`BYTES_A_MINUTE`] bytes in any minute: a sliding
/// minute, so never more in the Sphere's own.
#[derive(Default)]
struct Pace {
    sent: VecDeque<(Instant, usize)>,
    bytes: usize,
}

impl Pace {
    async fn wait(&mut self, len: usize) {
        loop {
            let now = Instant::now();
            while let Some((at, n)) = self.sent.front().copied() {
                if now.duration_since(at) < Duration::from_secs(60) {
                    break;
                }
                self.sent.pop_front();
                self.bytes -= n;
            }
            if self.sent.len() < FRAMES_A_MINUTE && self.bytes + len <= BYTES_A_MINUTE {
                self.sent.push_back((now, len));
                self.bytes += len;
                return;
            }
            let oldest = self.sent.front().map_or(now, |(at, _)| *at);
            tokio::time::sleep_until(oldest + Duration::from_secs(60)).await;
        }
    }
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Why a connection ended, and how long to wait before the next (the backoff when `None`).
struct Ended {
    why: String,
    wait: Option<Duration>,
}

fn again(why: impl Into<String>) -> Ended {
    Ended {
        why: why.into(),
        wait: None,
    }
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
            })
        }
        Err(e) => Err(again(format!("the Sphere couldn't be reached: {e}"))),
    }
}

/// Sends `envelope` to the phone `device` (hex) behind its 32 bytes, paced.
async fn send(ws: &mut Ws, pace: &mut Pace, device: &str, envelope: Vec<u8>) -> Result<(), Ended> {
    let Ok(mut frame) = hex::decode(device) else {
        return Ok(());
    };
    frame.extend_from_slice(&envelope);
    pace.wait(frame.len()).await;
    ws.send(Message::Binary(frame.into()))
        .await
        .map_err(|_| again("the relay's socket dropped"))
}

/// One message from the socket: a welcome to send back, or why the socket ended.
fn heard(
    shared: &Arc<Shared>,
    gateway: &Router,
    message: Message,
) -> Result<Option<(String, Vec<u8>)>, Ended> {
    let relay = &shared.relay;
    match message {
        Message::Binary(bytes) if bytes.len() > 32 => {
            let device = hex::encode(&bytes[..32]);
            let envelope = &bytes[32..];
            // A hello's second byte is 1; a sealed envelope's is 3.
            if envelope.get(1) == Some(&1) {
                return Ok(relay.start(&device, envelope).map(|w| (device, w)));
            }
            relay.take(shared, gateway, &device, envelope);
        }
        Message::Text(text) => {
            let said: Value = serde_json::from_str(text.as_str()).unwrap_or_default();
            if said["peer"] == "left"
                && let Some(device) = said["device"].as_str()
            {
                relay.forget_session(device);
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
            });
        }
        _ => {}
    }
    Ok(None)
}

impl Relay {
    fn forget_session(&self, device: &str) {
        self.sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(device);
    }
}

/// Keeps the relay's socket while there's a phone to relay for, again after a drop.
pub fn spawn(shared: Arc<Shared>, gateway: Router) {
    let Some(out) = shared
        .relay
        .out_rx
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take()
    else {
        return;
    };
    tokio::spawn(run(shared, gateway, out));
}

async fn run(shared: Arc<Shared>, gateway: Router, mut out: mpsc::Receiver<Out>) {
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
                connection(&shared, &gateway, &mut out, want, &mut synced).await
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
    out: &mut mpsc::Receiver<Out>,
    want: Want,
    synced: &mut Option<HashSet<String>>,
) -> Result<(), Ended> {
    let relay = &shared.relay;
    let (mut token, mut ends) = shared
        .link
        .relay_token()
        .await
        .map_err(|e| refused(&shared.link, e))?;
    sync(shared, &want, &token).await?;
    *synced = Some(want.devices.clone());
    let mut ws = socket(shared, &want, &token).await?;
    relay.up.store(true, Ordering::Relaxed);
    let _up = Up(&relay.up);
    tracing::info!("the phone relay is connected");
    let mut pace = Pace::default();
    let mut ping = tokio::time::interval(PING_EVERY);
    let mut check = tokio::time::interval(CHECK_EVERY);
    let mut last_heard = Instant::now();
    let mut stopping = shared.stopping.clone();
    let mut renew_at = renewal(ends);
    loop {
        tokio::select! {
            message = ws.next() => {
                let Some(Ok(message)) = message else {
                    return Err(again("the relay's socket dropped"));
                };
                last_heard = Instant::now();
                if let Some((device, welcome)) = heard(shared, gateway, message)? {
                    send(&mut ws, &mut pace, &device, welcome).await?;
                }
            }
            Some(item) = out.recv() => {
                if let Some(sealed) = relay.seal(&item) {
                    send(&mut ws, &mut pace, &item.device, sealed).await?;
                }
            }
            _ = ping.tick() => {
                if last_heard.elapsed() > SILENCE {
                    return Err(again("the relay's socket went silent"));
                }
                pace.wait(4).await;
                ws.send(Message::Text("ping".into())).await.map_err(|_| again("the relay's socket dropped"))?;
            }
            _ = async {
                tokio::select! {
                    () = relay.wake.notified() => {}
                    _ = check.tick() => {}
                }
            } => {
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
                // A new socket with a new token replaces this one (the Sphere closes it with 4003)
                // and the phones see nothing: what was on its way here is read first.
                let (new_token, new_ends) = shared.link.relay_token().await.map_err(|e| refused(&shared.link, e))?;
                if new_token == token {
                    renew_at = Instant::now() + Duration::from_secs(5);
                    continue;
                }
                let mut new = socket(shared, &want, &new_token).await?;
                while let Ok(Some(Ok(message))) = tokio::time::timeout(Duration::from_secs(5), ws.next()).await {
                    match heard(shared, gateway, message) {
                        Ok(Some((device, welcome))) => send(&mut new, &mut pace, &device, welcome).await?,
                        Ok(None) => {}
                        Err(_) => break,
                    }
                }
                ws = new;
                (token, ends) = (new_token, new_ends);
                renew_at = renewal(ends);
                last_heard = Instant::now();
            }
            _ = stopping.changed() => {
                let _ = ws.close(None).await;
                return Ok(());
            }
        }
    }
}
