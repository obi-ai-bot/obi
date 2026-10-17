//! The failure records as the apps see them: the real obid binary, asked over HTTP
//! (docs/runner-api.md, "Failure record", `GET /v1/failures?limit=50`, `GET /v1/failures/{id}`,
//! `POST /v1/failures/{id}/fix`). Ported from RunnerTests' `FailureTests.theAPIListsFailuresAndFixesThem`,
//! with a stand-in agent (tests/agents/fake-claude) run by obid's Claude Code adapter.
mod support;

use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};
use support::*;

fn fake_claude() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude")
}

fn post_job(obid: &Obid, job: Value) -> String {
    let answer = call(obid, "POST", "/v1/jobs", Some(&json!({ "job": job })));
    assert_eq!(answer.status, 201, "{}", answer.text);
    answer.body["id"].as_str().unwrap().to_owned()
}

fn wait(obid: &Obid, id: &str) -> Value {
    let answer = call(obid, "GET", &format!("/v1/jobs/{id}/wait"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

fn failures(obid: &Obid, query: &str) -> Vec<Value> {
    let answer = call(obid, "GET", &format!("/v1/failures{query}"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body.as_array().expect("a list").clone()
}

/// FailureTests.theAPIListsFailuresAndFixesThem: a job that failed and one stopped at a limit are
/// recorded, newest first, once each, kept across a restart; one that ended done or was stopped
/// isn't. A record is read by its id, the limit is capped, and Fix it refuses a record that
/// isn't studied (obid makes no post-mortem yet). The evidence holds no secret obid knows.
#[test]
fn the_api_lists_failures_and_fixes_them() {
    let folder = Folder::new("failures-api");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &fake_claude());
    let mut obid = start(&folder.0, &config, None);

    // Done, and stopped by the owner: not failures.
    let done = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Look around"}),
    );
    assert_eq!(wait(&obid, &done)["status"], "done");
    let stopped = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "SLEEP"}),
    );
    within(30, "the sleeping job runs", || {
        (call(&obid, "GET", &format!("/v1/jobs/{stopped}"), None).body["status"] == "running")
            .then_some(())
    });
    let answer = call(&obid, "POST", &format!("/v1/jobs/{stopped}/stop"), None);
    assert_eq!(answer.body["status"], "stopped", "{}", answer.text);

    // The older: a fix that commits nothing fails.
    let older = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Look around"}),
    );
    assert_eq!(wait(&obid, &older)["status"], "failed");
    // Records are dated to the second: the newer ends in a later one.
    std::thread::sleep(Duration::from_millis(1100));
    // The newer: a check that keeps failing, and prints obid's API token, stops at a limit.
    let newer = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: a.txt",
               "check": format!("echo the check failed {TOKEN}; false"), "rounds": 1}),
    );
    let job = wait(&obid, &newer);
    assert_eq!(job["status"], "failed");
    assert!(job["limit"].is_string(), "{job}");

    let list = failures(&obid, "");
    let jobs: Vec<&str> = list.iter().map(|r| r["job"].as_str().unwrap()).collect();
    assert_eq!(jobs, [newer.as_str(), older.as_str()], "{list:?}");
    let first = &list[0];
    assert_eq!(first["trigger"], "limit");
    assert_eq!(first["postMortem"], Value::Null);
    assert_eq!(first["intervention"], false);
    assert_eq!(first["repo"], "obi-e2e/fixture-app");
    assert!(first["date"].as_str().unwrap().ends_with('Z'), "{first}");
    assert!(
        first["what"]
            .as_str()
            .unwrap()
            .starts_with("Stopped at a limit: "),
        "{first}"
    );
    let check = first["evidence"]["check"].as_str().unwrap();
    assert!(check.contains("the check failed"), "{check}");
    assert!(!first.to_string().contains(TOKEN), "a secret in {first}");
    assert!(check.contains("[redacted: api-token]"), "{check}");
    assert_eq!(list[1]["trigger"], "failed");
    assert_eq!(list[1]["what"], "It failed.");
    // Its repository's check ran, and passed, before it failed with nothing committed.
    let check = list[1]["evidence"]["check"].as_str().unwrap();
    assert!(
        check.starts_with("`node --test` printed (its end):\n"),
        "{check}"
    );
    assert_eq!(
        list[1]["evidence"]["summary"],
        "Nothing committed: Nothing to do."
    );
    // Every key the API promises, null where obid has nothing.
    for key in [
        "rounds",
        "studyError",
        "issue",
        "issueError",
        "fix",
        "fixedBy",
        "fixedAt",
    ] {
        assert!(list[1].get(key).is_some(), "{key} in {}", list[1]);
    }
    for key in ["worktree", "source"] {
        assert_eq!(list[1]["evidence"][key], Value::Null, "{key}");
    }
    assert_eq!(list[1]["evidence"]["reviews"], json!([]));

    let id = list[1]["id"].as_str().unwrap().to_owned();
    let one = call(&obid, "GET", &format!("/v1/failures/{id}"), None);
    assert_eq!(one.status, 200, "{}", one.text);
    assert_eq!(one.body["trigger"], "failed");
    assert_eq!(one.body["job"], older.as_str());

    // A limit past what a 32-bit number holds is capped, not a crash; below 0 is none.
    for (limit, count) in [("3000000000", 2), ("-5", 0), ("1", 1)] {
        assert_eq!(
            failures(&obid, &format!("?limit={limit}")).len(),
            count,
            "{limit}"
        );
    }
    for unknown in ["nowhere", "..%2Fjobs%2F{older}", "..", "a.b"] {
        let target = format!("/v1/failures/{}", unknown.replace("{older}", &older));
        assert_eq!(call(&obid, "GET", &target, None).status, 404, "{target}");
    }
    assert_eq!(
        call(&obid, "POST", "/v1/failures/nowhere/fix", None).status,
        404
    );
    // Not studied yet: nothing to fix.
    let fix = call(&obid, "POST", &format!("/v1/failures/{id}/fix"), None);
    assert_eq!(fix.status, 409, "{}", fix.text);
    assert_eq!(fix.body["error"], "Oby hasn't studied this failure yet.");

    // Each is recorded once: dismissing the job changes it, and nothing new is recorded.
    let dismissed = call(&obid, "POST", &format!("/v1/jobs/{older}/dismiss"), None);
    assert_eq!(dismissed.status, 200, "{}", dismissed.text);
    assert_eq!(failures(&obid, "").len(), 2);

    // Kept for good: a restart reads them back.
    assert!(obid.stop().success());
    let obid = start(&folder.0, &config, None);
    assert_eq!(failures(&obid, ""), list);
}
