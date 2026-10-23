//! `obi-plugin.json`, the manifest every plug-in folder holds (docs/ARCHITECTURE.md 5.2).
//!
//! A manifest is checked whole: it parses with no field the spec doesn't list, and then
//! [`Manifest::validate`] holds. There is no field that enables a plug-in by itself.

use std::collections::BTreeSet;
use std::path::{Component, Path};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{EventKind, Kind, PROTOCOL, PROTOCOLS, PluginError, PluginId};

/// The manifest's file name inside the plug-in's folder.
pub const MANIFEST_FILE: &str = "obi-plugin.json";

/// At most this many bytes in a name `agentMcp.allowedTools` lists.
pub const MAX_TOOL_NAME_BYTES: usize = 128;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    /// One of [`PROTOCOLS`]: the protocol it speaks on the wire too.
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
///   control character or an invisible character (Unicode `Cf` like U+200B or U+202E, any other
///   `Default_Ignorable_Code_Point` like U+034F or U+3164, and U+2028 and U+2029);
/// - a `stdio` command or argument with a control or invisible character;
/// - a URL anywhere in a `stdio` command or argument (`npx mcp-remote https://user:pass@host/mcp`,
///   `--url=postgres://u:p@db`, and the forms a WHATWG parser reads the same way:
///   `https:\\user:pass@host`, `https:user:pass@host`, `https:host/mcp?k=x`) with a login, a
///   query string or a fragment, the same rule as an `http` URL;
/// - a `stdio` command or arguments that pass a credential the usual ways: `--token x`,
///   `--accessToken x`, `--api-key=x`, `--github-pat x`, `--auth-header x`, `--bearer x`,
///   `--jwt x`, `--passphrase x`, `--creds x`, `TOKEN=x`, `Authorization:`, `X-Api-Key: x`,
///   `--header X-Api-Key x`, a header blob like `{"X-Api-Key":"x"}` or `["X-Api-Key","x"]`
///   (also with its key escaped, `{"X-Api-\u004bey":"x"}`), `Bearer `, a `ghp_…` value,
///   curl's `--user alice:x`, and any of these inside a shell line, read the way the shell
///   reads it (`sh -c "server --token x"`, `--to''ken x`, `--headers "{\"X-Api-Key\":\"x\"}"`).
///
/// That last check goes by names and shapes, so it can't recognize every secret: one put in a
/// URL's path, or in an argument with no telling name or shape (`-t x`), gets through. The
/// owner sees the manifest before enabling the plug-in.
///
/// The manifest's `{"type": "http", "urlFromConfig": "<key>"}` is
/// [`McpServerSpec::HttpFromConfig`]: the URL is the owner's setting under that key, which the
/// manifest's `config` schema must require, as a string, with no default, so the plug-in can't
/// be enabled until the owner has given it. [`AgentMcpSpec::server_for`] makes it an
/// [`McpServerSpec::Http`] with the owner's settings, holding that URL to the same rule as an
/// `http` URL in the manifest; what `obid` gets from the host is always `Http` or `Stdio`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "ServerWire", into = "ServerWire")]
pub enum McpServerSpec {
    Http {
        url: String,
    },
    /// `{"type": "http", "urlFromConfig": key}`: the URL is the owner's setting `key`.
    HttpFromConfig {
        key: String,
    },
    Stdio {
        command: String,
        args: Vec<String>,
    },
}

/// [`McpServerSpec`] as `obi-plugin.json` writes it: an `http` server has exactly one of `url`
/// and `urlFromConfig`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
enum ServerWire {
    Http {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<String>,
        #[serde(
            default,
            rename = "urlFromConfig",
            skip_serializing_if = "Option::is_none"
        )]
        url_from_config: Option<String>,
    },
    Stdio {
        command: String,
        #[serde(default)]
        args: Vec<String>,
    },
}

impl TryFrom<ServerWire> for McpServerSpec {
    type Error = String;

    fn try_from(wire: ServerWire) -> Result<McpServerSpec, String> {
        match wire {
            ServerWire::Http {
                url: Some(url),
                url_from_config: None,
            } => Ok(McpServerSpec::Http { url }),
            ServerWire::Http {
                url: None,
                url_from_config: Some(key),
            } => Ok(McpServerSpec::HttpFromConfig { key }),
            ServerWire::Http { .. } => {
                Err("an http server has exactly one of url and urlFromConfig".into())
            }
            ServerWire::Stdio { command, args } => Ok(McpServerSpec::Stdio { command, args }),
        }
    }
}

impl From<McpServerSpec> for ServerWire {
    fn from(spec: McpServerSpec) -> ServerWire {
        match spec {
            McpServerSpec::Http { url } => ServerWire::Http {
                url: Some(url),
                url_from_config: None,
            },
            McpServerSpec::HttpFromConfig { key } => ServerWire::Http {
                url: None,
                url_from_config: Some(key),
            },
            McpServerSpec::Stdio { command, args } => ServerWire::Stdio { command, args },
        }
    }
}

/// At most this many bytes in a setting's key that `urlFromConfig` names.
pub const MAX_CONFIG_KEY_BYTES: usize = 64;

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
        if !PROTOCOLS.contains(&self.manifest.as_str()) {
            return fail(format!(
                "manifest is {:?}, not one of {PROTOCOLS:?}",
                self.manifest
            ));
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
            (Some(spec), true) => {
                spec.validate()?;
                if let McpServerSpec::HttpFromConfig { key } = &spec.server {
                    check_url_setting(self.config.as_ref(), key)?;
                }
            }
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
                if self.manifest == PROTOCOL
                    && let Some(kind) = spec.kinds.iter().find(|kind| !kind.is_github())
                {
                    return fail(format!(
                        "events.kinds lists {}, which needs obi-plugin/0.2",
                        kind.as_str()
                    ));
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
    /// The server agents get with the owner's settings `config`: a server given in the manifest
    /// as it is, and one whose URL is a setting ([`McpServerSpec::HttpFromConfig`]) as an
    /// [`McpServerSpec::Http`] with that setting's URL, which must be a string that holds to the
    /// rule for an `http` URL in the manifest (http or https, a host, no login, no query string
    /// or fragment, no space or invisible character). [`PluginError::Config`] says why not.
    pub fn server_for(&self, config: &Value) -> Result<McpServerSpec, PluginError> {
        match &self.server {
            McpServerSpec::HttpFromConfig { key } => {
                let Some(url) = config.get(key).and_then(Value::as_str) else {
                    return Err(PluginError::Config(format!(
                        "the setting {key:?} (the MCP server's URL) is missing or not a string"
                    )));
                };
                check_http_url(url, &format!("the setting {key:?}"))
                    .map_err(PluginError::Config)?;
                Ok(McpServerSpec::Http {
                    url: url.to_owned(),
                })
            }
            server => Ok(server.clone()),
        }
    }

    fn validate(&self) -> Result<(), PluginError> {
        let fail = |reason: String| Err(PluginError::Manifest(reason));
        match &self.server {
            McpServerSpec::Http { url } => {
                check_http_url(url, "agentMcp.server.url").map_err(PluginError::Manifest)?;
            }
            McpServerSpec::HttpFromConfig { key } => {
                let plain = (1..=MAX_CONFIG_KEY_BYTES).contains(&key.len())
                    && key.starts_with(|c: char| c.is_ascii_alphabetic())
                    && key
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'));
                if !plain {
                    return fail(format!(
                        "agentMcp.server.urlFromConfig {key:?} is not a setting's key (1 to {MAX_CONFIG_KEY_BYTES} ASCII letters, digits, '_' and '-', starting with a letter)"
                    ));
                }
            }
            McpServerSpec::Stdio { command, args } => {
                if command.trim().is_empty() {
                    return fail("agentMcp.server.command is empty".into());
                }
                // The command and its arguments are checked alike: a command line put in
                // `command` (`npx mcp-remote https://u:p@host/mcp`) gets no pass. Each problem
                // names the word by its place, not its text: the text may be the very secret,
                // and this message reaches logs.
                let words: Vec<&str> = std::iter::once(command.as_str())
                    .chain(args.iter().map(String::as_str))
                    .collect();
                let place = |i: usize| {
                    if i == 0 {
                        "agentMcp.server.command".to_string()
                    } else {
                        format!("agentMcp.server.args[{}]", i - 1)
                    }
                };
                for (i, word) in words.iter().enumerate() {
                    if word.chars().any(is_hidden) {
                        return fail(format!(
                            "{} has a control character or an invisible format character",
                            place(i)
                        ));
                    }
                    // Raw, shell-split and escape-decoded: a login hidden as `pass"@"host` or
                    // `\u0040` is the same URL once the argument is read the way a shell reads it.
                    match url_problem_in_forms(word) {
                        Some(UrlProblem::Login) => {
                            return fail(format!(
                                "{} passes a URL with a login; logins are the server's own, never in the manifest",
                                place(i)
                            ));
                        }
                        Some(UrlProblem::QueryOrFragment) => {
                            return fail(format!(
                                "{} passes a URL with a query string or a fragment, where a secret could ride; the manifest takes none",
                                place(i)
                            ));
                        }
                        None => {}
                    }
                }
                if let Some(i) = passes_credential(&words) {
                    return fail(format!(
                        "{} passes a credential; logins are the server's own, never in the manifest",
                        place(i)
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

/// The rule for an `http` MCP server's URL, in the manifest or in the owner's settings: http
/// or https, with a host, and no login (`user@`), query string or fragment, where a secret could
/// ride, and no space, control character or invisible character. `field` names where it is.
fn check_http_url(url: &str, field: &str) -> Result<(), String> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"));
    let Some(rest) = rest else {
        return Err(format!("{field} {url:?} is not an http or https URL"));
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.is_empty() {
        return Err(format!("{field} {url:?} has no host"));
    }
    if authority.contains('@') {
        return Err(format!(
            "{field} carries a login; logins are the server's own, never in the manifest or the settings"
        ));
    }
    if rest.contains(['?', '#']) {
        return Err(format!(
            "{field} has a query string or a fragment, where a secret could ride; it takes none"
        ));
    }
    if url.chars().any(|c| c.is_whitespace() || is_hidden(c)) {
        return Err(format!(
            "{field} {} has a space, a control character or an invisible format character",
            url.escape_unicode()
        ));
    }
    Ok(())
}

/// The manifest's `config` schema for a server URL that is the owner's setting `key`
/// (docs/ARCHITECTURE.md 5.2): an object schema that requires `key`, and whose `properties`
/// give `key` the type `string` and no `default`, so the plug-in can't be enabled before the
/// owner gives the URL.
fn check_url_setting(config: Option<&Value>, key: &str) -> Result<(), PluginError> {
    let fail = |reason: String| {
        Err(PluginError::Manifest(format!(
            "agentMcp.server.urlFromConfig is {key:?}, but {reason}"
        )))
    };
    let Some(schema) = config.and_then(Value::as_object) else {
        return fail("there is no config schema".into());
    };
    if schema.get("type").and_then(Value::as_str) != Some("object") {
        return fail("the config schema's type is not \"object\"".into());
    }
    let required = schema
        .get("required")
        .and_then(Value::as_array)
        .is_some_and(|required| required.iter().any(|k| k.as_str() == Some(key)));
    if !required {
        return fail("the config schema doesn't require it".into());
    }
    let Some(property) = schema
        .get("properties")
        .and_then(|properties| properties.get(key))
        .and_then(Value::as_object)
    else {
        return fail("the config schema's properties don't give it".into());
    };
    if property.get("type").and_then(Value::as_str) != Some("string") {
        return fail("the config schema doesn't make it a string".into());
    }
    if property.contains_key("default") {
        return fail(
            "the config schema gives it a default; the owner gives the URL, there is none to fall back on"
                .into(),
        );
    }
    Ok(())
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

/// The place of the first word (the command, then each argument) that passes a credential
/// the usual ways: an option or variable whose name names one (`--token x`, `--accessToken x`,
/// `--api-key=x`, `--pat x`, `--github-pat x`, `--auth-header x`, `--bearer x`, `--jwt x`,
/// `--passphrase x`, `--creds x`, `TOKEN=x`), an HTTP header or a header blob that carries one
/// (`Authorization:`, `X-Api-Key: x`, `Cookie: x`, `{"X-Api-Key":"x"}`, `["X-Api-Key","x"]`,
/// `curl -H 'X-Api-Key: x'`, `--header X-Api-Key x`, or a `Bearer `
/// value), or a value that starts the way well-known tokens do (`ghp_`, `github_pat_`, `xoxb-`,
/// `glpat-`, `sk-ant-` and the like).
///
/// Each word is read as written, with its backslash escapes decoded (`\"`, `\u004b`), and as
/// JSON when it is JSON (a key or an array's name-and-value pair that names a credential). Each
/// word is also read as a shell line, split into the words the shell would pass, so the same
/// forms inside `sh -c "server --token x"` count too, however the shell line quotes them
/// (`--to''ken x`, `--to\ken x`, `--headers "{\"X-Api-Key\":\"x\"}"`), and so does curl's
/// login (`curl --user alice:x`).
///
/// Goes by names and shapes, so a secret with no telling name or shape (`-t x`) isn't found: a
/// one-letter option means different things to different programs, and refusing every one
/// would refuse ordinary servers.
fn passes_credential(words: &[&str]) -> Option<usize> {
    if let Some(i) = words.iter().position(|word| text_passes_credential(word)) {
        return Some(i);
    }

    // Every word read as a shell line and split into the words the shell would pass (quotes
    // and backslashes taken off, `--to''ken` and `--to\ken` joined into `--token`), each
    // token keeping the place of the word it came from.
    let tokens: Vec<(usize, String)> = words
        .iter()
        .enumerate()
        .flat_map(|(i, word)| shell_words(word).into_iter().map(move |token| (i, token)))
        .filter(|(_, token)| !token.is_empty())
        .collect();
    let header_flags = ["-H", "--header", "--headers", "-header"];
    let mut runs_curl = false;
    for (at, (i, token)) in tokens.iter().enumerate() {
        let i = *i;
        let next = tokens.get(at + 1).map(|(_, next)| next.as_str());
        if text_passes_credential(token) {
            return Some(i);
        }
        // `--token x`, the value the next token, in this word or the next one.
        if token.starts_with('-') && names_credential(token) && next.is_some() {
            return Some(i);
        }
        // `--header X-Api-Key x`: a header's name and its value as tokens of their own.
        let after_header_flag = at > 0 && header_flags.contains(&tokens[at - 1].1.as_str());
        if after_header_flag
            && !token.starts_with('-')
            && !token.contains(':')
            && names_credential(token)
            && next.is_some()
        {
            return Some(i);
        }
        // curl's login: `curl --user alice:s3cret`, `-u alice:s3cret`, `--user=…`, `-ualice:…`.
        // Only after `curl`: elsewhere (`docker run -u node:node`) it is a user and a group.
        if token.rsplit('/').next() == Some("curl") {
            runs_curl = true;
        }
        if runs_curl && curl_login(token, next) {
            return Some(i);
        }
    }
    None
}

/// Whether one word, read as it stands and with its escapes decoded (`\"`, `K`), passes a
/// credential by its name or its shape, or is JSON that does.
fn text_passes_credential(text: &str) -> bool {
    let decoded = decode_escapes(text);
    [text, decoded.as_str()].iter().any(|text| {
        let lower = text.to_ascii_lowercase();
        lower.contains("authorization:")
            || lower.contains("bearer ")
            || looks_like_token(text)
            || field_passes_credential(text)
            || assigns_credential(text)
    }) || serde_json::from_str::<Value>(text.trim())
        .is_ok_and(|value| json_passes_credential(&value))
}

/// Whether a JSON value passes a credential: an object key that names one with a value that
/// isn't empty (`{"X-Api-Key":"x"}`, with the key in any escaped form a JSON parser decodes,
/// like `{"X-Api-Key":"x"}`), a name and its value next to each other in an array
/// (`["X-Api-Key","x"]`, `["--token","x"]`), or a string inside that passes one by itself.
fn json_passes_credential(value: &Value) -> bool {
    let carries = |value: &Value| match value {
        Value::String(text) => !text.is_empty(),
        Value::Number(_) => true,
        _ => false,
    };
    match value {
        Value::Object(fields) => fields.iter().any(|(key, value)| {
            (names_credential(key) && carries(value)) || json_passes_credential(value)
        }),
        Value::Array(items) => {
            items.windows(2).any(|pair| {
                pair[0]
                    .as_str()
                    .is_some_and(|name| !name.contains(':') && names_credential(name))
                    && carries(&pair[1])
            }) || items.iter().any(json_passes_credential)
        }
        Value::String(text) => text_passes_credential(text),
        _ => false,
    }
}

/// Whether `token` (with `next`, the token after it) is curl's login option with a password:
/// `--user alice:s3cret`, `-u alice:s3cret`, `--proxy-user` / `-U` the same, or the value
/// attached (`--user=alice:s3cret`, `-ualice:s3cret`). `alice:` alone has curl ask for the
/// password, so it carries none.
fn curl_login(token: &str, next: Option<&str>) -> bool {
    let with_password = |value: &str| {
        value
            .split_once(':')
            .is_some_and(|(_, password)| !password.is_empty())
    };
    match token {
        "--user" | "-u" | "--proxy-user" | "-U" => next.is_some_and(with_password),
        _ => ["--user=", "--proxy-user=", "-u", "-U"]
            .iter()
            .any(|flag| token.strip_prefix(flag).is_some_and(with_password)),
    }
}

/// The words a POSIX shell would split `line` into: whitespace and `;|&()<>` and backquotes
/// separate words; `'…'` is taken as is; inside `"…"` a backslash escapes `"`, `\`, `$` and
/// a backquote; outside quotes a backslash escapes any character; `$'…'` decodes its escapes;
/// parts written next to each other make one word (`--to''ken` is `--token`). A quote left open
/// runs to the end of the line.
fn shell_words(line: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            c if c.is_whitespace()
                || matches!(c, ';' | '|' | '&' | '(' | ')' | '<' | '>' | '`') =>
            {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            '\\' => {
                in_word = true;
                if let Some(next) = chars.next().filter(|next| *next != '\n') {
                    word.push(next);
                }
            }
            '\'' => {
                in_word = true;
                for next in chars.by_ref() {
                    if next == '\'' {
                        break;
                    }
                    word.push(next);
                }
            }
            '"' => {
                in_word = true;
                while let Some(next) = chars.next() {
                    match next {
                        '"' => break,
                        '\\' => match chars.peek().copied() {
                            Some(escaped @ ('"' | '\\' | '$' | '`')) => {
                                chars.next();
                                word.push(escaped);
                            }
                            Some('\n') => {
                                chars.next();
                            }
                            _ => word.push('\\'),
                        },
                        _ => word.push(next),
                    }
                }
            }
            '$' if chars.peek() == Some(&'\'') => {
                chars.next();
                in_word = true;
                let mut quoted = String::new();
                while let Some(next) = chars.next() {
                    match next {
                        '\'' => break,
                        '\\' => {
                            quoted.push('\\');
                            if let Some(escaped) = chars.next() {
                                quoted.push(escaped);
                            }
                        }
                        _ => quoted.push(next),
                    }
                }
                word.push_str(&decode_escapes(&quoted));
            }
            _ => {
                in_word = true;
                word.push(c);
            }
        }
    }
    if in_word {
        words.push(word);
    }
    words
}

/// `text` with the backslash escapes of JSON, JSON5, JavaScript and `$'…'` decoded: `\uXXXX`
/// (and surrogate pairs), `\u{X…}`, `\xHH`, and a backslash before any other character taken
/// off (`\"` is `"`, `\\` is `\`). An escape that doesn't decode is left as written.
fn decode_escapes(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let hex = |digits: &[char]| -> Option<u32> {
        let digits: String = digits.iter().collect();
        if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        u32::from_str_radix(&digits, 16).ok()
    };
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    while at < chars.len() {
        if chars[at] != '\\' || at + 1 == chars.len() {
            out.push(chars[at]);
            at += 1;
            continue;
        }
        let escape = chars[at + 1];
        // A code point and how many characters its escape takes, from the backslash on.
        let decoded: Option<(u32, usize)> = match escape {
            'u' if chars.get(at + 2) == Some(&'{') => chars[at + 3..]
                .iter()
                .position(|c| *c == '}')
                .and_then(|close| {
                    hex(&chars[at + 3..at + 3 + close]).map(|code| (code, close + 4))
                }),
            'u' => chars.get(at + 2..at + 6).and_then(hex).map(|high| {
                // A high surrogate followed by `\uDC00`-`\uDFFF` is one code point.
                let low = (chars.get(at + 6..at + 8) == Some(&['\\', 'u']))
                    .then(|| chars.get(at + 8..at + 12).and_then(hex))
                    .flatten()
                    .filter(|low| {
                        (0xD800..0xDC00).contains(&high) && (0xDC00..0xE000).contains(low)
                    });
                match low {
                    Some(low) => (0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00), 12),
                    None => (high, 6),
                }
            }),
            'x' => chars
                .get(at + 2..at + 4)
                .and_then(hex)
                .map(|code| (code, 4)),
            _ => None,
        };
        match decoded.and_then(|(code, len)| char::from_u32(code).map(|c| (c, len))) {
            Some((c, len)) => {
                out.push(c);
                at += len;
            }
            None if matches!(escape, 'u' | 'x') => {
                out.push('\\');
                at += 1;
            }
            None => {
                out.push(escape);
                at += 2;
            }
        }
    }
    out
}

/// Whether `text` is `NAME=value` with a name that names a credential and a value that isn't
/// empty, or with a value that starts the way a well-known token does.
fn assigns_credential(text: &str) -> bool {
    // Each comma-separated entry, not only the first `=`: `Accept=text/html,TOKEN=abc`.
    text.split(',')
        .any(|part| match part.trim().split_once('=') {
            Some((name, value)) => {
                let value = value.trim();
                (names_credential(name.trim()) && !value.is_empty()) || looks_like_token(value)
            }
            None => false,
        })
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

/// The schemes WHATWG URL parsers (Node's `new URL`, which `mcp-remote` uses; browsers) call
/// special: after one of them, any run of `/` and `\`, or none, leads to the host, so
/// `https:\\user:pass@host`, `https:user:pass@host` and `https:host/mcp?k=x` are all URLs with
/// a login or a query.
const SPECIAL_SCHEMES: [&str; 6] = ["http", "https", "ws", "wss", "ftp", "file"];

/// The problem with the first URL in `arg` that has one: a login (`user:pass@`) or a query
/// string or fragment (`?key=…`, `#token=…`).
///
/// A URL is a scheme and a colon. After a special scheme ([`SPECIAL_SCHEMES`], in any case,
/// also as the last part of one like `git+https`), the host follows any run of `/` and `\` or
/// none, the way a WHATWG parser reads it; after any other scheme, it follows two of them
/// (`postgres://`, `postgres:\\`), and without them the text is not taken as a URL
/// (`Accept: text/html`, `github:owner/repo#v1`). A URL ends at a space or a quote, so one inside
/// a shell line (`-c "curl 'https://u:p@x'"`) counts too.
/// `url_in_arg_problem` on the argument as written, on each word a shell would pass, and on
/// each of those with backslash escapes decoded.
fn url_problem_in_forms(arg: &str) -> Option<UrlProblem> {
    let decoded = decode_escapes(arg);
    let mut forms = vec![arg.to_string()];
    if decoded != arg {
        forms.push(decoded.clone());
    }
    for source in [arg.to_string(), decoded] {
        for token in shell_words(&source) {
            if !forms.iter().any(|have| have == &token) {
                forms.push(token.clone());
            }
            let again = decode_escapes(&token);
            if again != token && !forms.iter().any(|have| have == &again) {
                forms.push(again);
            }
        }
    }
    forms.iter().find_map(|form| url_in_arg_problem(form))
}

fn url_in_arg_problem(arg: &str) -> Option<UrlProblem> {
    let is_scheme_char = |c: char| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.');
    for (colon, _) in arg.match_indices(':') {
        let run_start = arg[..colon]
            .rfind(|c: char| !is_scheme_char(c))
            .map_or(0, |i| i + 1);
        // A scheme starts with a letter: `--https:` and `1https:` read as `https:`.
        let scheme = arg[run_start..colon]
            .trim_start_matches(|c: char| !c.is_ascii_alphabetic())
            .to_ascii_lowercase();
        if scheme.is_empty() {
            continue;
        }
        let special = SPECIAL_SCHEMES
            .iter()
            .any(|s| scheme == *s || scheme.ends_with(&format!("+{s}")));
        let body = &arg[colon + 1..];
        let body_end = body
            .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '`' | '<' | '>'))
            .unwrap_or(body.len());
        let body = &body[..body_end];
        let is_slash = |c: char| matches!(c, '/' | '\\');
        let rest = if special {
            body.trim_start_matches(is_slash)
        } else {
            let mut chars = body.chars();
            match (chars.next(), chars.next()) {
                (Some(a), Some(b)) if is_slash(a) && is_slash(b) => &body[2..],
                _ => continue,
            }
        };
        let authority = rest.split(['/', '\\', '?', '#']).next().unwrap_or("");
        if authority.contains('@') {
            return Some(UrlProblem::Login);
        }
        if rest.contains(['?', '#']) {
            return Some(UrlProblem::QueryOrFragment);
        }
    }
    None
}

/// Whether `c` is a control character (Unicode `Cc`), an invisible format character (Unicode
/// `Cf`: soft hyphen, zero-width space and joiners, bidirectional overrides and isolates, word
/// joiner, byte order mark, tags and the like), any other code point Unicode says to show as
/// nothing (`Default_Ignorable_Code_Point`: the combining grapheme joiner U+034F, variation
/// selectors like U+FE0F, Hangul fillers like U+3164, …), or a line or paragraph separator
/// (U+2028, U+2029). Such a character changes how text shows or reads without being seen:
/// `--to\u{200B}ken` or `--to\u{34F}ken` reads as `--token` to the owner and as some other name
/// to the checks, and U+202E turns what follows around.
fn is_hidden(c: char) -> bool {
    // Unicode 16.0's `Cf` and `Default_Ignorable_Code_Point` code points, and `Zl` and `Zp`.
    const HIDDEN: [(u32, u32); 26] = [
        (0x00AD, 0x00AD),
        (0x034F, 0x034F),
        (0x0600, 0x0605),
        (0x061C, 0x061C),
        (0x06DD, 0x06DD),
        (0x070F, 0x070F),
        (0x0890, 0x0891),
        (0x08E2, 0x08E2),
        (0x115F, 0x1160),
        (0x17B4, 0x17B5),
        (0x180B, 0x180F),
        (0x200B, 0x200F),
        (0x2028, 0x2029),
        (0x202A, 0x202E),
        (0x2060, 0x206F),
        (0x3164, 0x3164),
        (0xFE00, 0xFE0F),
        (0xFEFF, 0xFEFF),
        (0xFFA0, 0xFFA0),
        (0xFFF0, 0xFFFB),
        (0x110BD, 0x110BD),
        (0x110CD, 0x110CD),
        (0x13430, 0x1343F),
        (0x1BCA0, 0x1BCA3),
        (0x1D173, 0x1D17A),
        (0xE0000, 0xE0FFF),
    ];
    let code = u32::from(c);
    c.is_control()
        || HIDDEN
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
        "passphrase",
        "apikey",
        "credential",
        "credentials",
        "creds",
        "cookie",
        "authorization",
        "bearer",
        "jwt",
    ];
    let endings = [
        "token",
        "secret",
        "password",
        "passwd",
        "passphrase",
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
