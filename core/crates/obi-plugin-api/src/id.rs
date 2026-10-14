use std::fmt;

use serde::{Deserialize, Serialize};

use crate::PluginError;

/// A plug-in's id: one or more lower-case letters, digits and hyphens (docs/ARCHITECTURE.md
/// 5.2). It is also the plug-in's folder name under `home/plugins/` and `home/plugin-data/`,
/// which is why nothing else (no `.`, no `/`) is allowed.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct PluginId(String);

impl PluginId {
    pub fn new(id: impl Into<String>) -> Result<PluginId, PluginError> {
        let id = id.into();
        let valid = !id.is_empty()
            && id
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
        if valid {
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
