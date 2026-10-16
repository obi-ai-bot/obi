//! An exchange: one request and its replies, as this Obi sees it (docs/runner-api.md, "obid only:
//! Obi-to-Obi exchanges"). Kept one file per exchange in `home/exchanges/` (0600).

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::store;

/// One envelope sent or received in an exchange, exactly as signed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Message {
    /// `sent` or `received`.
    pub direction: String,
    /// The Sphere's audit seq, when known.
    pub seq: Option<u64>,
    /// When the Sphere recorded it (`recorded_at`, `relayed_at`).
    pub at: String,
    pub envelope: Value,
}

/// An exchange as obid keeps it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Exchange {
    pub correlation_id: String,
    /// `outgoing` or `incoming`.
    pub direction: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub peer: String,
    pub peer_owner: Option<String>,
    pub state: String,
    pub decided_by: Option<String>,
    pub rule: Option<String>,
    pub inbox_item: Option<String>,
    pub job: Option<String>,
    pub publish_scan: Option<Value>,
    pub messages: Vec<Message>,
    pub result: Option<Value>,
    pub error: Option<String>,
    /// Seconds since the epoch.
    pub created: i64,
    pub updated: i64,
    /// The request, whatever its direction: the first message.
    pub request: Value,
    /// Replies built and signed, waiting to be sent, oldest first. Never in the API's answer.
    #[serde(default)]
    pub outbox: Vec<Value>,
}

impl Exchange {
    /// A new exchange for `request`.
    pub fn new(
        direction: &str,
        request: Value,
        peer: String,
        peer_owner: Option<String>,
    ) -> Exchange {
        let now = obi_protocol::time::now();
        Exchange {
            correlation_id: request["correlation_id"].as_str().unwrap_or("").to_owned(),
            direction: direction.to_owned(),
            kind: request["type"].as_str().unwrap_or("").to_owned(),
            peer,
            peer_owner,
            state: String::new(),
            decided_by: None,
            rule: None,
            inbox_item: None,
            job: None,
            publish_scan: None,
            messages: Vec::new(),
            result: None,
            error: None,
            created: now,
            updated: now,
            request,
            outbox: Vec::new(),
        }
    }

    /// When the request expires, as seconds since the epoch.
    pub fn expires_at(&self) -> Option<i64> {
        self.request["expires_at"]
            .as_str()
            .and_then(obi_protocol::time::parse)
    }

    /// Whether the exchange has ended: a `decline`, `result` or `answer` was sent or received, or
    /// built and waiting to be sent.
    pub fn ended(&self) -> bool {
        self.messages
            .iter()
            .map(|m| &m.envelope)
            .chain(self.outbox.iter())
            .any(|e| obi_protocol::TERMINAL_TYPES.contains(&e["type"].as_str().unwrap_or("")))
    }

    /// The envelope ids it holds.
    pub fn envelope_ids(&self) -> impl Iterator<Item = &str> {
        self.messages
            .iter()
            .filter_map(|m| m.envelope["id"].as_str())
    }

    /// As the runner API shows it.
    pub fn to_json(&self) -> Value {
        let date = obi_protocol::time::format;
        json!({
            "correlationId": self.correlation_id,
            "direction": self.direction,
            "type": self.kind,
            "peer": self.peer,
            "peerOwner": self.peer_owner,
            "state": self.state,
            "decidedBy": self.decided_by,
            "rule": self.rule,
            "inboxItem": self.inbox_item,
            "job": self.job,
            "publishScan": self.publish_scan,
            "messages": self.messages,
            "result": self.result,
            "error": self.error,
            "created": date(self.created),
            "updated": date(self.updated),
        })
    }
}

/// Where exchanges are kept.
pub struct Exchanges {
    dir: PathBuf,
}

impl Exchanges {
    pub fn open(home: &Path) -> std::io::Result<Exchanges> {
        let dir = home.join("exchanges");
        store::make_private_dir(&dir)?;
        Ok(Exchanges { dir })
    }

    /// A correlation id is a lower-case UUID (the envelope's schema checked it): safe as a name.
    fn path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }

    pub fn save(&self, exchange: &Exchange) -> std::io::Result<()> {
        let text = serde_json::to_vec_pretty(exchange).map_err(std::io::Error::other)?;
        store::write_private(&self.path(&exchange.correlation_id), &text)
    }

    pub fn remove(&self, id: &str) {
        let _ = std::fs::remove_file(self.path(id));
    }

    pub fn load_all(&self) -> Vec<Exchange> {
        store::load_dir(&self.dir)
    }
}
