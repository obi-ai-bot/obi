//! The gateway (#446; docs/runner-api.md, "LAN gateway (#284)"), ported from Runner/Gateway.swift,
//! Runner/Pairing.swift, Runner/Routes.swift and the gateway tokens of Runner/Devices.swift: the
//! one way a paired phone reaches obid. It listens on its own address (`gateway` in the
//! configuration), redeems pairing invitations for device tokens, and forwards the routes a phone
//! uses (and only those) to obid's own API with the API token, which never leaves obid. Answers
//! come back through the API's own layers (the vault's secrets are already out), with an agent's
//! session id and the accounts' homes taken out too.
//!
//! Invitations are made, and paired devices listed and revoked, on the loopback API with the API
//! token (`/v1/pairing/invite`, `/v1/pairing/devices`): a phone that reaches the gateway can
//! redeem an invitation, never mint one.
//!
//! ponytail: the gateway binds 127.0.0.1 and `tailscale serve` puts it on the owner's tailnet.
//! The Swift gateway's LAN listener and Bonjour come back when pairing on the home network needs them.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::{Request, State};
use axum::http::{HeaderValue, Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use base64::Engine as _;
use futures_util::StreamExt as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tower::ServiceExt as _;

use crate::api::Shared;

/// How long an invitation can be redeemed (Pairing.swift: 120 seconds).
const INVITATION: Duration = Duration::from_secs(120);
/// Wrong credentials an invitation takes before it is gone.
const ATTEMPTS: u32 = 5;
/// How long a device token works (Devices.swift, `GatewayToken.lifetime`).
const LIFETIME: Duration = Duration::from_secs(30 * 24 * 60 * 60);
/// The largest request a phone may send through.
const BODY: usize = 4 << 20;
/// What stands for an account's home in an answer.
const HOME: &str = "[home]";

/// The routes a phone may use through the gateway (Runner/Routes.swift), apart from the API's own
/// router: adding an endpoint never makes it reachable from a phone by itself. Kept off on purpose:
/// `/v1/checks/…` and `/v1/agent/…` (the Mac's and agents' own calls), `/v1/connections…`,
/// `/v1/speech`, `PUT /v1/settings/jobs`, `/v1/pairing/…`, `/v1/obid/…` and everything else.
const ROUTES: &[(&str, &str)] = &[
    ("GET", "/v1/status"),
    ("GET", "/v1/events"),
    ("GET", "/v1/conversation"),
    ("GET", "/v1/conversations"),
    ("PATCH", "/v1/conversations/*"),
    ("DELETE", "/v1/conversations/*"),
    ("POST", "/v1/conversation/stop"),
    ("POST", "/v1/plans"),
    ("POST", "/v1/plans/cancel"),
    ("GET", "/v1/jobs"),
    ("POST", "/v1/jobs"),
    ("GET", "/v1/jobs/*"),
    ("GET", "/v1/jobs/*/wait"),
    ("GET", "/v1/jobs/*/report"),
    ("POST", "/v1/jobs/*/stop"),
    ("POST", "/v1/stop-all"),
    ("POST", "/v1/jobs/*/dismiss"),
    ("POST", "/v1/jobs/*/move"),
    ("POST", "/v1/jobs/*/start"),
    ("POST", "/v1/jobs/*/start-when"),
    ("POST", "/v1/jobs/*/mode"),
    ("POST", "/v1/jobs/*/permission"),
    ("POST", "/v1/jobs/*/messages"),
    ("GET", "/v1/jobs/*/publish"),
    ("POST", "/v1/jobs/*/publish"),
    ("POST", "/v1/clear"),
    ("GET", "/v1/inbox"),
    ("POST", "/v1/inbox/*/answer"),
    ("GET", "/v1/failures"),
    ("GET", "/v1/failures/*"),
    ("POST", "/v1/failures/*/fix"),
    ("POST", "/v1/accounts/*/reserve"),
    ("GET", "/v1/settings/models"),
    ("PUT", "/v1/settings/models"),
    ("GET", "/v1/settings/models/options"),
    ("GET", "/v1/settings/jobs"),
    ("GET", "/v1/settings/permissions"),
    ("PUT", "/v1/settings/permissions"),
    ("GET", "/v1/permissions/rules"),
    ("DELETE", "/v1/permissions/rules/*"),
    ("POST", "/v1/devices"),
    ("POST", "/v1/activities"),
    ("POST", "/v1/notifications"),
    ("GET", "/v1/watches"),
    ("POST", "/v1/watches"),
    ("DELETE", "/v1/watches/*"),
];

/// Whether a phone may `method` `path` through the gateway: `*` is one path segment.
pub fn allows(method: &Method, path: &str) -> bool {
    let actual: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    ROUTES.iter().any(|(m, pattern)| {
        let expected: Vec<&str> = pattern.split('/').filter(|s| !s.is_empty()).collect();
        *m == method.as_str()
            && expected.len() == actual.len()
            && expected
                .iter()
                .zip(&actual)
                .all(|(e, a)| *e == "*" || e == a)
    })
}

/// The open invitation: digests only, never the secret or the code.
struct Pending {
    secret: String,
    code: String,
    expires: SystemTime,
    attempts: u32,
    name: String,
    hostname: String,
}

/// A paired device, kept in `home/gateway-devices.json` under its token's digest.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Device {
    id: String,
    name: String,
    created: i64,
    expires_at: i64,
}

/// What `POST /v1/pairing/invite` answers: the QR code's parts and the six digits.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Invitation {
    pub url: String,
    pub name: String,
    pub hostname: String,
    /// `{"hostname":…,"name":…}`, as the QR code carries it.
    pub link: String,
    pub secret: String,
    pub code: String,
    pub expires_at: String,
}

/// What redeeming buys: the device token, shown once, and the Mac's link.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Redeemed {
    pub token: String,
    #[serde(rename = "deviceID")]
    pub device_id: String,
    pub expires_at: String,
    pub link: Value,
}

pub struct Gateway {
    file: PathBuf,
    devices: Mutex<HashMap<String, Device>>,
    pending: Mutex<Option<Pending>>,
}

fn digest(value: &str) -> String {
    hex::encode(obi_protocol::keys::sha256(value.as_bytes()))
}

fn random(bytes: usize) -> String {
    let mut buffer = vec![0u8; bytes];
    getrandom::fill(&mut buffer).expect("the system's random source works");
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(buffer)
}

fn seconds(at: SystemTime) -> i64 {
    at.duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

impl Gateway {
    /// The devices paired before, from `home/gateway-devices.json`. A file that doesn't read
    /// counts as none: every phone pairs again.
    pub fn open(home: &Path) -> Gateway {
        let file = home.join("gateway-devices.json");
        let devices = std::fs::read(&file)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Gateway {
            file,
            devices: Mutex::new(devices),
            pending: Mutex::new(None),
        }
    }

    /// A new invitation, replacing the one before.
    pub fn invite(&self, url: &str, name: &str, hostname: &str, now: SystemTime) -> Invitation {
        let secret = random(32);
        let code = {
            let mut bytes = [0u8; 4];
            getrandom::fill(&mut bytes).expect("the system's random source works");
            format!("{:06}", u32::from_le_bytes(bytes) % 1_000_000)
        };
        let expires = now + INVITATION;
        *self.pending.lock().unwrap_or_else(|e| e.into_inner()) = Some(Pending {
            secret: digest(&secret),
            code: digest(&code),
            expires,
            attempts: 0,
            name: name.to_owned(),
            hostname: hostname.to_owned(),
        });
        Invitation {
            url: url.to_owned(),
            name: name.to_owned(),
            hostname: hostname.to_owned(),
            link: json!({"hostname": hostname, "name": name}).to_string(),
            secret,
            code,
            expires_at: obi_protocol::time::format(seconds(expires)),
        }
    }

    /// Redeems the open invitation with its secret or its code, once: `410` when there's none or
    /// it expired, `401` for a wrong credential (the fifth uses it up).
    pub fn redeem(
        &self,
        credential: &str,
        name: &str,
        now: SystemTime,
    ) -> Result<Redeemed, (StatusCode, &'static str)> {
        const GONE: &str = "That pairing invitation has expired or was already used.";
        let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        let Some(open) = pending.as_mut() else {
            return Err((StatusCode::GONE, GONE));
        };
        if now > open.expires {
            *pending = None;
            return Err((StatusCode::GONE, GONE));
        }
        let given = digest(credential);
        if !crate::token::same(&given, &open.secret) && !crate::token::same(&given, &open.code) {
            open.attempts += 1;
            if open.attempts >= ATTEMPTS {
                *pending = None;
            }
            return Err((StatusCode::UNAUTHORIZED, "That pairing code is not valid."));
        }
        let open = pending.take().expect("checked above");
        drop(pending);
        let token = random(64);
        let device = Device {
            id: uuid::Uuid::new_v4().to_string(),
            // No control characters: the name goes in obid's log.
            name: name.chars().filter(|c| !c.is_control()).take(100).collect(),
            created: seconds(now),
            expires_at: seconds(now + LIFETIME),
        };
        let mut devices = self.devices.lock().unwrap_or_else(|e| e.into_inner());
        devices.insert(digest(&token), device.clone());
        if self.save(&devices).is_err() {
            devices.remove(&digest(&token));
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                "obid couldn't keep the paired device.",
            ));
        }
        tracing::info!("paired device {}: {}", device.id, device.name);
        Ok(Redeemed {
            token,
            device_id: device.id,
            expires_at: obi_protocol::time::format(device.expires_at),
            link: json!({"name": open.name, "hostname": open.hostname}),
        })
    }

    /// Whether `token` is a paired device's, and still works.
    pub fn accepts(&self, token: &str, now: SystemTime) -> bool {
        let devices = self.devices.lock().unwrap_or_else(|e| e.into_inner());
        devices
            .get(&digest(token))
            .is_some_and(|d| d.expires_at > seconds(now))
    }

    /// The paired devices, oldest first: never a token or its digest.
    pub fn list(&self) -> Value {
        let devices = self.devices.lock().unwrap_or_else(|e| e.into_inner());
        let mut listed: Vec<&Device> = devices.values().collect();
        listed.sort_by_key(|d| d.created);
        listed
            .into_iter()
            .map(|d| {
                json!({"id": d.id, "name": d.name,
                       "created": obi_protocol::time::format(d.created),
                       "expiresAt": obi_protocol::time::format(d.expires_at)})
            })
            .collect()
    }

    /// Forgets the device `id`: false when there's none.
    pub fn revoke(&self, id: &str) -> Result<bool, std::io::Error> {
        let mut devices = self.devices.lock().unwrap_or_else(|e| e.into_inner());
        let before = devices.len();
        devices.retain(|_, d| d.id != id);
        if devices.len() == before {
            return Ok(false);
        }
        self.save(&devices)?;
        Ok(true)
    }

    fn save(&self, devices: &HashMap<String, Device>) -> Result<(), std::io::Error> {
        let bytes = serde_json::to_vec_pretty(devices).map_err(std::io::Error::other)?;
        crate::store::write_private(&self.file, &bytes)
    }
}

fn error(status: StatusCode, message: &str) -> Response {
    (status, axum::Json(json!({"error": message}))).into_response()
}

// ---------------------------------------------------------------------------------------------
// The loopback API's pairing endpoints, behind the API token

#[derive(Deserialize)]
pub struct InviteRequest {
    url: String,
    name: Option<String>,
    hostname: Option<String>,
}

/// `POST /v1/pairing/invite`.
pub async fn invite(
    State(shared): State<Arc<Shared>>,
    axum::Json(request): axum::Json<InviteRequest>,
) -> Response {
    let Some((scheme, rest)) = request.url.split_once("://") else {
        return error(StatusCode::BAD_REQUEST, "url must be an HTTP or HTTPS URL.");
    };
    let authority = rest.split('/').next().unwrap_or("");
    if !matches!(scheme, "http" | "https") || authority.is_empty() {
        return error(StatusCode::BAD_REQUEST, "url must be an HTTP or HTTPS URL.");
    }
    let name = request.name.unwrap_or_else(|| shared.host.clone());
    let hostname = request.hostname.unwrap_or_else(|| authority.to_owned());
    let invitation = shared
        .gateway
        .invite(&request.url, &name, &hostname, SystemTime::now());
    axum::Json(invitation).into_response()
}

/// `GET /v1/pairing/devices`.
pub async fn devices(State(shared): State<Arc<Shared>>) -> Response {
    axum::Json(shared.gateway.list()).into_response()
}

/// `DELETE /v1/pairing/devices/{id}`.
pub async fn revoke(
    State(shared): State<Arc<Shared>>,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Response {
    match shared.gateway.revoke(&id) {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => error(StatusCode::NOT_FOUND, "That paired device was not found."),
        Err(_) => error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "obid couldn't forget the paired device.",
        ),
    }
}

// ---------------------------------------------------------------------------------------------
// The gateway's own listener

#[derive(Clone)]
struct Through {
    shared: Arc<Shared>,
    api: Router,
}

/// The gateway's router: redeeming, and every allowed route forwarded to `api`.
pub fn router(shared: Arc<Shared>, api: Router) -> Router {
    Router::new()
        .route("/v1/pairing", post(redeem))
        .fallback(forward)
        .with_state(Through { shared, api })
}

#[derive(Deserialize)]
struct RedeemRequest {
    credential: String,
    name: Option<String>,
}

/// `POST /v1/pairing`, on the gateway only. Only a phone redeems: a browser says its `Origin`,
/// and a page can't send JSON across origins without asking first, so neither a page the owner
/// opens nor a rebound name can use an invitation up.
async fn redeem(State(through): State<Through>, request: Request) -> Response {
    if request.headers().contains_key(header::ORIGIN) {
        return error(StatusCode::FORBIDDEN, "Only a phone pairs with obid.");
    }
    let json = request
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.to_ascii_lowercase().starts_with("application/json"));
    if !json {
        return error(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "Pairing takes JSON (Content-Type: application/json).",
        );
    }
    let Ok(bytes) = axum::body::to_bytes(request.into_body(), 64 * 1024).await else {
        return error(StatusCode::PAYLOAD_TOO_LARGE, "That request is too large.");
    };
    let Ok(asked) = serde_json::from_slice::<RedeemRequest>(&bytes) else {
        return error(
            StatusCode::BAD_REQUEST,
            "Pairing takes {\"credential\": …, \"name\": …}.",
        );
    };
    let name = asked.name.unwrap_or_else(|| "iPhone".into());
    match through
        .shared
        .gateway
        .redeem(&asked.credential, &name, SystemTime::now())
    {
        Ok(redeemed) => axum::Json(redeemed).into_response(),
        Err((status, message)) => error(status, message),
    }
}

/// Every other request: an allowed route with a paired device's token goes to the API, as obid's
/// own loopback call with the API token. Nothing else the phone sent goes with it but its body and
/// its content type.
async fn forward(State(through): State<Through>, request: Request) -> Response {
    let (parts, body) = request.into_parts();
    if !allows(&parts.method, parts.uri.path()) {
        return error(
            StatusCode::NOT_FOUND,
            "That route isn't available through the gateway.",
        );
    }
    let mut values = parts.headers.get_all(header::AUTHORIZATION).iter();
    let token = match (values.next(), values.next()) {
        (Some(value), None) => value
            .to_str()
            .ok()
            .and_then(|v| v.strip_prefix("Bearer "))
            .map(str::trim),
        _ => None,
    };
    if !token.is_some_and(|t| through.shared.gateway.accepts(t, SystemTime::now())) {
        return error(
            StatusCode::UNAUTHORIZED,
            "Every gateway request needs a device token.",
        );
    }
    let Ok(body) = axum::body::to_bytes(body, BODY).await else {
        return error(StatusCode::PAYLOAD_TOO_LARGE, "That request is too large.");
    };
    let target = parts
        .uri
        .path_and_query()
        .map_or(parts.uri.path(), |p| p.as_str())
        .to_owned();
    let mut upstream = Request::builder()
        .method(parts.method)
        .uri(target)
        .header(header::HOST, "127.0.0.1")
        .header(
            header::AUTHORIZATION,
            format!("Bearer {}", through.shared.token),
        );
    if let Some(kind) = parts.headers.get(header::CONTENT_TYPE) {
        upstream = upstream.header(header::CONTENT_TYPE, kind);
    }
    let Ok(upstream) = upstream.body(Body::from(body)) else {
        return error(StatusCode::BAD_REQUEST, "That request can't be forwarded.");
    };
    let response = match through.api.oneshot(upstream).await {
        Ok(response) => response,
        Err(never) => match never {},
    };
    let scrubber = Scrubber {
        homes: homes(&through.shared.config),
    };
    scrubbed(response, scrubber).await
}

/// The accounts' own folders, which never leave in an answer.
fn homes(config: &crate::config::Config) -> Vec<String> {
    [
        &config.agents.claude,
        &config.agents.codex,
        &config.agents.cursor,
    ]
    .into_iter()
    .flatten()
    .flat_map(|agent| &agent.accounts)
    .filter_map(|account| account.config_dir.as_ref())
    .map(|dir| dir.to_string_lossy().into_owned())
    .filter(|dir| !dir.is_empty())
    .collect()
}

/// The API's answer, with its status and content type only, scrubbed: whole when it has a known
/// length, chunk by chunk for an event stream (obid writes each event in one chunk, as
/// crate::vault::answers relies on too).
async fn scrubbed(response: Response, scrubber: Scrubber) -> Response {
    let (parts, body) = response.into_parts();
    let kind = parts.headers.get(header::CONTENT_TYPE).cloned();
    let events = kind
        .as_ref()
        .and_then(|k| k.to_str().ok())
        .is_some_and(|k| k.to_ascii_lowercase().starts_with("text/event-stream"));
    let mut out = if events {
        let frames = body.into_data_stream().map(move |chunk| {
            chunk.map(|bytes| Bytes::from(scrubber.frame(&String::from_utf8_lossy(&bytes))))
        });
        Response::new(Body::from_stream(frames))
    } else {
        let Ok(bytes) = axum::body::to_bytes(body, usize::MAX).await else {
            return error(
                StatusCode::BAD_GATEWAY,
                "The gateway got no whole answer from obid.",
            );
        };
        Response::new(Body::from(
            scrubber.document(&String::from_utf8_lossy(&bytes)),
        ))
    };
    *out.status_mut() = parts.status;
    let headers = out.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        kind.unwrap_or(HeaderValue::from_static("application/json")),
    );
    if let Some(cache) = parts.headers.get(header::CACHE_CONTROL) {
        headers.insert(header::CACHE_CONTROL, cache.clone());
    }
    out
}

/// What never leaves in a gateway answer besides the vault's secrets (already out): an agent's
/// session id (a job's `session`, which resumes the agent's own conversation), as null, and the
/// accounts' homes, as `[home]` (Runner/Gateway.swift, `GatewayScrubber`).
struct Scrubber {
    homes: Vec<String>,
}

impl Scrubber {
    fn document(&self, text: &str) -> String {
        self.without_homes(&self.json(text))
    }

    /// One event-stream frame: each `data:` line's JSON as a document.
    fn frame(&self, text: &str) -> String {
        let lines: Vec<String> = text
            .split('\n')
            .map(|line| match line.strip_prefix("data:") {
                Some(data) => format!("data: {}", self.json(data.trim_start_matches(' '))),
                None => line.to_owned(),
            })
            .collect();
        self.without_homes(&lines.join("\n"))
    }

    /// `text` as JSON with `session` null and the homes out of every string, or as it came when
    /// it isn't JSON or nothing in it changes.
    fn json(&self, text: &str) -> String {
        let Ok(mut value) = serde_json::from_str::<Value>(text) else {
            return text.to_owned();
        };
        if self.scrub(&mut value) {
            value.to_string()
        } else {
            text.to_owned()
        }
    }

    fn scrub(&self, value: &mut Value) -> bool {
        match value {
            Value::Object(fields) => {
                let mut changed = false;
                for (key, field) in fields.iter_mut() {
                    if key == "session" && !field.is_null() {
                        *field = Value::Null;
                        changed = true;
                    } else {
                        changed |= self.scrub(field);
                    }
                }
                changed
            }
            Value::Array(items) => items
                .iter_mut()
                .fold(false, |changed, item| self.scrub(item) | changed),
            Value::String(text) => {
                let clean = self.without_homes(text);
                let changed = clean != *text;
                *text = clean;
                changed
            }
            _ => false,
        }
    }

    fn without_homes(&self, text: &str) -> String {
        self.homes.iter().fold(text.to_owned(), |text, home| {
            text.replace(home.as_str(), HOME)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("obid-gateway-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    /// Ports GatewayTests.gatewayRoutesDefaultToDeny: only the listed routes, by method and
    /// segment count.
    #[test]
    fn the_gateway_allows_only_the_listed_routes() {
        assert!(allows(&Method::GET, "/v1/status"));
        assert!(allows(&Method::GET, "/v1/jobs/abc"));
        assert!(allows(&Method::POST, "/v1/jobs/abc/messages"));
        assert!(!allows(&Method::DELETE, "/v1/jobs/abc"));
        assert!(!allows(&Method::GET, "/v1/jobs/abc/def/wait"));
        for (method, path) in [
            (Method::GET, "/v1/connections"),
            (Method::POST, "/v1/pairing/invite"),
            (Method::GET, "/v1/pairing/devices"),
            (Method::DELETE, "/v1/pairing/devices/abc"),
            (Method::PUT, "/v1/settings/jobs"),
            (Method::GET, "/v1/checks/next"),
            (Method::POST, "/v1/agent/mcp/abc"),
            (Method::GET, "/v1/obid/plugins"),
            (Method::GET, "/app/"),
        ] {
            assert!(!allows(&method, path), "{method} {path}");
        }
    }

    /// Ports GatewayTests.pairingSecretAndCodeWorkOnceAndExpire.
    #[test]
    fn an_invitation_works_once_by_its_secret_or_its_code_and_expires() {
        let home = folder("once");
        let gateway = Gateway::open(&home);
        let now = SystemTime::now();
        let invitation = gateway.invite("https://mac.example", "Mac", "mac.example", now);
        assert_eq!(invitation.code.len(), 6);
        assert!(invitation.secret.len() >= 32);
        let redeemed = gateway.redeem(&invitation.secret, "Phone", now).unwrap();
        assert!(gateway.accepts(&redeemed.token, now));
        assert_eq!(
            gateway
                .redeem(&invitation.code, "Phone", now)
                .unwrap_err()
                .0,
            StatusCode::GONE
        );
        let invitation = gateway.invite("https://mac.example", "Mac", "mac.example", now);
        let later = now + INVITATION + Duration::from_secs(1);
        assert_eq!(
            gateway
                .redeem(&invitation.code, "Phone", later)
                .unwrap_err()
                .0,
            StatusCode::GONE
        );
        // A token stops working at the end of its life.
        assert!(!gateway.accepts(&redeemed.token, now + LIFETIME + Duration::from_secs(1)));
        // Only its digest is kept.
        let kept = std::fs::read_to_string(home.join("gateway-devices.json")).unwrap();
        assert!(!kept.contains(&redeemed.token));
        let _ = std::fs::remove_dir_all(home);
    }

    /// Ports GatewayTests.wrongPairingCredentialsExhaustTheInvitation.
    #[test]
    fn five_wrong_credentials_use_the_invitation_up() {
        let home = folder("wrong");
        let gateway = Gateway::open(&home);
        let now = SystemTime::now();
        let invitation = gateway.invite("https://mac.example", "Mac", "mac.example", now);
        for _ in 0..ATTEMPTS {
            assert_eq!(
                gateway.redeem("not it", "Phone", now).unwrap_err().0,
                StatusCode::UNAUTHORIZED
            );
        }
        assert_eq!(
            gateway
                .redeem(&invitation.code, "Phone", now)
                .unwrap_err()
                .0,
            StatusCode::GONE
        );
        let _ = std::fs::remove_dir_all(home);
    }

    /// Ports GatewayTests.gatewayTokenNamesPersistAndTokensCanBeRevoked.
    #[test]
    fn paired_devices_last_across_restarts_and_can_be_revoked() {
        let home = folder("revoke");
        let now = SystemTime::now();
        let token = {
            let gateway = Gateway::open(&home);
            let invitation = gateway.invite("https://mac.example", "Mac", "mac.example", now);
            gateway
                .redeem(&invitation.code, "Alice's iPhone", now)
                .unwrap()
                .token
        };
        let gateway = Gateway::open(&home);
        assert!(gateway.accepts(&token, now));
        let listed = gateway.list();
        assert_eq!(listed[0]["name"], "Alice's iPhone");
        let id = listed[0]["id"].as_str().unwrap().to_owned();
        assert!(gateway.revoke(&id).unwrap());
        assert!(!gateway.revoke(&id).unwrap());
        assert!(!Gateway::open(&home).accepts(&token, now));
        let _ = std::fs::remove_dir_all(home);
    }

    /// Ports GatewayTests.gatewayScrubsSessionIDsAndAccountHomes, with its own answers.
    #[test]
    fn answers_lose_session_ids_and_account_homes() {
        let home = "/Users/alice/Library/Application Support/Oby/accounts/work";
        let session = "e6a24229-1bd5-48c4-85c5-43b33d433775";
        let job = format!(
            r#"{{"id":"j1","session":"{session}","step":"Signed in at {home}/.codex","account":{{"id":"work","home":"{home}"}}}}"#
        );
        let scrubber = Scrubber {
            homes: vec![home.into()],
        };
        let body = scrubber.document(&format!("[{job}]"));
        assert!(!body.contains(session) && !body.contains(home), "{body}");
        let jobs: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(jobs[0]["id"], "j1");
        assert!(jobs[0]["session"].is_null());
        assert_eq!(jobs[0]["step"], "Signed in at [home]/.codex");
        assert_eq!(jobs[0]["account"]["home"], "[home]");

        let frames = scrubber.frame(&format!(
            "event: job\ndata: {job}\n\nevent: step\ndata: \"in {home}\"\n\n"
        ));
        assert!(
            !frames.contains(session) && !frames.contains(home),
            "{frames}"
        );
        assert!(frames.starts_with("event: job\ndata: {"), "{frames}");
        assert!(frames.contains("data: \"in [home]\""), "{frames}");

        // A clean answer goes as it came, byte for byte.
        let clean = r#"{"b": 1,  "a": "x"}"#;
        assert_eq!(scrubber.document(clean), clean);
    }
}
