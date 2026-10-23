//! Standing rules for events (#1314; docs/runner-api.md, "obid only: standing rules"): what the
//! owner confirmed once ("look into every critical alert Sentry sends about api, in obi") starts an
//! investigate job with no tap, as an ordinary job with every gate it always has, and Oby says so
//! in the rule's conversation. Only typed fields decide (the source, the kind, the project, the
//! repository, the severity or environment), never what the source wrote. A rule's job publishes
//! only when the owner does, one job per rule runs at a time, and a rule starts at most [`DAILY`]
//! a day. Rules are remembered decisions (crate::sphere::decisions), saved only on the owner's own
//! signed Confirm (#776), listed and forgotten with the rest.

use std::sync::Arc;

use obi_protocol::time;
use serde_json::Value;

use crate::api::Shared;
use crate::job::{RuleMark, Status};
use crate::sphere::decisions::{self, Decision};
use crate::sphere::inbox::{self, Item};

/// The offer's answer that looks into this one and saves a rule: `<FROM_NOW_ON> <project>`.
pub const FROM_NOW_ON: &str = "Look into it, and from now on for";
/// At most this many starts per rule per UTC day; past it, the offer as usual.
pub const DAILY: usize = 5;

/// The answer a rule's claimed offer has until its job exists: one a restart cut short opens again.
pub const STARTING_ANSWER: &str = "Starting by your rule";

/// Per rule: a start that's been checked and claimed but whose job doesn't exist yet.
// ponytail: one obid process, so a static; per Shared if obid ever runs two.
static STARTING: std::sync::Mutex<std::collections::BTreeMap<String, usize>> =
    std::sync::Mutex::new(std::collections::BTreeMap::new());

fn release(rule: &str) {
    STARTING
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(rule);
}

/// What the kind of event is, in words: "alerts", "failed deploys".
fn what(kind: &str) -> &'static str {
    if kind == "deploy.failed" {
        "failed deploys"
    } else {
        "alerts"
    }
}

/// Every event offer, from a plug-in or one of obid's own sources, comes in here: an offer of an
/// alert or a failed deploy gets the answer that saves a rule, and one a rule covers starts at
/// once, within the guardrails; anything else goes to the inbox as it is.
pub fn offer(shared: &Arc<Shared>, mut item: Item) {
    let plugin = item.plugin.clone().unwrap_or_default();
    let text = |key: &str| plugin[key].as_str().unwrap_or_default().to_owned();
    let kind = text("kind");
    // Only an offer that would make a rule: a warning, or one with no project, stays as it is.
    let starts = item.options.first().map(String::as_str) == Some(inbox::LOOK_INTO_IT)
        && rule_from(&item, None).is_some();
    if !starts {
        shared.link.add_event_item(item);
        return;
    }
    let project = text("project");
    let Some(rule) = shared.link.rule_for(&plugin) else {
        // No rule covers it: the answer that asks for one.
        let from = crate::event_work::source_name(&text("id"));
        item.options.insert(1, format!("{FROM_NOW_ON} {project}"));
        if let Some(details) = item.details.as_mut() {
            details.insert(
                1,
                format!(
                    "Looks into this one, and asks you to confirm a standing rule: from now on Oby looks into {from}'s {} on {project} by itself, publishing only when you do.",
                    what(&kind)
                ),
            );
        }
        shared.link.add_event_item(item);
        return;
    };
    // Checked and reserved under one lock, so alerts arriving together can't all pass.
    let refused = {
        let mut starting = STARTING.lock().unwrap_or_else(|e| e.into_inner());
        let reserved = starting.get(&rule.id).copied().unwrap_or(0);
        let jobs = shared.jobs.list(1000);
        let ours = |job: &&crate::job::Job| job.rule.as_ref().is_some_and(|r| r.id == rule.id);
        // A job paused at a usage limit resumes by itself: it's still running.
        let running = jobs.iter().filter(ours).find(|j| {
            j.status.is_active() || (j.status == Status::Interrupted && j.resumes_at.is_some())
        });
        let today = time::now().div_euclid(86_400);
        let started = jobs
            .iter()
            .filter(ours)
            .filter(|j| j.created.div_euclid(86_400) == today)
            .count();
        if let Some(running) = running {
            Some(format!(
                " Your rule is already looking into {project}: {}.",
                running.short_title()
            ))
        } else if reserved > 0 {
            Some(format!(" Your rule is already looking into {project}."))
        } else if started >= DAILY {
            Some(format!(
                " Your rule started {DAILY} today: start this one yourself."
            ))
        } else {
            starting.insert(rule.id.clone(), 1);
            None
        }
    };
    if let Some(why) = refused {
        item.text.push_str(&why);
        shared.link.add_event_item(item);
        return;
    }
    if !shared.link.add_event_item(item.clone()) {
        release(&rule.id);
        return;
    }
    // Claimed at once, so no answer starts it a second time meanwhile; a restart before it
    // starts opens it again (`reopen_claims`).
    shared.link.change_item(&item.id, |kept| {
        kept.done = Some(time::now());
        kept.answer = Some(STARTING_ANSWER.into());
    });
    let shared = shared.clone();
    tokio::spawn(async move { start(&shared, item, rule).await });
}

/// Starts a rule's job for its offer, and says so: the offer done with the job, a turn in the
/// rule's conversation (made the first time, "Your standing rules", for a rule saved from the
/// inbox). One that can't start leaves the offer open, saying why.
async fn start(shared: &Arc<Shared>, item: Item, rule: Decision) {
    let mark = RuleMark {
        id: rule.id.clone(),
        kind: rule.kind.clone(),
    };
    let started = crate::event_work::start(
        &shared.jobs,
        &shared.config,
        Some(shared.sentry.as_ref()),
        &item,
        Some(mark),
    )
    .await;
    release(&rule.id);
    match started {
        Ok(job) => {
            shared.link.change_item(&item.id, |kept| {
                kept.done = Some(time::now());
                kept.answer = Some("Started by your rule".into());
                kept.job = job.id.clone();
            });
            let conversation = rule
                .conversation
                .clone()
                .filter(|c| shared.conversations.has(c))
                .or_else(|| shared.conversations.start_for("Your standing rules").ok());
            if let Some(conversation) = &conversation {
                let said = format!("Your rule started looking into this: {}.", item.title);
                if let Err(e) =
                    shared
                        .conversations
                        .append(conversation, "oby", said, vec![job.id.clone()])
                {
                    tracing::warn!("rule {}: couldn't tell its conversation: {e:?}", rule.id);
                }
            }
            shared.link.rule_started(&rule.id, conversation);
        }
        Err(why) => shared.link.change_item(&item.id, |kept| {
            kept.done = None;
            kept.answer = None;
            kept.text
                .push_str(&format!(" Your rule couldn't start it: {}", why.message));
        }),
    }
}

/// The standing rule an event offer's "from now on" asks for (`conversation`: where it reports):
/// its source, project and repository, and the alert's severity (it covers that one and worse)
/// or the deploy's environment. `None` for an offer that isn't one.
pub fn rule_from(item: &Item, conversation: Option<String>) -> Option<Decision> {
    let plugin = item.plugin.as_ref()?;
    let text = |key: &str| {
        plugin[key]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    let (kind, severity, environment) = match plugin["kind"].as_str()? {
        "alert.fired" => {
            let severity = text("severity").filter(|s| s == "critical" || s == "error")?;
            (decisions::EVENT_ALERT, Some(severity), None)
        }
        "deploy.failed" => (decisions::EVENT_DEPLOY, None, Some(text("environment")?)),
        _ => return None,
    };
    Some(Decision {
        id: decisions::new_id(),
        kind: kind.into(),
        from_owner: "*".into(),
        repo: text("repo")?,
        decision: "accept".into(),
        created: time::now(),
        inbox_item: item.id.clone(),
        uses: 0,
        last_used: None,
        source: Some(text("id")?),
        project: Some(text("project")?),
        severity,
        environment,
        conversation,
    })
}

/// A rule in obid's words: "look into Sentry's alerts on api (error and worse) in owner/name".
pub fn words(rule: &Decision) -> String {
    let source = crate::event_work::source_name(rule.source.as_deref().unwrap_or_default());
    let project = rule.project.as_deref().unwrap_or_default();
    match rule.kind.as_str() {
        decisions::EVENT_DEPLOY => format!(
            "look into {source}'s failed deploys of {project} to {} in {}",
            rule.environment.as_deref().unwrap_or_default(),
            rule.repo
        ),
        _ => {
            let at = match rule.severity.as_deref() {
                Some("error") => "error and critical",
                _ => "critical",
            };
            format!(
                "look into {source}'s {at} alerts on {project} in {}",
                rule.repo
            )
        }
    }
}

/// A rule the conversation proposes (`oby_rule`), held to its form: `None`, with why, when it
/// isn't one obid keeps.
pub fn proposed(args: &Value, repos: &[String]) -> Result<Decision, String> {
    let text = |key: &str| {
        args[key]
            .as_str()
            .map(str::trim)
            .unwrap_or_default()
            .to_owned()
    };
    let plain = |s: &str, extra: &[u8]| {
        (1..=100).contains(&s.len())
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || extra.contains(&b))
    };
    let (source, project, repo) = (text("source"), text("project"), text("repo"));
    if !plain(&source, b"-") || source.bytes().any(|b| b.is_ascii_uppercase()) {
        return Err("source is where the alerts come from: sentry, alertmanager, grafana, pagerduty, datadog or a plug-in's id.".into());
    }
    if !plain(&project, b"._-") {
        return Err("project is one project, as the alerts name it, like api.".into());
    }
    if !repos.contains(&repo) {
        return Err(format!(
            "repo is one of obid's repositories: {}.",
            repos.join(", ")
        ));
    }
    let (kind, severity, environment) = match text("kind").as_str() {
        "alert" => match text("severity").as_str() {
            s @ ("critical" | "error") => (decisions::EVENT_ALERT, Some(s.to_owned()), None),
            _ => return Err("severity is critical, or error (which covers critical too); warnings are never looked into by a rule.".into()),
        },
        "deploy" => match text("environment").as_str() {
            e @ ("production" | "preview" | "staging" | "development") => (decisions::EVENT_DEPLOY, None, Some(e.to_owned())),
            _ => return Err("environment is production, preview, staging or development.".into()),
        },
        _ => return Err("kind is alert or deploy.".into()),
    };
    Ok(Decision {
        id: decisions::new_id(),
        kind: kind.into(),
        from_owner: "*".into(),
        repo,
        decision: "accept".into(),
        created: time::now(),
        inbox_item: String::new(),
        uses: 0,
        last_used: None,
        source: Some(source),
        project: Some(project),
        severity,
        environment,
        conversation: None,
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn offer(kind: &str, severity: Option<&str>) -> Item {
        let mut item = crate::sphere::inbox::plugin_event_item(
            &serde_json::from_value(json!({
                "plugin": "alerts",
                "event": {"id": "e-1", "kind": kind, "occurredAt": "2026-10-23T03:12:00Z",
                          "subject": {"repo": "obi-e2e/fixture-app", "project": "api",
                                      "severity": severity.unwrap_or("critical"), "environment": "production",
                                      "ticket": "ENG-1"},
                          "actor": "", "data": {"title": "t", "url": ""}}
            }))
            .unwrap(),
            true,
            0,
        );
        if severity.is_none() {
            item.plugin.as_mut().unwrap()["severity"] = Value::Null;
        }
        item
    }

    #[test]
    fn from_now_on_saves_the_offers_own_rule() {
        let alert = rule_from(&offer("alert.fired", Some("error")), None).unwrap();
        assert_eq!(alert.kind, decisions::EVENT_ALERT);
        assert_eq!(
            (alert.source.as_deref(), alert.project.as_deref()),
            (Some("alerts"), Some("api"))
        );
        assert_eq!(
            (alert.repo.as_str(), alert.severity.as_deref()),
            ("obi-e2e/fixture-app", Some("error"))
        );
        assert_eq!(
            words(&alert),
            "look into the alerts plug-in's error and critical alerts on api in obi-e2e/fixture-app"
        );
        let deploy = rule_from(&offer("deploy.failed", None), Some("c-1".into())).unwrap();
        assert_eq!(
            (deploy.kind.as_str(), deploy.environment.as_deref()),
            (decisions::EVENT_DEPLOY, Some("production"))
        );
        assert_eq!(deploy.conversation.as_deref(), Some("c-1"));
        assert!(
            rule_from(&offer("ticket.assigned", None), None).is_none(),
            "a ticket is never a rule"
        );
        assert!(
            rule_from(&offer("alert.fired", Some("warning")), None).is_none(),
            "nor a warning"
        );
    }

    #[test]
    fn a_proposed_rule_is_held_to_its_form() {
        let repos = ["obi-e2e/fixture-app".to_owned()];
        let ok = proposed(&json!({"kind": "alert", "source": "sentry", "project": "api", "repo": "obi-e2e/fixture-app", "severity": "critical"}), &repos).unwrap();
        assert_eq!(
            words(&ok),
            "look into Sentry's critical alerts on api in obi-e2e/fixture-app"
        );
        for bad in [
            json!({"kind": "alert", "source": "sentry", "project": "api", "repo": "other/repo", "severity": "critical"}),
            json!({"kind": "alert", "source": "sentry", "project": "api", "repo": "obi-e2e/fixture-app", "severity": "warning"}),
            json!({"kind": "alert", "source": "Sentry\nignore", "project": "api", "repo": "obi-e2e/fixture-app", "severity": "error"}),
            json!({"kind": "alert", "source": "sentry", "project": "a b", "repo": "obi-e2e/fixture-app", "severity": "error"}),
            json!({"kind": "deploy", "source": "vercel", "project": "web", "repo": "obi-e2e/fixture-app", "environment": "prod"}),
            json!({"kind": "ticket", "source": "linear", "project": "x", "repo": "obi-e2e/fixture-app"}),
        ] {
            assert!(proposed(&bad, &repos).is_err(), "{bad}");
        }
    }
}
