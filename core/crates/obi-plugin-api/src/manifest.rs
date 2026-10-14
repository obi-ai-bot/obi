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
    /// The only tools agents may call; the job's permission gate refuses every other.
    pub allowed_tools: Vec<String>,
}

/// The MCP server an `agent-mcp` plug-in gives agents. It has no field for headers or an
/// environment, so a server that needs a secret in its configuration can't be described: its
/// login is its own (OAuth in its own store), never a vault secret. A URL with a user or a
/// password in it is refused for the same reason.
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
            }
            McpServerSpec::Stdio { command, .. } => {
                if command.trim().is_empty() {
                    return fail("agentMcp.server.command is empty".into());
                }
            }
        }
        if self.allowed_tools.is_empty() {
            return fail("agentMcp.allowedTools is empty".into());
        }
        if self.allowed_tools.iter().any(|tool| tool.trim().is_empty()) {
            return fail("agentMcp.allowedTools lists an empty name".into());
        }
        if !unique(&self.allowed_tools) {
            return fail("agentMcp.allowedTools lists a tool twice".into());
        }
        Ok(())
    }
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
