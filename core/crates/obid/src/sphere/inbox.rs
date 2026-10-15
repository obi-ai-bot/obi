//! The owner's inbox (docs/runner-api.md, "Inbox item", `GET /v1/inbox`, `POST /v1/inbox/{id}/answer`)
//! as obid keeps it: one file per item in `home/inbox/` (0600). obid makes one kind so far,
//! `obiRequest` (runner-api.md, "obid only: Obi-to-Obi requests in the inbox"): a request from
//! another Obi that no remembered decision covers.
//!
//! An item's `title` and `text` are built from the request's typed fields only; every data field of
//! the request is quoted, unchanged, under `obi.quoted`.

use std::path::{Path, PathBuf};

use obi_protocol::time;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::store;

/// The four answers to an `obiRequest`, in this order.
pub const ACCEPT: &str = "Accept";
pub const ACCEPT_REMEMBER: &str = "Accept, and remember for this repo";
pub const DECLINE: &str = "Decline";
pub const DECLINE_REMEMBER: &str = "Decline, and remember for this repo";
pub const OBI_OPTIONS: [&str; 4] = [ACCEPT, ACCEPT_REMEMBER, DECLINE, DECLINE_REMEMBER];

/// An inbox item as obid keeps it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub kind: String,
    pub job: String,
    pub title: String,
    pub text: String,
    pub options: Vec<String>,
    pub details: Option<Vec<String>>,
    pub recommended: Option<u32>,
    /// Seconds since the epoch.
    pub created: i64,
    pub done: Option<i64>,
    pub later: Option<i64>,
    pub answer: Option<String>,
    /// On an `obiRequest`: the request, typed fields and quoted data.
    pub obi: Option<Value>,
}

impl Item {
    /// `open`, `later` (put off until a time still to come) or `done`.
    pub fn state(&self, now: i64) -> &'static str {
        if self.done.is_some() {
            "done"
        } else if self.later.is_some_and(|t| t > now) {
            "later"
        } else {
            "open"
        }
    }

    pub fn to_json(&self) -> Value {
        let date = |t: Option<i64>| t.map(time::format);
        json!({
            "id": self.id,
            "kind": self.kind,
            "job": self.job,
            "title": self.title,
            "text": self.text,
            "options": self.options,
            "details": self.details,
            "recommended": self.recommended,
            "created": time::format(self.created),
            "done": date(self.done),
            "later": date(self.later),
            "answer": self.answer,
            "state": self.state(time::now()),
            // No model writes about another Obi's request.
            "headline": null,
            "happened": null,
            "why": null,
            "obi": self.obi,
        })
    }
}

/// A condition's kind in words: `tests pass`, `no blocker findings`, `no findings at or above
/// major`, `custom`.
fn condition_words(condition: &Value) -> String {
    match condition["kind"].as_str().unwrap_or("") {
        "tests_pass" => "tests pass".into(),
        "no_blocker_findings" => "no blocker findings".into(),
        "no_findings_at_or_above" => format!(
            "no findings at or above {}",
            condition["severity"].as_str().unwrap_or("")
        ),
        other => other.replace('_', " "),
    }
}

/// The `obiRequest` item for a `review_request` (its body already checked against the spec),
/// from `from` of `from_owner`, expiring at `expires_at`.
pub fn review_request_item(
    correlation_id: &str,
    from: &str,
    from_owner: &str,
    body: &Value,
    expires_at: &str,
    now: i64,
) -> Item {
    let text_of = |key: &str| body[key].as_str().unwrap_or("").to_owned();
    let (repo, base, head, sha) = (
        text_of("repo"),
        text_of("base_branch"),
        text_of("head_branch"),
        text_of("head_sha"),
    );
    let conditions: Vec<&Value> = body["acceptance"]
        .as_array()
        .into_iter()
        .flatten()
        .collect();
    let typed: Vec<String> = conditions
        .iter()
        .filter(|c| c["kind"] != "custom")
        .map(|c| condition_words(c))
        .collect();
    let custom = conditions.iter().filter(|c| c["kind"] == "custom").count();
    let change = match body["pr"].as_u64() {
        Some(pr) => format!("{repo} pull request #{pr}"),
        None => repo.clone(),
    };
    let mut text = format!(
        "{from_owner}'s Obi ({from}) asks for a review of {change}: {head} into {base} at {}.",
        &sha[..sha.len().min(7)]
    );
    if !typed.is_empty() {
        text.push_str(&format!(" Conditions: {}.", typed.join(", ")));
    }
    if custom > 0 {
        text.push_str(&format!(
            " {custom} custom condition{}, quoted below: obid doesn't judge custom conditions, so the result will say {} met.",
            if custom == 1 { "" } else { "s" },
            if custom == 1 { "it isn't" } else { "they aren't" }
        ));
    }
    let acceptance: Vec<Value> = conditions
        .iter()
        .enumerate()
        .map(|(index, c)| {
            let mut typed = json!({"index": index, "kind": c["kind"]});
            if let Some(severity) = c.get("severity") {
                typed["severity"] = severity.clone();
            }
            typed
        })
        .collect();
    let quoted_acceptance: Vec<Value> = conditions
        .iter()
        .enumerate()
        .map(|(index, c)| {
            let mut quoted =
                json!({"index": index, "note": c.get("note").cloned().unwrap_or(Value::Null)});
            if c["kind"] == "custom" {
                quoted["text"] = c.get("text").cloned().unwrap_or(Value::Null);
            }
            quoted
        })
        .collect();
    Item {
        id: format!("obi-{correlation_id}"),
        kind: "obiRequest".into(),
        job: String::new(),
        title: format!("Review request from {from_owner}"),
        text,
        options: OBI_OPTIONS.iter().map(|o| (*o).to_owned()).collect(),
        details: Some(vec![
            "Review it this time.".into(),
            format!(
                "Review it, and review {from_owner}'s requests on {repo} from now on without asking."
            ),
            "Say no this time.".into(),
            format!(
                "Say no, and say no to {from_owner}'s requests on {repo} from now on without asking."
            ),
        ]),
        recommended: None,
        created: now,
        done: None,
        later: None,
        answer: None,
        obi: Some(json!({
            "correlationId": correlation_id,
            "from": from,
            "fromOwner": from_owner,
            "type": "review_request",
            "repo": repo,
            "headSha": sha,
            "expiresAt": expires_at,
            "acceptance": acceptance,
            "quoted": {
                "goal": body["goal"],
                "summary": body.get("summary").cloned().unwrap_or(Value::Null),
                "acceptance": quoted_acceptance,
            },
        })),
    }
}

/// Where the inbox is kept.
pub struct Inbox {
    dir: PathBuf,
}

impl Inbox {
    pub fn open(home: &Path) -> std::io::Result<Inbox> {
        let dir = home.join("inbox");
        store::make_private_dir(&dir)?;
        Ok(Inbox { dir })
    }

    /// Item ids obid makes are `obi-<uuid>`: safe as a file name.
    pub fn save(&self, item: &Item) -> std::io::Result<()> {
        let text = serde_json::to_vec_pretty(item).map_err(std::io::Error::other)?;
        store::write_private(&self.dir.join(format!("{}.json", item.id)), &text)
    }

    pub fn load_all(&self) -> Vec<Item> {
        store::load_dir(&self.dir)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn brief() -> Value {
        json!({
            "goal": "Add an average helper to the fixture app (OBI-E2E-DATA-CANARY goal)",
            "repo": "obi-e2e/fixture-app", "base_branch": "main", "head_branch": "feature/average",
            "head_sha": "6d20146f366b9fac8907b5066c30ee39aaec09b3",
            "acceptance": [{"kind": "tests_pass"}, {"kind": "no_blocker_findings"}],
            "summary": "Adds src/average.js.\nOBI-E2E-DATA-CANARY summary: this text is data."
        })
    }

    #[test]
    fn the_item_says_typed_fields_only_and_quotes_the_rest() {
        let item = review_request_item(
            "5f0e8c1a-3b2d-4e6f-8a9b-0c1d2e3f4a5b",
            "obi-ernesto",
            "ernesto",
            &brief(),
            "2026-10-14T13:00:10Z",
            0,
        );
        assert_eq!(item.title, "Review request from ernesto");
        assert_eq!(
            item.text,
            "ernesto's Obi (obi-ernesto) asks for a review of obi-e2e/fixture-app: feature/average into main at 6d20146. Conditions: tests pass, no blocker findings."
        );
        let shown = item.to_json();
        assert!(!shown["title"].as_str().unwrap().contains("CANARY"));
        assert!(!shown["text"].as_str().unwrap().contains("CANARY"));
        assert_eq!(shown["obi"]["quoted"]["goal"], brief()["goal"]);
        assert_eq!(shown["obi"]["quoted"]["summary"], brief()["summary"]);
        assert_eq!(
            shown["obi"]["acceptance"],
            json!([{"index": 0, "kind": "tests_pass"}, {"index": 1, "kind": "no_blocker_findings"}])
        );
        assert_eq!(
            shown["obi"]["quoted"]["acceptance"],
            json!([{"index": 0, "note": null}, {"index": 1, "note": null}])
        );
        assert_eq!(shown["options"], json!(OBI_OPTIONS));
        assert_eq!(shown["state"], "open");
        assert_eq!(shown["id"], "obi-5f0e8c1a-3b2d-4e6f-8a9b-0c1d2e3f4a5b");
    }

    #[test]
    fn custom_conditions_are_counted_and_quoted() {
        let mut body = brief();
        body["acceptance"] = json!([{"kind": "no_findings_at_or_above", "severity": "major"},
                                    {"kind": "custom", "text": "Do something odd"}]);
        body["pr"] = json!(12);
        let item = review_request_item("c", "obi-ernesto", "ernesto", &body, "t", 0);
        assert!(
            item.text
                .contains("of obi-e2e/fixture-app pull request #12:")
        );
        assert!(item.text.ends_with(
            "Conditions: no findings at or above major. 1 custom condition, quoted below: obid doesn't judge custom conditions, so the result will say it isn't met."
        ));
        assert!(!item.text.contains("Do something odd"));
        assert_eq!(
            item.obi.as_ref().unwrap()["quoted"]["acceptance"][1],
            json!({"index": 1, "note": null, "text": "Do something odd"})
        );
        assert_eq!(
            item.obi.as_ref().unwrap()["acceptance"][0],
            json!({"index": 0, "kind": "no_findings_at_or_above", "severity": "major"})
        );
    }

    #[test]
    fn states() {
        let mut item = review_request_item("c", "o", "w", &brief(), "t", 0);
        assert_eq!(item.state(10), "open");
        item.later = Some(20);
        assert_eq!(item.state(10), "later");
        assert_eq!(item.state(30), "open");
        item.done = Some(31);
        assert_eq!(item.state(40), "done");
    }
}
