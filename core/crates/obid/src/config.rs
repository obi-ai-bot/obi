//! obid's configuration file (docs/runner-api.md, "obid only: configuration").
//!
//! ```json
//! {"listen": "127.0.0.1:7811",
//!  "home": "/abs/path/obid-home",
//!  "owner": "wellington",
//!  "agents": {"claude": {"bin": "claude", "accounts": [{"id": "default", "name": "Default", "configDir": null}]},
//!             "codex": {"bin": "codex", "accounts": [{"id": "work", "name": "Work", "configDir": "/abs/path/codex-work"}]},
//!             "cursor": {"bin": "cursor-agent", "accounts": [{"id": "cursor", "name": "Cursor", "configDir": "/abs/path/cursor"}]}},
//!  "repos": [{"repo": "obi-e2e/fixture-app", "remote": "file:///abs/path/remote.git", "defaultBranch": "main", "check": "node --test"}],
//!  "allowFileRemotes": false,
//!  "bundledPlugins": "/abs/path/obi/plugins",
//!  "web": "/abs/path/obi/apps/web/dist",
//!  "telemetry": false}
//! ```
//!
//! A key the file doesn't know is refused, so a misspelled setting is an error rather than a
//! default nobody chose.

use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};

use serde::Deserialize;

/// Why a configuration file can't be used. Each reads as one line a person can act on.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("{path}: can't read it: {source}")]
    Read {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("{path}: isn't a valid configuration: {source}")]
    Parse {
        path: PathBuf,
        source: serde_json::Error,
    },
    #[error("{path}: {problem}")]
    Invalid { path: PathBuf, problem: String },
}

/// Where obid listens when the configuration doesn't say: on macOS, where the Mac app looks for
/// the runner on the same Mac (127.0.0.1:7777); elsewhere `listen` is required.
pub const DEFAULT_LISTEN: Option<&str> = if cfg!(target_os = "macos") {
    Some("127.0.0.1:7777")
} else {
    None
};

/// The file as written. Validated into [`Config`].
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct File {
    #[serde(default)]
    listen: Option<String>,
    home: PathBuf,
    owner: String,
    #[serde(default)]
    agents: Agents,
    #[serde(default)]
    repos: Vec<Repo>,
    #[serde(default)]
    allow_file_remotes: bool,
    #[serde(default)]
    bundled_plugins: Option<PathBuf>,
    #[serde(default)]
    web: Option<PathBuf>,
    #[serde(default)]
    telemetry: bool,
    /// How long one conversation turn may act, in seconds: 1 to 110, 110 when left out.
    #[serde(default)]
    turn_budget: Option<u64>,
    /// The least time a brain is asked to think in, in seconds: 1 to 110, 1 when left out. For
    /// tests, which widen it so a busy machine can't miss it.
    #[serde(default)]
    least_think: Option<u64>,
    orchestrator_delay: Option<u64>,
    /// How long a job may go without progress before it stalls, in seconds: 1 to 86,400, 900
    /// when left out.
    stall_after: Option<u64>,
    /// The safety ceiling of one run of a job, in hours: 1 to 168, 12 when left out.
    job_ceiling_hours: Option<u64>,
    /// The safety budget of a job, in tokens (cache reads left out): 1 to 10^10, 50 million when
    /// left out.
    job_token_budget: Option<u64>,
    /// Where the vault is (crate::vault): `{"store": "file"}` or `{"store": "keychain", "service":
    /// "…"}`; left out, [`crate::vault::Location::default_for`].
    #[serde(default)]
    vault: Option<VaultSetting>,
    /// Where the gateway listens (crate::gateway), on 127.0.0.1; left out, there's none.
    #[serde(default)]
    gateway: Option<String>,
    /// Whether obid copies Claude Code's login from the macOS Keychain (crate::jobs, keychain_login);
    /// left out, obid decides when it starts (crate::jobs::keychain_wanted).
    #[serde(default)]
    claude_keychain: Option<bool>,
    /// Sharing this Mac (crate::sphere::hosting): where `obi-vm` and the guest image are.
    #[serde(default)]
    vm_helper: Option<PathBuf>,
    #[serde(default)]
    vm_image: Option<PathBuf>,
    #[serde(default)]
    vm_image_url: Option<String>,
    /// The least seconds between two run_requests taken from one teammate's owner (900 when left
    /// out; 0 turns it off, for tests or an owner who wants that).
    #[serde(default)]
    guest_request_every: Option<i64>,
    /// Where a job run on another Mac sends its model calls from here (crate::sphere::guest):
    /// the providers' own APIs when it's left out. Tests point it at a stand-in.
    #[serde(default)]
    guest_model_api: Option<String>,
    /// How conversations run (crate::brain::harness): `{"agent", "model", "budget"}`.
    #[serde(default)]
    conversation: Option<ConversationSetting>,
}

/// `conversation` as written.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConversationSetting {
    /// `claude` (a Claude Code session, the default), `codex` (a Codex thread) or `plan` (obid's
    /// plan loop only).
    #[serde(default)]
    agent: Option<String>,
    /// The agent's model for conversations; left out, [`CONVERSATION_MODEL`] on Claude Code and
    /// Codex's own on Codex.
    #[serde(default)]
    model: Option<String>,
    /// How long one turn may take, in seconds: 10 to 3,600, 600 when left out.
    #[serde(default)]
    budget: Option<u64>,
}

/// The model a conversation's session talks with unless `conversation.model` says another.
pub const CONVERSATION_MODEL: &str = "claude-sonnet-5-5";

/// How conversations run (docs/runner-api.md, "obid only: the conversation harness").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conversation {
    /// True: each conversation is an agent session in its room (the default); false: obid's
    /// plan loop answers (`"agent": "plan"`).
    pub harness: bool,
    /// The session's agent: Claude Code (the default) or Codex.
    pub agent: crate::agent::Tool,
    /// Its model; empty for Codex's own.
    pub model: String,
    /// One turn's budget: 10 minutes unless `budget` says otherwise. Stop ends it sooner.
    pub budget: std::time::Duration,
}

/// `vault` as written.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct VaultSetting {
    store: String,
    #[serde(default)]
    service: Option<String>,
}

/// The agents' adapters, each the same shape: Claude Code (stream-json), Codex (`codex
/// app-server`) and Cursor (`cursor-agent acp`, the Agent Client Protocol).
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Agents {
    pub claude: Option<Agent>,
    pub codex: Option<Agent>,
    pub cursor: Option<Agent>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Agent {
    /// The adapter's binary: a path, or a command name found on the login shell's `PATH`.
    pub bin: String,
    #[serde(default)]
    pub accounts: Vec<Account>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Account {
    pub id: String,
    pub name: String,
    /// The account's own folder: `CLAUDE_CONFIG_DIR` for Claude Code, `CODEX_HOME` for Codex, and
    /// for Cursor its `CURSOR_CONFIG_DIR`, `HOME` and `XDG_CONFIG_HOME` (`<configDir>/.config`).
    /// Null for the tool's own default login (not for Cursor, whose accounts each need one).
    pub config_dir: Option<PathBuf>,
    /// Who pays for it, as the owner put it ("Deskree"), or none.
    #[serde(default)]
    pub payer: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Repo {
    /// `owner/name`.
    pub repo: String,
    /// An `https://` or ssh URL, or `file://` when `allowFileRemotes` is true.
    pub remote: String,
    #[serde(default = "default_branch")]
    pub default_branch: String,
    /// The one-line command that decides `tests_pass` and serves as the job's check.
    pub check: Option<String>,
    /// Whether its pushes get a pull request on GitHub (`gh`): by default only when `remote` is
    /// GitHub's (`crate::github::is_remote`).
    #[serde(default)]
    pub pull_requests: Option<bool>,
}

fn default_branch() -> String {
    "main".into()
}

/// A configuration obid can run with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// An address on 127.0.0.1: the only one obid binds.
    pub listen: SocketAddr,
    /// Everything obid keeps, and the only place it writes besides its `HOME` and `TMPDIR`.
    pub home: PathBuf,
    /// The owner's id, as their Sphere knows them.
    pub owner: String,
    /// The agents and their accounts as they are now: the configuration's, with what the API
    /// changed laid over them (crate::accounts). Every copy of the configuration shares them.
    pub agents: crate::accounts::Live,
    pub repos: Vec<Repo>,
    pub allow_file_remotes: bool,
    /// The plug-ins obid ships (`plugins/<id>`), installed into `home/plugins/<id>` at start when
    /// missing, disabled (docs/ARCHITECTURE.md 5.3, step 1): `bundledPlugins`, or when it is left
    /// out [`default_bundled_plugins`].
    pub bundled_plugins: PathBuf,
    /// The built web app (`apps/web/dist`) obid serves at `/app/` (crate::web): `web`, or when it
    /// is left out [`default_web`].
    pub web: PathBuf,
    /// False unless the owner turns it on; obid sends nothing to anyone otherwise.
    pub telemetry: bool,
    /// Where the owner's vault is (crate::vault).
    pub vault: crate::vault::Location,
    /// How long one conversation turn may plan and act (`Desk.turnBudget`): 110 seconds unless
    /// `turnBudget` says less, under the apps' 120-second wait.
    pub turn_budget: std::time::Duration,
    /// The least time a brain is asked to think in (#615): with less of the turn left, none is.
    /// [`crate::brain::planner::LEAST`] unless `leastThink` says otherwise, which only tests do.
    pub least_think: std::time::Duration,
    /// How long the event orchestrator waits for nearby events to come together before its
    /// turn (#590): 30 seconds unless `orchestratorDelay` says otherwise (1 to 600).
    pub orchestrator_delay: std::time::Duration,
    /// How long a job may go without progress before it stalls (docs/runner-api.md, `limit`): 15
    /// minutes unless `stallAfter` says otherwise.
    pub stall_after: std::time::Duration,
    /// The safety ceiling of one run of a job, against runaway cost only: 12 hours unless
    /// `jobCeilingHours` says otherwise.
    pub job_ceiling: std::time::Duration,
    /// The safety budget of a job, in tokens its tool counted, cache reads left out: 50 million
    /// unless `jobTokenBudget` says otherwise.
    pub job_token_budget: u64,
    /// Where paired phones reach obid (crate::gateway): `gateway`, an address on 127.0.0.1; none
    /// when it is left out.
    pub gateway: Option<SocketAddr>,
    /// `claudeKeychain`: obid copies Claude Code's macOS Keychain login into a boxed run's place
    /// for it (crate::jobs, keychain_login). `Some` as the owner set it; `None` when it's left out,
    /// and then obid turns it on by itself on macOS when Claude Code's default login is only in the
    /// Keychain (crate::jobs::keychain_wanted, the owner's decision of 2026-10-18).
    pub claude_keychain: Option<bool>,
    /// How conversations run.
    pub conversation: Conversation,
    /// `vmHelper` and `vmImage`: `obi-vm` and the guest image's folder, when not the defaults
    /// (crate::sphere::hosting::Setup).
    pub vm_helper: Option<PathBuf>,
    pub vm_image: Option<PathBuf>,
    /// `vmImageUrl`: where obid fetches the guest image from when sharing is turned on and it keeps
    /// the image itself (no `vmImage`); https://downloads.oby.deskree.com/vm when left out.
    pub vm_image_url: Option<String>,
    /// `guestRequestEvery`: the least seconds between two run_requests taken from one teammate's
    /// owner; 900 when left out, 0 for off (crate::sphere::hosting). Never negative.
    pub guest_request_every: Option<i64>,
    /// `guestModelApi`: the model API a guest job's calls go to from here, when not the providers'.
    pub guest_model_api: Option<String>,
}

/// Where the plug-ins obid ships are when the configuration doesn't say: the `plugins/` folder
/// of the repository this obid was built from (`core/crates/obid/../../../plugins`).
pub fn default_bundled_plugins() -> PathBuf {
    crate::app::resources()
        .map(|dir| dir.join("plugins"))
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../plugins"))
}

/// Where the built web app is when the configuration doesn't say: `apps/web/dist` in the
/// repository this obid was built from (`core/crates/obid/../../../apps/web/dist`).
pub fn default_web() -> PathBuf {
    crate::app::resources()
        .map(|dir| dir.join("web"))
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../apps/web/dist"))
}

impl Config {
    /// Reads and checks the file at `path`.
    pub fn load(path: &Path) -> Result<Config, ConfigError> {
        let text = std::fs::read_to_string(path).map_err(|source| ConfigError::Read {
            path: path.to_path_buf(),
            source,
        })?;
        Config::parse(&text).map_err(|e| match e {
            Problem::Parse(source) => ConfigError::Parse {
                path: path.to_path_buf(),
                source,
            },
            Problem::Invalid(problem) => ConfigError::Invalid {
                path: path.to_path_buf(),
                problem,
            },
        })
    }

    /// Checks a configuration given as JSON text.
    pub fn parse(text: &str) -> Result<Config, Problem> {
        let file: File = serde_json::from_str(text).map_err(Problem::Parse)?;
        let invalid = |problem: String| Err(Problem::Invalid(problem));

        let Some(listen_text) = file.listen.or_else(|| DEFAULT_LISTEN.map(str::to_owned)) else {
            return invalid(
                "listen is missing: give an address on 127.0.0.1 with a port, like 127.0.0.1:7811."
                    .into(),
            );
        };
        let listen: SocketAddr = match listen_text.parse() {
            Ok(address) => address,
            Err(_) => {
                return invalid(format!(
                    "listen is {listen_text:?}: it must be an address on 127.0.0.1 with a port, like 127.0.0.1:7811."
                ));
            }
        };
        if listen.ip() != Ipv4Addr::LOCALHOST {
            return invalid(format!(
                "listen is {listen_text:?}: obid binds only 127.0.0.1, like 127.0.0.1:7811."
            ));
        }
        if !file.home.is_absolute() {
            return invalid(format!(
                "home is {:?}: it must be an absolute path.",
                file.home
            ));
        }
        if file.owner.trim().is_empty() {
            return invalid(
                "owner is empty: it is the owner's id, as their Sphere knows them.".into(),
            );
        }
        // Account ids are unique across the tools: jobs and the apps name an account by its id.
        let mut seen = std::collections::HashSet::new();
        for (key, agent) in [
            ("claude", &file.agents.claude),
            ("codex", &file.agents.codex),
            ("cursor", &file.agents.cursor),
        ] {
            let Some(agent) = agent else { continue };
            if agent.bin.trim().is_empty() {
                return invalid(format!(
                    "agents.{key}.bin is empty: it is the adapter's binary, a path or a command name."
                ));
            }
            for account in &agent.accounts {
                if account.id.trim().is_empty() {
                    return invalid(format!(
                        "agents.{key}.accounts: an account has an empty id."
                    ));
                }
                if !seen.insert(account.id.as_str()) {
                    return invalid(format!(
                        "agents.{key}.accounts: the id {:?} is listed twice.",
                        account.id
                    ));
                }
                match &account.config_dir {
                    Some(dir) if !dir.is_absolute() => {
                        return invalid(format!(
                            "agents.{key}.accounts: {}'s configDir {dir:?} must be an absolute path.",
                            account.id
                        ));
                    }
                    Some(dir) if holds(dir, &file.home) => {
                        return invalid(format!(
                            "agents.{key}.accounts: {}'s configDir {dir:?} holds obid's home: every box would be hidden away with it.",
                            account.id
                        ));
                    }
                    Some(dir)
                        if holds(&file.home, dir)
                            && dir.parent() != Some(file.home.join("accounts").as_path()) =>
                    {
                        return invalid(format!(
                            "agents.{key}.accounts: {}'s configDir {dir:?} is inside obid's home but not a folder of home/accounts: obid's home holds its database, clones and the jobs' worktrees.",
                            account.id
                        ));
                    }
                    Some(dir) if key == "claude" && in_persons_folder(dir, ".claude") => {
                        return invalid(format!(
                            "agents.claude.accounts: {}'s configDir {dir:?} is the person's own ~/.claude or inside it: an account needs a folder of its own, and ~/.claude must stay the person's own login.",
                            account.id
                        ));
                    }
                    Some(dir) if key == "codex" && in_persons_folder(dir, ".codex") => {
                        return invalid(format!(
                            "agents.codex.accounts: {}'s configDir {dir:?} is the person's own ~/.codex or inside it: an account needs a folder of its own, and ~/.codex must stay the person's own login.",
                            account.id
                        ));
                    }
                    None if key == "cursor" => {
                        return invalid(format!(
                            "agents.cursor.accounts: {} has no configDir: each Cursor account needs a folder of its own, where its login lives.",
                            account.id
                        ));
                    }
                    _ => {}
                }
            }
        }
        let mut seen = std::collections::HashSet::new();
        for repo in &file.repos {
            if !is_repo_name(&repo.repo) {
                return invalid(format!("repos: {:?} isn't owner/name.", repo.repo));
            }
            if !seen.insert(repo.repo.as_str()) {
                return invalid(format!("repos: {:?} is listed twice.", repo.repo));
            }
            match remote_kind(&repo.remote) {
                Some(RemoteKind::File) if !file.allow_file_remotes => {
                    return invalid(format!(
                        "repos: {}'s remote is a file:// URL, which only allowFileRemotes: true allows.",
                        repo.repo
                    ));
                }
                Some(_) => {}
                None => {
                    return invalid(format!(
                        "repos: {}'s remote {:?} isn't an https://, ssh or file:// URL.",
                        repo.repo, repo.remote
                    ));
                }
            }
            if repo.default_branch.trim().is_empty() {
                return invalid(format!("repos: {}'s defaultBranch is empty.", repo.repo));
            }
        }
        if let Some(dir) = &file.bundled_plugins
            && !dir.is_absolute()
        {
            return invalid(format!(
                "bundledPlugins is {dir:?}: it must be an absolute path, the folder of the plug-ins obid ships."
            ));
        }
        if let Some(every) = file.guest_request_every
            && every < 0
        {
            return invalid(format!(
                "guestRequestEvery is {every}: it must be 0 (off) or more seconds."
            ));
        }
        if let Some(dir) = &file.web
            && !dir.is_absolute()
        {
            return invalid(format!(
                "web is {dir:?}: it must be an absolute path, the folder of the built web app (apps/web/dist)."
            ));
        }

        let vault = match &file.vault {
            None => crate::vault::Location::default_for(&file.home),
            Some(setting) => {
                match crate::vault::Location::parse(&setting.store, setting.service.as_deref()) {
                    Ok(location) => location,
                    Err(why) => return invalid(format!("vault: {why}")),
                }
            }
        };
        let turn_budget = file.turn_budget.unwrap_or(110);
        if !(1..=110).contains(&turn_budget) {
            return invalid(format!(
                "turnBudget is {turn_budget}: it is 1 to 110 seconds, under the apps' 120-second wait."
            ));
        }

        let gateway = match file.gateway.as_deref().map(str::parse::<SocketAddr>) {
            None => None,
            Some(Ok(address)) if address.ip() == Ipv4Addr::LOCALHOST => Some(address),
            Some(_) => {
                return invalid(format!(
                    "gateway is {:?}: it must be an address on 127.0.0.1 with a port, like 127.0.0.1:8810; put `tailscale serve` in front of it.",
                    file.gateway.unwrap_or_default()
                ));
            }
        };

        let least_think = match file.least_think {
            None => crate::brain::planner::LEAST,
            // Less than the whole budget: a turn no brain may ever think in is no turn.
            Some(least) if (1..turn_budget).contains(&least) => {
                std::time::Duration::from_secs(least)
            }
            Some(least) => {
                return invalid(format!(
                    "leastThink is {least}: it is 1 second to less than turnBudget ({turn_budget})."
                ));
            }
        };

        let orchestrator_delay = file.orchestrator_delay.unwrap_or(30);
        if !(1..=600).contains(&orchestrator_delay) {
            return invalid(format!(
                "orchestratorDelay is {orchestrator_delay}: it is 1 to 600 seconds."
            ));
        }

        let stall_after = file.stall_after.unwrap_or(15 * 60);
        if !(1..=86_400).contains(&stall_after) {
            return invalid(format!(
                "stallAfter is {stall_after}: it is 1 to 86400 seconds."
            ));
        }
        let job_ceiling_hours = file.job_ceiling_hours.unwrap_or(12);
        if !(1..=168).contains(&job_ceiling_hours) {
            return invalid(format!(
                "jobCeilingHours is {job_ceiling_hours}: it is 1 to 168 hours."
            ));
        }

        let job_token_budget = file.job_token_budget.unwrap_or(50_000_000);
        if !(1..=10_000_000_000).contains(&job_token_budget) {
            return invalid(format!(
                "jobTokenBudget is {job_token_budget}: it is 1 to 10000000000 tokens."
            ));
        }

        let setting = file.conversation.as_ref();
        use crate::agent::Tool;
        let (harness, agent) = match setting.and_then(|c| c.agent.as_deref()) {
            None | Some("claude") => (true, Tool::Claude),
            Some("codex") => (true, Tool::Codex),
            Some("plan") => (false, Tool::Claude),
            Some(other) => {
                return invalid(format!(
                    "conversation.agent is {other:?}: it is \"claude\", \"codex\" or \"plan\"."
                ));
            }
        };
        let model = match setting.and_then(|c| c.model.clone()) {
            Some(model) => model,
            // Codex's own model when none is named.
            None if agent == Tool::Codex => String::new(),
            None => CONVERSATION_MODEL.to_owned(),
        };
        let named = setting.is_some_and(|c| c.model.is_some()) || agent == Tool::Claude;
        if (named && model.is_empty())
            || model.starts_with('-')
            || model.len() > 64
            || !model
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-._[]".contains(&b))
        {
            return invalid(format!(
                "conversation.model is {model:?}: it is one of the agent's model names, like {CONVERSATION_MODEL}."
            ));
        }
        let budget = setting.and_then(|c| c.budget).unwrap_or(600);
        if !(10..=3600).contains(&budget) {
            return invalid(format!(
                "conversation.budget is {budget}: it is 10 to 3,600 seconds."
            ));
        }

        Ok(Config {
            listen,
            home: file.home,
            owner: file.owner,
            agents: crate::accounts::Live::new(file.agents),
            repos: file.repos,
            allow_file_remotes: file.allow_file_remotes,
            bundled_plugins: file.bundled_plugins.unwrap_or_else(default_bundled_plugins),
            web: file.web.unwrap_or_else(default_web),
            telemetry: file.telemetry,
            vault,
            turn_budget: std::time::Duration::from_secs(turn_budget),
            least_think,
            orchestrator_delay: std::time::Duration::from_secs(orchestrator_delay),
            stall_after: std::time::Duration::from_secs(stall_after),
            job_ceiling: std::time::Duration::from_secs(job_ceiling_hours * 3600),
            job_token_budget,
            gateway,
            claude_keychain: file.claude_keychain,
            vm_helper: file.vm_helper,
            vm_image: file.vm_image,
            vm_image_url: file.vm_image_url,
            guest_request_every: file.guest_request_every,
            guest_model_api: file.guest_model_api,
            conversation: Conversation {
                harness,
                agent,
                model,
                budget: std::time::Duration::from_secs(budget),
            },
        })
    }
}

/// Why a configuration text can't be used: it isn't the file's shape, or a value is wrong.
#[derive(Debug)]
pub enum Problem {
    Parse(serde_json::Error),
    Invalid(String),
}

impl std::fmt::Display for Problem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Problem::Parse(e) => write!(f, "isn't a valid configuration: {e}"),
            Problem::Invalid(problem) => f.write_str(problem),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum RemoteKind {
    Https,
    Ssh,
    File,
}

/// `https://host/…`, `ssh://…` or scp-like `user@host:path`, `file:///abs/path`; nothing else.
///
/// git hands a remote's user and host to ssh, and a remote to its own transports, so none of them
/// may read as a command-line option (`ssh://-oProxyCommand=…`, `-oProxyCommand=…@h:p`,
/// `https://-x/r`): a user or host that starts with `-` is refused, as are a remote that does,
/// control characters anywhere, and a host that isn't a host name, an IPv4 address or a bracketed
/// IPv6 one. git percent-decodes an `ssh://` or `https://` URL before it uses it, so
/// `ssh://%2DoProxyCommand=…@h/r` would reach ssh as `-oProxyCommand=…`: a `%` in the user or the
/// host is refused rather than decoded and checked again.
fn remote_kind(remote: &str) -> Option<RemoteKind> {
    if remote.starts_with('-') || remote.chars().any(char::is_control) {
        return None;
    }
    if let Some(rest) = remote.strip_prefix("https://") {
        return url_authority_ok(rest).then_some(RemoteKind::Https);
    }
    if let Some(rest) = remote.strip_prefix("ssh://") {
        return url_authority_ok(rest).then_some(RemoteKind::Ssh);
    }
    if let Some(rest) = remote.strip_prefix("file://") {
        return rest.starts_with('/').then_some(RemoteKind::File);
    }
    // scp-like: `git@github.com:owner/name.git`. No scheme, a user and host before the colon.
    // git reads a remote with a `/` before its first `:` as a local path, not ssh
    // (`/tmp/x@h:p`, `../srv/x@h:r.git`): that is refused here, or it would get round
    // `allowFileRemotes`. So is `\`, Windows' other separator.
    if !remote.contains("://")
        && let Some((user_host, path)) = remote.split_once(':')
    {
        if user_host.contains(['/', '\\']) {
            return None;
        }
        if let Some((user, host)) = user_host.split_once('@')
            && user_ok(user)
            && host_name_ok(host)
            && !path.is_empty()
            && !path.starts_with('-')
        {
            return Some(RemoteKind::Ssh);
        }
    }
    None
}

/// What follows `https://` or `ssh://`: `[user@]host[:port]`, then a path.
fn url_authority_ok(rest: &str) -> bool {
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host_port = match authority.rsplit_once('@') {
        Some((user, host_port)) => {
            if !user_ok(user) {
                return false;
            }
            host_port
        }
        None => authority,
    };
    host_port_ok(host_port)
}

/// A user name ssh can't take for an option: not empty, no leading `-`, no spaces, no `%`,
/// which git would decode into any of those, and no `/` or `\\`, which make git read an scp-like
/// remote as a local path.
fn user_ok(user: &str) -> bool {
    !user.is_empty()
        && !user.starts_with('-')
        && !user
            .chars()
            .any(|c| c.is_whitespace() || matches!(c, '@' | '%' | '/' | '\\'))
}

/// `host`, `host:port`, `[v6]` or `[v6]:port`.
fn host_port_ok(host_port: &str) -> bool {
    let port_ok =
        |port: &str| (1..=5).contains(&port.len()) && port.bytes().all(|b| b.is_ascii_digit());
    if let Some(rest) = host_port.strip_prefix('[') {
        let Some((inside, after)) = rest.split_once(']') else {
            return false;
        };
        let after_ok = after.is_empty() || after.strip_prefix(':').is_some_and(port_ok);
        return after_ok
            && !inside.is_empty()
            && inside
                .bytes()
                .all(|b| b.is_ascii_hexdigit() || b == b':' || b == b'.');
    }
    match host_port.split_once(':') {
        Some((host, port)) => host_name_ok(host) && port_ok(port),
        None => host_name_ok(host_port),
    }
}

/// A DNS name or IPv4 address: letters, digits, `-`, `_` and `.`, starting with a letter or digit.
fn host_name_ok(host: &str) -> bool {
    host.starts_with(|c: char| c.is_ascii_alphanumeric())
        && host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

fn is_repo_name(name: &str) -> bool {
    let ok = |part: &str| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    };
    matches!(name.split_once('/'), Some((owner, repo)) if ok(owner) && ok(repo))
}

/// Whether `dir` is the person's own `~/<folder>` (`.claude`, `.codex`: the default login's
/// folder) or inside it, in any of their homes, links resolved where they exist and letter case
/// ignored (macOS ignores it).
/// Whether `dir` is `inner` or holds it, as written or with links resolved, in lower case.
fn holds(dir: &std::path::Path, inner: &std::path::Path) -> bool {
    let forms = |path: &std::path::Path| {
        let real = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        [path.to_path_buf(), real]
            .map(|p| std::path::PathBuf::from(p.to_string_lossy().to_lowercase()))
    };
    let (dirs, inners) = (forms(dir), forms(inner));
    inners.iter().any(|i| dirs.iter().any(|d| i.starts_with(d)))
}

fn in_persons_folder(dir: &std::path::Path, folder: &str) -> bool {
    // As written and with links resolved, each in lower case.
    let forms = |path: &std::path::Path| {
        let real = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        [path.to_path_buf(), real]
            .map(|p| std::path::PathBuf::from(p.to_string_lossy().to_lowercase()))
    };
    let dirs = forms(dir);
    crate::jobs::person_homes().iter().any(|home| {
        let own = forms(&home.join(folder));
        dirs.iter().any(|d| own.iter().any(|c| d.starts_with(c)))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with(changes: serde_json::Value) -> String {
        let mut base = serde_json::json!({
            "listen": "127.0.0.1:7811",
            "home": "/srv/obid-home",
            "owner": "wellington",
            "agents": {"claude": {"bin": "claude", "accounts": [{"id": "default", "name": "Default", "configDir": null}]}},
            "repos": [{"repo": "obi-e2e/fixture-app", "remote": "https://github.com/obi-e2e/fixture-app.git", "defaultBranch": "main", "check": "node --test"}],
            "allowFileRemotes": false,
            "telemetry": false
        });
        for (key, value) in changes.as_object().unwrap() {
            if value.is_null() {
                base.as_object_mut().unwrap().remove(key);
            } else {
                base[key] = value.clone();
            }
        }
        base.to_string()
    }

    fn problem(text: &str) -> String {
        Config::parse(text).unwrap_err().to_string()
    }

    #[test]
    fn reads_the_documented_example() {
        let config = Config::parse(&with(serde_json::json!({}))).unwrap();
        assert_eq!(config.listen, "127.0.0.1:7811".parse().unwrap());
        assert_eq!(config.home, PathBuf::from("/srv/obid-home"));
        assert_eq!(config.owner, "wellington");
        let claude = config.agents.get().claude.unwrap();
        assert_eq!(claude.bin, "claude");
        assert_eq!(
            claude.accounts,
            vec![Account {
                id: "default".into(),
                name: "Default".into(),
                config_dir: None,
                payer: None,
            }]
        );
        assert_eq!(config.repos[0].check.as_deref(), Some("node --test"));
        assert!(!config.allow_file_remotes);
        assert!(!config.telemetry);
    }

    #[test]
    fn telemetry_is_off_unless_turned_on() {
        let config = Config::parse(&with(serde_json::json!({"telemetry": null}))).unwrap();
        assert!(!config.telemetry);
        let config = Config::parse(&with(serde_json::json!({"telemetry": true}))).unwrap();
        assert!(config.telemetry);
    }

    /// A conversation turn plans and acts for 110 seconds, or less when `turnBudget` says so.
    #[test]
    fn the_turn_budget_is_1_to_110_seconds() {
        let config = Config::parse(&with(serde_json::json!({}))).unwrap();
        assert_eq!(config.turn_budget, std::time::Duration::from_secs(110));
        let config = Config::parse(&with(serde_json::json!({"turnBudget": 5}))).unwrap();
        assert_eq!(config.turn_budget, std::time::Duration::from_secs(5));
        for wrong in [0, 111] {
            let text = with(serde_json::json!({"turnBudget": wrong}));
            assert!(problem(&text).contains("turnBudget"), "{wrong}");
        }
    }

    /// Conversations are agent sessions on Sonnet for 10 minutes a turn unless the owner says
    /// otherwise; `plan` keeps obid's plan loop.
    #[test]
    fn conversations_are_sessions_unless_the_owner_says_plan() {
        let config = Config::parse(&with(serde_json::json!({}))).unwrap();
        assert!(config.conversation.harness);
        assert_eq!(config.conversation.model, CONVERSATION_MODEL);
        assert_eq!(
            config.conversation.budget,
            std::time::Duration::from_secs(600)
        );
        let set = with(serde_json::json!({"conversation":
            {"agent": "plan", "model": "claude-opus-5-5", "budget": 60}}));
        let config = Config::parse(&set).unwrap();
        assert!(!config.conversation.harness);
        assert_eq!(config.conversation.model, "claude-opus-5-5");
        let codex = Config::parse(&with(
            serde_json::json!({"conversation": {"agent": "codex"}}),
        ))
        .unwrap()
        .conversation;
        assert!(codex.harness);
        assert_eq!(codex.agent, crate::agent::Tool::Codex);
        assert_eq!(codex.model, "", "Codex's own model");
        assert_eq!(
            config.conversation.budget,
            std::time::Duration::from_secs(60)
        );
        for (wrong, field) in [
            (serde_json::json!({"agent": "cursor"}), "conversation.agent"),
            (
                serde_json::json!({"agent": "codex", "model": ""}),
                "conversation.model",
            ),
            (
                serde_json::json!({"model": "--dangerously"}),
                "conversation.model",
            ),
            (serde_json::json!({"model": "a b"}), "conversation.model"),
            (serde_json::json!({"budget": 5}), "conversation.budget"),
            (serde_json::json!({"budget": 3601}), "conversation.budget"),
        ] {
            let text = with(serde_json::json!({"conversation": wrong}));
            assert!(problem(&text).contains(field), "{text}");
        }
    }

    /// The event orchestrator waits 30 seconds for nearby events, or 1 to 600 as configured.
    #[test]
    fn the_keychain_is_as_the_owner_set_it_or_left_to_obid() {
        let parse = |extra| Config::parse(&with(extra)).unwrap().claude_keychain;
        assert_eq!(parse(serde_json::json!({})), None);
        assert_eq!(
            parse(serde_json::json!({"claudeKeychain": true})),
            Some(true)
        );
        assert_eq!(
            parse(serde_json::json!({"claudeKeychain": false})),
            Some(false)
        );
    }

    /// A Claude account's `configDir` is never the person's own `~/.claude` nor inside it (#651's
    /// re-review): that is the person's own login, which obid refreshes unboxed. Nor is a Codex
    /// account's `configDir` the person's own `~/.codex` or inside it (finding 9). An account's
    /// folder is its own, of which a run gets only a copy of the login (#655).
    /// A `configDir` never holds obid's home: every box hides every account's folder (#655), and
    /// obid's home holds the boxes' own folders.
    #[test]
    fn a_config_dir_never_holds_obids_home() {
        for dir in ["/srv", "/srv/obid-home", "/"] {
            let agents = serde_json::json!({"codex": {"bin": "codex",
                "accounts": [{"id": "w", "name": "W", "configDir": dir}]}});
            let error = Config::parse(&with(serde_json::json!({"agents": agents})))
                .unwrap_err()
                .to_string();
            assert!(error.contains("holds obid's home"), "{dir}: {error}");
        }
    }

    /// A `configDir` inside obid's home is only a folder of `home/accounts` (where the accounts API
    /// makes them): never its clones, the jobs' worktrees or anything else of obid's.
    #[test]
    fn a_config_dir_in_obids_home_is_only_one_of_its_accounts() {
        let at = |dir: &str| {
            let agents = serde_json::json!({"codex": {"bin": "codex",
                "accounts": [{"id": "w", "name": "W", "configDir": dir}]}});
            Config::parse(&with(serde_json::json!({"agents": agents})))
        };
        for dir in [
            "/srv/obid-home/worktrees/abc/acct",
            "/srv/obid-home/clones/o/r",
            "/srv/obid-home/accounts/x/inner",
            "/srv/obid-home/logins",
        ] {
            let error = at(dir).unwrap_err().to_string();
            assert!(error.contains("inside obid's home"), "{dir}: {error}");
        }
        assert!(at("/srv/obid-home/accounts/work").is_ok());
        assert!(at("/srv/elsewhere/work").is_ok());
    }

    #[test]
    fn a_codex_config_dir_is_never_the_persons_own_codex_folder() {
        let home = crate::jobs::person_homes().into_iter().next().unwrap();
        for dir in [
            home.join(".codex"),
            home.join(".codex/work"),
            home.join(".Codex/work"),
        ] {
            let accounts = serde_json::json!({"codex": {"bin": "codex",
                "accounts": [{"id": "work", "name": "Work", "configDir": dir}]}});
            let text = with(serde_json::json!({"agents": accounts}));
            assert!(problem(&text).contains("~/.codex"), "{}", dir.display());
        }
        let beside = serde_json::json!({"codex": {"bin": "codex",
            "accounts": [{"id": "work", "name": "Work", "configDir": home.join(".codex-work")}]}});
        assert!(Config::parse(&with(serde_json::json!({"agents": beside}))).is_ok());
    }

    #[test]
    fn a_claude_config_dir_is_never_the_persons_own_claude_folder() {
        let home = crate::jobs::person_homes().into_iter().next().unwrap();
        for dir in [
            home.join(".claude"),
            home.join(".claude/accounts/work"),
            home.join(".Claude/work"),
        ] {
            let accounts = serde_json::json!({"claude": {"bin": "claude",
                "accounts": [{"id": "work", "name": "Work", "configDir": dir}]}});
            let text = with(serde_json::json!({"agents": accounts}));
            assert!(problem(&text).contains("~/.claude"), "{}", dir.display());
        }
        let beside = serde_json::json!({"claude": {"bin": "claude",
            "accounts": [{"id": "work", "name": "Work", "configDir": home.join(".claude-work")}]}});
        assert!(Config::parse(&with(serde_json::json!({"agents": beside}))).is_ok());
    }

    #[test]
    fn the_gateway_is_only_ever_on_127_0_0_1() {
        assert_eq!(
            Config::parse(&with(serde_json::json!({}))).unwrap().gateway,
            None
        );
        let config =
            Config::parse(&with(serde_json::json!({"gateway": "127.0.0.1:8810"}))).unwrap();
        assert_eq!(config.gateway, Some("127.0.0.1:8810".parse().unwrap()));
        for gateway in ["0.0.0.0:8810", "100.64.0.1:8810", "localhost:8810", "8810"] {
            let text = with(serde_json::json!({ "gateway": gateway }));
            assert!(problem(&text).contains("gateway"), "{gateway}");
        }
    }

    #[test]
    fn jobs_stall_after_15_minutes_and_stop_at_12_hours_unless_set() {
        let config = Config::parse(&with(serde_json::json!({}))).unwrap();
        assert_eq!(config.stall_after, std::time::Duration::from_secs(900));
        assert_eq!(
            config.job_ceiling,
            std::time::Duration::from_secs(12 * 3600)
        );
        let config = Config::parse(&with(
            serde_json::json!({"stallAfter": 2, "jobCeilingHours": 1}),
        ))
        .unwrap();
        assert_eq!(config.stall_after, std::time::Duration::from_secs(2));
        assert_eq!(config.job_ceiling, std::time::Duration::from_secs(3600));
        assert_eq!(config.job_token_budget, 50_000_000);
        for (key, wrong) in [
            ("stallAfter", 0),
            ("stallAfter", 86_401),
            ("jobCeilingHours", 0),
            ("jobCeilingHours", 169),
            ("jobTokenBudget", 0),
        ] {
            let text = with(serde_json::json!({key: wrong}));
            assert!(problem(&text).contains(key), "{key} {wrong}");
        }
    }

    #[test]
    fn the_orchestrator_delay_is_1_to_600_seconds() {
        let config = Config::parse(&with(serde_json::json!({}))).unwrap();
        assert_eq!(
            config.orchestrator_delay,
            std::time::Duration::from_secs(30)
        );
        let config = Config::parse(&with(serde_json::json!({"orchestratorDelay": 1}))).unwrap();
        assert_eq!(config.orchestrator_delay, std::time::Duration::from_secs(1));
        for wrong in [0, 601] {
            let text = with(serde_json::json!({"orchestratorDelay": wrong}));
            assert!(problem(&text).contains("orchestratorDelay"), "{wrong}");
        }
    }

    /// #763: tests may give a brain more than a second as the least it thinks in.
    #[test]
    fn the_least_think_time_is_1_second_to_under_the_budget() {
        let config = Config::parse(&with(serde_json::json!({}))).unwrap();
        assert_eq!(config.least_think, std::time::Duration::from_secs(1));
        let config = Config::parse(&with(serde_json::json!({"leastThink": 10}))).unwrap();
        assert_eq!(config.least_think, std::time::Duration::from_secs(10));
        for wrong in [0, 111] {
            let text = with(serde_json::json!({"leastThink": wrong}));
            assert!(problem(&text).contains("leastThink"), "{wrong}");
        }
        let text = with(serde_json::json!({"turnBudget": 10, "leastThink": 10}));
        assert!(
            problem(&text).contains("less than turnBudget (10)"),
            "{text}"
        );
        let config = Config::parse(&with(
            serde_json::json!({"turnBudget": 10, "leastThink": 9}),
        ));
        assert_eq!(
            config.unwrap().least_think,
            std::time::Duration::from_secs(9)
        );
    }

    #[test]
    fn listen_is_only_ever_127_0_0_1() {
        for listen in [
            "0.0.0.0:7811",
            "192.168.1.2:7811",
            "127.0.0.2:7811",
            "[::1]:7811",
            "localhost:7811",
            "127.0.0.1",
            "",
        ] {
            let text = with(serde_json::json!({ "listen": listen }));
            assert!(problem(&text).contains("listen"), "{listen}");
        }
    }

    #[test]
    fn requires_listen_home_and_owner() {
        for key in ["home", "owner"] {
            let text = with(serde_json::json!({ key: null }));
            assert!(problem(&text).contains(key), "{key}");
        }
        // `listen` is required but on macOS, where it is 127.0.0.1:7777 when not given.
        let text = with(serde_json::json!({ "listen": null }));
        if cfg!(target_os = "macos") {
            assert_eq!(
                Config::parse(&text).unwrap().listen,
                "127.0.0.1:7777".parse().unwrap()
            );
        } else {
            assert!(problem(&text).contains("listen"));
        }
        assert!(problem(&with(serde_json::json!({"owner": " "}))).contains("owner"));
    }

    #[test]
    fn bundled_plugins_are_the_repositorys_unless_given() {
        let config = Config::parse(&with(serde_json::json!({}))).unwrap();
        assert_eq!(config.bundled_plugins, default_bundled_plugins());
        assert!(
            config
                .bundled_plugins
                .join("tetrix/obi-plugin.json")
                .is_file(),
            "{:?}",
            config.bundled_plugins
        );
        let config = Config::parse(&with(
            serde_json::json!({"bundledPlugins": "/opt/obi/plugins"}),
        ))
        .unwrap();
        assert_eq!(config.bundled_plugins, PathBuf::from("/opt/obi/plugins"));
        assert!(
            problem(&with(serde_json::json!({"bundledPlugins": "plugins"}))).contains("absolute")
        );
    }

    #[test]
    fn the_web_app_is_the_repositorys_unless_given() {
        let config = Config::parse(&with(serde_json::json!({}))).unwrap();
        assert_eq!(config.web, default_web());
        assert!(config.web.ends_with("apps/web/dist"), "{:?}", config.web);
        let config = Config::parse(&with(serde_json::json!({"web": "/opt/obi/web"}))).unwrap();
        assert_eq!(config.web, PathBuf::from("/opt/obi/web"));
        assert!(problem(&with(serde_json::json!({"web": "dist"}))).contains("absolute"));
    }

    #[test]
    fn home_is_absolute() {
        assert!(problem(&with(serde_json::json!({"home": "obid-home"}))).contains("absolute"));
    }

    #[test]
    fn refuses_keys_it_doesnt_know() {
        assert!(problem(&with(serde_json::json!({"telemetri": true}))).contains("telemetri"));
    }

    #[test]
    fn file_remotes_only_when_allowed() {
        let repos = serde_json::json!([{"repo": "obi-e2e/fixture-app", "remote": "file:///tmp/remote.git", "defaultBranch": "main", "check": "node --test"}]);
        assert!(problem(&with(serde_json::json!({ "repos": repos }))).contains("allowFileRemotes"));
        let config = Config::parse(&with(
            serde_json::json!({ "repos": repos, "allowFileRemotes": true }),
        ))
        .unwrap();
        assert!(config.allow_file_remotes);
    }

    #[test]
    fn remotes() {
        for (remote, kind) in [
            ("https://github.com/o/r.git", Some(RemoteKind::Https)),
            ("ssh://git@github.com/o/r.git", Some(RemoteKind::Ssh)),
            ("git@github.com:o/r.git", Some(RemoteKind::Ssh)),
            ("file:///abs/remote.git", Some(RemoteKind::File)),
            ("file://relative/remote.git", None),
            ("http://github.com/o/r.git", None),
            ("/abs/remote.git", None),
            ("ext::sh -c touch% /tmp/pwned", None),
            ("https://", None),
            ("", None),
            ("https://github.com:443/o/r.git", Some(RemoteKind::Https)),
            ("ssh://git@github.com:22/o/r.git", Some(RemoteKind::Ssh)),
            ("ssh://git@[::1]:22/o/r.git", Some(RemoteKind::Ssh)),
            ("ssh://192.168.1.2/o/r.git", Some(RemoteKind::Ssh)),
            ("git@192.168.1.2:o/r.git", Some(RemoteKind::Ssh)),
            // Users and hosts git or ssh would read as options.
            ("ssh://-oProxyCommand=touch /tmp/pwned/x", None),
            ("ssh://-oProxyCommand=touch%20/tmp/pwned/x/o/r.git", None),
            ("ssh://git@-oProxyCommand=x/o/r.git", None),
            ("ssh://-oProxyCommand=x@github.com/o/r.git", None),
            ("-oProxyCommand=touch /tmp/x@h:p", None),
            ("git@-oProxyCommand=x:o/r.git", None),
            ("-git@github.com:o/r.git", None),
            ("git@github.com:-o/r.git", None),
            ("https://-x/r", None),
            ("https://user@github.com/o/r.git", Some(RemoteKind::Https)),
            ("https://-user@github.com/o/r.git", None),
            // Percent-escapes git decodes before ssh or curl sees the user or host.
            ("ssh://%2DoProxyCommand=x@github.com/o/r.git", None),
            ("ssh://%2doProxyCommand=x@github.com/o/r.git", None),
            ("ssh://git%40x@github.com/o/r.git", None),
            ("ssh://git@%2DoProxyCommand=x/o/r.git", None),
            ("ssh://git@github%2Ecom/o/r.git", None),
            ("https://%2Duser@github.com/o/r.git", None),
            ("https://github.com%2F@x/o/r.git", None),
            ("%2Dgit@github.com:o/r.git", None),
            ("git@%2Dgithub.com:o/r.git", None),
            ("ssh://git@github.com/o/r%20x.git", Some(RemoteKind::Ssh)),
            ("https://github.com:x/o/r.git", None),
            ("https://git hub.com/o/r.git", None),
            ("https://github.com/o/r.git\n", None),
            ("ssh://git@github.com\t/o/r.git", None),
            // Local paths git would clone from the disk, not over ssh: a `/` (or `\\`) before
            // the first `:` makes git read the remote as a path.
            ("/tmp/x@h:p", None),
            ("./x@h:p", None),
            ("../../srv/other@h:repo.git", None),
            ("x/y@h:p", None),
            ("git@github.com/x:o/r.git", None),
            ("..\\srv\\other@h:repo.git", None),
            ("git@github.com:o/r.git/", Some(RemoteKind::Ssh)),
        ] {
            assert_eq!(remote_kind(remote), kind, "{remote}");
        }
    }

    #[test]
    fn repo_names() {
        for name in ["obi-e2e/fixture-app", "o/r", "O_1/r.s"] {
            assert!(is_repo_name(name), "{name}");
        }
        for name in ["o", "o/", "/r", "o/r/x", "../r", "o/..", "o r/x", ""] {
            assert!(!is_repo_name(name), "{name}");
        }
    }

    #[test]
    fn account_ids_are_unique() {
        let agents = serde_json::json!({"claude": {"bin": "claude", "accounts": [
            {"id": "a", "name": "A", "configDir": null}, {"id": "a", "name": "B", "configDir": null}]}});
        assert!(problem(&with(serde_json::json!({ "agents": agents }))).contains("twice"));
        let agents = serde_json::json!({
            "claude": {"bin": "claude", "accounts": [{"id": "a", "name": "A", "configDir": null}]},
            "codex": {"bin": "codex", "accounts": [{"id": "a", "name": "B", "configDir": null}]}});
        assert!(
            problem(&with(serde_json::json!({ "agents": agents })))
                .contains("agents.codex.accounts: the id \"a\" is listed twice")
        );
    }

    #[test]
    fn codex_and_cursor_take_claudes_shape() {
        let agents = serde_json::json!({
            "codex": {"bin": "codex", "accounts": [{"id": "work", "name": "Work", "configDir": "/srv/codex-work"}]},
            "cursor": {"bin": "cursor-agent", "accounts": [{"id": "c", "name": "Cursor", "configDir": "/srv/cursor"}]}});
        let config = Config::parse(&with(serde_json::json!({ "agents": agents }))).unwrap();
        assert!(config.agents.get().claude.is_none());
        assert_eq!(config.agents.get().codex.unwrap().accounts[0].id, "work");
        assert_eq!(
            config.agents.get().cursor.unwrap().accounts[0].config_dir,
            Some(PathBuf::from("/srv/cursor"))
        );
        let agents = serde_json::json!({"cursor": {"bin": "cursor-agent", "accounts": [{"id": "c", "name": "C", "configDir": null}]}});
        assert!(
            problem(&with(serde_json::json!({ "agents": agents })))
                .contains("needs a folder of its own")
        );
        let agents = serde_json::json!({"codex": {"bin": " ", "accounts": []}});
        assert!(
            problem(&with(serde_json::json!({ "agents": agents })))
                .contains("agents.codex.bin is empty")
        );
        let agents = serde_json::json!({"codex": {"bin": "codex", "accounts": [{"id": "w", "name": "W", "configDir": "rel"}]}});
        assert!(
            problem(&with(serde_json::json!({ "agents": agents })))
                .contains("must be an absolute path")
        );
        let agents = serde_json::json!({"gemini": {"bin": "gemini"}});
        assert!(Config::parse(&with(serde_json::json!({ "agents": agents }))).is_err());
        assert!(
            problem(&with(serde_json::json!({"guestRequestEvery": -1})))
                .contains("guestRequestEvery is -1")
        );
        assert!(Config::parse(&with(serde_json::json!({"guestRequestEvery": 0}))).is_ok());
    }
}
