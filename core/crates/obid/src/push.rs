//! Push to Android phones through Firebase Cloud Messaging (docs/runner-api.md, "POST
//! /v1/notifications", obid's part): the Swift runner's job alerts (Runner/Push.swift) as FCM HTTP
//! v1 data messages. An APNs token is answered `{"push": false}` and not kept: obid has no APNs
//! sender (#452).
//!
//! - **Tokens.** The phones' FCM registration tokens, in `home/push/fcm.json` (0600), at most
//!   [`MOST`], oldest out. FCM's `UNREGISTERED`, or an `INVALID_ARGUMENT` about the token, drops one.
//! - **The service account.** The owner's vault secret [`SERVICE_ACCOUNT`] (`obid vault add`), so it
//!   is in no file an agent could read, and every answer, log line and push has it taken out. Its
//!   private key and the access tokens it gets are learned as obid's own secrets too.
//! - **When.** Two seconds after a job changes, each job whose need changed gets an alert, or a
//!   clear once it needs nothing. What was last said for each job is kept in
//!   `home/push/notices.json`, so a restart doesn't say it again; the first time, what the jobs
//!   already need isn't news.
//! - **What goes out.** Every alert's title and body pass the secret scan first: a finding, or a
//!   scan that can't run, sends nothing for that job. The send never holds up the API.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use aws_lc_rs::signature::{RSA_PKCS1_SHA256, RsaKeyPair};
use axum::body::Bytes;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::broadcast::error::{RecvError, TryRecvError};

use crate::api::{ApiError, Shared};
use crate::job::{Job, Status};

/// The vault secret holding the Firebase service account's JSON. `oby.` names are obid's own.
pub const SERVICE_ACCOUNT: &str = "oby.fcm.serviceAccount";
/// The most FCM tokens kept.
pub const MOST: usize = 20;
/// The Android app's application ID, the only `topic` an FCM token may name.
pub const TOPIC: &str = "com.deskree.oby";
/// FCM tokens are shorter than this.
const LONGEST: usize = 4096;
const SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const GRANT: &str = "urn:ietf:params:oauth:grant-type:jwt-bearer";
/// How long after a job changes the jobs are looked at: a burst of steps settles.
const SETTLE: Duration = Duration::from_secs(2);
/// How long FCM keeps a message for a phone that's off.
const TTL: &str = "86400s";

/// What a job needs from the owner: the only thing an alert is for. obid's jobs never ask a
/// question (`question` is null), and Oby's own review of a published job (#525) isn't ported,
/// so the Swift runner's `question`, `review` and `merge` don't arise here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Notice {
    /// Done with commits obid couldn't publish by itself: it waits for Publish.
    Ready,
    Failed,
    Interrupted,
    /// Its agent waits for the owner's OK on a command or an edit.
    Permission,
}

/// What `job` needs now, or none (a dismissed job's alert clears).
pub fn notice(job: &Job) -> Option<Notice> {
    if job.permission.is_some() && job.dismissed.is_none() && job.status != Status::Stopped {
        return Some(Notice::Permission);
    }
    if !job.needs_you() {
        return None;
    }
    if job.can_publish() {
        return Some(Notice::Ready);
    }
    match job.status {
        Status::Failed => Some(Notice::Failed),
        Status::Interrupted => Some(Notice::Interrupted),
        _ => None,
    }
}

/// A job whose alert changes, and what it needs now (none: clear it).
pub type Change = (Job, Option<Notice>);

/// What each job needs now against what was last said: the jobs whose alert changes (none: clear
/// it), and what to remember. Jobs no longer listed are forgotten.
pub fn changes(
    jobs: &[Job],
    said: &BTreeMap<String, Notice>,
) -> (Vec<Change>, BTreeMap<String, Notice>) {
    let mut changed = Vec::new();
    let mut now = BTreeMap::new();
    for job in jobs {
        let notice = notice(job);
        if let Some(notice) = notice {
            now.insert(job.id.clone(), notice);
        }
        if notice != said.get(&job.id).copied() {
            changed.push((job.clone(), notice));
        }
    }
    (changed, now)
}

fn first_line(text: &str) -> Option<&str> {
    text.lines().map(str::trim).find(|l| !l.is_empty())
}

/// The alert's title and body (runner-api.md's table) and its `category`.
pub fn alert(job: &Job, notice: Notice) -> (String, String, &'static str) {
    let title = job.short_title();
    let why = |otherwise: &str| {
        job.reason
            .as_deref()
            .and_then(first_line)
            .or_else(|| first_line(&job.summary))
            .unwrap_or(otherwise)
            .to_owned()
    };
    match notice {
        Notice::Ready => (
            format!("Couldn't publish: {title}"),
            job.publish_error
                .as_deref()
                .and_then(first_line)
                .or_else(|| first_line(&job.summary))
                .unwrap_or("Done")
                .to_owned(),
            "ready",
        ),
        Notice::Failed => (format!("Failed: {title}"), why("Failed"), "job"),
        Notice::Interrupted => (format!("Interrupted: {title}"), why("Interrupted"), "job"),
        Notice::Permission => {
            let (asks, detail) = job
                .permission
                .as_ref()
                .map_or(("Allow it", ""), |p| (p.title.as_str(), p.detail.as_str()));
            let detail = if detail.is_empty() { asks } else { detail };
            (
                format!("{asks}?"),
                format!("{title}: {}", detail.chars().take(200).collect::<String>()),
                "permission",
            )
        }
    }
}

/// The FCM v1 message for one token: an alert's data (`job`, `title`, `body`, `category`) or a
/// clear's (`clear`), every value a string, collapsed by the job's id.
pub fn message(token: &str, job: &str, data: Value, alert: bool) -> Value {
    json!({"message": {
        "token": token,
        "data": data,
        // FCM v1 spells AndroidMessagePriority by its enum names.
        "android": {"priority": if alert { "HIGH" } else { "NORMAL" }, "collapse_key": job, "ttl": TTL},
    }})
}

/// Why `body` isn't a registration obid takes (`422`), or the FCM token to keep; none for an
/// APNs token, which obid takes without keeping.
pub fn registration(body: &[u8]) -> Result<Option<String>, &'static str> {
    #[derive(Deserialize)]
    struct Registration {
        token: String,
        platform: Option<String>,
        topic: Option<String>,
    }
    let given: Registration = serde_json::from_slice(body)
        .map_err(|_| "The body is {\"token\": …, \"platform\": \"fcm\", \"topic\": …}.")?;
    if given.token.is_empty()
        || given.token.len() >= LONGEST
        || !given.token.bytes().all(|b| b.is_ascii_graphic())
    {
        return Err("token isn't a push token.");
    }
    match given.platform.as_deref() {
        None | Some("apns") => Ok(None),
        Some("fcm") => match given.topic.as_deref() {
            None | Some(TOPIC) => Ok(Some(given.token)),
            Some(_) => Err("topic is com.deskree.oby."),
        },
        Some(_) => Err("platform is fcm or apns."),
    }
}

/// `tokens` with `token` kept as the newest, at most [`MOST`].
pub fn kept(mut tokens: Vec<String>, token: String) -> Vec<String> {
    tokens.retain(|t| *t != token);
    tokens.push(token);
    let over = tokens.len().saturating_sub(MOST);
    tokens.drain(..over);
    tokens
}

/// Whether FCM's answer says the token is gone: `404 UNREGISTERED`, or `400 INVALID_ARGUMENT`
/// about the token.
pub fn gone(status: u16, answer: &Value) -> bool {
    let error = &answer["error"];
    let text = error.to_string();
    match status {
        404 => text.contains("UNREGISTERED"),
        400 => {
            error["status"] == "INVALID_ARGUMENT"
                && error["message"]
                    .as_str()
                    .is_some_and(|m| m.to_ascii_lowercase().contains("token"))
        }
        _ => false,
    }
}

/// A code from a server's answer, safe to log: letters, digits and `_.-` only.
fn code_of(value: &Value) -> String {
    let text = value
        .as_str()
        .or_else(|| value["status"].as_str())
        .unwrap_or("");
    text.chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
        .take(64)
        .collect()
}

/// The Firebase service account obid signs in with.
pub struct Account {
    pub project: String,
    pub email: String,
    pub token_uri: String,
    key: RsaKeyPair,
}

impl Account {
    /// The service account's JSON, or why it isn't one (never what it holds).
    pub fn parse(text: &str) -> Result<Account, &'static str> {
        #[derive(Deserialize)]
        struct Raw {
            project_id: String,
            client_email: String,
            private_key: String,
            token_uri: String,
        }
        let raw: Raw =
            serde_json::from_str(text).map_err(|_| "it isn't a service account's JSON")?;
        if raw.project_id.is_empty()
            || !raw
                .project_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b':'))
        {
            return Err("its project_id isn't one");
        }
        if !raw.token_uri.starts_with("https://") {
            return Err("its token_uri isn't https");
        }
        let body = raw
            .private_key
            .trim()
            .strip_prefix("-----BEGIN PRIVATE KEY-----")
            .and_then(|b| b.strip_suffix("-----END PRIVATE KEY-----"))
            .ok_or("its private_key isn't a PEM PKCS#8 key")?;
        let der = base64::engine::general_purpose::STANDARD
            .decode(body.split_whitespace().collect::<String>())
            .map_err(|_| "its private_key isn't a PEM PKCS#8 key")?;
        let key = RsaKeyPair::from_pkcs8(&der).map_err(|_| "its private_key isn't an RSA key")?;
        crate::secrets::known().learn("fcm private key", raw.private_key.trim());
        Ok(Account {
            project: raw.project_id,
            email: raw.client_email,
            token_uri: raw.token_uri,
            key,
        })
    }

    /// The signed JWT (RS256) Google's token endpoint takes for an hour's access token.
    pub fn assertion(&self, now: i64) -> Result<String, &'static str> {
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let header = b64.encode(br#"{"alg":"RS256","typ":"JWT"}"#);
        let claims = json!({"iss": self.email, "scope": SCOPE, "aud": self.token_uri,
                            "iat": now, "exp": now + 3600});
        let input = format!("{header}.{}", b64.encode(claims.to_string()));
        let mut signature = vec![0; self.key.public_modulus_len()];
        self.key
            .sign(
                &RSA_PKCS1_SHA256,
                &aws_lc_rs::rand::SystemRandom::new(),
                input.as_bytes(),
                &mut signature,
            )
            .map_err(|_| "the key couldn't sign")?;
        Ok(format!("{input}.{}", b64.encode(signature)))
    }
}

/// The phones' FCM tokens, what was last said for each job, and the cached access token.
pub struct Push {
    folder: PathBuf,
    tokens: Mutex<Vec<String>>,
    /// None until the first look at the jobs when `notices.json` wasn't there.
    said: Mutex<Option<BTreeMap<String, Notice>>>,
    /// The access token, the service account it's for, and until when it's used.
    access: tokio::sync::Mutex<Option<(String, String, Instant)>>,
    http: reqwest::Client,
}

impl Push {
    pub fn open(home: &Path) -> Push {
        let folder = home.join("push");
        let read = |name: &str| std::fs::read(folder.join(name)).ok();
        Push {
            tokens: Mutex::new(
                read("fcm.json")
                    .and_then(|b| serde_json::from_slice(&b).ok())
                    .unwrap_or_default(),
            ),
            said: Mutex::new(read("notices.json").and_then(|b| serde_json::from_slice(&b).ok())),
            folder,
            access: tokio::sync::Mutex::new(None),
            http: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(20))
                .build()
                .expect("reqwest client"),
        }
    }

    fn write(&self, name: &str, value: &impl Serialize) -> std::io::Result<()> {
        crate::store::make_private_dir(&self.folder)?;
        let bytes = serde_json::to_vec(value).map_err(std::io::Error::other)?;
        crate::store::write_private(&self.folder.join(name), &bytes)
    }

    fn save_tokens(&self, tokens: &[String]) -> std::io::Result<()> {
        self.write("fcm.json", &tokens)
    }

    /// The service account in the vault, when there is one that reads.
    pub fn account(&self) -> Option<Account> {
        match crate::vault::value(SERVICE_ACCOUNT) {
            Ok(Some(text)) => Account::parse(&text)
                .inspect_err(|why| {
                    tracing::warn!("no FCM push: {SERVICE_ACCOUNT} in the vault: {why}")
                })
                .ok(),
            Ok(None) => None,
            Err(why) => {
                tracing::warn!("no FCM push: {why}");
                None
            }
        }
    }

    /// Keeps `token` as the newest.
    pub fn keep(&self, token: String) -> std::io::Result<()> {
        let mut tokens = self.tokens.lock().unwrap_or_else(|e| e.into_inner());
        let next = kept(tokens.clone(), token);
        self.save_tokens(&next)?;
        *tokens = next;
        Ok(())
    }

    fn drop_token(&self, token: &str) {
        let mut tokens = self.tokens.lock().unwrap_or_else(|e| e.into_inner());
        tokens.retain(|t| t != token);
        if let Err(e) = self.save_tokens(&tokens) {
            tracing::error!("can't keep the FCM tokens: {e}");
        }
    }

    /// Looks at the jobs: remembers what each needs, and tells the phones what changed.
    pub async fn look(&self, jobs: &[Job], scratch: &Path) {
        let changed = {
            let mut said = self.said.lock().unwrap_or_else(|e| e.into_inner());
            let before = said.clone().unwrap_or_default();
            let (changed, now) = changes(jobs, &before);
            let first = said.is_none();
            if !first && now == before {
                return;
            }
            if let Err(e) = self.write("notices.json", &now) {
                tracing::error!("can't keep what the pushes said: {e}");
            }
            *said = Some(now);
            if first {
                return;
            }
            changed
        };
        let tokens = self
            .tokens
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        if changed.is_empty() || tokens.is_empty() {
            return;
        }
        let Some(account) = self.account() else {
            return;
        };
        for (job, notice) in changed {
            let data = match notice {
                None => json!({"clear": job.id}),
                Some(notice) => {
                    let (title, body, category) = alert(&job, notice);
                    if let Err(why) = scanned(&title, &body, scratch).await {
                        tracing::warn!(job = %job.id, "no push for the job: {why}");
                        continue;
                    }
                    json!({"job": job.id, "title": title, "body": body, "category": category})
                }
            };
            for token in &tokens {
                let message = message(token, &job.id, data.clone(), notice.is_some());
                self.send(&account, token, &message).await;
            }
        }
    }

    /// The access token for `account`, from Google's token endpoint when the cached one is near
    /// its end.
    async fn bearer(&self, account: &Account) -> Result<String, String> {
        let mut cached = self.access.lock().await;
        if let Some((token, email, until)) = cached.as_ref()
            && *email == account.email
            && Instant::now() < *until
        {
            return Ok(token.clone());
        }
        let assertion = account.assertion(obi_protocol::time::now())?;
        let response = self
            .http
            .post(&account.token_uri)
            .form(&[("grant_type", GRANT), ("assertion", assertion.as_str())])
            .send()
            .await
            .map_err(|e| format!("Google's token endpoint couldn't be reached ({e})"))?;
        let status = response.status();
        let answer: Value = response.json().await.unwrap_or(Value::Null);
        let token = answer["access_token"]
            .as_str()
            .filter(|_| status.is_success());
        let Some(token) = token else {
            return Err(format!(
                "Google's token endpoint answered {status} ({})",
                code_of(&answer["error"])
            ));
        };
        crate::secrets::known().learn("fcm access token", token);
        let lasts = answer["expires_in"].as_u64().unwrap_or(3600);
        let until = Instant::now() + Duration::from_secs(lasts.saturating_sub(300));
        *cached = Some((token.to_owned(), account.email.clone(), until));
        Ok(token.to_owned())
    }

    /// Sends one message; logs a failure without the token, and drops a token FCM no longer takes.
    async fn send(&self, account: &Account, token: &str, message: &Value) {
        let bearer = match self.bearer(account).await {
            Ok(bearer) => bearer,
            Err(why) => {
                tracing::warn!("no FCM push: {why}");
                return;
            }
        };
        let url = format!(
            "https://fcm.googleapis.com/v1/projects/{}/messages:send",
            account.project
        );
        let response = match self
            .http
            .post(url)
            .bearer_auth(bearer)
            .json(message)
            .send()
            .await
        {
            Ok(response) => response,
            Err(e) => {
                tracing::warn!("FCM couldn't be reached ({})", e.without_url());
                return;
            }
        };
        let status = response.status();
        if status.is_success() {
            return;
        }
        let answer: Value = response.json().await.unwrap_or(Value::Null);
        tracing::warn!(
            "an FCM push answered {status} ({})",
            code_of(&answer["error"])
        );
        if status == StatusCode::UNAUTHORIZED {
            *self.access.lock().await = None;
        }
        if gone(status.as_u16(), &answer) {
            self.drop_token(token);
        }
    }
}

/// Why an alert's text can't go out, or none: the secret scan runs on it first.
async fn scanned(title: &str, body: &str, scratch: &Path) -> Result<(), String> {
    crate::store::make_private_dir(scratch)
        .map_err(|e| format!("the secret scan couldn't run (its folder: {e})"))?;
    let texts = [
        ("push title".to_owned(), title.to_owned()),
        ("push body".to_owned(), body.to_owned()),
    ];
    match crate::scan::scan(&texts, scratch).await {
        crate::scan::Verdict::Clean => Ok(()),
        crate::scan::Verdict::Found(_) => Err("the secret scan found something in it".into()),
        crate::scan::Verdict::CouldNotRun(why) => {
            Err(format!("the secret scan couldn't run ({why})"))
        }
    }
}

/// `POST /v1/notifications`: `{"push": true}` once an FCM token is kept and obid can send;
/// `{"push": false}` for an APNs token, or without a service account (nothing kept).
pub async fn register(
    State(shared): State<Arc<Shared>>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let token =
        registration(&body).map_err(|why| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, why))?;
    let push = match token {
        Some(token) if shared.push.account().is_some() => {
            shared.push.keep(token).map_err(|e| {
                tracing::error!("can't keep an FCM token: {e}");
                ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "obid couldn't keep the token.",
                )
            })?;
            true
        }
        _ => false,
    };
    Ok((StatusCode::OK, axum::Json(json!({"push": push}))).into_response())
}

/// Looks at the jobs once now (a restart's news), then two seconds after each burst of job
/// changes, until obid stops.
pub fn spawn(shared: Arc<Shared>) {
    let mut events = shared.events.subscribe();
    let mut stopping = shared.stopping.clone();
    tokio::spawn(async move {
        let scratch = shared.config.home.join("tmp");
        loop {
            shared
                .push
                .look(&shared.jobs.list(usize::MAX), &scratch)
                .await;
            loop {
                tokio::select! {
                    got = events.recv() => match got {
                        Ok(event) if event.name == "job" => break,
                        Ok(_) => {}
                        Err(RecvError::Lagged(_)) => break,
                        Err(RecvError::Closed) => return,
                    },
                    _ = stopping.changed() => return,
                }
            }
            tokio::select! {
                () = tokio::time::sleep(SETTLE) => {}
                _ = stopping.changed() => return,
            }
            while !matches!(
                events.try_recv(),
                Err(TryRecvError::Empty | TryRecvError::Closed)
            ) {}
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(id: &str) -> Job {
        let mut job = Job::new(
            id.into(),
            "deskree-inc/oby".into(),
            "fix".into(),
            "Fix the push".into(),
            "claude".into(),
            "default".into(),
        );
        job.title = Some("Android push".into());
        job
    }

    fn permission() -> crate::permissions::Permission {
        crate::permissions::Permission {
            id: "p1".into(),
            tool: "Bash".into(),
            title: "Run swift test".into(),
            detail: "swift test --filter Push".into(),
            rule: None,
            always: None,
            why: None,
        }
    }

    #[test]
    fn registrations_are_checked() {
        let fcm = |body: Value| registration(body.to_string().as_bytes());
        assert_eq!(
            fcm(json!({"token": "abc:DEF-1_2", "platform": "fcm", "topic": TOPIC})),
            Ok(Some("abc:DEF-1_2".into()))
        );
        assert_eq!(
            fcm(json!({"token": "abc", "platform": "fcm"})),
            Ok(Some("abc".into()))
        );
        // The iPhone's: taken, never kept.
        assert_eq!(
            fcm(
                json!({"token": "5b0e9c", "topic": "com.deskree.oby", "environment": "production"})
            ),
            Ok(None)
        );
        assert_eq!(
            fcm(json!({"token": "5b0e9c", "platform": "apns"})),
            Ok(None)
        );
        for bad in [
            json!({"token": "", "platform": "fcm"}),
            json!({"token": "a b", "platform": "fcm"}),
            json!({"token": "é", "platform": "fcm"}),
            json!({"token": "x".repeat(LONGEST), "platform": "fcm"}),
            json!({"token": "abc", "platform": "web"}),
            json!({"token": "abc", "platform": "fcm", "topic": "com.other"}),
            json!({"platform": "fcm"}),
            json!({"token": 7}),
        ] {
            assert!(fcm(bad.clone()).is_err(), "{bad}");
        }
        assert!(registration(b"not json").is_err());
    }

    #[test]
    fn tokens_are_capped_oldest_out_and_a_known_one_moves_up() {
        let mut tokens = Vec::new();
        for n in 0..MOST + 3 {
            tokens = kept(tokens, format!("t{n}"));
        }
        assert_eq!(tokens.len(), MOST);
        assert_eq!(tokens[0], "t3");
        tokens = kept(tokens, "t3".into());
        assert_eq!(tokens.len(), MOST);
        assert_eq!(tokens.last().unwrap(), "t3");
        assert_eq!(tokens[0], "t4");
    }

    #[test]
    fn fcm_answers_that_drop_a_token() {
        let unregistered = json!({"error": {"code": 404, "status": "NOT_FOUND", "message": "Requested entity was not found.",
            "details": [{"@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode": "UNREGISTERED"}]}});
        assert!(gone(404, &unregistered));
        let invalid = json!({"error": {"code": 400, "status": "INVALID_ARGUMENT",
            "message": "The registration token is not a valid FCM registration token"}});
        assert!(gone(400, &invalid));
        let payload = json!({"error": {"code": 400, "status": "INVALID_ARGUMENT",
            "message": "Invalid value at 'message.data[0].value'"}});
        assert!(!gone(400, &payload));
        assert!(!gone(500, &unregistered));
        assert!(!gone(404, &json!({"error": {"status": "NOT_FOUND"}})));
        assert_eq!(code_of(&invalid["error"]), "INVALID_ARGUMENT");
        assert_eq!(code_of(&json!("invalid_grant\n<x>")), "invalid_grantx");
    }

    #[test]
    fn which_jobs_notify_and_what_they_say() {
        let mut failed = job("f1");
        failed.status = Status::Failed;
        failed.summary = "\nThe check failed: 3 tests.\nMore".into();
        assert_eq!(notice(&failed), Some(Notice::Failed));
        assert_eq!(
            alert(&failed, Notice::Failed),
            (
                "Failed: Android push".into(),
                "The check failed: 3 tests.".into(),
                "job"
            )
        );
        failed.reason = Some("The agent's login expired.".into());
        assert_eq!(
            alert(&failed, Notice::Failed).1,
            "The agent's login expired."
        );

        let mut interrupted = job("i1");
        interrupted.status = Status::Interrupted;
        assert_eq!(notice(&interrupted), Some(Notice::Interrupted));
        assert_eq!(
            alert(&interrupted, Notice::Interrupted),
            (
                "Interrupted: Android push".into(),
                "Interrupted".into(),
                "job"
            )
        );

        let mut ready = job("r1");
        ready.status = Status::Done;
        ready.base = Some("dev".into());
        ready.commits = Some(2);
        ready.publish_error = Some("Couldn't push oby/fix: the remote hung up.".into());
        assert_eq!(notice(&ready), Some(Notice::Ready));
        assert_eq!(
            alert(&ready, Notice::Ready),
            (
                "Couldn't publish: Android push".into(),
                "Couldn't push oby/fix: the remote hung up.".into(),
                "ready"
            )
        );

        let mut asking = job("p1");
        asking.status = Status::Running;
        asking.permission = Some(permission());
        assert_eq!(notice(&asking), Some(Notice::Permission));
        assert_eq!(
            alert(&asking, Notice::Permission),
            (
                "Run swift test?".into(),
                "Android push: swift test --filter Push".into(),
                "permission"
            )
        );
        asking.permission.as_mut().unwrap().detail = String::new();
        assert_eq!(
            alert(&asking, Notice::Permission).1,
            "Android push: Run swift test"
        );

        // Nothing else notifies: running, done without commits, stopped, dismissed.
        let mut quiet = job("q1");
        quiet.status = Status::Running;
        assert_eq!(notice(&quiet), None);
        quiet.status = Status::Done;
        assert_eq!(notice(&quiet), None);
        quiet.status = Status::Stopped;
        quiet.permission = Some(permission());
        assert_eq!(notice(&quiet), None);
        failed.dismissed = Some(1);
        assert_eq!(notice(&failed), None);
    }

    #[test]
    fn only_a_changed_need_is_said_and_a_job_that_needs_nothing_clears() {
        let mut a = job("a");
        a.status = Status::Failed;
        let mut b = job("b");
        b.status = Status::Running;
        let (changed, said) = changes(&[a.clone(), b.clone()], &BTreeMap::new());
        assert_eq!(
            changed
                .iter()
                .map(|(j, n)| (j.id.as_str(), *n))
                .collect::<Vec<_>>(),
            vec![("a", Some(Notice::Failed))]
        );
        // The same again: nothing.
        assert!(changes(&[a.clone(), b.clone()], &said).0.is_empty());
        // Dismissed: it clears; a job gone from the list is forgotten.
        a.dismissed = Some(1);
        let (changed, now) = changes(&[a.clone()], &said);
        assert_eq!(changed.len(), 1);
        assert_eq!(changed[0].1, None);
        assert!(now.is_empty());
        let (changed, now) = changes(&[], &said);
        assert!(changed.is_empty() && now.is_empty());
    }

    #[test]
    fn messages_are_data_only_collapsed_by_the_job() {
        let alert = message(
            "tok",
            "j1",
            json!({"job": "j1", "title": "t", "body": "b", "category": "job"}),
            true,
        );
        assert_eq!(
            alert,
            json!({"message": {"token": "tok", "data": {"job": "j1", "title": "t", "body": "b", "category": "job"},
                   "android": {"priority": "HIGH", "collapse_key": "j1", "ttl": "86400s"}}})
        );
        let clear = message("tok", "j1", json!({"clear": "j1"}), false);
        assert_eq!(clear["message"]["android"]["priority"], "NORMAL");
        assert!(clear["message"].get("notification").is_none());
    }

    /// A throwaway RSA key made here, so no key is in the source.
    fn service_account() -> (String, Vec<u8>) {
        use aws_lc_rs::encoding::AsDer;
        use aws_lc_rs::signature::KeyPair as _;
        let key = RsaKeyPair::generate(aws_lc_rs::rsa::KeySize::Rsa2048).unwrap();
        let der = key.as_der().unwrap();
        let body = base64::engine::general_purpose::STANDARD.encode(der.as_ref());
        // The PEM's label built here, so the secret scan doesn't take the test's own key for one.
        let label = ["PRIVATE", "KEY"].join(" ");
        let pem = format!(
            "-----BEGIN {label}-----\n{}\n-----END {label}-----\n",
            body.as_bytes()
                .chunks(64)
                .map(|c| std::str::from_utf8(c).unwrap())
                .collect::<Vec<_>>()
                .join("\n")
        );
        let json = json!({"type": "service_account", "project_id": "oby-test", "private_key": pem,
                          "client_email": "push@oby-test.iam.gserviceaccount.com",
                          "token_uri": "https://oauth2.googleapis.com/token"});
        (json.to_string(), key.public_key().as_ref().to_vec())
    }

    #[test]
    fn the_assertion_is_signed_with_the_service_accounts_key() {
        let (json, public) = service_account();
        let account = Account::parse(&json).unwrap();
        assert_eq!(account.project, "oby-test");
        let jwt = account.assertion(1_800_000_000).unwrap();
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let header: Value = serde_json::from_slice(&b64.decode(parts[0]).unwrap()).unwrap();
        assert_eq!(header, json!({"alg": "RS256", "typ": "JWT"}));
        let claims: Value = serde_json::from_slice(&b64.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(
            claims,
            json!({"iss": "push@oby-test.iam.gserviceaccount.com", "scope": SCOPE,
                   "aud": "https://oauth2.googleapis.com/token", "iat": 1_800_000_000_i64, "exp": 1_800_003_600_i64})
        );
        aws_lc_rs::signature::UnparsedPublicKey::new(
            &aws_lc_rs::signature::RSA_PKCS1_2048_8192_SHA256,
            public,
        )
        .verify(
            format!("{}.{}", parts[0], parts[1]).as_bytes(),
            &b64.decode(parts[2]).unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn what_isnt_a_service_account_is_refused() {
        let (json, _) = service_account();
        let mut value: Value = serde_json::from_str(&json).unwrap();
        assert!(Account::parse("{}").is_err());
        let mut plain = value.clone();
        plain["token_uri"] = json!("http://oauth2.googleapis.com/token");
        assert!(Account::parse(&plain.to_string()).is_err());
        let mut path = value.clone();
        path["project_id"] = json!("oby/../x");
        assert!(Account::parse(&path.to_string()).is_err());
        value["private_key"] =
            json!("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----");
        assert!(Account::parse(&value.to_string()).is_err());
    }

    #[test]
    fn tokens_and_notices_are_kept_private() {
        let home = std::env::temp_dir().join(format!("obid-push-{}", std::process::id()));
        let push = Push::open(&home);
        push.keep("tok-1".into()).unwrap();
        push.keep("tok-2".into()).unwrap();
        push.drop_token("tok-1");
        let file = home.join("push/fcm.json");
        let saved: Vec<String> = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(saved, vec!["tok-2".to_owned()]);
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(*Push::open(&home).tokens.lock().unwrap(), saved);
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[tokio::test]
    async fn the_first_look_is_no_news_and_a_restart_remembers() {
        let home = std::env::temp_dir().join(format!("obid-push-look-{}", std::process::id()));
        let mut failed = job("f1");
        failed.status = Status::Failed;
        let push = Push::open(&home);
        push.look(std::slice::from_ref(&failed), &home.join("tmp"))
            .await;
        let said: BTreeMap<String, Notice> =
            serde_json::from_slice(&std::fs::read(home.join("push/notices.json")).unwrap())
                .unwrap();
        assert_eq!(said.get("f1"), Some(&Notice::Failed));
        let again = Push::open(&home);
        assert_eq!(again.said.lock().unwrap().as_ref(), Some(&said));
        std::fs::remove_dir_all(&home).unwrap();
    }
}
