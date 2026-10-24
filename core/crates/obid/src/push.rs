//! Push to phones (docs/runner-api.md, "POST /v1/notifications", obid's part): Android through
//! Firebase Cloud Messaging, the Swift runner's job alerts (Runner/Push.swift) as FCM HTTP v1 data
//! messages; the iPhone through Deskree's relay, alerts sealed to the phone's own key so the relay
//! and Apple only ever carry a blob. A bare APNs token is answered `{"push": false}` and not kept:
//! obid has no APNs key of its own (#452).
//!
//! - **Tokens.** The phones' FCM registration tokens, in `home/push/fcm.json` (0600), at most
//!   [`MOST`], oldest out, each with the paired device that handed it over through the gateway
//!   (one token per device: a new one replaces it). Revoking the device drops its tokens, and a
//!   device that is no longer paired is sent nothing. FCM's `UNREGISTERED`, or an
//!   `INVALID_ARGUMENT` about the token, drops one. The iPhones' relay registrations follow the
//!   same rules in `home/push/relay.json`, their `pushKey` learned as obid's own secret (obid never
//!   gets the phone's `pushSecret`); the relay's `410` drops one.
//! - **The service account.** The owner's vault secret [`SERVICE_ACCOUNT`] (`obid vault add`), so it
//!   is in no file an agent could read, and every answer, log line and push has it taken out. Its
//!   private key and the access tokens it gets are learned as obid's own secrets too.
//! - **When.** Two seconds after a job, an inbox item or a conversation changes. FCM: each job
//!   whose need changed gets an alert, or a clear once it needs nothing. The relay, by the owner's
//!   lean rule ([`wanted`]): what needs the owner (urgent), a job that ended, an inbox item sorted
//!   `needs_you`, and Oby's messages while no paired device follows the events; one alert per
//!   thing, replaced in place, and a short "Settled" only for an urgent one. What was last said is
//!   kept in `home/push/notices.json` and `home/push/said.json`, so a restart doesn't say it
//!   again; the first time, what is already there isn't news.
//! - **What goes out.** Every alert's title and body pass the secret scan first: a finding, or a
//!   scan that can't run, sends nothing for it. The send never holds up the API.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
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
use crate::events::Event;
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
/// HPKE's `info` for an alert sealed to an iPhone.
pub const INFO: &[u8] = b"oby push v1";
/// The longest alert id: APNs' collapse id.
const ID: usize = 64;
/// The longest alert body, in characters.
const BODY: usize = 200;
/// The longest `sealed` the relay takes, in base64url characters: Apple's payload stays under 4 KB.
const SEALED: usize = 3072;
/// The control plane obid pushes through when `pushRelay` doesn't say (crate::config).
pub const RELAY: &str = "https://oby-control.deskree.com";
/// How long one push waits for the relay's answer.
const RELAY_WAIT: Duration = Duration::from_secs(10);
/// The longest a push waits before it's tried again.
const RETRY_MOST: Duration = Duration::from_secs(10);
/// The `401`s in a row that drop a registration: the relay doesn't know it, or never will.
const UNAUTHORIZED: u32 = 3;
/// Oby's message within this long of the owner's own words in its conversation answers them while
/// they're there: it isn't pushed (a turn takes at most 110 seconds).
const ANSWERING: Duration = Duration::from_secs(120);
/// The iPhone's sealed alerts: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305.
type SealKem = hpke::kem::X25519HkdfSha256;
type SealKdf = hpke::kdf::HkdfSha256;
type SealAead = hpke::aead::ChaCha20Poly1305;

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

/// One alert for an iPhone (docs/runner-api.md): what it says, what a tap opens, and the thing
/// it's about. Sealed as [`sealed_alert`] says.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Alert {
    /// The thing it's about, a job's, an inbox item's or a conversation's id: a newer alert for
    /// it replaces this one (the relay's `collapse`, never sealed).
    pub collapse: String,
    pub title: String,
    pub body: String,
    pub thread: String,
    pub category: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    /// It needs the owner: the relay is told so, outside the seal.
    #[serde(skip)]
    pub urgent: bool,
}

/// The relay's `collapse` for the thing `id`: `id` itself when it's at most [`ID`] printable ASCII
/// characters (APNs' collapse id), else a digest of it.
fn collapse_id(id: &str) -> String {
    if !id.is_empty() && id.len() <= ID && id.bytes().all(|b| b.is_ascii_graphic()) {
        return id.to_owned();
    }
    let digest = aws_lc_rs::digest::digest(&aws_lc_rs::digest::SHA256, id.as_bytes());
    format!("h-{}", hex::encode(&digest.as_ref()[..16]))
}

/// `text` on one line, without control characters, at most `most` characters.
fn clipped(text: &str, most: usize) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|c| !c.is_control())
        .take(most)
        .collect()
}

/// What's sealed for `alert`: its words and what a tap opens, with an `id` of this send alone
/// (the phone shows an id once) and `at`, when it was sealed in seconds since the epoch (the phone
/// drops one more than a day old). The thing's id stays outside, as the relay's `collapse`.
pub fn sealed_alert(alert: &Alert, at: i64) -> Value {
    let mut sealed = serde_json::to_value(alert).unwrap_or_default();
    if let Some(fields) = sealed.as_object_mut() {
        fields.remove("collapse");
        fields.insert(
            "id".into(),
            json!(uuid::Uuid::new_v4().simple().to_string()),
        );
        fields.insert("at".into(), json!(at));
    }
    sealed
}

/// What the relay should be saying now, by the owner's lean rule, each with what it says (an alert
/// is sent again only when that changes): a job's agent waiting for an OK (urgent); a job the
/// owner started that ended, once, with its result (a job another Obi asked for, a stopped or a
/// dismissed one, says nothing); and from the open inbox (`GET /v1/inbox`'s items), what Oby's
/// conversations wait on, Allow for a shell command, a Confirm or a Start, and an item sorted
/// `"triage": "needs_you"` (urgent). Progress, FYI and unsorted items are never alerts. A job's
/// permission item is its job's alert.
pub fn wanted(jobs: &[Job], inbox: &[Value]) -> Vec<(String, Alert)> {
    let mut wanted = Vec::new();
    for job in jobs
        .iter()
        .filter(|j| j.obi.is_none() && j.dismissed.is_none())
    {
        let alert = |(title, body, category): (String, String, &str), urgent| Alert {
            collapse: collapse_id(&job.id),
            title: clipped(&title, 100),
            body: clipped(&body, BODY),
            thread: "jobs".into(),
            category: category.into(),
            job: Some(job.id.clone()),
            conversation: None,
            item: None,
            urgent,
        };
        if let (Some(Notice::Permission), Some(permission)) = (notice(job), &job.permission) {
            let mut asks = alert(self::alert(job, Notice::Permission), true);
            // The answers its inbox item offers: Approve or Keep planning; Allow, Always allow
            // or Deny; Allow or Deny. The agent's own question's options are its own: only Open.
            asks.category = if permission.is_question() {
                "job"
            } else if permission.is_plan() {
                "plan"
            } else if permission.always.is_some() {
                "permissionRule"
            } else {
                "permission"
            }
            .into();
            asks.item = Some(crate::sphere::inbox::permission_item_id(
                &job.id,
                &permission.id,
            ));
            wanted.push((format!("permission:{}", permission.id), asks));
            continue;
        }
        let said = match job.status {
            Status::Done if job.can_publish() => self::alert(job, Notice::Ready),
            Status::Failed => self::alert(job, Notice::Failed),
            Status::Interrupted => self::alert(job, Notice::Interrupted),
            Status::Done => (
                format!("Done: {}", job.short_title()),
                first_line(&job.summary).unwrap_or("Done").to_owned(),
                "job",
            ),
            Status::Queued | Status::Running | Status::Stopped => continue,
        };
        let ended = job.finished.unwrap_or(job.created);
        wanted.push((format!("end:{ended}"), alert(said, false)));
    }
    for item in inbox.iter().filter(|i| i["state"] == "open") {
        let job = item["job"].as_str().filter(|j| !j.is_empty());
        let category = match item["kind"].as_str() {
            Some("permission") if job.is_some() => continue,
            Some("permission")
                if item["options"]
                    .as_array()
                    .is_some_and(|o| o.iter().any(|o| o == crate::permissions::ALWAYS_ALLOW)) =>
            {
                "permissionRule"
            }
            Some(kind @ ("permission" | "confirm" | "start")) => kind,
            _ if item["triage"] == "needs_you" => "inbox",
            _ => continue,
        };
        let (Some(id), Some(title)) = (item["id"].as_str(), item["title"].as_str()) else {
            continue;
        };
        let conversation = item["conversation"].as_str().map(str::to_owned);
        let text = item["text"].as_str().unwrap_or_default();
        wanted.push((
            "open".into(),
            Alert {
                collapse: collapse_id(id),
                title: clipped(title, 100),
                body: clipped(first_line(text).unwrap_or(""), BODY),
                thread: conversation.clone().unwrap_or_else(|| "inbox".into()),
                category: category.into(),
                job: job.map(str::to_owned),
                conversation,
                item: Some(id.to_owned()),
                urgent: true,
            },
        ));
    }
    wanted
}

/// What the relay said last for one thing: what it said, and for an urgent alert the alert, so
/// a "Settled" replaces it once the thing is gone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Said {
    pub what: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub settles: Option<Alert>,
}

/// What to send for `wanted` against what was said: each thing whose alert is new or says
/// something else, and a "Settled" for each urgent one that's gone; and what to remember.
pub fn told(
    wanted: Vec<(String, Alert)>,
    said: &BTreeMap<String, Said>,
) -> (Vec<Alert>, BTreeMap<String, Said>) {
    let mut send = Vec::new();
    let mut now = BTreeMap::new();
    for (what, alert) in wanted {
        if said.get(&alert.collapse).is_none_or(|s| s.what != what) {
            send.push(alert.clone());
        }
        let settles = alert.urgent.then(|| alert.clone());
        now.insert(alert.collapse.clone(), Said { what, settles });
    }
    for (id, gone) in said {
        if let Some(alert) = gone.settles.as_ref().filter(|_| !now.contains_key(id)) {
            send.push(Alert {
                title: "Settled".into(),
                body: alert.title.clone(),
                category: "settled".into(),
                urgent: false,
                ..alert.clone()
            });
        }
    }
    (send, now)
}

/// Oby's message in `conversation`, as its alert: its words on one line.
fn message_alert(conversation: &str, text: &str) -> Alert {
    Alert {
        collapse: collapse_id(conversation),
        title: "Oby".into(),
        body: clipped(text, BODY),
        thread: conversation.into(),
        category: "message".into(),
        job: None,
        conversation: Some(conversation.into()),
        item: None,
        urgent: false,
    }
}

/// `plaintext` sealed to `key` (an X25519 public key in base64url): HPKE (RFC 9180) base mode,
/// DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305, `info` [`INFO`], no associated
/// data; base64url, unpadded, of the encapsulated key (32 bytes) then the ciphertext.
pub fn seal(key: &str, plaintext: &[u8]) -> Result<String, &'static str> {
    use hpke::{Deserializable as _, Serializable as _};
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let key = b64
        .decode(key.trim_end_matches('='))
        .ok()
        .filter(|k| k.len() == 32)
        .ok_or("the key isn't 32 bytes of base64url")?;
    let key = <SealKem as hpke::Kem>::PublicKey::from_bytes(&key)
        .map_err(|_| "the key isn't an X25519 public key")?;
    let (enc, ciphertext) = hpke::single_shot_seal::<SealAead, SealKdf, SealKem>(
        &hpke::OpModeS::Base,
        &key,
        INFO,
        plaintext,
        b"",
    )
    .map_err(|_| "it couldn't be sealed to the key")?;
    let mut sealed = enc.to_bytes().to_vec();
    sealed.extend_from_slice(&ciphertext);
    Ok(b64.encode(sealed))
}

/// The raw 32 bytes of a `pushKey` (base64url, padding optional), or none.
fn push_key_bytes(push_key: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(push_key.trim_end_matches('='))
        .ok()
        .filter(|k| k.len() == 32)
}

/// The relay's `Oby-Push-Mac` for `body`: HMAC-SHA256 keyed by the `pushKey`'s raw bytes (never
/// its base64url text), base64url, unpadded.
pub fn mac(key: &[u8], body: &[u8]) -> String {
    let key = aws_lc_rs::hmac::Key::new(aws_lc_rs::hmac::HMAC_SHA256, key);
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(aws_lc_rs::hmac::sign(&key, body).as_ref())
}

/// What a `POST /v1/notifications` body hands over.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Registration {
    /// An Android phone's FCM token.
    Fcm(String),
    /// An iPhone's bare APNs token: taken, never kept.
    Apns,
    /// An iPhone's registration with Deskree's relay; its `device` is the caller's to fill in.
    Relay(Relayed),
}

/// Why `body` isn't a registration obid takes (`422`), or what it hands over. An iPhone's must be
/// with `relay`, the control plane obid pushes through (an origin).
pub fn registration(body: &[u8], relay: &str) -> Result<Registration, &'static str> {
    const SHAPE: &str = "The body is {\"token\": …, \"platform\": \"fcm\", \"topic\": …}, or {\"apns\": {\"pushId\", \"pushKey\", \"sealKey\", \"relay\"}}.";
    #[derive(Deserialize)]
    struct Token {
        token: String,
        platform: Option<String>,
        topic: Option<String>,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Apns {
        push_id: String,
        push_key: String,
        seal_key: String,
        relay: String,
    }
    let value: Value = serde_json::from_slice(body).map_err(|_| SHAPE)?;
    if let Some(apns) = value.get("apns") {
        let given: Apns = serde_json::from_value(apns.clone()).map_err(|_| SHAPE)?;
        let printable = |text: &str, least: usize| {
            (least..=512).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_graphic())
        };
        if !printable(&given.push_id, 1) {
            return Err("pushId isn't a push id.");
        }
        if push_key_bytes(&given.push_key).is_none() {
            return Err("pushKey is 32 bytes in base64url.");
        }
        if origin(&given.relay).as_deref() != Some(relay) {
            return Err("relay isn't the control plane this obid pushes through.");
        }
        seal(&given.seal_key, b"{}")
            .map_err(|_| "sealKey isn't an X25519 public key in base64url.")?;
        return Ok(Registration::Relay(Relayed {
            push_id: given.push_id,
            push_key: given.push_key,
            seal_key: given.seal_key,
            relay: relay.to_owned(),
            device: None,
        }));
    }
    let given: Token = serde_json::from_value(value).map_err(|_| SHAPE)?;
    if given.token.is_empty()
        || given.token.len() >= LONGEST
        || !given.token.bytes().all(|b| b.is_ascii_graphic())
    {
        return Err("token isn't a push token.");
    }
    match given.platform.as_deref() {
        None | Some("apns") => Ok(Registration::Apns),
        Some("fcm") => match given.topic.as_deref() {
            None | Some(TOPIC) => Ok(Registration::Fcm(given.token)),
            Some(_) => Err("topic is com.deskree.oby."),
        },
        Some(_) => Err("platform is fcm or apns."),
    }
}

/// `url` as a control plane's origin (`https://host[:port]`), or none: `https` only, with no
/// login, path, query or fragment.
pub fn origin(url: &str) -> Option<String> {
    let url = reqwest::Url::parse(url).ok()?;
    let fits = url.scheme() == "https"
        && url.host_str().is_some_and(|h| !h.is_empty())
        && url.username().is_empty()
        && url.password().is_none()
        && url.path() == "/"
        && url.query().is_none()
        && url.fragment().is_none();
    fits.then(|| url.origin().ascii_serialization())
}

/// One FCM token, and the paired device it came from; none when it came on the loopback API with
/// the API token.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Kept {
    pub token: String,
    pub device: Option<String>,
}

/// An iPhone's registration with Deskree's relay: where its alerts go, how the relay knows obid
/// sent them, the key they're sealed to, and the paired device it came from (as [`Kept`]).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Relayed {
    pub push_id: String,
    /// What obid signs its pushes with (the phone derives it from its `pushSecret`, which obid
    /// never gets). obid's own secret once kept: taken out of every answer, log line and push.
    pub push_key: String,
    pub seal_key: String,
    pub relay: String,
    pub device: Option<String>,
}

impl std::fmt::Debug for Relayed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Relayed")
            .field("relay", &self.relay)
            .field("device", &self.device)
            .finish_non_exhaustive()
    }
}

impl Relayed {
    /// The name its `pushKey` is learned under: its own, so each device's stays learned, and a
    /// digest of its push id, so a redaction marker shows neither.
    fn secret_name(&self) -> String {
        let digest = aws_lc_rs::digest::digest(&aws_lc_rs::digest::SHA256, self.push_id.as_bytes());
        format!("push key {}", hex::encode(&digest.as_ref()[..4]))
    }

    /// Learns its `pushKey` as obid's own, as written and as its raw bytes.
    fn learn(&self) {
        let raw = push_key_bytes(&self.push_key).unwrap_or_default();
        crate::secrets::known().learn_forms(&self.secret_name(), &[self.push_key.as_bytes(), &raw]);
    }
}

/// `list` with `new` kept as the newest, dropping what it replaces (`same`), at most [`MOST`].
fn newest<T>(mut list: Vec<T>, new: T, same: impl Fn(&T, &T) -> bool) -> Vec<T> {
    list.retain(|old| !same(old, &new));
    list.push(new);
    let over = list.len().saturating_sub(MOST);
    list.drain(..over);
    list
}

/// `tokens` with `token` kept as the newest, replacing its device's older one, at most [`MOST`].
pub fn kept(tokens: Vec<Kept>, token: Kept) -> Vec<Kept> {
    newest(tokens, token, |old, new| {
        old.token == new.token || (new.device.is_some() && old.device == new.device)
    })
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

/// The phones' FCM tokens and relay registrations, what was last said, and the cached access
/// token.
pub struct Push {
    folder: PathBuf,
    tokens: Mutex<Vec<Kept>>,
    relayed: Mutex<Vec<Relayed>>,
    /// None until the first look at the jobs when `notices.json` wasn't there.
    said: Mutex<Option<BTreeMap<String, Notice>>>,
    /// What the relay said for each thing; none until the first look when `said.json` wasn't
    /// there.
    told: Mutex<Option<BTreeMap<String, Said>>>,
    talk: Mutex<Talk>,
    /// The event streams paired devices follow now: a phone with Oby open.
    following: Arc<AtomicUsize>,
    /// The control plane's origin obid pushes through (`pushRelay`).
    relay: String,
    /// The relay's `401`s in a row, by push id.
    unauthorized: Mutex<HashMap<String, u32>>,
    /// The access token, the service account it's for, and until when it's used.
    access: tokio::sync::Mutex<Option<(String, String, Instant)>>,
    http: reqwest::Client,
}

/// What the conversations said since the last look, for the relay.
#[derive(Default)]
struct Talk {
    /// When the owner's own words last came, by conversation.
    words: HashMap<String, Instant>,
    /// The latest Oby turn heard, by conversation, its time and id: a turn sent again (its jobs
    /// changed) isn't news, nor an older one.
    heard: HashMap<String, (String, String)>,
    /// Oby's messages waiting for the next look, by conversation: the newest one.
    messages: BTreeMap<String, Alert>,
}

/// A paired device following the events while it's kept ([`Push::followed`]).
pub struct Following(Arc<AtomicUsize>);

impl Drop for Following {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

impl Push {
    /// The pushes kept in `home/push`, through the control plane at `relay` (an origin).
    pub fn open(home: &Path, relay: &str) -> Push {
        let folder = home.join("push");
        let read = |name: &str| std::fs::read(folder.join(name)).ok();
        let relayed: Vec<Relayed> = read("relay.json")
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        for kept in &relayed {
            kept.learn();
        }
        Push {
            tokens: Mutex::new(
                read("fcm.json")
                    .and_then(|b| serde_json::from_slice(&b).ok())
                    .unwrap_or_default(),
            ),
            relayed: Mutex::new(relayed),
            said: Mutex::new(read("notices.json").and_then(|b| serde_json::from_slice(&b).ok())),
            told: Mutex::new(read("said.json").and_then(|b| serde_json::from_slice(&b).ok())),
            talk: Mutex::new(Talk::default()),
            following: Arc::new(AtomicUsize::new(0)),
            relay: relay.to_owned(),
            unauthorized: Mutex::new(HashMap::new()),
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

    fn save_tokens(&self, tokens: &[Kept]) -> std::io::Result<()> {
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

    /// Keeps `token`, from the paired `device`, as the newest.
    pub fn keep(&self, token: String, device: Option<String>) -> std::io::Result<()> {
        let mut tokens = self.tokens.lock().unwrap_or_else(|e| e.into_inner());
        let next = kept(tokens.clone(), Kept { token, device });
        self.save_tokens(&next)?;
        *tokens = next;
        Ok(())
    }

    fn drop_where(&self, gone: impl Fn(&Kept) -> bool) {
        let mut tokens = self.tokens.lock().unwrap_or_else(|e| e.into_inner());
        let before = tokens.len();
        tokens.retain(|t| !gone(t));
        if tokens.len() != before
            && let Err(e) = self.save_tokens(&tokens)
        {
            tracing::error!("can't keep the FCM tokens: {e}");
        }
    }

    fn drop_token(&self, token: &str) {
        self.drop_where(|t| t.token == token);
    }

    /// Keeps an iPhone's relay registration, from the paired device it names, as the newest; its
    /// `pushKey` is obid's own secret from now on.
    pub fn keep_relayed(&self, relayed: Relayed) -> std::io::Result<()> {
        relayed.learn();
        let mut list = self.relayed.lock().unwrap_or_else(|e| e.into_inner());
        // Only its own device's: a push id handed over again by another device replaces nothing.
        let next = newest(list.clone(), relayed, |old, new| {
            old.device == new.device && (new.device.is_some() || old.push_id == new.push_id)
        });
        self.write("relay.json", &next)?;
        *list = next;
        Ok(())
    }

    fn drop_relayed(&self, gone: impl Fn(&Relayed) -> bool) {
        let mut list = self.relayed.lock().unwrap_or_else(|e| e.into_inner());
        let before = list.len();
        list.retain(|r| !gone(r));
        if list.len() != before
            && let Err(e) = self.write("relay.json", &*list)
        {
            tracing::error!("can't keep the iPhones' relay registrations: {e}");
        }
    }

    /// Drops the tokens and relay registrations the revoked device `id` handed over.
    pub fn forget(&self, id: &str) {
        self.drop_where(|t| t.device.as_deref() == Some(id));
        self.drop_relayed(|r| r.device.as_deref() == Some(id));
    }

    /// A paired device follows the events until the answer is dropped: Oby is open on it, so
    /// Oby's messages aren't pushed meanwhile.
    pub fn followed(&self) -> Following {
        self.following.fetch_add(1, Ordering::Relaxed);
        Following(self.following.clone())
    }

    /// Hears one of obid's events: whether the jobs, the inbox or a conversation changed, so the
    /// pushes look again. Oby's message (not a job's end or a routine's run, which their own
    /// alerts cover) waits for the next look, unless it came within [`ANSWERING`] of the owner's
    /// own words in its conversation.
    pub fn heard(&self, event: &Event) -> bool {
        match event.name {
            "job" | "inbox" => true,
            "turn" => {
                let turn = &event.data;
                let (Some(conversation), Some(id)) = (
                    turn["conversation"].as_str().filter(|c| !c.is_empty()),
                    turn["id"].as_str(),
                ) else {
                    return false;
                };
                let mut talk = self.talk.lock().unwrap_or_else(|e| e.into_inner());
                match turn["who"].as_str() {
                    Some("user") => {
                        talk.words.insert(conversation.into(), Instant::now());
                        talk.messages.remove(conversation);
                    }
                    Some("oby") if turn["ended"] != true && turn["routine"].is_null() => {
                        let at = turn["at"].as_str().unwrap_or_default();
                        let news = talk.heard.get(conversation).is_none_or(|(last, last_id)| {
                            at > last.as_str() || (at == last.as_str() && id != last_id.as_str())
                        });
                        if !news {
                            return true;
                        }
                        talk.heard
                            .insert(conversation.into(), (at.into(), id.into()));
                        let answering = talk
                            .words
                            .get(conversation)
                            .is_some_and(|at| at.elapsed() < ANSWERING);
                        if !answering {
                            let text = turn["text"].as_str().unwrap_or_default();
                            talk.messages
                                .insert(conversation.into(), message_alert(conversation, text));
                        }
                    }
                    _ => {}
                }
                true
            }
            _ => false,
        }
    }

    /// Looks at the jobs and the open inbox (`GET /v1/inbox`'s items): remembers what each needs,
    /// and tells the phones what changed: only devices still `paired`, and what came with the API
    /// token.
    pub async fn look(
        &self,
        jobs: &[Job],
        inbox: &[Value],
        paired: &HashSet<String>,
        scratch: &Path,
    ) {
        self.look_fcm(jobs, paired, scratch).await;
        self.look_relay(jobs, inbox, paired, scratch).await;
    }

    /// The relay's part of [`Push::look`]: [`wanted`] against what was said, then Oby's messages
    /// when no paired device follows the events.
    async fn look_relay(
        &self,
        jobs: &[Job],
        inbox: &[Value],
        paired: &HashSet<String>,
        scratch: &Path,
    ) {
        let (mut send, before, mut now) = {
            let told = self.told.lock().unwrap_or_else(|e| e.into_inner());
            let before = told.clone().unwrap_or_default();
            let (send, now) = self::told(wanted(jobs, inbox), &before);
            // The first look: what's there already isn't news.
            let send = if told.is_none() { Vec::new() } else { send };
            (send, before, now)
        };
        let messages =
            std::mem::take(&mut self.talk.lock().unwrap_or_else(|e| e.into_inner()).messages);
        if self.following.load(Ordering::Relaxed) == 0 {
            send.extend(messages.into_values());
        }
        // Only registrations made with the control plane obid pushes through now.
        let to: Vec<Relayed> = self
            .relayed
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .filter(|r| r.relay == self.relay)
            .filter(|r| r.device.as_ref().is_none_or(|d| paired.contains(d)))
            .cloned()
            .collect();
        if !to.is_empty() {
            let mut clean = Vec::new();
            for alert in send {
                // One the scan stops is never sent, nor tried again.
                match scanned(&alert.title, &alert.body, scratch).await {
                    Ok(()) => clean.push(alert),
                    Err(why) => {
                        tracing::warn!(alert = %alert.collapse, "no iPhone push for it: {why}")
                    }
                }
            }
            // Every alert to every phone at once: a slow relay holds up none of the others.
            let took = futures_util::future::join_all(clean.iter().map(|alert| async {
                futures_util::future::join_all(to.iter().map(|r| self.relay(r, alert)))
                    .await
                    .contains(&true)
            }))
            .await;
            // An ask, or its "Settled", that no phone took is said again at the next look.
            for (alert, took) in clean.iter().zip(took) {
                if took || !(alert.urgent || alert.category == "settled") {
                    continue;
                }
                match before.get(&alert.collapse) {
                    Some(was) => now.insert(alert.collapse.clone(), was.clone()),
                    None => now.remove(&alert.collapse),
                };
            }
        }
        let mut told = self.told.lock().unwrap_or_else(|e| e.into_inner());
        if told.as_ref() != Some(&now)
            && let Err(e) = self.write("said.json", &now)
        {
            tracing::error!("can't keep what the relay said: {e}");
        }
        *told = Some(now);
    }

    /// Seals `alert` to the iPhone of `to` and hands it to the relay: whether the relay took it.
    /// A `429`, a `5xx` or no answer within [`RELAY_WAIT`] is tried once more, the same send,
    /// after the relay's `Retry-After` (at most [`RETRY_MOST`]). `410` drops the registration,
    /// and so does the [`UNAUTHORIZED`]th `401` in a row. A failure is logged with the relay's
    /// status only; its body isn't read.
    async fn relay(&self, to: &Relayed, alert: &Alert) -> bool {
        let at = obi_protocol::time::now();
        let sealed = seal(&to.seal_key, sealed_alert(alert, at).to_string().as_bytes())
            .and_then(|sealed| {
                (sealed.len() <= SEALED)
                    .then_some(sealed)
                    .ok_or("it's longer than the relay takes")
            })
            .and_then(|sealed| {
                push_key_bytes(&to.push_key)
                    .map(|key| (sealed, key))
                    .ok_or("its pushKey isn't 32 bytes")
            });
        let (sealed, key) = match sealed {
            Ok(sealed) => sealed,
            Err(why) => {
                tracing::warn!(alert = %alert.collapse, "no iPhone push for it: {why}");
                return false;
            }
        };
        let body = json!({"pushId": to.push_id, "sealed": sealed, "collapse": alert.collapse,
                          "urgent": alert.urgent, "at": at})
        .to_string();
        let signed = mac(&key, body.as_bytes());
        let this = |r: &Relayed| r.push_id == to.push_id && r.device == to.device;
        for again in [false, true] {
            let answer = self
                .http
                .post(format!("{}/v1/push", self.relay))
                .timeout(RELAY_WAIT)
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .header("Oby-Push-Mac", &signed)
                .body(body.clone())
                .send()
                .await;
            let wait = match answer {
                Ok(answer) if answer.status().is_success() => {
                    self.unauthorized
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .remove(&to.push_id);
                    return true;
                }
                Ok(answer) if answer.status() == StatusCode::GONE => {
                    tracing::warn!("the push relay answered 410: an iPhone's registration is gone");
                    self.drop_relayed(this);
                    return false;
                }
                Ok(answer) if answer.status() == StatusCode::UNAUTHORIZED => {
                    let mut counts = self.unauthorized.lock().unwrap_or_else(|e| e.into_inner());
                    let count = counts.entry(to.push_id.clone()).or_insert(0);
                    *count += 1;
                    tracing::warn!("the push relay answered 401 ({count} in a row)");
                    if *count >= UNAUTHORIZED {
                        counts.remove(&to.push_id);
                        drop(counts);
                        self.drop_relayed(this);
                    }
                    return false;
                }
                Ok(answer)
                    if answer.status() == StatusCode::TOO_MANY_REQUESTS
                        || answer.status().is_server_error() =>
                {
                    tracing::warn!("the push relay answered {}", answer.status());
                    answer
                        .headers()
                        .get(reqwest::header::RETRY_AFTER)
                        .and_then(|v| v.to_str().ok()?.trim().parse().ok())
                        .map_or(Duration::from_secs(1), Duration::from_secs)
                }
                Ok(answer) => {
                    tracing::warn!("the push relay answered {}", answer.status());
                    return false;
                }
                Err(e) => {
                    tracing::warn!("the push relay couldn't be reached ({})", e.without_url());
                    Duration::from_secs(1)
                }
            };
            if again {
                break;
            }
            tokio::time::sleep(wait.min(RETRY_MOST)).await;
        }
        false
    }

    /// The FCM part of [`Push::look`]: each job whose need changed.
    async fn look_fcm(&self, jobs: &[Job], paired: &HashSet<String>, scratch: &Path) {
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
        let tokens: Vec<String> = self
            .tokens
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .filter(|t| t.device.as_ref().is_none_or(|d| paired.contains(d)))
            .map(|t| t.token.clone())
            .collect();
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

/// `POST /v1/notifications`: `{"push": true}` once an FCM token is kept and obid can send, or an
/// iPhone's relay registration is kept; `{"push": false}` for a bare APNs token, or an FCM token
/// without a service account (nothing kept).
pub async fn register(
    State(shared): State<Arc<Shared>>,
    device: Option<axum::Extension<crate::gateway::PairedDevice>>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let given = registration(&body, &shared.push.relay)
        .map_err(|why| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, why))?;
    let device = device.map(|axum::Extension(d)| d.0);
    let kept = match given {
        Registration::Fcm(token) if shared.push.account().is_some() => {
            Some(shared.push.keep(token, device))
        }
        Registration::Relay(relayed) => {
            Some(shared.push.keep_relayed(Relayed { device, ..relayed }))
        }
        _ => None,
    };
    if let Some(Err(e)) = &kept {
        tracing::error!("can't keep a push registration: {e}");
        return Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "obid couldn't keep the token.",
        ));
    }
    Ok((StatusCode::OK, axum::Json(json!({"push": kept.is_some()}))).into_response())
}

/// Looks at the jobs and the inbox once now (a restart's news), then two seconds after each burst
/// of changes to jobs, the inbox or the conversations, until obid stops.
pub fn spawn(shared: Arc<Shared>) {
    let mut events = shared.events.subscribe();
    let mut stopping = shared.stopping.clone();
    tokio::spawn(async move {
        let scratch = shared.config.home.join("tmp");
        loop {
            let paired = shared.gateway.paired(std::time::SystemTime::now());
            let inbox = match shared.link.inbox_json(false, usize::MAX) {
                Value::Array(items) => items,
                _ => Vec::new(),
            };
            shared
                .push
                .look(&shared.jobs.list(usize::MAX), &inbox, &paired, &scratch)
                .await;
            loop {
                tokio::select! {
                    got = events.recv() => match got {
                        Ok(event) if shared.push.heard(&event) => break,
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
            loop {
                match events.try_recv() {
                    Ok(event) => {
                        shared.push.heard(&event);
                    }
                    Err(TryRecvError::Lagged(_)) => {}
                    Err(TryRecvError::Empty | TryRecvError::Closed) => break,
                }
            }
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
            question: None,
        }
    }

    #[test]
    fn registrations_are_checked() {
        let fcm = |body: Value| registration(body.to_string().as_bytes(), RELAY);
        assert_eq!(
            fcm(json!({"token": "abc:DEF-1_2", "platform": "fcm", "topic": TOPIC})),
            Ok(Registration::Fcm("abc:DEF-1_2".into()))
        );
        assert_eq!(
            fcm(json!({"token": "abc", "platform": "fcm"})),
            Ok(Registration::Fcm("abc".into()))
        );
        // The iPhone's: taken, never kept.
        assert_eq!(
            fcm(
                json!({"token": "5b0e9c", "topic": "com.deskree.oby", "environment": "production"})
            ),
            Ok(Registration::Apns)
        );
        assert_eq!(
            fcm(json!({"token": "5b0e9c", "platform": "apns"})),
            Ok(Registration::Apns)
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
        assert!(registration(b"not json", RELAY).is_err());
    }

    #[test]
    fn tokens_are_capped_oldest_out_and_a_known_one_moves_up() {
        let k = |token: &str, device: Option<&str>| Kept {
            token: token.into(),
            device: device.map(Into::into),
        };
        let mut tokens = Vec::new();
        for n in 0..MOST + 3 {
            tokens = kept(tokens, k(&format!("t{n}"), None));
        }
        assert_eq!(tokens.len(), MOST);
        assert_eq!(tokens[0].token, "t3");
        tokens = kept(tokens, k("t3", None));
        assert_eq!(tokens.len(), MOST);
        assert_eq!(tokens.last().unwrap().token, "t3");
        assert_eq!(tokens[0].token, "t4");
        // A device's new token replaces its old one; another device's stays.
        let tokens = kept(
            vec![k("a1", Some("A")), k("b1", Some("B"))],
            k("a2", Some("A")),
        );
        assert_eq!(tokens, vec![k("b1", Some("B")), k("a2", Some("A"))]);
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
        let push = Push::open(&home, RELAY);
        push.keep("tok-1".into(), None).unwrap();
        push.keep("tok-2".into(), Some("phone".into())).unwrap();
        push.keep("tok-3".into(), Some("lost".into())).unwrap();
        push.drop_token("tok-1");
        push.forget("lost");
        let file = home.join("push/fcm.json");
        let saved: Vec<Kept> = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(
            saved,
            vec![Kept {
                token: "tok-2".into(),
                device: Some("phone".into())
            }]
        );
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(*Push::open(&home, RELAY).tokens.lock().unwrap(), saved);
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[tokio::test]
    async fn the_first_look_is_no_news_and_a_restart_remembers() {
        let home = std::env::temp_dir().join(format!("obid-push-look-{}", std::process::id()));
        let mut failed = job("f1");
        failed.status = Status::Failed;
        let push = Push::open(&home, RELAY);
        push.look(
            std::slice::from_ref(&failed),
            &[],
            &HashSet::new(),
            &home.join("tmp"),
        )
        .await;
        let said: BTreeMap<String, Notice> =
            serde_json::from_slice(&std::fs::read(home.join("push/notices.json")).unwrap())
                .unwrap();
        assert_eq!(said.get("f1"), Some(&Notice::Failed));
        let again = Push::open(&home, RELAY);
        assert_eq!(again.said.lock().unwrap().as_ref(), Some(&said));
        std::fs::remove_dir_all(&home).unwrap();
    }

    use hpke::{Deserializable as _, Kem as _, Serializable as _};

    type SecretKey = <SealKem as hpke::Kem>::PrivateKey;

    fn b64() -> base64::engine::GeneralPurpose {
        base64::engine::general_purpose::URL_SAFE_NO_PAD
    }

    /// A throwaway iPhone key made here: its private half, and the `sealKey` it registers.
    fn iphone() -> (SecretKey, String) {
        let (secret, public) = SealKem::gen_keypair();
        (secret, b64().encode(public.to_bytes()))
    }

    /// What `sealed` opens to with the iPhone's private key, as CryptoKit's `HPKE.Recipient` does.
    fn opened(secret: &SecretKey, sealed: &str) -> Value {
        let raw = b64().decode(sealed).unwrap();
        let enc = <SealKem as hpke::Kem>::EncappedKey::from_bytes(&raw[..32]).unwrap();
        let plain = hpke::single_shot_open::<SealAead, SealKdf, SealKem>(
            &hpke::OpModeR::Base,
            secret,
            &enc,
            INFO,
            &raw[32..],
            b"",
        )
        .unwrap();
        serde_json::from_slice(&plain).unwrap()
    }

    /// A test phone's `pushKey`: 32 bytes made from its push id, base64url.
    fn key_of(push_id: &str) -> String {
        b64().encode(aws_lc_rs::digest::digest(
            &aws_lc_rs::digest::SHA256,
            push_id.as_bytes(),
        ))
    }

    fn relayed(push_id: &str, device: Option<&str>, seal_key: &str, relay: &str) -> Relayed {
        Relayed {
            push_id: push_id.into(),
            push_key: key_of(push_id),
            seal_key: seal_key.into(),
            relay: relay.into(),
            device: device.map(Into::into),
        }
    }

    #[test]
    fn relay_registrations_are_checked() {
        let (_, key) = iphone();
        let signs = key_of("p-1");
        let apns = |id: &str, signs: &str, key: &str, relay: &str| {
            registration(
                json!({"apns": {"pushId": id, "pushKey": signs, "sealKey": key, "relay": relay}})
                    .to_string()
                    .as_bytes(),
                RELAY,
            )
        };
        let good = |relay: &str| apns("p-1", &signs, &key, relay);
        let kept = Ok(Registration::Relay(Relayed {
            push_id: "p-1".into(),
            push_key: signs.clone(),
            seal_key: key.clone(),
            relay: RELAY.into(),
            device: None,
        }));
        // Only the control plane obid pushes through, however it's written.
        assert_eq!(good("https://oby-control.deskree.com"), kept);
        assert_eq!(good("https://Oby-Control.deskree.com:443/"), kept);
        for relay in [
            "https://evil.example",
            "https://oby-control.deskree.com:8443",
            "http://oby-control.deskree.com",
            "http://127.0.0.1:8787",
            "https://oby-control.deskree.com/v1",
            "https://user:pass@oby-control.deskree.com",
            "https://oby-control.deskree.com/?x=1",
            "oby-control.deskree.com",
        ] {
            assert!(good(relay).is_err(), "{relay}");
        }
        assert_eq!(
            origin("https://Push.Example.com:8443/").as_deref(),
            Some("https://push.example.com:8443")
        );
        assert_eq!(origin("http://127.0.0.1:8787"), None);
        assert!(apns("p-1", &signs, &format!("{key}="), RELAY).is_ok());
        let zeros = b64().encode([0_u8; 32]);
        for bad_key in [
            String::new(),
            "abc".into(),
            b64().encode([7_u8; 31]),
            b64().encode([7_u8; 33]),
            // A low-order point: its shared secret would be all zeros.
            zeros,
        ] {
            assert!(apns("p-1", &signs, &bad_key, RELAY).is_err(), "{bad_key}");
        }
        assert!(apns("", &signs, &key, RELAY).is_err());
        assert!(apns("p 1", &signs, &key, RELAY).is_err());
        // The pushKey is 32 bytes in base64url (padded or not), never the phone's pushSecret.
        assert!(apns("p-1", &format!("{signs}="), &key, RELAY).is_ok());
        for bad in [
            String::new(),
            "short".into(),
            b64().encode([7_u8; 31]),
            b64().encode([7_u8; 33]),
            format!("{} ", signs),
            signs.replace(&signs[..2], "+/"),
        ] {
            assert!(apns("p-1", &bad, &key, RELAY).is_err(), "{bad}");
        }
        let secret_only = json!({"apns": {"pushId": "p-1", "pushSecret": signs, "sealKey": key,
                                          "relay": RELAY}});
        assert!(registration(secret_only.to_string().as_bytes(), RELAY).is_err());
        assert!(registration(br#"{"apns": {"pushId": "p-1"}}"#, RELAY).is_err());
        assert!(registration(br#"{"apns": "p-1"}"#, RELAY).is_err());
    }

    /// RFC 4231's test case 2, then the relay's own shape: the MAC is over the raw body as sent.
    #[test]
    fn the_mac_is_hmac_sha256_of_the_raw_body() {
        let expected =
            hex::decode("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
                .unwrap();
        assert_eq!(
            mac(b"Jefe", b"what do ya want for nothing?"),
            b64().encode(expected)
        );
        // Keyed by the pushKey's raw 32 bytes, never its base64url text.
        let signs = key_of("p-1");
        let raw = push_key_bytes(&signs).unwrap();
        assert_eq!(raw.len(), 32);
        let body =
            br#"{"at":1800000000,"collapse":"j1","pushId":"p-1","sealed":"AAAA","urgent":true}"#;
        assert_ne!(mac(&raw, body), mac(signs.as_bytes(), body));
        assert_ne!(
            mac(&raw, body),
            mac(&push_key_bytes(&key_of("p-2")).unwrap(), body)
        );
        assert_ne!(mac(&raw, body), mac(&raw, &body[1..]));
    }

    /// The relay's own vector (cloud/control-plane, docs/remote-access.md "Pushes", #1356): what
    /// obid signs is what the relay checks.
    #[test]
    fn the_mac_matches_the_relays_vector() {
        const SIGNS: &str = "vx_9SyYw9p7qPCxR8xHlDF8WlTOsR_LRA67SHhzpTHM";
        const BODY: &str = r#"{"pushId":"b2J5LXRlc3QtdmVjdG9yLTAx","sealed":"c2VhbGVkLWZvci10aGUtcGhvbmU","collapse":"9f08fd10","urgent":true,"at":1791806400}"#;
        const CHECKED: &str = "EK3ocbR_NCA7i3gJQAGEnXJe2mGFd74zqt190mk1a7s";
        assert_eq!(
            mac(&push_key_bytes(SIGNS).unwrap(), BODY.as_bytes()),
            CHECKED
        );
        // Signed with the key's text, the relay answers 401.
        assert_ne!(mac(SIGNS.as_bytes(), BODY.as_bytes()), CHECKED);
    }

    #[test]
    fn sealed_alerts_open_only_with_the_iphones_key() {
        let (secret, key) = iphone();
        let alert = br#"{"id":"j1","title":"Run swift test?"}"#;
        let sealed = seal(&key, alert).unwrap();
        let raw = b64().decode(&sealed).unwrap();
        // The encapsulated key, then the alert and ChaCha20-Poly1305's 16-byte tag.
        assert_eq!(raw.len(), 32 + alert.len() + 16);
        assert_eq!(
            opened(&secret, &sealed),
            json!({"id": "j1", "title": "Run swift test?"})
        );
        // A fresh seal each time, and another key can't open it.
        assert_ne!(seal(&key, alert).unwrap(), sealed);
        let (other, _) = iphone();
        let enc = <SealKem as hpke::Kem>::EncappedKey::from_bytes(&raw[..32]).unwrap();
        assert!(
            hpke::single_shot_open::<SealAead, SealKdf, SealKem>(
                &hpke::OpModeR::Base,
                &other,
                &enc,
                INFO,
                &raw[32..],
                b"",
            )
            .is_err()
        );
    }

    /// The longest alert obid makes, four-byte characters and quotes throughout, still fits the
    /// relay's `sealed`.
    #[test]
    fn the_longest_alert_fits_the_relay() {
        let (_, key) = iphone();
        let wide = "\u{1F600}\"\u{1}".repeat(400);
        let long_id = "x".repeat(200);
        let alert = Alert {
            collapse: collapse_id(&long_id),
            title: clipped(&wide, 100),
            body: clipped(&wide, BODY),
            thread: uuid::Uuid::new_v4().to_string(),
            category: "permissionRule".into(),
            job: Some("9f08fd10".into()),
            conversation: Some(uuid::Uuid::new_v4().to_string()),
            item: Some(format!(
                "shell-{}-{}",
                uuid::Uuid::new_v4(),
                uuid::Uuid::new_v4()
            )),
            urgent: true,
        };
        let sealed = seal(
            &key,
            sealed_alert(&alert, 1_800_000_000).to_string().as_bytes(),
        )
        .unwrap();
        assert!(sealed.len() <= SEALED, "{}", sealed.len());
        assert!(!alert.body.contains('\u{1}'));
        assert!(alert.collapse.len() <= ID);
    }

    /// The iPhone's check (docs/runner-api.md has these): `SEALED` is what obid sealed, opened on
    /// macOS 26 by CryptoKit's `HPKE.Recipient(privateKey:ciphersuite: .Curve25519_SHA256_ChachaPoly,
    /// info: "oby push v1", encapsulatedKey: first 32 bytes)` with `open(the rest)` to `ALERT`;
    /// `FROM_CRYPTOKIT` is what CryptoKit's `HPKE.Sender` sealed to the same key, opened here.
    #[test]
    fn cryptokit_opens_what_obid_seals() {
        // The test iPhone's X25519 private half (CryptoKit's rawRepresentation), base64url.
        const RECIPIENT: &str = "H8N3pC2swtsoc14zwnS2w5bHYEEqREpOIxv21rPygBw";
        const SEAL_KEY: &str = "IWlFcnjzHXlyLYTNMzTi8Jn5yrH6_QwEDMtloT3gQiY";
        const SEALED: &str = "yzzv3v2wiQKi22XvBmKaLVyZO7zv5rCO6ZKfOlkR2Ai6Tb_STHPyEjKJHTAkfAlwJmSBr2lqRetbeoz-6-nTUGP7YXs3rhK0cN2kVe4CY1AUJ9MJW1i6cjK4jQWwviFU3Y0neRoWsi6XkAMCQGGLYIL1ckm2uUr6FQfeZ2MAuHeq1pqlxHNPljCZ-XGpRQ73kif34Iw9guoNKB7djZSq9LpFtSbgQFNGBX3m5BCrSvUusYbbn5ELJTRPiXcGYwYdv9Dr5QCHQdPYaOzFbF3jFB98tZnDElz4R-68B5ZJZ0yAW_-sTqG-RsfPQd4z8r_NQfkoublPG-GL67p61NVyCJIpq4XJO_KWG0QVfQ";
        const ALERT: &str = r#"{"at":1800000000,"body":"Android push: swift test --filter Push","category":"permission","id":"5f0e8c1a3b2d4e6f8a9b0c1d2e3f4a5b","item":"9f08fd10-permission-p1","job":"9f08fd10","thread":"jobs","title":"Run swift test?"}"#;
        const FROM_CRYPTOKIT: &str =
            "5Cn_OepvWRMzD8YqLv_qFLzGHf9CXrCWM4XQ0HhPckgWAA_Y5Lh_AM-SZgzotrqXWko063ENCeZtOWw";
        let secret = SecretKey::from_bytes(&b64().decode(RECIPIENT).unwrap()).unwrap();
        assert_eq!(
            b64().encode(SealKem::sk_to_pk(&secret).to_bytes()),
            SEAL_KEY
        );
        assert_eq!(
            opened(&secret, SEALED),
            serde_json::from_str::<Value>(ALERT).unwrap()
        );
        assert_eq!(opened(&secret, FROM_CRYPTOKIT), json!({"id": "ck"}));
        // And what obid seals to that key now opens the same way.
        assert_eq!(
            opened(&secret, &seal(SEAL_KEY, ALERT.as_bytes()).unwrap()),
            serde_json::from_str::<Value>(ALERT).unwrap()
        );
    }

    fn inbox_item(id: &str, kind: &str, job: &str, triage: Option<&str>) -> Value {
        let mut item = json!({"id": id, "kind": kind, "job": job, "state": "open",
                              "title": format!("{kind} {id}"), "text": "First line.\nSecond.",
                              "conversation": null});
        if let Some(triage) = triage {
            item["triage"] = json!(triage);
        }
        item
    }

    #[test]
    fn the_relay_says_only_what_the_lean_rule_says() {
        let ids = |wanted: &[(String, Alert)]| -> Vec<(String, String, bool)> {
            wanted
                .iter()
                .map(|(_, a)| (a.collapse.clone(), a.category.clone(), a.urgent))
                .collect()
        };
        let mut asking = job("asks");
        asking.status = Status::Running;
        asking.permission = Some(permission());
        let mut failed = job("failed");
        failed.status = Status::Failed;
        failed.finished = Some(10);
        let mut done = job("done");
        done.status = Status::Done;
        done.finished = Some(20);
        done.summary = "\nFixed the push.\nMore".into();
        let mut ready = job("ready");
        ready.status = Status::Done;
        ready.finished = Some(30);
        ready.base = Some("dev".into());
        ready.commits = Some(2);
        ready.publish_error = Some("Couldn't push: the remote hung up.".into());
        let mut quiet = job("quiet");
        quiet.status = Status::Running;
        let mut stopped = job("stopped");
        stopped.status = Status::Stopped;
        let mut dismissed = job("dismissed");
        dismissed.status = Status::Failed;
        dismissed.dismissed = Some(1);
        let mut theirs = job("theirs");
        theirs.status = Status::Done;
        theirs.obi = Some(crate::job::ObiRef {
            correlation_id: "c".into(),
            from: "obi-ernesto".into(),
            from_owner: "ernesto".into(),
            request_id: "r".into(),
        });
        let mut always = job("always");
        always.status = Status::Running;
        always.permission = Some(crate::permissions::Permission {
            rule: Some("Bash(swift test:*)".into()),
            always: Some("Yes, and don't ask again for swift test".into()),
            ..permission()
        });
        let mut planning = job("planning");
        planning.status = Status::Running;
        planning.permission = Some(crate::permissions::Permission {
            tool: "ExitPlanMode".into(),
            ..permission()
        });
        let long = format!("shell-{}-p9", "c".repeat(80));
        let mut shell = inbox_item(&long, "permission", "", None);
        shell["conversation"] = json!("conv-1");
        let mut shell_rule = inbox_item("shell-conv-1-p8", "permission", "", None);
        shell_rule["options"] = json!(["Allow", "Always allow", "Deny"]);
        let mut later = inbox_item("later", "confirm", "", None);
        later["state"] = json!("later");
        let inbox = [
            shell,
            inbox_item("confirm-1", "confirm", "", None),
            inbox_item("start-1", "start", "", None),
            shell_rule,
            inbox_item("asks-permission-p1", "permission", "asks", None),
            inbox_item("watch-fyi", "watch", "", Some("fyi")),
            // Waiting for the model to sort it: not yet.
            inbox_item("watch-pending", "watch", "", Some("pending")),
            inbox_item("watch-unsorted", "watch", "", None),
            inbox_item("listen-1", "listen", "", Some("needs_you")),
            later,
        ];
        let wanted = wanted(
            &[
                asking, always, planning, failed, done, ready, quiet, stopped, dismissed, theirs,
            ],
            &inbox,
        );
        let digest = collapse_id(&long);
        assert!(digest.starts_with("h-") && digest.len() <= ID);
        assert_eq!(
            ids(&wanted),
            [
                ("asks", "permission", true),
                ("always", "permissionRule", true),
                ("planning", "plan", true),
                ("failed", "job", false),
                ("done", "job", false),
                ("ready", "ready", false),
                (digest.as_str(), "permission", true),
                ("confirm-1", "confirm", true),
                ("start-1", "start", true),
                ("shell-conv-1-p8", "permissionRule", true),
                ("listen-1", "inbox", true),
            ]
            .map(|(id, category, urgent)| (id.to_owned(), category.to_owned(), urgent))
        );
        let by_id = |id: &str| &wanted.iter().find(|(_, a)| a.collapse == id).unwrap().1;
        assert_eq!(
            *by_id("asks"),
            Alert {
                collapse: "asks".into(),
                title: "Run swift test?".into(),
                body: "Android push: swift test --filter Push".into(),
                thread: "jobs".into(),
                category: "permission".into(),
                job: Some("asks".into()),
                conversation: None,
                item: Some("asks-permission-p1".into()),
                urgent: true,
            }
        );
        assert_eq!(by_id("done").title, "Done: Android push");
        assert_eq!(by_id("done").body, "Fixed the push.");
        assert_eq!(by_id("ready").title, "Couldn't publish: Android push");
        let shell = by_id(&digest);
        assert_eq!(shell.item.as_deref(), Some(long.as_str()));
        assert_eq!(shell.conversation.as_deref(), Some("conv-1"));
        assert_eq!(shell.thread, "conv-1");
        assert_eq!(shell.body, "First line.");
        assert_eq!(by_id("listen-1").thread, "inbox");

        // What was said isn't said again; a gone urgent alert is settled in place, a gone result
        // just forgotten, and a new need on the same thing replaces the old alert.
        let (send, said) = told(wanted.clone(), &BTreeMap::new());
        assert_eq!(send.len(), wanted.len());
        assert!(told(wanted.clone(), &said).0.is_empty());
        let rest: Vec<(String, Alert)> = wanted
            .iter()
            .filter(|(_, a)| a.collapse != "asks" && a.collapse != "done")
            .cloned()
            .collect();
        let (send, now) = told(rest.clone(), &said);
        assert_eq!(
            send,
            vec![Alert {
                title: "Settled".into(),
                body: "Run swift test?".into(),
                category: "settled".into(),
                urgent: false,
                ..by_id("asks").clone()
            }]
        );
        assert!(!now.contains_key("asks") && !now.contains_key("done"));
        let mut again = wanted.clone();
        again[0].0 = "permission:p2".into();
        let (send, _) = told(again, &said);
        assert_eq!(
            ids(&send
                .iter()
                .map(|a| (String::new(), a.clone()))
                .collect::<Vec<_>>()),
            [("asks".to_owned(), "permission".to_owned(), true)]
        );
    }

    #[test]
    fn relay_registrations_are_private_and_go_with_their_device() {
        let home = std::env::temp_dir().join(format!("obid-push-relay-{}", std::process::id()));
        let (_, key) = iphone();
        let push = Push::open(&home, RELAY);
        let phone = relayed("a", Some("phone"), &key, "https://r.example");
        let lost = relayed("b", Some("lost"), &key, "https://r.example");
        push.keep_relayed(phone.clone()).unwrap();
        push.keep_relayed(lost.clone()).unwrap();
        // Each device's push key is obid's own: out of every answer and log line.
        let said =
            crate::secrets::known().redact(&format!("x {} y {} z", phone.push_key, lost.push_key));
        assert!(
            !said.contains(&phone.push_key) && !said.contains(&lost.push_key),
            "{said}"
        );
        // The phone's new registration replaces its old one; another device handing over the
        // same push id replaces nothing of the phone's.
        let newer = relayed("c", Some("phone"), &key, "https://r.example");
        push.keep_relayed(newer.clone()).unwrap();
        push.keep_relayed(relayed("c", Some("lost"), &key, "https://r.example"))
            .unwrap();
        push.forget("lost");
        let file = home.join("push/relay.json");
        let saved: Vec<Relayed> = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(saved, vec![newer.clone()]);
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(*Push::open(&home, RELAY).relayed.lock().unwrap(), saved);
        // Learned again when obid starts; never in Debug.
        crate::secrets::known().forget(&newer.secret_name());
        Push::open(&home, RELAY);
        let said = crate::secrets::known().redact(&format!("x {} y", newer.push_key));
        assert!(!said.contains(&newer.push_key), "{said}");
        assert!(!format!("{newer:?}").contains(&newer.push_key));
        std::fs::remove_dir_all(&home).unwrap();
    }

    /// What the test relay heard: each push's MAC and raw body.
    type Heard = Arc<Mutex<Vec<(String, Vec<u8>)>>>;

    /// What the test relay answers next, oldest first; `202` once it's empty.
    type Answers = Arc<Mutex<std::collections::VecDeque<u16>>>;

    /// A relay of the test's own: each push's MAC and body; `410` for the push id `gone`, else
    /// the next of its answers (with `Retry-After: 0`).
    async fn relay_stub() -> (String, Heard, Answers) {
        let heard: Heard = Arc::default();
        let answers: Answers = Arc::default();
        let (kept, next) = (heard.clone(), answers.clone());
        let app = axum::Router::new().route(
            "/v1/push",
            axum::routing::post(move |headers: axum::http::HeaderMap, body: Bytes| {
                let (kept, next) = (kept.clone(), next.clone());
                async move {
                    let given: Value = serde_json::from_slice(&body).unwrap();
                    let mac = headers["oby-push-mac"].to_str().unwrap().to_owned();
                    kept.lock().unwrap().push((mac, body.to_vec()));
                    let status = if given["pushId"] == "gone" {
                        410
                    } else {
                        next.lock().unwrap().pop_front().unwrap_or(202)
                    };
                    (
                        StatusCode::from_u16(status).unwrap(),
                        [("retry-after", "0")],
                        axum::Json(json!({"error": "a body obid doesn't read"})),
                    )
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        (relay, heard, answers)
    }

    fn turn(conversation: &str, id: &str, who: &str, text: &str) -> Event {
        Event {
            name: "turn",
            data: json!({"id": id, "who": who, "text": text, "conversation": conversation,
                         "at": "2026-10-23T12:00:00Z", "jobs": []}),
        }
    }

    #[tokio::test]
    async fn each_lean_case_is_one_sealed_relay_call() {
        let home = std::env::temp_dir().join(format!("obid-push-relayed-{}", std::process::id()));
        let scratch = home.join("tmp");
        let (relay, heard, _) = relay_stub().await;
        let (secret, key) = iphone();
        let push = Push::open(&home, &relay);
        let phone = relayed("phone", Some("iphone"), &key, &relay);
        push.keep_relayed(phone.clone()).unwrap();
        let paired: HashSet<String> = ["iphone".to_owned()].into();
        // The alerts each look sent, opened, after checking each call's MAC, body, `at` and
        // one-send `id`; each with the call's `collapse` in place of those two.
        let ids = Mutex::new(HashSet::new());
        let sent = |heard: &Heard| -> Vec<(Value, bool)> {
            heard
                .lock()
                .unwrap()
                .drain(..)
                .map(|(given_mac, body)| {
                    let given: Value = serde_json::from_slice(&body).unwrap();
                    let signs = key_of(given["pushId"].as_str().unwrap());
                    assert_eq!(given_mac, mac(&push_key_bytes(&signs).unwrap(), &body));
                    let keys: Vec<&str> = given
                        .as_object()
                        .unwrap()
                        .keys()
                        .map(String::as_str)
                        .collect();
                    assert_eq!(keys, ["at", "collapse", "pushId", "sealed", "urgent"]);
                    let now = obi_protocol::time::now();
                    let at = given["at"].as_i64().unwrap();
                    assert!((now - 60..=now).contains(&at), "{at}");
                    let mut alert = opened(&secret, given["sealed"].as_str().unwrap());
                    assert_eq!(alert["at"], at);
                    let id = alert["id"].as_str().unwrap().to_owned();
                    assert!(id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()));
                    assert!(ids.lock().unwrap().insert(id), "an id sent twice");
                    let fields = alert.as_object_mut().unwrap();
                    fields.remove("id");
                    fields.remove("at");
                    fields.insert("collapse".into(), given["collapse"].clone());
                    (alert, given["urgent"].as_bool().unwrap())
                })
                .collect()
        };
        let mut j = job("j1");
        j.status = Status::Running;
        let look = |jobs: Vec<Job>, inbox: Vec<Value>, paired: HashSet<String>| {
            let push = &push;
            let scratch = scratch.clone();
            async move { push.look(&jobs, &inbox, &paired, &scratch).await }
        };

        // The first look is no news; a running job never is.
        look(vec![j.clone()], vec![], paired.clone()).await;
        assert!(sent(&heard).is_empty());
        // Its agent asks: one urgent alert.
        j.permission = Some(permission());
        look(vec![j.clone()], vec![], paired.clone()).await;
        let got = sent(&heard);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0["category"], "permission");
        assert_eq!(got[0].0["item"], "j1-permission-p1");
        assert!(got[0].1);
        // The same again: nothing. Answered: one "Settled", not urgent.
        look(vec![j.clone()], vec![], paired.clone()).await;
        assert!(sent(&heard).is_empty());
        j.permission = None;
        look(vec![j.clone()], vec![], paired.clone()).await;
        let got = sent(&heard);
        assert_eq!(got.len(), 1);
        assert_eq!(
            (got[0].0["title"].as_str(), got[0].0["body"].as_str()),
            (Some("Settled"), Some("Run swift test?"))
        );
        assert!(!got[0].1);
        // It ends: one alert with its result, not urgent; never again.
        j.status = Status::Done;
        j.finished = Some(100);
        j.summary = "Fixed the push.".into();
        look(vec![j.clone()], vec![], paired.clone()).await;
        let got = sent(&heard);
        assert_eq!(got.len(), 1);
        assert_eq!(
            got[0].0,
            json!({"collapse": "j1", "title": "Done: Android push", "body": "Fixed the push.",
                                     "thread": "jobs", "category": "job", "job": "j1"})
        );
        assert!(!got[0].1);
        look(vec![j.clone()], vec![], paired.clone()).await;
        assert!(sent(&heard).is_empty());
        // The inbox: FYI, unsorted and still being sorted (`pending`) say nothing; once sorted
        // needs_you, it says so once.
        let fyi = vec![
            inbox_item("w1", "watch", "", Some("fyi")),
            inbox_item("w2", "watch", "", None),
            inbox_item("w3", "watch", "", Some("pending")),
        ];
        look(vec![j.clone()], fyi.clone(), paired.clone()).await;
        assert!(sent(&heard).is_empty());
        let mut needs = fyi.clone();
        needs[2]["triage"] = json!("needs_you");
        look(vec![j.clone()], needs.clone(), paired.clone()).await;
        let got = sent(&heard);
        assert_eq!(got.len(), 1);
        assert_eq!((got[0].0["item"].as_str(), got[0].1), (Some("w3"), true));

        // Oby's message: once, while no paired device follows the events.
        assert!(push.heard(&turn("c1", "t1", "oby", "Morning. Two jobs\nneed you.")));
        assert!(!push.heard(&Event {
            name: "step",
            data: json!({})
        }));
        look(vec![j.clone()], needs.clone(), paired.clone()).await;
        let got = sent(&heard);
        assert_eq!(got.len(), 1);
        assert_eq!(
            got[0].0,
            json!({"collapse": "c1", "title": "Oby", "body": "Morning. Two jobs need you.",
                                     "thread": "c1", "category": "message", "conversation": "c1"})
        );
        // The same turn sent again (its jobs changed) isn't news, nor an older one.
        push.heard(&turn("c1", "t1", "oby", "Morning. Two jobs\nneed you."));
        let mut older = turn("c1", "t0", "oby", "Yesterday.");
        older.data["at"] = json!("2026-10-22T12:00:00Z");
        push.heard(&older);
        look(vec![j.clone()], needs.clone(), paired.clone()).await;
        assert!(sent(&heard).is_empty());
        // A phone with Oby open: nothing. A job's end turn and a routine's run: nothing.
        let following = push.followed();
        push.heard(&turn("c1", "t2", "oby", "Anything else?"));
        look(vec![j.clone()], needs.clone(), paired.clone()).await;
        assert!(sent(&heard).is_empty());
        drop(following);
        let mut ended = turn("c1", "t3", "oby", "j1 is done.");
        ended.data["ended"] = json!(true);
        push.heard(&ended);
        let mut routine = turn("c1", "t4", "oby", "Ran the nightly review.");
        routine.data["routine"] = json!({"id": "r1"});
        push.heard(&routine);
        // An answer to the owner's own words while they're there: nothing.
        push.heard(&turn("c2", "u1", "user", "How are the jobs?"));
        push.heard(&turn("c2", "t5", "oby", "All green."));
        look(vec![j.clone()], needs.clone(), paired.clone()).await;
        assert!(sent(&heard).is_empty());

        // A device no longer paired is sent nothing.
        push.heard(&turn("c3", "t6", "oby", "Check-in."));
        look(vec![j.clone()], needs.clone(), HashSet::new()).await;
        assert!(sent(&heard).is_empty());
        // A relay that answers 410 drops its registration; the others still get theirs.
        push.keep_relayed(relayed("gone", None, &key, &relay))
            .unwrap();
        look(vec![j.clone()], vec![], paired.clone()).await;
        let got = sent(&heard);
        assert_eq!(got.len(), 2, "{got:?}");
        assert!(
            got.iter()
                .all(|(alert, urgent)| alert["category"] == "settled" && !urgent)
        );
        let kept: Vec<Relayed> =
            serde_json::from_slice(&std::fs::read(home.join("push/relay.json")).unwrap()).unwrap();
        assert_eq!(kept, vec![phone]);
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[tokio::test]
    async fn a_secret_in_an_alert_sends_nothing() {
        let home = std::env::temp_dir().join(format!("obid-push-secret-{}", std::process::id()));
        let (relay, heard, _) = relay_stub().await;
        let (_, key) = iphone();
        let push = Push::open(&home, &relay);
        push.keep_relayed(relayed("phone", None, &key, &relay))
            .unwrap();
        let mut j = job("j1");
        j.status = Status::Running;
        let scratch = home.join("tmp");
        push.look(std::slice::from_ref(&j), &[], &HashSet::new(), &scratch)
            .await;
        j.status = Status::Failed;
        // An AWS key id, put together here so no scanner takes the test for a leak.
        j.reason = Some(format!("The key {}{} leaked.", "AKIA", "QWERTYUIOPASDFGH"));
        push.look(std::slice::from_ref(&j), &[], &HashSet::new(), &scratch)
            .await;
        assert!(heard.lock().unwrap().is_empty());
        std::fs::remove_dir_all(&home).unwrap();
    }

    /// What the relay does with a push decides what obid says next: `5xx` and `429` are tried
    /// once more, an ask no phone took is said again at the next look, and the third `401` in a
    /// row drops the registration. A registration made with another control plane is skipped.
    #[tokio::test]
    async fn an_ask_the_relay_didnt_take_is_said_again() {
        let home = std::env::temp_dir().join(format!("obid-push-retry-{}", std::process::id()));
        let scratch = home.join("tmp");
        let (relay, heard, answers) = relay_stub().await;
        let (_, key) = iphone();
        let push = Push::open(&home, &relay);
        push.keep_relayed(relayed("phone", None, &key, &relay))
            .unwrap();
        push.keep_relayed(relayed("old", None, &key, "https://old.example"))
            .unwrap();
        let mut j = job("j1");
        j.status = Status::Running;
        let none = HashSet::new();
        let look = |job: Job| {
            let (push, none, scratch) = (&push, &none, &scratch);
            async move { push.look(&[job], &[], none, scratch).await }
        };
        let calls = |heard: &Heard| -> Vec<Value> {
            heard
                .lock()
                .unwrap()
                .drain(..)
                .map(|(_, body)| serde_json::from_slice(&body).unwrap())
                .collect()
        };
        let answer = |codes: &[u16]| answers.lock().unwrap().extend(codes);
        look(j.clone()).await;
        // Down twice: tried once more, the same send, then not taken.
        j.permission = Some(permission());
        answer(&[503, 503]);
        look(j.clone()).await;
        let got = calls(&heard);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0], got[1]);
        assert!(got.iter().all(|c| c["pushId"] == "phone"));
        // So the next look says it again, and then it's said.
        look(j.clone()).await;
        assert_eq!(calls(&heard).len(), 1);
        look(j.clone()).await;
        assert!(calls(&heard).is_empty());
        // Too many: tried once more, and taken.
        j.permission = None;
        answer(&[429]);
        look(j.clone()).await;
        let got = calls(&heard);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0], got[1]);
        look(j.clone()).await;
        assert!(calls(&heard).is_empty());
        // 401 isn't tried again; the third in a row drops the registration.
        j.permission = Some(crate::permissions::Permission {
            id: "p2".into(),
            ..permission()
        });
        answer(&[401, 401, 401]);
        for _ in 0..3 {
            look(j.clone()).await;
            assert_eq!(calls(&heard).len(), 1);
        }
        let kept: Vec<Relayed> =
            serde_json::from_slice(&std::fs::read(home.join("push/relay.json")).unwrap()).unwrap();
        assert_eq!(
            kept.iter().map(|r| r.push_id.as_str()).collect::<Vec<_>>(),
            ["old"]
        );
        look(j.clone()).await;
        assert!(calls(&heard).is_empty());
        std::fs::remove_dir_all(&home).unwrap();
    }
}
