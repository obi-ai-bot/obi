//! The accounts the agents run on, as the owner adds, renames, removes and signs them in from the
//! apps (docs/runner-api.md, "POST /v1/accounts" to "GET /v1/accounts/{id}/sign-in").
//!
//! The configuration's `agents.<tool>.accounts` are the seed. What the API changes is kept in
//! `home/accounts.json` (0600) and laid over the seed at every start ([`Live::open`]), so a restart
//! keeps it and the configuration file is never rewritten. Every copy of the configuration shares
//! one [`Live`], so a change reaches routing, the brain and the gateway's scrubbing at once. An
//! account the API adds always has a folder obid makes, `home/accounts/<id>`.
//!
//! Signing in runs the tool's own login, never obid's (AGENTS.md), in the account's own folder: no
//! box ever gets that folder (#655), so nothing a job wrote can steer the login, and obid never
//! reads or copies what it writes. obid passes on only the link to open and the code to type,
//! both read from what the login prints and checked, and the code the person pastes back goes to
//! the login's stdin. Nothing else the login prints is kept, shown or logged.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::{Path as UrlPath, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::agent::Tool;
use crate::api::{AccountJson, ApiError, Shared};
use crate::config::{Account, Agent, Agents};

/// Where obid keeps what the API changed, under its home.
const FILE: &str = "accounts.json";

/// The longest name or payer, in characters.
const LONGEST: usize = 60;

/// The most accounts obid keeps, the configuration's and the API's together.
const MOST_ACCOUNTS: usize = 32;

/// How long a sign-in may wait for the person: Codex's one-time code lasts 15 minutes.
const SIGN_IN_LASTS: Duration = Duration::from_secs(15 * 60);

/// How long a login may take to print its link.
const LINK_WITHIN: Duration = Duration::from_secs(30);

/// How long a pasted code may take to sign the login in.
const CODE_WITHIN: Duration = Duration::from_secs(60);

/// The longest line of a login's output obid reads; the rest of a longer line is dropped.
const LONGEST_LINE: usize = 4096;

/// The `PATH` a login runs with: the system's folders, then the folder of the tool's own binary.
const SYSTEM_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

/// The folders a sign-in uses for its temporary files, under obid's home: `sign-in-<…>`, swept at
/// every start ([`sweep`]).
const SCRATCH_PREFIX: &str = "sign-in-";

// ---------------------------------------------------------------------------------------------
// The accounts, live

/// The agents' accounts as they are now: the configuration's, with what the API changed laid over
/// them. Cloning shares it.
#[derive(Clone)]
pub struct Live(Arc<RwLock<Inner>>);

struct Inner {
    seed: Agents,
    saved: Saved,
    /// `home/accounts.json`, once [`Live::open`] read it.
    file: Option<PathBuf>,
    /// Why `home/accounts.json` can't be used: nothing is changed while it can't.
    broken: Option<String>,
    agents: Agents,
}

/// What the API changed: the accounts it added, and the configuration's accounts it renamed or
/// removed.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Saved {
    #[serde(default)]
    added: Vec<Added>,
    #[serde(default)]
    changed: BTreeMap<String, Change>,
    #[serde(default)]
    removed: Vec<String>,
}

/// An account the API added: its folder is obid's own, `home/accounts/<id>`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Added {
    id: String,
    agent: String,
    name: String,
    #[serde(default)]
    payer: Option<String>,
    config_dir: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Change {
    name: String,
    #[serde(default)]
    payer: Option<String>,
}

impl Added {
    fn account(&self) -> Account {
        Account {
            id: self.id.clone(),
            name: self.name.clone(),
            payer: self.payer.clone(),
            config_dir: Some(self.config_dir.clone()),
        }
    }
}

impl Live {
    pub fn new(seed: Agents) -> Live {
        Live(Arc::new(RwLock::new(Inner {
            agents: seed.clone(),
            seed,
            saved: Saved::default(),
            file: None,
            broken: None,
        })))
    }

    /// The agents and their accounts now.
    pub fn get(&self) -> Agents {
        self.read().agents.clone()
    }

    fn read(&self) -> std::sync::RwLockReadGuard<'_, Inner> {
        self.0.read().unwrap_or_else(|e| e.into_inner())
    }

    fn write(&self) -> std::sync::RwLockWriteGuard<'_, Inner> {
        self.0.write().unwrap_or_else(|e| e.into_inner())
    }

    /// Lays `home/accounts.json` over the configuration's accounts (crate::serve, before anything
    /// uses them), each entry checked as the API checks it ([`checked`]): one that isn't right is
    /// left out and logged. A file that doesn't read is left as it is, logged, and changes are
    /// refused until the owner fixes or removes it.
    pub fn open(&self, home: &Path) {
        let file = home.join(FILE);
        let mut inner = self.write();
        match std::fs::read(&file) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => inner.broken = Some(format!("obid can't read {}: {e}", file.display())),
            Ok(bytes) => match serde_json::from_slice::<Saved>(&bytes) {
                Ok(saved) => inner.saved = checked(&inner.seed, saved, home),
                Err(e) => inner.broken = Some(format!("{} doesn't read: {e}", file.display())),
            },
        }
        if let Some(why) = &inner.broken {
            tracing::warn!("{why}: accounts can't be changed until it's fixed or removed");
        }
        inner.agents = merged(&inner.seed, &inner.saved);
        inner.file = Some(file);
    }

    /// Changes what's saved with `change`, keeps it, and only then uses it. `change` answers what
    /// the caller needs, or why it refused.
    fn change<T>(
        &self,
        change: impl FnOnce(&Agents, &mut Saved) -> Result<T, ApiError>,
    ) -> Result<T, ApiError> {
        let mut inner = self.write();
        if let Some(why) = &inner.broken {
            return Err(ApiError::new(StatusCode::SERVICE_UNAVAILABLE, why.clone()));
        }
        let mut saved = inner.saved.clone();
        let answer = change(&inner.agents, &mut saved)?;
        if let Some(file) = &inner.file {
            let text = serde_json::to_vec_pretty(&saved).map_err(|e| unkept(file, e))?;
            crate::store::write_private(file, &text).map_err(|e| unkept(file, e))?;
        }
        inner.agents = merged(&inner.seed, &saved);
        inner.saved = saved;
        Ok(answer)
    }
}

fn unkept(file: &Path, e: impl std::fmt::Display) -> ApiError {
    ApiError::new(
        StatusCode::INTERNAL_SERVER_ERROR,
        format!("obid couldn't keep the change in {}: {e}", file.display()),
    )
}

impl std::fmt::Debug for Live {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Live").field(&self.get()).finish()
    }
}

impl PartialEq for Live {
    fn eq(&self, other: &Live) -> bool {
        self.get() == other.get()
    }
}

impl Eq for Live {}

/// `saved` as read from `home/accounts.json`, with what the API would refuse left out (and
/// logged): an added account must have an id obid makes, a tool, its folder `home/accounts/<id>`,
/// a name and payer the API takes and no other account's name, and keep the total within
/// [`MOST_ACCOUNTS`]; a change's name and payer the same.
fn checked(seed: &Agents, saved: Saved, home: &Path) -> Saved {
    let drop = |what: &str, id: &str| {
        tracing::warn!("{}: {what} {id:?} left out", home.join(FILE).display());
    };
    let mut kept = Saved {
        removed: saved.removed,
        ..Saved::default()
    };
    for (id, change) in saved.changed {
        // A configured account's, with a name no other account of its tool has.
        let agents = merged(seed, &kept);
        let fine = find(&agents, &id).and_then(|(tool, _)| {
            let name = name(&agents, tool, &change.name, Some(&id)).ok()?;
            let payer = payer_text(change.payer.as_deref()).ok()?;
            Some(Change { name, payer })
        });
        match fine {
            Some(change) => {
                kept.changed.insert(id, change);
            }
            None => drop("change", &id),
        }
    }
    for added in saved.added {
        let agents = merged(seed, &kept);
        let fine = Tool::from_id(&added.agent).filter(|_| {
            own_folder(home, &added.id).is_some_and(|own| own == added.config_dir)
                && find(&agents, &added.id).is_none()
                && all(&agents).len() < MOST_ACCOUNTS
                && payer_text(added.payer.as_deref()).is_ok()
        });
        match fine.map(|tool| name(&agents, tool, &added.name, None)) {
            Some(Ok(name)) if name == added.name => kept.added.push(added),
            _ => drop("account", &added.id),
        }
    }
    kept
}

/// The tool's own default login, which an empty `accounts` stands for (Cursor has none: each of
/// its accounts needs a folder).
fn implicit(tool: Tool) -> Vec<Account> {
    let (id, name) = match tool {
        Tool::Claude => ("default", "Default"),
        Tool::Codex => ("codex", "Codex"),
        Tool::Cursor => return Vec::new(),
    };
    vec![Account {
        id: id.into(),
        name: name.into(),
        payer: None,
        config_dir: None,
    }]
}

/// The binary a tool the configuration doesn't name runs as, found on the login shell's `PATH`.
fn default_bin(tool: Tool) -> &'static str {
    match tool {
        Tool::Claude => "claude",
        Tool::Codex => "codex",
        Tool::Cursor => "cursor-agent",
    }
}

fn agent_of(agents: &Agents, tool: Tool) -> &Option<Agent> {
    match tool {
        Tool::Claude => &agents.claude,
        Tool::Codex => &agents.codex,
        Tool::Cursor => &agents.cursor,
    }
}

fn agent_of_mut(agents: &mut Agents, tool: Tool) -> &mut Option<Agent> {
    match tool {
        Tool::Claude => &mut agents.claude,
        Tool::Codex => &mut agents.codex,
        Tool::Cursor => &mut agents.cursor,
    }
}

/// The configuration's accounts with `saved` laid over them: renamed, removed, then the added
/// ones after. A tool the configuration doesn't name is there while it has an added account. A
/// tool whose accounts were all removed is gone, rather than back on its own default login (an
/// empty list's meaning): its default login is listed (and can be removed) once anything about
/// the tool's accounts changed.
fn merged(seed: &Agents, saved: &Saved) -> Agents {
    let seeded: Vec<String> = Tool::ALL
        .iter()
        .filter_map(|t| agent_of(seed, *t).as_ref())
        .flat_map(|a| a.accounts.iter().map(|a| a.id.clone()))
        .collect();
    let mut agents = seed.clone();
    for tool in Tool::ALL {
        let added: Vec<Account> = saved
            .added
            .iter()
            .filter(|a| a.agent == tool.id() && !seeded.contains(&a.id))
            .map(Added::account)
            .collect();
        let slot = agent_of_mut(&mut agents, tool);
        let agent = match slot {
            Some(agent) => {
                let own_removed = implicit(tool).iter().any(|a| saved.removed.contains(&a.id));
                if agent.accounts.is_empty() && (!added.is_empty() || own_removed) {
                    agent.accounts = implicit(tool);
                }
                agent
            }
            None if added.is_empty() => continue,
            None => slot.insert(Agent {
                bin: default_bin(tool).into(),
                accounts: Vec::new(),
            }),
        };
        let had = agent.accounts.len() + added.len();
        agent.accounts.retain(|a| !saved.removed.contains(&a.id));
        for account in &mut agent.accounts {
            if let Some(change) = saved.changed.get(&account.id) {
                account.name = change.name.clone();
                account.payer = change.payer.clone();
            }
        }
        agent.accounts.extend(added);
        if had > 0 && agent.accounts.is_empty() {
            *slot = None;
        }
    }
    agents
}

/// Every account, with its tool.
fn all(agents: &Agents) -> Vec<(Tool, Account)> {
    Tool::ALL
        .iter()
        .filter_map(|t| agent_of(agents, *t).as_ref().map(|a| (*t, a)))
        .flat_map(|(t, a)| a.accounts.iter().map(move |a| (t, a.clone())))
        .collect()
}

/// The account `id`, with its tool.
pub fn find(agents: &Agents, id: &str) -> Option<(Tool, Account)> {
    all(agents).into_iter().find(|(_, a)| a.id == id)
}

// ---------------------------------------------------------------------------------------------
// What the owner may give

fn unprocessable(message: impl Into<String>) -> ApiError {
    ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, message)
}

/// A name or payer: one line, trimmed, 1 to 60 characters.
fn one_line(what: &str, text: &str) -> Result<String, ApiError> {
    let text = text.trim();
    let count = text.chars().count();
    if count == 0 || count > LONGEST || text.chars().any(char::is_control) {
        return Err(unprocessable(format!(
            "{what} is one line of 1 to {LONGEST} characters."
        )));
    }
    Ok(text.to_owned())
}

/// A name no other account of the tool has, as its name or its id (jobs name an account by
/// either), letter case aside.
fn name(agents: &Agents, tool: Tool, text: &str, except: Option<&str>) -> Result<String, ApiError> {
    let name = one_line("name", text)?;
    let lower = name.to_lowercase();
    let taken = agent_of(agents, tool)
        .iter()
        .flat_map(|a| &a.accounts)
        .any(|a| {
            Some(a.id.as_str()) != except
                && (a.name.to_lowercase() == lower || a.id.to_lowercase() == lower)
        });
    if taken {
        return Err(unprocessable(format!(
            "name {name:?} is another {} account's already.",
            tool.name()
        )));
    }
    Ok(name)
}

/// A payer, or none for empty or null.
fn payer(value: Option<&Value>) -> Result<Option<String>, ApiError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => payer_text(Some(text)),
        Some(_) => Err(unprocessable("payer is text or null.")),
    }
}

fn payer_text(text: Option<&str>) -> Result<Option<String>, ApiError> {
    match text {
        None => Ok(None),
        Some(text) if text.trim().is_empty() => Ok(None),
        Some(text) => one_line("payer", text).map(Some),
    }
}

/// An id no account has, nor had (a removed one), as job ids are made.
fn new_id(agents: &Agents, saved: &Saved) -> String {
    loop {
        let mut bytes = [0u8; 4];
        getrandom::fill(&mut bytes).expect("the system's random source works");
        let id = hex::encode(bytes);
        if find(agents, &id).is_none() && !saved.removed.contains(&id) {
            return id;
        }
    }
}

/// The folder obid makes for an account it adds: `home/accounts/<id>`, `id` being one obid made
/// (eight lowercase hex digits: macOS ignores letter case, so `A1B2C3D4` would be `a1b2c3d4`'s
/// folder), never one anybody wrote.
fn own_folder(home: &Path, id: &str) -> Option<PathBuf> {
    (id.len() == 8 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')))
        .then(|| home.join("accounts").join(id))
}

/// The body as a JSON object with only `keys`.
fn object(body: &Bytes, keys: &[&str], shape: &str) -> Result<Map<String, Value>, ApiError> {
    let Ok(Value::Object(map)) = serde_json::from_slice::<Value>(body) else {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            format!("The body is {shape}."),
        ));
    };
    if let Some(key) = map.keys().find(|k| !keys.contains(&k.as_str())) {
        return Err(unprocessable(format!(
            "{key} isn't something an account has here: the body is {shape}."
        )));
    }
    Ok(map)
}

fn text_field<'a>(map: &'a Map<String, Value>, key: &str) -> Result<Option<&'a str>, ApiError> {
    match map.get(key) {
        None => Ok(None),
        Some(Value::String(text)) => Ok(Some(text)),
        Some(_) => Err(unprocessable(format!("{key} is text."))),
    }
}

fn no_account(id: &str) -> ApiError {
    ApiError::new(StatusCode::NOT_FOUND, format!("There's no account {id:?}."))
}

fn answer(status: StatusCode, value: impl Serialize) -> Response {
    (status, axum::Json(value)).into_response()
}

/// Every account as the apps see it, worked out off obid's async runtime: whether an account is
/// signed in can ask the macOS Keychain (`security`), which blocks.
pub async fn list_now(shared: &Arc<Shared>) -> Vec<AccountJson> {
    let shared = shared.clone();
    tokio::task::spawn_blocking(move || crate::api::account_list(&shared))
        .await
        .unwrap_or_default()
}

/// One account as the apps see it, off obid's async runtime ([`list_now`]).
async fn json_now(shared: &Arc<Shared>, tool: Tool, account: Account) -> Option<AccountJson> {
    let shared = shared.clone();
    tokio::task::spawn_blocking(move || crate::api::account_json(&shared, tool, &account))
        .await
        .ok()
}

/// Tells every app the accounts as they are now (`accounts`, docs/runner-api.md, "GET /v1/events").
pub async fn send_accounts(shared: &Arc<Shared>) {
    let list = list_now(shared).await;
    shared
        .events
        .send("accounts", serde_json::to_value(list).unwrap_or_default());
}

// ---------------------------------------------------------------------------------------------
// POST /v1/accounts, PATCH and DELETE /v1/accounts/{id}

const NEW_SHAPE: &str =
    "{\"agent\": \"claude\" | \"codex\" | \"cursor\", \"name\": \"…\", \"payer\": \"…\"}";

/// `POST /v1/accounts`: a new account for Claude Code, Codex or Cursor, in a folder obid makes,
/// `home/accounts/<id>` (0700). `201` with the Account.
pub async fn add(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    let map = object(&body, &["agent", "name", "payer"], NEW_SHAPE)?;
    let agent = text_field(&map, "agent")?
        .ok_or_else(|| unprocessable(format!("agent is missing: the body is {NEW_SHAPE}.")))?;
    let tool = Tool::from_id(agent).ok_or_else(|| {
        unprocessable(format!("agent is claude, codex or cursor, not {agent:?}."))
    })?;
    let text = text_field(&map, "name")?
        .ok_or_else(|| unprocessable(format!("name is missing: the body is {NEW_SHAPE}.")))?;
    let payer = payer(map.get("payer"))?;
    let home = shared.config.home.clone();
    let added = shared.config.agents.change(|agents, saved| {
        if all(agents).len() >= MOST_ACCOUNTS {
            return Err(unprocessable(format!(
                "obid keeps at most {MOST_ACCOUNTS} accounts: remove one first."
            )));
        }
        let name = name(agents, tool, text, None)?;
        let id = new_id(agents, saved);
        let config_dir = own_folder(&home, &id).expect("obid's own id");
        make_folder(&config_dir).map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("obid couldn't make the account's folder: {e}"),
            )
        })?;
        let added = Added {
            id,
            agent: tool.id().into(),
            name,
            payer,
            config_dir,
        };
        saved.added.push(added.clone());
        Ok(added)
    })?;
    tracing::info!("account {}: added ({})", added.id, tool.id());
    send_accounts(&shared).await;
    Ok(answer(
        StatusCode::CREATED,
        json_now(&shared, tool, added.account()).await,
    ))
}

/// A new folder of obid's own (0700), in a private `home/accounts` (or `home/tmp`).
fn make_folder(dir: &Path) -> std::io::Result<()> {
    if let Some(parent) = dir.parent() {
        crate::store::make_private_dir(parent)?;
    }
    let mut builder = std::fs::DirBuilder::new();
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(dir)
}

const CHANGE_SHAPE: &str = "{\"name\": \"…\", \"payer\": \"…\" | null}";

/// `PATCH /v1/accounts/{id}`: a new name, a new payer (null for none), or both. The Account.
pub async fn change(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let map = object(&body, &["name", "payer"], CHANGE_SHAPE)?;
    let text = text_field(&map, "name")?;
    let new_payer = map.contains_key("payer").then(|| payer(map.get("payer")));
    let (tool, account) = shared.config.agents.change(|agents, saved| {
        let (tool, mut account) = find(agents, &id).ok_or_else(|| no_account(&id))?;
        if let Some(text) = text {
            account.name = name(agents, tool, text, Some(&id))?;
        }
        if let Some(new_payer) = new_payer {
            account.payer = new_payer?;
        }
        match saved.added.iter_mut().find(|a| a.id == id) {
            Some(added) => {
                added.name = account.name.clone();
                added.payer = account.payer.clone();
            }
            None => {
                saved.changed.insert(
                    id.clone(),
                    Change {
                        name: account.name.clone(),
                        payer: account.payer.clone(),
                    },
                );
            }
        }
        Ok((tool, account))
    })?;
    send_accounts(&shared).await;
    Ok(answer(
        StatusCode::OK,
        json_now(&shared, tool, account).await,
    ))
}

/// `DELETE /v1/accounts/{id}`: `204`. A sign-in under way ends first; then `409` while a job of
/// the account is queued or running. Its folder goes too when obid made it.
pub async fn remove(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    let home = shared.config.home.clone();
    find(&shared.config.agents.get(), &id).ok_or_else(|| no_account(&id))?;
    // One change of the account at a time: a sign-in can't start while it's removed. Looked up
    // again once held: it may have gone meanwhile.
    let lock = shared.sign_ins.lock_for(&id);
    let _held = lock.lock().await;
    let (_, account) = find(&shared.config.agents.get(), &id).ok_or_else(|| no_account(&id))?;
    if !shared.sign_ins.end(&id).await {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            format!(
                "{}'s sign-in didn't end within 5 seconds: try again in a moment.",
                account.name
            ),
        ));
    }
    let _changing = shared
        .jobs
        .begin_change(&id)
        .ok_or_else(|| busy(&account))?;
    let made = shared.config.agents.change(|agents, saved| {
        find(agents, &id).ok_or_else(|| no_account(&id))?;
        let made = match saved.added.iter().position(|a| a.id == id) {
            Some(at) => {
                let added = saved.added.remove(at);
                own_folder(&home, &id).filter(|own| added.config_dir == *own)
            }
            None => {
                saved.changed.remove(&id);
                saved.removed.push(id.clone());
                None
            }
        };
        Ok(made)
    })?;
    // Never through a link in the folder's place: only a real folder is removed, and what's in it
    // without following links.
    if let Some(dir) = made
        && std::fs::symlink_metadata(&dir).is_ok_and(|m| m.is_dir())
        && let Err(e) = std::fs::remove_dir_all(&dir)
    {
        tracing::warn!("account {id}: its folder {} stayed: {e}", dir.display());
    }
    // Nothing of obid's is kept for it any more. The tool's own login stays where the tool kept
    // it (on macOS, Claude Code's Keychain item) and with its provider.
    if let Some(dir) = &account.config_dir {
        crate::jobs::forget_kept(dir);
    }
    shared.sign_ins.forget(&id);
    tracing::info!("account {id}: removed");
    send_accounts(&shared).await;
    Ok(StatusCode::NO_CONTENT.into_response())
}

/// `DELETE /v1/accounts/{id}/sign-in`: ends the account's sign-in under way, if any, so an
/// abandoned one doesn't keep jobs off the account until it runs out. `204`.
pub async fn end_sign_in(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    let (_, account) = find(&shared.config.agents.get(), &id).ok_or_else(|| no_account(&id))?;
    if !shared.sign_ins.end(&id).await {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            format!(
                "{}'s sign-in didn't end within 5 seconds: try again in a moment.",
                account.name
            ),
        ));
    }
    Ok(StatusCode::NO_CONTENT.into_response())
}

fn busy(account: &Account) -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        format!(
            "{} has a job queued or running: stop it, or move it to another account, first.",
            account.name
        ),
    )
}

// ---------------------------------------------------------------------------------------------
// Signing in

/// The sign-ins under way, one per account at most.
#[derive(Default)]
pub struct SignIns {
    running: Mutex<HashMap<String, Arc<SignIn>>>,
    /// One change of an account at a time (a sign-in starting, the account removed).
    locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

/// One sign-in under way: the tool's own login, waiting for the person.
pub struct SignIn {
    account: String,
    url: String,
    /// Codex: the one-time code the person types on the page.
    user_code: Option<String>,
    /// Claude Code: the page shows a code the person pastes back (`POST`).
    paste: bool,
    expires: i64,
    /// The login's process group.
    group: Option<u32>,
    stdin: tokio::sync::Mutex<Option<tokio::process::ChildStdin>>,
    /// Whether it signed the account in, once it ended.
    ended: tokio::sync::watch::Receiver<Option<bool>>,
    cancel: tokio::sync::Notify,
}

impl SignIns {
    fn get(&self, id: &str) -> Option<Arc<SignIn>> {
        self.running().get(id).cloned()
    }

    fn running(&self) -> std::sync::MutexGuard<'_, HashMap<String, Arc<SignIn>>> {
        self.running.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The lock for changing the account `id` (one that exists: at most one per account obid had).
    fn lock_for(&self, id: &str) -> Arc<tokio::sync::Mutex<()>> {
        self.locks
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(id.to_owned())
            .or_default()
            .clone()
    }

    /// Ends the account's sign-in, if one is under way, and waits until it has: false when it
    /// hadn't within 5 seconds.
    async fn end(&self, id: &str) -> bool {
        let Some(sign_in) = self.get(id) else {
            return true;
        };
        sign_in.cancel.notify_one();
        let mut ended = sign_in.ended.clone();
        tokio::time::timeout(Duration::from_secs(5), ended.wait_for(Option::is_some))
            .await
            .is_ok()
    }

    /// Forgets the account's lock (the account is gone).
    fn forget(&self, id: &str) {
        self.locks
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(id);
    }

    /// Kills every sign-in's whole process group (obid is stopping).
    pub fn kill_all(&self) {
        for sign_in in self.running().values() {
            if let Some(group) = sign_in.group {
                crate::process::signal_group(group, nix::sys::signal::Signal::SIGKILL);
            }
        }
    }
}

impl SignIn {
    fn to_json(&self) -> Value {
        json!({"account": self.account, "url": self.url, "userCode": self.user_code,
               "pasteCode": self.paste, "expiresAt": obi_protocol::time::format(self.expires)})
    }
}

/// Removes the folders sign-ins left in `home/tmp` when obid stopped before they ended.
pub fn sweep(home: &Path) {
    let Ok(entries) = std::fs::read_dir(home.join("tmp")) else {
        return;
    };
    for entry in entries.flatten() {
        if entry
            .file_name()
            .to_string_lossy()
            .starts_with(SCRATCH_PREFIX)
            && entry.file_type().is_ok_and(|t| t.is_dir())
        {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

/// `GET /v1/accounts/{id}/sign-in`: the account's sign-in under way, or a new one: the tool's own
/// login in the account's folder, and what the person needs from it (`url`, `userCode`,
/// `pasteCode`).
pub async fn sign_in(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    find(&shared.config.agents.get(), &id).ok_or_else(|| no_account(&id))?;
    // One change of the account at a time; looked up again once held (it may have been removed).
    let lock = shared.sign_ins.lock_for(&id);
    let _held = lock.lock().await;
    let agents = shared.config.agents.get();
    let (tool, account) = find(&agents, &id).ok_or_else(|| no_account(&id))?;
    if let Some(sign_in) = shared.sign_ins.get(&id) {
        return Ok(answer(StatusCode::OK, sign_in.to_json()));
    }
    let conflict = |message: String| Err(ApiError::new(StatusCode::CONFLICT, message));
    let Some(dir) = account.config_dir.clone() else {
        return conflict(format!(
            "{} is {}'s own login, the person's: obid signs in only accounts with a folder of their own. Sign in with {} itself on this machine.",
            account.name,
            tool.name(),
            tool.name()
        ));
    };
    let home = &shared.config.home;
    if [home.join("worktrees"), home.join("clones")]
        .iter()
        .any(|root| inside(&dir, root))
    {
        return conflict(format!(
            "{}'s folder is inside obid's worktrees or clones, which jobs write: obid never signs it in there.",
            account.name
        ));
    }
    if tool == Tool::Claude && cfg!(target_os = "macos") && !crate::jobs::keychain_on() {
        return conflict("On macOS Claude Code keeps its login in the Keychain, which obid uses only with claudeKeychain on in its configuration.".into());
    }
    let bin = agent_of(&agents, tool)
        .as_ref()
        .and_then(|agent| crate::process::resolve_bin(&agent.bin))
        .filter(|bin| bin.is_absolute())
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                format!(
                    "obid can't find {}'s binary by an absolute path, which is how it runs a sign-in.",
                    tool.name()
                ),
            )
        })?;
    let changing = shared
        .jobs
        .begin_change(&id)
        .ok_or_else(|| busy(&account))?;
    let sign_in = start(&shared, tool, &account, &bin, &dir, changing)
        .await
        .map_err(|why| ApiError::new(StatusCode::BAD_GATEWAY, why))?;
    Ok(answer(StatusCode::OK, sign_in.to_json()))
}

/// Whether `path` is `root` or inside it, as written or with links resolved (the part that
/// exists), letter case aside as macOS compares names.
fn inside(path: &Path, root: &Path) -> bool {
    let forms = |path: &Path| {
        let mut existing = path.to_path_buf();
        let mut rest = Vec::new();
        let real = loop {
            if let Ok(real) = std::fs::canonicalize(&existing) {
                break rest.iter().rev().fold(real, |p: PathBuf, n| p.join(n));
            }
            match (
                existing.file_name().map(|n| n.to_owned()),
                existing.parent(),
            ) {
                (Some(name), Some(parent)) => {
                    rest.push(name);
                    existing = parent.to_path_buf();
                }
                _ => break path.to_path_buf(),
            }
        };
        [path.to_path_buf(), real].map(|p| PathBuf::from(p.to_string_lossy().to_lowercase()))
    };
    let (paths, roots) = (forms(path), forms(root));
    paths.iter().any(|p| roots.iter().any(|r| p.starts_with(r)))
}

/// `POST /v1/accounts/{id}/sign-in` with `{"code": "…"}`: the code the page showed, to the login
/// waiting for it (Claude Code's). The Account once it's signed in.
pub async fn sign_in_code(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let (tool, account) = find(&shared.config.agents.get(), &id).ok_or_else(|| no_account(&id))?;
    let map = object(&body, &["code"], "{\"code\": \"…\"}")?;
    let code = text_field(&map, "code")?.unwrap_or_default().trim();
    if code.is_empty() || code.len() > 4096 || code.chars().any(char::is_control) {
        return Err(unprocessable(
            "code is the one line the sign-in page showed.",
        ));
    }
    let conflict = |message: String| ApiError::new(StatusCode::CONFLICT, message);
    let sign_in = shared.sign_ins.get(&id).ok_or_else(|| {
        conflict(format!(
            "There's no sign-in under way for {}: start one first.",
            account.name
        ))
    })?;
    if !sign_in.paste {
        return Err(conflict(format!(
            "{}'s sign-in takes no code: it ends by itself once you've signed in in the browser.",
            tool.name()
        )));
    }
    let mut ended = sign_in.ended.clone();
    {
        use tokio::io::AsyncWriteExt;
        let mut stdin = sign_in.stdin.lock().await;
        let mut pipe = stdin
            .take()
            .ok_or_else(|| conflict("A code went to this sign-in already.".into()))?;
        let line = format!("{code}\n");
        if pipe.write_all(line.as_bytes()).await.is_err() || pipe.flush().await.is_err() {
            return Err(conflict(format!(
                "{}'s sign-in has ended: start again.",
                tool.name()
            )));
        }
    }
    let signed = tokio::time::timeout(CODE_WITHIN, ended.wait_for(Option::is_some))
        .await
        .ok()
        .and_then(|r| r.ok().and_then(|e| *e));
    match signed {
        Some(true) => {
            let account = find(&shared.config.agents.get(), &id)
                .map(|(_, a)| a)
                .unwrap_or(account);
            Ok(answer(
                StatusCode::OK,
                json_now(&shared, tool, account).await,
            ))
        }
        Some(false) => Err(unprocessable(format!(
            "{} didn't sign in with that code. Start again for a new link.",
            tool.name()
        ))),
        None => Err(ApiError::new(
            StatusCode::GATEWAY_TIMEOUT,
            format!(
                "{} didn't finish signing in within {} seconds.",
                tool.name(),
                CODE_WITHIN.as_secs()
            ),
        )),
    }
}

/// Starts the tool's own login in the account's folder `dir` and waits for its link. No box ever
/// gets that folder (#655), so nothing a job wrote there steers the login, and the login writes
/// its sign-in where the tool keeps it, read by nobody but the tool itself and the copies obid
/// makes for its boxed runs:
///
/// - Claude Code: `claude auth login` with `CLAUDE_CONFIG_DIR` the account's folder (on macOS its
///   login then goes to that folder's Keychain item). With no terminal it prints a link whose page
///   shows a code to paste back on its stdin.
/// - Codex: `codex login --device-auth`, its login kept in a file, with `CODEX_HOME` and `HOME` the
///   account's folder: a link and a one-time code to type there; it ends by itself.
/// - Cursor: `cursor-agent login` with the account's folders and its login kept in a file, its
///   `cli-config.json` rewritten first ([`crate::acp::cursor::rewrite_config`]); it ends by itself.
///
/// `changing` keeps jobs off the account until the login ends.
async fn start(
    shared: &Arc<Shared>,
    tool: Tool,
    account: &Account,
    bin: &Path,
    dir: &Path,
    changing: crate::jobs::Changing,
) -> Result<Arc<SignIn>, String> {
    crate::jobs::not_a_link(dir)?;
    crate::store::make_private_dir(dir)
        .map_err(|e| format!("obid can't make the account's folder: {e}"))?;
    static RUNS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = RUNS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let scratch = shared
        .config
        .home
        .join("tmp")
        .join(format!("{SCRATCH_PREFIX}{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    make_folder(&scratch).map_err(|e| format!("obid can't make a folder for the sign-in: {e}"))?;
    let child = command(tool, bin, dir, &scratch).and_then(|mut c| {
        c.spawn()
            .map_err(|e| format!("obid couldn't start {}'s sign-in: {e}", tool.name()))
    });
    let mut child = match child {
        Ok(child) => child,
        Err(why) => {
            let _ = std::fs::remove_dir_all(&scratch);
            return Err(why);
        }
    };
    let group = child.id();
    // Until the sign-in is registered, a request that ends (the app gone, obid stopping) takes
    // the login and its folder with it.
    let mut pending = Pending {
        group,
        scratch: scratch.clone(),
        armed: true,
    };
    let kill = move || {
        if let Some(group) = group {
            crate::process::signal_group(group, nix::sys::signal::Signal::SIGKILL);
        }
    };
    // What it prints, a line at a time (at most [`LONGEST_LINE`] of each), read until it ends:
    // only the link and the code are taken.
    let (lines, mut said) = tokio::sync::mpsc::unbounded_channel::<String>();
    for out in [
        child
            .stdout
            .take()
            .map(|o| Box::new(o) as Box<dyn tokio::io::AsyncRead + Unpin + Send>),
        child
            .stderr
            .take()
            .map(|e| Box::new(e) as Box<dyn tokio::io::AsyncRead + Unpin + Send>),
    ]
    .into_iter()
    .flatten()
    {
        tokio::spawn(read_lines(out, lines.clone()));
    }
    drop(lines);
    let wanted = async {
        let (mut url, mut code) = (None, None);
        while let Some(line) = said.recv().await {
            let line = plain(&line);
            url = url.or_else(|| link(tool, &line));
            if tool == Tool::Codex && url.is_some() {
                code = code.or_else(|| user_code(&line));
            }
            if url.is_some() && (tool != Tool::Codex || code.is_some()) {
                return Some((url?, code));
            }
        }
        None
    };
    let found = tokio::time::timeout(LINK_WITHIN, wanted).await;
    let (url, user_code) = match found {
        Ok(Some(found)) => found,
        _ => {
            kill();
            let _ = child.wait().await;
            let _ = std::fs::remove_dir_all(&scratch);
            return Err(format!(
                "{}'s sign-in didn't give a link to open.",
                tool.name()
            ));
        }
    };
    // The rest of what it prints is read and dropped.
    tokio::spawn(async move { while said.recv().await.is_some() {} });
    let (ended_tx, ended) = tokio::sync::watch::channel(None);
    let sign_in = Arc::new(SignIn {
        account: account.id.clone(),
        url,
        user_code,
        paste: tool == Tool::Claude,
        expires: obi_protocol::time::now() + SIGN_IN_LASTS.as_secs() as i64,
        group,
        stdin: tokio::sync::Mutex::new(child.stdin.take()),
        ended,
        cancel: tokio::sync::Notify::new(),
    });
    shared
        .sign_ins
        .running()
        .insert(account.id.clone(), sign_in.clone());
    // From here the sign-in's own task ends it.
    pending.armed = false;
    tracing::info!("account {}: {} sign-in started", account.id, tool.id());
    let (shared, watched, account) = (shared.clone(), sign_in.clone(), account.clone());
    tokio::spawn(async move {
        let exited = tokio::select! {
            status = child.wait() => status.ok(),
            () = tokio::time::sleep(SIGN_IN_LASTS) => None,
            () = watched.cancel.notified() => None,
        };
        // Whatever it started goes with it.
        kill();
        if exited.is_none() {
            let _ = child.wait().await;
        }
        let _ = std::fs::remove_dir_all(&scratch);
        let signed = match exited {
            Some(status) if status.success() => {
                let account = account.clone();
                tokio::task::spawn_blocking(move || {
                    crate::jobs::signed_in(tool, &account, crate::jobs::login_home().as_deref())
                })
                .await
                .unwrap_or(false)
            }
            _ => false,
        };
        {
            let mut running = shared.sign_ins.running();
            if running
                .get(&account.id)
                .is_some_and(|s| Arc::ptr_eq(s, &watched))
            {
                running.remove(&account.id);
            }
        }
        drop(changing);
        let _ = ended_tx.send(Some(signed));
        if signed {
            tracing::info!("account {}: signed in", account.id);
        } else {
            tracing::info!("account {}: sign-in ended without signing in", account.id);
        }
        send_accounts(&shared).await;
    });
    Ok(sign_in)
}

/// A login started and not yet registered as a sign-in: dropped armed (its request ended), its
/// whole process group is killed and its folder removed.
struct Pending {
    group: Option<u32>,
    scratch: PathBuf,
    armed: bool,
}

impl Drop for Pending {
    fn drop(&mut self) {
        if self.armed {
            if let Some(group) = self.group {
                crate::process::signal_group(group, nix::sys::signal::Signal::SIGKILL);
            }
            let _ = std::fs::remove_dir_all(&self.scratch);
        }
    }
}

/// Reads `out` a line at a time, each cut to [`LONGEST_LINE`] bytes, into `lines`, until it ends.
async fn read_lines(
    mut out: Box<dyn tokio::io::AsyncRead + Unpin + Send>,
    lines: tokio::sync::mpsc::UnboundedSender<String>,
) {
    use tokio::io::AsyncReadExt;
    let mut buffer = [0u8; 4096];
    let mut line = Vec::new();
    while let Ok(n) = out.read(&mut buffer).await {
        if n == 0 {
            break;
        }
        for byte in &buffer[..n] {
            if *byte == b'\n' {
                let _ = lines.send(String::from_utf8_lossy(&line).into_owned());
                line.clear();
            } else if line.len() < LONGEST_LINE {
                line.push(*byte);
            }
        }
    }
    if !line.is_empty() {
        let _ = lines.send(String::from_utf8_lossy(&line).into_owned());
    }
}

/// The tool's login command for the account's folder `dir`: its environment made from scratch (no
/// token, no Claude Code or Anthropic variable), a `PATH` of the system's folders and the tool's
/// own, run by its absolute path from `scratch` (its temporary folder, and Cursor's caches), no
/// browser opened on this machine, nothing printed to a terminal, in a process group of its own.
fn command(
    tool: Tool,
    bin: &Path,
    dir: &Path,
    scratch: &Path,
) -> Result<tokio::process::Command, String> {
    let mut command = tokio::process::Command::new(bin);
    command
        .env_clear()
        .envs(crate::process::kept(|name| std::env::var_os(name)))
        .env("PATH", login_path(bin))
        .env("TMPDIR", scratch)
        .env("BROWSER", "true")
        .current_dir(scratch)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .process_group(0);
    match tool {
        Tool::Claude => {
            let home = crate::jobs::login_home()
                .ok_or("obid can't find the person's home for Claude Code's sign-in.")?;
            command
                .args(["auth", "login"])
                .env("HOME", home)
                .env("CLAUDE_CONFIG_DIR", dir);
        }
        Tool::Codex => {
            command
                .args([
                    "login",
                    "--device-auth",
                    "-c",
                    r#"cli_auth_credentials_store="file""#,
                ])
                .env("HOME", dir)
                .env("CODEX_HOME", dir);
        }
        Tool::Cursor => {
            crate::acp::cursor::rewrite_config(dir)
                .map_err(|e| format!("obid can't write Cursor's settings for the sign-in: {e}"))?;
            command
                .arg("login")
                .envs(crate::acp::cursor::environment(dir))
                .env("NO_OPEN_BROWSER", "1")
                .env("NODE_COMPILE_CACHE", scratch)
                .env("XDG_CACHE_HOME", scratch);
        }
    }
    Ok(command)
}

/// [`SYSTEM_PATH`], then the folder the tool's binary is in (links followed: Cursor's runs the
/// `node` beside it), then, for a script that starts `#!/usr/bin/env <program>` (a CLI installed
/// with npm: `#!/usr/bin/env node`), the folder of that program as obid finds it.
fn login_path(bin: &Path) -> String {
    let real = std::fs::canonicalize(bin).ok();
    let mut path = SYSTEM_PATH.to_owned();
    let mut add = |dir: Option<&Path>| {
        if let Some(dir) = dir.and_then(|d| d.to_str())
            && !path.split(':').any(|p| p == dir)
        {
            path.push(':');
            path.push_str(dir);
        }
    };
    add(real.as_deref().and_then(Path::parent));
    let program = real.as_deref().and_then(interpreter);
    let found = program.as_deref().and_then(crate::process::resolve_bin);
    add(found
        .as_deref()
        .filter(|p| p.is_absolute())
        .and_then(Path::parent));
    path
}

/// The program a script names on its first line as `#!/usr/bin/env [-S] <program> …`.
fn interpreter(script: &Path) -> Option<String> {
    use std::io::Read;
    let mut head = [0u8; 256];
    let n = std::fs::File::open(script).ok()?.read(&mut head).ok()?;
    let line = std::str::from_utf8(&head[..n]).ok()?.lines().next()?;
    let mut words = line.strip_prefix("#!")?.split_whitespace();
    if words.next()? != "/usr/bin/env" {
        return None;
    }
    let program = words.find(|w| !w.starts_with('-'))?;
    (!program.contains('/') && !program.contains('=')).then(|| program.to_owned())
}

/// `line` without terminal colours and around spaces.
fn plain(line: &str) -> String {
    static ESCAPES: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    ESCAPES
        .get_or_init(|| regex::Regex::new(r"\x1b\[[0-9;?]*[ -/]*[@-~]").expect("a valid pattern"))
        .replace_all(line, "")
        .trim()
        .to_owned()
}

/// The sites each tool's sign-in page is on.
fn sites(tool: Tool) -> &'static [&'static str] {
    match tool {
        Tool::Claude => &["claude.com", "claude.ai", "anthropic.com"],
        Tool::Codex => &["openai.com", "chatgpt.com"],
        Tool::Cursor => &["cursor.com", "cursor.sh"],
    }
}

/// The first `https://` link in `line` on one of the tool's own sites (the site or below it), as
/// it is: no login in it, no space, at most 4,096 characters.
fn link(tool: Tool, line: &str) -> Option<String> {
    let at = line.find("https://")?;
    let url: &str = line[at..].split_whitespace().next()?;
    let rest = &url["https://".len()..];
    let authority = &rest[..rest.find(['/', '?', '#']).unwrap_or(rest.len())];
    let host = authority.to_ascii_lowercase();
    let fine = url.len() <= 4096
        && !host.contains(['@', ':', '\\'])
        && sites(tool)
            .iter()
            .any(|site| host == *site || host.ends_with(&format!(".{site}")))
        && url.chars().all(|c| c.is_ascii_graphic());
    fine.then(|| url.to_owned())
}

/// Codex's one-time code, a line of its own like `3U0G-DCVSU`.
fn user_code(line: &str) -> Option<String> {
    static CODE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    CODE.get_or_init(|| {
        regex::Regex::new(r"^[A-Z0-9]{4,8}(-[A-Z0-9]{4,8})+$").expect("a valid pattern")
    })
    .is_match(line)
    .then(|| line.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    /// The environment variables a sign-in's command names.
    fn env_of(command: &tokio::process::Command) -> HashMap<String, Option<OsString>> {
        command
            .as_std()
            .get_envs()
            .map(|(k, v)| (k.to_string_lossy().into_owned(), v.map(|v| v.to_owned())))
            .collect()
    }

    fn account(id: &str, name: &str, dir: Option<&str>) -> Account {
        Account {
            id: id.into(),
            name: name.into(),
            payer: None,
            config_dir: dir.map(PathBuf::from),
        }
    }

    fn agents(claude: Option<Vec<Account>>) -> Agents {
        Agents {
            claude: claude.map(|accounts| Agent {
                bin: "claude".into(),
                accounts,
            }),
            codex: None,
            cursor: None,
        }
    }

    fn added(id: &str, agent: &str) -> Added {
        Added {
            id: id.into(),
            agent: agent.into(),
            name: format!("Name {id}"),
            payer: Some("Deskree".into()),
            config_dir: PathBuf::from(format!("/srv/obid/accounts/{id}")),
        }
    }

    fn ids(agents: &Agents) -> Vec<String> {
        agents
            .claude
            .iter()
            .flat_map(|a| a.accounts.iter().map(|a| a.id.clone()))
            .collect()
    }

    #[test]
    fn whats_saved_is_laid_over_the_configuration() {
        let seed = agents(Some(vec![
            account("default", "Default", None),
            account("work", "Work", Some("/srv/work")),
        ]));
        let saved = Saved {
            added: vec![added("a1b2c3d4", "codex"), added("work", "claude")],
            changed: BTreeMap::from([(
                "default".into(),
                Change {
                    name: "Personal".into(),
                    payer: Some("Wellington".into()),
                },
            )]),
            removed: vec!["work".into()],
        };
        let agents = merged(&seed, &saved);
        let claude = agents.claude.unwrap().accounts;
        // Renamed, the removed one gone, and an added id the configuration has is left out.
        assert_eq!(claude.len(), 1);
        assert_eq!(claude[0].name, "Personal");
        assert_eq!(claude[0].payer.as_deref(), Some("Wellington"));
        // A tool the configuration doesn't name is there with its default binary.
        let codex = agents.codex.unwrap();
        assert_eq!(codex.bin, "codex");
        assert_eq!(codex.accounts[0].id, "a1b2c3d4");
        assert!(agents.cursor.is_none());
    }

    #[test]
    fn an_empty_list_keeps_the_tools_own_login_beside_what_is_added() {
        let seed = agents(Some(Vec::new()));
        let saved = Saved {
            added: vec![added("a1b2c3d4", "claude")],
            ..Saved::default()
        };
        assert_eq!(ids(&merged(&seed, &saved)), ["default", "a1b2c3d4"]);
        // Nothing added: nothing changes.
        assert_eq!(merged(&seed, &Saved::default()), seed);
    }

    /// Removing a tool's last account takes the tool away: it never comes back on its own default
    /// login, the person's, which an empty list would otherwise mean.
    #[test]
    fn the_last_account_removed_never_brings_the_default_login_back() {
        let empty = agents(Some(Vec::new()));
        let saved = Saved {
            removed: vec!["default".into()],
            ..Saved::default()
        };
        assert!(merged(&empty, &saved).claude.is_none());
        let saved = Saved {
            added: vec![added("a1b2c3d4", "claude")],
            removed: vec!["default".into()],
            ..Saved::default()
        };
        assert_eq!(ids(&merged(&empty, &saved)), ["a1b2c3d4"]);
        let listed = agents(Some(vec![account("work", "Work", Some("/srv/w"))]));
        let saved = Saved {
            removed: vec!["work".into()],
            ..Saved::default()
        };
        assert!(merged(&listed, &saved).claude.is_none());
    }

    #[test]
    fn a_change_is_kept_before_it_is_used() {
        let home = std::env::temp_dir().join(format!("obid-accounts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let seed = || {
            agents(Some(vec![
                account("work", "Work", Some("/srv/w")),
                account("more", "More", Some("/srv/m")),
            ]))
        };
        let live = Live::new(seed());
        live.open(&home);
        let copy = live.clone();
        live.change(|_, saved| {
            saved.removed.push("work".into());
            Ok(())
        })
        .unwrap_or_else(|e| panic!("{}", e.message));
        // Every copy sees it, and so does the next start.
        assert_eq!(ids(&copy.get()), ["more"]);
        let next = Live::new(seed());
        next.open(&home);
        assert_eq!(ids(&next.get()), ["more"]);
        // A file that doesn't read changes nothing, and nothing is changed over it.
        std::fs::write(home.join(FILE), "{").unwrap();
        let broken = Live::new(seed());
        broken.open(&home);
        assert_eq!(ids(&broken.get()), ["work", "more"]);
        let refused = broken.change(|_, _| Ok(())).err().unwrap();
        assert_eq!(refused.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(std::fs::read(home.join(FILE)).unwrap(), b"{");
        let _ = std::fs::remove_dir_all(&home);
    }

    /// What `home/accounts.json` holds is checked as the API checks it: an entry the API would
    /// refuse is left out, the rest kept.
    #[test]
    fn a_wrong_entry_in_the_file_is_left_out() {
        let home = std::env::temp_dir().join(format!("obid-accounts-bad-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let own = |id: &str| home.join("accounts").join(id);
        let entry = |id: &str, agent: &str, name: &str, dir: PathBuf| json!({"id": id, "agent": agent, "name": name, "configDir": dir});
        let file = json!({
            "added": [
                entry("a1b2c3d4", "claude", "Good", own("a1b2c3d4")),
                entry("b1b2c3d4", "claude", "Elsewhere", PathBuf::from("/Users/someone/.claude")),
                entry("../../x", "claude", "Traversal", own("../../x")),
                entry("c1b2c3d4", "gemini", "Tool", own("c1b2c3d4")),
                entry("d1b2c3d4", "claude", "two\nlines", own("d1b2c3d4")),
                entry("e1b2c3d4", "claude", "good", own("e1b2c3d4")),
                entry("work", "claude", "Seeded", own("work")),
                entry("A1B2C3D4", "claude", "Upper", own("A1B2C3D4")),
            ],
            "changed": {"work": {"name": ""}, "more": {"name": "Renamed", "payer": "x\u{7}"},
                        "other": {"name": "WORK"}},
            "removed": []
        });
        std::fs::write(home.join(FILE), file.to_string()).unwrap();
        let live = Live::new(agents(Some(vec![
            account("work", "Work", Some("/srv/w")),
            account("other", "Other", Some("/srv/o")),
        ])));
        live.open(&home);
        assert_eq!(ids(&live.get()), ["work", "other", "a1b2c3d4"]);
        let accounts = live.get().claude.unwrap().accounts;
        assert_eq!(accounts[0].name, "Work");
        // A change to a name another account has ("Work", letter case aside) is left out.
        assert_eq!(accounts[1].name, "Other");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn only_the_tools_own_sign_in_link_is_taken() {
        let claude = "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=x";
        assert_eq!(
            link(Tool::Claude, claude).as_deref(),
            Some("https://claude.com/cai/oauth/authorize?code=true&state=x")
        );
        assert_eq!(
            link(
                Tool::Codex,
                &plain("   \x1b[94mhttps://auth.openai.com/codex/device\x1b[0m")
            )
            .as_deref(),
            Some("https://auth.openai.com/codex/device")
        );
        for (tool, line) in [
            (Tool::Claude, "visit: https://evil.example/claude.com"),
            (Tool::Claude, "visit: https://claude.com@evil.example/x"),
            (Tool::Claude, "visit: https://claude.com.evil.example/x"),
            (Tool::Claude, "visit: https://notclaude.com/x"),
            (Tool::Claude, "visit: https://claude.com:8443/x"),
            (Tool::Claude, "visit: http://claude.com/x"),
            (Tool::Codex, "https://claude.com/cai/oauth/authorize"),
            (Tool::Cursor, "nothing here"),
        ] {
            assert_eq!(link(tool, line), None, "{line}");
        }
        assert_eq!(
            link(
                Tool::Cursor,
                "navigate to this link: https://cursor.com/loginDeepControl?challenge=a"
            ),
            Some("https://cursor.com/loginDeepControl?challenge=a".into())
        );
        assert_eq!(user_code("3U0G-DCVSU").as_deref(), Some("3U0G-DCVSU"));
        assert_eq!(
            user_code("2. Enter this one-time code (expires in 15 minutes)"),
            None
        );
        assert_eq!(user_code("ABCD"), None);
    }

    /// A login runs in the account's own folder, which no box gets (#655), with a `PATH` of the
    /// system's folders and its own, no secret of obid's, and Cursor's caches in obid's folder.
    #[test]
    fn a_login_runs_in_the_accounts_folder_with_a_pinned_path() {
        let (dir, scratch) = (Path::new("/srv/acct"), Path::new("/srv/obid/tmp/s"));
        let claude = command(Tool::Claude, Path::new("/bin/claude"), dir, scratch).unwrap();
        let env = env_of(&claude);
        assert_eq!(env["CLAUDE_CONFIG_DIR"], Some(dir.into()));
        assert!(!env.contains_key("CLAUDE_SECURESTORAGE_CONFIG_DIR"));
        let codex = command(Tool::Codex, Path::new("/bin/codex"), dir, scratch).unwrap();
        let env = env_of(&codex);
        assert_eq!(env["CODEX_HOME"], Some(dir.into()));
        assert_eq!(env["HOME"], Some(dir.into()));
        for command in [&claude, &codex] {
            let env = env_of(command);
            assert!(
                env["PATH"]
                    .as_ref()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with(SYSTEM_PATH)
            );
            assert!(
                command
                    .as_std()
                    .get_envs()
                    .all(|(k, _)| !crate::process::is_forbidden(&k.to_string_lossy()))
            );
            assert_eq!(command.as_std().get_current_dir(), Some(scratch));
        }
        assert_eq!(login_path(Path::new("/nowhere/claude")), SYSTEM_PATH);
    }

    /// A login whose request ended before its link (the app gone, obid stopping) is killed with
    /// everything it started, and its folder removed.
    #[test]
    fn a_login_its_request_dropped_ends_with_everything_it_started() {
        use std::os::unix::process::CommandExt;
        let root = std::env::temp_dir().join(format!("obid-pending-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let pids = root.join("pids");
        let mut child = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!(
                "sleep 300 & echo $$ $! > '{}'; wait",
                pids.display()
            ))
            .process_group(0)
            .spawn()
            .unwrap();
        let said = loop {
            if let Ok(text) = std::fs::read_to_string(&pids)
                && text.ends_with('\n')
            {
                break text;
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        drop(Pending {
            group: Some(child.id()),
            scratch: root.clone(),
            armed: true,
        });
        let _ = child.wait();
        assert!(!root.exists());
        for pid in said.split_whitespace() {
            let pid = nix::unistd::Pid::from_raw(pid.parse().unwrap());
            let gone = (0..100).any(|_| {
                std::thread::sleep(Duration::from_millis(20));
                nix::sys::signal::kill(pid, None).is_err()
            });
            assert!(gone, "{pid} outlived its login");
        }
    }

    /// A CLI installed with npm is a `#!/usr/bin/env node` script: node's folder joins its PATH.
    #[test]
    fn an_npm_scripts_interpreter_is_on_its_path() {
        let root = std::env::temp_dir().join(format!("obid-npm-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let script = root.join("codex.js");
        std::fs::write(&script, "#!/usr/bin/env node\nconsole.log(1)\n").unwrap();
        assert_eq!(interpreter(&script).as_deref(), Some("node"));
        std::fs::write(&script, "#!/usr/bin/env -S node --no-warnings\n").unwrap();
        assert_eq!(interpreter(&script).as_deref(), Some("node"));
        std::fs::write(&script, "#!/bin/sh\n").unwrap();
        assert_eq!(interpreter(&script), None);
        std::fs::write(&script, "#!/usr/bin/env node\n").unwrap();
        if let Some(node) = crate::process::resolve_bin("node") {
            let path = login_path(&script);
            assert!(path.starts_with(SYSTEM_PATH), "{path}");
            assert!(
                path.split(':')
                    .any(|p| Path::new(p) == node.parent().unwrap()),
                "{path}"
            );
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn names_and_payers_are_checked() {
        let agents = agents(Some(vec![account("work", "Work", Some("/srv/acct/work"))]));
        assert_eq!(
            name(&agents, Tool::Claude, " Personal ", None)
                .ok()
                .as_deref(),
            Some("Personal")
        );
        for bad in ["", "  ", "a\u{0}b", "Work", "WORK", "work"] {
            assert!(name(&agents, Tool::Claude, bad, None).is_err(), "{bad:?}");
        }
        // Its own name is its own; another tool's isn't taken.
        assert!(name(&agents, Tool::Claude, "Work", Some("work")).is_ok());
        assert!(name(&agents, Tool::Codex, "Work", None).is_ok());
        assert_eq!(payer(Some(&json!(" "))).ok(), Some(None));
        assert!(payer(Some(&json!(3))).is_err());
        let home = Path::new("/srv/obid");
        assert!(own_folder(home, "a1b2c3d4").is_some());
        assert!(own_folder(home, "../../x").is_none());
        assert!(own_folder(home, "A1B2C3D4").is_none());
    }
}
