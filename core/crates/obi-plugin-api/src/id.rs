use std::fmt;

use serde::{Deserialize, Serialize};

use crate::PluginError;

/// A plug-in's id: one or more lower-case letters, digits and hyphens (docs/ARCHITECTURE.md
/// 5.2), starting with a letter or a digit. It is also the plug-in's folder name under
/// `home/plugins/` and `home/plugin-data/`, which is why nothing else (no `.`, no `/`) is
/// allowed, and it ends up in the sandbox's command lines (bubblewrap's or `sandbox-exec`'s
/// arguments), which is why it never starts with a hyphen that could be read as an option. A
/// [`RESERVED`] id is refused.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct PluginId(String);

/// Ids no plug-in may take: `oby` is the server name of obid's connected-app broker in an agent's
/// MCP config, and a plug-in's tools are `mcp__<plugin id>__<tool>` there too.
pub const RESERVED: &[&str] = &["oby"];

impl PluginId {
    pub fn new(id: impl Into<String>) -> Result<PluginId, PluginError> {
        let id = id.into();
        let valid = id
            .bytes()
            .next()
            .is_some_and(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
            && id
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
        if valid && !RESERVED.contains(&id.as_str()) {
            Ok(PluginId(id))
        } else {
            Err(PluginError::InvalidId(id))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for PluginId {
    type Error = PluginError;

    fn try_from(id: String) -> Result<PluginId, PluginError> {
        PluginId::new(id)
    }
}

impl From<PluginId> for String {
    fn from(id: PluginId) -> String {
        id.0
    }
}

impl AsRef<str> for PluginId {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for PluginId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::str::FromStr for PluginId {
    type Err = PluginError;

    fn from_str(id: &str) -> Result<PluginId, PluginError> {
        PluginId::new(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `oby` is the connected-app broker's server name in an agent's MCP config
    /// (`mcp__oby__<connection>_<tool>`, obid's connections.rs): no plug-in may take it.
    #[test]
    fn the_brokers_name_is_no_plugins_id() {
        for id in ["tetrix", "oby-mail", "obyx", "0x"] {
            assert!(PluginId::new(id).is_ok(), "{id}");
        }
        for id in ["oby", "", "-oby", "Oby", "oby/x"] {
            assert!(PluginId::new(id).is_err(), "{id}");
        }
        assert!(serde_json::from_str::<PluginId>("\"oby\"").is_err());
    }
}
