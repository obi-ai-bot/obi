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
pub const NOT_CONNECTED: &str = "Oby isn't connected to Slack.";
const REFUSED: &str =
    "Slack refused Oby's tokens: paste new ones in Settings › Connectors › Slack.";
const API: &str = "https://slack.com/api";
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
    async fn connect(&self, user: &str, bot: &str) -> Result<(), ApiError> {
        let bad = |text: String| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, text);
        let internal = |text: String| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, text);
        if let Some(problem) =
            token_problem(user, "xoxp-", "user").or_else(|| token_problem(bot, "xoxb-", "bot"))
        {
            return Err(bad(problem));
        }
        let person = self.identify(user, "user").await?;
        let app = self.identify(bot, "bot").await?;
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
        for (value, name) in [(user, USER), (bot, BOT)] {
            self.vault
                .add(value, name)
                .map_err(|e| internal(format!("obid couldn't keep Slack's tokens: {e}")))?;
        }
        self.save(Saved {
            team: text(&person, "team"),
            team_id: Some(team_id),
            user: Some(owner),
            bot: text(&app, "user_id"),
            connected_at: Some(obi_protocol::time::format(obi_protocol::time::now())),
            error: None,
        })
        .map_err(internal)
    }

    /// Forgets both tokens (the app stays installed in Slack). `error` says why, when the owner
    /// didn't ask.
    fn forget(&self, error: Option<String>) {
        for name in [USER, BOT] {
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
                self.forget(Some(REFUSED.into()));
                Err(REFUSED.into())
            }
        }
    }

    /// The messages `search.messages` finds for `query` with the user token, newest first, at
    /// most 300.
    pub async fn search(&self, query: &str) -> Result<Vec<Message>, String> {
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
            if page.parse::<u64>().unwrap_or(1) >= pages {
                break;
            }
        }
        Ok(found)
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
}

async fn connect(State(shared): State<Arc<Shared>>, body: axum::body::Bytes) -> Response {
    let Ok(tokens) = serde_json::from_slice::<Tokens>(&body) else {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Send {\"user\": \"xoxp-…\", \"bot\": \"xoxb-…\"}.",
        )
        .into_response();
    };
    match shared
        .slack
        .connect(tokens.user.trim(), tokens.bot.trim())
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
            .connect(&user_token(), &bot_token())
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
        assert!(slack.connect(&user_token(), &bot_token()).await.is_err());
        assert!(!slack.connected());

        let bot = json!({"ok": true, "team": "Deskree", "team_id": "T1", "user_id": "UBOT", "bot_id": "B1"});
        let stub_c = stub(HashMap::from([
            ("auth.test", person),
            ("auth.test.bot", bot),
        ]))
        .await;
        let slack = unconnected(&home, stub_c.url);
        assert!(slack.connect(&user_token(), &bot_token()).await.is_ok());
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
