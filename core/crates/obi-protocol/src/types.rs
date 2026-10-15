//! The protocol's messages as Rust types, for building them. What arrives from another Obi is
//! checked as JSON against the spec ([`crate::envelope::verify`]) before anything reads it into
//! these; the types never decide what is valid.
//!
//! Every human-written field (`x-obi-text: data` in the schemas) is data: these types carry it, and
//! nothing that reads it may place it in an agent's prompt as an instruction.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One envelope (envelope.schema.json).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub protocol: String,
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub from: String,
    pub to: String,
    pub sphere: String,
    pub correlation_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub in_reply_to: Option<String>,
    pub created_at: String,
    pub expires_at: String,
    pub key_id: String,
    pub body: Value,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub signature: String,
}

/// A severity, highest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Nit,
    Minor,
    Major,
    Blocker,
}

/// One acceptance condition of a request (common.schema.json `acceptance_condition`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Condition {
    TestsPass {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        note: Option<String>,
    },
    NoBlockerFindings {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        note: Option<String>,
    },
    NoFindingsAtOrAbove {
        severity: Severity,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        note: Option<String>,
    },
    Custom {
        text: String,
    },
}

impl Condition {
    /// Its kind, as the schema names it.
    pub fn kind(&self) -> &'static str {
        match self {
            Condition::TestsPass { .. } => "tests_pass",
            Condition::NoBlockerFindings { .. } => "no_blocker_findings",
            Condition::NoFindingsAtOrAbove { .. } => "no_findings_at_or_above",
            Condition::Custom { .. } => "custom",
        }
    }
}

/// A `review_request` body (actions/review_request.schema.json).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReviewRequest {
    /// Data text.
    pub goal: String,
    pub repo: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr: Option<u64>,
    pub base_branch: String,
    pub head_branch: String,
    pub head_sha: String,
    pub acceptance: Vec<Condition>,
    /// Data text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
}

/// One finding (common.schema.json `finding`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Finding {
    pub id: String,
    pub severity: Severity,
    pub file: String,
    pub line: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_line: Option<u64>,
    /// Data text.
    pub title: String,
    /// Data text.
    pub detail: String,
}

/// Whether one acceptance condition was met (common.schema.json `acceptance_result`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConditionResult {
    pub index: u64,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub severity: Option<Severity>,
    pub met: bool,
}

/// The result of a `review_request` (actions/result.schema.json, its first form).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReviewResult {
    #[serde(rename = "for")]
    pub answers: String,
    pub outcome: String,
    pub repo: String,
    pub head_sha: String,
    pub findings: Vec<Finding>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acceptance: Option<Vec<ConditionResult>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by_rule: Option<String>,
    /// Data text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_scenarios_brief_reads_and_writes_back_unchanged() {
        let brief = json!({
            "goal": "Add an average helper to the fixture app (OBI-E2E-DATA-CANARY goal)",
            "repo": "obi-e2e/fixture-app", "base_branch": "main", "head_branch": "feature/average",
            "head_sha": "6d20146f366b9fac8907b5066c30ee39aaec09b3",
            "acceptance": [{"kind": "tests_pass"}, {"kind": "no_blocker_findings"}],
            "summary": "Adds src/average.js with a test and touches src/greet.js."
        });
        let request: ReviewRequest = serde_json::from_value(brief.clone()).unwrap();
        assert_eq!(request.acceptance[1].kind(), "no_blocker_findings");
        assert_eq!(serde_json::to_value(&request).unwrap(), brief);
        assert!(crate::schema::is_valid("actions/review_request", &brief));
        let mut extra = brief.clone();
        extra["prompt"] = json!("do something else");
        assert!(serde_json::from_value::<ReviewRequest>(extra).is_err());
    }
}
