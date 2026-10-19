//! The event orchestrator (#590): what happens to a job goes to obid's brain first, which reads
//! the job, then takes one allowed action or leaves the owner one decision.
mod support;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use support::*;

fn planner() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-planner")
}

/// obid with the fake planner as its brain, and events brought together for one second.
fn started(folder: &Folder) -> Obid {
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &planner());
    config["orchestratorDelay"] = json!(1);
    start(&folder.0, &config, Some(planner().parent().unwrap()))
}

/// A job whose agent keeps working until it's stopped.
fn sleeping(obid: &Obid) -> String {
    let job = json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "SLEEP",
                     "title": "Another thing"});
    let answer = call(obid, "POST", "/v1/jobs", Some(&json!({"job": job})));
    assert!(
        answer.status == 200 || answer.status == 201,
        "{}",
        answer.text
    );
    answer.body["id"].as_str().unwrap().to_owned()
}

/// A job whose agent fails its turn.
fn failing(obid: &Obid) -> String {
    let job = json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "FAIL",
                     "title": "Flaky thing", "rounds": 1});
    let answer = call(obid, "POST", "/v1/jobs", Some(&json!({"job": job})));
    assert!(
        answer.status == 200 || answer.status == 201,
        "{}",
        answer.text
    );
    answer.body["id"].as_str().unwrap().to_owned()
}

fn on(action: &str, job: &str) -> String {
    json!({"action": action, "reply": "", "dispatches": [], "question": null, "jobs": [job]})
        .to_string()
}

fn reply(text: &str) -> String {
    json!({"action": "reply_only", "reply": text, "dispatches": [], "question": null, "jobs": []})
        .to_string()
}

/// What the fake planner answers next, one line per call.
fn queue(obid: &Obid, lines: &[String]) {
    let dir = obid.home.join("accounts/stub");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("plans"), lines.join("\n") + "\n").unwrap();
}

fn calls(obid: &Obid) -> usize {
    std::fs::read_dir(obid.home.join("accounts/stub/calls"))
        .map(|dir| dir.count())
        .unwrap_or(0)
}

/// The actions the orchestrator's turns planned, in order.
fn planned(obid: &Obid) -> Vec<String> {
    std::fs::read_to_string(obid.home.join("brain-turns.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|r| r["conversation"] == "orchestrator")
        .map(|r| r["plan"]["action"].as_str().unwrap().to_owned())
        .collect()
}

/// The orchestrator's open items in the inbox.
fn escalations(obid: &Obid) -> Vec<Value> {
    call(obid, "GET", "/v1/inbox", None)
        .body
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|i| i["id"].as_str().unwrap_or("").starts_with("orchestrator-"))
        .collect()
}

/// A job that fails is read, then retried: one allowed action and nothing else, and the job
/// recovers. (A repeat after the action escalating is brain/orchestrator.rs
/// `a_fourth_action_in_a_day_and_a_repeated_failure_escalate`: the fake agent fails only its
/// first prompt.)
#[test]
fn a_failed_job_is_read_then_retried_once() {
    let folder = Folder::new("orchestrator-retry");
    let obid = started(&folder);
    let id = failing(&obid);
    queue(
        &obid,
        &[on("read_job", &id), on("retry_job", &id), reply("")],
    );
    within(60, "the retried job is done", || {
        let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        (job["status"] == "done").then_some(())
    });
    assert_eq!(planned(&obid), ["read_job", "retry_job", "reply_only"]);
    assert!(escalations(&obid).is_empty());
    assert!(
        obid.log().contains("Started Flaky thing again"),
        "the turn's answer says what it did"
    );
}

/// An event whose job the brain can't match to it escalates and changes nothing.
#[test]
fn an_event_it_cant_match_escalates_and_changes_nothing() {
    let folder = Folder::new("orchestrator-unmatched");
    let obid = started(&folder);
    let other = sleeping(&obid);
    let id = failing(&obid);
    queue(&obid, &[on("read_job", &other), on("retry_job", &id)]);
    let item = within(60, "it escalates", || escalations(&obid).pop());
    assert!(
        item["text"]
            .as_str()
            .unwrap()
            .starts_with("Oby couldn't match the job read to this event."),
        "{item}"
    );
    assert_eq!(planned(&obid), ["read_job"]);
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["status"], "interrupted");
    assert_eq!(job["round"], 1);
    // The owner settles it, and it goes (#710: it answered "settled already" and stayed).
    assert_eq!(item["options"], serde_json::json!(["Done"]));
    let path = format!("/v1/inbox/{}/answer", item["id"].as_str().unwrap());
    let settled = call(
        &obid,
        "POST",
        &path,
        Some(&serde_json::json!({"done": true})),
    );
    assert_eq!(settled.status, 200, "{}", settled.text);
    assert!(escalations(&obid).is_empty());
}

/// Telling a job that ended something starts a follow-up (the owner's decision of 2026-10-18),
/// which only the owner's own words start: an event turn's message to one escalates, and nothing
/// starts.
#[test]
fn an_event_turn_never_starts_a_follow_up() {
    let folder = Folder::new("orchestrator-follow-up");
    let obid = started(&folder);
    let id = failing(&obid);
    let mut tell = on("message_job", &id);
    tell = tell.replace(
        r#""jobs":"#,
        r#""message": "Rerun the flaky test.", "jobs":"#,
    );
    queue(&obid, &[on("read_job", &id), tell]);
    let item = within(60, "it escalates", || escalations(&obid).pop());
    assert!(
        item["text"]
            .as_str()
            .unwrap()
            .contains("only your own words start"),
        "{item}"
    );
    assert_eq!(planned(&obid), ["read_job", "message_job"]);
    let jobs = call(&obid, "GET", "/v1/jobs", None).body;
    assert_eq!(jobs.as_array().unwrap().len(), 1, "{jobs}");
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["status"], "interrupted");
    assert_eq!(job["round"], 1);
}

/// The user's words preempt an event turn: it stops after what it was doing, and acts on nothing.
#[test]
fn a_user_message_preempts_an_event_turn() {
    let folder = Folder::new("orchestrator-preempted");
    let obid = started(&folder);
    let id = failing(&obid);
    queue(
        &obid,
        &[format!("SLEEP 3 {}", on("read_job", &id)), reply("Fine.")],
    );
    within(60, "the event turn is thinking", || {
        (calls(&obid) == 1).then_some(())
    });
    let answer = call(
        &obid,
        "POST",
        "/v1/plans",
        Some(&json!({"said": "how are the jobs going?"})),
    );
    assert_eq!(answer.body["text"], "Fine.", "{}", answer.text);
    within(30, "the event turn stops", || {
        obid.log().contains(" ended: stopped").then_some(())
    });
    assert!(!planned(&obid).contains(&"retry_job".to_owned()));
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["round"], 1);
}
