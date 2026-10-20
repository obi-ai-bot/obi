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
    obid_env(name, signed_in, conversation, &[])
}

/// [`obid_with`], with `env` over a test obid's.
fn obid_env(
    name: &str,
    signed_in: bool,
    conversation: Value,
    env: &[(&str, &str)],
) -> (Folder, Obid) {
    let folder = Folder::new(name);
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &harness());
    config["conversation"] = conversation;
    let account = folder.0.join("home/accounts/stub");
    std::fs::create_dir_all(&account).unwrap();
    if signed_in {
        std::fs::write(account.join(".credentials.json"), "{}").unwrap();
    }
    let obid = start_with(&folder.0, &config, None, env);
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

/// What the stand-in recorded as the jobs' agent, in each job's own config folder.
fn job_turns(obid: &Obid) -> Vec<Value> {
    // In each job's own config folder (#655: never the account's), in the order they came.
    let mut turns: Vec<Value> = std::fs::read_dir(obid.home.join("logins"))
        .map(|dir| {
            dir.flatten()
                .flat_map(|e| recorded(&e.path().join("turns.jsonl")))
                .collect()
        })
        .unwrap_or_default();
    turns.sort_by_key(|t| t["at"].as_u64());
    turns
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

/// A conversation's Claude Code waits for its next turn (docs/fast-replies.md): the turn after
/// goes to the same process, with only the owner's words, and it ends when the conversation goes.
#[test]
fn the_next_turn_goes_to_the_waiting_claude_code() {
    let (_folder, obid) = obid("harness-warm", true);
    let first = said(&obid, json!({"said": "HELLO", "new": true}));
    let conversation = first.body["conversation"].as_str().unwrap().to_owned();
    let kept: Value = serde_json::from_slice(
        &std::fs::read(
            obid.home
                .join(format!("conversations/{conversation}/session.json")),
        )
        .unwrap(),
    )
    .unwrap();
    let again = said(
        &obid,
        json!({"said": "REMEMBER", "conversation": conversation}),
    );
    assert_eq!(
        again.body["text"],
        format!("resume={}", kept["session"].as_str().unwrap()),
        "{}",
        again.text
    );
    let recorded = turns(&obid);
    assert_eq!(recorded.len(), 2, "{recorded:?}");
    assert_eq!(recorded[0]["pid"], recorded[1]["pid"], "{recorded:?}");
    assert_eq!(recorded[1]["prompt"], "REMEMBER");
    let pid = recorded[0]["pid"].to_string();
    assert!(alive(&pid), "it waits for the next turn");
    let gone = call(
        &obid,
        "DELETE",
        &format!("/v1/conversations/{conversation}"),
        None,
    );
    assert_eq!(gone.status, 204, "{}", gone.text);
    assert!(ends_soon(&pid), "it ends with its conversation");
}

/// After the owner's turn, the next new conversation's Claude Code starts and waits (docs/
/// fast-replies.md): it connects to Oby's tools but can call none before its turn, and the new
/// conversation's first turn goes to it.
#[test]
fn a_new_conversation_finds_its_claude_code_started() {
    let (_folder, obid) = obid_env(
        "harness-prestart",
        true,
        json!({"agent": "claude"}),
        &[("OBID_PRESTART", "on")],
    );
    let first = said(&obid, json!({"said": "SAY hi", "new": true}));
    let one = first.body["conversation"].as_str().unwrap().to_owned();
    let conversations = obid.home.join("conversations");
    let started = || -> Option<(String, Value)> {
        std::fs::read_dir(&conversations)
            .ok()?
            .flatten()
            .filter(|e| e.path().is_dir() && e.file_name().to_string_lossy() != one)
            .find_map(|e| {
                let line = std::fs::read_to_string(e.path().join("config/started.jsonl")).ok()?;
                let record = serde_json::from_str(line.lines().next()?).ok()?;
                Some((e.file_name().to_string_lossy().into_owned(), record))
            })
    };
    let give_up_at = Instant::now() + Duration::from_secs(30);
    while started().is_none() && Instant::now() < give_up_at {
        std::thread::sleep(Duration::from_millis(100));
    }
    let (next, record) = started().expect("the next conversation's Claude Code started");
    let pid = record["pid"].to_string();
    assert!(alive(&pid));
    assert_eq!(
        std::fs::read_to_string(conversations.join("next-id")).unwrap(),
        next
    );

    // Its token connects and lists the tools, and calls none; another token is refused.
    let config: Value = serde_json::from_slice(
        &std::fs::read(conversations.join(format!("{next}/home/oby-mcp.json"))).unwrap(),
    )
    .unwrap();
    let token = config["mcpServers"]["oby"]["headers"]["Authorization"]
        .as_str()
        .unwrap()
        .strip_prefix("Bearer ")
        .unwrap()
        .to_owned();
    let endpoint = format!("/v1/agent/mcp/conversation-{next}");
    let mcp = |token: &str, method: &str| {
        call_with_token(
            &obid,
            token,
            "POST",
            &endpoint,
            Some(&json!({"jsonrpc": "2.0", "id": 1, "method": method,
                         "params": {"name": "oby_jobs", "arguments": {}}})),
        )
    };
    let hello = mcp(&token, "initialize");
    assert_eq!(hello.status, 200, "{}", hello.text);
    assert_eq!(hello.body["result"]["serverInfo"]["name"], "oby");
    let listed = mcp(&token, "tools/list");
    assert!(listed.body["result"]["tools"].as_array().unwrap().len() > 3);
    let called = mcp(&token, "tools/call");
    assert!(
        called.body["error"]["message"].is_string(),
        "{}",
        called.text
    );
    assert_eq!(mcp("not-its-token", "initialize").status, 401);

    // The new conversation is that one, and its first turn goes to it, with Oby's tools.
    let second = said(&obid, json!({"said": "OBY oby_jobs {}", "new": true}));
    assert_eq!(
        second.body["conversation"],
        next.as_str(),
        "{}",
        second.text
    );
    assert!(
        second.body["text"].as_str().unwrap().starts_with("oby: "),
        "{}",
        second.text
    );
    assert!(!second.body["text"].as_str().unwrap().contains("refused"));
    let recorded = recorded(&conversations.join(format!("{next}/config/turns.jsonl")));
    assert_eq!(recorded.len(), 1, "{recorded:?}");
    assert_eq!(recorded[0]["pid"].to_string(), pid);
    assert!(
        !conversations.join("next-id").exists() || {
            std::fs::read_to_string(conversations.join("next-id")).unwrap() != next
        }
    );
}

/// A waiting Claude Code that wrote a line while it waited isn't given the next turn (the line
/// would be taken for the turn's): a new one answers it.
#[test]
fn a_claude_code_that_wrote_while_it_waited_starts_anew() {
    let (_folder, obid) = obid("harness-warm-stray", true);
    let first = said(&obid, json!({"said": "SAYLATE early", "new": true}));
    let conversation = first.body["conversation"].as_str().unwrap().to_owned();
    std::thread::sleep(Duration::from_millis(1000));
    let next = said(
        &obid,
        json!({"said": "SAY later", "conversation": conversation}),
    );
    assert_eq!(next.body["text"], "later", "{}", next.text);
    let recorded = turns(&obid);
    assert_eq!(recorded.len(), 2, "{recorded:?}");
    assert_ne!(recorded[0]["pid"], recorded[1]["pid"]);
    assert!(ends_soon(&recorded[0]["pid"].to_string()));
}

/// A login copy a crash left in a conversation's folder is gone once obid has started.
#[test]
fn login_copies_left_in_conversations_go_at_start() {
    let folder = Folder::new("harness-left-logins");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &harness());
    config["conversation"] = json!({"agent": "claude"});
    std::fs::create_dir_all(folder.0.join("home/accounts/stub")).unwrap();
    let place = folder
        .0
        .join("home/conversations/c0000000-0000-4000-8000-000000000042");
    let left = [
        place.join("login/.claude/.credentials.json"),
        place.join("config/.credentials.json"),
    ];
    for file in &left {
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, r#"{"claudeAiOauth": {"accessToken": "left"}}"#).unwrap();
    }
    let _obid = start(&folder.0, &config, None);
    for file in &left {
        assert!(!file.exists(), "{} is still there", file.display());
    }
}

/// Whether the process `pid` runs.
fn alive(pid: &str) -> bool {
    std::process::Command::new("kill")
        .args(["-0", pid])
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success()
}

/// Whether the process `pid` ends within 15 seconds.
fn ends_soon(pid: &str) -> bool {
    let give_up_at = Instant::now() + Duration::from_secs(15);
    while alive(pid) && Instant::now() < give_up_at {
        std::thread::sleep(Duration::from_millis(100));
    }
    !alive(pid)
}

/// A turn stopped or out of time keeps no Claude Code waiting: the next starts a new one.
#[test]
fn nothing_waits_after_a_stop_or_the_budget() {
    let (_folder, obid) = obid_with(
        "harness-warm-ends",
        true,
        json!({"agent": "claude", "budget": 10}),
    );
    let first = said(&obid, json!({"said": "SAY hi", "new": true}));
    let conversation = first.body["conversation"].as_str().unwrap().to_owned();
    let pid = |n: usize| turns(&obid)[n]["pid"].to_string();
    let late = said(
        &obid,
        json!({"said": "LINGER 15000", "conversation": conversation}),
    );
    assert!(
        late.body["text"]
            .as_str()
            .unwrap()
            .contains("as far as Oby got"),
        "{}",
        late.text
    );
    assert_eq!(pid(0), pid(1), "the turn went to the waiting one");
    assert!(ends_soon(&pid(1)), "the budget ended it");
    said(
        &obid,
        json!({"said": "SAY again", "conversation": conversation}),
    );
    assert_ne!(pid(2), pid(1));
    std::thread::scope(|scope| {
        let slow = scope.spawn(|| {
            said(
                &obid,
                json!({"said": "LINGER 20000", "conversation": conversation}),
            )
        });
        let give_up_at = Instant::now() + Duration::from_secs(15);
        while turns(&obid).len() < 4 && Instant::now() < give_up_at {
            std::thread::sleep(Duration::from_millis(100));
        }
        let stopped = call(
            &obid,
            "POST",
            "/v1/conversation/stop",
            Some(&json!({"conversation": conversation})),
        );
        assert_eq!(stopped.status, 200, "{}", stopped.text);
        slow.join().unwrap();
    });
    assert_eq!(pid(3), pid(2));
    assert!(ends_soon(&pid(3)), "the stop ended it");
    said(
        &obid,
        json!({"said": "SAY last", "conversation": conversation}),
    );
    assert_ne!(pid(4), pid(3));
}

/// obid's stop ends every waiting Claude Code.
#[test]
fn obids_stop_ends_the_waiting_claude_code() {
    let (_folder, mut obid) = obid("harness-warm-stop", true);
    said(&obid, json!({"said": "SAY hi", "new": true}));
    let pid = turns(&obid)[0]["pid"].to_string();
    assert!(alive(&pid));
    obid.stop();
    assert!(ends_soon(&pid));
}

/// A new room takes the spare tree obid keeps ready (a rename, nothing extracted while the turn
/// waits), and a room whose branch moved keeps its checkout for the turn while the new one is made
/// and swapped in (docs/fast-replies.md).
#[test]
fn rooms_never_wait_for_a_checkout_obid_could_keep_ready() {
    use std::os::unix::fs::MetadataExt;
    let (_folder, obid) = obid("harness-spares", true);
    let first = said(&obid, json!({"said": "HELLO", "new": true}));
    let conversation = first.body["conversation"].as_str().unwrap().to_owned();
    let spares = obid.home.join("checkouts/obi-e2e/fixture-app");
    let spare = || {
        std::fs::read_dir(&spares)
            .into_iter()
            .flatten()
            .flatten()
            .find(|e| e.file_name().to_string_lossy().starts_with("spare-"))
            .map(|e| e.path())
    };
    let give_up_at = Instant::now() + Duration::from_secs(30);
    while spare().is_none() && Instant::now() < give_up_at {
        std::thread::sleep(Duration::from_millis(100));
    }
    let ready = spare().expect("a spare tree is made after the first room's");
    let inode = std::fs::metadata(&ready).unwrap().ino();
    let other = said(&obid, json!({"said": "HELLO", "new": true}));
    let other = other.body["conversation"].as_str().unwrap().to_owned();
    let taken = obid.home.join(format!(
        "conversations/{other}/room/repos/obi-e2e/fixture-app"
    ));
    assert_eq!(std::fs::metadata(&taken).unwrap().ino(), inode);
    assert!(taken.join("package.json").is_file());

    // The branch moves in obid's clone: the next turn doesn't wait, and the new tree comes in.
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let git = |args: &[&str]| {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(&clone)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "{out:?}");
        String::from_utf8(out.stdout).unwrap().trim().to_owned()
    };
    let tree = git(&["rev-parse", "refs/remotes/origin/main^{tree}"]);
    let parent = git(&["rev-parse", "refs/remotes/origin/main"]);
    let moved = git(&[
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit-tree",
        &tree,
        "-p",
        &parent,
        "-m",
        "moved",
    ]);
    git(&["update-ref", "refs/remotes/origin/main", &moved]);
    said(
        &obid,
        json!({"said": "HELLO", "conversation": conversation}),
    );
    let marks = obid
        .home
        .join(format!("conversations/{conversation}/repos.json"));
    let at = || -> Value { serde_json::from_slice(&std::fs::read(&marks).unwrap()).unwrap() };
    let give_up_at = Instant::now() + Duration::from_secs(30);
    while at()["obi-e2e/fixture-app"] != moved.as_str() && Instant::now() < give_up_at {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(at()["obi-e2e/fixture-app"], moved.as_str());
    assert!(
        obid.home
            .join(format!(
                "conversations/{conversation}/room/repos/obi-e2e/fixture-app/package.json"
            ))
            .is_file()
    );
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
        "tools: oby_jobs,oby_job,oby_dispatch,oby_tell_job,oby_stop_job,oby_continue_job,oby_archive_job,oby_delete_job,oby_change_job,oby_tasks,oby_inbox,oby_answer,oby_conversations,oby_artifact,oby_read,oby_search,oby_list,oby_shell,oby_shell_output,oby_shell_stop",
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
    // The job names the words that started it, and says so as it starts, before Oby's answer
    // lists it: the conversation shows its card at once.
    let user = seen
        .iter()
        .find(|(n, d)| n == "turn" && d["who"] == "user")
        .map(|(_, d)| d["id"].clone())
        .expect("the user's turn");
    assert_eq!(job.body["turn"], user, "{}", job.text);
    let started = seen
        .iter()
        .position(|(n, d)| n == "job" && d["id"] == id && d["turn"] == user)
        .expect("the job's event with its turn");
    let answered = seen
        .iter()
        .position(|(n, d)| n == "turn" && d["who"] == "oby" && d["jobs"] == json!([id]))
        .expect("Oby's answer listing the job");
    assert!(started < answered, "{seen:?}");
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

/// What a job hears is the owner's own words this turn; the agent's go along quoted, as data. Told
/// something after it ended, a job gets a follow-up (Sangam's design, the owner's decision of
/// 2026-10-18) whose request is the owner's words alone and whose card goes on the turn; a turn
/// that used the web only proposes it, a `start` item for the owner's Start.
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
    let first = ended(&obid, &id);
    let before = job_turns(&obid).len();
    let tell = format!(r#"OBY oby_tell_job {{"id": "{id}", "words": "AGENT-WORDS-1"}}"#);
    let told = said(&obid, json!({"said": tell, "conversation": conversation}));
    assert!(
        told.body["text"]
            .as_str()
            .unwrap()
            .contains("started a follow-up"),
        "{}",
        told.text
    );
    let cards = told.body["jobs"].as_array().unwrap();
    assert_eq!(cards.len(), 1, "{}", told.text);
    let next = cards[0]["id"].as_str().unwrap().to_owned();
    assert_ne!(next, id);
    let follow = ended(&obid, &next);
    assert_eq!(follow["followUpOf"], id.as_str());
    assert_eq!(follow["conversation"], conversation.as_str());
    // Started by these words in its parent's conversation: its card shows under them at once.
    let words = call(
        &obid,
        "GET",
        &format!("/v1/conversation?id={conversation}"),
        None,
    )
    .body
    .as_array()
    .unwrap()
    .iter()
    .find(|t| t["who"] == "user" && t["text"] == tell.as_str())
    .map(|t| t["id"].clone())
    .expect("the user's turn");
    assert_eq!(follow["turn"], words, "{follow}");
    assert_eq!(follow["request"], tell.as_str());
    assert_eq!(follow["kind"], first["kind"]);
    let heard = within(30, "the follow-up's agent hears it", || {
        job_turns(&obid).get(before).cloned()
    });
    let prompt = heard["prompt"].as_str().unwrap();
    let asked = prompt
        .find(&format!("What the user asked for: {tell}\n"))
        .unwrap_or_else(|| panic!("{prompt}"));
    let quoted = asked
        + prompt[asked..]
            .find("<<<quoted-")
            .expect("the agent's words are fenced");
    assert!(prompt[quoted..].contains("AGENT-WORDS-1"), "{prompt}");
    assert!(!prompt[..quoted].contains("AGENT-WORDS-1\n"), "{prompt}");
    assert_eq!(ended(&obid, &id)["status"], first["status"]);

    let jobs = call(&obid, "GET", "/v1/jobs", None)
        .body
        .as_array()
        .unwrap()
        .len();
    let web = format!(r#"WEB OBY oby_tell_job {{"id": "{id}", "words": "AGENT-WORDS-2"}}"#);
    let waits = said(&obid, json!({"said": web, "conversation": conversation}));
    assert!(
        waits.body["text"]
            .as_str()
            .unwrap()
            .contains("waits for your Start"),
        "{}",
        waits.text
    );
    let start = inbox(&obid)
        .into_iter()
        .find(|i| i["kind"] == "start")
        .unwrap_or_else(|| panic!("{:?}", inbox(&obid)));
    // The card reads as the owner wrote it: their words, then the agent's, never the fences the
    // agent's prompt keeps.
    let text = start["text"].as_str().unwrap();
    assert!(
        text.contains(&format!("Your words:\n{web}"))
            && text.ends_with("What Oby adds for its agent:\nAGENT-WORDS-2"),
        "{start}"
    );
    assert!(
        !text.contains("quoted-") && !text.contains("Everything between"),
        "{start}"
    );
    assert_eq!(start["title"], "Follow-up: Add a greeting");
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(
        call(&obid, "GET", "/v1/jobs", None)
            .body
            .as_array()
            .unwrap()
            .len(),
        jobs,
        "nothing started"
    );

    // A follow-up of the job working already takes the item's Start once it's at work: it hears
    // the words, the item is done, and nothing else starts.
    let pausing = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": "PAUSE: 30000"})),
    );
    assert_eq!(pausing.status, 201, "{}", pausing.text);
    let follow = pausing.body["id"].as_str().unwrap().to_owned();
    // Still getting ready, it isn't at work: the item's words would wait for nothing, or answer
    // what it asks next. Start is refused, naming it, and the item stays open.
    let item = start["id"].as_str().unwrap();
    let refused = call(
        &obid,
        "POST",
        &format!("/v1/inbox/{item}/answer"),
        Some(&json!({"answer": "Start"})),
    );
    assert_eq!(refused.status, 409, "{}", refused.text);
    assert!(refused.text.contains(&follow), "{}", refused.text);
    assert!(inbox(&obid).iter().any(|i| i["id"] == item), "still open");
    within(60, "the follow-up is at work", || {
        let body = call(&obid, "GET", &format!("/v1/jobs/{follow}"), None).body;
        (body["status"] == "running" && body["step"] == "Starting Claude Code").then_some(())
    });
    let answered = call(
        &obid,
        "POST",
        &format!("/v1/inbox/{item}/answer"),
        Some(&json!({"answer": "Start"})),
    );
    assert_eq!(answered.status, 200, "{}", answered.text);
    assert_eq!(answered.body["job"], follow.as_str());
    assert!(answered.body["done"].is_string(), "{}", answered.text);
    let heard = call(&obid, "GET", &format!("/v1/jobs/{follow}"), None).body;
    assert!(
        heard["notes"].to_string().contains("AGENT-WORDS-2"),
        "{heard}"
    );
    // Its step shows the owner's words, not the agent's quoted after them.
    assert_eq!(heard["step"], format!("You: {web}"), "{heard}");
    assert_eq!(
        call(&obid, "GET", "/v1/jobs", None)
            .body
            .as_array()
            .unwrap()
            .len(),
        jobs + 1,
        "only the follow-up the owner started"
    );

    // Told again in the conversation, the job's working follow-up hears it: no second follow-up,
    // and its card goes on the answer.
    let again = format!(r#"OBY oby_tell_job {{"id": "{id}", "words": "AGENT-WORDS-3"}}"#);
    let on_it = said(&obid, json!({"said": again, "conversation": conversation}));
    assert!(
        on_it.body["text"]
            .as_str()
            .unwrap()
            .contains("Already on it in"),
        "{}",
        on_it.text
    );
    assert_eq!(
        on_it.body["jobs"][0]["id"],
        follow.as_str(),
        "{}",
        on_it.text
    );
    ended(&obid, &follow);

    // A proposal names the conversation it was made in (another than the job's here), which
    // shows it; a later follow-up that ended, here done with nothing committed, leaves it open as
    // it was.
    let web = format!(r#"WEB OBY oby_tell_job {{"id": "{id}", "words": "AGENT-WORDS-4"}}"#);
    let elsewhere = said(&obid, json!({"said": web, "new": true}));
    let elsewhere = elsewhere.body["conversation"].as_str().unwrap().to_owned();
    assert_ne!(elsewhere, conversation);
    let proposed = inbox(&obid)
        .into_iter()
        .find(|i| i["kind"] == "start")
        .unwrap_or_else(|| panic!("{:?}", inbox(&obid)));
    assert_eq!(proposed["conversation"], elsewhere.as_str(), "{proposed}");
    std::thread::sleep(Duration::from_millis(1100));
    let other = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": "and the docs"})),
    );
    assert_eq!(other.status, 201, "{}", other.text);
    assert_eq!(
        ended(&obid, other.body["id"].as_str().unwrap())["status"],
        "done"
    );
    let still = inbox(&obid)
        .into_iter()
        .find(|i| i["id"] == proposed["id"])
        .unwrap_or_else(|| panic!("{:?}", inbox(&obid)));
    assert_eq!(still["text"], proposed["text"]);
    assert_eq!(still["options"], json!(["Start", "Cancel"]));
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

/// A follow-up is a job a turn starts: it counts against the turn's ten, and a turn starts at most
/// one follow-up of a job.
#[test]
fn a_turn_starts_one_follow_up_of_a_job_within_its_ten() {
    let (_folder, obid) = obid("harness-follow-up-caps", true);
    let started = said(
        &obid,
        json!({"said": r#"OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build"}"#,
               "new": true}),
    );
    let id = started.body["jobs"][0]["id"].as_str().unwrap().to_owned();
    ended(&obid, &id);
    let jobs = || {
        call(&obid, "GET", "/v1/jobs", None)
            .body
            .as_array()
            .unwrap()
            .len()
    };
    let tell = format!(r#"OBY oby_tell_job {{"id": "{id}", "words": "x"}}"#);
    let full = said(
        &obid,
        json!({"said": format!(r#"REPEAT 10 OBY oby_dispatch {{"repo": "obi-e2e/nowhere", "task": "x"}} THEN {tell}"#), "new": true}),
    );
    assert!(
        full.body["text"]
            .as_str()
            .unwrap()
            .contains("starts jobs at most 10"),
        "{}",
        full.text
    );
    assert_eq!(jobs(), 1);
    let twice = said(
        &obid,
        json!({"said": format!(r#"REPEAT 2 {tell}"#), "new": true}),
    );
    assert!(
        twice.body["text"].as_str().unwrap().contains("refused"),
        "{}",
        twice.text
    );
    assert_eq!(jobs(), 2);
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
    let recorded = turns(&obid);
    assert_eq!(
        recorded[0]["pid"], recorded[1]["pid"],
        "the later turn went to the waiting Claude Code, and the taint with it"
    );
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

/// The owner's attachments reach the session: copied into its room as
/// `attachments/<turn>/<name>`, names cleaned, text with every secret obid knows taken out, a
/// binary file that holds one left out, and named in the prompt as quoted data.
#[test]
fn attachments_reach_the_session_in_its_room() {
    let (_folder, obid) = obid("harness-attachments", true);
    let dir = obid.home.join("attachments");
    std::fs::create_dir_all(&dir).unwrap();
    let png: Vec<u8> = [
        0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d,
    ]
    .into_iter()
    .chain(0..=255u8)
    .collect();
    std::fs::write(dir.join("pic one.png"), &png).unwrap();
    std::fs::write(dir.join("notes.txt"), format!("token {TOKEN} here\n")).unwrap();
    let mut leak = vec![0xff, 0xfe, 0x00];
    leak.extend(TOKEN.as_bytes());
    std::fs::write(dir.join("leak.bin"), &leak).unwrap();
    let attached: Vec<String> = ["pic one.png", "notes.txt", "leak.bin"]
        .iter()
        .map(|n| dir.join(n).to_string_lossy().into_owned())
        .collect();
    let answer = said(
        &obid,
        json!({"said": "FILES", "new": true, "attachments": attached}),
    );
    let text = answer.body["text"].as_str().unwrap();
    let conversation = answer.body["conversation"].as_str().unwrap();
    let turn = call(
        &obid,
        "GET",
        &format!("/v1/conversation?id={conversation}"),
        None,
    )
    .body[0]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        text,
        format!("files: attachments/{turn}/notes.txt,attachments/{turn}/pic_one.png named=true"),
        "{}",
        answer.text
    );
    let copied = obid.home.join(format!(
        "conversations/{conversation}/room/attachments/{turn}"
    ));
    assert_eq!(std::fs::read(copied.join("pic_one.png")).unwrap(), png);
    let notes = std::fs::read_to_string(copied.join("notes.txt")).unwrap();
    assert!(
        notes.contains("[redacted") && !notes.contains(TOKEN),
        "{notes}"
    );
    assert!(!copied.join("leak.bin").exists());
}

/// An attachment is untrusted input: a turn that gets one proposes the work it dispatches for the
/// owner's Start, never starts it at once (P2).
#[test]
fn an_attachment_makes_the_turns_work_wait() {
    let (_folder, obid) = obid("harness-attach-taint", true);
    let dir = obid.home.join("attachments");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("pic.png"), b"not really a png").unwrap();
    let attached = vec![dir.join("pic.png").to_string_lossy().into_owned()];
    let dispatch = r#"OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build"}"#;
    let answer = said(
        &obid,
        json!({"said": dispatch, "new": true, "attachments": attached}),
    );
    assert_eq!(answer.body["jobs"], json!([]), "{}", answer.text);
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

/// An attachment larger than the cap is left out, not copied, and the prompt says so (P3).
#[test]
fn an_oversize_attachment_is_left_out() {
    let (_folder, obid) = obid("harness-attach-big", true);
    let dir = obid.home.join("attachments");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("small.txt"), b"ok").unwrap();
    // A sparse file over the cap: its length is large, but it writes no real bytes.
    let big = std::fs::File::create(dir.join("huge.bin")).unwrap();
    big.set_len(26_000_000).unwrap();
    drop(big);
    let attached: Vec<String> = ["small.txt", "huge.bin"]
        .iter()
        .map(|n| dir.join(n).to_string_lossy().into_owned())
        .collect();
    let answer = said(
        &obid,
        json!({"said": "FILES", "new": true, "attachments": attached}),
    );
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();
    let room = obid
        .home
        .join(format!("conversations/{conversation}/room/attachments"));
    let turn = std::fs::read_dir(&room)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert!(turn.join("small.txt").is_file(), "the small file is copied");
    assert!(!turn.join("huge.bin").exists(), "the big file isn't copied");
    // The prompt the agent got names the small file and says the big one was left out.
    let prompt = turns(&obid)[0]["prompt"].as_str().unwrap().to_owned();
    assert!(prompt.contains("small.txt"), "{prompt}");
    assert!(
        prompt.contains("huge.bin") && prompt.contains("larger than"),
        "{prompt}"
    );
}

/// The owner's attachments are theirs, whatever their name: one called CLAUDE.md is copied before
/// the room is scrubbed of planted instructions, and the scrub leaves attachments/ alone (R4).
#[test]
fn an_attachment_named_claude_md_survives_the_scrub() {
    let (_folder, obid) = obid("harness-attach-claude-md", true);
    let dir = obid.home.join("attachments");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("CLAUDE.md"), b"the owner's own notes").unwrap();
    let attached = vec![dir.join("CLAUDE.md").to_string_lossy().into_owned()];
    let answer = said(
        &obid,
        json!({"said": "FILES", "new": true, "attachments": attached}),
    );
    let text = answer.body["text"].as_str().unwrap();
    assert!(
        text.starts_with("files: attachments/") && text.contains("/CLAUDE.md named=true"),
        "{}",
        answer.text
    );
}

/// What obid sends with every file of an artifact (crate::artifacts::POLICY).
const ARTIFACT_POLICY: &str = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' data: blob:; style-src 'self' 'unsafe-inline' data:; img-src 'self' data: blob:; connect-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; sandbox allow-scripts";

/// One GET with the API token: the status, the head in lower case, and the body.
fn raw_get(obid: &Obid, target: &str) -> (u16, String, String) {
    use std::io::{Read, Write};
    let mut stream = std::net::TcpStream::connect(("127.0.0.1", obid.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    write!(
        stream,
        "GET {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {TOKEN}\r\nConnection: close\r\n\r\n"
    )
    .unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).unwrap();
    let raw = String::from_utf8_lossy(&raw).into_owned();
    let (head, body) = raw.split_once("\r\n\r\n").unwrap();
    let status = head.split(' ').nth(1).unwrap().parse().unwrap();
    (status, head.to_ascii_lowercase(), body.to_owned())
}

/// oby_artifact publishes a folder of the room as this conversation's artifact: the answer and
/// Oby's turn carry `artifacts: [{id, version}]`, an `artifact` event goes out, its files serve
/// with the CSP, and publishing the agent's own output doesn't taint the turn. A path out of the
/// room is #648's one-line refusal.
#[test]
fn oby_artifact_publishes_from_the_room_onto_the_turn() {
    let (_folder, obid) = obid("harness-artifact", true);
    let events = follow_events(&obid);
    let answer = said(
        &obid,
        json!({"said": r#"MAKEPAGE OBY oby_artifact {"title": "Fixture functions", "path": "page"}"#,
               "new": true}),
    );
    let text = answer.body["text"].as_str().unwrap();
    assert!(
        text.starts_with("oby: Published artifact ") && text.ends_with(", version 1."),
        "{}",
        answer.text
    );
    let made = answer.body["artifacts"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    assert_eq!(made.len(), 1, "{}", answer.text);
    let id = made[0]["id"].as_str().unwrap().to_owned();
    assert_eq!(made[0]["version"], 1);
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();

    let seen = until_oby_turn(&events, 30);
    assert!(
        seen.iter().any(|(n, d)| n == "artifact"
            && d["id"] == id.as_str()
            && d["conversation"] == conversation.as_str()),
        "an artifact event: {seen:?}"
    );
    let (_, turn) = seen.last().unwrap();
    assert_eq!(
        turn["artifacts"],
        json!([{"id": id, "version": 1}]),
        "{turn}"
    );
    let kept = call(
        &obid,
        "GET",
        &format!("/v1/conversation?id={conversation}"),
        None,
    );
    assert_eq!(
        kept.body.as_array().unwrap().last().unwrap()["artifacts"],
        json!([{"id": id, "version": 1}]),
        "{}",
        kept.text
    );

    let (status, head, body) = raw_get(&obid, &format!("/v1/artifacts/{id}/1/index.html"));
    assert_eq!(status, 200, "{head}");
    assert!(
        head.contains(&format!(
            "content-security-policy: {}",
            ARTIFACT_POLICY.to_ascii_lowercase()
        )),
        "{head}"
    );
    assert!(body.contains("<li>greet</li>"), "{body}");

    // The agent's own output: the turn isn't tainted.
    let session: Value = serde_json::from_slice(
        &std::fs::read(
            obid.home
                .join(format!("conversations/{conversation}/session.json")),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(session["web"], false, "{session}");

    // Out of the room: the publisher's own one line, as an error.
    let refused = said(
        &obid,
        json!({"said": r#"OBY oby_artifact {"title": "Escape", "path": "../session.json"}"#,
               "conversation": conversation}),
    );
    assert!(
        refused.body["text"]
            .as_str()
            .unwrap()
            .starts_with("oby: refused: Not published: "),
        "{}",
        refused.text
    );
    assert!(refused.body.get("artifacts").is_none(), "{}", refused.text);
}

/// Oby's answer in a turn: what the stand-in said of its tool's answer.
fn oby_said(answer: &Answer) -> String {
    answer.body["text"].as_str().unwrap_or_default().to_owned()
}

/// A job dispatched in `conversation` (a new one when none), once it has ended: its id and the
/// conversation.
fn ended_job(obid: &Obid, conversation: Option<&str>) -> (String, String) {
    let mut body = json!({"said": r#"OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build"}"#});
    match conversation {
        Some(c) => body["conversation"] = json!(c),
        None => body["new"] = json!(true),
    }
    let started = said(obid, body);
    let id = started.body["jobs"][0]["id"]
        .as_str()
        .unwrap_or_else(|| panic!("{}", started.text))
        .to_owned();
    ended(obid, &id);
    (
        id,
        started.body["conversation"].as_str().unwrap().to_owned(),
    )
}

/// The latest open confirm item about `job`, with its action.
fn confirm_for(obid: &Obid, job: &str) -> Value {
    inbox(obid)
        .into_iter()
        .rev()
        .find(|i| i["kind"] == "confirm" && i["job"] == job)
        .unwrap_or_else(|| panic!("no confirm for {job}: {:?}", inbox(obid)))
}

fn confirmed(obid: &Obid, item: &Value) -> Answer {
    let id = item["id"].as_str().unwrap();
    call(
        obid,
        "POST",
        &format!("/v1/inbox/{id}/answer"),
        Some(&json!({"answer": "Confirm"})),
    )
}

/// oby_continue_job picks a job that ended up again in its own session, its agent hearing Try
/// again's words and the conversation's quoted; another conversation's job, or a turn that read
/// something untrusted, waits for the owner's Confirm, which then continues it.
#[test]
fn oby_continue_job_continues_a_job_in_its_session() {
    let (_folder, obid) = obid("harness-continue", true);
    let (id, conversation) = ended_job(&obid, None);
    let first = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(first["status"], "failed", "{first}");
    let before = job_turns(&obid).len();
    let go = format!(r#"OBY oby_continue_job {{"id": "{id}", "words": "CONTINUE-WORDS"}}"#);
    let answer = said(&obid, json!({"said": go, "conversation": conversation}));
    assert!(
        oby_said(&answer).contains("Continuing Add a greeting: round 2."),
        "{}",
        answer.text
    );
    let again = ended(&obid, &id);
    assert_eq!(again["round"], 2, "{again}");
    let heard = within(30, "the job's agent hears it", || {
        job_turns(&obid).get(before).cloned()
    });
    let prompt = heard["prompt"].as_str().unwrap();
    assert!(
        prompt.starts_with("Try again, picking up where you left off."),
        "{prompt}"
    );
    let quoted = prompt
        .find("<<<quoted-")
        .unwrap_or_else(|| panic!("{prompt}"));
    assert!(prompt[quoted..].contains("CONTINUE-WORDS"), "{prompt}");
    assert!(!prompt[..quoted].contains("CONTINUE-WORDS\n"), "{prompt}");
    assert!(
        again["changes"]
            .to_string()
            .contains("Continued by Oby, in a conversation"),
        "{again}"
    );

    // A round the owner asked for may end done: a done job gets a follow-up instead.
    assert_eq!(again["status"], "done", "{again}");
    let done = said(
        &obid,
        json!({"said": format!(r#"OBY oby_continue_job {{"id": "{id}"}}"#), "conversation": conversation}),
    );
    assert!(
        oby_said(&done).contains("It's done: oby_tell_job starts a follow-up of it."),
        "{}",
        done.text
    );
    let unknown = said(
        &obid,
        json!({"said": r#"OBY oby_continue_job {"id": "nope"}"#, "conversation": conversation}),
    );
    assert!(
        oby_said(&unknown).contains("refused: There's no job with that id."),
        "{}",
        unknown.text
    );

    // Another conversation's job waits for the owner's Confirm.
    let (other, _) = ended_job(&obid, Some(&conversation));
    let elsewhere = said(
        &obid,
        json!({"said": format!(r#"OBY oby_continue_job {{"id": "{other}"}}"#), "new": true}),
    );
    assert!(
        oby_said(&elsewhere).contains("Continue Add a greeting waits for your OK"),
        "{}",
        elsewhere.text
    );
    let theirs = confirm_for(&obid, &other);
    assert_eq!(theirs["confirm"]["action"], "continue_job", "{theirs}");
    assert_eq!(theirs["title"], "Continue Add a greeting");
    assert!(
        theirs["text"]
            .as_str()
            .unwrap()
            .contains("another conversation started it"),
        "{theirs}"
    );

    // A turn that read the web: its own conversation's job waits too, the agent's words quoted in
    // the item, never in its title.
    let web = format!(r#"WEB OBY oby_continue_job {{"id": "{other}", "words": "WEB-WORDS"}}"#);
    let waits = said(&obid, json!({"said": web, "conversation": conversation}));
    assert!(
        oby_said(&waits).contains("waits for your OK"),
        "{}",
        waits.text
    );
    let item = confirm_for(&obid, &other);
    assert_ne!(item["id"], theirs["id"]);
    let text = item["text"].as_str().unwrap();
    assert!(
        text.contains("this turn read text Oby didn't write"),
        "{item}"
    );
    assert!(
        text.contains("> What Oby adds for its agent:\n> WEB-WORDS"),
        "{item}"
    );
    assert!(
        !text.contains("quoted-"),
        "the owner reads words, not fences: {item}"
    );
    assert!(!item["title"].as_str().unwrap().contains("WEB"), "{item}");
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(
        call(&obid, "GET", &format!("/v1/jobs/{other}"), None).body["round"],
        1,
        "nothing ran before a Confirm"
    );

    // The owner's Confirm continues it.
    let answered = confirmed(&obid, &theirs);
    assert_eq!(answered.status, 200, "{}", answered.text);
    let next = ended(&obid, &other);
    assert_eq!(next["round"], 2, "{next}");
    assert!(
        next["changes"]
            .to_string()
            .contains("Continued on your Confirm"),
        "{next}"
    );
    // The web's item was made for round 1: confirmed now, it's refused.
    let stale = confirmed(&obid, &item);
    assert_eq!(stale.status, 409, "{}", stale.text);
    assert!(
        stale.text.contains("The job changed since Oby asked"),
        "{}",
        stale.text
    );

    // A job in Bypass mode, even the conversation's own in a clean turn, waits, and its title says
    // Bypass.
    let (bypassed, clean) = ended_job(&obid, None);
    let mode = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{bypassed}/mode"),
        Some(&json!({"mode": "bypass"})),
    );
    assert_eq!(mode.status, 200, "{}", mode.text);
    let waits = said(
        &obid,
        json!({"said": format!(r#"OBY oby_continue_job {{"id": "{bypassed}"}}"#), "conversation": clean}),
    );
    assert!(
        oby_said(&waits).contains("waits for your OK"),
        "{}",
        waits.text
    );
    let item = confirm_for(&obid, &bypassed);
    assert_eq!(
        item["title"], "Continue Add a greeting in Bypass mode",
        "{item}"
    );
    assert!(
        item["text"].as_str().unwrap().contains("Bypass mode"),
        "{item}"
    );
}

/// oby_archive_job hides a job that ended and needs nothing, reversibly, at once even after the
/// web; oby_delete_job always waits for the owner's Confirm, which removes the job, its worktree
/// and its open items, and the REST routes do the same for the apps.
#[test]
fn archive_is_at_once_and_delete_waits_for_confirm() {
    let (_folder, obid) = obid("harness-archive", true);
    let (id, conversation) = ended_job(&obid, None);
    let archive = format!(r#"OBY oby_archive_job {{"id": "{id}"}}"#);
    let needs = said(
        &obid,
        json!({"said": archive, "conversation": conversation}),
    );
    assert!(
        oby_said(&needs).contains("It still needs you: dismiss it first"),
        "{}",
        needs.text
    );
    assert_eq!(
        call(&obid, "POST", &format!("/v1/jobs/{id}/dismiss"), None).status,
        200
    );
    let done = said(
        &obid,
        json!({"said": format!("WEB {archive}"), "conversation": conversation}),
    );
    assert!(
        oby_said(&done).contains("Archived Add a greeting."),
        "{}",
        done.text
    );
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert!(job["archived"].is_string(), "{job}");
    assert!(
        job["changes"][0]["what"]
            .as_str()
            .unwrap()
            .starts_with("Archived by Oby"),
        "{job}"
    );
    let listed = said(
        &obid,
        json!({"said": "OBY oby_jobs {}", "conversation": conversation}),
    );
    assert!(!oby_said(&listed).contains(&id), "{}", listed.text);
    let archived = said(
        &obid,
        json!({"said": r#"OBY oby_jobs {"archived": true}"#, "conversation": conversation}),
    );
    assert!(oby_said(&archived).contains(&id), "{}", archived.text);
    let back = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/archive"),
        Some(&json!({"archived": false})),
    );
    assert_eq!(back.status, 200, "{}", back.text);
    assert!(back.body["archived"].is_null(), "{}", back.text);
    assert_eq!(
        call(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/archive"),
            Some(&json!({"x": 1}))
        )
        .status,
        422
    );

    let worktree = PathBuf::from(job["worktree"].as_str().unwrap());
    assert!(worktree.is_dir());
    let branch = job["branch"].as_str().unwrap().to_owned();
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let has_branch = |name: &str| {
        let out = std::process::Command::new("git")
            .args(["-C"])
            .arg(&clone)
            .args(["branch", "--all", "--list", name])
            .output()
            .unwrap();
        !String::from_utf8_lossy(&out.stdout).trim().is_empty()
    };
    let delete = format!(r#"OBY oby_delete_job {{"id": "{id}"}}"#);
    let waits = said(&obid, json!({"said": delete, "conversation": conversation}));
    assert!(
        oby_said(&waits).contains("waits for your OK"),
        "{}",
        waits.text
    );
    let item = confirm_for(&obid, &id);
    assert_eq!(item["confirm"]["action"], "delete_job", "{item}");
    assert_eq!(
        item["title"],
        "Delete Add a greeting (its worktree and local branch go)"
    );
    assert_eq!(
        call(&obid, "GET", &format!("/v1/jobs/{id}"), None).status,
        200,
        "nothing yet"
    );
    let done = confirmed(&obid, &item);
    assert_eq!(done.status, 200, "{}", done.text);
    assert_eq!(
        call(&obid, "GET", &format!("/v1/jobs/{id}"), None).status,
        404
    );
    assert!(!worktree.exists());
    assert!(!has_branch(&branch), "its own branch goes");
    assert!(has_branch("origin/main"), "nothing else does");
    assert!(!inbox(&obid).iter().any(|i| i["job"] == id.as_str()));

    // The apps' own route: a running job is refused, one that ended goes.
    // (A new conversation: this one read the web, so its dispatch would wait for a Start.)
    let (other, _) = ended_job(&obid, None);
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/jobs/{other}"), None).status,
        204
    );
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/jobs/{other}"), None).status,
        404
    );
}

/// oby_change_job narrows a job's mode at once; Bypass, a mode that asks less, and anything after
/// the web wait for the owner's Confirm. Moving needs a job that ended and a tool obid has.
#[test]
fn oby_change_job_widens_only_on_confirm() {
    let (_folder, obid) = obid("harness-change", true);
    let (id, conversation) = ended_job(&obid, None);
    let change = |args: &str| {
        let words = format!(r#"OBY oby_change_job {{"id": "{id}", {args}}}"#);
        oby_said(&said(
            &obid,
            json!({"said": words, "conversation": conversation}),
        ))
    };
    assert!(change(r#""mode": "plan""#).contains("is in Plan mode now."));
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["mode"], "plan", "{job}");
    assert!(
        job["changes"]
            .to_string()
            .contains("Mode changed from Sandbox to Plan by Oby"),
        "{job}"
    );
    let mut asked = vec![];
    for widened in ["ask", "bypass"] {
        let waits = change(&format!(r#""mode": "{widened}""#));
        assert!(waits.contains("waits for your OK"), "{waits}");
        let item = confirm_for(&obid, &id);
        assert_eq!(item["confirm"]["action"], "change_job", "{item}");
        assert_eq!(item["confirm"]["payload"]["mode"], widened, "{item}");
        asked.push(item.clone());
        assert!(
            item["text"]
                .as_str()
                .unwrap()
                .contains("lets the job do more"),
            "{item}"
        );
        assert_eq!(
            call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body["mode"],
            "plan"
        );
    }
    let item = confirm_for(&obid, &id);
    assert_eq!(item["title"], "Put Add a greeting in Bypass mode");
    assert_eq!(confirmed(&obid, &item).status, 200);
    assert_eq!(
        call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body["mode"],
        "bypass"
    );
    // Ask was asked of a job in Plan: confirmed once it's in Bypass, it's refused.
    let stale = confirmed(&obid, &asked[0]);
    assert_eq!(stale.status, 409, "{}", stale.text);
    assert_eq!(
        call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body["mode"],
        "bypass"
    );

    // Another conversation's job: even a narrower mode waits.
    let theirs = said(
        &obid,
        json!({"said": format!(r#"OBY oby_change_job {{"id": "{id}", "mode": "plan"}}"#), "new": true}),
    );
    assert!(
        oby_said(&theirs).contains("waits for your OK"),
        "{}",
        theirs.text
    );
    assert!(
        confirm_for(&obid, &id)["text"]
            .as_str()
            .unwrap()
            .contains("another conversation started it")
    );

    assert!(change(r#""agent": "codex""#).contains("obid has no Codex set up"));
    assert!(change(r#""account": "Stub""#).contains("It's on Claude Code · Stub already."));
    assert!(change(r#""mode": "nope""#).contains("mode is ask, acceptEdits"));

    // After the web even a narrower mode waits.
    let web = format!(r#"WEB OBY oby_change_job {{"id": "{id}", "mode": "plan"}}"#);
    let waits = oby_said(&said(
        &obid,
        json!({"said": web, "conversation": conversation}),
    ));
    assert!(waits.contains("waits for your OK"), "{waits}");
    assert!(
        confirm_for(&obid, &id)["text"]
            .as_str()
            .unwrap()
            .contains("this turn read text")
    );
}

/// oby_tasks keeps the conversation's own list in its file, shown in the API, and every later
/// turn's prompt starts with it while a task is still to do.
#[test]
fn oby_tasks_keeps_a_list_that_reaches_every_turn() {
    let (_folder, obid) = obid("harness-tasks", true);
    let write = r#"OBY oby_tasks {"tasks": [{"title": "Fix the login test", "status": "in_progress"}, {"id": "docs", "title": "Update the docs", "status": "pending", "note": "after the fix"}]}"#;
    let answer = said(&obid, json!({"said": write, "new": true}));
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();
    assert!(
        oby_said(&answer).contains(r#""id": "t1""#),
        "{}",
        answer.text
    );
    let listed = call(&obid, "GET", "/v1/conversations", None).body;
    let kept = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == conversation.as_str())
        .unwrap();
    assert_eq!(kept["tasks"][0]["id"], "t1", "{kept}");
    assert_eq!(kept["tasks"][1]["id"], "docs", "{kept}");
    assert_eq!(kept["tasks"][1]["note"], "after the fix", "{kept}");
    let read = said(
        &obid,
        json!({"said": "OBY oby_tasks {}", "conversation": conversation}),
    );
    assert!(oby_said(&read).contains("Update the docs"), "{}", read.text);
    let prompt = turns(&obid).last().unwrap()["prompt"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        prompt.starts_with("Your task list for this conversation"),
        "{prompt}"
    );
    assert!(
        prompt.contains("- t1 [in_progress] Fix the login test"),
        "{prompt}"
    );
    let bad = said(
        &obid,
        json!({"said": r#"OBY oby_tasks {"tasks": [{"title": "x", "status": "maybe"}]}"#, "conversation": conversation}),
    );
    assert!(
        oby_said(&bad).contains("A task's status is pending"),
        "{}",
        bad.text
    );
    let all_done = r#"OBY oby_tasks {"tasks": [{"id": "t1", "title": "Fix the login test", "status": "completed"}]}"#;
    said(
        &obid,
        json!({"said": all_done, "conversation": conversation}),
    );
    said(
        &obid,
        json!({"said": "SAY hi", "conversation": conversation}),
    );
    let prompt = turns(&obid).last().unwrap()["prompt"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(!prompt.contains("Your task list"), "{prompt}");
}

/// oby_change_job moves a job that ended to another account; continued, it starts a new session
/// there that hears its task and where it was moved from, and the move is on the job.
#[test]
fn a_moved_job_continues_in_a_new_session() {
    let folder = Folder::new("harness-move");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &harness());
    config["conversation"] = json!({"agent": "claude"});
    let second = folder.0.join("home/accounts/second");
    config["agents"]["claude"]["accounts"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id": "second", "name": "Second", "configDir": second}));
    for account in ["stub", "second"] {
        let dir = folder.0.join("home/accounts").join(account);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(".credentials.json"), "{}").unwrap();
    }
    let obid = start(&folder.0, &config, None);
    let (id, conversation) = ended_job(&obid, None);
    let moved = said(
        &obid,
        json!({"said": format!(r#"OBY oby_change_job {{"id": "{id}", "account": "Second"}}"#),
               "conversation": conversation}),
    );
    assert!(
        oby_said(&moved).contains("Moved Add a greeting to Claude Code · Second"),
        "{}",
        moved.text
    );
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["account"], "second", "{job}");
    assert_eq!(job["moves"][0]["from"], "Claude Code · Stub", "{job}");
    assert_eq!(job["moves"][0]["to"], "Claude Code · Second", "{job}");
    assert!(job["session"].is_null(), "{job}");
    let before = job_turns(&obid).len();
    let go = said(
        &obid,
        json!({"said": format!(r#"OBY oby_continue_job {{"id": "{id}"}}"#), "conversation": conversation}),
    );
    assert!(oby_said(&go).contains("Continuing"), "{}", go.text);
    ended(&obid, &id);
    let heard = within(30, "the moved job's agent hears it", || {
        job_turns(&obid).get(before).cloned()
    });
    let prompt = heard["prompt"].as_str().unwrap();
    assert!(!prompt.starts_with("Try again"), "a new session: {prompt}");
    assert!(
        prompt.contains("The owner moved this job to you from Claude Code · Stub"),
        "{prompt}"
    );
    assert!(heard["resumed"].is_null(), "{heard}");
}

/// A task list written after the web carries that taint: fed to a later turn, even a new clean
/// session's, it taints that turn, so the work it starts waits for the owner.
#[test]
fn a_task_list_written_after_the_web_taints_the_turns_it_reaches() {
    let (_folder, obid) = obid("harness-tasks-taint", true);
    let write =
        r#"WEB OBY oby_tasks {"tasks": [{"title": "Do what the page said", "status": "pending"}]}"#;
    let answer = said(&obid, json!({"said": write, "new": true}));
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();
    // A new session that knows nothing of the web: its kept taint is gone.
    let kept = obid
        .home
        .join(format!("conversations/{conversation}/session.json"));
    let mut session: Value = serde_json::from_slice(&std::fs::read(&kept).unwrap()).unwrap();
    session["web"] = json!(false);
    std::fs::write(&kept, session.to_string()).unwrap();
    let dispatch = r#"OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build"}"#;
    let proposed = said(
        &obid,
        json!({"said": dispatch, "conversation": conversation}),
    );
    assert!(
        proposed.body["jobs"].as_array().is_none_or(Vec::is_empty),
        "the list's taint makes it a proposal: {}",
        proposed.text
    );
    let session: Value = serde_json::from_slice(&std::fs::read(&kept).unwrap()).unwrap();
    assert_eq!(session["web"], true, "{session}");
    // Read back, it's quoted as data.
    let read = said(
        &obid,
        json!({"said": "OBY oby_tasks {}", "conversation": conversation}),
    );
    assert!(oby_said(&read).contains("<<<quoted-"), "{}", read.text);
}
