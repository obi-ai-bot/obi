//! Slack, connected once in Oby (F10, #14; the spike #26; docs/runner-api.md, "obid only: Slack").
//!
//! obid is a Slack app's public client: OAuth v2 with PKCE and a redirect to `localhost` (Slack
//! takes one as a desktop redirect once the app has PKCE on), asking only for user scopes. The
//! owner's user token is kept in obid's vault, so every answer, log line and push has it taken
//! out. Agents never get it, and nothing here is on the gateway. obid uses it for two things only:
//! searching messages ([`Slack::search`]) and a direct message to the owner themselves
//! ([`Slack::tell_owner`]), which passes the secret scan first.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::{ApiError, Shared};

pub const ACCESS: &str = "oby.slack.access";
pub const REFRESH: &str = "oby.slack.refresh";
/// The port of the redirect the owner registers in the Slack app. Slack matches it, so it's fixed.
pub const PORT: u16 = 47823;
pub const REDIRECT: &str = "http://localhost:47823/callback";
/// The user scopes obid asks for: reading messages through search, and writing to the owner.
pub const USER_SCOPES: &str = "search:read,chat:write";
pub const NOT_CONNECTED: &str = "Oby isn't connected to Slack.";
const SIGNED_OUT: &str = "Slack signed Oby out: connect it again.";
const SIGN_IN_LASTS: Duration = Duration::from_secs(10 * 60);
const AUTHORIZE: &str = "https://slack.com/oauth/v2/authorize";
const API: &str = "https://slack.com/api";
/// The most a search reads: 3 pages of 100, newest first.
const PAGES: u32 = 3;

/// `home/slack.json` (0600): everything about the login but the tokens, which are in the vault.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Saved {
    /// The Slack app's client id: not a secret (a public client), the owner's app.
    client_id: Option<String>,
    team: Option<String>,
    team_id: Option<String>,
    /// The owner's own Slack user id: the only one obid ever writes to.
    user: Option<String>,
    scopes: Option<Vec<String>>,
    connected_at: Option<String>,
    /// When the access token ends, in seconds since the epoch; none for a token that doesn't.
    expires: Option<i64>,
    error: Option<String>,
}

pub struct Slack {
    file: PathBuf,
    scratch: PathBuf,
    saved: Mutex<Saved>,
    vault: Arc<crate::vault::Vault>,
    events: crate::events::Events,
    http: reqwest::Client,
    /// Slack's Web API (`https://slack.com/api`); a stub's in tests.
    api: String,
    sign_in: Mutex<Option<Arc<SignIn>>>,
    /// Held while the login changes, so one refresh runs at a time.
    changing: tokio::sync::Mutex<()>,
}

/// A sign-in under way: what its callback needs to finish it.
struct SignIn {
    url: String,
    expires: i64,
    state: String,
    verifier: String,
    client_id: String,
    end: tokio::sync::Notify,
    taken: AtomicBool,
    closed: tokio::sync::watch::Sender<bool>,
}

/// A message search found, as obid keeps it: Slack's typed fields and the text, quoted data.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Message {
    /// `<channel id>:<ts>`: the same message on every read.
    pub key: String,
    /// Slack's `ts`, as seconds since the epoch.
    pub at: f64,
    pub user: String,
    /// `#name`, or `a direct message` / `a group message`.
    pub place: String,
    pub text: String,
    pub permalink: Option<String>,
}

enum Failed {
    /// Slack refused the login (`invalid_auth`, `token_revoked`, `invalid_grant`…).
    Refused,
    Other(String),
}

/// A Slack app's client id: digits, a dot, digits (`1234567890.1234567890`).
fn client_id_problem(id: &str) -> Option<String> {
    let fine = id.len() <= 64
        && id.split_once('.').is_some_and(|(a, b)| {
            !a.is_empty()
                && !b.is_empty()
                && a.bytes().all(|c| c.is_ascii_digit())
                && b.bytes().all(|c| c.is_ascii_digit())
        });
    (!fine).then(|| {
        "That isn't a Slack app's Client ID: copy it from the app's Basic Information page (digits, a dot, digits).".into()
    })
}

/// An error code from Slack, safe to show.
fn code_of(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
        .take(64)
        .collect()
}

fn refused(code: &str) -> bool {
    matches!(
        code,
        "invalid_auth"
            | "not_authed"
            | "token_revoked"
            | "token_expired"
            | "account_inactive"
            | "invalid_grant"
            | "invalid_refresh_token"
            | "invalid_code"
            | "bad_redirect_uri"
    )
}

fn random(bytes: usize) -> Vec<u8> {
    let mut buffer = vec![0; bytes];
    getrandom::fill(&mut buffer).expect("the system's random source works");
    buffer
}

/// The login in an `oauth.v2.access` answer: a user token, from `authed_user` (a sign-in) or the
/// top level (a refresh of a user token).
struct Tokens {
    access: String,
    refresh: Option<String>,
    expires_in: Option<i64>,
    scope: Option<String>,
    user: Option<String>,
}

fn tokens(answer: &Value) -> Option<Tokens> {
    let text = |v: &Value| v.as_str().filter(|s| !s.is_empty()).map(str::to_owned);
    let user = &answer["authed_user"];
    let from = if text(&user["access_token"]).is_some() {
        user
    } else {
        answer
    };
    // Never a bot's token: obid asks for none, and writes only as the owner.
    if from["token_type"].as_str().is_some_and(|t| t != "user") {
        return None;
    }
    Some(Tokens {
        access: text(&from["access_token"])?,
        refresh: text(&from["refresh_token"]),
        expires_in: from["expires_in"].as_i64(),
        scope: text(&from["scope"]),
        user: text(&user["id"]).or_else(|| text(&answer["user_id"])),
    })
}

/// A search's matches as messages: those with a channel, a user and a `ts`.
fn messages(answer: &Value) -> Vec<Message> {
    let Some(matches) = answer["messages"]["matches"].as_array() else {
        return vec![];
    };
    matches
        .iter()
        .filter_map(|m| {
            let channel = &m["channel"];
            let id = channel["id"].as_str()?;
            let ts = m["ts"].as_str()?;
            let place = if channel["is_im"].as_bool() == Some(true) {
                "a direct message".to_owned()
            } else if channel["is_mpim"].as_bool() == Some(true) {
                "a group message".to_owned()
            } else {
                format!("#{}", channel["name"].as_str().unwrap_or(id))
            };
            Some(Message {
                key: format!("{id}:{ts}"),
                at: ts.parse().ok()?,
                user: m["user"].as_str()?.to_owned(),
                place,
                text: m["text"].as_str().unwrap_or_default().to_owned(),
                permalink: m["permalink"]
                    .as_str()
                    .filter(|p| p.starts_with("https://"))
                    .map(str::to_owned),
            })
        })
        .collect()
}

impl Slack {
    pub fn open(
        home: &std::path::Path,
        vault: Arc<crate::vault::Vault>,
        events: crate::events::Events,
    ) -> Arc<Slack> {
        Slack::open_at(home, vault, events, API.into())
    }

    fn open_at(
        home: &std::path::Path,
        vault: Arc<crate::vault::Vault>,
        events: crate::events::Events,
        api: String,
    ) -> Arc<Slack> {
        let file = home.join("slack.json");
        let saved = std::fs::read(&file)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(30))
            .build()
            .expect("reqwest client");
        Arc::new(Slack {
            file,
            scratch: home.join("tmp"),
            saved: Mutex::new(saved),
            vault,
            events,
            http,
            api,
            sign_in: Mutex::new(None),
            changing: tokio::sync::Mutex::new(()),
        })
    }

    fn saved(&self) -> Saved {
        self.saved.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn save(&self, saved: Saved) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(&saved).map_err(|e| e.to_string())?;
        crate::store::write_private(&self.file, &bytes)
            .map_err(|e| format!("obid couldn't keep Slack's settings: {e}"))?;
        *self.saved.lock().unwrap_or_else(|e| e.into_inner()) = saved;
        self.events.send("slack", self.status_json());
        Ok(())
    }

    fn running(&self) -> Option<Arc<SignIn>> {
        self.sign_in
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    pub fn connected(&self) -> bool {
        self.saved().connected_at.is_some()
    }

    /// The owner's own Slack user id, while connected.
    pub fn owner(&self) -> Option<String> {
        let saved = self.saved();
        saved.connected_at.and(saved.user)
    }

    pub fn status_json(&self) -> Value {
        let saved = self.saved();
        let connected = saved.connected_at.is_some();
        json!({
            "connected": connected,
            "team": saved.team.filter(|_| connected),
            "user": saved.user.filter(|_| connected),
            "clientId": saved.client_id,
            "redirect": REDIRECT,
            "scopes": saved.scopes.filter(|_| connected),
            "connectedAt": saved.connected_at,
            "signIn": self.running().map(|s| json!({"url": s.url,
                "expiresAt": obi_protocol::time::format(s.expires)})),
            "error": saved.error,
        })
    }

    /// Starts a sign-in with the Slack app `client_id` (none: the one obid kept), in place of the
    /// one under way, and gives the page the person opens.
    async fn start(self: &Arc<Self>, client_id: Option<String>) -> Result<Value, ApiError> {
        let client_id = client_id.or(self.saved().client_id).ok_or_else(|| {
            ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "Say which Slack app: {\"clientId\": \"…\"}, its Client ID.",
            )
        })?;
        if let Some(problem) = client_id_problem(&client_id) {
            return Err(ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, problem));
        }
        let before = self
            .sign_in
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take();
        if let Some(before) = before {
            before.end.notify_one();
            let mut closed = before.closed.subscribe();
            let _ = tokio::time::timeout(Duration::from_secs(5), closed.wait_for(|c| *c)).await;
        }
        let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, PORT))
            .await
            .map_err(|e| {
                ApiError::new(
                    StatusCode::CONFLICT,
                    format!("obid can't open Slack's redirect, port {PORT} on this Mac: {e}"),
                )
            })?;
        let verifier = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(random(32));
        let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(obi_protocol::keys::sha256(&verifier));
        let state = hex::encode(random(16));
        let mut page = reqwest::Url::parse(AUTHORIZE).expect("Slack's page");
        page.query_pairs_mut()
            .append_pair("client_id", &client_id)
            .append_pair("user_scope", USER_SCOPES)
            .append_pair("redirect_uri", REDIRECT)
            .append_pair("state", &state)
            .append_pair("code_challenge", &challenge)
            .append_pair("code_challenge_method", "S256");
        let sign_in = Arc::new(SignIn {
            url: page.to_string(),
            expires: obi_protocol::time::now() + SIGN_IN_LASTS.as_secs() as i64,
            state,
            verifier,
            client_id,
            end: tokio::sync::Notify::new(),
            taken: AtomicBool::new(false),
            closed: tokio::sync::watch::channel(false).0,
        });
        if let Some(meanwhile) = self
            .sign_in
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .replace(sign_in.clone())
        {
            meanwhile.end.notify_one();
        }
        let slack = self.clone();
        let running = sign_in.clone();
        tokio::spawn(async move {
            let app = Router::new()
                .route("/callback", get(callback))
                .with_state((slack.clone(), running.clone()));
            let ending = running.clone();
            let ended = async move {
                tokio::select! {
                    _ = ending.end.notified() => {}
                    _ = tokio::time::sleep(SIGN_IN_LASTS) => {}
                }
            };
            if let Err(e) = axum::serve(listener, app)
                .with_graceful_shutdown(ended)
                .await
            {
                tracing::warn!("Slack's sign-in page stopped: {e}");
            }
            running.closed.send_replace(true);
            let mut slot = slack.sign_in.lock().unwrap_or_else(|e| e.into_inner());
            if slot.as_ref().is_some_and(|s| Arc::ptr_eq(s, &running)) {
                *slot = None;
                drop(slot);
                slack.events.send("slack", slack.status_json());
            }
        });
        self.events.send("slack", self.status_json());
        Ok(json!({"url": sign_in.url,
            "expiresAt": obi_protocol::time::format(sign_in.expires)}))
    }

    pub fn cancel(&self) {
        if let Some(running) = self.running() {
            running.end.notify_one();
        }
    }

    fn set_error(&self, error: String) {
        let mut saved = self.saved();
        saved.error = Some(error);
        if let Err(e) = self.save(saved) {
            tracing::warn!("{e}");
        }
    }

    /// `oauth.v2.access`, with no client secret (PKCE).
    async fn token_request(&self, form: &[(&str, &str)]) -> Result<Tokens, Failed> {
        let answer = self.post("oauth.v2.access", None, form).await?;
        tokens(&answer).ok_or_else(|| Failed::Other("Slack sent no user token.".into()))
    }

    /// A Web API call, answered `ok`. A login Slack refuses is [`Failed::Refused`].
    async fn post(
        &self,
        method: &str,
        token: Option<&str>,
        form: &[(&str, &str)],
    ) -> Result<Value, Failed> {
        let mut request = self
            .http
            .post(format!("{}/{method}", self.api))
            .header(header::ACCEPT, "application/json")
            .form(form);
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        let response = request.send().await.map_err(|e| {
            Failed::Other(format!("Slack couldn't be reached: {}", e.without_url()))
        })?;
        let status = response.status();
        if status == StatusCode::TOO_MANY_REQUESTS {
            let wait = response
                .headers()
                .get(header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("a while");
            return Err(Failed::Other(format!(
                "Slack's rate limit: try again in {wait} seconds."
            )));
        }
        let bytes = response.bytes().await.unwrap_or_default();
        if bytes.len() > 4 * 1024 * 1024 {
            return Err(Failed::Other("Slack's answer was too long.".into()));
        }
        let answer: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        if answer["ok"] == true {
            return Ok(answer);
        }
        let code = code_of(answer["error"].as_str().unwrap_or(""));
        if refused(&code) {
            return Err(Failed::Refused);
        }
        Err(Failed::Other(if code.is_empty() {
            format!("Slack answered HTTP {}.", status.as_u16())
        } else {
            format!("Slack said {code}.")
        }))
    }

    fn keep(&self, tokens: &Tokens, new_login: bool) -> Result<(), String> {
        self.vault
            .add(&tokens.access, ACCESS)
            .map_err(|e| format!("obid couldn't keep Slack's login: {e}"))?;
        match &tokens.refresh {
            Some(refresh) => self
                .vault
                .add(refresh, REFRESH)
                .map_err(|e| format!("obid couldn't keep Slack's login: {e}"))?,
            None if new_login => {
                let _ = self.vault.remove(REFRESH);
            }
            None => {}
        }
        Ok(())
    }

    async fn finish(&self, sign_in: &SignIn, code: &str) -> Result<(), String> {
        let _held = self.changing.lock().await;
        let tokens = self
            .token_request(&[
                ("grant_type", "authorization_code"),
                ("code", code),
                ("client_id", &sign_in.client_id),
                ("code_verifier", &sign_in.verifier),
                ("redirect_uri", REDIRECT),
            ])
            .await
            .map_err(|e| match e {
                Failed::Refused => "Slack refused the sign-in.".to_owned(),
                Failed::Other(why) => why,
            })?;
        let user = tokens
            .user
            .clone()
            .ok_or("Slack didn't say who signed in.")?;
        self.keep(&tokens, true)?;
        let now = obi_protocol::time::now();
        let mut saved = self.saved();
        saved.client_id = Some(sign_in.client_id.clone());
        saved.user = Some(user);
        saved.scopes = Some(
            tokens
                .scope
                .as_deref()
                .unwrap_or(USER_SCOPES)
                .split(',')
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect(),
        );
        saved.connected_at = Some(obi_protocol::time::format(now));
        saved.expires = tokens.expires_in.map(|s| now + s);
        saved.error = None;
        // Who the workspace is: `auth.test`, best effort.
        if let Ok(who) = self.post("auth.test", Some(&tokens.access), &[]).await {
            saved.team = who["team"].as_str().map(str::to_owned);
            saved.team_id = who["team_id"].as_str().map(str::to_owned);
        }
        self.save(saved)
    }

    /// The access token, refreshed first when it has less than a minute left, or when `stale` (the
    /// token Slack just refused) is still the one held.
    async fn access(&self, stale: Option<&str>) -> Result<String, String> {
        let _held = self.changing.lock().await;
        let mut saved = self.saved();
        if saved.connected_at.is_none() {
            return Err(NOT_CONNECTED.into());
        }
        let current = self
            .vault
            .value(ACCESS)
            .map_err(|e| format!("the vault can't be read: {e}"))?
            .ok_or(NOT_CONNECTED)?;
        let now = obi_protocol::time::now();
        match stale {
            Some(stale) if stale != current => return Ok(current),
            None if saved.expires.is_none_or(|e| e - now > 60) => return Ok(current),
            _ => {}
        }
        let refresh = self
            .vault
            .value(REFRESH)
            .map_err(|e| format!("the vault can't be read: {e}"))?;
        let (Some(refresh), Some(client)) = (refresh, saved.client_id.clone()) else {
            self.forget(Some(SIGNED_OUT.into()));
            return Err(SIGNED_OUT.into());
        };
        match self
            .token_request(&[
                ("grant_type", "refresh_token"),
                ("refresh_token", &refresh),
                ("client_id", &client),
            ])
            .await
        {
            Ok(tokens) => {
                self.keep(&tokens, false)?;
                saved.expires = tokens.expires_in.map(|s| now + s);
                saved.error = None;
                self.save(saved)?;
                Ok(tokens.access)
            }
            Err(Failed::Refused) => {
                self.forget(Some(SIGNED_OUT.into()));
                Err(SIGNED_OUT.into())
            }
            Err(Failed::Other(why)) => Err(why),
        }
    }

    /// Forgets the login (the caller holds `changing`).
    fn forget(&self, error: Option<String>) {
        for name in [ACCESS, REFRESH] {
            if let Err(e) = self.vault.remove(name) {
                tracing::warn!("obid couldn't remove {name} from the vault: {e}");
            }
        }
        let mut saved = self.saved();
        saved.connected_at = None;
        saved.scopes = None;
        saved.expires = None;
        saved.error = error;
        if let Err(e) = self.save(saved) {
            tracing::warn!("{e}");
        }
    }

    /// Signs Oby out: the token revoked at Slack (`auth.revoke`, best effort), then forgotten.
    pub async fn disconnect(&self) {
        let _held = self.changing.lock().await;
        if let Ok(Some(token)) = self.vault.value(ACCESS)
            && let Err(Failed::Other(why)) = self.post("auth.revoke", Some(&token), &[]).await
        {
            tracing::info!("Slack didn't take back the login: {why}");
        }
        self.forget(None);
    }

    /// A call with the owner's token: refreshed once when Slack refuses it, signed out when it
    /// refuses again.
    async fn call(&self, method: &str, form: &[(&str, &str)]) -> Result<Value, String> {
        let token = self.access(None).await?;
        match self.post(method, Some(&token), form).await {
            Ok(answer) => Ok(answer),
            Err(Failed::Other(why)) => Err(why),
            Err(Failed::Refused) => {
                let token = self.access(Some(&token)).await?;
                match self.post(method, Some(&token), form).await {
                    Ok(answer) => Ok(answer),
                    Err(Failed::Other(why)) => Err(why),
                    Err(Failed::Refused) => {
                        let _held = self.changing.lock().await;
                        self.forget(Some(SIGNED_OUT.into()));
                        Err(SIGNED_OUT.into())
                    }
                }
            }
        }
    }

    /// The messages `search.messages` finds for `query`, newest first, at most 300.
    pub async fn search(&self, query: &str) -> Result<Vec<Message>, String> {
        let mut found = Vec::new();
        for page in 1..=PAGES {
            let page = page.to_string();
            let answer = self
                .call(
                    "search.messages",
                    &[
                        ("query", query),
                        ("count", "100"),
                        ("sort", "timestamp"),
                        ("sort_dir", "desc"),
                        ("page", &page),
                    ],
                )
                .await?;
            found.extend(messages(&answer));
            let pages = answer["messages"]["paging"]["pages"].as_u64().unwrap_or(1);
            if page.parse::<u64>().unwrap_or(1) >= pages {
                break;
            }
        }
        Ok(found)
    }

    /// Sends `text` to the owner themselves, as a direct message from their own account: never to
    /// anyone else. It passes the secret scan first: a finding, or a scan that can't run, sends
    /// nothing. Answers the message's `ts`.
    pub async fn tell_owner(&self, text: &str) -> Result<String, String> {
        let owner = self.owner().ok_or(NOT_CONNECTED)?;
        crate::store::make_private_dir(&self.scratch)
            .map_err(|e| format!("the secret scan couldn't run (its folder: {e})"))?;
        match crate::scan::scan(&[("slack.txt".into(), text.to_owned())], &self.scratch).await {
            crate::scan::Verdict::Clean => {}
            crate::scan::Verdict::Found(_) => {
                return Err("the secret scan found something in it, so it wasn't sent".into());
            }
            crate::scan::Verdict::CouldNotRun(why) => {
                return Err(format!(
                    "the secret scan couldn't run ({why}), so it wasn't sent"
                ));
            }
        }
        let answer = self
            .call(
                "chat.postMessage",
                &[
                    ("channel", &owner),
                    ("text", text),
                    ("unfurl_links", "false"),
                    ("unfurl_media", "false"),
                ],
            )
            .await?;
        Ok(answer["ts"].as_str().unwrap_or_default().to_owned())
    }
}

/// The page the browser lands on: a sentence of obid's own and nothing that runs.
fn page(status: StatusCode, text: &str) -> Response {
    let escaped = text
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    (
        status,
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
            (header::CONTENT_SECURITY_POLICY, "default-src 'none'"),
            (header::REFERRER_POLICY, "no-referrer"),
        ],
        format!("<!doctype html><meta charset=utf-8><title>Oby</title><p>{escaped}</p>"),
    )
        .into_response()
}

/// `GET /callback` on the redirect's port: the first request with its `state` finishes it.
async fn callback(
    State((slack, sign_in)): State<(Arc<Slack>, Arc<SignIn>)>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    // Only the address it gave: a page that renamed itself to this machine (DNS rebinding) isn't.
    let host = headers.get(header::HOST).and_then(|h| h.to_str().ok());
    if host != Some(&format!("localhost:{PORT}")) {
        return page(StatusCode::BAD_REQUEST, "This isn't Oby's sign-in page.");
    }
    if query.get("state") != Some(&sign_in.state) {
        return page(
            StatusCode::BAD_REQUEST,
            "This page isn't from Oby's sign-in to Slack.",
        );
    }
    if sign_in.taken.swap(true, Ordering::SeqCst) {
        return page(
            StatusCode::BAD_REQUEST,
            "This sign-in has already finished.",
        );
    }
    let finished = match (query.get("code"), query.get("error")) {
        (Some(code), _) => slack.finish(&sign_in, code).await,
        (None, Some(error)) => Err(format!("Slack's page said {}.", code_of(error))),
        _ => Err("Slack's page sent no code.".into()),
    };
    sign_in.end.notify_one();
    match finished {
        Ok(()) => page(
            StatusCode::OK,
            "Oby is connected to Slack. You can close this tab.",
        ),
        Err(why) => {
            slack.set_error(why.clone());
            page(
                StatusCode::BAD_REQUEST,
                &format!("Oby couldn't connect to Slack: {why}"),
            )
        }
    }
}

// The API: loopback only, never on the gateway.

pub fn router() -> Router<Arc<Shared>> {
    Router::new()
        .route("/v1/slack", get(status).delete(disconnect))
        .route("/v1/slack/sign-in", post(sign_in).delete(cancel))
}

async fn status(State(shared): State<Arc<Shared>>) -> Json<Value> {
    Json(shared.slack.status_json())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Start {
    client_id: Option<String>,
}

async fn sign_in(State(shared): State<Arc<Shared>>, body: axum::body::Bytes) -> Response {
    let start = if body.is_empty() {
        Start { client_id: None }
    } else {
        match serde_json::from_slice::<Start>(&body) {
            Ok(start) => start,
            Err(_) => {
                return ApiError::new(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "Send {\"clientId\": \"…\"}, the Slack app's Client ID, or nothing.",
                )
                .into_response();
            }
        }
    };
    match shared.slack.start(start.client_id).await {
        Ok(answer) => (StatusCode::OK, Json(answer)).into_response(),
        Err(error) => error.into_response(),
    }
}

async fn cancel(State(shared): State<Arc<Shared>>) -> StatusCode {
    shared.slack.cancel();
    StatusCode::NO_CONTENT
}

async fn disconnect(State(shared): State<Arc<Shared>>) -> StatusCode {
    shared.slack.disconnect().await;
    StatusCode::NO_CONTENT
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Each call a stub got: its method, its form and its `Authorization`.
    pub(crate) type Calls = Arc<Mutex<Vec<(String, String, Option<String>)>>>;

    /// A stub of Slack's Web API on 127.0.0.1: what each method answers, and every form it got.
    pub(crate) struct Stub {
        pub url: String,
        pub got: Calls,
    }

    pub(crate) async fn stub(answers: HashMap<&'static str, Value>) -> Stub {
        let got: Calls = Arc::default();
        let kept = got.clone();
        let answers = Arc::new(answers);
        let app = Router::new().route(
            "/api/{method}",
            post(
                move |axum::extract::Path(method): axum::extract::Path<String>,
                      headers: HeaderMap,
                      body: String| {
                    let kept = kept.clone();
                    let answers = answers.clone();
                    async move {
                        let auth = headers
                            .get(header::AUTHORIZATION)
                            .and_then(|h| h.to_str().ok())
                            .map(str::to_owned);
                        kept.lock().unwrap().push((method.clone(), body, auth));
                        Json(
                            answers
                                .get(method.as_str())
                                .cloned()
                                .unwrap_or(json!({"ok": false, "error": "unknown_method"})),
                        )
                    }
                },
            ),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/api", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Stub { url, got }
    }

    /// A connected Slack whose API is `api`, with `token` in a vault of its own under `home`.
    pub(crate) fn connected(home: &std::path::Path, api: String, token: &str) -> Arc<Slack> {
        let vault = Arc::new(crate::vault::Vault::file(
            home.join("vault"),
            Arc::new(crate::secrets::Secrets::default()),
        ));
        vault.add(token, ACCESS).unwrap();
        let slack = Slack::open_at(home, vault, crate::events::Events::new(), api);
        slack
            .save(Saved {
                client_id: Some("1.2".into()),
                user: Some("UOWNER".into()),
                connected_at: Some("2026-10-21T12:00:00Z".into()),
                ..Saved::default()
            })
            .unwrap();
        slack
    }

    /// A new empty folder of this test's own.
    pub(crate) fn scratch(name: &str) -> PathBuf {
        let home = std::env::temp_dir().join(format!("obid-slack-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        home
    }

    #[test]
    fn a_client_id_is_digits_a_dot_and_digits() {
        assert!(client_id_problem("1234567890.1234567890").is_none());
        for bad in ["", "1234", "a.1", "1.", ".1", "1.2&x=y", "1.2 "] {
            assert!(client_id_problem(bad).is_some(), "{bad:?}");
        }
    }

    #[test]
    fn a_sign_in_keeps_the_users_token_never_a_bots() {
        let signed_in = json!({"ok": true, "access_token": "xoxb-bot", "token_type": "bot",
            "authed_user": {"id": "U1", "scope": "search:read,chat:write", "access_token": "xoxp-1",
                "token_type": "user", "refresh_token": "xoxe-1", "expires_in": 43200}});
        let got = tokens(&signed_in).unwrap();
        assert_eq!(got.access, "xoxp-1");
        assert_eq!(got.refresh.as_deref(), Some("xoxe-1"));
        assert_eq!(got.user.as_deref(), Some("U1"));
        let refreshed = json!({"ok": true, "access_token": "xoxe.xoxp-2", "token_type": "user",
            "refresh_token": "xoxe-2", "expires_in": 43200});
        assert_eq!(tokens(&refreshed).unwrap().access, "xoxe.xoxp-2");
        assert!(
            tokens(&json!({"ok": true, "access_token": "xoxb", "token_type": "bot"})).is_none()
        );
    }

    #[test]
    fn search_matches_become_messages_with_slacks_typed_fields() {
        let answer = json!({"ok": true, "messages": {"matches": [
            {"ts": "1761062392.000100", "user": "U3", "text": "the snapshot cap",
             "channel": {"id": "C1", "name": "tetrix-avenga-testing"},
             "permalink": "https://deskree.slack.com/archives/C1/p1761062392000100"},
            {"ts": "1761062393.000200", "user": "U3", "text": "hi", "channel": {"id": "D1", "is_im": true},
             "permalink": "javascript:alert(1)"},
            {"ts": "1761062394.0", "text": "no user", "channel": {"id": "C2"}}]}});
        let found = messages(&answer);
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].key, "C1:1761062392.000100");
        assert_eq!(found[0].place, "#tetrix-avenga-testing");
        assert_eq!(found[1].place, "a direct message");
        assert_eq!(found[1].permalink, None, "only https links are kept");
    }

    #[tokio::test]
    async fn a_refused_token_is_refreshed_once_then_signs_out() {
        let home = scratch("refused");
        let stub = stub(HashMap::from([(
            "search.messages",
            json!({"ok": false, "error": "invalid_auth"}),
        )]))
        .await;
        let slack = connected(&home, stub.url, "xoxp-7c41e09b2fd8a365");
        let error = slack.search("from:<@U3>").await.unwrap_err();
        assert_eq!(error, SIGNED_OUT);
        assert!(!slack.connected());
        assert_eq!(slack.vault.value(ACCESS).unwrap(), None);
        assert_eq!(slack.status_json()["error"], SIGNED_OUT);
    }

    #[tokio::test]
    async fn the_owner_is_told_only_as_themselves_and_only_what_scans_clean() {
        let home = scratch("tell");
        let stub = stub(HashMap::from([(
            "chat.postMessage",
            json!({"ok": true, "ts": "1.2"}),
        )]))
        .await;
        let slack = connected(&home, stub.url, "xoxp-owner");
        assert_eq!(
            slack
                .tell_owner("Dmitry wrote about Avenga.")
                .await
                .unwrap(),
            "1.2"
        );
        let got = stub.got.lock().unwrap().clone();
        assert_eq!(got.len(), 1);
        let (method, body, auth) = &got[0];
        assert_eq!(method, "chat.postMessage");
        assert!(body.contains("channel=UOWNER"), "{body}");
        assert_eq!(auth.as_deref(), Some("Bearer xoxp-owner"));
        // A key in the text: nothing goes out.
        let leaked = slack
            .tell_owner(&format!("AKIA{}", "QWERTYUIOPASDFGH"))
            .await;
        assert!(leaked.is_err());
        assert_eq!(stub.got.lock().unwrap().len(), 1);
    }
}
