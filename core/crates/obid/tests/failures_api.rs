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

/// FailureTests.theAPIListsFailuresAndFixesThem: a job that needs you and one stopped at a limit are
/// recorded, newest first, kept across a restart; one that ended done (nothing committed too) or
/// was stopped isn't (that
/// each is recorded once is src/failures.rs `a_failure_is_recorded_once_whatever_the_job_says_later`). A record is read by its id, the limit is capped, and Fix it refuses a record that
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

    // A fix that commits nothing is done, not a failure: never recorded.
    let nothing = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Look around"}),
    );
    assert_eq!(wait(&obid, &nothing)["status"], "done");
    // The older: a check that fails as the task asked needs you, and is recorded.
    let older = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: a.txt, a test that fails ON PURPOSE",
               "check": "echo the check failed; false", "rounds": 3}),
    );
    assert_eq!(wait(&obid, &older)["status"], "interrupted");
    // Records are dated to the second: the newer ends in a later one.
    std::thread::sleep(Duration::from_millis(1100));
    // The newer: a check that keeps failing, and prints obid's API token, stops at a limit.
    let newer = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: a.txt",
               "check": format!("echo the check failed {TOKEN}; false"), "rounds": 1}),
    );
    let job = wait(&obid, &newer);
    assert_eq!(job["status"], "interrupted");
    assert!(job["limit"].is_string(), "{job}");

    let list = failures(&obid, "");
    let jobs: Vec<&str> = list.iter().map(|r| r["job"].as_str().unwrap()).collect();
    assert_eq!(jobs, [newer.as_str(), older.as_str()], "{list:?}");
    let first = &list[0];
    assert_eq!(first["trigger"], "limit");
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
    assert_eq!(list[1]["what"], "It stopped part way and needs you.");
    let check = list[1]["evidence"]["check"].as_str().unwrap();
    assert!(
        check.starts_with("`echo the check failed; false` printed (its end):\n"),
        "{check}"
    );
    // The agent's own summary, kept.
    assert!(
        list[1]["evidence"]["summary"]
            .as_str()
            .unwrap()
            .starts_with("FAILS AS ASKED"),
        "{}",
        list[1]
    );
    // Every key the API promises, sent: null, empty or none where obid has nothing (a key left
    // out would read as null too, so each is looked up as itself).
    for record in &list {
        let has = |key: &str, value: Value| {
            assert_eq!(record.get(key), Some(&value), "{key} in {record}");
        };
        for key in [
            "postMortem",
            "studyError",
            "issue",
            "issueError",
            "fix",
            "fixedBy",
            "fixedAt",
        ] {
            has(key, Value::Null);
        }
        has("intervention", json!(false));
        has("tries", json!(0));
        has("acted", json!(false));
        assert!(record.get("rounds").is_some_and(Value::is_u64), "{record}");
        let evidence = &record["evidence"];
        for (key, value) in [
            ("worktree", Value::Null),
            ("source", Value::Null),
            ("reviews", json!([])),
            ("log", json!([])),
        ] {
            assert_eq!(evidence.get(key), Some(&value), "{key} in {evidence}");
        }
    }

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

    // Kept for good: a restart reads them back.
    assert!(obid.stop().success());
    let obid = start(&folder.0, &config, None);
    assert_eq!(failures(&obid, ""), list);
}
