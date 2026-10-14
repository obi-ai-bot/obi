//! obid's configuration file (docs/runner-api.md, "obid only: configuration").
//!
//! ```json
//! {"listen": "127.0.0.1:7811",
//!  "home": "/abs/path/obid-home",
//!  "owner": "wellington",
//!  "agents": {"claude": {"bin": "claude", "accounts": [{"id": "default", "name": "Default", "configDir": null}]}},
//!  "repos": [{"repo": "obi-e2e/fixture-app", "remote": "file:///abs/path/remote.git", "defaultBranch": "main", "check": "node --test"}],
//!  "allowFileRemotes": false,
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

/// The file as written. Validated into [`Config`].
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct File {
    listen: String,
    home: PathBuf,
    owner: String,
    #[serde(default)]
    agents: Agents,
    #[serde(default)]
    repos: Vec<Repo>,
    #[serde(default)]
    allow_file_remotes: bool,
    #[serde(default)]
    telemetry: bool,
}

/// The agents' adapters. Codex and Cursor take the same shape as Claude Code when their adapters
/// land.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Agents {
    pub claude: Option<Agent>,
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
    /// `CLAUDE_CONFIG_DIR` for this account's agents, or null for the tool's own default login.
    pub config_dir: Option<PathBuf>,
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
    pub agents: Agents,
    pub repos: Vec<Repo>,
    pub allow_file_remotes: bool,
    /// False unless the owner turns it on; obid sends nothing to anyone otherwise.
    pub telemetry: bool,
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

        let listen: SocketAddr = match file.listen.parse() {
            Ok(address) => address,
            Err(_) => {
                return invalid(format!(
                    "listen is {:?}: it must be an address on 127.0.0.1 with a port, like 127.0.0.1:7811.",
                    file.listen
                ));
            }
        };
        if listen.ip() != Ipv4Addr::LOCALHOST {
            return invalid(format!(
                "listen is {:?}: obid binds only 127.0.0.1, like 127.0.0.1:7811.",
                file.listen
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
        if let Some(claude) = &file.agents.claude {
            if claude.bin.trim().is_empty() {
                return invalid("agents.claude.bin is empty: it is the Claude Code adapter's binary, a path or a command name.".into());
            }
            let mut seen = std::collections::HashSet::new();
            for account in &claude.accounts {
                if account.id.trim().is_empty() {
                    return invalid("agents.claude.accounts: an account has an empty id.".into());
                }
                if !seen.insert(account.id.as_str()) {
                    return invalid(format!(
                        "agents.claude.accounts: the id {:?} is listed twice.",
                        account.id
                    ));
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

        Ok(Config {
            listen,
            home: file.home,
            owner: file.owner,
            agents: file.agents,
            repos: file.repos,
            allow_file_remotes: file.allow_file_remotes,
            telemetry: file.telemetry,
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
    if !remote.contains("://") {
        if let Some((user_host, path)) = remote.split_once(':') {
            if user_host.contains(['/', '\\']) {
                return None;
            }
            if let Some((user, host)) = user_host.split_once('@') {
                if user_ok(user) && host_name_ok(host) && !path.is_empty() && !path.starts_with('-')
                {
                    return Some(RemoteKind::Ssh);
                }
            }
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
        let claude = config.agents.claude.unwrap();
        assert_eq!(claude.bin, "claude");
        assert_eq!(
            claude.accounts,
            vec![Account {
                id: "default".into(),
                name: "Default".into(),
                config_dir: None
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
        for key in ["listen", "home", "owner"] {
            let text = with(serde_json::json!({ key: null }));
            assert!(problem(&text).contains(key), "{key}");
        }
        assert!(problem(&with(serde_json::json!({"owner": " "}))).contains("owner"));
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
    }
}
