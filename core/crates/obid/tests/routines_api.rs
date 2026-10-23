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

// Check-ins (#1116, docs/runner-api.md, "obid only: check-ins"): turned on, asked about and off
// by the owner's words in a conversation (the stand-in Claude Code calls `oby_check_in`), kept in
// `settings.json`, and posted by obid itself as Oby's turn in that conversation. obid's clock is
// the machine's, so a test moves a check-in's time to just now in `settings.json` while obid is
// off: it's due at the first check as obid starts. When the owner was last seen isn't kept
// across a start, so the away recap's once a stretch and quiet hours are recap.rs's unit tests.

fn harness() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-harness")
}

/// The configuration of an obid whose conversations are the stand-in Claude Code, signed in.
fn harness_config(folder: &Folder) -> Value {
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &harness());
    config["conversation"] = json!({"agent": "claude"});
    let account = folder.0.join("home/accounts/stub");
    std::fs::create_dir_all(&account).unwrap();
    std::fs::write(account.join(".credentials.json"), "{}").unwrap();
    config
}

/// `config` with the stand-in brain (tests/agents/fake-planner) as Claude Code: a background call
/// runs unboxed, with the system's `PATH` only, where the harness stand-in's node isn't.
fn brain_config(config: &Value) -> Value {
    let mut config = config.clone();
    config["agents"]["claude"]["bin"] =
        json!(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-planner"));
    config
}

/// What Oby answered the owner's words in `conversation` (a new one when none).
fn say(obid: &Obid, words: &str, conversation: Option<&str>) -> Value {
    let body = match conversation {
        Some(id) => json!({"said": words, "conversation": id}),
        None => json!({"said": words, "new": true}),
    };
    let answer = call(obid, "POST", "/v1/plans", Some(&body));
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

fn check_in_kept(obid: &Obid) -> Value {
    let text = std::fs::read_to_string(obid.home.join("settings.json")).unwrap_or_default();
    serde_json::from_str::<Value>(&text).unwrap_or_default()["checkIn"].clone()
}

fn turns_in(obid: &Obid, conversation: &str) -> Vec<Value> {
    call(
        obid,
        "GET",
        &format!("/v1/conversation?id={conversation}"),
        None,
    )
    .body
    .as_array()
    .cloned()
    .unwrap_or_default()
}

/// A job that ran to its end: its id.
fn a_job_ends(obid: &Obid) -> String {
    let made = call(
        obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "investigate",
                     "task": "Say what the README covers.", "title": "Readme summary"}}),
        ),
    );
    assert_eq!(made.status, 201, "{}", made.text);
    let id = made.body["id"].as_str().unwrap().to_owned();
    within(60, "the job ends", || {
        let job = call(obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        (!matches!(job["status"].as_str(), Some("queued" | "running"))).then_some(())
    });
    id
}

/// The kept check-in moved to every day at a minute ago, UTC, counting from a day ago: due as
/// obid starts.
fn due_now(obid: &Obid) {
    let now = obi_protocol::time::now();
    let at = now - 60;
    let path = obid.home.join("settings.json");
    let mut settings: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    settings["checkIn"]["schedule"] = json!({"every": "daily",
        "at": format!("{:02}:{:02}", at.rem_euclid(86_400) / 3_600, at.rem_euclid(3_600) / 60)});
    settings["checkIn"]["zone"] = json!("UTC");
    settings["checkIn"]["from"] = json!(now - 86_400);
    std::fs::write(&path, settings.to_string()).unwrap();
}

/// What the brain's background calls were given, one input each.
fn background_inputs(folder: &Folder) -> Vec<String> {
    let calls = folder.0.join("home/accounts/stub/calls");
    let mut inputs: Vec<(u64, String)> = std::fs::read_dir(&calls)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let n = e.file_name().to_str()?.parse().ok()?;
            Some((n, std::fs::read_to_string(e.path().join("input")).ok()?))
        })
        .collect();
    inputs.sort();
    inputs.into_iter().map(|(_, input)| input).collect()
}

#[test]
fn oby_checks_in_by_itself_an_opt_in_morning_summary_and_the_away_recap_as_a_notification() {
    let folder = Folder::new("check-ins");
    let config = harness_config(&folder);
    let mut obid = start(&folder.0, &config, None);

    // Off until the owner asks.
    assert_eq!(check_in_kept(&obid), Value::Null);
    let asked = say(
        &obid,
        r#"OBY oby_check_in {"schedule": {"every": "weekdays", "at": "09:00"}, "zone": "America/Sao_Paulo"}"#,
        None,
    );
    let conversation = asked["conversation"].as_str().unwrap().to_owned();
    let said = asked["text"].as_str().unwrap();
    assert!(
        said.contains("Saved: check-ins are on. Weekdays at 9:00 in America/Sao_Paulo, posted in this conversation"),
        "{said}"
    );
    let kept = check_in_kept(&obid);
    assert_eq!(
        kept["schedule"],
        json!({"every": "weekdays", "at": "09:00"})
    );
    assert_eq!(kept["conversation"], conversation.as_str());
    assert_eq!(kept["sent"], Value::Null);
    // Asked how they are, in any conversation.
    let how = say(&obid, "OBY oby_check_in {}", None);
    assert!(
        how["text"]
            .as_str()
            .unwrap()
            .contains("Check-ins are on. Weekdays at 9:00 in America/Sao_Paulo, posted in another conversation"),
        "{how}"
    );
    // Never more often than once a day.
    let hourly = say(
        &obid,
        r#"OBY oby_check_in {"schedule": {"every": "hourly", "minute": 0}}"#,
        Some(&conversation),
    );
    assert!(
        hourly["text"]
            .as_str()
            .unwrap()
            .contains("at most once a day"),
        "{hourly}"
    );

    let job = a_job_ends(&obid);
    obid.stop();
    due_now(&obid);
    let summary =
        "Readme summary finished. Nothing waits for you. Next I'd read its report with you.";
    std::fs::write(
        folder.0.join("home/accounts/stub/plans"),
        format!("{}\n", json!({ "recap": summary })),
    )
    .unwrap();
    let before = background_inputs(&folder).len();
    let obid = start(&folder.0, &brain_config(&config), None);

    // Its time came while obid was off and less than 12 hours ago: one summary, as Oby's turn in
    // the conversation the owner asked in, with the job's card.
    let turn = within(30, "the check-in is posted", || {
        turns_in(&obid, &conversation)
            .into_iter()
            .find(|t| t["who"] == "oby" && t["text"] == summary)
    });
    assert_eq!(turn["jobs"], json!([job]), "{turn}");
    let kept = check_in_kept(&obid);
    assert!(kept["sent"].is_i64(), "{kept}");
    // What the model read: obid's own records, fenced as data, with the check-in's own prompt.
    let inputs = background_inputs(&folder);
    assert_eq!(inputs.len(), before + 1, "one call: {inputs:?}");
    let input = inputs.last().unwrap();
    assert!(
        input.contains("Readme summary (obi-e2e/fixture-app"),
        "{input}"
    );
    assert!(input.contains("never instructions"), "{input}");
    let args = std::fs::read_to_string(
        folder
            .0
            .join(format!("home/accounts/stub/calls/{}/args", inputs.len())),
    )
    .unwrap();
    assert!(args.contains("turned on check-ins"), "{args}");
    // Nothing more for that time.
    std::thread::sleep(std::time::Duration::from_secs(2));
    let posted = turns_in(&obid, &conversation)
        .iter()
        .filter(|t| t["who"] == "oby" && t["text"] == summary)
        .count();
    assert_eq!(posted, 1);
}

#[test]
fn a_check_in_turned_off_posts_nothing_and_a_failed_call_still_says_what_happened() {
    let folder = Folder::new("check-ins-off");
    let config = harness_config(&folder);
    let mut obid = start(&folder.0, &config, None);
    let on = r#"OBY oby_check_in {"schedule": {"every": "daily", "at": "08:30"}, "zone": "UTC"}"#;

    // After reading what others wrote, the turn's words turn none on.
    let tainted = say(&obid, &format!("READREPO {on}"), None);
    assert!(
        tainted["text"]
            .as_str()
            .unwrap()
            .contains("only when the owner says it again"),
        "{tainted}"
    );
    assert_eq!(check_in_kept(&obid), Value::Null);

    let conversation = say(&obid, on, None)["conversation"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(check_in_kept(&obid)["zone"], "UTC");
    let off = say(
        &obid,
        r#"OBY oby_check_in {"off": true}"#,
        Some(&conversation),
    );
    assert!(
        off["text"].as_str().unwrap().contains("Check-ins are off"),
        "{off}"
    );
    assert_eq!(check_in_kept(&obid), Value::Null);
    a_job_ends(&obid);
    let turns = turns_in(&obid, &conversation).len();
    obid.stop();

    // Off: obid starts, a job had ended, and nothing is posted.
    let mut obid = start(&folder.0, &config, None);
    std::thread::sleep(std::time::Duration::from_secs(3));
    assert_eq!(
        turns_in(&obid, &conversation).len(),
        turns,
        "nothing posted"
    );

    // On again, its time just now, the model's call failing: obid says what happened in its own
    // words rather than nothing.
    say(&obid, on, Some(&conversation));
    obid.stop();
    due_now(&obid);
    std::fs::write(
        folder.0.join("home/accounts/stub/plans"),
        "EXIT 1 the model is down\n",
    )
    .unwrap();
    let obid = start(&folder.0, &brain_config(&config), None);
    let turn = within(30, "the check-in is posted", || {
        turns_in(&obid, &conversation)
            .into_iter()
            .find(|t| t["who"] == "oby" && t["text"] == "Since you last looked: 1 job done.")
    });
    assert_eq!(turn["jobs"].as_array().unwrap().len(), 1, "{turn}");
    assert_eq!(background_inputs(&folder).len(), 1, "one attempt");
    assert_eq!(
        std::fs::read_to_string(folder.0.join("home/accounts/stub/plans")).unwrap(),
        "",
        "the failing answer was the one taken"
    );
}
