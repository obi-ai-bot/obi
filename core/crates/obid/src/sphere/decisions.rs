//! Remembered decisions (docs/runner-api.md, "obid only: remembered decisions"; spec `protocol.md`
//! section 11, step 5): what the owner decided once, applied after that without asking. Only an
//! inbox answer makes one; nothing another Obi sends can. Kept in `home/decisions.json` (0600).

use std::path::{Path, PathBuf};

use obi_protocol::time;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::store;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
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
    /// A standing rule for events (#1314, types [`EVENT_ALERT`] and [`EVENT_DEPLOY`]): the
    /// source it covers (`plugin.id`: `sentry`, `alertmanager`, a plug-in's id).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    /// The one project it covers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    /// An alert rule's least severity (`critical`, or `error`, which covers critical too).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub severity: Option<String>,
    /// A deploy rule's one environment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<String>,
    /// The conversation it was made in: where its starts are said.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
}

/// A rule that looks into a source's alerts on one project of one repository, with no tap.
pub const EVENT_ALERT: &str = "event_alert";
/// A rule that looks into a source's failed deploys of one project to one environment.
pub const EVENT_DEPLOY: &str = "event_deploy";

/// The standing rule that covers an event offer (its item's `plugin`), if one does: its kind's
/// type, the exact source, project and repository, and for an alert a severity at or above the
/// rule's, for a deploy the exact environment. Only typed fields decide.
pub fn covering_event<'a>(decisions: &'a [Decision], plugin: &Value) -> Option<&'a Decision> {
    let text = |key: &str| plugin[key].as_str().unwrap_or_default();
    let kind = match text("kind") {
        "alert.fired" => EVENT_ALERT,
        "deploy.failed" => EVENT_DEPLOY,
        _ => return None,
    };
    let rank = |s: &str| match s {
        "critical" => 2,
        "error" => 1,
        _ => 0,
    };
    decisions.iter().find(|d| {
        d.kind == kind
            && d.decision == "accept"
            && d.source.as_deref() == Some(text("id"))
            && d.project.as_deref() == Some(text("project"))
            && !text("repo").is_empty()
            && d.repo == text("repo")
            && match kind {
                EVENT_ALERT => {
                    let least = rank(d.severity.as_deref().unwrap_or("critical"));
                    least > 0 && rank(text("severity")) >= least
                }
                _ => d.environment.as_deref() == Some(text("environment")),
            }
    })
}

impl Decision {
    pub fn to_json(&self) -> Value {
        let mut shown = json!({
            "id": self.id,
            "type": self.kind,
            "fromOwner": self.from_owner,
            "repo": self.repo,
            "decision": self.decision,
            "created": time::format(self.created),
            "source": {"inboxItem": self.inbox_item},
            "uses": self.uses,
            "lastUsed": self.last_used.map(time::format),
        });
        if matches!(self.kind.as_str(), EVENT_ALERT | EVENT_DEPLOY) {
            shown["rule"] = json!({"source": self.source, "project": self.project, "severity": self.severity,
                                   "environment": self.environment, "conversation": self.conversation});
        }
        shown
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

/// The remembered decline that covers a question from an Obi of `from_owner` about `repos`
/// (protocol.md section 11, step 5): for each repository, one for that repository (compared
/// ignoring ASCII case) or one for every repository (`*`); for a question about none, one for `*`.
/// Only a decline applies to a question: what lets the Obi answer one is a sharing rule. The
/// decision named is the first repository's.
pub fn covering_question<'a>(
    decisions: &'a [Decision],
    from_owner: &str,
    repos: &[String],
) -> Option<&'a Decision> {
    let declines = |d: &&Decision| {
        d.kind == "question" && d.from_owner == from_owner && d.decision == "decline"
    };
    let every = decisions.iter().filter(declines).find(|d| d.repo == "*");
    if repos.is_empty() {
        return every;
    }
    let mut first = None;
    for repo in repos {
        let found = decisions
            .iter()
            .filter(declines)
            .find(|d| d.repo.eq_ignore_ascii_case(repo))
            .or(every)?;
        first.get_or_insert(found);
    }
    first
}

/// The repositories the owner said no to `from_owner`'s questions about, by a remembered decline:
/// what an answer by the Obi never draws on.
pub fn declined_repos(decisions: &[Decision], from_owner: &str) -> Vec<String> {
    decisions
        .iter()
        .filter(|d| d.kind == "question" && d.from_owner == from_owner && d.decision == "decline")
        .map(|d| d.repo.clone())
        .collect()
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
            ..Decision::default()
        }
    }

    fn rule(kind: &str, severity: Option<&str>, environment: Option<&str>) -> Decision {
        Decision {
            id: "d-0000000000aa".into(),
            kind: kind.into(),
            from_owner: "*".into(),
            repo: "obi-e2e/fixture-app".into(),
            decision: "accept".into(),
            source: Some("sentry".into()),
            project: Some("api".into()),
            severity: severity.map(str::to_owned),
            environment: environment.map(str::to_owned),
            ..Decision::default()
        }
    }

    #[test]
    fn an_event_rule_covers_only_its_source_project_and_repository() {
        let rules = [rule(EVENT_ALERT, Some("error"), None)];
        let plugin = |id: &str, project: &str, repo: &str, severity: &str| json!({"id": id, "kind": "alert.fired", "project": project, "repo": repo, "severity": severity});
        assert!(
            covering_event(
                &rules,
                &plugin("sentry", "api", "obi-e2e/fixture-app", "error")
            )
            .is_some()
        );
        assert!(
            covering_event(
                &rules,
                &plugin("grafana", "api", "obi-e2e/fixture-app", "error")
            )
            .is_none()
        );
        assert!(
            covering_event(
                &rules,
                &plugin("sentry", "web", "obi-e2e/fixture-app", "error")
            )
            .is_none()
        );
        assert!(covering_event(&rules, &plugin("sentry", "api", "other/repo", "error")).is_none());
        assert!(covering_event(&rules, &plugin("sentry", "api", "", "error")).is_none());
        let mut ticket = plugin("sentry", "api", "obi-e2e/fixture-app", "error");
        ticket["kind"] = json!("ticket.assigned");
        assert!(
            covering_event(&rules, &ticket).is_none(),
            "tickets are never covered"
        );
        let deploys = [rule(EVENT_DEPLOY, None, Some("production"))];
        let deploy = |environment: &str| {
            json!({"id": "sentry", "kind": "deploy.failed", "project": "api",
                                                 "repo": "obi-e2e/fixture-app", "environment": environment})
        };
        assert!(covering_event(&deploys, &deploy("production")).is_some());
        assert!(covering_event(&deploys, &deploy("preview")).is_none());
    }

    #[test]
    fn an_alert_rule_covers_its_severity_and_worse_never_warnings() {
        let at = |least: &str, severity: &str| {
            let plugin = json!({"id": "sentry", "kind": "alert.fired", "project": "api",
                                "repo": "obi-e2e/fixture-app", "severity": severity});
            covering_event(&[rule(EVENT_ALERT, Some(least), None)], &plugin).is_some()
        };
        assert!(at("error", "error") && at("error", "critical") && at("critical", "critical"));
        assert!(!at("critical", "error") && !at("error", "warning") && !at("error", "info"));
        assert!(!at("warning", "warning"), "a rule never covers warnings");
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
