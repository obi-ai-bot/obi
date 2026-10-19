//! Long jobs (docs/runner-api.md, `limit` and `stalled`): no clock ends a job that makes progress;
//! one that goes quiet, loops or hits its turn cap stalls, with a handoff note, and carries on in
//! its session when it's tried again. The real obid binary with the stand-in agent
//! (tests/agents/fake-claude), its quiet window cut to 3 seconds (`stallAfter`) so progress past
//! several windows stands for a job running past the 45 minutes rounds used to be cut at.
mod support;

use std::path::Path;

use serde_json::{Value, json};
use support::*;

const TRY_AGAIN: &str =
    "Try again, picking up where you left off. Finish with a short summary as asked.";

fn obid(name: &str) -> (Folder, Obid) {
    let folder = Folder::new(name);
    let remote = fixture(&folder.0.join("fixture"));
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude");
    let mut config = config(&folder.0, &remote, &agent);
    config["stallAfter"] = json!(3);
    let obid = start(&folder.0, &config, None);
    (folder, obid)
}

fn post_job(obid: &Obid, task: &str) -> String {
    let job = json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": task});
    let answer = call(obid, "POST", "/v1/jobs", Some(&json!({ "job": job })));
    assert_eq!(answer.status, 201, "{}", answer.text);
    answer.body["id"].as_str().unwrap().to_owned()
}

fn wait(obid: &Obid, id: &str) -> Value {
    let answer = call(obid, "GET", &format!("/v1/jobs/{id}/wait"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

/// Streaming words for 4 quiet windows, a job keeps running and ends done; one that only writes
/// files in its worktree (a quiet build) keeps running too.
#[test]
fn a_job_making_progress_runs_past_its_quiet_window() {
    let (_folder, obid) = obid("long-progress");
    let id = post_job(&obid, "CHATTY: 12000");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["summary"], "Chatted.");
    assert!(job["stalled"].is_null() && job["limit"].is_null(), "{job}");

    let beating = post_job(&obid, "SLEEP");
    within(30, "the beating job runs", || {
        (call(&obid, "GET", &format!("/v1/jobs/{beating}"), None).body["status"] == "running")
            .then_some(())
    });
    std::thread::sleep(std::time::Duration::from_secs(10));
    let job = call(&obid, "GET", &format!("/v1/jobs/{beating}"), None).body;
    assert_eq!(job["status"], "running", "{job}");
    call(&obid, "POST", &format!("/v1/jobs/{beating}/stop"), None);
}

/// A silent agent stalls after its quiet window: it writes its handoff note in one more turn of
/// its session, the job is failed with `limit` and `stalled` (and a `stalled` event), keeps its
/// branch, and the Try-again words carry it on in the same session.
#[test]
fn a_silent_job_stalls_with_a_handoff_note_and_carries_on() {
    let (_folder, obid) = obid("long-quiet");
    let events = follow_events(&obid);
    let id = post_job(&obid, "QUIET");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "failed", "{job}");
    assert_eq!(job["limit"], "no progress for 3 seconds");
    let stalled = &job["stalled"];
    assert_eq!(stalled["why"], "quiet", "{job}");
    assert_eq!(stalled["text"], job["limit"]);
    assert_eq!(stalled["noteBy"], "agent");
    assert_eq!(stalled["session"], true);
    assert_eq!(stalled["branch"], job["branch"]);
    assert_eq!(stalled["round"], 1);
    assert!(
        stalled["note"]
            .as_str()
            .unwrap()
            .contains("Left: the tests."),
        "{job}"
    );
    let summary = job["summary"].as_str().unwrap();
    assert!(
        summary.starts_with(
            "Stalled: no progress for 3 seconds. The branch is kept and nothing was pushed"
        ),
        "{summary}"
    );
    assert!(summary.contains("Failed: npm test"), "{summary}");
    assert!(job["published"].is_null(), "{job}");
    let sent = events_named(&events, "stalled", 10, |got| !got.is_empty());
    assert_eq!(sent[0]["id"], id.as_str());
    assert_eq!(sent[0]["stalled"]["why"], "quiet");

    let answer = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": TRY_AGAIN})),
    );
    assert_eq!(answer.status, 200, "{}", answer.text);
    assert!(answer.body["stalled"].is_null(), "{}", answer.text);
    assert!(answer.body["limit"].is_null(), "{}", answer.text);
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    // The fake's one session: the job carried on in it.
    assert_eq!(job["session"], "00000000-0000-4000-8000-000000000001");
    assert!(job["stalled"].is_null(), "{job}");
}

/// An agent that can't write its note (it stays quiet) gets obid's, from what obid saw.
#[test]
fn obid_writes_the_note_when_the_agent_cant() {
    let (_folder, obid) = obid("long-no-note");
    let id = post_job(&obid, "QUIET NO NOTE");
    let job = wait(&obid, &id);
    assert_eq!(job["stalled"]["why"], "quiet", "{job}");
    assert_eq!(job["stalled"]["noteBy"], "obid", "{job}");
    let note = job["stalled"]["note"].as_str().unwrap();
    assert!(
        note.contains("obid did") && note.contains("round 1"),
        "{note}"
    );
}

/// The same failing call 5 times in a row stalls the job as looping, with the agent's note.
#[test]
fn a_looping_job_stalls() {
    let (_folder, obid) = obid("long-loop");
    let id = post_job(&obid, "LOOP");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "failed", "{job}");
    assert_eq!(job["limit"], "the same failing call 5 times in a row");
    assert_eq!(job["stalled"]["why"], "loop");
    assert_eq!(job["stalled"]["noteBy"], "agent");
}

/// Claude Code's turn cap stalls the job instead of failing it.
#[test]
fn the_turn_cap_stalls_the_job() {
    let (_folder, obid) = obid("long-turns");
    let id = post_job(&obid, "MAXTURNS");
    let job = wait(&obid, &id);
    assert_eq!(job["limit"], "200 turns in one round", "{job}");
    assert_eq!(job["stalled"]["why"], "turns");
}

/// An overloaded API's error ends no job: the round runs again in its session.
#[test]
fn a_transient_error_is_retried() {
    let (_folder, obid) = obid("long-transient");
    let id = post_job(&obid, "TRANSIENT");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["summary"], "Nothing to do.");
}
