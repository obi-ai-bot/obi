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
    /// `transcript` events, many to a job (each tool call's start and end), on a channel of
    /// their own: a busy job never pushes another event out of a slow listener's backlog.
    transcripts: broadcast::Sender<Event>,
}

impl Events {
    pub fn new() -> Events {
        let (sender, _) = broadcast::channel(1024);
        let (transcripts, _) = broadcast::channel(1024);
        Events {
            sender,
            transcripts,
        }
    }

    pub fn send(&self, name: &'static str, data: Value) {
        let channel = if name == "transcript" {
            &self.transcripts
        } else {
            &self.sender
        };
        // Nobody listening is fine.
        let _ = channel.send(Event { name, data });
    }

    /// Every event but `transcript` ones.
    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.sender.subscribe()
    }

    /// `transcript` events only (`GET /v1/events` follows both).
    pub fn subscribe_transcripts(&self) -> broadcast::Receiver<Event> {
        self.transcripts.subscribe()
    }
}

impl Default for Events {
    fn default() -> Events {
        Events::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn transcripts_never_crowd_the_other_events() {
        let events = Events::new();
        let mut others = events.subscribe();
        let mut transcripts = events.subscribe_transcripts();
        for n in 0..2000 {
            events.send("transcript", json!({"n": n}));
        }
        events.send("job", json!({"id": "j"}));
        assert_eq!(others.try_recv().unwrap().name, "job");
        assert!(matches!(
            transcripts.try_recv(),
            Err(broadcast::error::TryRecvError::Lagged(_))
        ));
    }
}
