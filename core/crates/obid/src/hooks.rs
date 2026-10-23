//! Webhooks into obid (#1128; docs/runner-api.md, "obid only: webhooks"): outside systems post to
//! a hook's address on Oby's control plane, which passes each delivery through the Mac's tunnel to
//! the gateway's `POST /v1/hooks/{id}/deliver`. obid makes every check itself, whatever the Worker
//! did: the hook, the size, the rate, the sender's signature with the secret only obid holds
//! (in the vault as `oby.hook.<name>`), and a body seen in the last 24 hours. A delivery is data
//! from the moment it arrives; what it becomes (an offer, a read) is its source's handler's, and
//! nothing here reads the body but the signature check. The registry's routes are loopback only.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use axum::extract::{Path as UrlPath, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get};
use axum::{Json, Router};
use obi_protocol::time;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::{ApiError, Shared};

/// The biggest delivery read; a bigger one is refused before it is read whole.
pub const BODY_MAX: usize = 1024 * 1024;
/// At most this many deliveries a minute to one hook.
const PER_MINUTE: usize = 120;
/// How long a body's digest is kept, so the same delivery again is a duplicate.
const DUPLICATE_SECONDS: i64 = 24 * 3600;
/// The sources a hook may have, each with how it proves itself.
pub const SOURCES: &[&str] = &["github", "generic"];

/// What the last delivery to a hook came to.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Delivery {
    pub at: String,
    /// `accepted`, `duplicate`, `bad signature`, `too large` or `too many`.
    pub result: String,
}

/// A hook, as `home/hooks.json` (0600) keeps it: never its secret, which is in the vault.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hook {
    pub id: String,
    pub name: String,
    pub source: String,
    pub repo: Option<String>,
    pub url: String,
    pub created_at: String,
    pub last_delivery: Option<Delivery>,
}

/// Per hook: the digests of bodies accepted lately, and when.
type Digests = HashMap<String, Vec<([u8; 32], i64)>>;

/// A hook to keep, as `POST /v1/hooks` gives it.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NewHook {
    pub id: String,
    pub url: String,
    pub name: String,
    pub source: String,
    pub secret: String,
    pub repo: Option<String>,
}

pub struct Hooks {
    file: PathBuf,
    hooks: Mutex<Vec<Hook>>,
    vault: Arc<crate::vault::Vault>,
    events: crate::events::Events,
    /// Per hook: the digests of bodies accepted in the last 24 hours, and when.
    seen: Mutex<Digests>,
    /// Per hook: when its deliveries of the last minute came.
    rate: Mutex<HashMap<String, Vec<i64>>>,
}

/// The vault's name for a hook's secret.
fn secret_name(name: &str) -> String {
    format!("oby.hook.{name}")
}

/// A hook's name: 1 to 32 lower-case letters, digits and `-`.
fn is_name(text: &str) -> bool {
    (1..=32).contains(&text.len())
        && text
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// A hook's id as the control plane makes them: 32 lower-case letters and digits.
fn is_id(text: &str) -> bool {
    text.len() == 32
        && text
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

/// Whether `signature` (`sha256=<hex>`) is the HMAC-SHA256 of `body` with `secret`, compared in
/// constant time.
fn signed(secret: &str, body: &[u8], signature: Option<&str>) -> bool {
    let Some(tag) = signature
        .and_then(|s| s.trim().strip_prefix("sha256="))
        .and_then(|hex| hex::decode(hex).ok())
    else {
        return false;
    };
    let key = aws_lc_rs::hmac::Key::new(aws_lc_rs::hmac::HMAC_SHA256, secret.as_bytes());
    aws_lc_rs::hmac::verify(&key, body, &tag).is_ok()
}

impl Hooks {
    pub fn open(
        home: &std::path::Path,
        vault: Arc<crate::vault::Vault>,
        events: crate::events::Events,
    ) -> Arc<Hooks> {
        let file = home.join("hooks.json");
        let hooks = std::fs::read(&file)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Arc::new(Hooks {
            file,
            hooks: Mutex::new(hooks),
            vault,
            events,
            seen: Mutex::default(),
            rate: Mutex::default(),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Hook>> {
        self.hooks.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn list(&self) -> Vec<Hook> {
        self.lock().clone()
    }

    pub fn get(&self, id: &str) -> Option<Hook> {
        self.lock().iter().find(|h| h.id == id).cloned()
    }

    fn save(&self, hooks: &[Hook]) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(hooks).map_err(|e| e.to_string())?;
        crate::store::write_private(&self.file, &bytes)
            .map_err(|e| format!("obid couldn't keep its hooks: {e}"))?;
        self.events.send("hooks", json!(hooks));
        Ok(())
    }

    /// Keeps a hook the Mac made at the control plane (`id`, `url`), with its secret in the vault.
    pub fn add(&self, new: &NewHook, repos: &[String]) -> Result<Hook, ApiError> {
        let (id, url, name, source) = (
            new.id.as_str(),
            new.url.as_str(),
            new.name.as_str(),
            new.source.as_str(),
        );
        let (secret, repo) = (new.secret.as_str(), new.repo.as_deref());
        let bad = |text: String| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, text);
        if !is_id(id) {
            return Err(bad(
                "id is the control plane's: 32 lower-case letters and digits.".into(),
            ));
        }
        let shaped = url.starts_with("https://")
            && url.ends_with(&format!("/h/{id}"))
            && !url.chars().any(|c| c.is_whitespace() || c.is_control());
        if !shaped {
            return Err(bad(format!("url is the control plane's https://…/h/{id}.")));
        }
        if !is_name(name) {
            return Err(bad(
                "name is up to 32 lower-case letters, digits or dashes.".into(),
            ));
        }
        if !SOURCES.contains(&source) {
            return Err(bad(format!("source is one of {}.", SOURCES.join(", "))));
        }
        let printable = secret.chars().all(|c| c.is_ascii_graphic());
        if !(32..=512).contains(&secret.len()) || !printable {
            return Err(bad("secret is 32 to 512 printable characters.".into()));
        }
        if let Some(problem) = crate::vault::value_problem(secret) {
            return Err(bad(problem));
        }
        if let Some(repo) = repo
            && !repos.iter().any(|r| r == repo)
        {
            return Err(bad(format!(
                "obid doesn't work in {repo}: pick one of its repositories."
            )));
        }
        let mut hooks = self.lock();
        if hooks.iter().any(|h| h.name == name || h.id == id) {
            return Err(ApiError::new(
                StatusCode::CONFLICT,
                format!("There's a hook named {name} already."),
            ));
        }
        self.vault.add(secret, &secret_name(name)).map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("obid couldn't keep the hook's secret: {e}"),
            )
        })?;
        let hook = Hook {
            id: id.into(),
            name: name.into(),
            source: source.into(),
            repo: repo.map(str::to_owned),
            url: url.into(),
            created_at: time::format(time::now()),
            last_delivery: None,
        };
        let mut next = hooks.clone();
        next.push(hook.clone());
        if let Err(why) = self.save(&next) {
            let _ = self.vault.remove(&secret_name(name));
            return Err(ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, why));
        }
        *hooks = next;
        Ok(hook)
    }

    /// Forgets a hook and its secret. False when there's no such hook.
    pub fn remove(&self, id: &str) -> Result<bool, String> {
        let mut hooks = self.lock();
        let Some(hook) = hooks.iter().find(|h| h.id == id).cloned() else {
            return Ok(false);
        };
        let next: Vec<Hook> = hooks.iter().filter(|h| h.id != id).cloned().collect();
        self.save(&next)?;
        *hooks = next;
        if let Err(e) = self.vault.remove(&secret_name(&hook.name)) {
            tracing::warn!("obid couldn't remove a hook's secret from the vault: {e}");
        }
        Ok(true)
    }

    fn note(&self, id: &str, result: &str) {
        let mut hooks = self.lock();
        let Some(hook) = hooks.iter_mut().find(|h| h.id == id) else {
            return;
        };
        hook.last_delivery = Some(Delivery {
            at: time::format(time::now()),
            result: result.into(),
        });
        let next = hooks.clone();
        if let Err(e) = self.save(&next) {
            tracing::warn!("{e}");
        }
    }

    /// Counts a delivery to `id` now; false past [`PER_MINUTE`].
    fn take(&self, id: &str, now: i64) -> bool {
        let mut rate = self.rate.lock().unwrap_or_else(|e| e.into_inner());
        let times = rate.entry(id.to_owned()).or_default();
        times.retain(|t| *t > now - 60);
        if times.len() >= PER_MINUTE {
            return false;
        }
        times.push(now);
        true
    }

    /// Whether `body` was accepted on `id` in the last 24 hours; if not, it is now.
    fn duplicate(&self, id: &str, body: &[u8], now: i64) -> bool {
        let digest: [u8; 32] = obi_protocol::keys::sha256(body);
        let mut seen = self.seen.lock().unwrap_or_else(|e| e.into_inner());
        let kept = seen.entry(id.to_owned()).or_default();
        kept.retain(|(_, at)| *at > now - DUPLICATE_SECONDS);
        if kept.iter().any(|(d, _)| *d == digest) {
            return true;
        }
        kept.push((digest, now));
        false
    }

    /// One delivery, as the gateway got it: checked, then handed to its source's handler. The
    /// answer's body is obid's few words; the Worker passes on only its status.
    pub fn deliver(&self, id: &str, headers: &HeaderMap, body: &[u8]) -> (StatusCode, Value) {
        let Some(hook) = self.get(id) else {
            return (StatusCode::NOT_FOUND, json!({"error": "No such hook."}));
        };
        if body.len() > BODY_MAX {
            self.note(id, "too large");
            return (
                StatusCode::PAYLOAD_TOO_LARGE,
                json!({"error": "That delivery is too large."}),
            );
        }
        let now = time::now();
        if !self.take(id, now) {
            self.note(id, "too many");
            return (
                StatusCode::TOO_MANY_REQUESTS,
                json!({"error": "Too many deliveries to this hook."}),
            );
        }
        let secret = match self.vault.value(&secret_name(&hook.name)) {
            Ok(Some(secret)) => secret,
            Ok(None) => {
                return (
                    StatusCode::UNAUTHORIZED,
                    json!({"error": "That signature doesn't match."}),
                );
            }
            Err(_) => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    json!({"error": "obid can't check deliveries now."}),
                );
            }
        };
        let header = |name: &str| headers.get(name).and_then(|v| v.to_str().ok());
        let proved = match hook.source.as_str() {
            "github" => signed(&secret, body, header("x-hub-signature-256")),
            "generic" => signed(&secret, body, header("x-oby-signature-256")),
            _ => false,
        };
        if !proved {
            self.note(id, "bad signature");
            return (
                StatusCode::UNAUTHORIZED,
                json!({"error": "That signature doesn't match."}),
            );
        }
        if self.duplicate(id, body, now) {
            self.note(id, "duplicate");
            return (StatusCode::OK, json!({"duplicate": true}));
        }
        self.note(id, "accepted");
        // ponytail: no handler yet; #1129, #1130, #1311 and #1312 give each source one here.
        (StatusCode::ACCEPTED, json!({"accepted": true}))
    }
}

/// `POST /v1/hooks/{id}/deliver`, on the gateway's own router (crate::gateway): no device token,
/// so every check is this one's.
pub async fn deliver(
    shared: &Shared,
    id: &str,
    headers: HeaderMap,
    body: axum::body::Body,
) -> Response {
    if shared.hooks.get(id).is_none() {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({"error": "No such hook."})),
        )
            .into_response();
    }
    let Ok(bytes) = axum::body::to_bytes(body, BODY_MAX).await else {
        shared.hooks.note(id, "too large");
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(json!({"error": "That delivery is too large."})),
        )
            .into_response();
    };
    let (status, answer) = shared.hooks.deliver(id, &headers, &bytes);
    (status, Json(answer)).into_response()
}

// The registry's API: loopback only, never on the gateway.

pub fn router() -> Router<Arc<Shared>> {
    Router::new()
        .route("/v1/hooks", get(list).post(add))
        .route("/v1/hooks/{id}", delete(remove))
}

async fn list(State(shared): State<Arc<Shared>>) -> Json<Value> {
    Json(json!(shared.hooks.list()))
}

async fn add(State(shared): State<Arc<Shared>>, body: axum::body::Bytes) -> Response {
    let Ok(given) = serde_json::from_slice::<NewHook>(&body) else {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Send {\"id\", \"url\", \"name\", \"source\", \"secret\"} and, optionally, \"repo\".",
        )
        .into_response();
    };
    let repos: Vec<String> = shared.config.repos.iter().map(|r| r.repo.clone()).collect();
    match shared.hooks.add(&given, &repos) {
        Ok(hook) => (StatusCode::CREATED, Json(json!(hook))).into_response(),
        Err(error) => error.into_response(),
    }
}

async fn remove(State(shared): State<Arc<Shared>>, UrlPath(id): UrlPath<String>) -> Response {
    match shared.hooks.remove(&id) {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => ApiError::new(StatusCode::NOT_FOUND, "There's no such hook.").into_response(),
        Err(why) => ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, why).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hooks(name: &str) -> Arc<Hooks> {
        let home = std::env::temp_dir().join(format!("obid-hooks-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let vault = Arc::new(crate::vault::Vault::file(
            home.join("vault"),
            Arc::new(crate::secrets::Secrets::default()),
        ));
        Hooks::open(&home, vault, crate::events::Events::new())
    }

    fn sign(secret: &str, body: &[u8]) -> String {
        let key = aws_lc_rs::hmac::Key::new(aws_lc_rs::hmac::HMAC_SHA256, secret.as_bytes());
        format!(
            "sha256={}",
            hex::encode(aws_lc_rs::hmac::sign(&key, body).as_ref())
        )
    }

    const ID: &str = "abcdefghij0123456789abcdefghij01";

    fn new(
        id: &str,
        url: &str,
        name: &str,
        source: &str,
        secret: &str,
        repo: Option<&str>,
    ) -> NewHook {
        NewHook {
            id: id.into(),
            url: url.into(),
            name: name.into(),
            source: source.into(),
            secret: secret.into(),
            repo: repo.map(str::to_owned),
        }
    }

    fn secret() -> String {
        ["9f2c7e1a", "4b8d3f6e", "0a5c9e2b", "7d1f4a8c"].concat()
    }

    #[test]
    fn github_and_generic_signatures_are_checked_in_constant_time() {
        let body = br#"{"zen":"Keep it logically awesome."}"#;
        assert!(signed(&secret(), body, Some(&sign(&secret(), body))));
        assert!(!signed(
            &secret(),
            body,
            Some(&sign("another secret entirely 0123456789", body))
        ));
        assert!(!signed(&secret(), body, None));
        assert!(!signed(&secret(), body, Some("sha1=abc")));
        assert!(!signed(&secret(), body, Some("sha256=zz")));
    }

    #[test]
    fn a_hook_is_checked_kept_and_forgotten_with_its_secret() {
        let hooks = hooks("add");
        let url = format!("https://oby-control.tetrix.pro/h/{ID}");
        let repos = ["obi-e2e/fixture-app".to_owned()];
        for (id, url, name, source, secret) in [
            ("short", url.as_str(), "github-obi", "github", secret()),
            (
                ID,
                "http://oby-control.tetrix.pro/h/x",
                "github-obi",
                "github",
                secret(),
            ),
            (ID, url.as_str(), "GitHub Obi", "github", secret()),
            (ID, url.as_str(), "github-obi", "svn", secret()),
            (ID, url.as_str(), "github-obi", "github", "too short".into()),
        ] {
            assert!(
                hooks
                    .add(&new(id, url, name, source, &secret, None), &repos)
                    .is_err(),
                "{id} {url} {name} {source}"
            );
        }
        let elsewhere = new(
            ID,
            &url,
            "github-obi",
            "github",
            &secret(),
            Some("someone/else"),
        );
        assert!(hooks.add(&elsewhere, &repos).is_err());
        let here = new(
            ID,
            &url,
            "github-obi",
            "github",
            &secret(),
            Some("obi-e2e/fixture-app"),
        );
        let hook = hooks
            .add(&here, &repos)
            .unwrap_or_else(|e| panic!("{}", e.message));
        assert_eq!(hook.repo.as_deref(), Some("obi-e2e/fixture-app"));
        assert_eq!(
            hooks.vault.value("oby.hook.github-obi").unwrap(),
            Some(secret())
        );
        let kept = std::fs::read_to_string(&hooks.file).unwrap();
        assert!(!kept.contains(&secret()), "the secret is only in the vault");
        assert!(hooks.remove(ID).unwrap());
        assert_eq!(hooks.vault.value("oby.hook.github-obi").unwrap(), None);
        assert!(!hooks.remove(ID).unwrap());
    }

    #[test]
    fn a_delivery_is_checked_before_it_is_accepted() {
        let hooks = hooks("deliver");
        let url = format!("https://oby-control.tetrix.pro/h/{ID}");
        hooks
            .add(&new(ID, &url, "deploys", "generic", &secret(), None), &[])
            .unwrap_or_else(|e| panic!("{}", e.message));
        let body = br#"{"service":"api","status":"failed"}"#;
        let headers = |signature: &str| {
            let mut headers = HeaderMap::new();
            headers.insert("x-oby-signature-256", signature.parse().unwrap());
            headers
        };
        assert_eq!(
            hooks.deliver("unknown", &headers("x"), body).0,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            hooks.deliver(ID, &HeaderMap::new(), body).0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            hooks.get(ID).unwrap().last_delivery.unwrap().result,
            "bad signature"
        );
        let good = headers(&sign(&secret(), body));
        assert_eq!(hooks.deliver(ID, &good, body).0, StatusCode::ACCEPTED);
        assert_eq!(
            hooks.get(ID).unwrap().last_delivery.unwrap().result,
            "accepted"
        );
        let again = hooks.deliver(ID, &good, body);
        assert_eq!(again, (StatusCode::OK, json!({"duplicate": true})));
        let big = vec![b'x'; BODY_MAX + 1];
        assert_eq!(
            hooks.deliver(ID, &headers(&sign(&secret(), &big)), &big).0,
            StatusCode::PAYLOAD_TOO_LARGE
        );
        // GitHub's header is GitHub's alone: a generic hook doesn't read it.
        let mut github = HeaderMap::new();
        github.insert(
            "x-hub-signature-256",
            sign(&secret(), b"{}").parse().unwrap(),
        );
        assert_eq!(
            hooks.deliver(ID, &github, b"{}").0,
            StatusCode::UNAUTHORIZED
        );
    }

    #[test]
    fn deliveries_past_the_rate_are_refused() {
        let hooks = hooks("rate");
        let url = format!("https://oby-control.tetrix.pro/h/{ID}");
        hooks
            .add(&new(ID, &url, "deploys", "generic", &secret(), None), &[])
            .unwrap_or_else(|e| panic!("{}", e.message));
        for n in 0..PER_MINUTE {
            let body = format!("{{\"n\":{n}}}");
            let mut headers = HeaderMap::new();
            headers.insert(
                "x-oby-signature-256",
                sign(&secret(), body.as_bytes()).parse().unwrap(),
            );
            assert_eq!(
                hooks.deliver(ID, &headers, body.as_bytes()).0,
                StatusCode::ACCEPTED,
                "{n}"
            );
        }
        assert_eq!(
            hooks.deliver(ID, &HeaderMap::new(), b"{}").0,
            StatusCode::TOO_MANY_REQUESTS
        );
    }
}
