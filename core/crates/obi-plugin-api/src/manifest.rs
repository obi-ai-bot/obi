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
/// field for headers or an environment, and [`Manifest::validate`] refuses
/// - an `http` URL with a login (`user@`), a query string or a fragment, or with a space, a
///   control character or an invisible format character (Unicode `Cf`, like U+200B or U+202E);
/// - a `stdio` command or argument with a control or invisible format character;
/// - a URL anywhere in a `stdio` argument (`npx mcp-remote https://user:pass@host/mcp`,
///   `--url=postgres://u:p@db`) with a login, a query string or a fragment, the same rule as
///   an `http` URL;
/// - `stdio` arguments that pass a credential the usual ways: `--token x`, `--accessToken x`,
///   `--api-key=x`, `--github-pat x`, `--auth-header x`, `TOKEN=x`, `Authorization:`,
///   `X-Api-Key: x`, a header blob like `{"X-Api-Key":"x"}`, `Bearer `, a `ghp_…` value.
///
/// That last check goes by names and shapes, so it can't recognize every secret: one put in a
/// URL's path, or in an argument with no telling name or shape (`-t x`), gets through. The
/// owner sees the manifest before enabling the plug-in.
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
                if url.chars().any(|c| c.is_whitespace() || is_hidden(c)) {
                    return fail(format!(
                        "agentMcp.server.url {} has a space, a control character or an invisible format character",
                        url.escape_unicode()
                    ));
                }
            }
            McpServerSpec::Stdio { command, args } => {
                if command.trim().is_empty() {
                    return fail("agentMcp.server.command is empty".into());
                }
                if command.chars().any(is_hidden) {
                    return fail("agentMcp.server.command has a control character or an invisible format character".into());
                }
                // Each problem names the argument by its place, not its text: the text may be
                // the very secret, and this message reaches logs.
                for (i, arg) in args.iter().enumerate() {
                    if arg.chars().any(is_hidden) {
                        return fail(format!(
                            "agentMcp.server.args[{i}] has a control character or an invisible format character"
                        ));
                    }
                    match url_in_arg_problem(arg) {
                        Some(UrlProblem::Login) => {
                            return fail(format!(
                                "agentMcp.server.args[{i}] passes a URL with a login; logins are the server's own, never in the manifest"
                            ));
                        }
                        Some(UrlProblem::QueryOrFragment) => {
                            return fail(format!(
                                "agentMcp.server.args[{i}] passes a URL with a query string or a fragment, where a secret could ride; the manifest takes none"
                            ));
                        }
                        None => {}
                    }
                }
                if let Some(i) = passes_credential(args) {
                    return fail(format!(
                        "agentMcp.server.args[{i}] passes a credential; logins are the server's own, never in the manifest"
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

/// The place of the first argument that passes a credential the usual ways: an option or
/// variable whose name names one (`--token x`, `--accessToken x`, `--api-key=x`, `--pat x`,
/// `--github-pat x`, `--auth-header x`, `TOKEN=x`), an HTTP header or a header blob that
/// carries one (`Authorization:`, `X-Api-Key: x`, `Cookie: x`, `{"X-Api-Key":"x"}`,
/// `curl -H 'X-Api-Key: x'`, or a `Bearer ` value), or a value that starts the way well-known
/// tokens do (`ghp_`, `github_pat_`, `xoxb-`, `glpat-`, `sk-ant-` and the like). Goes by names
/// and shapes, so a secret with no telling name or shape (`-t x`) isn't found: a one-letter
/// option means different things to different programs, and refusing every one would refuse
/// ordinary servers.
fn passes_credential(args: &[String]) -> Option<usize> {
    for (i, arg) in args.iter().enumerate() {
        let lower = arg.to_ascii_lowercase();
        if lower.contains("authorization:") || lower.contains("bearer ") {
            return Some(i);
        }
        if looks_like_token(arg) || field_passes_credential(arg) {
            return Some(i);
        }
        match arg.split_once('=') {
            Some((name, value)) if names_credential(name) && !value.is_empty() => {
                return Some(i);
            }
            Some((_, value)) if looks_like_token(value) => return Some(i),
            None if arg.starts_with('-') && names_credential(arg) && i + 1 < args.len() => {
                return Some(i);
            }
            _ => {}
        }
    }
    None
}

/// Whether `text` holds a `name: value` field whose name names a credential and whose value
/// isn't empty, wherever it stands: an HTTP header (`X-Api-Key: x`, `Cookie: x`), one inside
/// a shell line (`curl -H 'X-Api-Key: x'`), or a key of a JSON or JSON-like object
/// (`{"X-Api-Key":"x"}`, `{'Authorization': 'x'}`, `{token: x}`).
fn field_passes_credential(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();
    let is_name = |c: char| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.');
    for (colon, _) in chars.iter().enumerate().filter(|(_, c)| **c == ':') {
        // The name: the run of name characters before the colon, past spaces and one closing
        // quote.
        let mut end = colon;
        while end > 0 && chars[end - 1].is_whitespace() {
            end -= 1;
        }
        if end > 0 && matches!(chars[end - 1], '"' | '\'') {
            end -= 1;
        }
        let mut start = end;
        while start > 0 && is_name(chars[start - 1]) {
            start -= 1;
        }
        let name: String = chars[start..end].iter().collect();
        if name.is_empty() || !names_credential(&name) {
            continue;
        }
        // The value: past spaces and one opening quote, something other than the end, a
        // closing quote or the end of the object.
        let mut at = colon + 1;
        while at < chars.len() && chars[at].is_whitespace() {
            at += 1;
        }
        if at < chars.len() && matches!(chars[at], '"' | '\'') {
            at += 1;
        }
        let has_value = chars
            .get(at)
            .is_some_and(|c| !c.is_whitespace() && !matches!(c, '"' | '\'' | ',' | '}' | ']'));
        if has_value {
            return true;
        }
    }
    false
}

/// What makes a URL unfit for a manifest, besides its characters.
enum UrlProblem {
    Login,
    QueryOrFragment,
}

/// The problem with the first URL (`scheme://…`) in `arg` that has one: a login
/// (`user:pass@`) or a query string or fragment (`?key=…`, `#token=…`). A URL ends at a space
/// or a quote, so one inside a shell line (`-c "curl 'https://u:p@x'"`) counts too.
fn url_in_arg_problem(arg: &str) -> Option<UrlProblem> {
    let mut search = 0;
    while let Some(found) = arg[search..].find("://") {
        let marker = search + found;
        search = marker + 3;
        let scheme_start = arg[..marker]
            .rfind(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')))
            .map_or(0, |i| i + 1);
        let scheme = &arg[scheme_start..marker];
        if !scheme.starts_with(|c: char| c.is_ascii_alphabetic()) {
            continue;
        }
        let rest = &arg[search..];
        let url_end = rest
            .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '`' | '<' | '>'))
            .unwrap_or(rest.len());
        let rest = &rest[..url_end];
        let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
        if authority.contains('@') {
            return Some(UrlProblem::Login);
        }
        if rest.contains(['?', '#']) {
            return Some(UrlProblem::QueryOrFragment);
        }
    }
    None
}

/// Whether `c` is a control character (Unicode `Cc`) or an invisible format character
/// (Unicode `Cf`: soft hyphen, zero-width space and joiners, bidirectional overrides and
/// isolates, word joiner, byte order mark, tags and the like). A format character changes
/// how text shows or reads without being seen: `--to\u{200B}ken` reads as `--token` to the
/// owner and as some other name to the checks, and U+202E turns what follows around.
fn is_hidden(c: char) -> bool {
    // Unicode 16.0's `Cf` code points.
    const FORMAT: [(u32, u32); 21] = [
        (0x00AD, 0x00AD),
        (0x0600, 0x0605),
        (0x061C, 0x061C),
        (0x06DD, 0x06DD),
        (0x070F, 0x070F),
        (0x0890, 0x0891),
        (0x08E2, 0x08E2),
        (0x180E, 0x180E),
        (0x200B, 0x200F),
        (0x202A, 0x202E),
        (0x2060, 0x2064),
        (0x2066, 0x206F),
        (0xFEFF, 0xFEFF),
        (0xFFF9, 0xFFFB),
        (0x110BD, 0x110BD),
        (0x110CD, 0x110CD),
        (0x13430, 0x1343F),
        (0x1BCA0, 0x1BCA3),
        (0x1D173, 0x1D17A),
        (0xE0001, 0xE0001),
        (0xE0020, 0xE007F),
    ];
    let code = u32::from(c);
    c.is_control()
        || FORMAT
            .iter()
            .any(|&(low, high)| (low..=high).contains(&code))
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
/// `GITHUB_TOKEN`, `X-Api-Key` or `Authorization`, names a credential. The name is cut into
/// words at `-`, `_`, `.` and where a lower-case letter meets an upper-case one; a word names a
/// credential when it is one of the usual words or ends with one (`githubtoken`, `dbpassword`),
/// so `--tokens` or `--tokenizer` don't count. A name that is all of `auth`, `pat`, `key`,
/// `pass`, `pw` or `pwd` counts too, and so does a longer one that ends with `pat`, `key` or
/// `auth` (`--github-pat`, `--openai-key`, `--basic-auth`, though `--no-auth` doesn't) or
/// pairs `auth` with what it carries (`--auth-header`, `--auth-value`).
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
        "authorization",
    ];
    let endings = [
        "token",
        "secret",
        "password",
        "passwd",
        "apikey",
        "authorization",
    ];
    let last = ["pat", "key", "auth"];
    let negations = ["no", "skip", "disable", "without"];
    let pairs = [
        ("api", "key"),
        ("access", "key"),
        ("private", "key"),
        ("secret", "key"),
        ("client", "secret"),
        ("auth", "header"),
        ("auth", "headers"),
        ("auth", "value"),
        ("auth", "string"),
        ("auth", "code"),
        ("auth", "key"),
    ];
    let compound_last = words.len() > 1
        && !negations.contains(&words[0].as_str())
        && last.contains(&words[words.len() - 1].as_str());
    (words.len() == 1 && whole.contains(&words[0].as_str()))
        || compound_last
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
