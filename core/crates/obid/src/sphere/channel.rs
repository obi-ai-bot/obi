//! A `run_request`'s job channel (spec `protocol.md` section 13; `sphere-api.md` 6.3): the private
//! pipe between the guest's obid (the request's sender) and the host's (its receiver) that carries
//! the code bundle, the job's model calls, its transcript and its commits. The Sphere relays it and
//! can't read it: each side signs a new X25519 key with its Obi key, both derive a key per
//! direction with HKDF-SHA256, and every frame is ChaCha20-Poly1305 with its number as the nonce,
//! so a changed, replayed, dropped or reordered frame doesn't open and the channel starts over.
//!
//! [`open`] keeps one channel up until the exchange ends: it connects, waits for the other side,
//! makes the handshake, and does it all again after a drop. What it carries is [`Frame`]s on
//! numbered streams; what they mean is the host's and the guest's business.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use aws_lc_rs::{aead, agreement, hkdf, rand};
use futures_util::{SinkExt, StreamExt};
use obi_protocol::keys::{Keypair, b64url, from_b64url, sha256, verify_bytes};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

/// What every hello's signature starts with.
const HELLO_PREFIX: &[u8] = b"obi/0.1 channel\n";
/// The most bytes one frame may be on the wire.
pub const MAX_FRAME: usize = 262_144;
/// The most payload obid puts in one data frame: room for the header and the tag.
pub const CHUNK: usize = 65_536;
/// How often each side pings once the channel is up, and how long silence may last.
const PING_EVERY: Duration = Duration::from_secs(20);
const SILENCE: Duration = Duration::from_secs(60);
/// The longest wait before connecting again.
const BACKOFF_MAX: Duration = Duration::from_secs(30);

/// Which end of the exchange this side is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// The request's sender: its owner's job, its owner's account.
    Guest,
    /// The request's receiver: the Mac the job runs on.
    Host,
}

impl Role {
    pub fn name(self) -> &'static str {
        match self {
            Role::Guest => "guest",
            Role::Host => "host",
        }
    }

    pub fn other(self) -> Role {
        match self {
            Role::Guest => Role::Host,
            Role::Host => Role::Guest,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The handshake and the frames' keys

/// This side's hello: the signed JSON it sends, and the X25519 key it made for it.
pub struct Hello {
    secret: agreement::EphemeralPrivateKey,
    pub bytes: Vec<u8>,
}

/// Makes a hello for this connection (`channel-hello.schema.json`).
pub fn hello(
    key: &Keypair,
    sphere: &str,
    exchange: &str,
    obi: &str,
    role: Role,
) -> Result<Hello, String> {
    let rng = rand::SystemRandom::new();
    let secret = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng)
        .map_err(|_| "no X25519 key could be made".to_owned())?;
    let public = secret
        .compute_public_key()
        .map_err(|_| "no X25519 public key".to_owned())?;
    let mut hello = json!({"protocol": "obi/0.1 channel", "sphere": sphere, "correlation_id": exchange,
                           "obi": obi, "role": role.name(), "x25519": b64url(public.as_ref()),
                           "key_id": key.key_id()});
    let signature = key.sign(&signing_input(&hello)?);
    hello["signature"] = json!(signature);
    Ok(Hello {
        secret,
        bytes: hello.to_string().into_bytes(),
    })
}

fn signing_input(hello: &Value) -> Result<Vec<u8>, String> {
    let mut unsigned = hello.clone();
    if let Some(map) = unsigned.as_object_mut() {
        map.remove("signature");
    }
    let canonical = obi_protocol::jcs::canonical_bytes(&unsigned).map_err(|e| e.to_string())?;
    Ok([HELLO_PREFIX, &canonical].concat())
}

/// What a hello must be: the exchange's, from the other party in the other role, signed with that
/// Obi's current key as the directory has it.
pub struct Expect<'a> {
    pub sphere: &'a str,
    pub exchange: &'a str,
    pub obi: &'a str,
    pub role: Role,
    pub key_id: &'a str,
    pub public_key: &'a str,
}

/// Checks the other side's hello and answers its X25519 public key.
pub fn check_hello(bytes: &[u8], expect: &Expect) -> Result<Vec<u8>, String> {
    let hello: Value =
        serde_json::from_slice(bytes).map_err(|_| "the hello isn't JSON".to_owned())?;
    if !obi_protocol::schema::is_valid("channel-hello", &hello) {
        return Err("the hello doesn't match its schema".into());
    }
    let field = |k: &str| hello[k].as_str().unwrap_or("");
    if field("sphere") != expect.sphere || field("correlation_id") != expect.exchange {
        return Err("the hello is for another exchange".into());
    }
    if field("obi") != expect.obi || field("role") != expect.role.name() {
        return Err("the hello isn't from the exchange's other Obi".into());
    }
    if field("key_id") != expect.key_id {
        return Err("the hello isn't signed with that Obi's current key".into());
    }
    if !verify_bytes(
        expect.public_key,
        &signing_input(&hello)?,
        field("signature"),
    ) {
        return Err("the hello's signature doesn't verify".into());
    }
    from_b64url(field("x25519"))
        .filter(|k| k.len() == 32)
        .ok_or_else(|| "the hello's X25519 key isn't 32 bytes".into())
}

/// Seals this side's frames: its direction's key, and the number of the next frame.
pub struct Sealer {
    key: aead::LessSafeKey,
    next: u64,
}

/// Opens the other side's frames, in order.
pub struct Opener {
    key: aead::LessSafeKey,
    next: u64,
}

fn nonce(n: u64) -> aead::Nonce {
    let mut bytes = [0u8; 12];
    bytes[4..].copy_from_slice(&n.to_be_bytes());
    aead::Nonce::assume_unique_for_key(bytes)
}

impl Sealer {
    pub fn seal(&mut self, plaintext: &[u8]) -> Vec<u8> {
        let mut buffer = plaintext.to_vec();
        // Sealing only fails for a buffer past the AEAD's limit, which a frame never is.
        if self
            .key
            .seal_in_place_append_tag(nonce(self.next), aead::Aad::empty(), &mut buffer)
            .is_err()
        {
            buffer.clear();
        }
        self.next += 1;
        buffer
    }
}

impl Opener {
    pub fn open(&mut self, frame: &[u8]) -> Result<Vec<u8>, String> {
        let mut buffer = frame.to_vec();
        let plain = self
            .key
            .open_in_place(nonce(self.next), aead::Aad::empty(), &mut buffer)
            .map_err(|_| {
                "a frame didn't open: changed, replayed, dropped or out of order".to_owned()
            })?
            .len();
        self.next += 1;
        buffer.truncate(plain);
        Ok(buffer)
    }
}

/// The two keys, from this side's hello, the other side's X25519 key, and both hellos' bytes.
pub fn keys(
    own: Hello,
    role: Role,
    peer_x25519: &[u8],
    peer_hello: &[u8],
) -> Result<(Sealer, Opener), String> {
    let (guest, host) = match role {
        Role::Guest => (own.bytes.as_slice(), peer_hello),
        Role::Host => (peer_hello, own.bytes.as_slice()),
    };
    let salt = sha256([guest, host].concat());
    let peer = agreement::UnparsedPublicKey::new(&agreement::X25519, peer_x25519);
    let derive = |shared: &[u8], info: &[u8]| -> Result<aead::LessSafeKey, ()> {
        let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, &salt).extract(shared);
        let info = [info];
        let okm = prk
            .expand(&info, &aead::CHACHA20_POLY1305)
            .map_err(|_| ())?;
        Ok(aead::LessSafeKey::new(aead::UnboundKey::from(okm)))
    };
    let (send_info, recv_info): (&[u8], &[u8]) = match role {
        Role::Guest => (b"obi/0.1 channel guest>host", b"obi/0.1 channel host>guest"),
        Role::Host => (b"obi/0.1 channel host>guest", b"obi/0.1 channel guest>host"),
    };
    agreement::agree_ephemeral(
        own.secret,
        peer,
        "the X25519 agreement failed".to_owned(),
        |shared| {
            let send = derive(shared, send_info).map_err(|_| "no key".to_owned())?;
            let recv = derive(shared, recv_info).map_err(|_| "no key".to_owned())?;
            Ok((Sealer { key: send, next: 0 }, Opener { key: recv, next: 0 }))
        },
    )
}

// ---------------------------------------------------------------------------------------------
// Frames

/// A frame's kind (protocol.md section 13).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A stream opens: its payload is JSON saying what it is.
    Open = 0,
    Data = 1,
    End = 2,
    /// The stream failed: one line saying why.
    Reset = 3,
}

/// One frame's plaintext: a stream, a kind and a payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub stream: u32,
    pub kind: Kind,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(stream: u32, kind: Kind, payload: impl Into<Vec<u8>>) -> Frame {
        Frame {
            stream,
            kind,
            payload: payload.into(),
        }
    }

    pub fn json(stream: u32, kind: Kind, value: &Value) -> Frame {
        Frame::new(stream, kind, value.to_string().into_bytes())
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(5 + self.payload.len());
        out.extend_from_slice(&self.stream.to_be_bytes());
        out.push(self.kind as u8);
        out.extend_from_slice(&self.payload);
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Frame> {
        let (head, payload) = (bytes.get(..5)?, bytes.get(5..)?);
        let kind = match head[4] {
            0 => Kind::Open,
            1 => Kind::Data,
            2 => Kind::End,
            3 => Kind::Reset,
            _ => return None,
        };
        Some(Frame {
            stream: u32::from_be_bytes([head[0], head[1], head[2], head[3]]),
            kind,
            payload: payload.to_vec(),
        })
    }

    /// The payload as JSON, for `open` frames and the control stream.
    pub fn value(&self) -> Option<Value> {
        serde_json::from_slice(&self.payload).ok()
    }
}

// ---------------------------------------------------------------------------------------------
// The running channel

/// What the channel needs from its Obi: a token for the Sphere, and the other Obi's current key.
pub trait Party: Send + Sync + 'static {
    fn token(&self) -> Pin<Box<dyn Future<Output = Result<String, String>> + Send + '_>>;
    /// The other Obi's current key id and public key, from the directory.
    fn peer_key(&self, obi: &str) -> Option<(String, String)>;
}

/// Where and who.
#[derive(Clone)]
pub struct Params {
    /// The Sphere's base URL (`https://…`, or `http://` on this machine).
    pub base: String,
    pub sphere: String,
    pub exchange: String,
    pub me: String,
    pub peer: String,
    pub role: Role,
    pub key: Arc<Keypair>,
}

/// What the channel tells its owner.
#[derive(Debug)]
pub enum Event {
    /// The handshake is done: frames go through from now.
    Ready,
    /// The connection or the handshake was lost: every stream open is gone. A `Ready` follows when
    /// the channel is up again.
    Lost(String),
    Frame(Frame),
    /// The channel is over for good: the exchange ended, either Obi was removed, or the Sphere
    /// refused it. Nothing follows.
    Closed(String),
}

/// The sending half: frames to send, in order. A frame sent while the channel isn't up is dropped.
#[derive(Clone)]
pub struct Channel {
    out: mpsc::Sender<Frame>,
    stop: mpsc::Sender<()>,
}

impl Channel {
    /// Sends one frame, waiting while frames before it go out: so a big bundle and a model call
    /// share the channel frame by frame.
    pub async fn send(&self, frame: Frame) -> bool {
        self.out.send(frame).await.is_ok()
    }

    /// Sends a whole stream's bytes as data frames of at most [`CHUNK`].
    pub async fn send_data(&self, stream: u32, bytes: &[u8]) -> bool {
        for chunk in bytes.chunks(CHUNK) {
            if !self
                .send(Frame::new(stream, Kind::Data, chunk.to_vec()))
                .await
            {
                return false;
            }
        }
        true
    }

    /// Ends the channel: the connection closes, and `Closed` is the last event.
    pub async fn close(&self) {
        let _ = self.stop.send(()).await;
    }
}

/// Opens the exchange's channel and keeps it up: connecting, handshaking, and doing both again
/// after a drop, until the exchange ends or [`Channel::close`].
pub fn open(params: Params, party: Arc<dyn Party>) -> (Channel, mpsc::Receiver<Event>) {
    let (out_tx, out_rx) = mpsc::channel(16);
    let (stop_tx, stop_rx) = mpsc::channel(1);
    let (events_tx, events_rx) = mpsc::channel(64);
    tokio::spawn(run(params, party, out_rx, stop_rx, events_tx));
    (
        Channel {
            out: out_tx,
            stop: stop_tx,
        },
        events_rx,
    )
}

fn ws_url(params: &Params) -> String {
    let base = params.base.trim_end_matches('/');
    let base = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        base.to_owned()
    };
    format!(
        "{base}/v0.1/spheres/{}/channels/{}",
        params.sphere, params.exchange
    )
}

/// Why a connection ended, and whether to connect again.
enum Ended {
    Again(String),
    Over(String),
}

async fn run(
    params: Params,
    party: Arc<dyn Party>,
    mut out: mpsc::Receiver<Frame>,
    mut stop: mpsc::Receiver<()>,
    events: mpsc::Sender<Event>,
) {
    let mut backoff = Duration::from_secs(1);
    loop {
        let ended = tokio::select! {
            ended = connection(&params, party.as_ref(), &mut out, &events) => ended,
            _ = stop.recv() => Ended::Over("closed".into()),
        };
        match ended {
            Ended::Over(why) => {
                let _ = events.send(Event::Closed(why)).await;
                return;
            }
            Ended::Again(why) => {
                if events.send(Event::Lost(why)).await.is_err() {
                    return;
                }
            }
        }
        tokio::select! {
            _ = tokio::time::sleep(backoff) => {}
            _ = stop.recv() => {
                let _ = events.send(Event::Closed("closed".into())).await;
                return;
            }
        }
        backoff = (backoff * 2).min(BACKOFF_MAX);
    }
}

/// One connection, from connecting until it ends.
async fn connection(
    params: &Params,
    party: &dyn Party,
    out: &mut mpsc::Receiver<Frame>,
    events: &mpsc::Sender<Event>,
) -> Ended {
    let token = match party.token().await {
        Ok(token) => token,
        Err(e) => return Ended::Again(format!("no token for the Sphere: {e}")),
    };
    let Ok(mut request) = ws_url(params).into_client_request() else {
        return Ended::Over("the Sphere's address isn't one a channel can use".into());
    };
    let Ok(bearer) = format!("Bearer {token}").parse() else {
        return Ended::Again("the token isn't a header value".into());
    };
    request.headers_mut().insert("Authorization", bearer);
    let mut ws = match tokio_tungstenite::connect_async(request).await {
        Ok((ws, _)) => ws,
        Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
            let status = response.status().as_u16();
            // Not accepted yet (a reply in flight) is worth another try; the rest isn't.
            return match status {
                409 | 429 | 500..=599 => Ended::Again(format!("the Sphere answered {status}")),
                _ => Ended::Over(format!("the Sphere refused the channel ({status})")),
            };
        }
        Err(e) => return Ended::Again(format!("the Sphere couldn't be reached: {e}")),
    };
    let mut session: Option<(Sealer, Opener)> = None;
    let mut mine: Option<Hello> = None;
    let mut ping = tokio::time::interval(PING_EVERY);
    let mut heard = tokio::time::Instant::now();
    let mut pings = 0u64;
    loop {
        tokio::select! {
            message = ws.next() => {
                let Some(Ok(message)) = message else {
                    return Ended::Again("the connection dropped".into());
                };
                heard = tokio::time::Instant::now();
                match message {
                    Message::Text(text) => {
                        let said: Value = serde_json::from_str(text.as_str()).unwrap_or_default();
                        if said["peer"] == "joined" {
                            // Every join starts over with new keys (protocol.md section 13).
                            if session.take().is_some() && events.send(Event::Lost("the other side came back".into())).await.is_err() {
                                return Ended::Over("closed".into());
                            }
                            let made = match hello(&params.key, &params.sphere, &params.exchange, &params.me, params.role) {
                                Ok(made) => made,
                                Err(e) => return Ended::Over(e),
                            };
                            if ws.send(Message::Binary(made.bytes.clone().into())).await.is_err() {
                                return Ended::Again("the connection dropped".into());
                            }
                            mine = Some(made);
                        } else if said["peer"] == "left" && session.take().is_some() {
                            mine = None;
                            if events.send(Event::Lost("the other side left".into())).await.is_err() {
                                return Ended::Over("closed".into());
                            }
                        }
                    }
                    Message::Binary(bytes) => {
                        if let Some((_, opener)) = session.as_mut() {
                            let Some(frame) = opener.open(&bytes).ok().and_then(|p| Frame::decode(&p)) else {
                                // Close it: the Sphere tells the other side, and both start over.
                                let _ = ws.close(None).await;
                                return Ended::Again("a frame didn't open".into());
                            };
                            if frame.stream == 0 && frame.kind == Kind::Data {
                                if let Some(n) = frame.value().and_then(|v| v["ping"].as_u64()) {
                                    send_sealed(&mut ws, &mut session, Frame::json(0, Kind::Data, &json!({"pong": n}))).await;
                                    continue;
                                }
                                if frame.value().is_some_and(|v| v.get("pong").is_some()) {
                                    continue;
                                }
                            }
                            if events.send(Event::Frame(frame)).await.is_err() {
                                return Ended::Over("closed".into());
                            }
                        } else if let Some(own) = mine.take() {
                            let Some((key_id, public_key)) = party.peer_key(&params.peer) else {
                                return Ended::Over("the other Obi isn't in the directory".into());
                            };
                            let expect = Expect { sphere: &params.sphere, exchange: &params.exchange, obi: &params.peer,
                                                  role: params.role.other(), key_id: &key_id, public_key: &public_key };
                            let made = check_hello(&bytes, &expect).and_then(|peer| keys(own, params.role, &peer, &bytes));
                            match made {
                                Ok(made) => {
                                    session = Some(made);
                                    if events.send(Event::Ready).await.is_err() {
                                        return Ended::Over("closed".into());
                                    }
                                }
                                Err(why) => {
                                    let _ = ws.close(None).await;
                                    return Ended::Again(why);
                                }
                            }
                        }
                    }
                    Message::Close(frame) => {
                        let code = frame.as_ref().map(|f| u16::from(f.code)).unwrap_or(1005);
                        let reason = frame.map(|f| f.reason.to_string()).unwrap_or_default();
                        return match code {
                            4001 | 4002 => Ended::Over(format!("the Sphere closed the channel: {reason}")),
                            _ => Ended::Again(format!("the Sphere closed the connection ({code})")),
                        };
                    }
                    _ => {}
                }
            }
            frame = out.recv() => {
                let Some(frame) = frame else {
                    let _ = ws.close(Some(tokio_tungstenite::tungstenite::protocol::CloseFrame { code: CloseCode::Normal, reason: "".into() })).await;
                    return Ended::Over("closed".into());
                };
                if session.is_some() && !send_sealed(&mut ws, &mut session, frame).await {
                    return Ended::Again("the connection dropped".into());
                }
            }
            _ = ping.tick() => {
                if heard.elapsed() > SILENCE {
                    return Ended::Again("the other side went silent".into());
                }
                if session.is_some() {
                    pings += 1;
                    if !send_sealed(&mut ws, &mut session, Frame::json(0, Kind::Data, &json!({"ping": pings}))).await {
                        return Ended::Again("the connection dropped".into());
                    }
                }
            }
        }
    }
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn send_sealed(ws: &mut Ws, session: &mut Option<(Sealer, Opener)>, frame: Frame) -> bool {
    let Some((sealer, _)) = session.as_mut() else {
        return true;
    };
    let sealed = sealer.seal(&frame.encode());
    ws.send(Message::Binary(sealed.into())).await.is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (Keypair, Keypair) {
        (
            Keypair::from_seed_string("channel test guest"),
            Keypair::from_seed_string("channel test host"),
        )
    }

    const CID: &str = "8a6c1f4e-5d2b-4c7a-9e3f-1b2c3d4e5f60";

    fn expect<'a>(
        key: &'a Keypair,
        kid: &'a str,
        pk: &'a str,
        obi: &'a str,
        role: Role,
    ) -> Expect<'a> {
        let _ = key;
        Expect {
            sphere: "deskree",
            exchange: CID,
            obi,
            role,
            key_id: kid,
            public_key: pk,
        }
    }

    /// Both sides' keys, after a handshake checked the way each side checks the other's hello.
    fn handshake(g: &Keypair, h: &Keypair) -> (Sealer, Opener, Sealer, Opener) {
        let gh = hello(g, "deskree", CID, "obi-sangam", Role::Guest).unwrap();
        let hh = hello(h, "deskree", CID, "obi-wellington", Role::Host).unwrap();
        let (gkid, gpk, hkid, hpk) = (g.key_id(), g.public_key(), h.key_id(), h.public_key());
        let g_peer = check_hello(
            &hh.bytes,
            &expect(h, &hkid, &hpk, "obi-wellington", Role::Host),
        )
        .unwrap();
        let h_peer = check_hello(
            &gh.bytes,
            &expect(g, &gkid, &gpk, "obi-sangam", Role::Guest),
        )
        .unwrap();
        let (gb, hb) = (gh.bytes.clone(), hh.bytes.clone());
        let (gs, go) = keys(gh, Role::Guest, &g_peer, &hb).unwrap();
        let (hs, ho) = keys(hh, Role::Host, &h_peer, &gb).unwrap();
        (gs, go, hs, ho)
    }

    #[test]
    fn a_handshake_gives_both_sides_matching_keys_and_frames_open_only_in_order() {
        let (g, h) = pair();
        let (mut gs, mut go, mut hs, mut ho) = handshake(&g, &h);
        let a = gs.seal(b"bundle part one");
        let b = gs.seal(b"bundle part one");
        assert_ne!(a, b, "the same bytes seal differently each time");
        assert_eq!(ho.open(&a).unwrap(), b"bundle part one");
        // Replayed: the same frame again doesn't open.
        assert!(ho.open(&a).is_err());
        assert_eq!(go.open(&hs.seal(b"model answer")).unwrap(), b"model answer");

        // Out of order, or changed: neither opens.
        let (mut gs, _, _, mut ho) = handshake(&g, &h);
        let _first = gs.seal(b"one");
        let second = gs.seal(b"two");
        assert!(ho.open(&second).is_err());
        let (mut gs, _, _, mut ho) = handshake(&g, &h);
        let mut changed = gs.seal(b"one");
        changed[0] ^= 1;
        assert!(ho.open(&changed).is_err());
        // Another handshake's keys don't open this one's frames.
        let (mut gs, _, _, _) = handshake(&g, &h);
        let (_, _, _, mut other) = handshake(&g, &h);
        assert!(other.open(&gs.seal(b"one")).is_err());
    }

    #[test]
    fn a_hello_is_refused_unless_it_is_the_other_obis_for_this_exchange() {
        let (g, h) = pair();
        let mallory = Keypair::from_seed_string("channel test mallory");
        let (gkid, gpk) = (g.key_id(), g.public_key());
        let ok =
            |bytes: &[u8]| check_hello(bytes, &expect(&g, &gkid, &gpk, "obi-sangam", Role::Guest));
        assert!(
            ok(&hello(&g, "deskree", CID, "obi-sangam", Role::Guest)
                .unwrap()
                .bytes)
            .is_ok()
        );
        // Another exchange, another Sphere, the wrong role, another Obi's key.
        assert!(
            ok(&hello(
                &g,
                "deskree",
                "9a6c1f4e-5d2b-4c7a-9e3f-1b2c3d4e5f60",
                "obi-sangam",
                Role::Guest
            )
            .unwrap()
            .bytes)
            .is_err()
        );
        assert!(
            ok(&hello(&g, "other", CID, "obi-sangam", Role::Guest)
                .unwrap()
                .bytes)
            .is_err()
        );
        assert!(
            ok(&hello(&g, "deskree", CID, "obi-sangam", Role::Host)
                .unwrap()
                .bytes)
            .is_err()
        );
        assert!(
            ok(&hello(&h, "deskree", CID, "obi-sangam", Role::Guest)
                .unwrap()
                .bytes)
            .is_err()
        );
        // A Sphere that swaps the X25519 key can't sign for the Obi.
        let mut swapped: Value = serde_json::from_slice(
            &hello(&g, "deskree", CID, "obi-sangam", Role::Guest)
                .unwrap()
                .bytes,
        )
        .unwrap();
        swapped["x25519"] = json!(b64url([7u8; 32]));
        assert!(ok(swapped.to_string().as_bytes()).is_err());
        // Signed by Mallory's key while naming the guest's key id.
        let mut forged: Value = serde_json::from_slice(
            &hello(&mallory, "deskree", CID, "obi-sangam", Role::Guest)
                .unwrap()
                .bytes,
        )
        .unwrap();
        forged["key_id"] = json!(gkid);
        forged["signature"] = json!(mallory.sign(&signing_input(&forged).unwrap()));
        assert!(ok(forged.to_string().as_bytes()).is_err());
        // An extra field.
        let mut extra: Value = serde_json::from_slice(
            &hello(&g, "deskree", CID, "obi-sangam", Role::Guest)
                .unwrap()
                .bytes,
        )
        .unwrap();
        extra["note"] = json!("hi");
        assert!(ok(extra.to_string().as_bytes()).is_err());
    }

    #[test]
    fn frames_round_trip() {
        let frame = Frame::json(
            7,
            Kind::Open,
            &json!({"type": "model", "method": "POST", "path": "/v1/messages"}),
        );
        assert_eq!(Frame::decode(&frame.encode()), Some(frame));
        assert_eq!(Frame::decode(&[0, 0, 0, 1, 9]), None);
        assert_eq!(Frame::decode(&[0, 0, 1]), None);
    }

    /// A relay as the Sphere's (sphere-api.md 6.3), for one exchange: pairs the first two
    /// connections by the token's Obi, says `joined`, forwards binary frames, and can drop both.
    mod relay {
        use std::collections::HashMap;
        use std::sync::{Arc, Mutex};

        use axum::extract::State;
        use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
        use axum::http::HeaderMap;
        use axum::response::Response;
        use futures_util::{SinkExt, StreamExt};
        use tokio::sync::mpsc;

        #[derive(Default)]
        pub struct Relay {
            sides: Mutex<HashMap<String, mpsc::UnboundedSender<Message>>>,
            pub frames: Mutex<usize>,
        }

        impl Relay {
            pub fn drop_all(&self) {
                for (_, tx) in self.sides.lock().unwrap().drain() {
                    let _ = tx.send(Message::Close(None));
                }
            }
        }

        pub async fn start() -> (String, Arc<Relay>) {
            let relay = Arc::new(Relay::default());
            let app = axum::Router::new()
                .route(
                    "/v0.1/spheres/{s}/channels/{c}",
                    axum::routing::get(connect),
                )
                .with_state(relay.clone());
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
            (url, relay)
        }

        async fn connect(
            State(relay): State<Arc<Relay>>,
            headers: HeaderMap,
            ws: WebSocketUpgrade,
        ) -> Response {
            let who = headers["authorization"]
                .to_str()
                .unwrap()
                .trim_start_matches("Bearer ")
                .to_owned();
            ws.on_upgrade(move |socket| side(relay, who, socket))
        }

        async fn side(relay: Arc<Relay>, who: String, socket: WebSocket) {
            let (mut sink, mut stream) = socket.split();
            let (tx, mut rx) = mpsc::unbounded_channel();
            let joined = {
                let mut sides = relay.sides.lock().unwrap();
                sides.insert(who.clone(), tx);
                sides.len() == 2
            };
            if joined {
                for tx in relay.sides.lock().unwrap().values() {
                    let _ = tx.send(Message::Text(r#"{"peer":"joined"}"#.into()));
                }
            }
            tokio::spawn(async move {
                while let Some(m) = rx.recv().await {
                    let close = matches!(m, Message::Close(_));
                    if sink.send(m).await.is_err() || close {
                        break;
                    }
                }
            });
            while let Some(Ok(m)) = stream.next().await {
                if let Message::Binary(bytes) = m {
                    *relay.frames.lock().unwrap() += 1;
                    let sides = relay.sides.lock().unwrap();
                    for (other, tx) in sides.iter() {
                        if *other != who {
                            let _ = tx.send(Message::Binary(bytes.clone()));
                        }
                    }
                }
            }
            relay.sides.lock().unwrap().remove(&who);
        }
    }

    struct TestParty {
        token: String,
        peer: (String, String),
    }

    impl Party for TestParty {
        fn token(&self) -> Pin<Box<dyn Future<Output = Result<String, String>> + Send + '_>> {
            Box::pin(async move { Ok(self.token.clone()) })
        }
        fn peer_key(&self, _obi: &str) -> Option<(String, String)> {
            Some(self.peer.clone())
        }
    }

    async fn next(events: &mut mpsc::Receiver<Event>) -> Event {
        tokio::time::timeout(Duration::from_secs(10), events.recv())
            .await
            .expect("an event in time")
            .expect("the channel is open")
    }

    #[tokio::test]
    async fn two_sides_handshake_through_a_relay_carry_frames_and_start_over_after_a_drop() {
        let (base, relay) = relay::start().await;
        let (g, h) = pair();
        let params = |me: &str, peer: &str, role, key: &Keypair| Params {
            base: base.clone(),
            sphere: "deskree".into(),
            exchange: CID.into(),
            me: me.into(),
            peer: peer.into(),
            role,
            key: Arc::new(Keypair::from_seed(&key.seed())),
        };
        let (guest, mut gev) = open(
            params("obi-sangam", "obi-wellington", Role::Guest, &g),
            Arc::new(TestParty {
                token: "guest".into(),
                peer: (h.key_id(), h.public_key()),
            }),
        );
        let (host, mut hev) = open(
            params("obi-wellington", "obi-sangam", Role::Host, &h),
            Arc::new(TestParty {
                token: "host".into(),
                peer: (g.key_id(), g.public_key()),
            }),
        );
        assert!(matches!(next(&mut gev).await, Event::Ready));
        assert!(matches!(next(&mut hev).await, Event::Ready));

        // A bundle of 200 KiB in chunks, and a model call the other way.
        let bundle: Vec<u8> = (0..200 * 1024).map(|i| (i % 251) as u8).collect();
        assert!(
            guest
                .send(Frame::json(2, Kind::Open, &json!({"type": "bundle"})))
                .await
        );
        assert!(guest.send_data(2, &bundle).await);
        assert!(guest.send(Frame::new(2, Kind::End, Vec::new())).await);
        assert!(
            host.send(Frame::json(
                1,
                Kind::Open,
                &json!({"type": "model", "path": "/v1/messages"})
            ))
            .await
        );
        let mut got = Vec::new();
        loop {
            match next(&mut hev).await {
                Event::Frame(f) if f.kind == Kind::Data => got.extend_from_slice(&f.payload),
                Event::Frame(f) if f.kind == Kind::End => break,
                Event::Frame(f) => assert_eq!(f.value().unwrap()["type"], "bundle"),
                other => panic!("{other:?}"),
            }
        }
        assert_eq!(got, bundle);
        match next(&mut gev).await {
            Event::Frame(f) => assert_eq!(f.value().unwrap()["path"], "/v1/messages"),
            other => panic!("{other:?}"),
        }
        // What the relay saw was sealed: no frame of the bundle in the clear.
        assert!(*relay.frames.lock().unwrap() >= 6);

        // The relay drops both: each side says it lost the channel, connects again, and is ready.
        relay.drop_all();
        assert!(matches!(next(&mut gev).await, Event::Lost(_)));
        assert!(matches!(next(&mut hev).await, Event::Lost(_)));
        assert!(matches!(next(&mut gev).await, Event::Ready));
        assert!(matches!(next(&mut hev).await, Event::Ready));
        assert!(
            host.send(Frame::new(1, Kind::Data, b"after".to_vec()))
                .await
        );
        match next(&mut gev).await {
            Event::Frame(f) => assert_eq!(f.payload, b"after"),
            other => panic!("{other:?}"),
        }
        guest.close().await;
        assert!(matches!(next(&mut gev).await, Event::Closed(_)));
    }
}
