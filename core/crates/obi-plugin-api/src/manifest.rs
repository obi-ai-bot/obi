//! `obi-plugin.json`, the manifest every plug-in folder holds (docs/ARCHITECTURE.md 5.2).
//!
//! A manifest is checked whole: it parses with no field the spec doesn't list, and then
//! [`Manifest::validate`] holds. There is no field that enables a plug-in by itself.

use std::collections::BTreeSet;
use std::path::{Component, Path};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{EventKind, Kind, PROTOCOL, PluginError, PluginId};

/// The manifest's file name inside the plug-in's folder.
pub const MANIFEST_FILE: &str = "obi-plugin.json";

/// At most this many bytes in a name `agentMcp.allowedTools` lists.
pub const MAX_TOOL_NAME_BYTES: usize = 128;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    /// Always [`PROTOCOL`].
    pub manifest: String,
    /// Unique, and the folder's name.
    pub id: PluginId,
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub description: String,
    /// One or more, each once.
    pub kinds: Vec<Kind>,
    /// The process to start, relative to the plug-in's folder: needed for `context` and
    /// `events`; an `agent-mcp`-only plug-in may leave it out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run: Option<RunSpec>,
    /// Required for `agent-mcp`, refused on any other.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_mcp: Option<AgentMcpSpec>,
    /// Required for `events`, refused on any other.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub events: Option<EventsSpec>,
    /// The hosts it talks to, shown to the owner before enabling. Declared, not enforced.
    #[serde(default)]
    pub network: Vec<String>,
    /// A JSON Schema for its settings. Left out, the plug-in takes no settings.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config: Option<Value>,
}

/// The plug-in's process: `command` is relative to its folder.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RunSpec {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AgentMcpSpec {
    pub server: McpServerSpec,
    /// The only tools agents may call; the job's permission gate refuses every other. Each is
    /// one tool's bare name, as the server lists it: 1 to [`MAX_TOOL_NAME_BYTES`] ASCII letters,
    /// digits, `_`, `-` and `.`, not starting with `mcp__`. So no name is a wildcard (`*`), a
    /// list (`a,b`), a rule for another tool (`a Bash(...)`), or a name already prefixed for
    /// another server: `obid` prefixes each one itself (`mcp__<plugin id>__<tool>`).
    pub allowed_tools: Vec<String>,
}

/// The MCP server an `agent-mcp` plug-in gives agents. Its login is its own (OAuth in its own
/// store), never a vault secret, so the manifest gives a secret nowhere to go: there is no
/// field for headers or an environment, and [`Manifest::validate`] refuses an `http` URL with
/// a login (`user@`), a query string or a fragment, and `stdio` arguments that pass a
/// credential the usual ways (`--token x`, `--accessToken x`, `--api-key=x`, `TOKEN=x`,
/// `Authorization:`, `X-Api-Key: x`, `Bearer `, a `ghp_…` value). That last check goes by
/// names and shapes, so it can't recognize every secret: one put in a URL's path, or in an
/// argument with no telling name or shape (`-t x`), gets through. The owner sees the
/// manifest before enabling the plug-in.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum McpServerSpec {
    Http {
        url: String,
    },
    Stdio {
        command: String,
        #[serde(default)]
        args: Vec<String>,
    },
}

/// The event kinds an `events` plug-in may emit; an event of a kind not listed is refused.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EventsSpec {
    pub kinds: Vec<EventKind>,
}

impl Manifest {
    /// Parses and checks `obi-plugin.json` read from the folder named `folder`: the manifest's
    /// `id` must be that name.
    pub fn from_slice(json: &[u8], folder: &str) -> Result<Manifest, PluginError> {
        let manifest: Manifest = serde_json::from_slice(json)
            .map_err(|error| PluginError::Manifest(error.to_string()))?;
        manifest.validate()?;
        if manifest.id.as_str() != folder {
            return Err(PluginError::Manifest(format!(
                "id {} is not its folder's name {folder:?}",
                manifest.id
            )));
        }
        Ok(manifest)
    }

    /// Whether this manifest serves `kind`.
    pub fn serves(&self, kind: Kind) -> bool {
        self.kinds.contains(&kind)
    }

    /// The rules of docs/ARCHITECTURE.md 5.2 that parsing alone doesn't hold.
    pub fn validate(&self) -> Result<(), PluginError> {
        let fail = |reason: String| Err(PluginError::Manifest(reason));
        if self.manifest != PROTOCOL {
            return fail(format!("manifest is {:?}, not {PROTOCOL:?}", self.manifest));
        }
        if self.name.trim().is_empty() {
            return fail("name is empty".into());
        }
        if self.version.trim().is_empty() {
            return fail("version is empty".into());
        }
        if self.kinds.is_empty() {
            return fail("kinds is empty".into());
        }
        if !unique(&self.kinds) {
            return fail("kinds lists a kind twice".into());
        }

        let needs_run = self.serves(Kind::Context) || self.serves(Kind::Events);
        match &self.run {
            None if needs_run => {
                return fail("run is needed for a context or events plug-in".into());
            }
            Some(run) => check_relative(&run.command, "run.command")?,
            None => {}
        }

        match (&self.agent_mcp, self.serves(Kind::AgentMcp)) {
            (None, true) => return fail("agentMcp is needed for an agent-mcp plug-in".into()),
            (Some(_), false) => return fail("agentMcp is only for an agent-mcp plug-in".into()),
            (Some(spec), true) => spec.validate()?,
            (None, false) => {}
        }

        match (&self.events, self.serves(Kind::Events)) {
            (None, true) => return fail("events is needed for an events plug-in".into()),
            (Some(_), false) => return fail("events is only for an events plug-in".into()),
            (Some(spec), true) => {
                if spec.kinds.is_empty() {
                    return fail("events.kinds is empty".into());
                }
                if !unique(&spec.kinds) {
                    return fail("events.kinds lists a kind twice".into());
                }
            }
            (None, false) => {}
        }

        for host in &self.network {
            let plain = !host.is_empty()
                && host
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':'));
            if !plain {
                return fail(format!("network lists {host:?}, which is not a host name"));
            }
        }

        if self
            .config
            .as_ref()
            .is_some_and(|config| !config.is_object())
        {
            return fail("config is not a JSON Schema object".into());
        }
        Ok(())
    }
}

impl AgentMcpSpec {
    fn validate(&self) -> Result<(), PluginError> {
        let fail = |reason: String| Err(PluginError::Manifest(reason));
        match &self.server {
            McpServerSpec::Http { url } => {
                let rest = url
                    .strip_prefix("https://")
                    .or_else(|| url.strip_prefix("http://"));
                let Some(rest) = rest else {
                    return fail(format!("agentMcp.server.url {url:?} is not http or https"));
                };
                let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
                if authority.is_empty() {
                    return fail(format!("agentMcp.server.url {url:?} has no host"));
                }
                if authority.contains('@') {
                    return fail("agentMcp.server.url carries a login; logins are the server's own, never in the manifest".into());
                }
                if rest.contains(['?', '#']) {
                    return fail("agentMcp.server.url has a query string or a fragment, where a secret could ride; the manifest takes none".into());
                }
                if url.chars().any(|c| c.is_whitespace() || c.is_control()) {
                    return fail(format!(
                        "agentMcp.server.url {url:?} has a space or a control character"
                    ));
                }
            }
            McpServerSpec::Stdio { command, args } => {
                if command.trim().is_empty() {
                    return fail("agentMcp.server.command is empty".into());
                }
                if let Some(arg) = passes_credential(args) {
                    return fail(format!(
                        "agentMcp.server.args passes a credential ({arg:?}); logins are the server's own, never in the manifest"
                    ));
                }
            }
        }
        if self.allowed_tools.is_empty() {
            return fail("agentMcp.allowedTools is empty".into());
        }
        if let Some(tool) = self.allowed_tools.iter().find(|tool| !is_tool_name(tool)) {
            return fail(format!(
                "agentMcp.allowedTools lists {tool:?}, which is not one tool's bare name (1 to {MAX_TOOL_NAME_BYTES} ASCII letters, digits, '_', '-' and '.', not starting with \"mcp__\")"
            ));
        }
        if !unique(&self.allowed_tools) {
            return fail("agentMcp.allowedTools lists a tool twice".into());
        }
        Ok(())
    }
}

/// One tool's bare name, as an MCP server lists it: 1 to [`MAX_TOOL_NAME_BYTES`] ASCII
/// letters, digits, `_`, `-` and `.`, and not already prefixed for a server (`mcp__`).
fn is_tool_name(tool: &str) -> bool {
    (1..=MAX_TOOL_NAME_BYTES).contains(&tool.len())
        && tool
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
        && !tool.to_ascii_lowercase().starts_with("mcp__")
}

/// The first argument that passes a credential the usual ways: an option or variable whose
/// name names one (`--token x`, `--accessToken x`, `--api-key=x`, `--pat x`, `TOKEN=x`), an
/// HTTP header that carries one (`Authorization:`, `X-Api-Key: x`, `Cookie: x`, or a `Bearer `
/// value), or a value that starts the way well-known tokens do (`ghp_`, `github_pat_`,
/// `xoxb-`, `glpat-`, `sk-ant-` and the like). Goes by names and shapes, so a secret with no
/// telling name or shape (`-t x`) isn't found: a one-letter option means different things to
/// different programs, and refusing every one would refuse ordinary servers.
fn passes_credential(args: &[String]) -> Option<&str> {
    for (i, arg) in args.iter().enumerate() {
        let lower = arg.to_ascii_lowercase();
        if lower.contains("authorization:") || lower.contains("bearer ") {
            return Some(arg);
        }
        if looks_like_token(arg) || header_passes_credential(arg) {
            return Some(arg);
        }
        match arg.split_once('=') {
            Some((name, value)) if names_credential(name) && !value.is_empty() => {
                return Some(arg);
            }
            Some((_, value)) if looks_like_token(value) || header_passes_credential(value) => {
                return Some(arg);
            }
            None if arg.starts_with('-') && names_credential(arg) && i + 1 < args.len() => {
                return Some(arg);
            }
            _ => {}
        }
    }
    None
}

/// Whether `text` is an HTTP header (`Name: value`) whose name names a credential, like
/// `X-Api-Key: x` or `Cookie: x`, with a value.
fn header_passes_credential(text: &str) -> bool {
    let Some((name, value)) = text.split_once(':') else {
        return false;
    };
    let header = !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'));
    header && !value.trim().is_empty() && names_credential(name)
}

/// Whether `value` starts the way a well-known token does.
fn looks_like_token(value: &str) -> bool {
    const PREFIXES: [&str; 11] = [
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "ghr_",
        "github_pat_",
        "glpat-",
        "xoxb-",
        "xoxp-",
        "xapp-",
        "sk-ant-",
    ];
    PREFIXES
        .iter()
        .any(|prefix| value.len() > prefix.len() && value.starts_with(prefix))
}

/// Whether an option, variable or header name, like `--api-key`, `--accessToken`,
/// `GITHUB_TOKEN` or `X-Api-Key`, names a credential. The name is cut into words at `-`, `_`,
/// `.` and where a lower-case letter meets an upper-case one; a word names a credential when
/// it is one of the usual words or ends with one (`githubtoken`, `dbpassword`), so `--tokens`
/// or `--tokenizer` don't count. A name that is all of `auth`, `pat`, `key`, `pass`, `pw` or
/// `pwd` counts too.
fn names_credential(name: &str) -> bool {
    let name = name.trim_start_matches('-');
    let mut words: Vec<String> = Vec::new();
    let mut word = String::new();
    let mut previous_lower = false;
    for c in name.chars() {
        if matches!(c, '-' | '_' | '.') {
            words.push(std::mem::take(&mut word));
            previous_lower = false;
            continue;
        }
        if c.is_ascii_uppercase() && previous_lower {
            words.push(std::mem::take(&mut word));
        }
        previous_lower = c.is_ascii_lowercase() || c.is_ascii_digit();
        word.push(c.to_ascii_lowercase());
    }
    words.push(word);
    words.retain(|w| !w.is_empty());

    let whole = ["auth", "pat", "key", "pass", "pw", "pwd"];
    let single = [
        "token",
        "secret",
        "password",
        "passwd",
        "apikey",
        "credential",
        "credentials",
        "cookie",
    ];
    let endings = ["token", "secret", "password", "passwd", "apikey"];
    let pairs = [
        ("api", "key"),
        ("access", "key"),
        ("private", "key"),
        ("secret", "key"),
        ("client", "secret"),
    ];
    (words.len() == 1 && whole.contains(&words[0].as_str()))
        || words.iter().any(|w| {
            single.contains(&w.as_str()) || endings.iter().any(|ending| w.ends_with(ending))
        })
        || words
            .windows(2)
            .any(|pair| pairs.contains(&(pair[0].as_str(), pair[1].as_str())))
}

/// A path that stays inside the plug-in's folder: relative, no `..`.
fn check_relative(path: &str, field: &str) -> Result<(), PluginError> {
    let p = Path::new(path);
    let inside = !path.is_empty()
        && p.components()
            .all(|c| matches!(c, Component::Normal(_) | Component::CurDir));
    if inside {
        Ok(())
    } else {
        Err(PluginError::Manifest(format!(
            "{field} {path:?} is not a path inside the plug-in's folder"
        )))
    }
}

fn unique<T: Ord>(items: &[T]) -> bool {
    items.iter().collect::<BTreeSet<_>>().len() == items.len()
}
