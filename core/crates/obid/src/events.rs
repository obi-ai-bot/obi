//! What `GET /v1/events` sends: one Server-Sent Event per change (docs/runner-api.md,
//! "GET /v1/events"), to every app that follows.

use serde_json::Value;
use tokio::sync::broadcast;

/// One event: its name (`job`, `inbox`, `accounts`, …) and its data.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub name: &'static str,
    pub data: Value,
}

/// Where events go out. An app that falls too far behind loses the oldest and fetches again
/// (the document says to fetch after every reconnect).
#[derive(Clone)]
pub struct Events {
    sender: broadcast::Sender<Event>,
}

impl Events {
    pub fn new() -> Events {
        let (sender, _) = broadcast::channel(1024);
        Events { sender }
    }

    pub fn send(&self, name: &'static str, data: Value) {
        // Nobody listening is fine.
        let _ = self.sender.send(Event { name, data });
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.sender.subscribe()
    }
}

impl Default for Events {
    fn default() -> Events {
        Events::new()
    }
}
