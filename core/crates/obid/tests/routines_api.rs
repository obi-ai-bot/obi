//! Routines (#395, docs/runner-api.md, "obid only: routines"): made, listed, paused, run now and
//! deleted over the API, and a routine that was due while obid was off run once when it starts,
//! as a job with the routine's mark, in the routine's conversation, with the missed time recorded.
mod support;

use serde_json::{Value, json};
use support::*;

fn obid(folder: &Folder) -> Obid {
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &stub_agent());
    start(&folder.0, &config, None)
}

fn routine(name: &str) -> Value {
    json!({"name": name, "repo": "obi-e2e/fixture-app", "kind": "investigate",
           "task": "Say what the README covers.", "schedule": {"every": "weekdays", "at": "09:00"},
           "zone": "America/Sao_Paulo", "createdBy": "mac"})
}

#[test]
fn routines_are_made_paused_run_and_deleted() {
    let folder = Folder::new("routines-api");
    let obid = obid(&folder);

    // What obid can't run is refused, with why.
    for (change, why) in [
        (json!({"zone": "Mars/Olympus"}), "time zone"),
        (json!({"repo": "nobody/nothing"}), "repository"),
        (
            json!({"schedule": {"every": "daily", "at": "9am"}}),
            "HH:MM",
        ),
        (json!({"name": ""}), "name"),
    ] {
        let mut body = routine("Readme check");
        for (key, value) in change.as_object().unwrap() {
            body[key] = value.clone();
        }
        let refused = call(&obid, "POST", "/v1/routines", Some(&body));
        assert_eq!(refused.status, 422, "{change}: {}", refused.text);
        assert!(refused.text.contains(why), "{change}: {}", refused.text);
    }
    let unknown = call(
        &obid,
        "POST",
        "/v1/routines",
        Some(&json!({"name": "x", "every": "day"})),
    );
    assert_eq!(unknown.status, 400, "{}", unknown.text);

    let made = call(
        &obid,
        "POST",
        "/v1/routines",
        Some(&routine("Readme check")),
    );
    assert_eq!(made.status, 201, "{}", made.text);
    let id = made.body["id"].as_str().unwrap().to_owned();
    assert_eq!(made.body["when"], "Weekdays at 9:00");
    assert_eq!(made.body["enabled"], true);
    assert!(made.body["nextRun"].is_string(), "{}", made.body);
    assert_eq!(made.body["lastRun"], Value::Null);
    // A client can't say the brain made it: only the owner's Confirm of a chat routine does.
    let mut claims = routine("Claims chat");
    claims["createdBy"] = json!("chat");
    let claimed = call(&obid, "POST", "/v1/routines", Some(&claims));
    assert_eq!(claimed.body["createdBy"], "app", "{}", claimed.text);
    let other = claimed.body["id"].as_str().unwrap();
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/routines/{other}"), None).status,
        204
    );
    let listed = call(&obid, "GET", "/v1/routines", None);
    assert_eq!(listed.body.as_array().unwrap().len(), 1);

    // Paused: no next run.
    let paused = call(
        &obid,
        "PATCH",
        &format!("/v1/routines/{id}"),
        Some(&json!({"enabled": false})),
    );
    assert_eq!(paused.status, 200, "{}", paused.text);
    assert_eq!(paused.body["nextRun"], Value::Null);

    // Run now, paused or not: a job with the routine's mark, and a turn in the conversation
    // obid started for it, with the job's card.
    let ran = call(&obid, "POST", &format!("/v1/routines/{id}/run"), None);
    assert_eq!(ran.status, 201, "{}", ran.text);
    let job = &ran.body["job"];
    assert_eq!(job["routine"]["id"], id.as_str());
    assert_eq!(job["routine"]["name"], "Readme check");
    assert_eq!(job["title"], "Readme check");
    let conversation = ran.body["routine"]["conversation"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(job["conversation"], conversation.as_str());
    assert_eq!(ran.body["routine"]["lastRun"]["outcome"], "started");
    let turns = call(
        &obid,
        "GET",
        &format!("/v1/conversation?id={conversation}"),
        None,
    );
    let turn = turns.body.as_array().unwrap().last().unwrap().clone();
    assert_eq!(turn["who"], "oby");
    assert_eq!(turn["routine"]["id"], id.as_str());
    assert_eq!(turn["jobs"], json!([job["id"]]));
    assert!(
        turn["text"]
            .as_str()
            .unwrap()
            .starts_with("Readme check started a run now"),
        "{turn}"
    );

    // While that run's job is still going, another is refused.
    let again = call(&obid, "POST", &format!("/v1/routines/{id}/run"), None);
    let first = call(
        &obid,
        "GET",
        &format!("/v1/jobs/{}", job["id"].as_str().unwrap()),
        None,
    );
    if again.status == 201 {
        // It had ended already: then the second run was rightly let through.
        assert!(
            !matches!(first.body["status"].as_str(), Some("queued" | "running")),
            "{}",
            first.body
        );
    } else {
        assert_eq!(again.status, 409, "{}", again.text);
    }

    let deleted = call(&obid, "DELETE", &format!("/v1/routines/{id}"), None);
    assert_eq!(deleted.status, 204, "{}", deleted.text);
    assert_eq!(
        call(&obid, "GET", &format!("/v1/routines/{id}"), None).status,
        404
    );
    // The job its run started stays.
    assert_eq!(first.status, 200);
}

#[test]
fn a_routine_due_while_obid_was_off_runs_once_when_it_starts() {
    let folder = Folder::new("routines-catch-up");
    let now = obi_protocol::time::now();
    // Every day at 00:00 UTC, last run three days ago: two times were missed, one runs.
    let dir = folder.0.join("home/routines");
    std::fs::create_dir_all(&dir).unwrap();
    let saved = json!({"id": "c0ffee01", "name": "Nightly readme", "repo": "obi-e2e/fixture-app",
        "kind": "investigate", "task": "Say what the README covers.", "agent": "auto",
        "account": "auto", "mode": null, "check": null, "rounds": 1,
        "schedule": {"every": "daily", "at": "00:00"}, "zone": "UTC", "enabled": true,
        "created": now - 10 * 86_400, "createdBy": "mac", "conversation": null,
        "lastFire": now - now.rem_euclid(86_400) - 3 * 86_400, "failuresInARow": 0, "runs": []});
    std::fs::write(dir.join("c0ffee01.json"), saved.to_string()).unwrap();
    // One whose account is gone: its run can't start, its third failure in a row, so it pauses.
    let mut ghost = saved.clone();
    ghost["id"] = json!("dead0001");
    ghost["name"] = json!("Ghost check");
    ghost["account"] = json!("ghost");
    ghost["failuresInARow"] = json!(2);
    std::fs::write(dir.join("dead0001.json"), ghost.to_string()).unwrap();
    let obid = obid(&folder);

    // It runs within its first check, as obid starts.
    let give_up_at = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let routine = loop {
        let routine = call(&obid, "GET", "/v1/routines/c0ffee01", None).body;
        if routine["runs"].as_array().is_some_and(|r| r.len() >= 2) {
            break routine;
        }
        assert!(
            std::time::Instant::now() < give_up_at,
            "no run: {routine} {}",
            obid.log()
        );
        std::thread::sleep(std::time::Duration::from_millis(200));
    };
    let runs = routine["runs"].as_array().unwrap();
    assert_eq!(runs.len(), 2, "{routine}");
    // Newest first: the catch-up for the latest time, then the missed ones before it.
    assert_eq!(runs[0]["outcome"], "started", "{routine}");
    assert_eq!(runs[0]["catchUp"], true);
    assert_eq!(
        runs[0]["scheduled"],
        obi_protocol::time::format(now - now.rem_euclid(86_400))
    );
    assert_eq!(runs[1]["outcome"], "missed");
    assert_eq!(runs[1]["reason"], "Missed 2 runs while Oby wasn't running.");
    let job = call(
        &obid,
        "GET",
        &format!("/v1/jobs/{}", runs[0]["job"].as_str().unwrap()),
        None,
    );
    assert_eq!(job.body["routine"]["catchUp"], true, "{}", job.body);
    let conversation = routine["conversation"].as_str().unwrap();
    let turns = call(
        &obid,
        "GET",
        &format!("/v1/conversation?id={conversation}"),
        None,
    );
    let texts: Vec<&str> = turns
        .body
        .as_array()
        .unwrap()
        .iter()
        .filter(|t| t["routine"].is_object())
        .map(|t| t["text"].as_str().unwrap())
        .collect();
    assert_eq!(
        texts,
        ["Nightly readme started its 0:00 run, which it missed while Oby wasn't running."]
    );
    let ghost = call(&obid, "GET", "/v1/routines/dead0001", None).body;
    assert_eq!(ghost["runs"][0]["outcome"], "failed", "{ghost}");
    assert_eq!(ghost["runs"][0]["reason"], "There's no account ghost.");
    assert_eq!(ghost["enabled"], false, "{ghost}");
    assert_eq!(ghost["failuresInARow"], 3);
    let conversation = ghost["conversation"].as_str().unwrap();
    let said: Vec<String> = call(
        &obid,
        "GET",
        &format!("/v1/conversation?id={conversation}"),
        None,
    )
    .body
    .as_array()
    .unwrap()
    .iter()
    .map(|t| t["text"].as_str().unwrap().to_owned())
    .collect();
    assert_eq!(
        said,
        [
            "Ghost check couldn't start its 0:00 run: There's no account ghost.",
            "Ghost check failed 3 times in a row, so it's paused. Turn it back on in Settings › Routines."
        ]
    );
    // The time it acted on is kept: nothing more runs for it.
    std::thread::sleep(std::time::Duration::from_secs(1));
    let after = call(&obid, "GET", "/v1/routines/c0ffee01", None).body;
    assert_eq!(after["runs"].as_array().unwrap().len(), 2, "{after}");
}
