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
    obid_with(name, json!({}), &[])
}

/// obid with `more` in its configuration and `jobs` kept in its home before it starts.
fn obid_with(name: &str, more: Value, jobs: &[obid::job::Job]) -> (Folder, Obid) {
    let folder = Folder::new(name);
    let remote = fixture(&folder.0.join("fixture"));
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude");
    let mut config = config(&folder.0, &remote, &agent);
    config["stallAfter"] = json!(3);
    for (key, value) in more.as_object().unwrap() {
        config[key] = value.clone();
    }
    let dir = folder.0.join("home/jobs");
    std::fs::create_dir_all(&dir).unwrap();
    for job in jobs {
        let path = dir.join(format!("{}.json", job.id));
        std::fs::write(path, serde_json::to_vec(job).unwrap()).unwrap();
    }
    let obid = start(&folder.0, &config, None);
    (folder, obid)
}

fn post_job(obid: &Obid, task: &str) -> String {
    post_kind(obid, "investigate", task)
}

fn post_kind(obid: &Obid, kind: &str, task: &str) -> String {
    let job = json!({"repo": "obi-e2e/fixture-app", "kind": kind, "task": task});
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
/// files in its worktree (a quiet build) keeps running too, but not past 4 windows without a word
/// (a loop touching a file isn't progress).
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
    std::thread::sleep(std::time::Duration::from_secs(8));
    let job = call(&obid, "GET", &format!("/v1/jobs/{beating}"), None).body;
    assert_eq!(job["status"], "running", "{job}");
    let job = wait(&obid, &beating);
    assert_eq!(job["stalled"]["why"], "quiet", "{job}");
}

/// A silent agent stalls after its quiet window: it writes its handoff note in one more turn of
/// its session, the job needs you (`interrupted`, #725) with `limit` and `stalled` (and a `stalled`
/// event), keeps its branch and the agent's own summary, and the Try-again words carry it on in
/// the same session.
#[test]
fn a_silent_job_stalls_with_a_handoff_note_and_carries_on() {
    let (_folder, obid) = obid("long-quiet");
    let events = follow_events(&obid);
    let id = post_job(&obid, "QUIET");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
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
    assert_eq!(
        job["reason"], "Stalled: no progress for 3 seconds.",
        "{job}"
    );
    assert_eq!(job["nextStep"], "Try again", "{job}");
    assert!(
        stalled["note"]
            .as_str()
            .unwrap()
            .contains("Failed: npm test"),
        "{job}"
    );
    // Its agent reported nothing before it went quiet: its summary is why it stopped.
    assert_eq!(job["summary"], job["reason"], "{job}");
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

/// A turn that ends while a background task of Claude Code's runs isn't the job's end (job b121d098:
/// "The build is still going. I'll continue when the monitor reports it's done."): the job waits,
/// past several quiet windows while the task is alive, says what it waits for, and goes on in the
/// turn Claude Code wakes for when the task ends.
#[test]
fn a_job_waits_for_its_background_task() {
    let (_folder, obid) = obid("long-background");
    let id = post_job(&obid, "BACKGROUND: 8000");
    within(30, "the job waits for its build", || {
        (call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body["step"]
            == "Waiting for npm run build")
            .then_some(())
    });
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["summary"], "Built.", "{job}");
    assert!(job["stalled"].is_null(), "{job}");
}

/// Waiting counts as progress only while the task is alive, and for 4 quiet windows at most with
/// no word from the agent, as a change in the worktree does: once the task ended and the agent
/// doesn't go on, or when it never ends (a server, a `--watch`), the job stalls as a quiet one does.
#[test]
fn a_background_task_is_progress_only_for_a_while() {
    let (_folder, obid) = obid("long-background-silent");
    let silent = post_job(&obid, "BACKGROUND: 1000 SILENT");
    let forever = post_job(&obid, "BACKGROUND: 0 FOREVER");
    for id in [silent, forever] {
        let job = wait(&obid, &id);
        assert_eq!(job["status"], "interrupted", "{job}");
        assert_eq!(job["stalled"]["why"], "quiet", "{job}");
    }
}

/// A Claude Code that ends before its background task does (it exits, so nothing can wake it) is
/// told once, in its session, to wait in the foreground, and goes on, the transcript saying it was
/// Oby's words; one that ends that way again needs you, never "nothing committed".
#[test]
fn a_turn_that_ends_before_its_task_goes_on_or_needs_you() {
    let (_folder, obid) = obid("long-waits");
    let id = post_job(&obid, "BACKGROUND: 0 EXIT");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["summary"], "Built in the foreground.", "{job}");
    let transcript = call(&obid, "GET", &format!("/v1/jobs/{id}/transcript"), None);
    assert!(
        transcript
            .text
            .contains("Oby told Claude Code to wait for its work in the foreground"),
        "{}",
        transcript.text
    );

    let again = post_kind(&obid, "build", "BACKGROUND: 0 EXIT ALWAYS");
    let job = wait(&obid, &again);
    assert_eq!(job["status"], "interrupted", "{job}");
    let reason = job["reason"].as_str().unwrap();
    assert!(
        reason.starts_with("Stopped waiting: The build is still going.")
            && reason.contains("nothing wakes it"),
        "{job}"
    );
    assert_eq!(job["nextStep"], "Try again", "{job}");
}

/// The same failing call 5 times in a row stalls the job as looping, with the agent's note.
#[test]
fn a_looping_job_stalls() {
    let (_folder, obid) = obid("long-loop");
    let id = post_job(&obid, "LOOP");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(job["limit"], "the same failing call 5 times");
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

/// A committing job that stalls keeps its commit on its branch and publishes nothing.
#[test]
fn a_committing_job_that_stalls_publishes_nothing() {
    // A quiet window git's commit fits in on a busy machine (it took over 10 s at load 500).
    let (_folder, obid) = obid_with("long-commit-quiet", json!({"stallAfter": 30}), &[]);
    let id = post_kind(&obid, "build", "COMMIT: a.txt QUIET");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(job["stalled"]["why"], "quiet", "{job}");
    assert_eq!(job["stalled"]["commits"], 1, "{job}");
    assert!(job["stalled"]["commit"].is_string(), "{job}");
    assert_eq!(job["commits"], 1, "{job}");
    assert!(
        job["published"].is_null() && job["pushed"].is_null(),
        "{job}"
    );
    assert!(job["outgoing"].as_array().unwrap().is_empty(), "{job}");
}

/// An error trying again won't mend fails the job at once, with no retry.
#[test]
fn a_permanent_error_is_not_retried() {
    let (_folder, obid) = obid("long-permanent");
    let events = follow_events(&obid);
    let id = post_job(&obid, "FAIL");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(job["summary"], "it broke");
    assert!(job["stalled"].is_null(), "{job}");
    let retried = std::iter::from_fn(|| events.try_recv().ok()).any(|(name, job)| {
        name == "job"
            && job["step"]
                .as_str()
                .is_some_and(|s| s.starts_with("Retrying"))
    });
    assert!(!retried);
}

/// A transient error every time: three retries, then the job needs you with it (not stalled).
#[test]
fn retries_run_out() {
    let (_folder, obid) = obid("long-retries-out");
    let events = follow_events(&obid);
    let id = post_job(&obid, "TRANSIENT ALWAYS");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert!(job["summary"].as_str().unwrap().contains("529"), "{job}");
    assert!(job["stalled"].is_null(), "{job}");
    let steps: Vec<String> = std::iter::from_fn(|| events.try_recv().ok())
        .filter(|(name, _)| name == "job")
        .filter_map(|(_, job)| job["step"].as_str().map(str::to_owned))
        .filter(|step| step.starts_with("Retrying after"))
        .collect();
    for n in 1..=3 {
        assert!(
            steps.iter().any(|s| s.ends_with(&format!("({n} of 3)"))),
            "{steps:?}"
        );
    }
}

/// The token budget stalls a job. Past it, Try again or other words through the API (what oby-mcp
/// and other sessions call) do nothing but ask the owner in the inbox, once per kind however often
/// they're sent; their Confirm carries it on with a new budget.
#[test]
fn the_token_budget_stalls_and_only_the_owners_confirm_carries_on() {
    let (_folder, obid) = obid_with("long-budget", json!({"jobTokenBudget": 1000}), &[]);
    let id = post_job(&obid, "SPEND: 5000");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(job["limit"], "the job used 1000 tokens", "{job}");
    assert_eq!(job["stalled"]["why"], "budget");
    // A safety stall is never tried again by itself, whatever any reset says (#740).
    assert_eq!(job["resumesAt"], Value::Null, "{job}");
    let confirms = || -> Vec<Value> {
        let inbox = call(&obid, "GET", "/v1/inbox", None).body;
        inbox
            .as_array()
            .unwrap()
            .iter()
            .filter(|i| i["kind"] == "confirm" && i["job"] == id.as_str())
            .cloned()
            .collect()
    };
    // Asked again and again (a looping caller), each kind of item comes once.
    for words in [
        TRY_AGAIN,
        "start it again from scratch",
        TRY_AGAIN,
        "start it again from scratch",
    ] {
        let answer = call(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/messages"),
            Some(&json!({"text": words})),
        );
        assert_eq!(answer.status, 422, "{}", answer.text);
        assert!(
            answer.text.contains("waits for your Confirm"),
            "{}",
            answer.text
        );
    }
    // Its Confirm takes words only: files with them are refused, rather than dropped.
    let file = obid.home.join("attachments/shot.png");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, b"png").unwrap();
    let with_files = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(
            &json!({"text": "start it again from scratch", "attachments": [file.to_str().unwrap()]}),
        ),
    );
    assert_eq!(with_files.status, 422, "{}", with_files.text);
    assert!(
        with_files.text.contains("takes words only"),
        "{}",
        with_files.text
    );
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["status"], "interrupted", "{job}");
    assert!(job["followUpOf"].is_null());
    let items = confirms();
    assert_eq!(items.len(), 2, "{items:?}");
    assert!(
        items
            .iter()
            .all(|i| i["text"].as_str().unwrap().contains("safety limit"))
    );
    let retry = items
        .iter()
        .find(|i| i["title"].as_str().unwrap().starts_with("Try "))
        .expect("Try again's item");
    let answer = confirm(&obid, retry["id"].as_str().unwrap());
    assert_eq!(answer.status, 200, "{}", answer.text);
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert!(job["stalled"].is_null(), "{job}");
}

/// The ceiling counts the time of every run before (a restart, a Try again): a job that already
/// ran its hour stalls at once, and obid writes its note.
#[test]
fn the_ceiling_counts_every_run() {
    let mut job = obid::job::Job::new(
        "ce111ng0".into(),
        "obi-e2e/fixture-app".into(),
        "investigate".into(),
        "CHATTY: 600000".into(),
        "claude".into(),
        "stub".into(),
    );
    job.branch = "oby/investigate-ce111ng0".into();
    job.ran_secs = Some(3600);
    let (_folder, obid) = obid_with("long-ceiling", json!({"jobCeilingHours": 1}), &[job]);
    let job = wait(&obid, "ce111ng0");
    // It never had a session to pick up: a dead end (#725), its stall kept.
    assert_eq!(job["status"], "failed", "{job}");
    assert_eq!(job["limit"], "the job ran 1 hour", "{job}");
    assert_eq!(job["stalled"]["why"], "ceiling");
    assert_eq!(job["stalled"]["noteBy"], "obid");
}
