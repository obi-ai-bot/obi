//! Remembered decisions (docs/runner-api.md, "obid only: remembered decisions"; spec `protocol.md`
//! section 11, step 5): what the owner decided once, applied after that without asking. Only an
//! inbox answer makes one; nothing another Obi sends can. Kept in `home/decisions.json` (0600).

use std::path::{Path, PathBuf};

use obi_protocol::time;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::store;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    /// `d-` and 12 lower-case hex.
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub from_owner: String,
    /// The exact repository, or `*`.
    pub repo: String,
    /// `accept` or `decline`.
    pub decision: String,
    pub created: i64,
    pub inbox_item: String,
    pub uses: u64,
    pub last_used: Option<i64>,
}

impl Decision {
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "type": self.kind,
            "fromOwner": self.from_owner,
            "repo": self.repo,
            "decision": self.decision,
            "created": time::format(self.created),
            "source": {"inboxItem": self.inbox_item},
            "uses": self.uses,
            "lastUsed": self.last_used.map(time::format),
        })
    }
}

/// A new decision id: `d-` and 12 lower-case hex.
pub fn new_id() -> String {
    let mut bytes = [0u8; 6];
    getrandom::fill(&mut bytes).expect("the system's random source works");
    format!("d-{}", hex::encode(bytes))
}

/// The decision that covers a request of `kind` from an Obi of `from_owner` on `repo` (`None` for
/// a request with no repository): one for that exact repository wins over one for `*`.
pub fn covering<'a>(
    decisions: &'a [Decision],
    kind: &str,
    from_owner: &str,
    repo: Option<&str>,
) -> Option<&'a Decision> {
    let same = |d: &&Decision| d.kind == kind && d.from_owner == from_owner;
    repo.and_then(|repo| decisions.iter().filter(same).find(|d| d.repo == repo))
        .or_else(|| decisions.iter().filter(same).find(|d| d.repo == "*"))
}

/// Where the decisions are kept.
pub struct Decisions {
    path: PathBuf,
}

impl Decisions {
    pub fn open(home: &Path) -> Decisions {
        Decisions {
            path: home.join("decisions.json"),
        }
    }

    pub fn load(&self) -> Vec<Decision> {
        match std::fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                tracing::error!("{} doesn't read: {e}", self.path.display());
                Vec::new()
            }),
            Err(_) => Vec::new(),
        }
    }

    pub fn save(&self, decisions: &[Decision]) -> std::io::Result<()> {
        let text = serde_json::to_vec_pretty(decisions).map_err(std::io::Error::other)?;
        store::write_private(&self.path, &text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decision(id: &str, repo: &str, decision: &str) -> Decision {
        Decision {
            id: id.into(),
            kind: "review_request".into(),
            from_owner: "ernesto".into(),
            repo: repo.into(),
            decision: decision.into(),
            created: 0,
            inbox_item: "obi-x".into(),
            uses: 0,
            last_used: None,
        }
    }

    #[test]
    fn an_exact_repository_beats_every_repository() {
        let all = vec![
            decision("d-000000000001", "*", "decline"),
            decision("d-000000000002", "obi-e2e/fixture-app", "accept"),
        ];
        let found = covering(
            &all,
            "review_request",
            "ernesto",
            Some("obi-e2e/fixture-app"),
        );
        assert_eq!(found.unwrap().id, "d-000000000002");
        let found = covering(&all, "review_request", "ernesto", Some("other/repo"));
        assert_eq!(found.unwrap().id, "d-000000000001");
        assert!(
            covering(
                &all,
                "review_request",
                "wellington",
                Some("obi-e2e/fixture-app")
            )
            .is_none()
        );
        assert!(covering(&all, "question", "ernesto", None).is_none());
        assert!(covering(&all[1..], "review_request", "ernesto", None).is_none());
    }

    #[test]
    fn ids_and_json() {
        let id = new_id();
        assert_eq!(id.len(), 14);
        assert!(
            id[2..]
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        );
        let shown = decision(&id, "obi-e2e/fixture-app", "accept").to_json();
        assert_eq!(shown["source"], json!({"inboxItem": "obi-x"}));
        assert_eq!(shown["lastUsed"], Value::Null);
        assert_eq!(shown["fromOwner"], "ernesto");
    }
}
