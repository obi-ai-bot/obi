use crate::PluginId;

/// Why something about a plug-in didn't work. A plug-in's own words (an RPC error's message)
/// are data: shown to the owner as text, never given to a model as instructions.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginError {
    /// Not lower-case letters, digits and hyphens, starting with a letter or a digit.
    #[error(
        "{0:?} is not a plug-in id: only lower-case letters, digits and hyphens, starting with a letter or a digit, and not one Oby keeps for itself (oby)"
    )]
    InvalidId(String),
    /// `obi-plugin.json` doesn't parse or doesn't match docs/ARCHITECTURE.md 5.2.
    #[error("the manifest is invalid: {0}")]
    Manifest(String),
    /// No plug-in with this id was found (`404` on `PUT /v1/obid/plugins/{id}`).
    #[error("no plug-in has the id {0}")]
    Unknown(PluginId),
    /// The owner's settings don't match the manifest's `config` schema (`422`).
    #[error("the settings don't match the plug-in's config schema: {0}")]
    Config(String),
    /// The plug-in's sandbox can't be made on this machine, so it isn't started.
    #[error("can't make the plug-in's sandbox: {0}")]
    Sandbox(String),
    /// A message that isn't `obi-plugin/0.1`: not JSON-RPC 2.0, a method the plug-in may not
    /// call, params or a result of the wrong shape, an event of a kind it didn't declare.
    #[error("protocol error: {0}")]
    Protocol(String),
    /// The plug-in didn't answer `method` in time.
    #[error("no answer to {method} within {seconds} seconds")]
    Timeout { method: String, seconds: u64 },
    /// The plug-in answered with a JSON-RPC error.
    #[error("the plug-in answered error {code}: {message}")]
    Rpc { code: i64, message: String },
    /// Starting it, or reading or writing its pipes or files, failed.
    #[error("{0}")]
    Io(String),
    /// It has stopped, or the host stopped listening.
    #[error("the plug-in has stopped")]
    Stopped,
}

impl From<std::io::Error> for PluginError {
    fn from(error: std::io::Error) -> PluginError {
        PluginError::Io(error.to_string())
    }
}
