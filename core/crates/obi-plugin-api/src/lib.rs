//! Obi's plug-in boundary as types: the kinds, the manifest (`obi-plugin.json`), the wire
//! protocol `obi-plugin/0.1` and the traits a plug-in is seen through (docs/ARCHITECTURE.md,
//! section 5). The host (`obi-plugin-host`) adapts out-of-process plug-ins to these traits;
//! built-in plug-ins may implement them in process later.
//!
//! Everything a plug-in sends is data: context items and events are quoted to agents and shown
//! to the owner, never placed in a prompt as instructions (docs/ARCHITECTURE.md, section 4).

mod error;
mod id;
pub mod manifest;
pub mod rpc;
mod types;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

pub use error::PluginError;
pub use id::PluginId;
pub use manifest::{AgentMcpSpec, EventsSpec, MANIFEST_FILE, Manifest, McpServerSpec, RunSpec};
pub use types::{
    ContextItem, ContextJob, ContextRequest, DEFAULT_MAX_BYTES, Event, EventData, EventKind,
    EventSubject, MAX_CONTEXT_ITEMS, PluginEvent, PluginState, PluginStatus, Purpose, limit_items,
};

/// The protocol both the manifest and the wire speak.
pub const PROTOCOL: &str = "obi-plugin/0.1";

/// What a plug-in gives (docs/ARCHITECTURE.md 5.1). On the wire and in the manifest: `context`,
/// `events`, `agent-mcp`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    Context,
    Events,
    AgentMcp,
}

/// A plug-in that gives context items for a job.
#[async_trait]
pub trait ContextProvider: Send + Sync {
    async fn query(&self, request: ContextRequest) -> Result<Vec<ContextItem>, PluginError>;
}

/// A plug-in that gives events from outside.
#[async_trait]
pub trait EventSource: Send + Sync {
    /// Runs until shutdown, sending each event to `sink`.
    async fn run(&self, sink: EventSink) -> Result<(), PluginError>;
}

/// A plug-in that gives an MCP server the job's agents may call, limited to the listed tools.
pub trait AgentMcpProvider: Send + Sync {
    fn server(&self) -> &McpServerSpec;
    fn allowed_tools(&self) -> &[String];
}

/// Where an [`EventSource`] sends its events. The host makes one per plug-in and checks every
/// event it receives (the manifest's `events.kinds`, a repeated `id`) before it reaches `obid`.
#[derive(Clone, Debug)]
pub struct EventSink {
    sender: mpsc::Sender<Event>,
}

impl EventSink {
    pub fn new(sender: mpsc::Sender<Event>) -> EventSink {
        EventSink { sender }
    }

    /// A sink and the receiver its events arrive on, holding at most `capacity` unread events.
    pub fn channel(capacity: usize) -> (EventSink, mpsc::Receiver<Event>) {
        let (sender, receiver) = mpsc::channel(capacity);
        (EventSink { sender }, receiver)
    }

    /// Sends one event, waiting while the receiver is full. Fails with
    /// [`PluginError::Stopped`] once the host stopped listening.
    pub async fn send(&self, event: Event) -> Result<(), PluginError> {
        self.sender
            .send(event)
            .await
            .map_err(|_| PluginError::Stopped)
    }

    /// Whether the host stopped listening: an [`EventSource`] may end its `run` then.
    pub fn is_closed(&self) -> bool {
        self.sender.is_closed()
    }
}
