//! The plug-in host: all `obid` calls to find, start, sandbox and talk to plug-ins
//! (docs/ARCHITECTURE.md 5.3 and 5.5). `obid` makes one [`PluginHost`] at start, takes its event
//! receiver once, and calls `shutdown` when it stops.
//!
//! This version finds no plug-ins: `list` is empty, `context` and `agent_mcp_servers` give
//! nothing, `set_enabled` answers [`PluginError::Unknown`] for every id, and the receiver from
//! `take_events` yields nothing until `shutdown` ends it. Discovery, the sandbox (bubblewrap on
//! Linux, Seatbelt on macOS) and the lifecycle come behind these same signatures.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use tokio::sync::mpsc;

pub use obi_plugin_api as api;
use obi_plugin_api::{ContextItem, ContextRequest, McpServerSpec, PluginError, PluginEvent};
pub use obi_plugin_api::{PluginId, PluginStatus};

/// How many accepted events wait for `obid` before the plug-ins sending them wait too.
const EVENT_BUFFER: usize = 256;

/// The plug-ins `obid` found in `home/plugins/`, and the ones it runs.
#[derive(Debug)]
pub struct PluginHost {
    /// `obid`'s home: plug-ins live in `home/plugins/<id>/`, their data in
    /// `home/plugin-data/<id>/`, and which are enabled in `home/plugins.json`.
    #[allow(dead_code)] // read once discovery comes
    home: PathBuf,
    events: Mutex<Events>,
}

/// The one channel every plug-in's accepted events go to.
#[derive(Debug)]
struct Events {
    /// Dropped at shutdown, which is what ends the receiver.
    sender: Option<mpsc::Sender<PluginEvent>>,
    /// Handed over by the first `take_events`.
    receiver: Option<mpsc::Receiver<PluginEvent>>,
}

impl PluginHost {
    /// Discovers the plug-ins in `home/plugins/` and starts the enabled ones. This version finds
    /// none, so it starts none.
    pub async fn start(home: &Path) -> Result<PluginHost, PluginError> {
        let (sender, receiver) = mpsc::channel(EVENT_BUFFER);
        Ok(PluginHost {
            home: home.to_path_buf(),
            events: Mutex::new(Events {
                sender: Some(sender),
                receiver: Some(receiver),
            }),
        })
    }

    /// Every plug-in found, enabled or not: `GET /v1/obid/plugins`.
    pub fn list(&self) -> Vec<PluginStatus> {
        Vec::new()
    }

    /// Enables or disables one plug-in, with the owner's settings when given:
    /// `PUT /v1/obid/plugins/{id}`. [`PluginError::Unknown`] is that route's `404`,
    /// [`PluginError::Config`] its `422`.
    pub async fn set_enabled(
        &self,
        id: &PluginId,
        enabled: bool,
        config: Option<serde_json::Value>,
    ) -> Result<PluginStatus, PluginError> {
        let _ = (enabled, config);
        Err(PluginError::Unknown(id.clone()))
    }

    /// Asks every ready context plug-in, each answer held to `obi-plugin/0.1`'s limits. Never
    /// fails: a plug-in that fails or is late gives nothing, and the job goes on.
    pub async fn context(&self, request: ContextRequest) -> Vec<(PluginId, Vec<ContextItem>)> {
        let _ = request;
        Vec::new()
    }

    /// The MCP server of every ready `agent-mcp` plug-in, with the only tools agents may call.
    pub fn agent_mcp_servers(&self) -> Vec<(PluginId, McpServerSpec, Vec<String>)> {
        Vec::new()
    }

    /// The receiver every accepted event from every plug-in arrives on: `Some` on the first call
    /// only, `None` after, so no event is split between two consumers. It ends (`recv` gives
    /// `None`) only after [`PluginHost::shutdown`].
    pub fn take_events(&self) -> Option<tokio::sync::mpsc::Receiver<PluginEvent>> {
        self.lock_events().receiver.take()
    }

    /// Stops every plug-in and ends the event receiver. Calling it again does nothing.
    pub async fn shutdown(&self) {
        self.lock_events().sender = None;
    }

    fn lock_events(&self) -> MutexGuard<'_, Events> {
        // Nothing panics while holding the lock, so a poisoned lock still holds sound data.
        self.events
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}
