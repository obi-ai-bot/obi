//! obid's link to its Sphere: membership and keys, the Obi-to-Obi client, exchanges, the
//! `obiRequest` inbox item, remembered decisions, and the reply to a review another Obi asked for
//! with its publish gate (docs/runner-api.md, "obid only"; spec `protocol.md`, `identity.md`,
//! `sphere-api.md`).
//!
//! What crosses in from another Obi is a signed, typed action, checked against the spec before
//! anything acts on it (protocol.md section 10). It may become only what section 11 allows: an inbox
//! item, or work a remembered decision covers, and then only the typed reply to that action. Its
//! text is data: it never reaches a prompt, an inbox item's title or text, or a log line.
//!
//! Three tasks run once obid has joined: the follower (deliveries, long-polled), the sender (each
//! exchange's replies in order, again after a failure) and the clock (requests that expire).

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::http::StatusCode;
use obi_protocol::client::{Client, ClientError, Delivery};
use obi_protocol::keys::Keypair;
use obi_protocol::{DirectoryKey, Keys, time};
use serde_json::{Map, Value, json};
use tokio::sync::{Notify, watch};

use super::answering;
use super::channel;
use super::decisions::{self, Decision, Decisions};
use super::exchange::{Exchange, Exchanges, Message};
use super::inbox::{self, Inbox, Item};
use super::membership::{Files, Membership};
use super::sharing::{self, Rule, Sharing};
use crate::api::ApiError;
use crate::config::Config;
use crate::events::Events;
use crate::job::Job;
use crate::jobs::{Jobs, ObiReview};
use crate::sandbox::Sandbox;
use crate::scan;

/// How long a reply obid sends lives, at least (runner-api.md, "Expiry of what obid sends").
const REPLY_LIFETIME: i64 = 3_600;
/// A new token when the one held has less than this left.
const TOKEN_MARGIN: i64 = 60;
/// How long the Sphere may hold a deliveries call.
const POLL_WAIT: u32 = 25;
/// How often the directory is read again while following.
const DIRECTORY_EVERY: i64 = 60;
/// The longest a reply waits to be sent again after a failure.
const BACKOFF_MAX: Duration = Duration::from_secs(30);
/// What obid's card says it is.
const OBID_VERSION: &str = env!("CARGO_PKG_VERSION");
/// The scopes a delegation must grant for obid to follow and answer.
const NEEDED_SCOPES: [&str; 2] = ["receive", "reply"];
/// The most model runs answering questions by themselves at once, across every sender.
const ANSWER_RUNS: usize = 2;
/// The most dropped message ids obid remembers, to acknowledge them again without a second look.
const DROPPED_MAX: usize = 10_000;

/// One member of the directory, once its card passed the checks (identity.md 2.2).
#[derive(Debug, Clone)]
struct Member {
    owner: String,
    active: bool,
    accepts: Vec<String>,
    /// Its runner status, when the directory shows it to this Obi's owner (protocol.md section
    /// 14), signature checked.
    runner: Option<Value>,
}

#[derive(Debug, Clone, Default)]
struct Directory {
    members: HashMap<String, Member>,
    keys: Keys,
}

struct State {
    key: Option<Arc<Keypair>>,
    membership: Option<Membership>,
    delegation: Option<String>,
    client: Option<Client>,
    /// The access token and when it expires.
    token: Option<(String, i64)>,
    directory: Directory,
    directory_read: i64,
    last_poll: Option<i64>,
    last_error: Option<String>,
    exchanges: HashMap<String, Exchange>,
    inbox: HashMap<String, Item>,
    decisions: Vec<Decision>,
    /// The owner's sharing rules and the per-sender limits.
    sharing: Sharing,
    /// When each sender's owner's questions started an answer the Obi wrote by itself, within the
    /// last hour: the self-answer limit (protocol.md section 11, "Rate limits").
    self_answers: HashMap<String, Vec<i64>>,
    /// The same, every sender's together: the overall hourly cap.
    all_self_answers: Vec<i64>,
    /// Every envelope id obid has handled: the messages of its exchanges, and the ones it dropped.
    seen: HashSet<String>,
    dropped: Vec<String>,
}

/// Whether a runner status is `obi`'s, signed with its current key (protocol.md section 14).
fn runner_signed(status: &Value, keys: &obi_protocol::Keys, obi: &str) -> bool {
    let Some(key) = status["key_id"].as_str().and_then(|k| keys.get(k)) else {
        return false;
    };
    if key.obi != obi || key.valid_until_seq.is_some() || status["obi"] != obi {
        return false;
    }
    let mut unsigned = status.clone();
    let signature = unsigned.as_object_mut().and_then(|m| m.remove("signature"));
    let Some(signature) = signature.as_ref().and_then(Value::as_str) else {
        return false;
    };
    let Ok(canonical) = obi_protocol::jcs::canonical_bytes(&unsigned) else {
        return false;
    };
    obi_protocol::schema::is_valid("runner-status", status)
        && obi_protocol::keys::verify_bytes(
            &key.public_key,
            &[RUNNER_PREFIX, &canonical].concat(),
            signature,
        )
}

/// What a runner status's signature starts with.
const RUNNER_PREFIX: &[u8] = b"obi/0.1 runner_status\n";

/// The chain as this Obi knows it for itself (spec sphere-api.md 7.1, "No rollback, no fork"), in
/// `home/sphere/chain.json` (0600): the last head it verified, and the seq and hash the Sphere
/// answered for each of its own sends. A chain that is shorter than that head, has another hash at
/// it, or lacks one of these sends at its seq is a rollback or a fork.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
struct ChainKept {
    head: Option<(u64, String)>,
    /// By envelope id: (seq, hash).
    sends: std::collections::BTreeMap<String, (u64, String)>,
}

impl ChainKept {
    fn path(home: &std::path::Path) -> std::path::PathBuf {
        home.join("sphere").join("chain.json")
    }

    fn open(home: &std::path::Path) -> ChainKept {
        std::fs::read(Self::path(home))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    fn save(&self, home: &std::path::Path) {
        let path = Self::path(home);
        let saved = path
            .parent()
            .map_or(Ok(()), crate::store::make_private_dir)
            .and_then(|()| {
                crate::store::write_private(&path, &serde_json::to_vec(self).unwrap_or_default())
            });
        if let Err(e) = saved {
            tracing::error!("can't keep what obid saw of the chain: {e}");
        }
    }

    /// What's wrong with `entries` (the whole chain, from seq 1) against what this Obi saw: a
    /// `rollback`, a `fork`, or nothing.
    fn problem(&self, entries: &[Value]) -> Option<&'static str> {
        let at = |seq: u64| entries.get((seq as usize).wrapping_sub(1));
        if let Some((seq, hash)) = &self.head {
            match at(*seq) {
                None => return Some("rollback"),
                Some(e) if e["hash"] != hash.as_str() => return Some("fork"),
                _ => {}
            }
        }
        for (id, (seq, hash)) in &self.sends {
            let ok = at(*seq)
                .is_some_and(|e| e["hash"] == hash.as_str() && e["envelope"]["id"] == id.as_str());
            if !ok {
                return Some("fork");
            }
        }
        None
    }
}

impl Link {
    /// Keeps the seq and hash the Sphere answered for a send of this Obi's.
    fn keep_receipt(&self, sent: &obi_protocol::client::Sent) {
        let mut kept = self.chain.lock().unwrap();
        kept.sends
            .insert(sent.id.clone(), (sent.seq, sent.entry_hash.clone()));
        kept.save(&self.config.home);
    }
}

/// An audit entry as typed fields only: never a text the message carries.
fn audit_entry(entry: &Value) -> Value {
    let e = &entry["envelope"];
    let b = &e["body"];
    let mut out = json!({"seq": entry["seq"], "recordedAt": entry["recorded_at"], "type": e["type"], "from": e["from"],
                         "to": e["to"], "correlationId": e["correlation_id"]});
    for (key, value) in [
        ("repo", &b["repo"]),
        ("reason", &b["reason"]),
        ("state", &b["state"]),
        ("outcome", &b["outcome"]),
        ("costCents", &b["cost_cents"]),
        (
            "grant",
            if b["grant"].is_null() {
                &b["account"]["grant"]
            } else {
                &b["grant"]
            },
        ),
        ("share", &b["share"]),
        ("usedCents", &b["used_cents"]),
        ("limitCents", &b["limit_cents"]),
    ] {
        if !value.is_null() {
            out[key] = value.clone();
        }
    }
    out
}

/// The names the Sphere's secrets are known by in `crate::secrets`.
const OBI_KEY_SECRET: &str = "obi-key";
const DELEGATION_SECRET: &str = "sphere-delegation";
const SPHERE_TOKEN_SECRET: &str = "sphere-token";

/// The Obi key, as obid's log layer takes it out: its hex text (`keys/obi.key`) and its 32
/// bytes, each in every common encoding (crate::secrets).
fn learn_key(key: &Keypair) {
    let seed = key.seed();
    let text = hex::encode(seed);
    crate::secrets::known().learn_forms(OBI_KEY_SECRET, &[text.as_bytes(), &seed]);
}

/// The link. One per obid; one Sphere per obid in this version.
pub struct Link {
    config: Config,
    files: Files,
    exchanges: Exchanges,
    inbox: Inbox,
    decisions: Decisions,
    sharing: sharing::Kept,
    /// The owner keys this Obi trusts, pinned the first time it saw each (crate::sphere::pins).
    pins: super::pins::Pins,
    /// What the quick model said of the inbox's items, and when it was asked (crate::triage).
    pub(crate) triage: crate::triage::Kept,
    /// What the model that answers a question by itself runs in: the job sandbox.
    sandbox: Result<Sandbox, String>,
    /// At most this many of those runs at once, whoever asked.
    answering: tokio::sync::Semaphore,
    jobs: Arc<Jobs>,
    events: Events,
    state: Mutex<State>,
    /// Woken when a reply waits to be sent.
    outbox: Notify,
    /// One send at a time, so each exchange's replies go in order.
    sending: tokio::sync::Mutex<()>,
    /// One save of an item or exchange at a time, so what reaches the disk and the apps never goes
    /// back to an older copy.
    saving: Mutex<()>,
    /// One token exchange at a time.
    tokening: tokio::sync::Mutex<()>,
    /// One key, card or join call at a time.
    joining: tokio::sync::Mutex<()>,
    /// One pass over the shares of the owner's API accounts at a time (crate::sphere::shares).
    shares_sync: tokio::sync::Mutex<()>,
    /// The chain as this Obi knows it for itself: no rollback, no fork (crate::sphere::link::ChainKept).
    chain: Mutex<ChainKept>,
    following: AtomicBool,
    /// Whether the sender and the clock run: only while obid is in a Sphere.
    sender_running: AtomicBool,
    stopping: watch::Receiver<bool>,
    /// Teammates' jobs on this Mac (crate::sphere::hosting).
    pub(super) hosting: super::hosting::Hosting,
    setup: super::hosting::Setup,
    /// Sentry, when obid has it (crate::sentry): what a Sentry offer's start reads.
    sentry: std::sync::OnceLock<Arc<crate::sentry::Sentry>>,
    /// The phone relay (crate::relay): told at once when this Obi's membership is revoked.
    relay: std::sync::OnceLock<Arc<crate::relay::Relay>>,
}

fn api(status: StatusCode, message: impl Into<String>) -> ApiError {
    ApiError::new(status, message)
}

/// A client error as the API answers it: `502` with the Sphere's code and message, `504` when it
/// couldn't be reached.
fn from_client(error: &ClientError) -> ApiError {
    match error {
        ClientError::Unreachable(_) => api(StatusCode::GATEWAY_TIMEOUT, error.to_string()),
        _ => api(StatusCode::BAD_GATEWAY, error.to_string()),
    }
}

fn new_uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Resolves once obid is stopping.
pub(super) async fn stopped(mut stopping: watch::Receiver<bool>) {
    while !*stopping.borrow() {
        if stopping.changed().await.is_err() {
            std::future::pending::<()>().await;
        }
    }
}

/// A Sphere's base URL: `https://`, a host and maybe a port, nothing after it. Plain `http://`
/// only on this machine (a local Sphere, the e2e harness's), so the delegation and every token
/// cross the network encrypted.
fn is_base_url(url: &str) -> bool {
    let (rest, plain) = match url.strip_prefix("https://") {
        Some(rest) => (rest, false),
        None => match url.strip_prefix("http://") {
            Some(rest) => (rest, true),
            None => return false,
        },
    };
    let valid = !rest.is_empty()
        && rest.len() <= 255
        && rest
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':' | b'[' | b']'));
    valid && (!plain || is_loopback(rest))
}

/// `host[:port]` names this machine: `localhost`, `127.x.x.x` or `[::1]`.
fn is_loopback(authority: &str) -> bool {
    let host = match authority.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or(""),
        None => authority.split(':').next().unwrap_or(""),
    };
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
}

/// What `POST /v1/obid/sphere/join` takes as `invitation`.
const INVITATION_SHAPE: &str = "invitation is {\"id\", \"secret\"}, and {\"signin\": {\"state\", \"code\"}} for one limited to a domain.";

/// An id the Sphere makes (an invitation id) or a secret: what may go in a path or a body.
fn is_token_text(text: &str) -> bool {
    (1..=256).contains(&text.len())
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~'))
}

fn is_slug(text: &str) -> bool {
    obi_protocol::schema::is_valid("common#/$defs/slug", &json!(text))
}

/// Reads exactly the keys `allowed` from a JSON object body: `422` for anything else.
fn object(body: &[u8], allowed: &[&str]) -> Result<Map<String, Value>, ApiError> {
    let value: Value = serde_json::from_slice(body)
        .map_err(|e| api(StatusCode::BAD_REQUEST, format!("The body isn't JSON: {e}")))?;
    let Value::Object(map) = value else {
        return Err(api(
            StatusCode::UNPROCESSABLE_ENTITY,
            "The body is a JSON object.",
        ));
    };
    if let Some(unknown) = map.keys().find(|k| !allowed.contains(&k.as_str())) {
        return Err(api(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("{unknown} isn't a field this endpoint takes."),
        ));
    }
    Ok(map)
}

fn text_field<'a>(map: &'a Map<String, Value>, key: &str) -> Result<&'a str, ApiError> {
    map.get(key).and_then(Value::as_str).ok_or_else(|| {
        api(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("{key} is a string, and it's required."),
        )
    })
}

/// A later time as the inbox takes it: a protocol timestamp, with or without fractional seconds.
fn parse_later(text: &str) -> Option<i64> {
    if let Some(t) = time::parse(text) {
        return Some(t);
    }
    // 2026-10-10T10:12:00.000Z
    let (whole, rest) = text.split_once('.')?;
    let digits = rest.strip_suffix('Z')?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    time::parse(&format!("{whole}Z"))
}

/// What needs the owner first (crate::triage, with what waits for the model), then FYI, then
/// ignore; each in the order they came, also within one second (Item::arrival_order).
fn needs_you_first(items: &mut [impl std::borrow::Borrow<Item>], sorts: &crate::triage::Sorts) {
    items.sort_by_cached_key(|i| {
        let i: &Item = i.borrow();
        let rank = crate::triage::rank(sorts.get(i));
        (rank, i.arrival_order(), i.id.clone())
    });
}

impl Link {
    /// Opens what obid keeps of its Sphere, its exchanges, inbox and decisions.
    pub fn open(
        config: Config,
        jobs: Arc<Jobs>,
        events: Events,
        stopping: watch::Receiver<bool>,
    ) -> std::io::Result<Arc<Link>> {
        let files = Files::new(&config.home);
        let setup_config = config.clone();
        let key = files.load_key()?.map(Arc::new);
        let membership = files.load_membership();
        let delegation = files.load_delegation();
        // What obid's log layer takes out of plug-ins' lines (crate::logs).
        let secrets = crate::secrets::known();
        if let Some(key) = &key {
            learn_key(key);
        }
        if let Some(delegation) = &delegation {
            secrets.learn(DELEGATION_SECRET, delegation);
        }
        let exchanges = Exchanges::open(&config.home)?;
        let inbox = Inbox::open(&config.home)?;
        let decisions = Decisions::open(&config.home);
        let sharing = sharing::Kept::open(&config.home);
        let pins = super::pins::Pins::open(&config.home);
        let triage = crate::triage::Kept::open(&config.home);
        let chain = ChainKept::open(&config.home);
        // Nothing of a guest job a crash left behind: obid starts with none running.
        super::hosting::clean_leftovers(&config.home);
        let sandbox = std::env::current_exe()
            .map_err(|e| format!("obid can't find its own executable: {e}"))
            .and_then(|obid| Sandbox::detect(&obid));
        let mut seen = HashSet::new();
        let mut by_id = HashMap::new();
        for exchange in exchanges.load_all() {
            seen.extend(exchange.envelope_ids().map(str::to_owned));
            by_id.insert(exchange.correlation_id.clone(), exchange);
        }
        let now = time::now();
        let items = inbox
            .load_all()
            .into_iter()
            .map(|mut i| {
                // A permission waited on an agent that ended with obid: its job's agent asks again
                // when it runs, so the old item is done by itself.
                if matches!(i.kind.as_str(), "permission" | "plan") && i.done.is_none() {
                    i.done = Some(now);
                    if let Err(e) = inbox.save(&i) {
                        tracing::error!("can't keep inbox item {}: {e}", i.id);
                    }
                }
                (i.id.clone(), i)
            })
            .collect();
        let client = membership
            .as_ref()
            .and_then(|m| Client::new(&m.url, &m.sphere).ok());
        let state = State {
            key,
            membership,
            delegation,
            client,
            token: None,
            directory: Directory::default(),
            directory_read: 0,
            last_poll: None,
            last_error: None,
            exchanges: by_id,
            inbox: items,
            decisions: decisions.load(),
            sharing: sharing.load(),
            self_answers: HashMap::new(),
            all_self_answers: Vec::new(),
            seen,
            dropped: Vec::new(),
        };
        let link = Arc::new(Link {
            config,
            files,
            exchanges,
            inbox,
            decisions,
            sharing,
            pins,
            triage,
            sandbox,
            answering: tokio::sync::Semaphore::new(ANSWER_RUNS),
            jobs,
            events,
            state: Mutex::new(state),
            outbox: Notify::new(),
            sending: tokio::sync::Mutex::new(()),
            saving: Mutex::new(()),
            tokening: tokio::sync::Mutex::new(()),
            joining: tokio::sync::Mutex::new(()),
            shares_sync: tokio::sync::Mutex::new(()),
            chain: Mutex::new(chain),
            following: AtomicBool::new(false),
            sender_running: AtomicBool::new(false),
            stopping,
            hosting: super::hosting::Hosting::default(),
            setup: super::hosting::Setup::from(&setup_config),
            sentry: std::sync::OnceLock::new(),
            relay: std::sync::OnceLock::new(),
        });
        // The inbox hears of the permissions jobs wait on. Jobs tells it with none of its own
        // locks held, and never while this Link's state is locked (only `start_obi_review` is
        // called under it, and an Obi-to-Obi review never asks the owner).
        link.jobs.set_link(Arc::downgrade(&link));
        let hook = Arc::downgrade(&link);
        link.jobs.on_permission(Arc::new(move |note| {
            if let Some(link) = hook.upgrade() {
                link.permission_note(note);
            }
        }));
        let hook = Arc::downgrade(&link);
        link.jobs.on_confirm(Arc::new(move |item| {
            if let Some(link) = hook.upgrade() {
                link.add_confirm_once(item);
            }
        }));
        let hook = Arc::downgrade(&link);
        link.jobs.on_review_end(Arc::new(move |job, done| {
            let link = hook.upgrade();
            Box::pin(async move {
                if let Some(link) = link {
                    link.review_ended(job, done).await;
                }
            })
        }));
        Ok(link)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Starts following the Sphere, and the sender and the clock, when obid has joined one.
    pub fn start(self: &Arc<Self>) {
        self.reconcile();
        if self.is_joined() {
            self.follow();
            self.start_sender();
        }
        if self.mac().on {
            super::hosting::fetch_image_soon(self);
        }
    }

    /// Whether obid is in a Sphere now.
    fn is_joined(&self) -> bool {
        self.lock()
            .membership
            .as_ref()
            .is_some_and(|m| m.state == "joined")
    }

    /// After a restart: an accepted request whose job has ended without a reply gets its failed
    /// result, and one whose job is gone too. A question the Obi was answering by itself goes to
    /// the owner: its run ended with obid.
    fn reconcile(self: &Arc<Self>) {
        // What a run cut short left: its folder, with a copied login in it.
        let _ = std::fs::remove_dir_all(self.config.home.join("answers"));
        {
            // The self-answer limits count the last hour across restarts: every run obid took
            // on, whatever it ended in (an answer, the owner's inbox, `busy`).
            let mut state = self.lock();
            let since = time::now() - 3600;
            let started: Vec<(String, i64)> = state
                .exchanges
                .values()
                .filter_map(|e| {
                    e.self_answered
                        .filter(|at| *at > since)
                        .map(|at| (e.peer_owner.clone().unwrap_or_default(), at))
                })
                .collect();
            for (owner, at) in started {
                state.self_answers.entry(owner).or_default().push(at);
                state.all_self_answers.push(at);
            }
        }
        let answering: Vec<String> = self
            .lock()
            .exchanges
            .values()
            .filter(|e| e.direction == "incoming" && e.state == "answering")
            .map(|e| e.correlation_id.clone())
            .collect();
        for cid in answering {
            self.to_owner(&cid);
        }
        let waiting: Vec<(String, Option<String>)> = self
            .lock()
            .exchanges
            .values()
            .filter(|e| e.direction == "incoming" && e.state == "accepted" && !e.ended())
            .map(|e| (e.correlation_id.clone(), e.job.clone()))
            .collect();
        for (cid, job) in waiting {
            let ended = match job.as_deref().and_then(|id| self.jobs.get(id)) {
                Some(job) => !job.status.is_active(),
                None => true,
            };
            if ended {
                let link = self.clone();
                tokio::spawn(async move { link.reply_failed(&cid, None).await });
            }
        }
    }

    /// A permission waits for the owner: its item, which settles any other open item of the job's
    /// (one open item per job). Or one stopped waiting: its item is done, with the owner's answer
    /// or none.
    fn permission_note(&self, note: crate::jobs::PermissionNote) {
        use crate::jobs::PermissionNote;
        let now = time::now();
        let mut changed = Vec::new();
        {
            let mut state = self.lock();
            match note {
                PermissionNote::Waiting(job, permission) => {
                    let item = inbox::permission_item(&job, &permission, now);
                    for other in state.inbox.values_mut() {
                        if other.job == job.id && other.done.is_none() && other.id != item.id {
                            other.done = Some(now);
                            changed.push(other.clone());
                        }
                    }
                    if !state.inbox.contains_key(&item.id) {
                        state.inbox.insert(item.id.clone(), item.clone());
                        changed.push(item);
                    }
                }
                PermissionNote::Settled {
                    job,
                    permission,
                    answer,
                } => {
                    let id = inbox::permission_item_id(&job, &permission);
                    if let Some(item) = state.inbox.get_mut(&id).filter(|i| i.done.is_none()) {
                        item.done = Some(now);
                        item.answer = answer;
                        changed.push(item.clone());
                    }
                }
            }
        }
        for item in &changed {
            self.save_item(item);
        }
    }

    /// An event a plug-in emitted and the host accepted: one `pluginEvent` inbox item
    /// (docs/runner-api.md, "obid only: plug-ins"), unless an item for the same plug-in and event
    /// id is there already, open or done. Past [`inbox::MAX_OPEN_EVENTS`] open items of that
    /// plug-in, the oldest open one is settled by itself, with no answer. The event never starts
    /// work by itself and no remembered decision applies to it: a failed deploy, an alert or a
    /// ticket about one of obid's repositories is an offer, started only on an answer (#1124).
    pub fn plugin_event(&self, event: obi_plugin_api::PluginEvent) {
        self.add_event_item(self.plugin_event_offer(&event));
    }

    /// The item [`Self::plugin_event`] keeps for `event`, an offer on one of obid's repositories;
    /// crate::rules applies standing rules before it's kept.
    pub fn plugin_event_offer(&self, event: &obi_plugin_api::PluginEvent) -> Item {
        let repo = &event.event.subject.repo;
        let known = self.config.repos.get().iter().any(|r| &r.repo == repo);
        inbox::plugin_event_item(event, known, time::now())
    }

    /// A `pluginEvent` item from a plug-in or from one of obid's own sources (crate::sentry): kept
    /// unless an item with its id is there already, open or done; past
    /// [`inbox::MAX_OPEN_EVENTS`] open items of its source (`plugin.id`), the oldest open one is
    /// settled by itself, with no answer.
    pub fn add_event_item(&self, item: Item) -> bool {
        let now = time::now();
        let mut changed = Vec::new();
        {
            let mut state = self.lock();
            if state.inbox.contains_key(&item.id) {
                return false;
            }
            let source = item
                .plugin
                .as_ref()
                .and_then(|p| p["id"].as_str())
                .unwrap_or_default()
                .to_owned();
            let plugin = source.as_str();
            // Oldest first, in the order they arrived (not by id: ids are hashes).
            let mut open: Vec<(u64, String)> = state
                .inbox
                .values()
                .filter(|i| {
                    i.kind == "pluginEvent"
                        && i.done.is_none()
                        && i.plugin.as_ref().and_then(|p| p["id"].as_str()) == Some(plugin)
                })
                .map(|i| (i.arrival_order(), i.id.clone()))
                .collect();
            open.sort();
            let over = (open.len() + 1).saturating_sub(inbox::MAX_OPEN_EVENTS);
            for (_, id) in open.into_iter().take(over) {
                if let Some(old) = state.inbox.get_mut(&id) {
                    old.done = Some(now);
                    changed.push(old.clone());
                }
            }
            state.inbox.insert(item.id.clone(), item.clone());
            changed.push(item);
        }
        for item in &changed {
            self.save_item(item);
        }
        true
    }

    /// Settles an open `pluginEvent` item by itself, with `answer` saying why (its source said the
    /// problem went away, #1311): one already answered, or done, is left alone.
    pub fn settle_event(&self, id: &str, answer: &str) {
        let settled = {
            let mut state = self.lock();
            let Some(item) = state.inbox.get_mut(id).filter(|i| i.done.is_none()) else {
                return;
            };
            item.done = Some(time::now());
            item.answer = Some(answer.to_owned());
            item.clone()
        };
        self.save_item(&settled);
    }

    /// Settles, as [`Self::settle_event`] does, every open `pluginEvent` item that `matches` (a
    /// PagerDuty incident's offers, opened and opened again, #1312).
    pub fn settle_events(&self, matches: impl Fn(&Item) -> bool, answer: &str) {
        let ids: Vec<String> = self
            .lock()
            .inbox
            .values()
            .filter(|i| i.kind == "pluginEvent" && i.done.is_none() && matches(i))
            .map(|i| i.id.clone())
            .collect();
        for id in ids {
            self.settle_event(&id, answer);
        }
    }

    /// Sentry's offers start with what it reads then (crate::sentry::Sentry::quote).
    pub fn use_sentry(&self, sentry: Arc<crate::sentry::Sentry>) {
        let _ = self.sentry.set(sentry);
    }

    pub fn use_relay(&self, relay: Arc<crate::relay::Relay>) {
        let _ = self.relay.set(relay);
    }

    /// What a read of the owner's GitHub work found (crate::github_work): a `github` item for each
    /// of `new` that never had one, open or done; and, with `live` (the inbox ids of every offer
    /// the feed holds now, when no list was cut), each open `github` item that isn't one any more
    /// (its work left the feed, or its pull request's head moved or isn't red now) is done by
    /// itself, with no answer.
    pub fn github_work(
        &self,
        new: &[crate::github_work::Item],
        live: Option<&std::collections::HashSet<String>>,
    ) {
        let now = time::now();
        let known: Vec<bool> = new
            .iter()
            .map(|work| self.config.repos.find(&work.repo).is_some())
            .collect();
        let mut changed = Vec::new();
        {
            let mut state = self.lock();
            if let Some(live) = live {
                for item in state.inbox.values_mut() {
                    if item.kind == "github" && item.done.is_none() && !live.contains(&item.id) {
                        item.done = Some(now);
                        changed.push(item.clone());
                    }
                }
            }
            for (work, known) in new.iter().zip(known) {
                let item = inbox::github_item(work, known, now);
                if !state.inbox.contains_key(&item.id) {
                    state.inbox.insert(item.id.clone(), item.clone());
                    changed.push(item);
                }
            }
        }
        for item in &changed {
            self.save_item(item);
        }
    }

    /// What the watcher saw (crate::watch): a `watch` item for each notice that never had one,
    /// open or done.
    pub fn watch_notices(&self, person: &str, notices: &[crate::watch::Notice]) {
        let now = time::now();
        let mut changed = Vec::new();
        {
            let mut state = self.lock();
            for notice in notices {
                let item = inbox::watch_item("watch", person, notice, now);
                if !state.inbox.contains_key(&item.id) {
                    state.inbox.insert(item.id.clone(), item.clone());
                    changed.push(item);
                }
            }
        }
        for item in &changed {
            self.save_item(item);
        }
    }

    /// After the owner's review was posted: its author is told on Slack, in the background
    /// (crate::listen::tell_author), and what was sent is in the job's `outgoing`.
    fn tell_author(self: &Arc<Self>, review: &Item) {
        let Some(slack) = self.jobs.slack().filter(|s| s.tells_authors()) else {
            return;
        };
        let pr = review.watch.as_deref().map(|w| &w["pr"]);
        let (Some(repo), Some(number)) = (
            pr.and_then(|p| p["repo"].as_str()).map(str::to_owned),
            pr.and_then(|p| p["number"].as_u64()),
        ) else {
            return;
        };
        let verdict = review
            .watch
            .as_deref()
            .and_then(|w| w["verdict"].as_str())
            .unwrap_or("comment")
            .to_owned();
        let link = self.clone();
        let job = review.job.clone();
        tokio::spawn(async move {
            let author = crate::listen::pr_author(&repo, number).await;
            match crate::listen::tell_author(&slack, &job, &repo, number, &verdict, author).await {
                Some(crate::listen::Told::Sent(person)) => {
                    link.jobs.sent_on_slack(&job, &person.id)
                }
                Some(crate::listen::Told::Ask(item)) => link.add_items(vec![*item]),
                None => {}
            }
        });
    }

    /// Send, or Send and Remember (`answer`), on a review's author's item claimed as done: Oby's
    /// message to the person it names, as the owner; Send and Remember also keeps who they are.
    async fn send_to_author(&self, open: Item, answer: &str) -> Result<Value, ApiError> {
        let watch = open.watch.as_deref().cloned().unwrap_or_default();
        let (person, pr) = (&watch["slack"], &watch["pr"]);
        let named = (
            person["user"].as_str(),
            person["name"].as_str(),
            person["login"].as_str(),
            pr["repo"].as_str(),
            pr["number"].as_u64(),
        );
        let sent = match (named, self.jobs.slack()) {
            ((Some(user), Some(name), Some(login), Some(repo), Some(number)), Some(slack)) => slack
                .send_as_owner(
                    user,
                    &crate::slack::review_message(
                        repo,
                        number,
                        watch["verdict"].as_str().unwrap_or("comment"),
                    ),
                )
                .await
                .map(|_| {
                    let person = crate::slack::Person {
                        id: user.to_owned(),
                        name: name.to_owned(),
                    };
                    if answer == crate::listen::SEND_AND_REMEMBER
                        && let Err(why) = slack.remember(login, person)
                    {
                        tracing::warn!("{why}");
                    }
                    user.to_owned()
                }),
            (_, None) => Err(crate::slack::NOT_CONNECTED.to_owned()),
            _ => Err("the item names nobody to send it to".to_owned()),
        };
        match sent {
            Ok(user) => {
                self.jobs.sent_on_slack(&open.job, &user);
                let mut item = open;
                item.done = Some(time::now());
                item.answer = Some(answer.to_owned());
                self.lock().inbox.insert(item.id.clone(), item.clone());
                self.save_item(&item);
                Ok(item.to_json())
            }
            Err(why) => {
                self.lock().inbox.insert(open.id.clone(), open.clone());
                Err(api(
                    StatusCode::BAD_GATEWAY,
                    format!("Nothing was sent: {why}."),
                ))
            }
        }
    }

    /// Items obid made (crate::listen): each one that never was in the inbox, open or done.
    pub fn add_items(&self, items: Vec<Item>) {
        let mut changed = Vec::new();
        {
            let mut state = self.lock();
            for item in items {
                if !state.inbox.contains_key(&item.id) {
                    state.inbox.insert(item.id.clone(), item.clone());
                    changed.push(item);
                }
            }
        }
        for item in &changed {
            self.save_item(item);
        }
    }

    /// Work started from the feed (`POST /v1/github/work/{id}/start`): its open `github` item `id`
    /// is done, answered with its start option, `job` the job on it.
    pub fn github_started(&self, id: &str, job: &str) {
        let item = {
            let mut state = self.lock();
            let Some(item) = state.inbox.get_mut(id).filter(|i| i.done.is_none()) else {
                return;
            };
            item.done = Some(time::now());
            item.answer = item.options.first().cloned();
            item.job = job.to_owned();
            item.clone()
        };
        self.save_item(&item);
    }

    /// `POST /v1/inbox/{id}/answer` on a `github` item: `Review it`, `Fix it` or `Fix CI` starts the
    /// work as `POST /v1/github/work/{id}/start` does (an error leaves the item open), `Dismiss` or
    /// done settle it, later puts it off. Nothing is sent to GitHub. A review in a repository obid
    /// doesn't work in yet waits for the owner's signed Confirm instead, which adds it (#776,
    /// #1118): an API token alone (an agent, oby-mcp) never widens what obid clones.
    async fn answer_github(
        &self,
        mut item: Item,
        answer: Option<String>,
        later: Option<i64>,
    ) -> Result<Value, ApiError> {
        if let Some(at) = later {
            item.later = Some(at);
        } else {
            if let Some(answer) = &answer {
                let start = item.options.first().cloned().unwrap_or_default();
                if *answer != start && answer != inbox::DISMISS {
                    return Err(api(
                        StatusCode::UNPROCESSABLE_ENTITY,
                        format!("The answer is {start} or {}.", inbox::DISMISS),
                    ));
                }
                if *answer == start {
                    let work = item.github.as_deref().cloned().unwrap_or_default();
                    let list = work["list"].as_str().unwrap_or_default();
                    let repo = work["repo"].as_str().unwrap_or_default();
                    let number = work["number"].as_u64().unwrap_or_default();
                    if list == "reviews" && self.config.repos.find(repo).is_none() {
                        // `answer` claimed it: it stays open for the Confirm.
                        self.lock().inbox.insert(item.id.clone(), item.clone());
                        return Err(self.confirm_adding(&item.id, repo, number));
                    }
                    let started = crate::github_work::start_work(
                        &self.jobs,
                        &self.config,
                        list,
                        repo,
                        number,
                    )
                    .await;
                    match started {
                        Ok((job, _)) => item.job = job.id,
                        // `answer` claimed it; what couldn't start leaves it open again.
                        Err(why) => {
                            self.lock().inbox.insert(item.id.clone(), item.clone());
                            return Err(why);
                        }
                    }
                }
            }
            item.done = Some(time::now());
            item.answer = answer;
        }
        self.lock().inbox.insert(item.id.clone(), item.clone());
        self.save_item(&item);
        Ok(item.to_json())
    }

    /// The `confirm` item that adds `repo` and starts Oby's review of its pull request `number`
    /// (#1118), for the GitHub offer `offer` (its inbox id, whether that item was made or not); the
    /// one still open for it stands. Answers the error a start asked for this way answers: only the
    /// owner's signed Confirm adds a repository (#776), from the feed and the inbox alike.
    pub fn confirm_adding(&self, offer: &str, repo: &str, number: u64) -> ApiError {
        let item = inbox::confirm_item(
            "",
            format!("Add {repo} and review #{number}"),
            format!(
                "Adds {repo} to the repositories Oby works in, with no check, then starts Oby's review of pull request #{number}. Nothing is posted on GitHub. It happens only if you confirm."
            ),
            inbox::Confirmed {
                action: inbox::action::ADD_REPOSITORY.into(),
                target: offer.into(),
                payload: json!({"repo": repo, "number": number}),
            },
            time::now(),
        );
        let added = {
            let mut state = self.lock();
            let open = state.inbox.values().any(|i| {
                i.kind == "confirm"
                    && i.done.is_none()
                    && i.confirm.as_ref().is_some_and(|c| {
                        c.action == inbox::action::ADD_REPOSITORY && c.target == offer
                    })
            });
            if !open {
                state.inbox.insert(item.id.clone(), item.clone());
            }
            !open
        };
        if added {
            self.save_item(&item);
        }
        api(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("Adding {repo} waits for your Confirm in the inbox."),
        )
    }

    /// `POST /v1/inbox/{id}/answer` on a plug-in's offer with its start answer (`Look into it`,
    /// `Fix it`), which `answer` claimed: starts the work (crate::event_work); what couldn't start
    /// leaves the item open again. Nothing is sent anywhere.
    async fn answer_plugin_offer(&self, mut item: Item, answer: String) -> Result<Value, ApiError> {
        let sentry = self.sentry.get().map(Arc::as_ref);
        match crate::event_work::start(&self.jobs, &self.config, sentry, &item, None).await {
            Ok(job) => item.job = job.id,
            Err(why) => {
                self.lock().inbox.insert(item.id.clone(), item.clone());
                return Err(why);
            }
        }
        // "…, and from now on for <project>" (#1314): this one is looked into now; the standing
        // rule waits for the owner's own tap on a `confirm` item (#776), since it starts work with
        // none. An API token alone (an agent, an MCP client) never saves one.
        if answer.starts_with(crate::rules::FROM_NOW_ON)
            && let Some(rule) = crate::rules::rule_from(&item, None)
        {
            let words = crate::rules::words(&rule);
            self.add_confirm(inbox::confirm_item(
                &item.job,
                format!("From now on, {words}"),
                format!(
                    "You asked Oby to look into these from now on, with no tap: an investigate job each time, which publishes only when you do, one at a time and at most {} a day. It's saved only if you confirm.",
                    crate::rules::DAILY
                ),
                inbox::Confirmed {
                    action: inbox::action::REMEMBER_RULE.into(),
                    target: item.id.clone(),
                    payload: json!({ "rule": rule }),
                },
                time::now(),
            ));
        }
        item.done = Some(time::now());
        item.answer = Some(answer);
        self.lock().inbox.insert(item.id.clone(), item.clone());
        self.save_item(&item);
        Ok(item.to_json())
    }

    /// At startup: a rule's claimed offer whose job never started (obid stopped in between) is an
    /// offer again (#1314).
    pub fn reopen_claims(&self) {
        let claimed: Vec<String> = self
            .lock()
            .inbox
            .values()
            .filter(|i| {
                i.kind == "pluginEvent"
                    && i.job.is_empty()
                    && i.answer.as_deref() == Some(crate::rules::STARTING_ANSWER)
            })
            .map(|i| i.id.clone())
            .collect();
        for id in claimed {
            self.change_item(&id, |item| {
                item.done = None;
                item.answer = None;
            });
        }
    }

    /// The standing rule (#1314) that covers an event offer's `plugin`, if one does.
    pub fn rule_for(&self, plugin: &Value) -> Option<Decision> {
        decisions::covering_event(&self.lock().decisions, plugin).cloned()
    }

    /// Keeps a standing rule, in place of one for the same source, project and repository.
    pub fn remember_rule(&self, rule: Decision) {
        let kept = {
            let mut state = self.lock();
            state.decisions.retain(|d| {
                !(d.kind == rule.kind
                    && d.source == rule.source
                    && d.project == rule.project
                    && d.repo == rule.repo)
            });
            state.decisions.push(rule);
            state.decisions.clone()
        };
        self.save_decisions(&kept);
    }

    /// The standing rules for events (#1314), as `GET /v1/obid/decisions` lists them.
    pub fn rules(&self) -> Vec<Decision> {
        self.lock()
            .decisions
            .iter()
            .filter(|d| {
                matches!(
                    d.kind.as_str(),
                    decisions::EVENT_ALERT | decisions::EVENT_DEPLOY
                )
            })
            .cloned()
            .collect()
    }

    /// Forgets a standing rule for events; false when there's no such rule.
    pub fn forget_event_rule(&self, id: &str) -> bool {
        let kept = {
            let mut state = self.lock();
            let before = state.decisions.len();
            state.decisions.retain(|d| {
                !(d.id == id
                    && matches!(
                        d.kind.as_str(),
                        decisions::EVENT_ALERT | decisions::EVENT_DEPLOY
                    ))
            });
            if state.decisions.len() == before {
                return false;
            }
            state.decisions.clone()
        };
        self.save_decisions(&kept);
        true
    }

    /// Counts a rule's start, and keeps where it reports (`conversation`, once it has one).
    pub fn rule_started(&self, id: &str, conversation: Option<String>) {
        let kept = {
            let mut state = self.lock();
            let Some(rule) = state.decisions.iter_mut().find(|d| d.id == id) else {
                return;
            };
            rule.uses += 1;
            rule.last_used = Some(time::now());
            if conversation.is_some() {
                rule.conversation = conversation;
            }
            state.decisions.clone()
        };
        self.save_decisions(&kept);
    }

    /// Changes an inbox item as `change` does, keeps it and says so.
    pub fn change_item(&self, id: &str, change: impl FnOnce(&mut Item)) {
        let changed = {
            let mut state = self.lock();
            let Some(item) = state.inbox.get_mut(id) else {
                return;
            };
            change(item);
            item.clone()
        };
        self.save_item(&changed);
    }

    /// `POST /v1/inbox/{id}/answer` on a `pluginEvent` item: `Dismiss` or `{"done": true}` settles
    /// it, `later` puts it off. Nothing is sent anywhere. (An offer's start is
    /// [`Self::answer_plugin_offer`]'s.)
    fn answer_plugin_event(
        &self,
        mut item: Item,
        answer: Option<String>,
        later: Option<i64>,
    ) -> Result<Value, ApiError> {
        if let Some(answer) = &answer
            && answer != inbox::DISMISS
        {
            let options = if item.kind == "pluginEvent" {
                item.options.join(" or ")
            } else {
                inbox::DISMISS.to_owned()
            };
            return Err(api(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("The answer is {options}."),
            ));
        }
        match later {
            Some(at) => item.later = Some(at),
            None => {
                item.done = Some(time::now());
                item.answer = answer;
            }
        }
        self.lock().inbox.insert(item.id.clone(), item.clone());
        self.save_item(&item);
        Ok(item.to_json())
    }

    /// `POST /v1/inbox/{id}/answer` on a `permission` item: the owner's answer goes to the job (an
    /// answer of their own words is a no, with those words for the agent); done or later only
    /// settles or puts off the item.
    fn answer_permission_item(
        &self,
        item: Item,
        answer: Option<String>,
        later: Option<i64>,
    ) -> Result<Value, ApiError> {
        let now = time::now();
        let Some(answer) = answer else {
            let mut item = item;
            match later {
                Some(at) => item.later = Some(at),
                None => item.done = Some(now),
            }
            // Done without an answer: a shell command waiting for it doesn't run.
            if item.done.is_some() && crate::brain::shell::is_item(&item) {
                crate::brain::shell::answered(&item.id, None);
            }
            self.lock().inbox.insert(item.id.clone(), item.clone());
            self.save_item(&item);
            return Ok(item.to_json());
        };
        // A command of a conversation's shell: the owner's answer goes to it, and only once.
        if crate::brain::shell::is_item(&item) {
            if answer == crate::permissions::ALWAYS_ALLOW
                && !item
                    .options
                    .iter()
                    .any(|o| o == crate::permissions::ALWAYS_ALLOW)
            {
                return Err(api(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "It has no rule to save: allow it once instead.",
                ));
            }
            if !crate::brain::shell::answered(&item.id, Some(answer.clone())) {
                self.settle(&item.id);
                return Err(api(
                    StatusCode::CONFLICT,
                    "Its command isn't waiting any more: its turn ended.",
                ));
            }
            let mut item = item;
            item.answer = Some(answer);
            item.done = Some(now);
            self.lock().inbox.insert(item.id.clone(), item.clone());
            self.save_item(&item);
            return Ok(item.to_json());
        }
        let permission = item
            .id
            .strip_prefix(&format!("{}-permission-", item.job))
            .unwrap_or("")
            .to_owned();
        let (decision, words) = crate::permissions::inbox_decision(&answer);
        use crate::jobs::PermissionRefused;
        match self
            .jobs
            .answer_permission(&item.job, &permission, decision, words.as_deref())
        {
            Ok(_) => {}
            Err(PermissionRefused::NoJob) => {
                return Err(api(StatusCode::CONFLICT, "Its job is gone."));
            }
            Err(PermissionRefused::NotWaiting(why)) => return Err(api(StatusCode::CONFLICT, why)),
            Err(PermissionRefused::Refused(why)) => {
                return Err(api(StatusCode::UNPROCESSABLE_ENTITY, why));
            }
        }
        let settled = self.lock().inbox.get(&item.id).cloned().unwrap_or(item);
        Ok(settled.to_json())
    }

    /// Keeps the exchange and tells the apps, as it is now: a caller's copy can be older than what
    /// another change has put there since (docs/runner-api.md, "GET /v1/events").
    fn save_exchange(&self, exchange: &Exchange) {
        let _saving = self.saving.lock().unwrap_or_else(|e| e.into_inner());
        let now = self.lock().exchanges.get(&exchange.correlation_id).cloned();
        let exchange = now.as_ref().unwrap_or(exchange);
        if let Err(e) = self.exchanges.save(exchange) {
            tracing::error!("can't keep exchange {}: {e}", exchange.correlation_id);
        }
        self.events.send("exchange", exchange.to_json());
    }

    /// Keeps the item and tells the apps, as it is now (as `save_exchange`).
    fn save_item(&self, item: &Item) {
        if let Err(e) = self.keep_item(item) {
            tracing::error!("can't keep inbox item {}: {e}", item.id);
        }
    }

    /// [`Link::save_item`], saying whether it was kept on disk.
    fn keep_item(&self, item: &Item) -> Result<(), String> {
        let _saving = self.saving.lock().unwrap_or_else(|e| e.into_inner());
        let now = self.lock().inbox.get(&item.id).cloned();
        let item = now.as_ref().unwrap_or(item);
        let kept = self.inbox.save(item).map_err(|e| e.to_string());
        self.events.send("inbox", self.shown(item));
        kept
    }

    /// The inbox's sorts as they are now (crate::triage), over `inbox`.
    fn sorts<'a>(&'a self, inbox: &'a HashMap<String, Item>) -> crate::triage::Sorts<'a> {
        crate::triage::Sorts::of(&self.triage, inbox.values(), time::now())
    }

    /// An item's sort now (crate::triage). Never with this Link's state locked.
    pub fn triage_of(&self, item: &Item) -> &'static str {
        let state = self.lock();
        self.sorts(&state.inbox).get(item)
    }

    /// An item as the API shows it: with its `triage`.
    fn shown(&self, item: &Item) -> Value {
        let mut shown = item.to_json();
        shown["triage"] = self.triage_of(item).into();
        shown
    }

    /// Open items waiting for the quick model (crate::triage), the longest-waiting first.
    pub fn unsorted(&self) -> Vec<Item> {
        let state = self.lock();
        let sorts = self.sorts(&state.inbox);
        let mut items: Vec<Item> = state
            .inbox
            .values()
            .filter(|i| sorts.waits(i))
            .cloned()
            .collect();
        items.sort_by_key(Item::arrival_order);
        items
    }

    /// The model's sorts (crate::triage::sort), kept for good: the apps hear each item again, now
    /// sorted. Nothing about the item changes but that.
    pub fn sorted(&self, sorts: &[(String, &str)]) {
        self.retell(&self.triage.keep(sorts));
    }

    /// The apps hear these items again, as they are now: their sort changed, nothing else.
    pub fn retell(&self, ids: &[String]) {
        let _saving = self.saving.lock().unwrap_or_else(|e| e.into_inner());
        for id in ids {
            if let Some(item) = self.item(id) {
                self.events.send("inbox", self.shown(&item));
            }
        }
    }

    fn save_sharing(&self, sharing: &Sharing) {
        if let Err(e) = self.sharing.save(sharing) {
            tracing::error!("can't keep the sharing rules: {e}");
        }
    }

    fn save_decisions(&self, decisions: &[Decision]) {
        if let Err(e) = self.decisions.save(decisions) {
            tracing::error!("can't keep the remembered decisions: {e}");
        }
    }

    fn note_error(&self, error: impl std::fmt::Display) {
        let line = error.to_string();
        tracing::warn!("sphere: {line}");
        self.lock().last_error = Some(line);
    }

    // -----------------------------------------------------------------------------------------
    // Membership: GET /v1/obid/sphere, POST …/key, …/card, …/join

    /// `GET /v1/obid/sphere`.
    pub fn membership_json(&self) -> Value {
        let state = self.lock();
        let key = state.key.as_ref();
        let joined = state.membership.as_ref();
        json!({
            "state": joined.map_or("none", |m| m.state.as_str()),
            "url": joined.map(|m| &m.url),
            "sphere": joined.map(|m| &m.sphere),
            "obiId": joined.map(|m| &m.obi_id),
            "owner": self.config.owner,
            "keyId": key.map(|k| k.key_id()),
            "publicKey": key.map(|k| k.public_key()),
            "card": joined.map(|m| &m.card),
            "tokenExpiresAt": state.token.as_ref().map(|t| time::format(t.1)),
            "lastPoll": state.last_poll.map(time::format),
            "lastError": state.last_error,
        })
    }

    /// `POST /v1/obid/sphere/key`: the Obi key, made the first time.
    pub async fn make_key(&self) -> Result<Value, ApiError> {
        let _one = self.joining.lock().await;
        let existing = self.lock().key.clone();
        let key = match existing {
            Some(key) => key,
            None => {
                let key = Arc::new(self.files.make_key().map_err(|e| {
                    api(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        format!("obid couldn't keep its key: {e}"),
                    )
                })?);
                learn_key(&key);
                self.lock().key = Some(key.clone());
                key
            }
        };
        Ok(json!({"keyId": key.key_id(), "publicKey": key.public_key()}))
    }

    /// `GET /v1/obid/sphere/pins`: the owner keys this Obi trusts, each with the fingerprint owners
    /// compare, and any changed key waiting for this owner's OK.
    pub fn pins_json(&self) -> Value {
        self.pins.to_json()
    }

    /// `POST /v1/obid/sphere/pins/{owner}` with `{"fingerprint"}`: the owner compared `owner`'s new
    /// key with them and trusts it. The directory is read again.
    pub async fn accept_pin(&self, owner: &str, body: &[u8]) -> Result<Value, ApiError> {
        let map = object(body, &["fingerprint"])?;
        let seen = text_field(&map, "fingerprint")?;
        let pinned = self
            .pins
            .accept(owner, seen, time::now())
            .map_err(|m| api(StatusCode::UNPROCESSABLE_ENTITY, m))?;
        if self.lock().membership.is_some()
            && let Err(e) = self.read_directory().await
        {
            self.note_error(&e);
        }
        Ok(pinned)
    }

    /// `POST /v1/obid/sphere/card`: the card the owner is to sign, around obid's own key.
    pub async fn card(&self, body: &[u8]) -> Result<Value, ApiError> {
        let _one = self.joining.lock().await;
        let map = object(
            body,
            &[
                "url",
                "sphere",
                "obiId",
                "name",
                "ownerKey",
                "accepts",
                "description",
            ],
        )?;
        let invalid = |m: String| api(StatusCode::UNPROCESSABLE_ENTITY, m);
        let (key, card_seq) = {
            let state = self.lock();
            let key = state.key.clone().ok_or_else(|| {
                api(
                    StatusCode::CONFLICT,
                    "There's no Obi key yet: POST /v1/obid/sphere/key first.",
                )
            })?;
            (
                key,
                state.membership.as_ref().map_or(1, |m| m.card_seq() + 1),
            )
        };
        let url = text_field(&map, "url")?.trim_end_matches('/');
        if !is_base_url(url) {
            return Err(invalid(format!(
                "url is the Sphere's base URL, https (http only on this machine), like https://sphere.example.com, not {url:?}."
            )));
        }
        let sphere = text_field(&map, "sphere")?;
        let obi_id = text_field(&map, "obiId")?;
        let name = text_field(&map, "name")?;
        let owner_key = text_field(&map, "ownerKey")?;
        let description = match map.get("description") {
            None | Some(Value::Null) => obi_protocol::identity::DEFAULT_DESCRIPTION,
            Some(Value::String(d)) => d.as_str(),
            Some(_) => return Err(invalid("description is a string.".into())),
        };
        let accepts: Vec<String> = match map.get("accepts") {
            Some(Value::Array(list)) => list
                .iter()
                .map(|a| a.as_str().map(str::to_owned))
                .collect::<Option<Vec<_>>>()
                .ok_or_else(|| invalid("accepts is a list of request types.".into()))?,
            _ => {
                return Err(invalid(
                    "accepts is a list of request types, and it's required.".into(),
                ));
            }
        };
        if accepts.is_empty() {
            return Err(invalid("accepts names at least one request type.".into()));
        }
        if let Some(other) = accepts.iter().find(|a| {
            !matches!(
                a.as_str(),
                "review_request" | "question" | "run_request" | "share_offer"
            )
        }) {
            return Err(invalid(format!(
                "obid takes review_request, question, run_request and share_offer in this version, not {other}."
            )));
        }
        if obi_protocol::keys::key_id_of(owner_key).is_none() {
            return Err(invalid(
                "ownerKey is an Ed25519 public key, base64url.".into(),
            ));
        }
        if owner_key == key.public_key() {
            return Err(invalid(
                "ownerKey is the owner's key, not the Obi's.".into(),
            ));
        }
        let (key_id, public_key, issued_at) =
            (key.key_id(), key.public_key(), time::format(time::now()));
        let unsigned = obi_protocol::identity::unsigned_card(&obi_protocol::identity::CardFields {
            sphere_url: url,
            sphere,
            obi_id,
            owner: &self.config.owner,
            owner_key,
            name,
            description,
            version: OBID_VERSION,
            key_id: &key_id,
            public_key: &public_key,
            accepts: &accepts,
            card_seq,
            issued_at: &issued_at,
        });
        let problems = obi_protocol::identity::unsigned_card_problems(&unsigned);
        if !problems.is_empty() {
            return Err(invalid(format!(
                "That card wouldn't pass the spec's checks: {}",
                problems.join("; ")
            )));
        }
        Ok(json!({"card": unsigned}))
    }

    /// `POST /v1/obid/sphere/join`: checks the owner-signed card and the delegation, redeems the
    /// invitation, exchanges a token, reads the directory and starts following.
    pub async fn join(self: &Arc<Self>, body: &[u8]) -> Result<Value, ApiError> {
        let _one = self.joining.lock().await;
        let map = object(body, &["url", "sphere", "invitation", "card", "delegation"])?;
        let invalid = |m: String| api(StatusCode::UNPROCESSABLE_ENTITY, m);
        let key = {
            let state = self.lock();
            if let Some(m) = &state.membership {
                return Err(api(
                    StatusCode::CONFLICT,
                    format!("obid has joined {} already ({}).", m.sphere, m.state),
                ));
            }
            state.key.clone().ok_or_else(|| {
                api(
                    StatusCode::CONFLICT,
                    "There's no Obi key yet: POST /v1/obid/sphere/key first.",
                )
            })?
        };
        let url = text_field(&map, "url")?.trim_end_matches('/').to_owned();
        if !is_base_url(&url) {
            return Err(invalid(format!(
                "url is the Sphere's base URL, https (http only on this machine), like https://sphere.example.com, not {url:?}."
            )));
        }
        let sphere = text_field(&map, "sphere")?.to_owned();
        if !is_slug(&sphere) {
            return Err(invalid(format!("{sphere:?} isn't a Sphere id.")));
        }
        let invitation = map
            .get("invitation")
            .and_then(Value::as_object)
            .ok_or_else(|| invalid(INVITATION_SHAPE.into()))?;
        if invitation
            .keys()
            .any(|k| !matches!(k.as_str(), "id" | "secret" | "signin"))
        {
            return Err(invalid(INVITATION_SHAPE.into()));
        }
        let invitation_id = text_field(invitation, "id")?;
        let secret = text_field(invitation, "secret")?;
        if !is_token_text(invitation_id) || !is_token_text(secret) {
            return Err(invalid(
                "The invitation's id and secret are what the Sphere gave, unchanged.".into(),
            ));
        }
        // The owner's sign-in with the Sphere, for an invitation limited to a domain: passed on
        // to the redeem as it is, and kept nowhere.
        let signin = match invitation.get("signin") {
            None => None,
            Some(Value::Object(s))
                if s.len() == 2
                    && ["state", "code"]
                        .iter()
                        .all(|k| s.get(*k).and_then(Value::as_str).is_some_and(is_token_text)) =>
            {
                invitation.get("signin")
            }
            Some(_) => return Err(invalid(INVITATION_SHAPE.into())),
        };
        let card = map
            .get("card")
            .filter(|c| c.is_object())
            .ok_or_else(|| invalid("card is the agent card, signed by the owner.".into()))?
            .clone();
        let delegation = text_field(&map, "delegation")?.to_owned();
        let now = time::now();
        obi_protocol::card::verify(
            &card,
            &obi_protocol::card::Context {
                now: Some(now),
                bound_owner_key: None,
            },
        )
        .map_err(|r| invalid(format!("The card doesn't pass the spec's checks: {r}")))?;
        let params = obi_protocol::card::params(&card).expect("a verified card has its params");
        let param = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or("");
        if param("key_id") != key.key_id() || param("public_key") != key.public_key() {
            return Err(invalid("The card doesn't carry obid's own key.".into()));
        }
        if param("sphere") != sphere {
            return Err(invalid(format!(
                "The card is for the Sphere {}, not {sphere}.",
                param("sphere")
            )));
        }
        if param("owner") != self.config.owner {
            return Err(invalid(format!(
                "The card's owner is {}, not obid's owner {}.",
                param("owner"),
                self.config.owner
            )));
        }
        let obi_id = param("obi_id").to_owned();
        let expected_url = format!("{url}/v0.1/spheres/{sphere}/members/{obi_id}");
        if card["url"].as_str() != Some(expected_url.as_str()) {
            return Err(invalid(format!("The card's url isn't {expected_url}.")));
        }
        let owner_key = param("owner_key").to_owned();
        obi_protocol::identity::check_delegation(
            &delegation,
            &obi_protocol::identity::DelegationCheck {
                owner_key: &owner_key,
                owner: &self.config.owner,
                sphere: &sphere,
                obi_id: &obi_id,
                now,
                needs: &NEEDED_SCOPES,
            },
        )
        .map_err(|why| invalid(format!("The delegation doesn't pass: {why}.")))?;

        let client = Client::new(&url, &sphere).map_err(|e| from_client(&e))?;
        client
            .redeem(invitation_id, secret, &owner_key, &card, signin)
            .await
            .map_err(|e| from_client(&e))?;
        let membership = Membership {
            state: "joined".into(),
            url,
            sphere,
            obi_id,
            card,
            joined_at: now,
        };
        crate::secrets::known().learn(DELEGATION_SECRET, &delegation);
        let kept = self
            .files
            .save_membership(&membership)
            .and_then(|()| self.files.save_delegation(&delegation));
        {
            let mut state = self.lock();
            state.membership = Some(membership);
            state.delegation = Some(delegation);
            state.client = Some(client);
            state.token = None;
        }
        if let Err(e) = kept {
            self.note_error(format!("obid couldn't keep its membership: {e}"));
        }
        let read = self.read_directory().await;
        self.follow();
        self.start_sender();
        if let Err(e) = read {
            self.note_error(&e);
            return Err(from_client(&e));
        }
        Ok(self.membership_json())
    }

    // -----------------------------------------------------------------------------------------
    // Talking to the Sphere

    fn client(&self) -> Result<Client, ClientError> {
        self.lock()
            .client
            .clone()
            .ok_or_else(|| ClientError::Unreachable("obid hasn't joined a Sphere".into()))
    }

    /// The access token, exchanged again when the one held has less than a minute left.
    async fn token(&self) -> Result<String, ClientError> {
        let fresh = |state: &State| {
            state
                .token
                .as_ref()
                .filter(|(_, expires)| expires - time::now() > TOKEN_MARGIN)
                .map(|(t, _)| t.clone())
        };
        if let Some(token) = fresh(&self.lock()) {
            return Ok(token);
        }
        let _one = self.tokening.lock().await;
        let (client, delegation, key, membership) = {
            let state = self.lock();
            if let Some(token) = fresh(&state) {
                return Ok(token);
            }
            let missing = || ClientError::Unreachable("obid hasn't joined a Sphere".into());
            (
                state.client.clone().ok_or_else(missing)?,
                state.delegation.clone().ok_or_else(missing)?,
                state.key.clone().ok_or_else(missing)?,
                state.membership.clone().ok_or_else(missing)?,
            )
        };
        let now = time::now();
        let actor = obi_protocol::identity::actor_assertion(
            &membership.obi_id,
            &membership.sphere,
            &key,
            now,
            &new_uuid(),
        )
        .map_err(|e| ClientError::Protocol(e.to_string()))?;
        let token = client.token(&delegation, &actor).await?;
        crate::secrets::known().learn(SPHERE_TOKEN_SECRET, &token.access_token);
        self.lock().token = Some((token.access_token.clone(), now + token.expires_in));
        Ok(token.access_token)
    }

    /// The Sphere's client while obid is a member (`joined`): the phone relay's (crate::relay).
    pub fn relay_client(&self) -> Option<Client> {
        let state = self.lock();
        state.membership.as_ref().filter(|m| m.state == "joined")?;
        state.client.clone()
    }

    /// An access token for the phone relay's calls and socket, and when it ends (Unix seconds).
    pub async fn relay_token(&self) -> Result<(String, i64), ClientError> {
        let token = self.token().await?;
        let ends = self
            .lock()
            .token
            .as_ref()
            .filter(|(held, _)| *held == token)
            .map_or(time::now() + TOKEN_MARGIN, |(_, ends)| *ends);
        Ok((token, ends))
    }

    /// The Sphere refused a relay call: a refused token is forgotten, as for any other call.
    pub fn relay_refused(&self, error: &ClientError) {
        self.refused_token(error);
    }

    /// What to do with a refusal of the token: forget it, so the next call exchanges a new one.
    fn refused_token(&self, error: &ClientError) {
        if matches!(error, ClientError::Refused { status: 401, .. }) {
            self.lock().token = None;
        }
    }

    /// Reads the directory and keeps every member whose card passes the checks (identity.md 2.2,
    /// with the owner key the Sphere bound), with every key it ever had.
    async fn read_directory(&self) -> Result<(), ClientError> {
        let token = self.token().await?;
        let members = match self.client()?.members(&token).await {
            Ok(members) => members,
            Err(e) => {
                self.refused_token(&e);
                return Err(e);
            }
        };
        let now = time::now();
        let mut directory = Directory::default();
        for member in &members {
            let obi = member["obi"].as_str().unwrap_or("");
            let owner = member["owner"].as_str().unwrap_or("");
            let card = &member["card"];
            let checked = obi_protocol::card::verify(
                card,
                &obi_protocol::card::Context {
                    now: Some(now),
                    bound_owner_key: member["owner_key"].as_str().map(str::to_owned),
                },
            );
            let params = obi_protocol::card::params(card);
            let matches = params.is_some_and(|p| p["obi_id"] == obi && p["owner"] == owner);
            if let Err(why) = checked {
                tracing::warn!(
                    "sphere: {obi}'s card doesn't pass the checks ({}): not trusted",
                    why.code
                );
                continue;
            }
            if !matches {
                tracing::warn!("sphere: {obi}'s card names another Obi or owner: not trusted");
                continue;
            }
            // Only a card signed with the owner key pinned here, whatever the Sphere bound.
            let owner_key = params.and_then(|p| p["owner_key"].as_str()).unwrap_or("");
            if !self.pins.check(owner, owner_key, now) {
                continue;
            }
            // Never an older card than one trusted before (a key rotated away coming back).
            let card_seq = params.and_then(|p| p["card_seq"].as_u64()).unwrap_or(0);
            if !self.pins.check_card(obi, card_seq) {
                continue;
            }
            // The Obi key is the one the card signs: a current key the Sphere lists must be it.
            // Older keys (with `valid_until_seq`) only check entries signed before they ended.
            let (card_id, card_key) = (
                params.and_then(|p| p["key_id"].as_str()).unwrap_or(""),
                params.and_then(|p| p["public_key"].as_str()).unwrap_or(""),
            );
            let keys: Vec<&Value> = member["keys"].as_array().into_iter().flatten().collect();
            let current: Vec<&&Value> = keys
                .iter()
                .filter(|k| k["valid_until_seq"].as_u64().is_none())
                .collect();
            if current.len() != 1
                || current[0]["key_id"] != card_id
                || current[0]["public_key"] != card_key
            {
                tracing::warn!(
                    "sphere: the Sphere lists a key for {obi} that its card doesn't sign ({}): not trusted",
                    current
                        .iter()
                        .filter_map(|k| k["key_id"].as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                );
                continue;
            }
            self.pins.keep_key(obi, card_id, card_key);
            for key in keys {
                let (Some(id), Some(public_key)) =
                    (key["key_id"].as_str(), key["public_key"].as_str())
                else {
                    continue;
                };
                let older = key["valid_until_seq"].as_u64().is_some();
                if older && (id == card_id || !self.pins.knows_key(obi, id, public_key)) {
                    // Only a key a card obid trusted signed: the Sphere can't add one of its own.
                    tracing::warn!(
                        "sphere: the Sphere lists an older key for {obi} no card obid trusted signed: not used"
                    );
                    continue;
                }
                directory.keys.insert(
                    id.to_owned(),
                    DirectoryKey {
                        obi: obi.to_owned(),
                        public_key: public_key.to_owned(),
                        ranged: true,
                        valid_from_seq: key["valid_from_seq"].as_u64().unwrap_or(1),
                        valid_until_seq: key["valid_until_seq"].as_u64(),
                    },
                );
            }
            directory.members.insert(
                obi.to_owned(),
                Member {
                    owner: owner.to_owned(),
                    active: member["status"] == "active",
                    accepts: params
                        .and_then(|p| p.get("accepts"))
                        .and_then(Value::as_array)
                        .map(|a| {
                            a.iter()
                                .filter_map(Value::as_str)
                                .map(str::to_owned)
                                .collect()
                        })
                        .unwrap_or_default(),
                    runner: member
                        .get("runner")
                        .filter(|r| runner_signed(r, &directory.keys, obi))
                        .cloned(),
                },
            );
        }
        let revoked = {
            let mut state = self.lock();
            let me = state.membership.as_ref().map(|m| m.obi_id.clone());
            let revoked = me
                .and_then(|me| members.iter().find(|m| m["obi"] == me.as_str()).cloned())
                .is_some_and(|m| m["status"] == "revoked");
            state.directory = directory;
            state.directory_read = now;
            if revoked && let Some(m) = state.membership.as_mut() {
                m.state = "revoked".into();
            }
            revoked.then(|| state.membership.clone()).flatten()
        };
        if let Some(membership) = revoked {
            let _ = self.files.save_membership(&membership);
            // The sender and the clock stop now, not at their next wakeup: what's open is settled
            // here, its peers not told.
            self.settle_on_revoke();
            self.outbox.notify_one();
            // The relay's socket stops serving phones now, not at its next check.
            if let Some(relay) = self.relay.get() {
                relay.wake();
            }
        }
        Ok(())
    }

    // -----------------------------------------------------------------------------------------
    // Following: deliveries

    /// Starts the follower, once.
    fn follow(self: &Arc<Self>) {
        if self.following.swap(true, Ordering::SeqCst) {
            return;
        }
        self.keep_runner_status();
        let link = self.clone();
        tokio::spawn(async move {
            tokio::select! {
                () = link.clone().run_follower() => {}
                () = stopped(link.stopping.clone()) => {}
            }
        });
    }

    async fn run_follower(self: Arc<Self>) {
        let mut backoff = Duration::from_secs(1);
        loop {
            let revoked = self
                .lock()
                .membership
                .as_ref()
                .is_none_or(|m| m.state != "joined");
            if revoked {
                return;
            }
            match self.poll().await {
                Ok(()) => backoff = Duration::from_secs(1),
                Err(e) => {
                    self.note_error(&e);
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(BACKOFF_MAX);
                }
            }
        }
    }

    /// One deliveries call: each delivery handled, then acknowledged once what it decided is kept.
    async fn poll(self: &Arc<Self>) -> Result<(), ClientError> {
        let stale = time::now() - self.lock().directory_read >= DIRECTORY_EVERY;
        if stale {
            self.read_directory().await?;
        }
        let token = self.token().await?;
        let client = self.client()?;
        let deliveries = match client.deliveries(&token, 50, POLL_WAIT).await {
            Ok(list) => list,
            Err(e) => {
                self.refused_token(&e);
                return Err(e);
            }
        };
        {
            let mut state = self.lock();
            state.last_poll = Some(time::now());
            state.last_error = None;
        }
        if deliveries.is_empty() {
            return Ok(());
        }
        let mut handled = Vec::new();
        for delivery in deliveries {
            let id = delivery.delivery_id.clone();
            self.handle(delivery).await;
            handled.push(id);
        }
        if let Err(e) = client.ack(&token, &handled).await {
            // They come again; the ids already handled make the second time harmless.
            self.refused_token(&e);
            return Err(e);
        }
        Ok(())
    }

    fn verify(&self, delivery: &Delivery) -> Result<(), obi_protocol::Rejection> {
        let state = self.lock();
        let context = obi_protocol::envelope::Context {
            now: Some(time::now()),
            sphere: state.membership.as_ref().map(|m| m.sphere.clone()),
            receiver: state.membership.as_ref().map(|m| m.obi_id.clone()),
            // A live message is signed with its sender's current key, the one its card signs;
            // older keys only check old chain entries.
            keys: state
                .directory
                .keys
                .iter()
                .filter(|(_, k)| k.valid_until_seq.is_none())
                .map(|(id, k)| (id.clone(), k.clone()))
                .collect(),
            seq: Some(delivery.seq),
            seen_ids: Vec::new(),
        };
        obi_protocol::envelope::verify(&delivery.envelope, &context)
    }

    fn drop_message(&self, id: &str, why: &str) {
        // The reason names checks and codes, never the message's text.
        tracing::warn!("sphere: dropped message {id}: {why}");
        let mut state = self.lock();
        state.seen.insert(id.to_owned());
        state.dropped.push(id.to_owned());
        if state.dropped.len() > DROPPED_MAX {
            let old = state.dropped.remove(0);
            state.seen.remove(&old);
        }
    }

    /// One delivery (protocol.md section 11): verified, deduplicated, then a reply matched to its
    /// exchange or a request decided.
    async fn handle(self: &Arc<Self>, delivery: Delivery) {
        let id = delivery.envelope["id"].as_str().unwrap_or("").to_owned();
        if !id.is_empty() && self.lock().seen.contains(&id) {
            return;
        }
        let mut verdict = self.verify(&delivery);
        if matches!(&verdict, Err(r) if r.code == "unknown_key") {
            // A member who joined or rotated since the directory was read.
            if let Err(e) = self.read_directory().await {
                self.note_error(&e);
            }
            verdict = self.verify(&delivery);
        }
        if let Err(rejection) = verdict {
            // Its code only: a schema's message may quote the message's text.
            self.drop_message(&id, rejection.code);
            return;
        }
        let kind = delivery.envelope["type"].as_str().unwrap_or("");
        if obi_protocol::REPLY_TYPES.contains(&kind) {
            self.handle_reply(delivery);
        } else {
            self.handle_request(delivery);
        }
    }

    fn received(delivery: &Delivery) -> Message {
        Message {
            direction: "received".into(),
            seq: Some(delivery.seq),
            at: delivery.relayed_at.clone(),
            envelope: delivery.envelope.clone(),
        }
    }

    /// A reply: matched to the outgoing request it names, sent to the reply's sender, keeping the
    /// exchange rules; else dropped.
    fn handle_reply(&self, delivery: Delivery) {
        let envelope = &delivery.envelope;
        let id = envelope["id"].as_str().unwrap_or("").to_owned();
        let cid = envelope["in_reply_to"].as_str().unwrap_or("");
        let from = envelope["from"].as_str().unwrap_or("");
        let kind = envelope["type"].as_str().unwrap_or("");
        let mut state = self.lock();
        let Some(exchange) = state.exchanges.get_mut(cid).filter(|e| {
            e.peer == from
                && (e.direction == "outgoing"
                    || (obi_protocol::SENDER_REPLY_TYPES.contains(&kind)
                        && e.direction == "incoming"))
        }) else {
            drop(state);
            self.drop_message(&id, "a reply to no request of this Obi's");
            return;
        };
        let earlier: Vec<&Value> = exchange
            .messages
            .iter()
            .skip(1)
            .map(|m| &m.envelope)
            .collect();
        if let Some(problem) =
            obi_protocol::chain::exchange_problem(envelope, Some(&exchange.request), &earlier)
        {
            drop(state);
            self.drop_message(&id, &format!("breaks the exchange rules: {problem}"));
            return;
        }
        // An answer picking a choice its question doesn't have (protocol.md section 11, step 3).
        let choices = exchange.request["body"]["choices"]
            .as_array()
            .map_or(0, Vec::len) as u64;
        if envelope["type"] == "answer"
            && envelope["body"]
                .get("choice")
                .is_some_and(|c| c.as_u64().is_none_or(|c| c >= choices))
        {
            drop(state);
            self.drop_message(&id, "an answer with a choice its question doesn't have");
            return;
        }
        exchange.messages.push(Link::received(&delivery));
        match envelope["type"].as_str().unwrap_or("") {
            "accept" if exchange.state == "sent" => exchange.state = "accepted".into(),
            "decline" => exchange.state = "declined".into(),
            // A result finishes a review or a handoff, an answer a question: either ends the
            // exchange, and is its result.
            "result" | "answer" => {
                exchange.state = "done".into();
                exchange.result = Some(envelope["body"].clone());
            }
            // A job that came back from the other Mac with what it did.
            "run_return" => {
                exchange.state = "returned".into();
                exchange.result = Some(envelope["body"].clone());
            }
            // The sender called its job off: it stops here at once.
            "run_cancel" => exchange.state = "cancelled".into(),
            // A teammate took their share back.
            "share_revoke" => exchange.state = "revoked".into(),
            _ => {}
        }
        exchange.updated = time::now();
        let exchange = exchange.clone();
        state.seen.insert(id);
        drop(state);
        self.save_exchange(&exchange);
        if kind == "run_cancel" {
            self.hosting.cancelled(cid);
            if let Some(item) = exchange.inbox_item.as_deref() {
                self.settle(item);
            }
        }
    }

    /// A request (protocol.md section 11, steps 4 to 6): declined when the card doesn't accept its
    /// type, decided by a remembered decision when one covers it, else put in the owner's inbox
    /// (declined `busy` when the sender's owner has as many waiting there as the limit allows). A
    /// question goes on to [`Link::decide_question`].
    fn handle_request(self: &Arc<Self>, delivery: Delivery) {
        let envelope = delivery.envelope.clone();
        let id = envelope["id"].as_str().unwrap_or("").to_owned();
        let from = envelope["from"].as_str().unwrap_or("").to_owned();
        let kind = envelope["type"].as_str().unwrap_or("").to_owned();
        let body = &envelope["body"];
        // A question's repositories, its job references checked against obid's own jobs, before
        // the Link's state is locked.
        let (repos, referenced) = if kind == "question" {
            self.question_repos(body)
        } else {
            (Vec::new(), Vec::new())
        };
        let mut state = self.lock();
        if state.exchanges.contains_key(&id) {
            drop(state);
            self.drop_message(&id, "a request for an exchange obid has already");
            return;
        }
        // The sender's owner comes from the directory, never from the message; a removed member
        // is never admitted.
        let owner = state
            .directory
            .members
            .get(&from)
            .filter(|m| m.active)
            .map(|m| m.owner.clone());
        let Some(owner) = owner else {
            drop(state);
            self.drop_message(&id, "its sender isn't an active member in the directory");
            return;
        };
        let accepts = state
            .membership
            .as_ref()
            .map(Membership::accepts)
            .unwrap_or_default();
        let mut exchange = Exchange::new(
            "incoming",
            envelope.clone(),
            from.clone(),
            Some(owner.clone()),
        );
        exchange.messages.push(Link::received(&delivery));
        state.seen.insert(id.clone());
        let repo = body["repo"].as_str();
        let now = time::now();
        let mut item = None;
        let mut decisions_changed = false;
        let mut answer_by_itself = None;
        let mut admit = false;
        if accepts.contains(&kind) && kind == "share_offer" {
            // A share of a teammate's API account: shown in "Shared with you" until its revoke.
            exchange.state = "offered".into();
        } else if accepts.contains(&kind) && kind == "run_request" {
            // Decided by the owner's sharing rules, which read the Mac: off this lock.
            exchange.state = "admitting".into();
            admit = true;
        } else if !accepts.contains(&kind) || !(kind == "review_request" || kind == "question") {
            exchange.state = "declined".into();
            let decline = self.reply_locked(
                &state,
                &exchange,
                "decline",
                json!({"reason": "out_of_scope"}),
            );
            exchange.outbox.extend(decline);
        } else if kind == "question" {
            match self.decide_question(&mut state, &mut exchange, &repos, &referenced, now) {
                Decided::Settled { decisions } => decisions_changed = decisions,
                Decided::Inbox(made) => item = Some(*made),
                Decided::ByItself(rule) => answer_by_itself = Some(rule),
            }
        } else if let Some(decision) =
            decisions::covering(&state.decisions, &kind, &owner, repo).cloned()
        {
            exchange.decided_by = Some("rule".into());
            exchange.rule = Some(decision.id.clone());
            if let Some(d) = state.decisions.iter_mut().find(|d| d.id == decision.id) {
                d.uses += 1;
                d.last_used = Some(now);
            }
            decisions_changed = true;
            if decision.decision == "accept" {
                self.accept_locked(&state, &mut exchange, Some(&decision.id));
            } else {
                exchange.state = "declined".into();
                let decline = self.reply_locked(
                    &state,
                    &exchange,
                    "decline",
                    json!({"reason": "owner_declined", "by_rule": decision.id}),
                );
                exchange.outbox.extend(decline);
            }
        } else if self.inbox_full(&state, &owner) {
            self.decline_busy(&state, &mut exchange);
        } else {
            let made = inbox::review_request_item(
                &exchange.correlation_id,
                &from,
                &owner,
                body,
                envelope["expires_at"].as_str().unwrap_or(""),
                now,
            );
            exchange.state = "inbox".into();
            exchange.inbox_item = Some(made.id.clone());
            state.inbox.insert(made.id.clone(), made.clone());
            item = Some(made);
        }
        state
            .exchanges
            .insert(exchange.correlation_id.clone(), exchange.clone());
        let decisions = decisions_changed.then(|| state.decisions.clone());
        drop(state);
        if let Some(decisions) = decisions {
            self.save_decisions(&decisions);
        }
        if let Some(item) = item {
            self.save_item(&item);
        }
        self.save_exchange(&exchange);
        self.outbox.notify_one();
        if admit {
            super::hosting::admit(self, exchange.correlation_id.clone(), false);
        }
        if let Some(rule) = answer_by_itself {
            let link = self.clone();
            let cid = exchange.correlation_id.clone();
            tokio::spawn(async move {
                link.answer_by_itself(cid, rule, repos, referenced).await;
            });
        }
    }

    /// The repositories a question is about (protocol.md 5.2), each once, compared ignoring ASCII
    /// case, and the job references among them that are obid's own jobs. A job reference counts
    /// only when the job is obid's own and runs in the repository it names (5.9): otherwise it is
    /// something obid doesn't know, and names no repository.
    fn question_repos(&self, body: &Value) -> (Vec<String>, Vec<String>) {
        let mut repos: Vec<String> = Vec::new();
        let mut referenced = Vec::new();
        for r in body["about"].as_array().into_iter().flatten() {
            let repo = r["repo"].as_str().unwrap_or("");
            if r["kind"] == "job" {
                let job = r["job"].as_str().unwrap_or("");
                let ours = self
                    .jobs
                    .get(job)
                    .is_some_and(|j| j.repo.eq_ignore_ascii_case(repo));
                if !ours {
                    continue;
                }
                referenced.push(job.to_owned());
            }
            if !repo.is_empty() && !repos.iter().any(|r| r.eq_ignore_ascii_case(repo)) {
                repos.push(repo.to_owned());
            }
        }
        (repos, referenced)
    }

    /// Whether the sender's `owner` has as many requests waiting in the inbox as the limit allows.
    fn inbox_full(&self, state: &State, owner: &str) -> bool {
        let waiting = state
            .inbox
            .values()
            .filter(|i| {
                i.kind == "obiRequest"
                    && i.done.is_none()
                    && i.obi.as_ref().is_some_and(|o| o["fromOwner"] == owner)
            })
            .count();
        waiting >= state.sharing.limits.inbox_per_owner as usize
    }

    /// Declines with reason `busy`: nothing reaches the inbox.
    fn decline_busy(&self, state: &State, exchange: &mut Exchange) {
        exchange.state = "declined".into();
        exchange.decided_by = None;
        exchange.rule = None;
        let decline = self.reply_locked(state, exchange, "decline", json!({"reason": "busy"}));
        exchange.outbox.extend(decline);
    }

    /// A question (protocol.md section 11, step 5 and "Questions"): a remembered decline that
    /// covers each repository it is about declines it; the same question open already is `busy`;
    /// a sharing rule for the asker that covers it, with the self-answer limit not spent, lets the
    /// Obi answer by itself; else it goes to the owner's inbox, or is `busy` when that is full.
    fn decide_question(
        &self,
        state: &mut State,
        exchange: &mut Exchange,
        repos: &[String],
        referenced: &[String],
        now: i64,
    ) -> Decided {
        let owner = exchange.peer_owner.clone().unwrap_or_default();
        if self.decline_remembered(state, exchange, repos, now) {
            return Decided::Settled { decisions: true };
        }
        let body = &exchange.request["body"];
        let asked_already = state.exchanges.values().any(|e| {
            e.direction == "incoming"
                && e.kind == "question"
                && e.peer_owner.as_deref() == Some(owner.as_str())
                && (e.state == "inbox" || e.state == "answering")
                && e.request["body"]["text"] == body["text"]
                && e.request["body"].get("about") == body.get("about")
        });
        if asked_already {
            self.decline_busy(state, exchange);
            return Decided::Settled { decisions: false };
        }
        if let Some(rule) = state.sharing.covering(&owner, repos).cloned() {
            let limits = state.sharing.limits;
            state.all_self_answers.retain(|t| *t > now - 3600);
            let all = state.all_self_answers.len();
            let started = state.self_answers.entry(owner.clone()).or_default();
            started.retain(|t| *t > now - 3600);
            if started.len() < limits.self_answers_per_hour as usize
                && all < limits.self_answers_per_hour_total as usize
            {
                // It counts when obid takes it on, whatever the run ends in.
                started.push(now);
                state.all_self_answers.push(now);
                exchange.self_answered = Some(now);
                exchange.state = "answering".into();
                exchange.decided_by = Some("sharing".into());
                exchange.rule = Some(rule.id.clone());
                return Decided::ByItself(rule);
            }
        }
        match self.question_to_inbox(state, exchange, repos, referenced, now) {
            Some(item) => Decided::Inbox(Box::new(item)),
            None => Decided::Settled { decisions: false },
        }
    }

    /// Declines the question with reason `owner_declined` when a remembered decline covers it,
    /// repository by repository (`by_rule` its id, counted as a use): whether it did.
    fn decline_remembered(
        &self,
        state: &mut State,
        exchange: &mut Exchange,
        repos: &[String],
        now: i64,
    ) -> bool {
        let owner = exchange.peer_owner.clone().unwrap_or_default();
        let Some(decision) = decisions::covering_question(&state.decisions, &owner, repos).cloned()
        else {
            return false;
        };
        exchange.decided_by = Some("rule".into());
        exchange.rule = Some(decision.id.clone());
        if let Some(d) = state.decisions.iter_mut().find(|d| d.id == decision.id) {
            d.uses += 1;
            d.last_used = Some(now);
        }
        exchange.state = "declined".into();
        let decline = self.reply_locked(
            state,
            exchange,
            "decline",
            json!({"reason": "owner_declined", "by_rule": decision.id}),
        );
        exchange.outbox.extend(decline);
        true
    }

    /// A question obid is answering by itself that a remembered decline now covers (the owner said
    /// "Decline, and remember" while it waited or ran): declined as one that came in covered.
    /// Whether it was. Takes the lock.
    fn declined_meanwhile(&self, cid: &str, repos: &[String]) -> bool {
        let (exchange, decisions) = {
            let mut state = self.lock();
            let Some(mut exchange) = state
                .exchanges
                .get(cid)
                .filter(|e| e.state == "answering")
                .cloned()
            else {
                return false;
            };
            let now = time::now();
            if !self.decline_remembered(&mut state, &mut exchange, repos, now) {
                return false;
            }
            exchange.updated = now;
            state.exchanges.insert(cid.to_owned(), exchange.clone());
            (exchange, state.decisions.clone())
        };
        self.save_decisions(&decisions);
        self.save_exchange(&exchange);
        self.outbox.notify_one();
        true
    }

    /// Puts the question in the owner's inbox (`inbox`), or declines it `busy` when the asker's
    /// owner has as many requests waiting there as the limit allows: the item, when one was made.
    fn question_to_inbox(
        &self,
        state: &mut State,
        exchange: &mut Exchange,
        repos: &[String],
        referenced: &[String],
        now: i64,
    ) -> Option<Item> {
        let owner = exchange.peer_owner.clone().unwrap_or_default();
        if self.inbox_full(state, &owner) {
            self.decline_busy(state, exchange);
            return None;
        }
        let made = inbox::question_item(exchange, repos, referenced, now);
        exchange.state = "inbox".into();
        exchange.decided_by = None;
        exchange.rule = None;
        exchange.inbox_item = Some(made.id.clone());
        state.inbox.insert(made.id.clone(), made.clone());
        Some(made)
    }

    /// A question the Obi was answering by itself, and couldn't: to the owner's inbox (or `busy`).
    fn to_owner(&self, cid: &str) {
        let Some(body) = self
            .lock()
            .exchanges
            .get(cid)
            .map(|e| e.request["body"].clone())
        else {
            return;
        };
        let (repos, referenced) = self.question_repos(&body);
        let (exchange, item) = {
            let mut state = self.lock();
            let Some(mut exchange) = state
                .exchanges
                .get(cid)
                .filter(|e| e.state == "answering")
                .cloned()
            else {
                return;
            };
            let now = time::now();
            let item = self.question_to_inbox(&mut state, &mut exchange, &repos, &referenced, now);
            exchange.updated = now;
            state.exchanges.insert(cid.to_owned(), exchange.clone());
            (exchange, item)
        };
        if let Some(item) = &item {
            self.save_item(item);
        }
        self.save_exchange(&exchange);
        self.outbox.notify_one();
    }

    /// Accepts the request: `accept` (with `by_rule` when a decision made it) waits to be sent, and
    /// the review job starts. When the job can't even start, a failed result follows.
    fn accept_locked(&self, state: &State, exchange: &mut Exchange, rule: Option<&str>) {
        let body = match rule {
            Some(rule) => json!({"by_rule": rule}),
            None => json!({}),
        };
        exchange
            .outbox
            .extend(self.reply_locked(state, exchange, "accept", body));
        exchange.state = "accepted".into();
        let request = &exchange.request;
        let started = self.jobs.start_obi_review(ObiReview {
            correlation_id: exchange.correlation_id.clone(),
            request_id: request["id"].as_str().unwrap_or("").to_owned(),
            from: exchange.peer.clone(),
            from_owner: exchange.peer_owner.clone().unwrap_or_default(),
            body: request["body"].clone(),
        });
        match started {
            Ok(job) => exchange.job = Some(job.id),
            Err(refused) => {
                tracing::warn!(
                    "sphere: the review for {} couldn't start: {}",
                    exchange.correlation_id,
                    refused.0
                );
                exchange.error = Some(refused.0);
                let mut failed = failed_result(&exchange.request);
                if let Some(rule) = rule {
                    failed["by_rule"] = json!(rule);
                }
                exchange.result = Some(failed.clone());
                exchange.state = "failed".into();
                exchange
                    .outbox
                    .extend(self.reply_locked(state, exchange, "result", failed));
            }
        }
    }

    /// A reply in `exchange`, built and signed (runner-api.md, "Expiry of what obid sends"):
    /// created now, expiring the later of an hour from now and the request's expiry, at most the
    /// longest a message may live. `None` when obid has no key or membership to sign it with.
    fn reply_locked(
        &self,
        state: &State,
        exchange: &Exchange,
        kind: &str,
        mut body: Value,
    ) -> Option<Value> {
        let key = state.key.as_ref()?;
        // A guest job's decline says only unavailable, whatever this Mac's reason (its owner at it,
        // no slot, sharing off, not allowed, no VM now), and names no rule: why stays here, in the
        // log (the owner's decision of 2026-10-21; spec protocol.md section 4, rule 9). Only the
        // guest's own doing keeps its reason.
        // Nor whether a rule or this owner in person said yes or no.
        if exchange.kind == "run_request"
            && let Some(map) = body.as_object_mut()
        {
            map.remove("by_rule");
        }
        if kind == "decline" && exchange.kind == "run_request" {
            let reason = body["reason"].as_str().unwrap_or("other").to_owned();
            let said = match reason.as_str() {
                "expired" | "out_of_scope" | "share_used" => reason.clone(),
                _ => "unavailable".to_owned(),
            };
            tracing::info!(
                "sphere: declined {} ({reason}); the guest is told {said}",
                exchange.correlation_id
            );
            body = json!({"reason": said});
        }
        let membership = state.membership.as_ref()?;
        let now = time::now();
        let request_expires = exchange.expires_at().unwrap_or(now);
        let expires = (now + REPLY_LIFETIME)
            .max(request_expires)
            .min(now + obi_protocol::MAX_LIFETIME_SECONDS);
        let unsigned = json!({
            "protocol": obi_protocol::PROTOCOL,
            "id": new_uuid(),
            "type": kind,
            "from": membership.obi_id,
            "to": exchange.peer,
            "sphere": membership.sphere,
            "correlation_id": exchange.correlation_id,
            "in_reply_to": exchange.correlation_id,
            "created_at": time::format(now),
            "expires_at": time::format(expires),
            "key_id": key.key_id(),
            "body": body,
        });
        let Value::Object(unsigned) = unsigned else {
            unreachable!("an envelope is an object")
        };
        match obi_protocol::envelope::sign(&unsigned, key) {
            Ok(signed) => Some(signed),
            Err(e) => {
                tracing::error!("sphere: can't sign a {kind}: {e}");
                None
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // Sending replies, and the clock

    /// Starts the sender and the clock, once: they stop by themselves when obid leaves its Sphere.
    fn start_sender(self: &Arc<Self>) {
        if self.sender_running.swap(true, Ordering::SeqCst) {
            return;
        }
        let link = self.clone();
        tokio::spawn(async move {
            tokio::select! {
                () = link.clone().run_sender() => {}
                () = stopped(link.stopping.clone()) => {}
            }
        });
    }

    async fn run_sender(self: Arc<Self>) {
        let mut backoff = Duration::from_secs(1);
        loop {
            if !self.is_joined() {
                self.sender_running.store(false, Ordering::SeqCst);
                return;
            }
            self.expire();
            let all_sent = self.send_waiting().await;
            let wait = if all_sent {
                backoff = Duration::from_secs(1);
                Duration::from_secs(2)
            } else {
                let wait = backoff;
                backoff = (backoff * 2).min(BACKOFF_MAX);
                wait
            };
            tokio::select! {
                () = self.outbox.notified() => {}
                () = tokio::time::sleep(wait) => {}
            }
        }
    }

    /// Sends every waiting reply, exchange by exchange, oldest first: `false` when one couldn't
    /// go and should be tried again.
    async fn send_waiting(&self) -> bool {
        let mut waiting: Vec<(i64, String)> = self
            .lock()
            .exchanges
            .values()
            .filter(|e| !e.outbox.is_empty())
            .map(|e| (e.updated, e.correlation_id.clone()))
            .collect();
        waiting.sort();
        let mut all = true;
        for (_, cid) in waiting {
            all &= self.flush(&cid).await;
        }
        all
    }

    /// Sends the exchange's waiting replies, in order: `true` once none is left to send.
    async fn flush(&self, cid: &str) -> bool {
        let _one = self.sending.lock().await;
        loop {
            let next = {
                let state = self.lock();
                match state.exchanges.get(cid).and_then(|e| e.outbox.first()) {
                    Some(next) => next.clone(),
                    None => return true,
                }
            };
            let expires = next["expires_at"]
                .as_str()
                .and_then(time::parse)
                .unwrap_or(0);
            if expires <= time::now() {
                self.update_exchange(cid, |e| {
                    e.outbox.remove(0);
                    e.error = Some("A reply expired before the Sphere took it.".into());
                });
                continue;
            }
            let sent = match self.token().await {
                Ok(token) => match self.client() {
                    Ok(client) => client.send(&token, &next).await,
                    Err(e) => Err(e),
                },
                Err(e) => Err(e),
            };
            match sent {
                Ok(sent) => {
                    let id = next["id"].as_str().unwrap_or("").to_owned();
                    self.keep_receipt(&sent);
                    self.lock().seen.insert(id);
                    self.update_exchange(cid, |e| {
                        e.outbox.remove(0);
                        e.messages.push(Message {
                            direction: "sent".into(),
                            seq: Some(sent.seq),
                            at: sent.recorded_at.clone(),
                            envelope: next.clone(),
                        });
                    });
                }
                Err(ClientError::Refused {
                    status,
                    code,
                    message,
                }) if status < 500 && status != 401 && status != 429 && status != 408 => {
                    // The Sphere won't take it, now or later: what's left of the exchange can't go.
                    let line = format!(
                        "The Sphere refused a {}: {code}: {message}",
                        next["type"].as_str().unwrap_or("reply")
                    );
                    tracing::warn!("sphere: exchange {cid}: {line}");
                    self.update_exchange(cid, |e| {
                        e.outbox.clear();
                        e.error = Some(line.clone());
                    });
                    return true;
                }
                Err(e) => {
                    self.refused_token(&e);
                    self.note_error(&e);
                    return false;
                }
            }
        }
    }

    /// Changes the exchange `cid`, keeps it and tells the apps.
    fn update_exchange(&self, cid: &str, change: impl FnOnce(&mut Exchange)) -> Option<Exchange> {
        let exchange = {
            let mut state = self.lock();
            let exchange = state.exchanges.get_mut(cid)?;
            change(exchange);
            exchange.updated = time::now();
            exchange.clone()
        };
        self.save_exchange(&exchange);
        Some(exchange)
    }

    /// Requests that expired: one waiting in the inbox (or a question the Obi is still answering by
    /// itself) is settled by itself, with no answer, and declined with reason `expired`; one this
    /// Obi sent with no result or answer is `expired`.
    fn expire(&self) {
        let now = time::now();
        self.settle_open(
            |e| e.expires_at().is_some_and(|t| t <= now) && e.kind != "share_offer",
            true,
            "expired",
            Some("expired"),
        );
    }

    /// obid's membership was revoked: no open incoming request can be answered any more, and the
    /// clock that would expire them has stopped with the sender. Each is settled here, `declined`
    /// with its inbox item done, and its peer isn't told: the sender stops at revocation, so a
    /// decline queued now would never go, and none is built.
    fn settle_on_revoke(&self) {
        self.settle_open(|_| true, false, "declined", None);
    }

    /// Settles the open requests `due` picks: an incoming one goes to `settled` with its inbox item
    /// done, and a decline for `reason` queued when there is one; an outgoing one, if `outgoing`,
    /// goes to `settled`.
    fn settle_open(
        &self,
        due: impl Fn(&Exchange) -> bool,
        outgoing: bool,
        settled: &str,
        reason: Option<&str>,
    ) {
        let now = time::now();
        let mut changed = Vec::new();
        let mut items = Vec::new();
        {
            let mut state = self.lock();
            let due: Vec<String> = state
                .exchanges
                .values()
                .filter(|e| due(e))
                .filter(|e| match e.direction.as_str() {
                    "incoming" => e.state == "inbox" || e.state == "answering",
                    _ => outgoing && (e.state == "sent" || e.state == "accepted"),
                })
                .map(|e| e.correlation_id.clone())
                .collect();
            for cid in due {
                let Some(mut exchange) = state.exchanges.get(&cid).cloned() else {
                    continue;
                };
                exchange.state = settled.into();
                exchange.updated = now;
                if exchange.direction == "incoming" {
                    if let Some(reason) = reason {
                        let decline = self.reply_locked(
                            &state,
                            &exchange,
                            "decline",
                            json!({"reason": reason}),
                        );
                        exchange.outbox.extend(decline);
                    }
                    if let Some(item) = exchange
                        .inbox_item
                        .as_ref()
                        .and_then(|id| state.inbox.get_mut(id))
                        .filter(|i| i.done.is_none())
                    {
                        item.done = Some(now);
                        items.push(item.clone());
                    }
                }
                state.exchanges.insert(cid, exchange.clone());
                changed.push(exchange);
            }
        }
        for item in &items {
            self.save_item(item);
        }
        for exchange in &changed {
            self.save_exchange(exchange);
        }
    }

    // -----------------------------------------------------------------------------------------
    // The review job's end: the publish gate and the result

    /// The review job of an exchange ended (before the job says so): `done` with its result body,
    /// or not. The publish gate scans every text of the result; clean, it goes; a finding, or a
    /// scanner that can't run, sends a failed result with no text. Waits for the first try to send.
    pub async fn review_ended(&self, job: Job, done: bool) {
        let Some(obi) = job.obi.clone() else { return };
        let cid = obi.correlation_id;
        let rule = {
            let state = self.lock();
            match state.exchanges.get(&cid) {
                Some(e) if e.direction == "incoming" && !e.ended() => e.rule.clone(),
                _ => return,
            }
        };
        let body = job
            .review_result
            .clone()
            .filter(|b| done && b["outcome"] != "failed");
        let Some(mut body) = body else {
            self.reply_failed(&cid, None).await;
            return;
        };
        let texts = every_text(&body);
        let scratch = self.config.home.join("tmp");
        let verdict = scan::scan(&texts, &scratch).await;
        let (scan_json, failure) = match &verdict {
            scan::Verdict::Clean => (json!({"ran": true, "clean": true}), None),
            scan::Verdict::Found(found) => {
                let places: Vec<String> = found.iter().take(3).map(ToString::to_string).collect();
                (
                    json!({"ran": true, "clean": false}),
                    Some(format!(
                        "The publish gate found a possible secret in {}: no text was sent.",
                        places.join(", ")
                    )),
                )
            }
            scan::Verdict::CouldNotRun(why) => (
                json!({"ran": false, "clean": false}),
                Some(format!(
                    "The secret scan couldn't run ({why}): no text was sent."
                )),
            ),
        };
        if let Some(why) = failure {
            tracing::warn!("sphere: exchange {cid}: {why}");
            self.reply_failed(&cid, Some((scan_json, why))).await;
            return;
        }
        if let Some(rule) = rule {
            body["by_rule"] = json!(rule);
        }
        let queued = {
            let mut state = self.lock();
            let Some(mut exchange) = state.exchanges.get(&cid).cloned() else {
                return;
            };
            let Some(result) = self.reply_locked(&state, &exchange, "result", body.clone()) else {
                return;
            };
            exchange.outbox.push(result);
            exchange.result = Some(body);
            exchange.publish_scan = Some(scan_json);
            exchange.state = "done".into();
            exchange.updated = time::now();
            state.exchanges.insert(cid.clone(), exchange.clone());
            exchange
        };
        self.save_exchange(&queued);
        self.send_now(&cid).await;
    }

    /// The Obi answers a question by itself under `rule` (protocol.md section 11, "Questions"): a
    /// model writes it from the rule's material only ([`answering`]), then the publish gate scans
    /// it. Clean, the `answer` goes, `by: obi` with the rule in `by_rule`; a possible secret, or a
    /// scanner that can't run, declines it `other` with no text. A model that says it can't
    /// answer, or that fails, sends the question to the owner.
    async fn answer_by_itself(
        self: Arc<Self>,
        cid: String,
        rule: Rule,
        repos: Vec<String>,
        referenced: Vec<String>,
    ) {
        let Ok(_run) = self.answering.acquire().await else {
            return;
        };
        // A remembered decline the owner made while it waited covers it now: no run.
        if self.declined_meanwhile(&cid, &repos) {
            return;
        }
        // Once a run may start: the question still waits for it, unexpired, and the rule is still
        // there and still covers it (the owner may have changed it meanwhile). Else no run.
        let snapshot = {
            let state = self.lock();
            let Some(e) = state.exchanges.get(&cid).filter(|e| {
                e.state == "answering" && e.expires_at().is_none_or(|t| t > time::now())
            }) else {
                return;
            };
            let owner = e.peer_owner.clone().unwrap_or_default();
            state
                .sharing
                .rules
                .iter()
                .find(|r| r.id == rule.id && r.covers(&owner, &repos))
                .cloned()
                .map(|rule| {
                    let shared: Vec<Exchange> = state
                        .exchanges
                        .values()
                        .filter(|x| x.direction == "incoming" && x.peer_owner == e.peer_owner)
                        .cloned()
                        .collect();
                    let declined = decisions::declined_repos(&state.decisions, &owner);
                    (e.request["body"].clone(), owner, shared, declined, rule)
                })
        };
        let Some((question, owner, shared, declined, rule)) = snapshot else {
            self.to_owner(&cid);
            return;
        };
        let jobs = self.jobs.list(usize::MAX);
        let shared: Vec<&Exchange> = shared.iter().collect();
        let material = answering::material(
            &rule,
            &owner,
            &repos,
            &declined,
            &referenced,
            &jobs,
            &shared,
        );
        let dir = self.config.home.join("answers").join(&cid);
        let written = match answering::write(
            &self.config,
            &self.sandbox,
            &dir,
            &owner,
            &question,
            &material,
        )
        .await
        {
            Ok(Some(written)) => written,
            Ok(None) => {
                self.to_owner(&cid);
                return;
            }
            Err(why) => {
                // Why names checks, never the question's or the model's words.
                tracing::warn!("sphere: exchange {cid}: obid couldn't answer by itself ({why})");
                self.to_owner(&cid);
                return;
            }
        };
        let mut body = json!({"by": "obi", "text": written.text, "by_rule": rule.id});
        if !written.refs.is_empty() {
            body["refs"] = json!(written.refs);
        }
        if let Some(choice) = written.choice {
            body["choice"] = json!(choice);
        }
        if !obi_protocol::schema::is_valid("actions/answer", &body) {
            tracing::warn!("sphere: exchange {cid}: the answer obid wrote isn't the spec's");
            self.to_owner(&cid);
            return;
        }
        let scratch = self.config.home.join("tmp");
        let _ = std::fs::create_dir_all(&scratch);
        let verdict = scan::scan(&every_text(&body), &scratch).await;
        let (scan_json, failure) = match &verdict {
            scan::Verdict::Clean => (json!({"ran": true, "clean": true}), None),
            scan::Verdict::Found(found) => {
                let places: Vec<String> = found.iter().take(3).map(ToString::to_string).collect();
                (
                    json!({"ran": true, "clean": false}),
                    Some(format!(
                        "The publish gate found a possible secret in {}: no text was sent.",
                        places.join(", ")
                    )),
                )
            }
            scan::Verdict::CouldNotRun(why) => (
                json!({"ran": false, "clean": false}),
                Some(format!(
                    "The secret scan couldn't run ({why}): no text was sent."
                )),
            ),
        };
        let now = time::now();
        let queued = {
            let mut state = self.lock();
            let Some(mut exchange) = state
                .exchanges
                .get(&cid)
                .filter(|e| e.state == "answering" && e.expires_at().is_none_or(|t| t > now))
                .cloned()
            else {
                return;
            };
            // A remembered decline made while the model ran covers it now: declined, and nothing
            // the model wrote goes.
            if self.decline_remembered(&mut state, &mut exchange, &repos, now) {
                exchange.updated = now;
                state.exchanges.insert(cid.clone(), exchange.clone());
                let decisions = state.decisions.clone();
                drop(state);
                self.save_decisions(&decisions);
                self.save_exchange(&exchange);
                self.outbox.notify_one();
                return;
            }
            // The rule may have gone while the model ran: then nothing it wrote goes.
            let still = state
                .sharing
                .rules
                .iter()
                .any(|r| r.id == rule.id && r.covers(&owner, &repos));
            let reply = match &failure {
                _ if !still => None,
                None => self.reply_locked(&state, &exchange, "answer", body.clone()),
                Some(_) => {
                    self.reply_locked(&state, &exchange, "decline", json!({"reason": "other"}))
                }
            };
            let Some(reply) = reply else {
                drop(state);
                self.to_owner(&cid);
                return;
            };
            exchange.outbox.push(reply);
            match failure {
                None => {
                    exchange.result = Some(body);
                    exchange.state = "done".into();
                    if let Some(r) = state.sharing.rules.iter_mut().find(|r| r.id == rule.id) {
                        r.uses += 1;
                        r.last_used = Some(now);
                    }
                    // Kept under the lock, so an older copy never overwrites a newer one.
                    self.save_sharing(&state.sharing);
                }
                Some(why) => {
                    tracing::warn!("sphere: exchange {cid}: {why}");
                    exchange.state = "declined".into();
                    exchange.error = Some(why);
                }
            }
            exchange.publish_scan = Some(scan_json);
            exchange.updated = now;
            state.exchanges.insert(cid.clone(), exchange.clone());
            exchange
        };
        self.save_exchange(&queued);
        self.send_now(&cid).await;
    }

    /// Sends a failed result with no text (and `by_rule` when a decision accepted it): the work, or
    /// the publish gate (`scan`: what it found, and why nothing with text went), failed.
    async fn reply_failed(&self, cid: &str, scan: Option<(Value, String)>) {
        let queued = {
            let mut state = self.lock();
            let Some(mut exchange) = state.exchanges.get(cid).cloned() else {
                return;
            };
            if exchange.direction != "incoming" || exchange.ended() {
                return;
            }
            let mut body = failed_result(&exchange.request);
            if let Some(rule) = &exchange.rule {
                body["by_rule"] = json!(rule);
            }
            let Some(result) = self.reply_locked(&state, &exchange, "result", body.clone()) else {
                return;
            };
            exchange.outbox.push(result);
            exchange.result = Some(body);
            exchange.state = "failed".into();
            if let Some((scan, why)) = scan {
                exchange.publish_scan = Some(scan);
                exchange.error = Some(why);
            }
            exchange.updated = time::now();
            state.exchanges.insert(cid.to_owned(), exchange.clone());
            exchange
        };
        self.save_exchange(&queued);
        self.send_now(cid).await;
    }

    /// Tries to send the exchange's waiting replies now, for at most 30 seconds; the sender tries
    /// again later whatever is left.
    async fn send_now(&self, cid: &str) {
        let sent = tokio::time::timeout(Duration::from_secs(30), self.flush(cid)).await;
        if !matches!(sent, Ok(true)) {
            self.outbox.notify_one();
        }
    }

    // -----------------------------------------------------------------------------------------
    // Outgoing requests and exchanges

    /// `POST /v1/obid/sphere/requests`: the owner's Obi asks another Obi.
    pub async fn request(&self, body: &[u8]) -> Result<Value, ApiError> {
        let map = object(body, &["to", "type", "body", "expiresIn"])?;
        let invalid = |m: String| api(StatusCode::UNPROCESSABLE_ENTITY, m);
        let joined = self
            .lock()
            .membership
            .clone()
            .filter(|m| m.state == "joined")
            .ok_or_else(|| api(StatusCode::CONFLICT, "obid hasn't joined a Sphere."))?;
        let to = text_field(&map, "to")?.to_owned();
        let kind = text_field(&map, "type")?.to_owned();
        if !obi_protocol::REQUEST_TYPES.contains(&kind.as_str()) {
            return Err(invalid(format!(
                "type is review_request, question, handoff, run_request or share_offer, not {kind}."
            )));
        }
        let action = map
            .get("body")
            .ok_or_else(|| invalid("body is the action's fields, and it's required.".into()))?
            .clone();
        let errors = obi_protocol::schema::errors(&format!("actions/{kind}"), &action, 5);
        if !errors.is_empty() {
            return Err(invalid(format!(
                "body doesn't match the spec's {kind}: {}",
                errors.join("; ")
            )));
        }
        let expires_in = map
            .get("expiresIn")
            .and_then(Value::as_i64)
            .filter(|n| (60..=obi_protocol::MAX_LIFETIME_SECONDS).contains(n))
            .ok_or_else(|| invalid("expiresIn is 60 to 2,592,000 seconds.".into()))?;
        if to == joined.obi_id {
            return Err(invalid("An Obi doesn't ask itself.".into()));
        }
        // Every text field, before anything is signed or sent (#478).
        let texts = every_text(&action);
        let scratch = self.config.home.join("tmp");
        std::fs::create_dir_all(&scratch).map_err(|e| {
            api(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("obid couldn't scan the request: {e}"),
            )
        })?;
        match scan::scan(&texts, &scratch).await {
            scan::Verdict::Clean => {}
            scan::Verdict::Found(found) => {
                let places: Vec<String> = found.iter().take(3).map(ToString::to_string).collect();
                return Err(invalid(format!(
                    "The secret scan found a possible secret in {}: nothing was sent.",
                    places.join(", ")
                )));
            }
            scan::Verdict::CouldNotRun(why) => {
                return Err(invalid(format!(
                    "The secret scan couldn't run ({why}): nothing was sent."
                )));
            }
        }
        if let Err(e) = self.read_directory().await {
            self.note_error(&e);
            return Err(from_client(&e));
        }
        let (envelope, peer_owner) = {
            let state = self.lock();
            let member = state
                .directory
                .members
                .get(&to)
                .ok_or_else(|| invalid(format!("{to} isn't a member of {}.", joined.sphere)))?;
            if !member.active {
                return Err(invalid(format!("{to} has been revoked.")));
            }
            if !member.accepts.contains(&kind) {
                return Err(invalid(format!("{to}'s card doesn't accept {kind}.")));
            }
            if kind == "share_offer"
                && !state.sharing.grants.iter().any(|g| {
                    g.id == action["grant"].as_str().unwrap_or("") && g.offered_to(&member.owner)
                })
            {
                return Err(invalid(
                    "obid offers only a share its owner set in Settings › Sharing.".into(),
                ));
            }
            let key = state
                .key
                .clone()
                .ok_or_else(|| api(StatusCode::CONFLICT, "There's no Obi key."))?;
            let id = new_uuid();
            let now = time::now();
            let unsigned = json!({
                "protocol": obi_protocol::PROTOCOL,
                "id": id,
                "type": kind,
                "from": joined.obi_id,
                "to": to,
                "sphere": joined.sphere,
                "correlation_id": id,
                "created_at": time::format(now),
                "expires_at": time::format(now + expires_in),
                "key_id": key.key_id(),
                "body": action,
            });
            let Value::Object(unsigned) = unsigned else {
                unreachable!("an envelope is an object")
            };
            let envelope = obi_protocol::envelope::sign(&unsigned, &key).map_err(|e| {
                api(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("obid couldn't sign it: {e}"),
                )
            })?;
            // What the receiver will check, checked here first.
            let context = obi_protocol::envelope::Context {
                now: Some(now),
                sphere: Some(joined.sphere.clone()),
                receiver: Some(to.clone()),
                keys: state.directory.keys.clone(),
                seq: None,
                seen_ids: Vec::new(),
            };
            obi_protocol::envelope::verify(&envelope, &context).map_err(|r| {
                invalid(format!("That message wouldn't pass the spec's checks: {r}"))
            })?;
            (envelope, member.owner.clone())
        };
        let cid = envelope["id"].as_str().unwrap_or("").to_owned();
        let mut exchange = Exchange::new("outgoing", envelope.clone(), to, Some(peer_owner));
        exchange.state = "sent".into();
        // Kept before it goes, so a reply that comes back at once finds it.
        self.lock().exchanges.insert(cid.clone(), exchange.clone());
        let sent = match self.token().await {
            Ok(token) => match self.client() {
                Ok(client) => client.send(&token, &envelope).await,
                Err(e) => Err(e),
            },
            Err(e) => Err(e),
        };
        match sent {
            Ok(sent) => {
                self.keep_receipt(&sent);
                self.lock().seen.insert(cid.clone());
                let updated = self.update_exchange(&cid, |e| {
                    e.messages.insert(
                        0,
                        Message {
                            direction: "sent".into(),
                            seq: Some(sent.seq),
                            at: sent.recorded_at.clone(),
                            envelope: envelope.clone(),
                        },
                    );
                });
                Ok(updated.unwrap_or(exchange).to_json())
            }
            Err(e) => {
                self.lock().exchanges.remove(&cid);
                self.exchanges.remove(&cid);
                self.refused_token(&e);
                Err(from_client(&e))
            }
        }
    }

    /// `GET /v1/obid/sphere/exchanges?limit=50`, the latest first.
    pub fn exchanges_json(&self, limit: usize) -> Value {
        let state = self.lock();
        let mut all: Vec<&Exchange> = state.exchanges.values().collect();
        all.sort_by(|a, b| {
            b.created
                .cmp(&a.created)
                .then_with(|| b.correlation_id.cmp(&a.correlation_id))
        });
        Value::Array(all.into_iter().take(limit).map(Exchange::to_json).collect())
    }

    /// `GET /v1/obid/sphere/exchanges/{correlationId}`.
    pub fn exchange_json(&self, cid: &str) -> Option<Value> {
        self.lock().exchanges.get(cid).map(Exchange::to_json)
    }

    // -----------------------------------------------------------------------------------------
    // Decisions and the inbox

    /// `GET /v1/obid/decisions`, oldest first.
    pub fn decisions_json(&self) -> Value {
        Value::Array(
            self.lock()
                .decisions
                .iter()
                .map(Decision::to_json)
                .collect(),
        )
    }

    /// `DELETE /v1/obid/decisions/{id}`: `false` for one obid doesn't have.
    pub fn forget(&self, id: &str) -> bool {
        let decisions = {
            let mut state = self.lock();
            let before = state.decisions.len();
            state.decisions.retain(|d| d.id != id);
            if state.decisions.len() == before {
                return false;
            }
            state.decisions.clone()
        };
        self.save_decisions(&decisions);
        true
    }

    /// `GET /v1/inbox` (`done` false: open and put off, what needs the owner first, then FYI,
    /// then ignore, each the longest-waiting first) or `?state=done` (the latest settled first, at
    /// most `limit`).
    pub fn inbox_json(&self, done: bool, limit: usize) -> Value {
        self.settle_stale_starts();
        let state = self.lock();
        let mut items: Vec<&Item> = state
            .inbox
            .values()
            .filter(|i| i.done.is_some() == done)
            .collect();
        let sorts = self.sorts(&state.inbox);
        if done {
            items.sort_by(|a, b| b.done.cmp(&a.done).then_with(|| b.id.cmp(&a.id)));
            items.truncate(limit);
        } else {
            needs_you_first(&mut items, &sorts);
        }
        let shown = items.into_iter().map(|i| {
            let mut shown = i.to_json();
            shown["triage"] = sorts.get(i).into();
            shown
        });
        Value::Array(shown.collect())
    }

    /// Settles an open item with no answer: what it asked about is gone (a shell command whose
    /// turn ended). Nothing for an item that's done already.
    pub fn settle(&self, id: &str) {
        let settled = {
            let mut state = self.lock();
            state
                .inbox
                .get_mut(id)
                .filter(|i| i.done.is_none())
                .map(|item| {
                    item.done = Some(time::now());
                    item.clone()
                })
        };
        if let Some(item) = settled {
            self.save_item(&item);
        }
    }

    /// The open items of a job that's gone are done, with no answer.
    pub fn settle_job(&self, job: &str) {
        let now = time::now();
        let settled: Vec<Item> = {
            let mut state = self.lock();
            state
                .inbox
                .values_mut()
                .filter(|i| i.job == job && i.done.is_none())
                .map(|i| {
                    i.done = Some(now);
                    i.clone()
                })
                .collect()
        };
        for item in &settled {
            self.save_item(item);
        }
    }

    /// Something Oby's brain planned that persists or widens trust waits in the inbox for the
    /// owner's own `Confirm` (#546): the brain never carries it out itself. A conversation's shell
    /// keeps its `permission` items here too.
    pub fn add_confirm(&self, item: Item) -> Item {
        self.lock().inbox.insert(item.id.clone(), item.clone());
        self.save_item(&item);
        item
    }

    /// [`Link::add_confirm`], unless a `confirm` item for the same job and action is still open:
    /// that one stands, so a caller asking again and again adds nothing (crate::jobs,
    /// `confirm_past_safety`).
    pub fn add_confirm_once(&self, item: Item) -> Item {
        let action = |i: &Item| i.confirm.as_ref().map(|c| c.action.clone());
        {
            let state = self.lock();
            if let Some(open) = state.inbox.values().find(|i| {
                i.kind == "confirm"
                    && i.done.is_none()
                    && i.job == item.job
                    && action(i) == action(&item)
            }) {
                return open.clone();
            }
        }
        self.add_confirm(item)
    }

    /// `POST /v1/inbox/{id}/answer` on a `confirm` item: `Confirm` carries out what its title
    /// says; `Cancel`, done or later do nothing.
    async fn answer_confirm(
        self: &Arc<Self>,
        mut item: Item,
        answer: Option<String>,
        later: Option<i64>,
    ) -> Result<Value, ApiError> {
        if let Some(at) = later {
            item.later = Some(at);
        } else {
            if let Some(answer) = &answer {
                if answer != inbox::CONFIRM && answer != inbox::CANCEL {
                    return Err(api(
                        StatusCode::UNPROCESSABLE_ENTITY,
                        format!("The answer is {} or {}.", inbox::CONFIRM, inbox::CANCEL),
                    ));
                }
                if answer == inbox::CONFIRM {
                    let done = match item.confirm.clone() {
                        Some(confirmed) => self.carry_out(*confirmed).await,
                        None => Err(api(StatusCode::CONFLICT, "That item says nothing to do.")),
                    };
                    // What it was for moved on (the permission was answered, the job ended): the
                    // item is closed with why, never left open to fail again.
                    if let Err(why) = done {
                        item.done = Some(time::now());
                        item.answer = Some(answer.clone());
                        item.text = format!("{} It couldn't happen: {}", item.text, why.message);
                        self.lock().inbox.insert(item.id.clone(), item.clone());
                        self.save_item(&item);
                        return Err(why);
                    }
                }
            }
            item.done = Some(time::now());
            item.answer = answer;
        }
        self.lock().inbox.insert(item.id.clone(), item.clone());
        self.save_item(&item);
        Ok(item.to_json())
    }

    /// What a confirmed `confirm` item does: one dispatcher, a case per action.
    async fn carry_out(self: &Arc<Self>, confirmed: inbox::Confirmed) -> Result<(), ApiError> {
        let target = confirmed.target.as_str();
        match confirmed.action.as_str() {
            inbox::action::ALWAYS_ALLOW => {
                use crate::jobs::PermissionRefused;
                let permission = confirmed.payload["permission"].as_str().unwrap_or("");
                match self.jobs.answer_permission(
                    target,
                    permission,
                    crate::permissions::Decision::Always,
                    None,
                ) {
                    Ok(_) => Ok(()),
                    Err(PermissionRefused::NoJob) => {
                        Err(api(StatusCode::CONFLICT, "Its job is gone."))
                    }
                    Err(PermissionRefused::NotWaiting(why)) => Err(api(StatusCode::CONFLICT, why)),
                    Err(PermissionRefused::Refused(why)) => {
                        Err(api(StatusCode::UNPROCESSABLE_ENTITY, why))
                    }
                }
            }
            inbox::action::SET_MODE_BYPASS => {
                if !self.jobs.get(target).is_some_and(|j| j.status.is_active()) {
                    return Err(api(
                        StatusCode::CONFLICT,
                        "That job isn't running any more.",
                    ));
                }
                self.jobs
                    .set_mode(target, crate::permissions::Mode::Bypass)
                    .map(|_| ())
                    .ok_or_else(|| api(StatusCode::CONFLICT, "That job is gone."))
            }
            inbox::action::START_JOB => {
                let new: crate::jobs::NewJob =
                    serde_json::from_value(confirmed.payload["job"].clone())
                        .map_err(|_| api(StatusCode::CONFLICT, "That job's plan was lost."))?;
                self.jobs
                    .create(new)
                    .map(|_| ())
                    .map_err(|e| api(StatusCode::UNPROCESSABLE_ENTITY, e.0))
            }
            // Made before 2026-10-18 for one more round: the words now start a follow-up, as any
            // words for a job that ended do.
            inbox::action::MESSAGE_JOB => {
                let words = confirmed.payload["words"].as_str().unwrap_or("");
                match self
                    .jobs
                    .message(target, words, crate::jobs::Source::Confirmed)
                {
                    Some(Ok(_)) => Ok(()),
                    Some(Err(refused)) => Err(api(StatusCode::UNPROCESSABLE_ENTITY, refused.0)),
                    None => Err(api(StatusCode::CONFLICT, "That job is gone.")),
                }
            }
            inbox::action::DISMISS_JOB => match self.jobs.dismiss(target) {
                Some(Ok(_)) => Ok(()),
                Some(Err(refused)) => Err(api(StatusCode::CONFLICT, refused.0)),
                None => Err(api(StatusCode::CONFLICT, "That job is gone.")),
            },
            inbox::action::ADD_REPOSITORY => {
                // obid's own words of the review request (crate::github_work's typed fields).
                let (repo, number) = (
                    confirmed.payload["repo"].as_str().unwrap_or_default(),
                    confirmed.payload["number"].as_u64().unwrap_or_default(),
                );
                if self
                    .lock()
                    .inbox
                    .get(target)
                    .is_some_and(|i| i.done.is_some())
                {
                    return Err(api(StatusCode::CONFLICT, "That review request is settled."));
                }
                let (job, _) =
                    crate::github_work::start_adding(&self.jobs, &self.config, repo, number)
                        .await?;
                self.github_started(target, &job.id);
                Ok(())
            }
            inbox::action::REMEMBER_RULE => {
                let rule: Decision = serde_json::from_value(confirmed.payload["rule"].clone())
                    .map_err(|_| api(StatusCode::CONFLICT, "That rule's plan was lost."))?;
                let known = self.config.repos.get().iter().any(|r| r.repo == rule.repo);
                if !known
                    || !matches!(
                        rule.kind.as_str(),
                        decisions::EVENT_ALERT | decisions::EVENT_DEPLOY
                    )
                {
                    return Err(api(StatusCode::CONFLICT, "That rule isn't one Oby keeps."));
                }
                self.remember_rule(Decision {
                    id: decisions::new_id(),
                    created: time::now(),
                    uses: 0,
                    last_used: None,
                    ..rule
                });
                Ok(())
            }
            inbox::action::CREATE_ROUTINE => {
                let draft: crate::routines::Draft =
                    serde_json::from_value(confirmed.payload["routine"].clone())
                        .map_err(|_| api(StatusCode::CONFLICT, "That routine's plan was lost."))?;
                let routines = self
                    .jobs
                    .routines()
                    .ok_or_else(|| api(StatusCode::CONFLICT, "obid keeps no routines."))?;
                routines
                    .create(&self.jobs, draft, time::now())
                    .map(|_| ())
                    .map_err(|why| api(StatusCode::UNPROCESSABLE_ENTITY, why))
            }
            inbox::action::CHANGE_ROUTINE => {
                use crate::routines::{Change, NotRun};
                let routines = self
                    .jobs
                    .routines()
                    .ok_or_else(|| api(StatusCode::CONFLICT, "obid keeps no routines."))?;
                let gone = || api(StatusCode::CONFLICT, "That routine is gone.");
                // The card named its mode, tool, account and check: one changed since is a routine
                // the owner didn't see.
                let current = routines.get(target).ok_or_else(gone)?;
                let payload = &confirmed.payload;
                if payload["mode"] != serde_json::json!(current.mode)
                    || payload["agent"] != serde_json::json!(current.agent)
                    || payload["account"] != serde_json::json!(current.account)
                    || payload["check"] != serde_json::json!(current.check)
                {
                    return Err(api(
                        StatusCode::CONFLICT,
                        "The routine's mode, tool, account or check changed since Oby asked: ask again.",
                    ));
                }
                let now = time::now();
                let change = |change: Change| match routines.change(&self.jobs, target, change, now)
                {
                    None => Err(gone()),
                    Some(Err(why)) => Err(api(StatusCode::UNPROCESSABLE_ENTITY, why)),
                    Some(Ok(_)) => Ok(()),
                };
                match confirmed.payload["action"].as_str() {
                    Some("resume") => change(Change {
                        enabled: Some(true),
                        ..Default::default()
                    }),
                    Some("reschedule") => change(Change {
                        schedule: serde_json::from_value(confirmed.payload["schedule"].clone())
                            .ok(),
                        zone: confirmed.payload["zone"].as_str().map(str::to_owned),
                        ..Default::default()
                    }),
                    Some("delete") => routines.delete(target).then_some(()).ok_or_else(gone),
                    Some("run") => {
                        // Off the async threads: a run takes the routines' firing lock.
                        let (routines, target) = (routines.clone(), target.to_owned());
                        let ran = tokio::task::spawn_blocking(move || routines.run(&target, now))
                            .await
                            .map_err(|_| {
                                api(StatusCode::INTERNAL_SERVER_ERROR, "The run stopped.")
                            })?;
                        match ran {
                            Ok(_) => Ok(()),
                            Err(NotRun::NoRoutine) => Err(gone()),
                            Err(NotRun::Busy) => Err(api(
                                StatusCode::CONFLICT,
                                "Its previous run is still going.",
                            )),
                            Err(NotRun::Refused(why)) => {
                                Err(api(StatusCode::UNPROCESSABLE_ENTITY, why))
                            }
                        }
                    }
                    _ => Err(api(StatusCode::CONFLICT, "That change was lost.")),
                }
            }
            inbox::action::RETRY_JOB => {
                if self.jobs.get(target).is_some_and(|j| j.status.is_active()) {
                    return Err(api(StatusCode::CONFLICT, "That job is running again."));
                }
                match self.jobs.message(
                    target,
                    crate::brain::actions::TRY_AGAIN,
                    crate::jobs::Source::Confirmed,
                ) {
                    Some(Ok(_)) => Ok(()),
                    Some(Err(refused)) => Err(api(StatusCode::UNPROCESSABLE_ENTITY, refused.0)),
                    None => Err(api(StatusCode::CONFLICT, "That job is gone.")),
                }
            }
            // Proposed against the job as it was: after another round, a move or a new mode,
            // the title no longer says what Confirm would do.
            inbox::action::CONTINUE_JOB | inbox::action::DELETE_JOB | inbox::action::CHANGE_JOB
                if self
                    .jobs
                    .get(target)
                    .is_some_and(|j| j.snapshot() != confirmed.payload["snapshot"]) =>
            {
                Err(api(
                    StatusCode::CONFLICT,
                    "The job changed since Oby asked (another round, a move or a new mode): ask Oby again.",
                ))
            }
            inbox::action::CONTINUE_JOB => {
                let words = confirmed.payload["words"].as_str();
                match self.jobs.continue_job(target, words, "on your Confirm") {
                    Some(Ok(_)) => Ok(()),
                    Some(Err(refused)) => Err(api(StatusCode::CONFLICT, refused.0)),
                    None => Err(api(StatusCode::CONFLICT, "That job is gone.")),
                }
            }
            inbox::action::DELETE_JOB => match self.jobs.delete(target).await {
                Some(Ok(_)) => {
                    self.settle_job(target);
                    Ok(())
                }
                Some(Err(refused)) => Err(api(StatusCode::CONFLICT, refused.0)),
                None => Err(api(StatusCode::CONFLICT, "That job is gone.")),
            },
            inbox::action::CHANGE_JOB => {
                let text = |key: &str| confirmed.payload[key].as_str();
                if let Some(mode) = text("mode") {
                    let mode = crate::permissions::Mode::parse(mode)
                        .ok_or_else(|| api(StatusCode::CONFLICT, "That mode isn't one."))?;
                    self.jobs
                        .set_mode(target, mode)
                        .ok_or_else(|| api(StatusCode::CONFLICT, "That job is gone."))?;
                    self.jobs.note_change(
                        target,
                        format!("Mode changed to {} on your Confirm", mode.title()),
                    );
                }
                if text("agent").is_some() || text("account").is_some() {
                    match self.jobs.change(
                        target,
                        text("agent"),
                        text("account"),
                        "on your Confirm",
                    ) {
                        Some(Ok(_)) => {}
                        Some(Err(refused)) => return Err(api(StatusCode::CONFLICT, refused.0)),
                        None => return Err(api(StatusCode::CONFLICT, "That job is gone.")),
                    }
                }
                Ok(())
            }
            // The ones that answer an inbox item, as the owner would have.
            inbox::action::ACCEPT
            | inbox::action::ACCEPT_REMEMBER
            | inbox::action::DECLINE_REMEMBER
            | inbox::action::ANSWER_QUESTION
            | inbox::action::START
            | inbox::action::ANSWER_ITEM => {
                let answer = match confirmed.action.as_str() {
                    inbox::action::ACCEPT => inbox::ACCEPT.to_owned(),
                    inbox::action::ACCEPT_REMEMBER => inbox::ACCEPT_REMEMBER.to_owned(),
                    inbox::action::DECLINE_REMEMBER => inbox::DECLINE_REMEMBER.to_owned(),
                    inbox::action::START => inbox::START.to_owned(),
                    inbox::action::ANSWER_QUESTION => {
                        confirmed.payload["words"].as_str().unwrap_or("").to_owned()
                    }
                    _ => confirmed.payload["answer"]
                        .as_str()
                        .unwrap_or("")
                        .to_owned(),
                };
                // A confirm item never confirms another.
                if self
                    .lock()
                    .inbox
                    .get(target)
                    .is_none_or(|i| i.kind == "confirm")
                {
                    return Err(api(StatusCode::CONFLICT, "That item is gone."));
                }
                let body = json!({"answer": answer}).to_string();
                Box::pin(self.answer(target, body.as_bytes()))
                    .await
                    .map(|_| ())
            }
            other => Err(api(
                StatusCode::CONFLICT,
                format!("obid doesn't know the action {other:?}."),
            )),
        }
    }

    /// A `start` item for a follow-up whose work merged after it was proposed (the first job's pull
    /// request or a follow-up's) is done by itself, with no options, its text saying so above the
    /// owner's words. Checked whenever the inbox is read; nothing starts.
    fn settle_stale_starts(&self) {
        let open: Vec<Item> = self
            .lock()
            .inbox
            .values()
            .filter(|i| i.kind == "start" && i.done.is_none())
            .cloned()
            .collect();
        if open.is_empty() {
            return;
        }
        let jobs = self.jobs.list(usize::MAX);
        let now = time::now();
        let mut closed = Vec::new();
        for mut item in open {
            let Some(of) = item.start.as_ref().and_then(|s| s["follow_up_of"].as_str()) else {
                continue;
            };
            // The work it would follow up merged after it was proposed: the first job's pull
            // request, or one of its follow-ups'. Anything else (a follow-up that ended, even
            // failed) leaves it open, its words and Start as they were.
            let Some(merged) = jobs
                .iter()
                .filter(|j| j.id == of || j.follow_up_of.as_deref() == Some(of))
                .find(|j| {
                    j.pull_request
                        .as_ref()
                        .and_then(|pr| pr.merged_at)
                        .is_some_and(|at| at > item.created)
                })
            else {
                continue;
            };
            item.text = format!(
                "Closed by Oby: {}'s work merged after this was proposed.\n\n{}",
                merged.short_title(),
                inbox::unfenced(&item.text)
            );
            item.options = vec![];
            item.details = None;
            item.recommended = None;
            item.done = Some(now);
            closed.push(item);
        }
        {
            let mut state = self.lock();
            for item in &closed {
                // Answered meanwhile: the owner's answer stands.
                if state.inbox.get(&item.id).is_some_and(|i| i.done.is_none()) {
                    state.inbox.insert(item.id.clone(), item.clone());
                }
            }
        }
        for item in &closed {
            self.save_item(item);
        }
    }

    /// Work the brain planned after looking things up waits for the owner's Start, as a `start`
    /// item (Engine/Inbox.swift, `Inbox.proposal`): nothing starts until they say so.
    /// `conversation`: the one it was proposed in, which shows it (`Item::conversation`).
    pub fn propose(
        &self,
        new: &crate::jobs::NewJob,
        title: String,
        text: String,
        conversation: &str,
    ) -> Item {
        let mut start = serde_json::to_value(new).unwrap_or_default();
        start["proposedIn"] = json!(conversation);
        let item = Item {
            id: format!("start-{}", &uuid::Uuid::new_v4().simple().to_string()[..8]),
            kind: "start".into(),
            job: String::new(),
            title,
            text,
            options: vec![inbox::START.into(), inbox::CANCEL_START.into()],
            details: Some(vec![
                "Starts it now, as planned.".into(),
                "Drops the plan. Nothing starts; say it another way.".into(),
            ]),
            recommended: Some(0),
            created: time::now(),
            done: None,
            later: None,
            answer: None,
            obi: None,
            plugin: None,
            arrived: Some(inbox::arrival()),
            confirm: None,
            start: Some(Box::new(start)),
            github: None,
            watch: None,
        };
        self.lock().inbox.insert(item.id.clone(), item.clone());
        self.save_item(&item);
        item
    }

    /// `POST /v1/inbox/{id}/answer` on a `start` item: Start queues the job as planned; Cancel,
    /// done or later start nothing.
    fn answer_start(
        &self,
        mut item: Item,
        answer: Option<String>,
        later: Option<i64>,
    ) -> Result<Value, ApiError> {
        if let Some(at) = later {
            item.later = Some(at);
        } else {
            if let Some(answer) = &answer {
                if answer != inbox::START && answer != inbox::CANCEL_START {
                    return Err(api(
                        StatusCode::UNPROCESSABLE_ENTITY,
                        format!("The answer is {} or {}.", inbox::START, inbox::CANCEL_START),
                    ));
                }
                if answer == inbox::START {
                    // `answer` claimed it; what couldn't start leaves it open again.
                    let open_again = |why: ApiError| {
                        self.lock().inbox.insert(item.id.clone(), item.clone());
                        why
                    };
                    let new: crate::jobs::NewJob = item
                        .start
                        .clone()
                        .and_then(|s| serde_json::from_value(*s).ok())
                        .ok_or_else(|| {
                            open_again(api(StatusCode::CONFLICT, "That plan was lost."))
                        })?;
                    // A follow-up of a job whose follow-up is working already: that one hears
                    // it (the owner's own Start), and the item is done, never a second. Only
                    // while it's at work with nothing waiting, checked as the words are taken
                    // (`hear_at_work`): a permission or plan would take them as its answer, so
                    // the item stays open until then.
                    let following = new
                        .follow_up_of
                        .as_deref()
                        .and_then(|of| self.jobs.following(of));
                    let job = match following {
                        Some(next) => match self.jobs.hear_at_work(&next.id, &new.task) {
                            Some(Ok(job)) => job,
                            Some(Err(e)) => {
                                return Err(open_again(api(
                                    StatusCode::CONFLICT,
                                    format!(
                                        "{} (job {}) is following it up already. {} Start it again once it's at work, or tell that job.",
                                        next.short_title(),
                                        next.id,
                                        e.0
                                    ),
                                )));
                            }
                            None => {
                                return Err(open_again(api(
                                    StatusCode::CONFLICT,
                                    "That job is gone.",
                                )));
                            }
                        },
                        None => self
                            .jobs
                            .create(new)
                            .map_err(|e| open_again(api(StatusCode::UNPROCESSABLE_ENTITY, e.0)))?,
                    };
                    item.job = job.id;
                }
            }
            item.done = Some(time::now());
            item.answer = answer;
        }
        self.lock().inbox.insert(item.id.clone(), item.clone());
        self.save_item(&item);
        Ok(item.to_json())
    }

    /// The inbox item `id`, whatever its state.
    pub fn item(&self, id: &str) -> Option<Item> {
        self.lock().inbox.get(id).cloned()
    }

    /// The items waiting for the owner now (not done, and not put off past `now`), what needs them
    /// first and each group in the order they came: what the brain is told about the inbox (#546).
    pub fn waiting_items(&self, now: i64) -> Vec<Item> {
        self.settle_stale_starts();
        let state = self.lock();
        let mut items: Vec<Item> = state
            .inbox
            .values()
            .filter(|i| i.done.is_none() && i.later.is_none_or(|later| later <= now))
            .cloned()
            .collect();
        needs_you_first(&mut items, &self.sorts(&state.inbox));
        items
    }

    /// `POST /v1/inbox/{id}/answer`, from anything but the owner's own tap: a `Confirm` on a
    /// `confirm` item is refused (#776). Agents, oby-mcp, the brain and obid's own callers come
    /// this way.
    pub async fn answer(self: &Arc<Self>, id: &str, body: &[u8]) -> Result<Value, ApiError> {
        let answered = self.answer_as(id, body, None).await;
        answered.map(|shown| self.with_triage(shown))
    }

    /// An answer's item with its `triage`, as every item the API shows (crate::triage).
    fn with_triage(&self, mut shown: Value) -> Value {
        if let Some(item) = shown["id"].as_str().and_then(|id| self.item(id)) {
            shown["triage"] = self.triage_of(&item).into();
        }
        shown
    }

    /// `POST /v1/inbox/{id}/answer` after a registered device signed a Confirm of item `id`
    /// whose title was `approved` (crate::approval, `oby-confirm`): checked by the route before
    /// this, and here again against the item as it's claimed.
    pub async fn answer_confirmed(
        self: &Arc<Self>,
        id: &str,
        body: &[u8],
        approved: &str,
    ) -> Result<Value, ApiError> {
        let answered = self.answer_as(id, body, Some(approved)).await;
        answered.map(|shown| self.with_triage(shown))
    }

    async fn answer_as(
        self: &Arc<Self>,
        id: &str,
        body: &[u8],
        approved: Option<&str>,
    ) -> Result<Value, ApiError> {
        let map = object(body, &["answer", "done", "later"])?;
        let one_of = "The body is exactly one of {\"answer\": …}, {\"done\": true} or {\"later\": \"<date>\"}.";
        if map.len() != 1 {
            return Err(api(StatusCode::UNPROCESSABLE_ENTITY, one_of));
        }
        enum Given {
            Answer(String),
            Done,
            Later(i64),
        }
        let given = match map.iter().next() {
            Some((k, Value::String(a))) if k == "answer" => {
                let length = a.chars().count();
                if a.trim().is_empty() || length > 2000 {
                    return Err(api(
                        StatusCode::UNPROCESSABLE_ENTITY,
                        "An answer is 1 to 2,000 characters.",
                    ));
                }
                Given::Answer(a.clone())
            }
            Some((k, Value::Bool(true))) if k == "done" => Given::Done,
            Some((k, Value::String(t))) if k == "later" => {
                Given::Later(parse_later(t).ok_or_else(|| {
                    api(
                        StatusCode::UNPROCESSABLE_ENTITY,
                        "later is a date, like 2026-10-10T10:12:00Z.",
                    )
                })?)
            }
            _ => return Err(api(StatusCode::UNPROCESSABLE_ENTITY, one_of)),
        };
        // What Oby's brain planned that only the owner may do: carried out on their Confirm.
        // A Confirm claims the item under the lock, so a second one at the same moment finds it
        // done and carries out nothing (review on #552).
        let confirm = {
            let mut state = self.lock();
            let item = state
                .inbox
                .get(id)
                .filter(|i| i.done.is_none() && i.kind == "confirm")
                .cloned();
            let confirming = matches!(&given, Given::Answer(a) if a == inbox::CONFIRM);
            // Only the owner's tap confirms: a device's signature over this item's own title,
            // checked before the item is claimed, so a refused Confirm leaves it open (#776).
            if let Some(open) = &item
                && confirming
                && approved != Some(open.title.as_str())
            {
                return Err(api(StatusCode::FORBIDDEN, NEEDS_YOUR_TAP));
            }
            if item.is_some()
                && confirming
                && let Some(kept) = state.inbox.get_mut(id)
            {
                kept.done = Some(time::now());
            }
            item
        };
        if let Some(item) = confirm {
            return match given {
                Given::Answer(answer) => self.answer_confirm(item, Some(answer), None).await,
                Given::Done => self.answer_confirm(item, None, None).await,
                Given::Later(at) => self.answer_confirm(item, None, Some(at)).await,
            };
        }
        // A question's item, answered or declined: the words pass the publish gate first, with
        // no lock held.
        let question = self
            .lock()
            .inbox
            .get(id)
            .filter(|i| i.done.is_none() && i.obi.as_ref().is_some_and(|o| o["type"] == "question"))
            .cloned();
        if let Some(item) = question {
            match given {
                Given::Answer(words) => return self.answer_question(item, Some(words)).await,
                Given::Done => return self.answer_question(item, None).await,
                Given::Later(_) => {}
            }
        }
        // A listener's review (crate::listen): Approve posts it on GitHub, with no lock held. The
        // answer claims it first, and the claim (`watch.posting`) is on disk before gh is asked, so
        // a second Approve, or one after obid stopped mid-post, never posts it twice; when nothing
        // was posted it's open again.
        let approving = {
            let mut state = self.lock();
            let item = state
                .inbox
                .get(id)
                .filter(|i| {
                    i.done.is_none()
                        && i.kind == "listen"
                        && i.options.iter().any(|o| o == crate::listen::APPROVE)
                })
                .cloned();
            match (item, &given) {
                (Some(item), Given::Answer(a)) if a == crate::listen::APPROVE => {
                    if item
                        .watch
                        .as_deref()
                        .is_some_and(|w| !w["posting"].is_null())
                    {
                        return Err(api(
                            StatusCode::CONFLICT,
                            "Oby was posting this review when it stopped, or still is: check the pull request on GitHub, then Dismiss it.",
                        ));
                    }
                    let mut claimed = item.clone();
                    if let Some(watch) = claimed.watch.as_mut() {
                        watch["posting"] = serde_json::json!(time::format(time::now()));
                    }
                    state.inbox.insert(claimed.id.clone(), claimed.clone());
                    Some((item, claimed))
                }
                _ => None,
            }
        };
        if let Some((open, claimed)) = approving {
            // Not on disk: nothing is posted (a stop could then post it twice).
            if let Err(why) = self.keep_item(&claimed) {
                self.lock().inbox.insert(open.id.clone(), open.clone());
                self.save_item(&open);
                return Err(api(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("Nothing was posted: obid couldn't keep the claim ({why})."),
                ));
            }
            return match crate::listen::post_review_with_gh(&self.config.home, &claimed).await {
                Ok(()) => {
                    let mut item = claimed;
                    item.done = Some(time::now());
                    item.answer = Some(crate::listen::APPROVE.into());
                    self.lock().inbox.insert(item.id.clone(), item.clone());
                    self.save_item(&item);
                    self.tell_author(&item);
                    Ok(item.to_json())
                }
                Err(why) => {
                    // Open again, unless the owner dismissed it meanwhile.
                    let dismissed = {
                        let mut state = self.lock();
                        let dismissed = state.inbox.get(&open.id).is_some_and(|i| i.done.is_some());
                        if !dismissed {
                            state.inbox.insert(open.id.clone(), open.clone());
                        }
                        dismissed
                    };
                    if !dismissed {
                        self.save_item(&open);
                    }
                    Err(api(
                        StatusCode::BAD_GATEWAY,
                        format!("Nothing was posted: {why}."),
                    ))
                }
            };
        }
        // A review's author on Slack (crate::listen::tell_author): Send, or Send and Remember,
        // claims the item under the lock (done), then sends as the owner with no lock held; a send
        // that fails leaves it open again.
        let telling = {
            let mut state = self.lock();
            let sending = matches!(&given, Given::Answer(a)
                if a == crate::listen::SEND || a == crate::listen::SEND_AND_REMEMBER);
            let item = state
                .inbox
                .get(id)
                .filter(|i| {
                    sending
                        && i.done.is_none()
                        && i.kind == "listen"
                        && i.options.iter().any(|o| o == crate::listen::SEND)
                })
                .cloned();
            if item.is_some()
                && let Some(kept) = state.inbox.get_mut(id)
            {
                kept.done = Some(time::now());
            }
            item
        };
        if let (Some(open), Given::Answer(answer)) = (telling, &given) {
            return self.send_to_author(open, answer).await;
        }
        // An offer of GitHub work: its start reads GitHub first, with no lock held, so its start
        // answer claims the item under the lock (done), as Start does: nothing settles it
        // meanwhile, and a second answer finds it done.
        let github = {
            let mut state = self.lock();
            let item = state
                .inbox
                .get(id)
                .filter(|i| i.done.is_none() && i.kind == "github")
                .cloned();
            if let Some(item) = &item
                && matches!(&given, Given::Answer(a) if item.options.first() == Some(a))
                && let Some(kept) = state.inbox.get_mut(id)
            {
                kept.done = Some(time::now());
            }
            item
        };
        // A plug-in's offer (#1124): its start answer claims the item under the lock, as a GitHub
        // offer's does, so a second answer finds it done and starts nothing.
        let offer = {
            let mut state = self.lock();
            let item = state
                .inbox
                .get(id)
                .filter(|i| {
                    i.done.is_none()
                        && i.kind == "pluginEvent"
                        && i.options.len() > 1
                        && matches!(&given, Given::Answer(a) if i.options.first() == Some(a)
                            || (a.starts_with(crate::rules::FROM_NOW_ON) && i.options.contains(a)))
                })
                .cloned();
            if item.is_some()
                && let Some(kept) = state.inbox.get_mut(id)
            {
                kept.done = Some(time::now());
            }
            item
        };
        if let (Some(item), Given::Answer(answer)) = (offer, &given) {
            return self.answer_plugin_offer(item, answer.clone()).await;
        }
        let share_used = self
            .lock()
            .inbox
            .get(id)
            .filter(|i| {
                i.done.is_none() && i.obi.as_ref().is_some_and(|o| o["type"] == "share_used")
            })
            .cloned();
        if let Some(item) = share_used {
            match given {
                Given::Answer(answer) => return self.answer_share_used(item, Some(answer)),
                Given::Done => return self.answer_share_used(item, None),
                Given::Later(_) => {}
            }
        }
        if let Some(item) = github {
            return match given {
                Given::Answer(answer) => self.answer_github(item, Some(answer), None).await,
                Given::Done => self.answer_github(item, None, None).await,
                Given::Later(at) => self.answer_github(item, None, Some(at)).await,
            };
        }
        let now = time::now();
        let (item, exchange, decisions) = {
            let mut state = self.lock();
            let item = state
                .inbox
                .get(id)
                .cloned()
                .ok_or_else(|| api(StatusCode::NOT_FOUND, "There's no such inbox item."))?;
            if item.done.is_some() {
                return Err(api(StatusCode::CONFLICT, "That item is done already."));
            }
            if matches!(item.kind.as_str(), "permission" | "plan") {
                drop(state);
                return match given {
                    Given::Answer(answer) => self.answer_permission_item(item, Some(answer), None),
                    Given::Done => self.answer_permission_item(item, None, None),
                    Given::Later(at) => self.answer_permission_item(item, None, Some(at)),
                };
            }
            if item.kind == "start" {
                // Start claims the item under the lock: a second Start at the same moment finds
                // it done and starts nothing (review on #552).
                if matches!(&given, Given::Answer(a) if a == inbox::START)
                    && let Some(kept) = state.inbox.get_mut(id)
                {
                    kept.done = Some(now);
                }
                drop(state);
                return match given {
                    Given::Answer(answer) => self.answer_start(item, Some(answer), None),
                    Given::Done => self.answer_start(item, None, None),
                    Given::Later(at) => self.answer_start(item, None, Some(at)),
                };
            }
            // Oby's own question about a job event (the event orchestrator's escalation): the
            // owner's answer, or Done, settles it, and nothing else is carried out (#710). It isn't
            // another Obi's request, whose exchange it would look for.
            if item.obi.is_none() && item.id.starts_with("orchestrator-") {
                let mut item = item;
                match &given {
                    Given::Later(at) => item.later = Some(*at),
                    Given::Answer(answer) => {
                        item.answer = Some(answer.clone());
                        item.done = Some(now);
                    }
                    Given::Done => item.done = Some(now),
                }
                state.inbox.insert(item.id.clone(), item.clone());
                drop(state);
                self.save_item(&item);
                return Ok(item.to_json());
            }
            // A plug-in's event and the watcher's notice only say something: Dismiss settles them.
            if matches!(item.kind.as_str(), "pluginEvent" | "watch" | "listen") {
                drop(state);
                return match given {
                    Given::Answer(answer) => self.answer_plugin_event(item, Some(answer), None),
                    Given::Done => self.answer_plugin_event(item, None, None),
                    Given::Later(at) => self.answer_plugin_event(item, None, Some(at)),
                };
            }
            if let Given::Later(at) = &given {
                let mut item = item;
                item.later = Some(*at);
                state.inbox.insert(item.id.clone(), item.clone());
                drop(state);
                self.save_item(&item);
                return Ok(item.to_json());
            }
            let run_request = item
                .obi
                .as_ref()
                .is_some_and(|o| o["type"] == "run_request");
            let answer = match &given {
                Given::Answer(a) => {
                    if !run_request && !inbox::OBI_OPTIONS.contains(&a.as_str()) {
                        return Err(api(
                            StatusCode::UNPROCESSABLE_ENTITY,
                            format!("The answer is one of: {}.", inbox::OBI_OPTIONS.join("; ")),
                        ));
                    }
                    Some(a.clone())
                }
                _ => None,
            };
            let cid = item
                .obi
                .as_ref()
                .and_then(|o| o["correlationId"].as_str())
                .unwrap_or("")
                .to_owned();
            let mut exchange = state
                .exchanges
                .get(&cid)
                .cloned()
                .filter(|e| e.state == "inbox")
                .ok_or_else(|| api(StatusCode::CONFLICT, "That request was settled already."))?;
            // After its expires_at nobody acts on a request (protocol.md section 3): it's settled
            // here, as the clock would at its next pass, and the answer is refused.
            if exchange.expires_at().is_some_and(|t| t <= now) {
                drop(state);
                self.expire();
                return Err(api(
                    StatusCode::CONFLICT,
                    "That request expired before the answer.",
                ));
            }
            if exchange.kind == "run_request" {
                drop(state);
                return self.answer_run_request(item, answer);
            }
            // Only a review request is accepted here: a question is answered in words (above).
            if exchange.kind != "review_request" {
                return Err(api(
                    StatusCode::CONFLICT,
                    "That request isn't a review request.",
                ));
            }
            let chosen = answer.as_deref().unwrap_or(inbox::DECLINE);
            let accept = chosen == inbox::ACCEPT || chosen == inbox::ACCEPT_REMEMBER;
            let remember = chosen == inbox::ACCEPT_REMEMBER || chosen == inbox::DECLINE_REMEMBER;
            exchange.decided_by = Some("inbox".into());
            if accept {
                self.accept_locked(&state, &mut exchange, None);
            } else {
                exchange.state = "declined".into();
                let decline = self.reply_locked(
                    &state,
                    &exchange,
                    "decline",
                    json!({"reason": "owner_declined"}),
                );
                exchange.outbox.extend(decline);
            }
            exchange.updated = now;
            let mut decisions = None;
            if remember {
                let decision = Decision {
                    id: decisions::new_id(),
                    kind: exchange.kind.clone(),
                    from_owner: exchange.peer_owner.clone().unwrap_or_default(),
                    repo: exchange.request["body"]["repo"]
                        .as_str()
                        .unwrap_or("*")
                        .to_owned(),
                    decision: if accept { "accept" } else { "decline" }.into(),
                    created: now,
                    inbox_item: item.id.clone(),
                    uses: 0,
                    last_used: None,
                    ..Decision::default()
                };
                state.decisions.retain(|d| {
                    !(d.kind == decision.kind
                        && d.from_owner == decision.from_owner
                        && d.repo == decision.repo)
                });
                state.decisions.push(decision);
                decisions = Some(state.decisions.clone());
            }
            let mut item = item;
            item.done = Some(now);
            item.answer = answer;
            state.inbox.insert(item.id.clone(), item.clone());
            state.exchanges.insert(cid, exchange.clone());
            (item, exchange, decisions)
        };
        if let Some(decisions) = decisions {
            self.save_decisions(&decisions);
        }
        self.save_item(&item);
        self.save_exchange(&exchange);
        self.outbox.notify_one();
        Ok(item.to_json())
    }
}

impl Link {
    /// `POST /v1/inbox/{id}/answer` on a question's item: `Decline` (or `{"done": true}`) and
    /// `Decline, and remember for this repo` decline it, the second keeping a decline for each
    /// repository it is about (`*` for one about none); any other words are the owner's answer,
    /// `by: owner`, with `choice` when they are exactly one of the question's choices. The words
    /// pass the publish gate first: a possible secret, or a scanner that can't run, is `422`,
    /// nothing is sent, and the item stays open.
    async fn answer_question(&self, item: Item, words: Option<String>) -> Result<Value, ApiError> {
        let invalid = |m: String| api(StatusCode::UNPROCESSABLE_ENTITY, m);
        let cid = item
            .obi
            .as_ref()
            .and_then(|o| o["correlationId"].as_str())
            .unwrap_or("")
            .to_owned();
        let declining = words
            .as_deref()
            .is_none_or(|w| inbox::QUESTION_OPTIONS.contains(&w));
        let mut body = Value::Null;
        if let Some(text) = words.as_deref().filter(|_| !declining) {
            let asked = self
                .lock()
                .exchanges
                .get(&cid)
                .map(|e| e.request["body"].clone())
                .unwrap_or(Value::Null);
            body = json!({"by": "owner", "text": text});
            if let Some(choice) = asked["choices"]
                .as_array()
                .and_then(|choices| choices.iter().position(|c| c == text))
            {
                body["choice"] = json!(choice);
            }
            // Scanned first; the schema's own messages would quote the words.
            let scratch = self.config.home.join("tmp");
            let _ = std::fs::create_dir_all(&scratch);
            let verdict = scan::scan(&every_text(&body), &scratch).await;
            match verdict {
                scan::Verdict::Clean => {}
                scan::Verdict::Found(_) => {
                    return Err(invalid(
                        "The secret scan found a possible secret in the answer: nothing was sent."
                            .into(),
                    ));
                }
                scan::Verdict::CouldNotRun(why) => {
                    return Err(invalid(format!(
                        "The secret scan couldn't run ({why}): nothing was sent."
                    )));
                }
            }
            if !obi_protocol::schema::is_valid("actions/answer", &body) {
                return Err(invalid(
                    "An answer is one line or more of text with no control or bidirectional characters but tab and line breaks: nothing was sent."
                        .into(),
                ));
            }
        }
        let now = time::now();
        let (item, exchange, decisions) = {
            let mut state = self.lock();
            if state.inbox.get(&item.id).is_none_or(|i| i.done.is_some()) {
                return Err(api(StatusCode::CONFLICT, "That item is done already."));
            }
            let mut exchange = state
                .exchanges
                .get(&cid)
                .cloned()
                .filter(|e| e.state == "inbox")
                .ok_or_else(|| api(StatusCode::CONFLICT, "That question was settled already."))?;
            if exchange.expires_at().is_some_and(|t| t <= now) {
                drop(state);
                self.expire();
                return Err(api(
                    StatusCode::CONFLICT,
                    "That question expired before the answer.",
                ));
            }
            exchange.decided_by = Some("inbox".into());
            let mut decisions = None;
            if declining {
                exchange.state = "declined".into();
                let decline = self.reply_locked(
                    &state,
                    &exchange,
                    "decline",
                    json!({"reason": "owner_declined"}),
                );
                exchange.outbox.extend(decline);
                if words.as_deref() == Some(inbox::DECLINE_REMEMBER) {
                    let owner = exchange.peer_owner.clone().unwrap_or_default();
                    let mut repos: Vec<String> = item
                        .obi
                        .as_ref()
                        .and_then(|o| o["repos"].as_array())
                        .into_iter()
                        .flatten()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect();
                    if repos.is_empty() {
                        repos.push("*".into());
                    }
                    for repo in repos {
                        state.decisions.retain(|d| {
                            !(d.kind == "question"
                                && d.from_owner == owner
                                && d.repo.eq_ignore_ascii_case(&repo))
                        });
                        state.decisions.push(Decision {
                            id: decisions::new_id(),
                            kind: "question".into(),
                            from_owner: owner.clone(),
                            repo,
                            decision: "decline".into(),
                            created: now,
                            inbox_item: item.id.clone(),
                            uses: 0,
                            last_used: None,
                            ..Decision::default()
                        });
                    }
                    decisions = Some(state.decisions.clone());
                }
            } else {
                let Some(answer) = self.reply_locked(&state, &exchange, "answer", body.clone())
                else {
                    return Err(api(
                        StatusCode::CONFLICT,
                        "obid has no key or membership to sign the answer with.",
                    ));
                };
                exchange.outbox.push(answer);
                exchange.result = Some(body);
                exchange.state = "done".into();
            }
            exchange.updated = now;
            let mut item = item;
            item.done = Some(now);
            item.answer = words;
            state.inbox.insert(item.id.clone(), item.clone());
            state.exchanges.insert(cid, exchange.clone());
            (item, exchange, decisions)
        };
        if let Some(decisions) = decisions {
            self.save_decisions(&decisions);
        }
        self.save_item(&item);
        self.save_exchange(&exchange);
        self.outbox.notify_one();
        Ok(item.to_json())
    }

    // -----------------------------------------------------------------------------------------
    // Sharing rules and limits: GET /v1/obid/sharing, POST …/rules, DELETE …/rules/{id},
    // PUT …/limits

    /// `GET /v1/obid/sharing`.
    pub fn sharing_json(&self) -> Value {
        self.lock().sharing.to_json()
    }

    /// `POST /v1/obid/sharing/rules`: a new rule, kept after the others.
    pub fn add_rule(&self, body: &[u8]) -> Result<Value, ApiError> {
        let value: Value = serde_json::from_slice(body)
            .map_err(|e| api(StatusCode::BAD_REQUEST, format!("The body isn't JSON: {e}")))?;
        let rule = sharing::rule_from(&value, time::now())
            .map_err(|why| api(StatusCode::UNPROCESSABLE_ENTITY, why))?;
        {
            let mut state = self.lock();
            if state.sharing.rules.len() >= sharing::MAX_RULES {
                return Err(api(
                    StatusCode::CONFLICT,
                    format!("obid keeps at most {} sharing rules.", sharing::MAX_RULES),
                ));
            }
            state.sharing.rules.push(rule.clone());
            // Kept under the lock, so an older copy never overwrites a newer one.
            self.save_sharing(&state.sharing);
        }
        Ok(rule.to_json())
    }

    /// `DELETE /v1/obid/sharing/rules/{id}`: `false` for one obid doesn't have.
    pub fn forget_rule(&self, id: &str) -> bool {
        let mut state = self.lock();
        let before = state.sharing.rules.len();
        state.sharing.rules.retain(|r| r.id != id);
        if state.sharing.rules.len() == before {
            return false;
        }
        self.save_sharing(&state.sharing);
        true
    }

    /// `PUT /v1/obid/sharing/limits`.
    pub fn set_limits(&self, body: &[u8]) -> Result<Value, ApiError> {
        let value: Value = serde_json::from_slice(body)
            .map_err(|e| api(StatusCode::BAD_REQUEST, format!("The body isn't JSON: {e}")))?;
        let limits = sharing::limits_from(&value)
            .map_err(|why| api(StatusCode::UNPROCESSABLE_ENTITY, why))?;
        let mut state = self.lock();
        state.sharing.limits = limits;
        self.save_sharing(&state.sharing);
        Ok(limits.to_json())
    }
}

impl channel::Party for Link {
    fn token(
        &self,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<String, String>> + Send + '_>>
    {
        Box::pin(async move { Link::token(self).await.map_err(|e| e.to_string()) })
    }

    fn peer_key(&self, obi: &str) -> Option<(String, String)> {
        let state = self.lock();
        state
            .directory
            .keys
            .iter()
            .find(|(_, k)| k.obi == obi && k.valid_until_seq.is_none())
            .map(|(id, k)| (id.clone(), k.public_key.clone()))
    }
}

/// Running on another Obi's Mac, and sharing this one (#797; docs/runner-api.md, "obid only:
/// sharing this Mac").
impl Link {
    pub(super) fn home(&self) -> &std::path::Path {
        &self.config.home
    }

    pub(super) fn owner(&self) -> &str {
        &self.config.owner
    }

    pub(super) fn model_api_base(&self) -> Option<String> {
        self.config.guest_model_api.clone()
    }

    /// Whether obid is stopping, for tasks that end with it.
    pub(super) fn stopping(&self) -> watch::Receiver<bool> {
        self.stopping.clone()
    }

    pub(super) fn hosting_setup(&self) -> super::hosting::Setup {
        self.setup.clone()
    }

    pub(super) fn exchange(&self, cid: &str) -> Option<Exchange> {
        self.lock().exchanges.get(cid).cloned()
    }

    pub(super) fn mac(&self) -> sharing::Mac {
        self.lock().sharing.mac.clone()
    }

    /// Where one guest job's files are: short, since its sockets' paths must be.
    pub(super) fn guest_dir(&self, cid: &str) -> std::path::PathBuf {
        self.config.home.join("g").join(&cid[..cid.len().min(8)])
    }

    pub(super) fn channel_params(
        &self,
        cid: &str,
        peer: &str,
        role: channel::Role,
    ) -> Option<channel::Params> {
        let state = self.lock();
        let membership = state.membership.as_ref()?;
        Some(channel::Params {
            base: membership.url.clone(),
            sphere: membership.sphere.clone(),
            exchange: cid.to_owned(),
            me: membership.obi_id.clone(),
            peer: peer.to_owned(),
            role,
            key: state.key.clone()?,
        })
    }

    /// A reply in an exchange of this Obi's, built, kept and queued to send; `state` is the
    /// exchange's state from now (unchanged when empty).
    pub(super) fn host_reply(&self, cid: &str, kind: &str, body: Value, state_now: &str) {
        let exchange = {
            let mut state = self.lock();
            let Some(mut exchange) = state.exchanges.get(cid).cloned() else {
                return;
            };
            if exchange.ended() {
                return;
            }
            let Some(reply) = self.reply_locked(&state, &exchange, kind, body.clone()) else {
                return;
            };
            exchange.outbox.push(reply);
            if !state_now.is_empty() {
                exchange.state = state_now.into();
            }
            if matches!(kind, "result" | "run_return" | "share_status") {
                exchange.result = Some(body);
            }
            exchange.updated = time::now();
            state.exchanges.insert(cid.to_owned(), exchange.clone());
            exchange
        };
        self.save_exchange(&exchange);
        self.outbox.notify_one();
    }

    /// Whether `obi` is an active member in the directory obid trusts.
    pub(super) fn member_active(&self, obi: &str) -> bool {
        self.lock()
            .directory
            .members
            .get(obi)
            .is_some_and(|m| m.active)
    }

    /// The owner's inbox gets the first-time ask, unless the sender's owner has too many there.
    pub(super) fn host_ask(&self, cid: &str) {
        let (item, exchange) = {
            let mut state = self.lock();
            let Some(mut exchange) = state.exchanges.get(cid).cloned() else {
                return;
            };
            let owner = exchange.peer_owner.clone().unwrap_or_default();
            if self.inbox_full(&state, &owner) {
                drop(state);
                self.host_reply(cid, "decline", json!({"reason": "busy"}), "declined");
                return;
            }
            let item = super::hosting::ask_item(
                cid,
                &exchange.peer,
                &owner,
                &exchange.request["body"],
                exchange.request["expires_at"].as_str().unwrap_or(""),
                time::now(),
            );
            exchange.state = "inbox".into();
            exchange.inbox_item = Some(item.id.clone());
            state.inbox.insert(item.id.clone(), item.clone());
            state.exchanges.insert(cid.to_owned(), exchange.clone());
            (item, exchange)
        };
        self.save_item(&item);
        self.save_exchange(&exchange);
    }

    /// The owner's answer to a teammate's ask: Allow (this time, or from now on) or Decline.
    fn answer_run_request(
        self: &Arc<Self>,
        item: Item,
        answer: Option<String>,
    ) -> Result<Value, ApiError> {
        let cid = item
            .obi
            .as_ref()
            .and_then(|o| o["correlationId"].as_str())
            .unwrap_or("")
            .to_owned();
        let from_owner = item
            .obi
            .as_ref()
            .and_then(|o| o["fromOwner"].as_str())
            .unwrap_or("")
            .to_owned();
        let from_now_on = format!("Allow {} from now on", super::hosting::person(&from_owner));
        let chosen = answer.unwrap_or_else(|| super::hosting::DECLINE.into());
        if chosen != super::hosting::ALLOW
            && chosen != from_now_on
            && chosen != super::hosting::DECLINE
        {
            return Err(api(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!(
                    "The answer is one of: {}; {from_now_on}; {}.",
                    super::hosting::ALLOW,
                    super::hosting::DECLINE
                ),
            ));
        }
        let (item, sharing) = {
            let mut state = self.lock();
            if !state
                .exchanges
                .get(&cid)
                .is_some_and(|e| e.state == "inbox")
            {
                return Err(api(
                    StatusCode::CONFLICT,
                    "That request was settled already.",
                ));
            }
            let mut item = item;
            item.done = Some(time::now());
            item.answer = Some(chosen.clone());
            state.inbox.insert(item.id.clone(), item.clone());
            let mut sharing = None;
            if chosen == from_now_on && !state.sharing.mac.allowed.contains(&from_owner) {
                state.sharing.mac.allowed.push(from_owner.clone());
                sharing = Some(state.sharing.clone());
            }
            if let Some(e) = state.exchanges.get_mut(&cid) {
                e.decided_by = Some("inbox".into());
                e.state = "admitting".into();
            }
            (item, sharing)
        };
        if let Some(sharing) = sharing {
            self.save_sharing(&sharing);
        }
        self.save_item(&item);
        if chosen == super::hosting::DECLINE {
            self.host_reply(
                &cid,
                "decline",
                json!({"reason": "owner_declined"}),
                "declined",
            );
        } else {
            super::hosting::admit(self, cid, true);
        }
        Ok(item.to_json())
    }

    /// The request's sender calls it off: a `run_cancel` in an outgoing run_request's exchange.
    pub(super) fn send_cancel(&self, cid: &str) {
        self.host_reply(cid, "run_cancel", json!({}), "cancelled");
    }

    /// Sends a request this obid makes itself (a job's run on another Mac): the same checks and
    /// secret scan as `POST /v1/obid/sphere/requests`.
    pub(super) async fn send_request(
        &self,
        to: &str,
        kind: &str,
        body: Value,
        expires_in: i64,
    ) -> Result<Exchange, ApiError> {
        let request = json!({"to": to, "type": kind, "body": body, "expiresIn": expires_in});
        let answer = self.request(request.to_string().as_bytes()).await?;
        let cid = answer["correlationId"].as_str().unwrap_or("").to_owned();
        self.exchange(&cid).ok_or_else(|| {
            api(
                StatusCode::INTERNAL_SERVER_ERROR,
                "The request wasn't kept.",
            )
        })
    }

    /// Publishes the runner status soon, off this task.
    pub(super) fn publish_runner_soon(self: &Arc<Self>) {
        let link = self.clone();
        tokio::spawn(async move { super::hosting::publish_status(&link).await });
    }

    /// Signs and publishes the runner status (protocol.md section 14).
    pub(super) async fn put_runner(
        &self,
        fields: &Value,
        now: i64,
        expires: i64,
    ) -> Result<(), String> {
        let (key, membership) = {
            let state = self.lock();
            (
                state.key.clone().ok_or("no key")?,
                state.membership.clone().ok_or("not joined")?,
            )
        };
        let mut status = fields.clone();
        status["protocol"] = json!(obi_protocol::PROTOCOL);
        status["sphere"] = json!(membership.sphere);
        status["obi"] = json!(membership.obi_id);
        status["created_at"] = json!(time::format(now));
        status["expires_at"] = json!(time::format(expires));
        status["key_id"] = json!(key.key_id());
        let canonical = obi_protocol::jcs::canonical_bytes(&status).map_err(|e| e.to_string())?;
        status["signature"] = json!(key.sign(&[RUNNER_PREFIX, &canonical].concat()));
        let token = self.token().await.map_err(|e| e.to_string())?;
        self.client()
            .map_err(|e| e.to_string())?
            .put_runner(&token, &membership.obi_id, &status)
            .await
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub(super) async fn delete_runner(&self) -> Result<(), String> {
        let membership = self.lock().membership.clone().ok_or("not joined")?;
        let token = self.token().await.map_err(|e| e.to_string())?;
        self.client()
            .map_err(|e| e.to_string())?
            .delete_runner(&token, &membership.obi_id)
            .await
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Publishes the runner status every 30 seconds while obid is in a Sphere.
    fn keep_runner_status(self: &Arc<Self>) {
        let link = self.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(30));
            loop {
                tokio::select! {
                    _ = tick.tick() => {
                        if link.lock().membership.as_ref().is_some_and(|m| m.state == "joined") {
                            super::hosting::publish_status(&link).await;
                            link.sync_shares(false).await;
                        }
                    }
                    () = stopped(link.stopping.clone()) => return,
                }
            }
        });
    }

    /// Whether `obi`'s runner status says it's free now (None: it publishes none to this owner),
    /// reading the directory again first.
    pub(super) async fn runner_free(&self, obi: &str) -> Option<bool> {
        if let Err(e) = self.read_directory().await {
            self.note_error(&e);
        }
        let state = self.lock();
        let runner = state.directory.members.get(obi)?.runner.clone()?;
        let live = runner["expires_at"]
            .as_str()
            .and_then(time::parse)
            .is_some_and(|t| t > time::now());
        Some(live && runner["free"] == true)
    }

    /// The owner of `obi`, when it is an active teammate whose card takes run_request.
    pub fn run_host(&self, obi: &str) -> Option<String> {
        let state = self.lock();
        let me = state.membership.as_ref().map(|m| m.obi_id.as_str());
        state
            .directory
            .members
            .get(obi)
            .filter(|m| m.active && m.accepts.iter().any(|a| a == "run_request") && Some(obi) != me)
            .map(|m| m.owner.clone())
    }

    /// Of `people`, who has joined this Sphere (an Obi of theirs is in the directory, active or
    /// revoked: their owner id is bound) and who is still waiting to join. The runner status names
    /// only the first: the Sphere refuses one that names anyone else (sphere-api.md section 6.4).
    pub fn joined(&self, people: &[String]) -> (Vec<String>, Vec<String>) {
        let state = self.lock();
        people
            .iter()
            .cloned()
            .partition(|p| state.directory.members.values().any(|m| m.owner == *p))
    }

    /// [`Link::joined`], reading the directory again first (at most every 15 seconds) while someone
    /// chosen isn't in it: they may have joined since.
    pub(super) async fn joined_now(&self, people: &[String]) -> (Vec<String>, Vec<String>) {
        if !self.joined(people).1.is_empty()
            && time::now() - self.lock().directory_read > 15
            && self.lock().membership.is_some()
            && let Err(e) = self.read_directory().await
        {
            self.note_error(&e);
        }
        self.joined(people)
    }

    /// `GET /v1/obid/sharing/mac`: this Mac's sharing, whether it can run guests, what runs here
    /// now, and the people chosen who haven't joined yet (`waiting`).
    pub fn mac_json(&self) -> Value {
        let mac = self.mac();
        let waiting = if mac.who == "people" {
            self.joined(&mac.people).1
        } else {
            Vec::new()
        };
        json!({"settings": mac.to_json(), "ready": self.setup.ready(), "image": super::hosting::image_json(self), "jobs": self.hosting.jobs_json(),
               "week": super::hosting::week(self.home(), time::now()), "waiting": waiting})
    }

    /// `GET /v1/obid/sphere/audit`: the Sphere's audit chain, checked here end to end against the
    /// directory's keys, and the entries this Obi sent or got, as metadata only (#810): who, which
    /// Obi, the repository, the kind, the times, the host's use and the cost; no message's text.
    pub async fn audit_json(&self) -> Result<Value, ApiError> {
        let membership = self
            .lock()
            .membership
            .clone()
            .filter(|m| m.state == "joined")
            .ok_or_else(|| api(StatusCode::CONFLICT, "obid hasn't joined a Sphere."))?;
        self.read_directory().await.map_err(|e| from_client(&e))?;
        let token = self.token().await.map_err(|e| from_client(&e))?;
        let client = self.client().map_err(|e| from_client(&e))?;
        // ponytail: the whole chain each time, at most MAX_AUDIT entries; from a checked head
        // once chains grow long.
        const MAX_AUDIT: usize = 100_000;
        let mut entries: Vec<Value> = Vec::new();
        let mut head = json!({"seq": 0, "hash": obi_protocol::ZERO_HASH});
        loop {
            let page = client
                .audit(&token, entries.len() as u64 + 1, 1000)
                .await
                .map_err(|e| from_client(&e))?;
            head = page["head"].clone();
            let got = page["entries"].as_array().cloned().unwrap_or_default();
            let done = got.is_empty()
                || entries.len() + got.len() >= head["seq"].as_u64().unwrap_or(0) as usize;
            entries.extend(got);
            if entries.len() > MAX_AUDIT {
                return Err(api(
                    StatusCode::BAD_GATEWAY,
                    "The Sphere's chain is longer than obid checks here (100,000 entries).",
                ));
            }
            if done {
                break;
            }
        }
        let chain = json!({"sphere": membership.sphere, "entries": entries});
        let checked =
            obi_protocol::chain::verify(&chain, &self.lock().directory.keys).and_then(|()| {
                // The head the Sphere names is the chain's last entry.
                let last = entries
                    .last()
                    .map_or((0, obi_protocol::ZERO_HASH.to_owned()), |e| {
                        (
                            e["seq"].as_u64().unwrap_or(0),
                            e["hash"].as_str().unwrap_or("").to_owned(),
                        )
                    });
                if head["seq"].as_u64() == Some(last.0) && head["hash"].as_str() == Some(&last.1) {
                    Ok(())
                } else {
                    Err(obi_protocol::Rejection::new(
                        "head_mismatch",
                        "the Sphere's head isn't the chain's last entry",
                    ))
                }
            });
        // The chain checks out by itself; it must also be the one this Obi saw before.
        let problem = match &checked {
            Err(rejection) => Some(rejection.code.to_owned()),
            Ok(()) => {
                let mut kept = self.chain.lock().unwrap();
                let found = kept.problem(&entries);
                if found.is_none() {
                    kept.head = Some((
                        head["seq"].as_u64().unwrap_or(0),
                        head["hash"].as_str().unwrap_or("").to_owned(),
                    ));
                    kept.save(&self.config.home);
                }
                found.map(str::to_owned)
            }
        };
        let me = membership.obi_id.as_str();
        let mine: Vec<Value> = entries
            .iter()
            .filter(|e| e["envelope"]["from"] == me || e["envelope"]["to"] == me)
            .map(audit_entry)
            .collect();
        Ok(
            json!({"verified": problem.is_none(), "problem": problem, "head": head, "entries": mine}),
        )
    }

    /// `PUT /v1/obid/sharing/mac`. Turning it off stops every guest job here.
    pub fn set_mac(self: &Arc<Self>, body: &[u8]) -> Result<Value, ApiError> {
        let value: Value = serde_json::from_slice(body)
            .map_err(|_| api(StatusCode::BAD_REQUEST, "The body isn't JSON."))?;
        let mac =
            sharing::mac_from(&value).map_err(|m| api(StatusCode::UNPROCESSABLE_ENTITY, m))?;
        let sharing = {
            let mut state = self.lock();
            state.sharing.mac = mac.clone();
            state.sharing.clone()
        };
        self.save_sharing(&sharing);
        if mac.on {
            super::hosting::fetch_image_soon(self);
        } else {
            self.hosting.stop(None, "sharing_off");
            super::hosting::cancel_image_fetch(self);
        }
        self.publish_runner_soon();
        Ok(self.mac_json())
    }

    /// `POST /v1/obid/sharing/mac/jobs/{cid}/stop`, and Stop All without one.
    pub fn stop_guests(&self, cid: Option<&str>) -> usize {
        self.hosting.stop(cid, "stopped")
    }

    /// The teammates' Macs this owner may send a job to, as their runner statuses say: free or
    /// busy, never whether their owner is at them (`GET /v1/obid/sharing/macs`).
    pub async fn macs_json(&self) -> Value {
        // Fresh when the picker opens: a status published since the last read shows.
        if time::now() - self.lock().directory_read > 15
            && self.lock().membership.is_some()
            && let Err(e) = self.read_directory().await
        {
            self.note_error(&e);
        }
        let state = self.lock();
        let now = time::now();
        let me = state
            .membership
            .as_ref()
            .map(|m| m.obi_id.clone())
            .unwrap_or_default();
        let mut list: Vec<Value> = state
            .directory
            .members
            .iter()
            .filter(|(obi, m)| {
                **obi != me && m.active && m.accepts.iter().any(|a| a == "run_request")
            })
            .filter_map(|(obi, m)| {
                let runner = m.runner.as_ref()?;
                let live = runner["expires_at"]
                    .as_str()
                    .and_then(time::parse)
                    .is_some_and(|t| t > now);
                Some(
                    json!({"obi": obi, "owner": m.owner, "free": live && runner["free"] == true,
                            "size": runner["size"], "agents": runner["agents"],
                            "verified": self.pins.verified(&m.owner)}),
                )
            })
            .collect();
        list.sort_by(|a, b| a["owner"].as_str().cmp(&b["owner"].as_str()));
        json!(list)
    }

    /// `PUT /v1/obid/sphere/membership`: a new card and/or delegation the owner signed (to take
    /// `run_request`, or a delegation with `send:run_request`, or a fresh one), checked as at
    /// joining. The card goes to the Sphere first; the delegation is kept and the token renewed.
    pub async fn renew(self: &Arc<Self>, body: &[u8]) -> Result<Value, ApiError> {
        let _one = self.joining.lock().await;
        let map = object(body, &["card", "delegation"])?;
        let invalid = |m: String| api(StatusCode::UNPROCESSABLE_ENTITY, m);
        if map.is_empty() {
            return Err(invalid(
                "The body has a card, a delegation, or both.".into(),
            ));
        }
        let (key, membership) = {
            let state = self.lock();
            let membership = state
                .membership
                .clone()
                .filter(|m| m.state == "joined")
                .ok_or_else(|| api(StatusCode::CONFLICT, "obid hasn't joined a Sphere."))?;
            (
                state
                    .key
                    .clone()
                    .ok_or_else(|| api(StatusCode::CONFLICT, "There's no Obi key."))?,
                membership,
            )
        };
        let now = time::now();
        let owner_key = obi_protocol::card::params(&membership.card)
            .and_then(|p| {
                p.get("owner_key")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_default();
        let mut card = None;
        if let Some(new) = map.get("card") {
            obi_protocol::card::verify(
                new,
                &obi_protocol::card::Context {
                    now: Some(now),
                    bound_owner_key: Some(owner_key.clone()),
                },
            )
            .map_err(|r| invalid(format!("The card doesn't pass the spec's checks: {r}")))?;
            let params = obi_protocol::card::params(new).expect("a verified card has its params");
            let param = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or("");
            if param("key_id") != key.key_id()
                || param("obi_id") != membership.obi_id
                || param("sphere") != membership.sphere
                || param("owner") != self.config.owner
            {
                return Err(invalid(
                    "The card isn't for this Obi, its key, Sphere and owner.".into(),
                ));
            }
            if params.get("card_seq").and_then(Value::as_u64).unwrap_or(0) <= membership.card_seq()
            {
                return Err(invalid(format!(
                    "The card's card_seq must be more than {}.",
                    membership.card_seq()
                )));
            }
            card = Some(new.clone());
        }
        let delegation = match map.get("delegation") {
            None => None,
            Some(Value::String(d)) => {
                obi_protocol::identity::check_delegation(
                    d,
                    &obi_protocol::identity::DelegationCheck {
                        owner_key: &owner_key,
                        owner: &self.config.owner,
                        sphere: &membership.sphere,
                        obi_id: &membership.obi_id,
                        now,
                        needs: &NEEDED_SCOPES,
                    },
                )
                .map_err(|why| invalid(format!("The delegation doesn't pass: {why}.")))?;
                Some(d.clone())
            }
            Some(_) => {
                return Err(invalid(
                    "delegation is the owner's delegation, a JWT.".into(),
                ));
            }
        };
        if let Some(d) = &delegation {
            crate::secrets::known().learn(DELEGATION_SECRET, d);
            self.files.save_delegation(d).map_err(|e| {
                api(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("obid couldn't keep the delegation: {e}"),
                )
            })?;
            let mut state = self.lock();
            state.delegation = Some(d.clone());
            state.token = None;
        }
        if let Some(card) = card {
            let token = self.token().await.map_err(|e| from_client(&e))?;
            self.client()
                .map_err(|e| from_client(&e))?
                .update_card(&token, &membership.obi_id, &card)
                .await
                .map_err(|e| from_client(&e))?;
            let membership = {
                let mut state = self.lock();
                if let Some(m) = state.membership.as_mut() {
                    m.card = card;
                }
                state.membership.clone()
            };
            if let Some(m) = membership {
                let _ = self.files.save_membership(&m);
            }
        }
        if let Err(e) = self.read_directory().await {
            self.note_error(&e);
        }
        Ok(self.membership_json())
    }
}

/// What [`Link::decide_question`] decided.
enum Decided {
    /// Declined (`decisions`: a remembered decision was used).
    Settled { decisions: bool },
    /// In the owner's inbox: its item, boxed (an item is far larger than the rest).
    Inbox(Box<Item>),
    /// The Obi answers it by itself, under this sharing rule.
    ByItself(Rule),
}

/// A failed review result: no findings, no text.
fn failed_result(request: &Value) -> Value {
    let body = &request["body"];
    json!({"for": "review_request", "outcome": "failed", "repo": body["repo"], "head_sha": body["head_sha"], "findings": []})
}

/// Every string in a reply's body, each with where it is (`finding 1 file`, `summary`,
/// `condition 2 kind`): the publish gate scans all of them, the agent's paths too, not only the
/// fields meant as prose (ARCHITECTURE.md section 4: nothing leaves until the scan has passed on
/// everything in it).
pub(crate) fn every_text(body: &Value) -> Vec<(String, String)> {
    fn walk(value: &Value, place: String, out: &mut Vec<(String, String)>) {
        match value {
            Value::String(text) => out.push((place, text.clone())),
            Value::Array(items) => {
                let one = match place.as_str() {
                    "findings" => "finding",
                    "acceptance" => "condition",
                    other => other,
                }
                .to_owned();
                for (i, item) in items.iter().enumerate() {
                    walk(item, format!("{one} {}", i + 1), out);
                }
            }
            Value::Object(fields) => {
                for (key, field) in fields {
                    let here = if place.is_empty() {
                        key.clone()
                    } else {
                        format!("{place} {key}")
                    };
                    walk(field, here, out);
                }
            }
            _ => {}
        }
    }
    let mut out = Vec::new();
    walk(body, String::new(), &mut out);
    out
}

// ---------------------------------------------------------------------------------------------
// Shares of the owner's API accounts (#809, crate::sphere::shares)

/// The answers to "Sangam used the share of Deskree API" (Sangam's design).
pub const SHARE_MORE: &str = "Share 20% more this month";
pub const LEAVE_IT: &str = "Leave it";

/// "1st", "2nd", "23rd": a day of the month as Sangam's words have it.
fn ordinal(day: u8) -> String {
    let suffix = match (day % 10, day % 100) {
        (1, n) if n != 11 => "st",
        (2, n) if n != 12 => "nd",
        (3, n) if n != 13 => "rd",
        _ => "th",
    };
    format!("{day}{suffix}")
}

impl Link {
    /// The owner's shares with each one's period started again when it turned; kept when it did.
    fn rolled_grants(&self, now: i64) -> Vec<super::shares::Grant> {
        let (grants, changed) = {
            let mut state = self.lock();
            let mut changed = false;
            for grant in &mut state.sharing.grants {
                changed |= grant.roll(now);
            }
            (
                state.sharing.grants.clone(),
                changed.then(|| state.sharing.clone()),
            )
        };
        if let Some(sharing) = changed {
            self.save_sharing(&sharing);
        }
        grants
    }

    /// `GET /v1/obid/sharing/grants`'s shares.
    pub fn grants_json(&self) -> Value {
        let now = time::now();
        json!(
            self.rolled_grants(now)
                .iter()
                .map(|g| g.to_json(now))
                .collect::<Vec<_>>()
        )
    }

    /// `PUT /v1/obid/sharing/grants`: a share of `label`'s account, new or changed (one per
    /// account); its offers, statuses and revokes go out at once.
    pub fn put_grant(self: &Arc<Self>, body: &Value, label: &str) -> Result<Value, ApiError> {
        let now = time::now();
        let mut body = body.clone();
        body["label"] = json!(label);
        body["agent"] = json!("claude");
        let account = body["account"].as_str().unwrap_or("").to_owned();
        if body["who"] == self.config.owner {
            return Err(api(
                StatusCode::UNPROCESSABLE_ENTITY,
                "A share is for someone else.",
            ));
        }
        let (grant, sharing) = {
            let mut state = self.lock();
            let kept = state
                .sharing
                .grants
                .iter()
                .position(|g| g.account.as_deref() == Some(&account));
            let grant =
                super::shares::grant_from(&body, kept.map(|i| &state.sharing.grants[i]), now)
                    .map_err(|m| api(StatusCode::UNPROCESSABLE_ENTITY, m))?;
            match kept {
                Some(i) => state.sharing.grants[i] = grant.clone(),
                None => state.sharing.grants.push(grant.clone()),
            }
            (grant, state.sharing.clone())
        };
        self.save_sharing(&sharing);
        // A job running on it for someone it's no longer for comes back.
        self.hosting
            .stop_on_share(&grant.id, |owner| grant.offered_to(owner));
        self.sync_shares_soon(true);
        Ok(grant.to_json(now))
    }

    /// `DELETE /v1/obid/sharing/grants/{id}`: taken back from everyone at once.
    pub fn delete_grant(self: &Arc<Self>, id: &str) -> Result<(), ApiError> {
        let sharing = {
            let mut state = self.lock();
            let before = state.sharing.grants.len();
            state.sharing.grants.retain(|g| g.id != id);
            if state.sharing.grants.len() == before {
                return Err(api(StatusCode::NOT_FOUND, "There's no such share."));
            }
            state.sharing.clone()
        };
        self.save_sharing(&sharing);
        // Taken back: a job running on it comes back at once.
        self.hosting.stop_on_share(id, |_| false);
        self.sync_shares_soon(true);
        Ok(())
    }

    pub(super) fn sync_shares_soon(self: &Arc<Self>, now: bool) {
        let link = self.clone();
        tokio::spawn(async move { link.sync_shares(now).await });
    }

    /// Brings every teammate's view of the owner's shares up to date: a `share_offer` to each
    /// teammate a share is for and who hasn't one open, a `share_revoke` where it's gone or no
    /// longer for them, and a `share_status` when what they used changed (at once when `now`, a
    /// job on it having ended, else at most hourly) or the share itself did.
    pub(super) async fn sync_shares(self: &Arc<Self>, now_please: bool) {
        let _one = self.shares_sync.lock().await;
        let now = time::now();
        let grants = self.rolled_grants(now);
        // Who's in the Sphere now, and whose card takes shares: fresh when there's a share.
        if !grants.is_empty()
            && now - self.lock().directory_read > 15
            && self.lock().membership.is_some()
            && let Err(e) = self.read_directory().await
        {
            self.note_error(&e);
        }
        let (members, open) = {
            let state = self.lock();
            let Some(me) = state
                .membership
                .as_ref()
                .filter(|m| m.state == "joined")
                .map(|m| m.obi_id.clone())
            else {
                return;
            };
            let members: Vec<(String, String)> = state
                .directory
                .members
                .iter()
                .filter(|(obi, m)| {
                    **obi != me && m.active && m.accepts.iter().any(|a| a == "share_offer")
                })
                .map(|(obi, m)| (obi.clone(), m.owner.clone()))
                .collect();
            let open: Vec<Exchange> = state
                .exchanges
                .values()
                .filter(|e| e.kind == "share_offer" && e.direction == "outgoing" && !e.ended())
                .cloned()
                .collect();
            (members, open)
        };
        for exchange in &open {
            let id = exchange.request["body"]["grant"].as_str().unwrap_or("");
            let owner = exchange.peer_owner.clone().unwrap_or_default();
            let still = members.iter().any(|(obi, _)| *obi == exchange.peer);
            match grants
                .iter()
                .find(|g| g.id == id)
                .filter(|g| still && g.offered_to(&owner))
            {
                None => self.host_reply(
                    &exchange.correlation_id,
                    "share_revoke",
                    json!({"grant": id}),
                    "revoked",
                ),
                Some(grant) => {
                    let status = grant.status(&owner, now);
                    let last = exchange.result.clone().unwrap_or_else(|| {
                        let offer = &exchange.request["body"];
                        json!({"grant": id, "used_cents": 0, "limit_cents": offer["limit_cents"], "resets": offer["resets"]})
                    });
                    let changed = |k: &str| status[k] != last[k];
                    let due = now_please || now - exchange.updated >= super::shares::STATUS_EVERY;
                    if changed("limit_cents") || changed("resets") || (changed("used_cents") && due)
                    {
                        self.host_reply(&exchange.correlation_id, "share_status", status, "");
                    }
                }
            }
        }
        for grant in grants.iter().filter(|g| g.who != "nobody") {
            for (obi, owner) in members.iter().filter(|(_, owner)| grant.offered_to(owner)) {
                let offered = open
                    .iter()
                    .any(|e| e.peer == *obi && e.request["body"]["grant"] == grant.id.as_str());
                if offered {
                    continue;
                }
                match self
                    .send_request(
                        obi,
                        "share_offer",
                        grant.offer(now),
                        obi_protocol::MAX_LIFETIME_SECONDS,
                    )
                    .await
                {
                    Ok(_) => tracing::info!("sphere: offered {owner} a share of {}", grant.label),
                    Err(e) => self.note_error(format!(
                        "offering {owner} a share of {}: {}",
                        grant.label, e.message
                    )),
                }
            }
        }
    }

    /// The share `grant` a job from `owner`'s Obi may run on, for `agent`.
    pub(super) fn grant_for(
        &self,
        grant: &str,
        owner: &str,
        agent: &str,
    ) -> Option<super::shares::Grant> {
        self.rolled_grants(time::now())
            .into_iter()
            .find(|g| g.id == grant && g.agent == agent && g.offered_to(owner))
    }

    /// A call on `grant` by `owner`'s job cost `micros`: counted, and when it used the share up,
    /// the owner hears it (Sangam's "Sangam used the share of Deskree API"). What's left.
    pub(super) fn count_use(&self, grant: &str, owner: &str, micros: u64) -> u64 {
        self.count(grant, owner, micros, false).unwrap_or(0)
    }

    /// Counts `micros` on `grant` for `owner` only when the share has that much left, checked
    /// under the same lock; whether it did.
    pub(super) fn reserve(&self, grant: &str, owner: &str, micros: u64) -> bool {
        self.count(grant, owner, micros, true).is_some()
    }

    fn count(&self, grant: &str, owner: &str, micros: u64, only_if_room: bool) -> Option<u64> {
        let now = time::now();
        let (left, used_up, sharing) = {
            let mut state = self.lock();
            let g = state.sharing.grants.iter_mut().find(|g| g.id == grant)?;
            g.roll(now);
            let had = g.left_for(owner);
            if only_if_room && had < micros {
                return None;
            }
            *g.used.entry(owner.to_owned()).or_default() += micros;
            let left = g.left_for(owner);
            let used_up = (had > 0 && left == 0).then(|| g.clone());
            (left, used_up, state.sharing.clone())
        };
        self.save_sharing(&sharing);
        if let Some(g) = used_up {
            self.share_used_item(&g, owner, now);
        }
        Some(left)
    }

    /// Gives back `micros` counted on `grant` for `owner` (a call's worst case, past what it cost).
    pub(super) fn refund(&self, grant: &str, owner: &str, micros: u64) {
        if micros == 0 {
            return;
        }
        let sharing = {
            let mut state = self.lock();
            let Some(g) = state.sharing.grants.iter_mut().find(|g| g.id == grant) else {
                return;
            };
            if let Some(used) = g.used.get_mut(owner) {
                *used = used.saturating_sub(micros);
            }
            state.sharing.clone()
        };
        self.save_sharing(&sharing);
    }

    /// The owner's own job on `account` cost `usd` (Claude Code's `total_cost_usd`): it counts
    /// against the month of every share of that account.
    pub fn count_own(&self, account: &str, usd: f64) {
        if usd.is_nan() || usd <= 0.0 {
            return;
        }
        let micros = (usd * 1_000_000.0).ceil() as u64;
        let ids: Vec<String> = self
            .lock()
            .sharing
            .grants
            .iter()
            .filter(|g| g.account.as_deref() == Some(account))
            .map(|g| g.id.clone())
            .collect();
        let owner = self.config.owner.clone();
        for id in ids {
            self.count_use(&id, &owner, micros);
        }
    }

    /// "Sangam used the share of Deskree API": once a period for each person and share.
    fn share_used_item(&self, grant: &super::shares::Grant, owner: &str, now: i64) {
        if owner == self.config.owner {
            return;
        }
        let name = super::hosting::person(owner);
        let id = format!("share-used-{}-{owner}-{}", grant.id, grant.period);
        let item = Item {
            id: id.clone(),
            kind: "obiRequest".into(),
            job: String::new(),
            title: format!("{name} used the share of {}", grant.label),
            text: format!(
                "All {}% of this month’s share is used (${} of ${}). The job that was running finished; Oby takes no more of {name}’s jobs on it until the {}.",
                (grant.share + grant.extra).min(100),
                grant.limit_micros() / 1_000_000,
                grant.budget_cents / 100,
                ordinal(grant.resets_day)
            ),
            options: vec![SHARE_MORE.into(), LEAVE_IT.into()],
            details: None,
            recommended: Some(1),
            created: now,
            done: None,
            later: None,
            answer: None,
            obi: Some(json!({"type": "share_used", "grant": grant.id, "fromOwner": owner})),
            plugin: None,
            arrived: None,
            confirm: None,
            start: None,
            github: None,
            watch: None,
        };
        {
            let mut state = self.lock();
            if state.inbox.contains_key(&id) {
                return;
            }
            state.inbox.insert(id, item.clone());
        }
        self.save_item(&item);
    }

    /// The owner's answer to "… used the share": 20% more this month (never past all of it), or
    /// leave it.
    fn answer_share_used(
        self: &Arc<Self>,
        mut item: Item,
        answer: Option<String>,
    ) -> Result<Value, ApiError> {
        if let Some(a) = answer
            .as_deref()
            .filter(|a| *a != SHARE_MORE && *a != LEAVE_IT)
        {
            return Err(api(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("The answer is {SHARE_MORE} or {LEAVE_IT}, not {a}."),
            ));
        }
        let grant = item
            .obi
            .as_ref()
            .and_then(|o| o["grant"].as_str())
            .unwrap_or("")
            .to_owned();
        let sharing = {
            let mut state = self.lock();
            let mut sharing = None;
            if answer.as_deref() == Some(SHARE_MORE)
                && let Some(g) = state.sharing.grants.iter_mut().find(|g| g.id == grant)
            {
                g.extra = (g.extra + 20).min(100 - g.share);
                sharing = Some(state.sharing.clone());
            }
            item.done = Some(time::now());
            item.answer = answer;
            state.inbox.insert(item.id.clone(), item.clone());
            sharing
        };
        self.save_item(&item);
        if let Some(sharing) = sharing {
            self.save_sharing(&sharing);
            self.sync_shares_soon(true);
        }
        Ok(item.to_json())
    }

    /// `GET /v1/obid/sharing/shared`: the shares teammates gave this owner.
    pub fn shared_with_me_json(&self) -> Value {
        let exchanges: Vec<Exchange> = self.lock().exchanges.values().cloned().collect();
        let mut list = super::shares::shared_with_me(&exchanges);
        list.sort_by(|a, b| a["owner"].as_str().cmp(&b["owner"].as_str()));
        json!(list)
    }

    /// A job's place from the API's `runsOn`: a teammate's Obi id, or `{obi, grant}` for a share
    /// of their API account they gave this owner.
    pub fn runs_on(&self, place: &Value) -> Result<crate::job::RunsOn, String> {
        let (obi, grant) = match place {
            Value::String(obi) => (obi.as_str(), None),
            Value::Object(map) if map.keys().all(|k| k == "obi" || k == "grant") => (
                map.get("obi").and_then(Value::as_str).unwrap_or(""),
                map.get("grant").and_then(Value::as_str),
            ),
            _ => {
                return Err(
                    "runsOn is a teammate's Obi id, or {obi, grant} for a share they gave you."
                        .into(),
                );
            }
        };
        let owner = self
            .run_host(obi)
            .ok_or_else(|| format!("{obi} isn't a teammate's Mac that takes jobs."))?;
        if let Some(grant) = grant {
            let offered = self.shared_with_me_json();
            if !offered
                .as_array()
                .into_iter()
                .flatten()
                .any(|s| s["grant"] == grant && s["from"] == obi)
            {
                return Err(format!(
                    "{} hasn't shared that account with you.",
                    super::hosting::person(&owner)
                ));
            }
        }
        Ok(crate::job::RunsOn {
            obi: obi.to_owned(),
            owner,
            grant: grant.map(str::to_owned),
        })
    }

    /// Whether this Obi's card takes teammates' shares (`share_offer`).
    pub fn takes_shares(&self) -> bool {
        self.lock()
            .membership
            .as_ref()
            .is_some_and(|m| m.accepts().iter().any(|a| a == "share_offer"))
    }
}

/// Why a Confirm without the owner's tap is refused (#776).
pub const NEEDS_YOUR_TAP: &str =
    "Only your tap can confirm this: confirm it in Oby on your Mac or iPhone.";

#[cfg(test)]
mod tests {
    use super::*;

    /// The publish gate scans every string of the reply: the agent's paths as much as its prose.
    #[test]
    fn the_gate_reads_every_text_of_a_result() {
        let body = json!({"for": "review_request", "outcome": "approved", "repo": "o/r",
            "head_sha": "a".repeat(40), "summary": "S",
            "findings": [{"id": "f-1", "severity": "nit", "file": "src/F1.js", "line": 3, "title": "T1", "detail": "D1"},
                         {"id": "f-2", "severity": "minor", "file": "src/F2.js", "line": 4, "title": "T2", "detail": "D2", "end_line": 5}],
            "acceptance": [{"index": 0, "kind": "tests_pass", "met": true}]});
        let texts: std::collections::BTreeMap<String, String> =
            every_text(&body).into_iter().collect();
        for (place, text) in [
            ("finding 1 file", "src/F1.js"),
            ("finding 1 title", "T1"),
            ("finding 1 detail", "D1"),
            ("finding 2 file", "src/F2.js"),
            ("finding 2 title", "T2"),
            ("finding 2 detail", "D2"),
            ("summary", "S"),
            ("repo", "o/r"),
            ("condition 1 kind", "tests_pass"),
        ] {
            assert_eq!(
                texts.get(place).map(String::as_str),
                Some(text),
                "{place}: {texts:?}"
            );
        }
        // Numbers and booleans aren't text; all 16 strings are there.
        assert_eq!(texts.len(), 16, "{texts:?}");
    }

    #[test]
    fn base_urls() {
        assert!(is_base_url("http://127.0.0.1:8787"));
        assert!(is_base_url("https://sphere.example.com"));
        assert!(!is_base_url("http://127.0.0.1:8787/v0.1"));
        assert!(!is_base_url("ftp://x"));
        assert!(!is_base_url("http://"));
        assert!(!is_base_url("http://a?b"));
        // Plain http only on this machine.
        assert!(is_base_url("http://localhost:8787"));
        assert!(is_base_url("http://[::1]:8787"));
        assert!(is_base_url("http://127.0.0.2"));
        assert!(!is_base_url("http://obysphere.deskree.com"));
        assert!(!is_base_url("http://10.0.0.5:8787"));
        assert!(!is_base_url("http://169.254.169.254"));
        assert!(!is_base_url("http://127.0.0.1.nip.io"));
        assert!(is_base_url("https://obysphere.deskree.com"));
    }

    #[test]
    fn later_dates() {
        assert_eq!(
            parse_later("2026-10-10T10:12:00Z"),
            time::parse("2026-10-10T10:12:00Z")
        );
        assert_eq!(
            parse_later("2026-10-10T10:12:00.123Z"),
            time::parse("2026-10-10T10:12:00Z")
        );
        assert_eq!(parse_later("tomorrow"), None);
        assert_eq!(parse_later("2026-10-10T10:12:00.Z"), None);
    }

    #[test]
    fn a_failed_result_has_no_text_and_passes_the_schema() {
        let request = json!({"body": {"repo": "obi-e2e/fixture-app", "head_sha": "6d20146f366b9fac8907b5066c30ee39aaec09b3"}});
        let mut body = failed_result(&request);
        assert!(obi_protocol::schema::is_valid("actions/result", &body));
        body["by_rule"] = json!("d-3f9a0c1b2e4d");
        assert!(obi_protocol::schema::is_valid("actions/result", &body));
    }

    #[test]
    fn bodies_take_only_their_fields() {
        assert!(object(br#"{"to": "x"}"#, &["to"]).is_ok());
        assert_eq!(
            object(br#"{"to": "x", "prompt": "y"}"#, &["to"])
                .err()
                .unwrap()
                .status,
            StatusCode::UNPROCESSABLE_ENTITY
        );
        assert_eq!(
            object(b"[", &["to"]).err().unwrap().status,
            StatusCode::BAD_REQUEST
        );
    }

    /// A save keeps and tells what is in memory now, never an older copy its caller still holds:
    /// a request's arrival that saves after the owner already answered can't put the item back to
    /// open, nor its exchange back to waiting, on the stream or on disk.
    #[tokio::test]
    async fn a_save_keeps_and_tells_what_is_there_now() {
        let home = std::env::temp_dir().join(format!("obid-link-save-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let config = Config::parse(
            &json!({"listen": "127.0.0.1:0", "home": home, "owner": "wellington"}).to_string(),
        )
        .unwrap();
        let events = Events::new();
        let jobs = Jobs::open(config.clone(), events.clone(), Err("no sandbox".into())).unwrap();
        let (_stop, stopping) = watch::channel(false);
        let link = Link::open(config, jobs, events.clone(), stopping).unwrap();
        let mut heard = events.subscribe();

        let request = json!({"id": "c-1", "correlation_id": "c-1", "type": "review_request",
            "body": {"repo": "o/r"}});
        let mut arrived = Exchange::new("incoming", request.clone(), "obi-ernesto".into(), None);
        arrived.state = "inbox".into();
        let item = inbox::review_request_item(
            "c-1",
            "obi-ernesto",
            "ernesto",
            &request["body"],
            "2099-01-01T09:00:00Z",
            time::now(),
        );
        let mut answered = item.clone();
        answered.done = Some(time::now());
        answered.answer = Some(inbox::DECLINE.into());
        let mut declined = arrived.clone();
        declined.state = "declined".into();
        {
            let mut state = link.lock();
            state.inbox.insert(item.id.clone(), answered.clone());
            state
                .exchanges
                .insert(declined.correlation_id.clone(), declined.clone());
        }
        // The answer saves first; the arrival, slower, saves its older copies after.
        link.save_item(&answered);
        link.save_exchange(&declined);
        link.save_item(&item);
        link.save_exchange(&arrived);

        let mut told = Vec::new();
        while let Ok(event) = heard.try_recv() {
            told.push((event.name, event.data["state"].clone()));
        }
        assert_eq!(
            told,
            [
                ("inbox", json!("done")),
                ("exchange", json!("declined")),
                ("inbox", json!("done")),
                ("exchange", json!("declined")),
            ]
        );
        let kept = Inbox::open(&home).unwrap().load_all();
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].answer.as_deref(), Some(inbox::DECLINE));
        let kept = Exchanges::open(&home).unwrap().load_all();
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].state, "declined");
        let _ = std::fs::remove_dir_all(&home);
    }

    /// A link, its home under `name`: in a Sphere when `joined`, as kept from before a restart.
    fn sender_link(
        name: &str,
        joined: bool,
    ) -> (Arc<Link>, std::path::PathBuf, watch::Sender<bool>) {
        let home = std::env::temp_dir().join(format!("obid-link-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        if joined {
            Files::new(&home)
                .save_membership(&membership("joined"))
                .unwrap();
        }
        let config = Config::parse(
            &json!({"listen": "127.0.0.1:0", "home": home, "owner": "wellington"}).to_string(),
        )
        .unwrap();
        let events = Events::new();
        let jobs = Jobs::open(config.clone(), events.clone(), Err("no sandbox".into())).unwrap();
        let (stop, stopping) = watch::channel(false);
        let link = Link::open(config, jobs, events, stopping).unwrap();
        (link, home, stop)
    }

    fn membership(state: &str) -> Membership {
        Membership {
            state: state.into(),
            url: "http://127.0.0.1:1".into(),
            sphere: "s".into(),
            obi_id: "obi-wellington".into(),
            card: json!({}),
            joined_at: time::now(),
        }
    }

    /// Out of a Sphere, start() leaves the sender off; in one, start() starts it.
    #[tokio::test]
    async fn the_sender_starts_on_join() {
        let (link, home, _stop) = sender_link("sender-out", false);
        link.start();
        assert!(!link.sender_running.load(Ordering::SeqCst));
        let _ = std::fs::remove_dir_all(&home);

        let (link, home, _stop) = sender_link("sender-in", true);
        link.start();
        assert!(link.sender_running.load(Ordering::SeqCst));
        let _ = std::fs::remove_dir_all(&home);
    }

    /// The sender stops when obid leaves its Sphere, and nothing holds the link any more.
    #[tokio::test]
    async fn the_sender_stops_on_leave() {
        let (link, home, _stop) = sender_link("sender-leave", false);
        link.lock().membership = Some(membership("joined"));
        link.start_sender();
        assert!(link.sender_running.load(Ordering::SeqCst));

        link.lock().membership = Some(membership("revoked"));
        link.outbox.notify_one();
        tokio::time::timeout(Duration::from_secs(5), async {
            while link.sender_running.load(Ordering::SeqCst) || Arc::strong_count(&link) > 1 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the sender stops");
        let _ = std::fs::remove_dir_all(&home);
    }

    /// Revoked, obid can answer no request any more: each open incoming one is settled, its inbox
    /// item done, with no decline queued (the sender has stopped); an ended one, and one this Obi
    /// sent, are left as they are.
    #[tokio::test]
    async fn a_revoke_settles_open_incoming_requests() {
        let (link, home, _stop) = sender_link("sender-revoke", false);
        let request = |cid: &str| {
            json!({"id": cid, "correlation_id": cid, "type": "review_request",
                "body": {"repo": "o/r"}, "expires_at": "2099-01-01T09:00:00Z"})
        };
        let item = inbox::review_request_item(
            "c-open",
            "obi-ernesto",
            "ernesto",
            &request("c-open")["body"],
            "2099-01-01T09:00:00Z",
            time::now(),
        );
        let mut open = Exchange::new("incoming", request("c-open"), "obi-ernesto".into(), None);
        open.state = "inbox".into();
        open.inbox_item = Some(item.id.clone());
        let mut answering = Exchange::new(
            "incoming",
            request("c-answering"),
            "obi-ernesto".into(),
            None,
        );
        answering.state = "answering".into();
        let mut done = Exchange::new("incoming", request("c-done"), "obi-ernesto".into(), None);
        done.state = "done".into();
        let mut sent = Exchange::new("outgoing", request("c-sent"), "obi-ernesto".into(), None);
        sent.state = "sent".into();
        {
            let mut state = link.lock();
            state.inbox.insert(item.id.clone(), item.clone());
            for e in [&open, &answering, &done, &sent] {
                state.exchanges.insert(e.correlation_id.clone(), e.clone());
            }
        }

        link.settle_on_revoke();
        let state = link.lock();
        for cid in ["c-open", "c-answering"] {
            assert_eq!(state.exchanges[cid].state, "declined");
            assert!(
                state.exchanges[cid].outbox.is_empty(),
                "no decline for {cid}"
            );
        }
        assert!(state.inbox[&item.id].done.is_some());
        assert_eq!(state.exchanges["c-done"].state, "done");
        assert_eq!(state.exchanges["c-sent"].state, "sent");
        drop(state);
        let _ = std::fs::remove_dir_all(&home);
    }

    /// The inbox lists what needs the owner first (with what waits for the model), then FYI, then
    /// ignore, each by arrival; a second item about the same thing is `ignore` while the one that
    /// stands for it is open, an offer standing before what only says something; and the model's
    /// sort is kept once, the apps told (crate::triage).
    #[tokio::test]
    async fn the_inbox_lists_what_needs_you_first() {
        let home = std::env::temp_dir().join(format!("obid-link-triage-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let config = Config::parse(
            &json!({"listen": "127.0.0.1:0", "home": home, "owner": "wellington"}).to_string(),
        )
        .unwrap();
        let events = Events::new();
        let jobs = Jobs::open(config.clone(), events.clone(), Err("no sandbox".into())).unwrap();
        let (_stop, stopping) = watch::channel(false);
        let link = Link::open(config, jobs, events.clone(), stopping).unwrap();
        let mut heard = events.subscribe();
        let event = |id: &str, kind: &str, subject: Value| -> obi_plugin_api::PluginEvent {
            serde_json::from_value(json!({"plugin": "tetrix", "event": {"id": id, "kind": kind,
                "occurredAt": "2026-10-23T03:12:00Z", "subject": subject, "actor": "sangam",
                "data": {"title": "Needs you NOW", "url": "https://example.com/x"}}}))
            .unwrap()
        };
        let warning = event(
            "w",
            "alert.fired",
            json!({"repo": "o/r", "project": "api", "severity": "warning"}),
        );
        let review = event(
            "r",
            "pull_request.review_requested",
            json!({"repo": "o/r", "pr": 12}),
        );
        link.plugin_event(warning);
        link.plugin_event(review);
        let work: crate::github_work::Item = serde_json::from_value(json!({
            "id": "i-7", "list": "assigned", "repo": "o/r", "number": 7, "title": "Fix it",
            "url": "https://github.com/o/r/issues/7", "author": "sangam", "labels": [],
            "updated": "2026-10-23T03:12:00Z", "state": "OPEN", "draft": null,
            "reviewDecision": null, "checks": null, "board": null}))
        .unwrap();
        let mut asked = work.clone();
        (asked.id, asked.list, asked.number) = ("r-12".into(), "reviews".into(), 12);
        link.github_work(&[asked, work], None);

        let drain = |heard: &mut tokio::sync::broadcast::Receiver<crate::events::Event>| {
            std::iter::from_fn(|| heard.try_recv().ok())
                .map(|e| (e.data["title"].clone(), e.data["triage"].clone()))
                .collect::<Vec<_>>()
        };
        // The plug-in's review request needed the owner when it came; the feed's offer of the same
        // review then stands for both.
        assert_eq!(
            drain(&mut heard),
            [
                (json!("Alert: api (warning)"), json!("fyi")),
                (json!("Review requested: o/r #12"), json!("needs_you")),
                (json!("Review requested: r #12"), json!("needs_you")),
                (json!("Assigned to you: r #7"), json!("pending")),
            ]
        );
        let order = |items: Vec<Value>| -> Vec<(String, Value)> {
            items
                .iter()
                .map(|i| (i["title"].as_str().unwrap().to_owned(), i["triage"].clone()))
                .collect()
        };
        let listed = order(link.inbox_json(false, 50).as_array().unwrap().clone());
        assert_eq!(
            listed,
            [
                ("Review requested: r #12".to_owned(), json!("needs_you")),
                ("Assigned to you: r #7".to_owned(), json!("pending")),
                ("Alert: api (warning)".to_owned(), json!("fyi")),
                ("Review requested: o/r #12".to_owned(), json!("ignore")),
            ]
        );
        let waiting: Vec<String> = link
            .waiting_items(time::now())
            .into_iter()
            .map(|i| i.title)
            .collect();
        assert_eq!(
            waiting,
            listed.iter().map(|(t, _)| t.clone()).collect::<Vec<_>>()
        );
        // The offer dismissed, the plug-in's request needs the owner again.
        link.answer("github-r-12", br#"{"answer": "Dismiss"}"#)
            .await
            .ok()
            .unwrap();
        assert_eq!(
            order(link.inbox_json(false, 50).as_array().unwrap().clone())[0],
            ("Review requested: o/r #12".to_owned(), json!("needs_you"))
        );
        drain(&mut heard);

        // Only the assigned issue waits for the model; its sort is kept once, the apps told.
        let unsorted = link.unsorted();
        assert_eq!(unsorted.len(), 1);
        let id = unsorted[0].id.clone();
        link.sorted(&[(id.clone(), crate::triage::FYI)]);
        link.sorted(&[(id.clone(), crate::triage::NEEDS_YOU)]);
        assert_eq!(
            drain(&mut heard),
            [(json!("Assigned to you: r #7"), json!("fyi"))]
        );
        assert!(link.unsorted().is_empty());
        // Answered, it shows its sort too; nothing was answered or settled by sorting.
        let answered = link
            .answer(&id, br#"{"answer": "Dismiss"}"#)
            .await
            .ok()
            .unwrap();
        assert_eq!(
            (&answered["state"], &answered["triage"]),
            (&json!("done"), &json!("fyi"))
        );
        assert_eq!(link.inbox_json(true, 50).as_array().unwrap().len(), 2);
        let _ = std::fs::remove_dir_all(&home);
    }
}
