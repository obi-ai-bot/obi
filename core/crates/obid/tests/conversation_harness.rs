//! The conversation harness (docs/conversation-harness.md, step 1; docs/runner-api.md, "obid only:
//! the conversation harness"): a conversation is a Claude Code session in its room, boxed like a
//! job, with Oby's own tools over MCP. The agent here is a stand-in (tests/agents/fake-harness).
mod support;

use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use support::*;

fn harness() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-harness")
}

/// obid with the stand-in as Claude Code and conversations on the harness; `signed_in` puts a
/// login in the account's folder.
fn obid(name: &str, signed_in: bool) -> (Folder, Obid) {
    let folder = Folder::new(name);
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &harness());
    config["conversation"] = json!({"agent": "claude"});
    let account = folder.0.join("home/accounts/stub");
    std::fs::create_dir_all(&account).unwrap();
    if signed_in {
        std::fs::write(account.join(".credentials.json"), "{}").unwrap();
    }
    let obid = start(&folder.0, &config, None);
    (folder, obid)
}

/// Every event until Oby's turn in `conversation` (not one telling how a job ended), in order.
fn until_oby_turn(events: &Receiver<(String, Value)>, seconds: u64) -> Vec<(String, Value)> {
    let give_up_at = Instant::now() + Duration::from_secs(seconds);
    let mut got = vec![];
    loop {
        let left = give_up_at.saturating_duration_since(Instant::now());
        let (name, data) = events
            .recv_timeout(left)
            .unwrap_or_else(|_| panic!("no Oby turn within {seconds} s: {got:?}"));
        let done = name == "turn" && data["who"] == "oby" && data["ended"] != true;
        got.push((name, data));
        if done {
            return got;
        }
    }
}

fn said(obid: &Obid, body: Value) -> Answer {
    let answer = call(obid, "POST", "/v1/plans", Some(&body));
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer
}

/// What the stand-in recorded of each turn, oldest first.
fn turns(obid: &Obid) -> Vec<Value> {
    std::fs::read_to_string(obid.home.join("accounts/stub/turns.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

/// A turn is an agent session: its words stream as `delta` events, each tool call is a `step`
/// with its tool and detail, and the turn ends with Oby's `turn`, the whole text. The agent runs
/// in the conversation's room with Claude Code's stream-json, partial messages and Oby's MCP.
#[test]
fn a_turn_streams_its_words_and_ends_in_a_turn() {
    let (_folder, obid) = obid("harness-stream", true);
    let events = follow_events(&obid);
    let answer = said(&obid, json!({"said": "HELLO", "new": true}));
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();
    assert_eq!(answer.body["kind"], "reply", "{}", answer.text);
    assert_eq!(answer.body["text"], "Hello there.", "{}", answer.text);

    let seen = until_oby_turn(&events, 30);
    let user = seen
        .iter()
        .find(|(n, d)| n == "turn" && d["who"] == "user")
        .map(|(_, d)| d["id"].clone())
        .expect("the user's turn");
    let deltas: Vec<&Value> = seen
        .iter()
        .filter(|(n, _)| n == "delta")
        .map(|(_, d)| d)
        .collect();
    assert!(deltas.len() >= 2, "{seen:?}");
    assert!(
        deltas
            .iter()
            .all(|d| d["conversation"] == conversation.as_str() && d["turn"] == user)
    );
    let streamed: String = deltas.iter().map(|d| d["text"].as_str().unwrap()).collect();
    assert_eq!(streamed, "Hello there.");
    let steps: Vec<&Value> = seen
        .iter()
        .filter(|(n, d)| n == "step" && d["tool"].is_string())
        .map(|(_, d)| d)
        .collect();
    assert_eq!(steps.len(), 2, "{seen:?}");
    assert_eq!(steps[0]["tool"], "read");
    assert_eq!(steps[0]["detail"], "notes.md");
    assert_eq!(steps[0]["state"], "running");
    assert_eq!(steps[1]["state"], "done");
    assert_eq!(steps[0]["conversation"], conversation.as_str());
    let (_, last) = seen.last().unwrap();
    assert_eq!(last["text"], "Hello there.");
    assert_eq!(last["conversation"], conversation.as_str());
    assert!(seen.iter().any(|(n, _)| n == "thinking"));

    let recorded = turns(&obid);
    assert_eq!(recorded.len(), 1, "{recorded:?}");
    let argv: Vec<&str> = recorded[0]["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a.as_str().unwrap())
        .collect();
    for flag in [
        "--input-format",
        "--output-format",
        "--include-partial-messages",
        "--permission-prompt-tool",
        "--strict-mcp-config",
        "--mcp-config",
    ] {
        assert!(argv.contains(&flag), "{flag}: {argv:?}");
    }
    assert!(!argv.contains(&"--resume"), "{argv:?}");
    let room = obid
        .home
        .join(format!("conversations/{conversation}/room"))
        .canonicalize()
        .unwrap();
    assert_eq!(
        Path::new(recorded[0]["cwd"].as_str().unwrap())
            .canonicalize()
            .unwrap(),
        room
    );
    assert_eq!(
        recorded[0]["prompt"].as_str().unwrap().lines().last(),
        Some("HELLO")
    );
}

/// Later turns resume the conversation's own session, also after obid restarts.
#[test]
fn a_conversation_resumes_its_session() {
    let (folder, obid) = obid("harness-resume", true);
    let first = said(&obid, json!({"said": "HELLO", "new": true}));
    let conversation = first.body["conversation"].as_str().unwrap().to_owned();
    let session = obid
        .home
        .join(format!("conversations/{conversation}/session.json"));
    let kept: Value = serde_json::from_slice(&std::fs::read(&session).unwrap()).unwrap();
    let id = kept["session"].as_str().unwrap().to_owned();
    let again = said(
        &obid,
        json!({"said": "REMEMBER", "conversation": conversation}),
    );
    assert_eq!(again.body["text"], format!("resume={id}"), "{}", again.text);
    let config: Value =
        serde_json::from_slice(&std::fs::read(folder.0.join("config.json")).unwrap()).unwrap();
    drop(obid);
    let restarted = start(&folder.0, &config, None);
    let after = said(
        &restarted,
        json!({"said": "REMEMBER", "conversation": conversation}),
    );
    assert_eq!(after.body["text"], format!("resume={id}"), "{}", after.text);
    // Another conversation has a session of its own.
    let other = said(&restarted, json!({"said": "REMEMBER", "new": true}));
    assert_eq!(other.body["text"], "resume=none", "{}", other.text);
}

/// oby_dispatch starts a job from the conversation, with the plan loop's checks: the job names the
/// conversation, and its card is on the turn. A tool's list is Oby's own.
#[test]
fn oby_dispatch_starts_a_job_whose_card_is_on_the_turn() {
    let (_folder, obid) = obid("harness-dispatch", true);
    let events = follow_events(&obid);
    let tools = said(&obid, json!({"said": "TOOLS", "new": true}));
    let conversation = tools.body["conversation"].as_str().unwrap().to_owned();
    assert_eq!(
        tools.body["text"],
        "tools: oby_jobs,oby_job,oby_dispatch,oby_tell_job,oby_stop_job,oby_inbox,oby_answer,oby_conversations",
        "{}",
        tools.text
    );
    let _ = until_oby_turn(&events, 30);

    let refused = said(
        &obid,
        json!({"said": r#"OBY oby_dispatch {"repo": "obi-e2e/nowhere", "task": "Fix it", "kind": "fix"}"#,
               "conversation": conversation}),
    );
    assert!(
        refused.body["text"]
            .as_str()
            .unwrap()
            .starts_with("oby: refused: "),
        "{}",
        refused.text
    );
    assert_eq!(refused.body["jobs"], json!([]));
    let _ = until_oby_turn(&events, 30);

    let answer = said(
        &obid,
        json!({"said": r#"OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build", "title": "Greeting"}"#,
               "conversation": conversation}),
    );
    let jobs = answer.body["jobs"].as_array().unwrap();
    assert_eq!(jobs.len(), 1, "{}", answer.text);
    assert_eq!(jobs[0]["conversation"], conversation.as_str());
    let id = jobs[0]["id"].as_str().unwrap();
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None);
    assert_eq!(job.status, 200, "{}", job.text);
    assert_eq!(job.body["conversation"], conversation.as_str());
    let seen = until_oby_turn(&events, 30);
    let (_, turn) = seen.last().unwrap();
    assert_eq!(turn["jobs"], json!([id]));
    assert!(
        seen.iter()
            .any(|(n, d)| n == "step" && d["tool"] == "oby_dispatch"),
        "{seen:?}"
    );
}

/// What widens trust is the owner's alone: a Bypass job waits for their Confirm, and the agent
/// can't answer a confirm item.
#[test]
fn owner_only_answers_become_confirm_items() {
    let (_folder, obid) = obid("harness-confirm", true);
    let answer = said(
        &obid,
        json!({"said": r#"OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build", "mode": "bypass"}"#,
               "new": true}),
    );
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();
    assert_eq!(answer.body["jobs"], json!([]), "{}", answer.text);
    assert!(
        answer.body["text"]
            .as_str()
            .unwrap()
            .contains("waits for your OK"),
        "{}",
        answer.text
    );
    let jobs = call(&obid, "GET", "/v1/jobs", None);
    assert_eq!(jobs.body.as_array().map_or(0, Vec::len), 0, "{}", jobs.text);
    let inbox = call(&obid, "GET", "/v1/inbox", None);
    let items = inbox.body.as_array().cloned().unwrap_or_default();
    let confirm = items
        .iter()
        .find(|i| i["kind"] == "confirm")
        .unwrap_or_else(|| panic!("a confirm item: {}", inbox.text));
    let item = confirm["id"].as_str().unwrap();

    let listed = said(
        &obid,
        json!({"said": "OBY oby_inbox {}", "conversation": conversation}),
    );
    assert!(
        listed.body["text"].as_str().unwrap().contains(item),
        "{}",
        listed.text
    );
    let answered = said(
        &obid,
        json!({"said": format!(r#"OBY oby_answer {{"item": "{item}", "answer": "Confirm"}}"#),
               "conversation": conversation}),
    );
    assert!(
        answered.body["text"]
            .as_str()
            .unwrap()
            .contains("only you can confirm it"),
        "{}",
        answered.text
    );
    let inbox = call(&obid, "GET", "/v1/inbox", None);
    assert!(
        inbox
            .body
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["id"] == item && i["done"].is_null()),
        "{}",
        inbox.text
    );
}

/// The room is the only place the agent writes: not its conversation's folder, not obid's home,
/// not the read-only checkouts of the repositories in repos/, which it reads. obid's policy
/// refuses what leaves the room and lets the web through, never asking the owner.
#[test]
fn the_room_cannot_write_outside_itself() {
    let (_folder, obid) = obid("harness-room", true);
    let answer = said(&obid, json!({"said": "ESCAPE", "new": true}));
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();
    assert_eq!(
        answer.body["text"], "escape: parent=no home=no repos=no config=no inside=ok readRepo=ok",
        "{}",
        answer.text
    );
    let folder = obid.home.join(format!("conversations/{conversation}"));
    assert!(!folder.join("escaped.txt").exists());
    assert!(!obid.home.join("escaped.txt").exists());
    assert!(folder.join("room/mine.txt").is_file());
    assert!(
        folder
            .join("room/repos/obi-e2e/fixture-app/package.json")
            .is_file()
    );

    let perms = said(
        &obid,
        json!({"said": "PERMS", "conversation": conversation}),
    );
    assert_eq!(
        perms.body["text"],
        "perms: Write=allow Write=deny Edit=deny WebFetch=allow Bash=deny mcp__elsewhere__run=deny",
        "{}",
        perms.text
    );
    let inbox = call(&obid, "GET", "/v1/inbox", None);
    assert_eq!(
        inbox.body.as_array().map_or(0, Vec::len),
        0,
        "the owner is never asked mid-turn: {}",
        inbox.text
    );
}

/// With no Claude Code account signed in, or a session that fails twice, the plan loop answers,
/// and says so in one line.
#[test]
fn the_plan_loop_answers_when_the_session_cant_run() {
    let (_folder, obid) = obid("harness-fallback", false);
    let answer = said(&obid, json!({"said": "HELLO", "new": true}));
    assert_eq!(
        answer.body["text"],
        "Fine.\n(Oby's plan loop answered: no Claude Code account is signed in for conversations.)",
        "{}",
        answer.text
    );
    assert!(turns(&obid).is_empty());

    std::fs::write(obid.home.join("accounts/stub/.credentials.json"), "{}").unwrap();
    let failed = said(&obid, json!({"said": "FAIL", "new": true}));
    assert_eq!(
        failed.body["text"], "Fine.\n(Oby's plan loop answered: its agent session failed twice.)",
        "{}",
        failed.text
    );
    assert_eq!(turns(&obid).len(), 2);
}
