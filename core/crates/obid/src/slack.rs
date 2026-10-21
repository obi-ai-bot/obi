//! Slack, connected once in Oby (F10, #14; the spike #26; docs/runner-api.md, "obid only: Slack").
//!
//! The owner installs their workspace's own Slack app ("Install to Workspace") and pastes its two
//! tokens into Oby: the user token (`xoxp-`), which obid uses only to search messages, and the
//! bot token (`xoxb-`), which it uses only to send the owner a direct message as the app. obid
//! checks both with `auth.test` and keeps them in its vault, so every answer, log line and push has
//! them taken out. Agents never get them, and nothing here is on the gateway. Every message obid
//! sends passes the secret scan first, and goes to the owner and nobody else.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::{ApiError, Shared};

pub const USER: &str = "oby.slack.user";
pub const BOT: &str = "oby.slack.bot";
/// The app-level token (`xapp-`, `connections:write`): Socket Mode only (crate::listen).
pub const APP: &str = "oby.slack.app";
pub const NOT_CONNECTED: &str = "Oby isn't connected to Slack.";
const REFUSED: &str =
    "Slack refused Oby's tokens: paste new ones in Settings › Connectors › Slack.";
const API: &str = "https://slack.com/api";
const SOCKET_REFUSED: &str = "Slack refused the app-level token: paste a new one in Settings › Connectors › Slack to listen again.";
/// The most a search reads: 3 pages of 100, newest first.
const PAGES: u32 = 3;

/// `home/slack.json` (0600): who the tokens are, never the tokens, which are in the vault.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Saved {
    team: Option<String>,
    team_id: Option<String>,
    /// The owner's own Slack user id (the user token's): the only one obid ever writes to.
    user: Option<String>,
    /// The app's bot user id (the bot token's).
    bot: Option<String>,
    /// Whether obid holds the app-level token, for Socket Mode.
    socket: bool,
    connected_at: Option<String>,
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
    /// Held while the tokens change.
    changing: tokio::sync::Mutex<()>,
    /// People's names by Slack id, as `users.info` said them.
    names: Mutex<std::collections::HashMap<String, String>>,
}

/// What a `PUT /v1/slack` says of the app-level token: left out (or empty), keep the one held;
/// `null`, forget it; a token, check it and keep it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AppToken<'a> {
    Keep,
    Forget,
    Set(&'a str),
}

/// A channel obid listens to: its id and, as Slack named it, its name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Channel {
    pub id: String,
    pub name: String,
}

/// Whether `url` is a Socket Mode address obid connects to: `wss://` on slack.com.
fn socket_url_ok(url: &str) -> bool {
    reqwest::Url::parse(url).is_ok_and(|u| {
        u.scheme() == "wss"
            && u.username().is_empty()
            && u.host_str()
                .is_some_and(|h| h == "slack.com" || h.ends_with(".slack.com"))
    })
}

/// A message event (Socket Mode's `event`, or one of `conversations.history`'s messages) in
/// `channel`, as obid keeps it: a person's own new message only (no subtype but a thread's
/// broadcast, no bot), with a link to it on slack.com.
pub fn event_message(event: &Value, channel: &Channel) -> Option<Message> {
    if skip_reason(event).is_some() {
        return None;
    }
    let ts = event["ts"].as_str()?;
    let user = event["user"].as_str().filter(|u| !u.is_empty())?;
    let at: f64 = ts.parse().ok()?;
    let digits: String = ts.chars().filter(char::is_ascii_digit).collect();
    Some(Message {
        key: format!("{}:{ts}", channel.id),
        at,
        user: user.to_owned(),
        place: format!("#{}", channel.name),
        text: event["text"].as_str().unwrap_or_default().to_owned(),
        permalink: Some(format!(
            "https://slack.com/archives/{}/p{digits}",
            channel.id
        ))
        .filter(|p| crate::watch::link_ok(p, "slack.com")),
    })
}

/// Why a message event isn't one obid reads, by its type only (never its words): a bot's post (one
/// with a `bot_id`), an edit or another subtype, or one with no person. None for a person's own.
pub fn skip_reason(event: &Value) -> Option<&'static str> {
    if event.get("bot_id").is_some_and(|b| !b.is_null()) {
        Some("a bot's post")
    } else if event["subtype"]
        .as_str()
        .is_some_and(|s| s != "thread_broadcast")
    {
        Some("an edit, a join or another subtype")
    } else if event["user"].as_str().is_none_or(str::is_empty) || event["ts"].as_str().is_none() {
        Some("no person or no time")
    } else {
        None
    }
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
    /// Slack refused the token (`invalid_auth`, `token_revoked`…).
    Refused,
    Other(String),
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
        "invalid_auth" | "not_authed" | "token_revoked" | "token_expired" | "account_inactive"
    )
}

/// Why `token` isn't a Slack token of this kind (`xoxp-` or `xoxb-`), or none.
fn token_problem(token: &str, prefix: &str, what: &str) -> Option<String> {
    let fine = token.starts_with(prefix)
        && (20..=512).contains(&token.len())
        && token.bytes().all(|c| c.is_ascii_graphic());
    (!fine).then(|| {
        format!("The {what} token starts with {prefix} (OAuth & Permissions › OAuth Tokens).")
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
                    .filter(|p| crate::watch::link_ok(p, "slack.com"))
                    .map(str::to_owned),
            })
        })
        .collect()
}

fn text(v: &Value, key: &str) -> Option<String> {
    v[key].as_str().filter(|s| !s.is_empty()).map(str::to_owned)
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
            changing: tokio::sync::Mutex::new(()),
            names: Mutex::default(),
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

    pub fn connected(&self) -> bool {
        self.saved().connected_at.is_some()
    }

    pub fn status_json(&self) -> Value {
        let saved = self.saved();
        let connected = saved.connected_at.is_some();
        json!({
            "connected": connected,
            "team": saved.team.filter(|_| connected),
            "user": saved.user.filter(|_| connected),
            "bot": saved.bot.filter(|_| connected),
            "socket": connected && saved.socket,
            "connectedAt": saved.connected_at,
            "error": saved.error,
        })
    }

    /// A Web API call, answered `ok`. A token Slack refuses is [`Failed::Refused`].
    async fn post(
        &self,
        method: &str,
        token: &str,
        form: &[(&str, &str)],
    ) -> Result<Value, Failed> {
        let response = self
            .http
            .post(format!("{}/{method}", self.api))
            .header(header::ACCEPT, "application/json")
            .bearer_auth(token)
            .form(form)
            .send()
            .await
            .map_err(|e| {
                Failed::Other(format!("Slack couldn't be reached: {}", e.without_url()))
            })?;
        let status = response.status();
        if status == StatusCode::TOO_MANY_REQUESTS {
            let wait = response
                .headers()
                .get(header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.trim().parse::<u64>().ok())
                .map_or("a while".to_owned(), |s| format!("{s} seconds"));
            return Err(Failed::Other(format!(
                "Slack's rate limit: try again in {wait}."
            )));
        }
        let mut response = response;
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|e| Failed::Other(format!("Slack's answer broke off: {}", e.without_url())))?
        {
            bytes.extend_from_slice(&chunk);
            if bytes.len() > 4 * 1024 * 1024 {
                return Err(Failed::Other("Slack's answer was too long.".into()));
            }
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

    /// `auth.test` for a pasted token: what Slack says it is, or why it can't be used.
    async fn identify(&self, token: &str, what: &str) -> Result<Value, ApiError> {
        self.post("auth.test", token, &[])
            .await
            .map_err(|e| match e {
                Failed::Refused => ApiError::new(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    format!("Slack refused the {what} token."),
                ),
                Failed::Other(why) => ApiError::new(StatusCode::BAD_GATEWAY, why),
            })
    }

    /// Checks both tokens with `auth.test` (one workspace; the user token a person's, the bot
    /// token the app's bot) and keeps them. Nothing is kept when either is refused.
    async fn connect(
        &self,
        user: &str,
        bot: &str,
        app_token: AppToken<'_>,
    ) -> Result<(), ApiError> {
        // Left out: the app-level token obid holds stays as it is, untested.
        let socket = match app_token {
            AppToken::Set(token) => Some(token),
            AppToken::Keep | AppToken::Forget => None,
        };
        let bad = |text: String| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, text);
        let internal = |text: String| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, text);
        if let Some(problem) =
            token_problem(user, "xoxp-", "user").or_else(|| token_problem(bot, "xoxb-", "bot"))
        {
            return Err(bad(problem));
        }
        if let Some(problem) = socket.and_then(|t| token_problem(t, "xapp-", "app-level")) {
            return Err(bad(problem));
        }
        let person = self.identify(user, "user").await?;
        let app = self.identify(bot, "bot").await?;
        // An app-level token has no `auth.test`: opening a Socket Mode connection is its test
        // (the URL it answers is used once, or never).
        if let Some(token) = socket {
            match self.post("apps.connections.open", token, &[]).await {
                Ok(answer) if socket_url_ok(answer["url"].as_str().unwrap_or("")) => {}
                Ok(_) => {
                    return Err(bad(
                        "Slack opened no Socket Mode connection for the app-level token.".into(),
                    ));
                }
                Err(Failed::Refused) => {
                    return Err(bad("Slack refused the app-level token.".into()));
                }
                Err(Failed::Other(why)) => return Err(ApiError::new(StatusCode::BAD_GATEWAY, why)),
            }
        }
        let (Some(owner), Some(team_id)) = (text(&person, "user_id"), text(&person, "team_id"))
        else {
            return Err(bad("Slack didn't say whose the user token is.".into()));
        };
        if text(&person, "bot_id").is_some() {
            return Err(bad(
                "That user token is a bot's: copy the User OAuth Token.".into(),
            ));
        }
        if text(&app, "bot_id").is_none() {
            return Err(bad(
                "That bot token isn't a bot's: copy the Bot User OAuth Token.".into(),
            ));
        }
        if text(&app, "team_id").as_deref() != Some(&team_id) {
            return Err(bad("The two tokens are from different workspaces.".into()));
        }
        let _held = self.changing.lock().await;
        let held = self.saved().socket && matches!(self.vault.value(APP), Ok(Some(_)));
        let socket_kept = match app_token {
            AppToken::Set(_) => true,
            AppToken::Keep => held,
            AppToken::Forget => false,
        };
        for (value, name) in [(Some(user), USER), (Some(bot), BOT), (socket, APP)] {
            let kept = match (value, name == APP && app_token == AppToken::Keep) {
                (Some(value), _) => self.vault.add(value, name),
                (None, true) => Ok(()),
                (None, false) => self.vault.remove(name).map(|_| ()),
            };
            if let Err(e) = kept {
                // Never half a login: what was kept goes too.
                let why = format!("obid couldn't keep Slack's tokens: {e}");
                self.forget(Some(why.clone()));
                return Err(internal(why));
            }
        }
        self.save(Saved {
            team: text(&person, "team"),
            team_id: Some(team_id),
            user: Some(owner),
            bot: text(&app, "user_id"),
            socket: socket_kept,
            connected_at: Some(obi_protocol::time::format(obi_protocol::time::now())),
            error: None,
        })
        .map_err(|why| {
            // Never half a login: the tokens kept go too.
            self.forget(Some(why.clone()));
            internal(why)
        })
    }

    /// Forgets both tokens (the app stays installed in Slack). `error` says why, when the owner
    /// didn't ask.
    fn forget(&self, error: Option<String>) {
        for name in [USER, BOT, APP] {
            if let Err(e) = self.vault.remove(name) {
                tracing::warn!("obid couldn't remove {name} from the vault: {e}");
            }
        }
        let saved = Saved {
            error,
            ..Saved::default()
        };
        if let Err(e) = self.save(saved) {
            tracing::warn!("{e}");
        }
    }

    pub async fn disconnect(&self) {
        let _held = self.changing.lock().await;
        self.forget(None);
    }

    /// A call with the token `name`; one Slack refuses signs Oby out (`error` says so).
    async fn call(&self, name: &str, method: &str, form: &[(&str, &str)]) -> Result<Value, String> {
        if !self.connected() {
            return Err(NOT_CONNECTED.into());
        }
        let token = self
            .vault
            .value(name)
            .map_err(|e| format!("the vault can't be read: {e}"))?
            .ok_or(NOT_CONNECTED)?;
        match self.post(method, &token, form).await {
            Ok(answer) => Ok(answer),
            Err(Failed::Other(why)) => Err(why),
            Err(Failed::Refused) => {
                let _held = self.changing.lock().await;
                // Only the token Slack refused signs Oby out: one pasted meanwhile stays.
                if self.vault.value(name).ok().flatten().as_deref() != Some(token.as_str()) {
                    return Err("Slack refused a token that was replaced meanwhile.".into());
                }
                if name == APP {
                    // The app-level token only stops the listener: the rest stays.
                    let _ = self.vault.remove(APP);
                    let mut saved = self.saved();
                    saved.socket = false;
                    saved.error = Some(SOCKET_REFUSED.into());
                    let _ = self.save(saved);
                    return Err(SOCKET_REFUSED.into());
                }
                self.forget(Some(REFUSED.into()));
                Err(REFUSED.into())
            }
        }
    }

    /// Whether obid holds the app-level token Socket Mode needs.
    pub fn socket_ready(&self) -> bool {
        let saved = self.saved();
        saved.connected_at.is_some() && saved.socket
    }

    /// A Socket Mode connection's address (`apps.connections.open`, the app-level token): a
    /// `wss://` URL on slack.com, used once.
    pub async fn socket_url(&self) -> Result<String, String> {
        let answer = self.call(APP, "apps.connections.open", &[]).await?;
        answer["url"]
            .as_str()
            .filter(|u| socket_url_ok(u))
            .map(str::to_owned)
            .ok_or_else(|| "Slack answered no Socket Mode address on slack.com.".into())
    }

    /// The messages in `channel` newer than `oldest` (a Slack `ts`), oldest first, at most 5
    /// pages of 200, with the user token: people's own messages, and why each other one was left
    /// out (`skip_reason`).
    pub async fn history(
        &self,
        channel: &Channel,
        oldest: &str,
    ) -> Result<(Vec<Message>, Vec<&'static str>), String> {
        let mut found = vec![];
        let mut skipped = vec![];
        let mut cursor = String::new();
        for _ in 0..5 {
            let mut form = vec![
                ("channel", channel.id.as_str()),
                ("oldest", oldest),
                ("limit", "200"),
            ];
            if !cursor.is_empty() {
                form.push(("cursor", cursor.as_str()));
            }
            let answer = self.call(USER, "conversations.history", &form).await?;
            for m in answer["messages"].as_array().into_iter().flatten() {
                match event_message(m, channel) {
                    Some(message) => found.push(message),
                    None => skipped.extend(skip_reason(m)),
                }
            }
            cursor = answer["response_metadata"]["next_cursor"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
            if answer["has_more"] != true || cursor.is_empty() {
                break;
            }
        }
        found.sort_by(|a, b| a.at.total_cmp(&b.at));
        Ok((found, skipped))
    }

    /// A channel's name (`conversations.info`, the user token): also the check that the owner can
    /// read it.
    pub async fn channel_name(&self, id: &str) -> Result<String, String> {
        let answer = self
            .call(USER, "conversations.info", &[("channel", id)])
            .await?;
        text(&answer["channel"], "name").ok_or_else(|| format!("Slack has no channel {id}."))
    }

    /// A person's display name (`users.info`, the user token), or their id when Slack doesn't say.
    pub async fn user_name(&self, id: &str) -> String {
        if let Some(name) = self.names.lock().unwrap_or_else(|e| e.into_inner()).get(id) {
            return name.clone();
        }
        let answer = self.call(USER, "users.info", &[("user", id)]).await;
        let user = answer.as_ref().map(|a| &a["user"]);
        let name = user
            .ok()
            .and_then(|u| {
                text(&u["profile"], "display_name")
                    .or_else(|| text(u, "real_name"))
                    .or_else(|| text(u, "name"))
            })
            .map(|n| {
                n.chars()
                    .filter(|c| !c.is_control())
                    .take(60)
                    .collect::<String>()
            });
        match name {
            Some(name) => {
                self.names
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(id.to_owned(), name.clone());
                name
            }
            None => id.to_owned(),
        }
    }

    /// The messages `search.messages` finds for `query` with the user token, newest first, at
    /// most 300, and whether that was all of them.
    pub async fn search(&self, query: &str) -> Result<(Vec<Message>, bool), String> {
        let mut found = Vec::new();
        for page in 1..=PAGES {
            let page = page.to_string();
            let answer = self
                .call(
                    USER,
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
            let page = page.parse::<u64>().unwrap_or(1);
            if page >= pages {
                return Ok((found, true));
            }
        }
        Ok((found, false))
    }

    /// Sends `text` to the owner as the app's bot, in its direct message with them: never to
    /// anyone else. It passes the secret scan first: a finding, or a scan that can't run, sends
    /// nothing. Answers the message's `ts`.
    pub async fn tell_owner(&self, text: &str) -> Result<String, String> {
        let owner = self
            .saved()
            .user
            .filter(|_| self.connected())
            .ok_or(NOT_CONNECTED)?;
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
        let opened = self
            .call(BOT, "conversations.open", &[("users", &owner)])
            .await?;
        let channel = opened["channel"]["id"]
            .as_str()
            .filter(|c| c.starts_with('D'))
            .ok_or("Slack opened no direct message with you.")?
            .to_owned();
        let answer = self
            .call(
                BOT,
                "chat.postMessage",
                &[
                    ("channel", &channel),
                    ("text", text),
                    ("unfurl_links", "false"),
                    ("unfurl_media", "false"),
                ],
            )
            .await?;
        Ok(answer["ts"].as_str().unwrap_or_default().to_owned())
    }
}

// The API: loopback only, never on the gateway.

pub fn router() -> Router<Arc<Shared>> {
    Router::new().route("/v1/slack", get(status).put(connect).delete(disconnect))
}

async fn status(State(shared): State<Arc<Shared>>) -> Json<Value> {
    Json(shared.slack.status_json())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Tokens {
    user: String,
    bot: String,
    /// The app-level token, for Socket Mode (crate::listen): left out, kept; `null`, forgotten.
    #[serde(default, deserialize_with = "present")]
    app: Option<Value>,
}

/// A key that's there, `null` too, as `Some`: only a key left out is `None`.
fn present<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Value>, D::Error> {
    Value::deserialize(d).map(Some)
}

async fn connect(State(shared): State<Arc<Shared>>, body: axum::body::Bytes) -> Response {
    let Ok(tokens) = serde_json::from_slice::<Tokens>(&body) else {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Send {\"user\": \"xoxp-…\", \"bot\": \"xoxb-…\"}, and \"app\": \"xapp-…\" for Socket Mode.",
        )
        .into_response();
    };
    let app = match &tokens.app {
        None => AppToken::Keep,
        Some(Value::Null) => AppToken::Forget,
        Some(Value::String(t)) if t.trim().is_empty() => AppToken::Keep,
        Some(Value::String(t)) => AppToken::Set(t.trim()),
        Some(_) => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "\"app\" is the app-level token (xapp-…), or null to forget it.",
            )
            .into_response();
        }
    };
    match shared
        .slack
        .connect(tokens.user.trim(), tokens.bot.trim(), app)
        .await
    {
        Ok(()) => Json(shared.slack.status_json()).into_response(),
        Err(error) => error.into_response(),
    }
}

async fn disconnect(State(shared): State<Arc<Shared>>) -> StatusCode {
    shared.slack.disconnect().await;
    StatusCode::NO_CONTENT
}

#[cfg(test)]
pub(crate) mod tests {
    use std::collections::HashMap;

    use super::*;

    /// Each call a stub got: its method, its form and its `Authorization`.
    pub(crate) type Calls = Arc<Mutex<Vec<(String, String, Option<String>)>>>;

    /// A stub of Slack's Web API on 127.0.0.1: what each method answers (a bot token's
    /// `auth.test` answers `auth.test.bot` when there's one), and every call it got.
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
            axum::routing::post(
                move |axum::extract::Path(method): axum::extract::Path<String>,
                      headers: axum::http::HeaderMap,
                      body: String| {
                    let kept = kept.clone();
                    let answers = answers.clone();
                    async move {
                        let auth = headers
                            .get(header::AUTHORIZATION)
                            .and_then(|h| h.to_str().ok())
                            .map(str::to_owned);
                        let bot = auth.as_deref().is_some_and(|a| a.contains("xoxb-"));
                        kept.lock().unwrap().push((method.clone(), body, auth));
                        let answer = (method == "auth.test" && bot)
                            .then(|| answers.get("auth.test.bot"))
                            .flatten()
                            .or_else(|| answers.get(method.as_str()));
                        Json(
                            answer
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

    /// A new empty folder of this test's own.
    pub(crate) fn scratch(name: &str) -> PathBuf {
        let home = std::env::temp_dir().join(format!("obid-slack-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        home
    }

    fn unconnected(home: &std::path::Path, api: String) -> Arc<Slack> {
        let vault = Arc::new(crate::vault::Vault::file(
            home.join("vault"),
            Arc::new(crate::secrets::Secrets::default()),
        ));
        Slack::open_at(home, vault, crate::events::Events::new(), api)
    }

    fn user_token() -> String {
        format!("xoxp-{}", "1111-2222-3333-7c41e09b2fd8a365")
    }

    fn bot_token() -> String {
        format!("xoxb-{}", "1111-4444-9d02b7f1e6c3a548")
    }

    /// A Slack connected as the owner `UOWNER` whose API is `api`.
    pub(crate) fn connected(home: &std::path::Path, api: String) -> Arc<Slack> {
        let slack = unconnected(home, api);
        slack.vault.add(&user_token(), USER).unwrap();
        slack.vault.add(&bot_token(), BOT).unwrap();
        slack
            .save(Saved {
                user: Some("UOWNER".into()),
                connected_at: Some("2026-10-21T12:00:00Z".into()),
                ..Saved::default()
            })
            .unwrap();
        slack
    }

    #[test]
    fn a_token_is_its_kind() {
        assert!(token_problem(&user_token(), "xoxp-", "user").is_none());
        assert!(token_problem(&bot_token(), "xoxp-", "user").is_some());
        assert!(token_problem("xoxp-short", "xoxp-", "user").is_some());
        assert!(token_problem("xoxp-1111-2222 3333-7c41e09b2fd8", "xoxp-", "user").is_some());
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

    /// The tokens are checked with Slack before they're kept: the user's a person's, the bot's a
    /// bot's, both of one workspace. Disconnect forgets both.
    #[tokio::test]
    async fn pasted_tokens_are_checked_then_kept() {
        let person = json!({"ok": true, "team": "Deskree", "team_id": "T1", "user_id": "UOWNER"});
        let home = scratch("connect");
        // The bot token answers as a person: refused, nothing kept.
        let stub_a = stub(HashMap::from([("auth.test", person.clone())])).await;
        let slack = unconnected(&home, stub_a.url);
        let refused = slack
            .connect(&user_token(), &bot_token(), AppToken::Keep)
            .await
            .unwrap_err();
        assert!(
            refused.message.contains("isn't a bot's"),
            "{}",
            refused.message
        );
        assert!(!slack.connected());
        assert_eq!(slack.vault.value(USER).unwrap(), None);

        let other_team = json!({"ok": true, "team_id": "T2", "user_id": "UBOT", "bot_id": "B1"});
        let stub_b = stub(HashMap::from([
            ("auth.test", person.clone()),
            ("auth.test.bot", other_team),
        ]))
        .await;
        let slack = unconnected(&home, stub_b.url);
        assert!(
            slack
                .connect(&user_token(), &bot_token(), AppToken::Keep)
                .await
                .is_err()
        );
        assert!(!slack.connected());

        let bot = json!({"ok": true, "team": "Deskree", "team_id": "T1", "user_id": "UBOT", "bot_id": "B1"});
        let stub_c = stub(HashMap::from([
            ("auth.test", person),
            ("auth.test.bot", bot),
        ]))
        .await;
        let slack = unconnected(&home, stub_c.url);
        assert!(
            slack
                .connect(&user_token(), &bot_token(), AppToken::Keep)
                .await
                .is_ok()
        );
        let status = slack.status_json();
        assert_eq!(status["connected"], true);
        assert_eq!(status["team"], "Deskree");
        assert_eq!(status["user"], "UOWNER");
        assert_eq!(status["bot"], "UBOT");
        assert!(
            !status.to_string().contains("xox"),
            "no token in the answer"
        );
        assert_eq!(slack.vault.value(BOT).unwrap(), Some(bot_token()));
        slack.disconnect().await;
        assert!(!slack.connected());
        assert_eq!(slack.vault.value(USER).unwrap(), None);
        assert_eq!(slack.vault.value(BOT).unwrap(), None);
    }

    /// A refusal that comes back after the owner pasted new tokens signs nothing out.
    #[tokio::test]
    async fn a_late_refusal_keeps_the_new_tokens() {
        let home = scratch("late");
        let app = Router::new().route(
            "/api/search.messages",
            axum::routing::post(|| async {
                tokio::time::sleep(Duration::from_millis(300)).await;
                Json(json!({"ok": false, "error": "invalid_auth"}))
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/api", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let slack = connected(&home, url);
        let newer = format!("xoxp-{}", "1111-2222-3333-9e8d7c6b5a4f3021");
        let searching = {
            let slack = slack.clone();
            tokio::spawn(async move { slack.search("from:<@U3>").await })
        };
        tokio::time::sleep(Duration::from_millis(100)).await;
        slack.vault.add(&newer, USER).unwrap();
        assert!(searching.await.unwrap().is_err());
        assert!(slack.connected(), "the new token stays");
        assert_eq!(slack.vault.value(USER).unwrap(), Some(newer));
    }

    /// The app-level token, for Socket Mode: its shape, then a Socket Mode connection opened as
    /// its test, on slack.com only.
    #[tokio::test]
    async fn the_app_level_token_is_tested_by_opening_a_connection() {
        let home = scratch("socket");
        let person = json!({"ok": true, "team": "Deskree", "team_id": "T1", "user_id": "UOWNER"});
        let bot = json!({"ok": true, "team_id": "T1", "user_id": "UBOT", "bot_id": "B1"});
        let app = format!("xapp-{}", "1-A0CAWE3AH99-1111-5f0e2a9c7b31d846");
        let elsewhere = stub(HashMap::from([
            ("auth.test", person.clone()),
            ("auth.test.bot", bot.clone()),
            (
                "apps.connections.open",
                json!({"ok": true, "url": "wss://evil.example/link"}),
            ),
        ]))
        .await;
        let slack = unconnected(&home, elsewhere.url);
        assert!(
            slack
                .connect(&user_token(), &bot_token(), AppToken::Set(&app))
                .await
                .is_err()
        );
        assert!(
            slack
                .connect(&user_token(), &bot_token(), AppToken::Set(&bot_token()))
                .await
                .is_err(),
            "an xapp- token only"
        );
        assert!(!slack.socket_ready());
        let fine = stub(HashMap::from([
            ("auth.test", person),
            ("auth.test.bot", bot),
            (
                "apps.connections.open",
                json!({"ok": true, "url": "wss://wss-primary.slack.com/link/?ticket=1"}),
            ),
        ]))
        .await;
        let slack = unconnected(&home, fine.url);
        assert!(
            slack
                .connect(&user_token(), &bot_token(), AppToken::Set(&app))
                .await
                .is_ok()
        );
        assert!(slack.socket_ready());
        assert_eq!(slack.status_json()["socket"], true);
        assert_eq!(slack.vault.value(APP).unwrap(), Some(app.clone()));
        assert_eq!(
            slack.socket_url().await.unwrap(),
            "wss://wss-primary.slack.com/link/?ticket=1"
        );
        // Connected again without it: kept. With `"app": null`: forgotten.
        assert!(
            slack
                .connect(&user_token(), &bot_token(), AppToken::Keep)
                .await
                .is_ok()
        );
        assert!(slack.socket_ready());
        assert_eq!(slack.vault.value(APP).unwrap(), Some(app.clone()));
        assert!(
            slack
                .connect(&user_token(), &bot_token(), AppToken::Forget)
                .await
                .is_ok()
        );
        assert!(!slack.socket_ready());
        assert_eq!(slack.vault.value(APP).unwrap(), None);
    }

    #[test]
    fn a_message_event_is_a_persons_new_message_only() {
        let channel = Channel {
            id: "C1".into(),
            name: "reviews".into(),
        };
        let event = json!({"type": "message", "channel": "C1", "user": "U3", "text": "hi", "ts": "1792501500.000100"});
        let m = event_message(&event, &channel).unwrap();
        assert_eq!(
            (m.key.as_str(), m.place.as_str()),
            ("C1:1792501500.000100", "#reviews")
        );
        assert_eq!(
            m.permalink.as_deref(),
            Some("https://slack.com/archives/C1/p1792501500000100")
        );
        for skipped in [
            json!({"subtype": "message_changed", "user": "U3", "ts": "1.0"}),
            json!({"bot_id": "B1", "user": "U3", "ts": "1.0"}),
            json!({"ts": "1.0", "text": "no user"}),
        ] {
            assert!(event_message(&skipped, &channel).is_none(), "{skipped}");
        }
    }

    #[tokio::test]
    async fn a_refused_token_signs_out() {
        let home = scratch("refused");
        let stub = stub(HashMap::from([(
            "search.messages",
            json!({"ok": false, "error": "invalid_auth"}),
        )]))
        .await;
        let slack = connected(&home, stub.url);
        assert_eq!(slack.search("from:<@U3>").await.unwrap_err(), REFUSED);
        assert!(!slack.connected());
        assert_eq!(slack.vault.value(USER).unwrap(), None);
        assert_eq!(slack.status_json()["error"], REFUSED);
    }

    #[tokio::test]
    async fn the_owner_is_told_by_the_bot_only_and_only_what_scans_clean() {
        let home = scratch("tell");
        let stub = stub(HashMap::from([
            (
                "conversations.open",
                json!({"ok": true, "channel": {"id": "D0OWNER"}}),
            ),
            ("chat.postMessage", json!({"ok": true, "ts": "1.2"})),
        ]))
        .await;
        let slack = connected(&home, stub.url);
        assert_eq!(
            slack
                .tell_owner("Dmitry wrote about Avenga.")
                .await
                .unwrap(),
            "1.2"
        );
        let got = stub.got.lock().unwrap().clone();
        assert_eq!(got.len(), 2);
        assert_eq!(
            (got[0].0.as_str(), got[0].1.as_str()),
            ("conversations.open", "users=UOWNER")
        );
        assert_eq!(got[1].0, "chat.postMessage");
        assert!(got[1].1.starts_with("channel=D0OWNER&"), "{}", got[1].1);
        let bearer = format!("Bearer {}", bot_token());
        assert!(got.iter().all(|c| c.2.as_deref() == Some(bearer.as_str())));
        // A key in the text: nothing goes out.
        let leaked = slack
            .tell_owner(&format!("AKIA{}", "QWERTYUIOPASDFGH"))
            .await;
        assert!(leaked.is_err());
        assert_eq!(stub.got.lock().unwrap().len(), 2);
    }
}
