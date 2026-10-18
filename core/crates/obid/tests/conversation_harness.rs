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
    obid_with(name, signed_in, json!({"agent": "claude"}))
}

/// [`obid`], with `conversation` as the configuration's.
fn obid_with(name: &str, signed_in: bool, conversation: Value) -> (Folder, Obid) {
    let folder = Folder::new(name);
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &harness());
    config["conversation"] = conversation;
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

/// What the stand-in recorded of each conversation turn, oldest first (each conversation's
/// session has a config folder of its own).
fn turns(obid: &Obid) -> Vec<Value> {
    let mut all: Vec<Value> = std::fs::read_dir(obid.home.join("conversations"))
        .into_iter()
        .flatten()
        .flatten()
        .flat_map(|entry| recorded(&entry.path().join("config/turns.jsonl")))
        .collect();
    all.sort_by_key(|t| t["at"].as_u64());
    all
}

/// What the stand-in recorded as the jobs' agent, in the account's own folder.
fn job_turns(obid: &Obid) -> Vec<Value> {
    recorded(&obid.home.join("accounts/stub/turns.jsonl"))
}

fn recorded(file: &Path) -> Vec<Value> {
    std::fs::read_to_string(file)
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

/// A job, once it has ended.
fn ended(obid: &Obid, id: &str) -> Value {
    within(60, "the job ends", || {
        let job = call(obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        (!matches!(job["status"].as_str(), Some("queued" | "running"))).then_some(job)
    })
}

fn inbox(obid: &Obid) -> Vec<Value> {
    call(obid, "GET", "/v1/inbox", None)
        .body
        .as_array()
        .cloned()
        .unwrap_or_default()
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
        "--restricted",
        "--tools",
        "--mcp-config",
    ] {
        assert!(argv.contains(&flag), "{flag}: {argv:?}");
    }
    assert!(!argv.contains(&"--resume"), "{argv:?}");
    // The built-in tools name no Bash or other code-runner (N2).
    let tools = argv[argv.iter().position(|a| *a == "--tools").unwrap() + 1];
    assert!(
        tools.contains("Read") && tools.contains("WebFetch"),
        "{tools}"
    );
    for runner in ["Bash", "PowerShell", "BashOutput"] {
        assert!(!tools.split(',').any(|t| t == runner), "{runner}: {tools}");
    }
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
    // What other processes leave in /tmp, the test's own folder (under /var/folders) and the
    // account's shared folder are none of the room's business.
    let probe = PathBuf::from(format!(
        "/private/tmp/obid-harness-probe-{}",
        std::process::id()
    ));
    std::fs::write(&probe, "someone else's").unwrap();
    let answer = said(
        &obid,
        json!({"said": format!("ESCAPE {}", probe.display()), "new": true}),
    );
    let _ = std::fs::remove_file(&probe);
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();
    assert_eq!(
        answer.body["text"],
        "escape: parent=no home=no repos=no account=no config=no login=no folder=no tmp=no inside=ok readRepo=ok",
        "{}",
        answer.text
    );
    let folder = obid.home.join(format!("conversations/{conversation}"));
    assert!(!folder.join("escaped.txt").exists());
    assert!(!obid.home.join("escaped.txt").exists());
    assert!(folder.join("room/mine.txt").is_file());
    assert!(!obid.home.join("accounts/stub/planted.txt").exists());
    // The session's own config folder held only the account's login, and keeps none after.
    let recorded = turns(&obid);
    assert_eq!(
        recorded[0]["config"].as_str().map(PathBuf::from),
        Some(folder.join("config"))
    );
    assert!(!folder.join("config/.credentials.json").exists());
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
        "perms: Write=allow Write=deny Edit=deny WebFetch=allow Bash=deny Bash=deny mcp__elsewhere__run=deny",
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
    // What the plan loop says depends on whether its brain can run (with no usable login it's
    // keyword rules, #651); its answer, a reply or a question, ends with the line saying why.
    let words = |answer: &Answer| {
        answer.body["text"]
            .as_str()
            .or(answer.body["question"]["text"].as_str())
            .unwrap_or("")
            .to_owned()
    };
    let answer = said(&obid, json!({"said": "HELLO", "new": true}));
    assert!(
        words(&answer).ends_with(
            "\n(Oby's plan loop answered: no Claude Code account is signed in for conversations.)"
        ),
        "{}",
        answer.text
    );
    assert!(turns(&obid).is_empty());

    std::fs::write(obid.home.join("accounts/stub/.credentials.json"), "{}").unwrap();
    let failed = said(&obid, json!({"said": "FAIL", "new": true}));
    assert!(
        words(&failed).ends_with("\n(Oby's plan loop answered: its agent session failed twice.)"),
        "{}",
        failed.text
    );
    assert_eq!(turns(&obid).len(), 2);
}

/// A turn that used the web (a search, or a command that reached it) doesn't start work by itself:
/// the job waits in the inbox for the owner's Start, as the plan loop's research does (#374). One
/// that used only the owner's words and repositories starts it at once.
#[test]
fn work_planned_after_the_web_waits_for_the_owners_start() {
    let (_folder, obid) = obid("harness-web", true);
    let dispatch = r#"OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build"}"#;
    // The web, a read of repos/, and a search with no path (the whole room, repos/ in it: R1).
    for (n, words) in [
        format!("WEB {dispatch}"),
        format!("READREPO {dispatch}"),
        format!("GREP {dispatch}"),
    ]
    .iter()
    .enumerate()
    {
        let answer = said(&obid, json!({"said": words, "new": true}));
        assert_eq!(answer.body["jobs"], json!([]), "{}", answer.text);
        assert!(
            answer.body["text"]
                .as_str()
                .unwrap()
                .contains("waiting in your inbox"),
            "{}",
            answer.text
        );
        let starts = inbox(&obid)
            .into_iter()
            .filter(|i| i["kind"] == "start")
            .count();
        assert_eq!(starts, n + 1, "{words}");
    }
    let jobs = call(&obid, "GET", "/v1/jobs", None);
    assert_eq!(jobs.body.as_array().map_or(0, Vec::len), 0, "{}", jobs.text);
    let answer = said(&obid, json!({"said": dispatch, "new": true}));
    assert_eq!(
        answer.body["jobs"].as_array().map_or(0, Vec::len),
        1,
        "{}",
        answer.text
    );
}

/// What a job hears is the owner's own words this turn; the agent's go along quoted, as data. A
/// turn that used the web picks up a job that ended only with the owner's Confirm.
#[test]
fn a_job_hears_the_owners_words_and_the_agents_only_quoted() {
    let (_folder, obid) = obid("harness-tell", true);
    let started = said(
        &obid,
        json!({"said": r#"OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build"}"#,
               "new": true}),
    );
    let conversation = started.body["conversation"].as_str().unwrap().to_owned();
    let id = started.body["jobs"][0]["id"].as_str().unwrap().to_owned();
    ended(&obid, &id);
    let before = job_turns(&obid).len();
    let tell = format!(r#"OBY oby_tell_job {{"id": "{id}", "words": "AGENT-WORDS-1"}}"#);
    let told = said(&obid, json!({"said": tell, "conversation": conversation}));
    assert!(
        told.body["text"]
            .as_str()
            .unwrap()
            .contains("picks up again"),
        "{}",
        told.text
    );
    let heard = within(30, "the job hears it", || {
        job_turns(&obid).get(before).cloned()
    });
    let prompt = heard["prompt"].as_str().unwrap();
    assert!(prompt.starts_with(&tell), "{prompt}");
    let quoted = prompt
        .find("<<<quoted-")
        .expect("the agent's words are fenced");
    assert!(prompt[quoted..].contains("AGENT-WORDS-1"), "{prompt}");
    assert!(!prompt[..quoted].contains("AGENT-WORDS-1\n"), "{prompt}");
    ended(&obid, &id);

    let after = job_turns(&obid).len();
    let web = format!(r#"WEB OBY oby_tell_job {{"id": "{id}", "words": "AGENT-WORDS-2"}}"#);
    let waits = said(&obid, json!({"said": web, "conversation": conversation}));
    assert!(
        waits.body["text"]
            .as_str()
            .unwrap()
            .contains("waits for your OK"),
        "{}",
        waits.text
    );
    assert!(
        inbox(&obid)
            .iter()
            .any(|i| i["kind"] == "confirm" && i["job"] == id.as_str()),
        "{:?}",
        inbox(&obid)
    );
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(job_turns(&obid).len(), after, "it didn't pick up");
}

/// One turn starts at most ten jobs and tells jobs at most ten times: past that a tool says why.
#[test]
fn a_turn_starts_and_tells_at_most_ten() {
    let (_folder, obid) = obid("harness-caps", true);
    for words in [
        r#"REPEAT 11 OBY oby_dispatch {"repo": "obi-e2e/nowhere", "task": "x"}"#,
        r#"REPEAT 11 OBY oby_tell_job {"id": "nope", "words": "x"}"#,
    ] {
        let answer = said(&obid, json!({"said": words, "new": true}));
        assert!(
            answer.body["text"].as_str().unwrap().contains("at most 10"),
            "{}",
            answer.text
        );
    }
}

/// What the agent could plant for the next turn's Claude Code (instructions, settings, commands,
/// helpers, hooks) is gone before it starts, links taken away without being followed.
#[test]
fn what_the_agent_planted_is_gone_before_the_next_turn() {
    let (folder, obid) = obid("harness-planted", true);
    let first = said(&obid, json!({"said": "HELLO", "new": true}));
    let conversation = first.body["conversation"].as_str().unwrap().to_owned();
    let place = obid.home.join(format!("conversations/{conversation}"));
    let target = folder.0.join("target.md");
    std::fs::write(&target, "kept").unwrap();
    std::os::unix::fs::symlink(&target, place.join("room/CLAUDE.md")).unwrap();
    let planted = [
        "room/CLAUDE.local.md",
        "room/.claude/settings.json",
        "room/.mcp.json",
        "home/.claude/CLAUDE.md",
        "home/.claude/settings.json",
        "home/.claude/commands/x.md",
        "config/CLAUDE.md",
        "config/settings.json",
        "config/agents/x.md",
        "config/hooks/x.sh",
    ];
    for file in planted {
        let path = place.join(file);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "planted").unwrap();
    }
    said(
        &obid,
        json!({"said": "HELLO", "conversation": conversation}),
    );
    for file in planted
        .iter()
        .chain(&["room/CLAUDE.md", "room/.claude", "config/agents"])
    {
        assert!(
            std::fs::symlink_metadata(place.join(file)).is_err(),
            "{file} is still there"
        );
    }
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "kept");
}

/// The budget is the whole turn's: a session that fails slowly isn't given a second whole budget.
#[test]
fn the_budget_is_the_whole_turns() {
    let (_folder, obid) = obid_with(
        "harness-budget",
        true,
        json!({"agent": "claude", "budget": 10}),
    );
    let started = Instant::now();
    let answer = said(&obid, json!({"said": "SLOWFAIL 6000", "new": true}));
    assert!(
        answer.body["text"]
            .as_str()
            .unwrap()
            .contains("as far as Oby got"),
        "{}",
        answer.text
    );
    assert!(
        started.elapsed() < Duration::from_secs(13),
        "{:?}",
        started.elapsed()
    );
}

/// Reading repo code taints the turn, and the taint lasts: a later resumed turn that dispatches
/// still proposes the work for the owner's Start, never starts it at once (N1).
#[test]
fn the_taint_lasts_across_resumed_turns() {
    let (_folder, obid) = obid("harness-taint-persist", true);
    let first = said(&obid, json!({"said": "READREPO SAY looked", "new": true}));
    let conversation = first.body["conversation"].as_str().unwrap().to_owned();
    let kept: Value = serde_json::from_slice(
        &std::fs::read(
            obid.home
                .join(format!("conversations/{conversation}/session.json")),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(kept["web"], true, "the turn's taint is kept: {kept}");

    // A later turn that touches nothing untrusted itself still waits, because the taint lasts.
    let dispatch = r#"OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build"}"#;
    let answer = said(
        &obid,
        json!({"said": dispatch, "conversation": conversation}),
    );
    assert_eq!(answer.body["jobs"], json!([]), "{}", answer.text);
    assert!(
        answer.body["text"]
            .as_str()
            .unwrap()
            .contains("waiting in your inbox"),
        "{}",
        answer.text
    );
    assert!(
        inbox(&obid).iter().any(|i| i["kind"] == "start"),
        "a start item: {:?}",
        inbox(&obid)
    );
    assert_eq!(
        call(&obid, "GET", "/v1/jobs", None)
            .body
            .as_array()
            .map_or(0, Vec::len),
        0
    );
}

/// The ToolSearch call before an MCP tool (the deferred-tool lookup) is Oby's own bookkeeping: no
/// `step` event for it (the live e2e saw a bare "toolsearch" line).
#[test]
fn the_toolsearch_step_is_hidden() {
    let (_folder, obid) = obid("harness-toolsearch", true);
    let events = follow_events(&obid);
    let answer = said(&obid, json!({"said": "TOOLSEARCH", "new": true}));
    assert_eq!(answer.body["text"], "searched", "{}", answer.text);
    let seen = until_oby_turn(&events, 30);
    for (name, data) in &seen {
        if name == "step" {
            assert_ne!(data["tool"], "toolsearch", "{data}");
            assert!(
                !data["detail"].as_str().unwrap_or("").contains("select:"),
                "{data}"
            );
        }
    }
}

/// A turn that was replaced while it waited for the one before it (one turn per conversation at a
/// time) exits as soon as it gets its turn, without starting: no `thinking` for it, and the latest
/// answers. Event-driven: the third words go in as soon as the second's turn is seen, which is when
/// the first is cancelled; the first then holds the lock for at least obid's 400 ms stop grace, so
/// the second is still waiting when the third replaces it.
#[test]
fn a_turn_replaced_while_it_waits_never_starts() {
    let (_folder, obid) = obid("harness-cancel-waiting", true);
    let first = said(&obid, json!({"said": "SAY hi", "new": true}));
    let conversation = first.body["conversation"].as_str().unwrap().to_owned();
    let events = follow_events(&obid);
    let mut seen: Vec<(String, Value)> = vec![];
    let mut until = |what: &str, done: &dyn Fn(&str, &Value) -> bool| loop {
        let (name, data) = events
            .recv_timeout(Duration::from_secs(30))
            .unwrap_or_else(|_| panic!("no {what}: {seen:?}"));
        let hit = done(&name, &data);
        seen.push((name, data));
        if hit {
            return;
        }
    };
    std::thread::scope(|scope| {
        let slow = scope.spawn(|| {
            said(
                &obid,
                json!({"said": "LINGER 5000", "conversation": conversation}),
            )
        });
        // The first is running its agent.
        until("the first's agent", &|n, d| {
            n == "thinking" && d["state"] == "running"
        });
        let waiting = scope.spawn(|| {
            said(
                &obid,
                json!({"said": "SAY second", "conversation": conversation}),
            )
        });
        // The second began: the first is cancelled now, and still holds the lock.
        until("the second's turn", &|n, d| {
            n == "turn" && d["who"] == "user" && d["text"] == "SAY second"
        });
        let latest = said(
            &obid,
            json!({"said": "SAY third", "conversation": conversation}),
        );
        assert_eq!(latest.body["text"], "third", "{}", latest.text);
        let _ = slow.join();
        let _ = waiting.join();
    });
    until("the third's answer", &|n, d| {
        n == "turn" && d["who"] == "oby" && d["text"] == "third"
    });
    let second = seen
        .iter()
        .find(|(n, d)| n == "turn" && d["who"] == "user" && d["text"] == "SAY second")
        .map(|(_, d)| d["id"].clone())
        .unwrap();
    assert!(
        !seen
            .iter()
            .any(|(n, d)| (n == "thinking" || n == "reply") && d["turn"] == second),
        "the replaced turn started: {seen:?}"
    );
}
