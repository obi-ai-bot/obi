//! Codex's app-server adapter and the Agent Client Protocol's (Cursor), each driving a scripted
//! stand-in for the tool (tests/agents/fake-codex, tests/agents/fake-cursor) through the real obid
//! binary, asked over HTTP, in the job sandbox: a job that commits, obid's answers to what the
//! agent asks (and the fixed denials, in every mode), the session picked up again in the next
//! round, the model and the mode, a tool's own requests obid refuses, a signed-out account, a turn
//! that fails, and Stop. No credentials: the stand-ins sign in from a file the test writes.
//!
//! What the Swift runner's ACPTests and CursorTests checked of its own types is covered here
//! through the API, and in src/acp.rs and src/codex.rs for the wire format (tests/PORTING.md).

mod support;

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use support::*;

fn agents() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents")
}

/// obid with the fixture repository, Codex and Cursor (the stand-ins), and no Claude Code: each
/// account in a folder of its own. Cursor's account is signed in unless `signed_out`.
fn obid(folder: &Folder, signed_out: bool) -> Obid {
    obid_and_remote(folder, signed_out).0
}

/// [`obid`], and the fixture's bare remote.
fn obid_and_remote(folder: &Folder, signed_out: bool) -> (Obid, PathBuf) {
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &agents().join("fake-claude"));
    let accounts = folder.0.join("home/accounts");
    config["agents"] = json!({
        "codex": {"bin": agents().join("fake-codex"),
                  "accounts": [{"id": "work", "name": "Work", "configDir": accounts.join("codex-work")}]},
        "cursor": {"bin": agents().join("fake-cursor"),
                   "accounts": [{"id": "cursor", "name": "Personal", "configDir": accounts.join("cursor")}]}
    });
    let cursor = accounts.join("cursor");
    // Where Cursor's file store keeps its login.
    let login = cursor.join(if cfg!(target_os = "macos") {
        ".cursor/auth.json"
    } else {
        ".config/cursor/auth.json"
    });
    std::fs::create_dir_all(login.parent().unwrap()).unwrap();
    std::fs::create_dir_all(cursor.join(".config")).unwrap();
    if !signed_out {
        std::fs::write(&login, "{}").unwrap();
    }
    // Cursor's own settings: obid keeps its keys and empties what it would let through.
    std::fs::write(
        cursor.join("cli-config.json"),
        r#"{"authInfo": {"email": "owner@example.com"}, "version": 1, "permissions": {"allow": ["Shell(*)"], "deny": []}}"#,
    )
    .unwrap();
    (start(&folder.0, &config, None), remote)
}

fn dispatch(obid: &Obid, job: Value) -> String {
    let mut whole = json!({"repo": "obi-e2e/fixture-app", "kind": "research", "check": "true"});
    for (key, value) in job.as_object().unwrap() {
        whole[key] = value.clone();
    }
    let answer = call(obid, "POST", "/v1/jobs", Some(&json!({ "job": whole })));
    assert_eq!(answer.status, 201, "{}", answer.text);
    answer.body["id"].as_str().unwrap().to_owned()
}

fn ended(obid: &Obid, id: &str) -> Value {
    let answer = call(obid, "GET", &format!("/v1/jobs/{id}/wait"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

fn summary(job: &Value) -> &str {
    job["summary"].as_str().unwrap_or("")
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}");
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// Whether the agent of job `id`, which writes `.obi/beat` every 50 ms, has stopped.
fn stopped_beating(obid: &Obid, id: &str) -> bool {
    let path = obid.home.join("worktrees").join(id).join(".obi/beat");
    let first = std::fs::read_to_string(&path).ok();
    std::thread::sleep(Duration::from_millis(400));
    std::fs::read_to_string(&path).ok() == first
}

fn beats(obid: &Obid, id: &str) {
    let path = obid.home.join("worktrees").join(id).join(".obi/beat");
    within(30, "the agent beats", || path.exists().then_some(()));
}

/// A Codex job: the thread starts in obid's sandbox with every approval coming to obid, its file
/// change and its commit are approved, its commit counts, and its words are the summary. Its
/// CODEX_HOME is a folder of the job's own (#655), never the account's: a box never writes it.
#[test]
fn codex_commits_with_obids_approval() {
    let folder = Folder::new("codex-commits");
    let obid = obid(&folder, false);
    let id = dispatch(
        &obid,
        json!({"agent": "codex", "kind": "build", "task": "COMMIT: hello.txt", "check": "test -f hello.txt", "model": "gpt-6-sol"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["agent"], "codex");
    assert_eq!(job["account"], "work");
    assert_eq!(job["commits"], 1);
    assert_eq!(summary(&job), "Added hello.txt.");
    let thread = job["session"].as_str().unwrap();
    let kept: Value = serde_json::from_str(
        &std::fs::read_to_string(
            obid.home
                .join("logins")
                .join(&id)
                .join(format!("threads/{thread}.json")),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(kept["sandbox"], "danger-full-access");
    assert_eq!(kept["approvalPolicy"], "untrusted");
    assert_eq!(kept["model"], "gpt-6-sol");
    let worktree = obid.home.join("worktrees").join(&id);
    assert_eq!(
        git(&worktree, &["log", "-1", "--format=%s"]),
        "Add hello.txt"
    );

    let id = dispatch(&obid, json!({"agent": "codex", "task": "ENV"}));
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    let home = obid.home.join("logins").join(&id);
    assert!(
        summary(&job).contains(&format!("CODEX_HOME={}", home.display())),
        "{job}"
    );
    // The account's folder got nothing of the jobs'.
    let account = folder.0.join("home/accounts/codex-work");
    assert!(
        !account.join("threads").exists(),
        "a job wrote the account's folder"
    );

    let status = call(&obid, "GET", "/v1/status", None).body;
    let accounts: Vec<(&str, &str)> = status["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| (a["id"].as_str().unwrap(), a["agent"].as_str().unwrap()))
        .collect();
    assert_eq!(accounts, [("work", "codex"), ("cursor", "cursor")]);
}

/// obid's fixed denials hold for Codex: a push is declined, and since the decision carries no
/// words, the turn hears why; a change outside the worktree is declined and nothing is written.
/// A request obid doesn't answer is refused, so Codex never waits on it; a command that's fine is
/// accepted.
#[test]
fn codex_hears_what_obid_declined_and_why() {
    let folder = Folder::new("codex-declines");
    let obid = obid(&folder, false);
    let push = dispatch(
        &obid,
        json!({"agent": "codex", "task": "ASK: /bin/zsh -lc 'git push origin HEAD'"}),
    );
    let outside = dispatch(&obid, json!({"agent": "codex", "task": "OUTSIDE"}));
    let unknown = dispatch(&obid, json!({"agent": "codex", "task": "UNKNOWN"}));
    let fine = dispatch(&obid, json!({"agent": "codex", "task": "ASK: node --test"}));

    let job = ended(&obid, &push);
    assert_eq!(job["status"], "done", "{job}");
    assert!(
        summary(&job).starts_with(
            "answer: decline\nheard: obid declined that: obid publishes the job's work itself"
        ),
        "{job}"
    );
    let job = ended(&obid, &outside);
    assert!(
        summary(&job).starts_with(
            "answer: decline\nheard: obid declined that: Stay inside this job's worktree"
        ),
        "{job}"
    );
    assert!(!obid.home.join("worktrees/outside.txt").exists());
    let job = ended(&obid, &unknown);
    assert!(summary(&job).contains("-32601"), "{job}");
    let job = ended(&obid, &fine);
    assert_eq!(summary(&job), "answer: accept", "{job}");
}

/// Plan mode: Codex reads and plans, and obid declines its file changes.
#[test]
fn codex_in_plan_mode_changes_no_file() {
    let folder = Folder::new("codex-plan");
    let obid = obid(&folder, false);
    let id = dispatch(
        &obid,
        json!({"agent": "codex", "kind": "build", "task": "COMMIT: plan.txt", "mode": "plan"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "failed", "{job}");
    assert_eq!(job["commits"], Value::Null);
    assert!(
        summary(&job).contains("Nothing committed: edit: decline"),
        "{job}"
    );
    assert!(
        !obid
            .home
            .join("worktrees")
            .join(&id)
            .join("plan.txt")
            .exists()
    );
}

/// Review jobs only read (#630): Plan mode whatever they ask for or the default says, so Codex's
/// file change is declined, and a mode change keeps them in Plan. Investigations run as other
/// work does (the owner's decision of 2026-10-18).
#[test]
fn codex_reviews_and_investigates_in_plan_mode() {
    let folder = Folder::new("codex-read-only");
    let obid = obid(&folder, false);
    {
        let kind = "review";
        let id = dispatch(
            &obid,
            json!({"agent": "codex", "kind": kind, "task": "COMMIT: plan.txt", "mode": "bypass"}),
        );
        let changed = call(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/mode"),
            Some(&json!({"mode": "bypass"})),
        );
        assert_eq!(changed.status, 200, "{}", changed.text);
        assert_eq!(changed.body["mode"], "plan", "{kind}");
        let job = ended(&obid, &id);
        assert_eq!(job["mode"], "plan", "{job}");
        assert_eq!(job["status"], "done", "{job}");
        assert_eq!(job["commits"], 0, "{job}");
        assert!(summary(&job).starts_with("edit: decline"), "{job}");
        assert!(
            !obid
                .home
                .join("worktrees")
                .join(&id)
                .join("plan.txt")
                .exists()
        );
    }
}

/// A review on Codex that commits anyway (#630) fails: it publishes nothing, says so, and shows
/// the commits it made.
#[test]
fn a_review_that_commits_fails() {
    let folder = Folder::new("codex-review-commits");
    let obid = obid(&folder, false);
    let id = dispatch(
        &obid,
        json!({"agent": "codex", "kind": "review", "task": "SNEAK: notes.txt"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "failed", "{job}");
    assert_eq!(
        summary(&job),
        "A review made commits; nothing was published.",
        "{job}"
    );
    assert_eq!(job["commits"], 1, "{job}");
    assert_eq!(job["published"], Value::Null, "{job}");
}

/// The next round (the check failed) picks the same thread up again (`thread/resume`) in a new
/// app-server, which remembers the task; a turn that fails says what the API said; Stop ends the server and
/// everything it started within Stop's 2 seconds.
#[test]
fn codex_resumes_fails_and_stops() {
    let folder = Folder::new("codex-rounds");
    let obid = obid(&folder, false);
    let twice = dispatch(
        &obid,
        json!({"agent": "codex", "task": "TWICE", "rounds": 2, "check": "test -f .obi/twice"}),
    );
    let fail = dispatch(&obid, json!({"agent": "codex", "task": "FAIL"}));
    let sleep = dispatch(&obid, json!({"agent": "codex", "task": "SLEEP"}));

    let job = ended(&obid, &twice);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["round"], 2);
    let thread = job["session"].as_str().unwrap();
    let summaries = job["summaries"].as_array().unwrap();
    assert_eq!(summaries[0], "First round.");
    let second = summaries[1].as_str().unwrap();
    assert!(
        second.starts_with(&format!("Round 2 on thread {thread}, which remembers: "))
            && second.contains("What the user asked for: TWICE")
            && second.ends_with("GOAL MET"),
        "{job}"
    );
    let job = ended(&obid, &fail);
    assert_eq!(job["status"], "failed", "{job}");
    assert_eq!(summary(&job), "Codex hit an error: it broke");

    beats(&obid, &sleep);
    let started = std::time::Instant::now();
    let stopped = call(&obid, "POST", &format!("/v1/jobs/{sleep}/stop"), None);
    assert_eq!(stopped.status, 200);
    assert_eq!(stopped.body["status"], "stopped");
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(stopped_beating(&obid, &sleep), "Codex outlived its stop");
}

/// A Cursor job: Cursor writes without asking (as the probe saw), asks before its commit, and
/// obid picks `allow_once`, never `allow_always`. Its three folders are the job's own (#655), with
/// a copy of the account's login and settings, and obid's settings for it allow nothing ahead of
/// obid, keeping Cursor's own keys. The account's own folder is left as it was.
#[test]
fn cursor_commits_with_obids_approval() {
    let folder = Folder::new("cursor-commits");
    let obid = obid(&folder, false);
    let id = dispatch(
        &obid,
        json!({"agent": "cursor", "kind": "build", "task": "COMMIT: hello.txt", "check": "test -f hello.txt"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["agent"], "cursor");
    assert_eq!(job["account"], "cursor");
    assert_eq!(job["commits"], 1);
    // What it said after its last tool call is the summary.
    assert_eq!(summary(&job), "Added hello.txt.");
    assert!(job["session"].as_str().is_some_and(|s| !s.is_empty()));

    let id = dispatch(
        &obid,
        json!({"agent": "cursor", "task": "ENV", "model": "gpt-5.6-luna"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    let home = obid.home.join("logins").join(&id);
    let account = folder.0.join("home/accounts/cursor");
    assert_eq!(
        std::fs::read_to_string(account.join("cli-config.json")).unwrap(),
        r#"{"authInfo": {"email": "owner@example.com"}, "version": 1, "permissions": {"allow": ["Shell(*)"], "deny": []}}"#,
        "a job's settings reached the account's folder"
    );
    assert_eq!(
        summary(&job),
        [
            format!("HOME={}", home.display()),
            format!("XDG_CONFIG_HOME={}", home.join(".config").display()),
            format!("CURSOR_CONFIG_DIR={}", home.display()),
            "model=gpt-5.6-luna[context=272k,reasoning=medium]".into(),
            "mode=agent".into(),
            "approvalMode=allowlist".into(),
            "allow=[]".into(),
            "kept=owner@example.com".into(),
        ]
        .join("\n")
    );
}

/// obid's fixed denials hold for Cursor: a push is `reject_once`, and the next round's prompt
/// starts with what obid declined and why, since ACP's answer carries no words. Cursor's question
/// is skipped, a request for obid's files is refused, and a fine command is allowed once.
#[test]
fn cursor_hears_what_obid_declined_at_its_next_prompt() {
    let folder = Folder::new("cursor-declines");
    let obid = obid(&folder, false);
    let twice = dispatch(
        &obid,
        json!({"agent": "cursor", "task": "TWICE", "rounds": 2, "check": "test -f .obi/twice"}),
    );
    let question = dispatch(&obid, json!({"agent": "cursor", "task": "QUESTION"}));
    let fs = dispatch(&obid, json!({"agent": "cursor", "task": "FS"}));
    let fine = dispatch(
        &obid,
        json!({"agent": "cursor", "task": "ASK: node --test"}),
    );

    let job = ended(&obid, &twice);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["round"], 2);
    let summaries = job["summaries"].as_array().unwrap();
    assert_eq!(summaries[0], "push: reject-once");
    assert!(
        summaries[1]
            .as_str()
            .unwrap()
            .starts_with("heard: obid declined git push: obid publishes the job's work itself."),
        "{job}"
    );
    assert_eq!(ended(&obid, &question)["summary"], "question: skipped");
    assert_eq!(ended(&obid, &fs)["summary"], "fs: error -32601");
    assert_eq!(ended(&obid, &fine)["summary"], "answer: allow-once");
}

/// Plan mode: Cursor plans in its own plan mode; its plan is approved as Claude Code's
/// `ExitPlanMode` is, and the same round goes on in its agent mode.
#[test]
fn cursor_plans_then_goes_ahead() {
    let folder = Folder::new("cursor-plan");
    let obid = obid(&folder, false);
    let id = dispatch(
        &obid,
        json!({"agent": "cursor", "task": "PLAN", "mode": "plan"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(
        summary(&job),
        "mode agent: Your plan is approved: carry it out now, then finish with a short summary."
    );
}

/// A signed-out Cursor account fails the job saying so; a prompt answered with an error, or a
/// refusal, fails it with the tool's words; Stop cancels the prompt and ends Cursor.
#[test]
fn cursor_signed_out_failures_and_stop() {
    let folder = Folder::new("cursor-out");
    let obid = obid(&folder, true);
    let id = dispatch(&obid, json!({"agent": "cursor", "task": "anything"}));
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "failed", "{job}");
    assert!(
        summary(&job).starts_with("Cursor · Personal is signed out"),
        "{job}"
    );
    drop(obid);

    let folder = Folder::new("cursor-fails");
    let obid = self::obid(&folder, false);
    let fail = dispatch(&obid, json!({"agent": "cursor", "task": "FAIL"}));
    let refuse = dispatch(&obid, json!({"agent": "cursor", "task": "REFUSE"}));
    let sleep = dispatch(&obid, json!({"agent": "cursor", "task": "SLEEP"}));
    assert_eq!(
        ended(&obid, &fail)["summary"],
        "Cursor hit an error: it broke"
    );
    let job = ended(&obid, &refuse);
    assert_eq!(job["status"], "failed");
    assert_eq!(summary(&job), "The model refused to continue.");
    beats(&obid, &sleep);
    let started = std::time::Instant::now();
    let stopped = call(&obid, "POST", &format!("/v1/jobs/{sleep}/stop"), None);
    assert_eq!(stopped.body["status"], "stopped");
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(stopped_beating(&obid, &sleep), "Cursor outlived its stop");
}

/// Codex runs `danger-full-access` and Cursor edits without asking: obid's job sandbox is what
/// keeps either from writing outside the worktree.
#[test]
fn the_sandbox_holds_what_the_tools_dont_ask_about() {
    let folder = Folder::new("adapters-escape");
    let obid = obid(&folder, false);
    let codex = dispatch(&obid, json!({"agent": "codex", "task": "ESCAPE"}));
    let cursor = dispatch(&obid, json!({"agent": "cursor", "task": "ESCAPE"}));
    for id in [codex, cursor] {
        let job = ended(&obid, &id);
        assert_eq!(job["status"], "done", "{job}");
        assert!(summary(&job).starts_with("escape: E"), "{job}");
    }
    assert!(!obid.home.join("worktrees/escaped.txt").exists());
}

/// A repository whose `.cursor/cli.json` lets commands through without asking: Cursor doesn't
/// start, and the job says why. And jobs name a tool obid has: Claude Code isn't set up here.
#[test]
fn a_repository_allowlist_keeps_cursor_from_starting() {
    let folder = Folder::new("cursor-allowlist");
    let (obid, remote) = obid_and_remote(&folder, false);
    // The fixture's remote, with a commit that adds the allowlist.
    let work = folder.0.join("work");
    git(
        &folder.0,
        &[
            "clone",
            "-q",
            remote.to_str().unwrap(),
            work.to_str().unwrap(),
        ],
    );
    std::fs::create_dir_all(work.join(".cursor")).unwrap();
    std::fs::write(
        work.join(".cursor/cli.json"),
        r#"{"permissions": {"allow": ["Shell(npm test)"]}}"#,
    )
    .unwrap();
    git(&work, &["add", ".cursor/cli.json"]);
    git(
        &work,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.com",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "allowlist",
        ],
    );
    git(&work, &["push", "-q", "origin", "HEAD:main"]);
    let id = dispatch(&obid, json!({"agent": "cursor", "task": "anything"}));
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "failed", "{job}");
    assert!(
        summary(&job).starts_with("Cursor didn't start: this repository's .cursor/cli.json lets it run Shell(npm test) without asking obid"),
        "{job}"
    );

    let answer = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "x", "agent": "claude"}}),
        ),
    );
    assert_eq!(answer.status, 422);
    assert!(
        answer.text.contains("names no agents.claude"),
        "{}",
        answer.text
    );
    let answer = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "x", "account": "Personal"}}),
        ),
    );
    assert_eq!(answer.status, 201, "{}", answer.text);
    assert_eq!(answer.body["agent"], "cursor");
}

/// The real `cursor-agent`, signed out on a fresh account folder: obid starts it in the job sandbox,
/// speaks ACP with it, and the job fails saying the account is signed out. No credentials. Runs only
/// when asked (`cargo test -- --ignored`) on a machine with `cursor-agent` on PATH.
#[test]
#[ignore]
fn the_real_cursor_agent_signed_out_says_so() {
    let Some(bin) = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|dir| dir.join("cursor-agent"))
        .find(|p| p.exists())
    else {
        panic!("cursor-agent isn't on PATH");
    };
    let folder = Folder::new("real-cursor");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &agents().join("fake-claude"));
    // A short folder: Cursor keeps its sockets under its config folder only while that path is
    // short enough for a socket's name (else in /tmp/.cursor, which the sandbox doesn't let it write).
    let fresh = Folder(
        std::path::Path::new("/tmp")
            .canonicalize()
            .unwrap()
            .join(format!("obid-cursor-{}", std::process::id())),
    );
    let _ = std::fs::remove_dir_all(&fresh.0);
    config["agents"] = json!({"cursor": {"bin": bin, "accounts": [
        {"id": "fresh", "name": "Fresh", "configDir": fresh.0}]}});
    let obid = start(&folder.0, &config, None);
    let id = dispatch(&obid, json!({"task": "Say hello."}));
    let job = ended(&obid, &id);
    eprintln!("{job}");
    assert_eq!(job["status"], "failed", "{job}");
    assert!(
        summary(&job).starts_with("Cursor · Fresh is signed out"),
        "{job}\n{}",
        std::fs::read_to_string(obid.home.join("jobs").join(&id).join("agent.log"))
            .unwrap_or_default()
    );
}

/// In `ask`, Codex's and Cursor's commands wait for the owner like Claude Code's
/// (docs/runner-api.md, "Permission modes"): the job shows the permission, and the owner's answer
/// reaches the tool as its own decision (Codex's `accept` or `decline`, Cursor's `allow-once` or
/// `reject-once`).
#[test]
fn codex_and_cursor_ask_the_owner_in_ask_mode() {
    let folder = Folder::new("ask-tools");
    let obid = obid(&folder, false);
    let codex = dispatch(
        &obid,
        json!({"agent": "codex", "task": "ASK: node --test", "mode": "ask"}),
    );
    let cursor = dispatch(
        &obid,
        json!({"agent": "cursor", "task": "ASK: node --test", "mode": "ask"}),
    );
    let answer = |id: &str, decision: &str| {
        let job = within(60, "the tool waits for the owner", || {
            let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
            (job["permission"]["title"] == "Run node --test").then_some(job)
        });
        let answered = call(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/permission"),
            Some(&json!({"id": job["permission"]["id"], "decision": decision})),
        );
        assert_eq!(answered.status, 200, "{}", answered.text);
    };
    answer(&codex, "allow");
    answer(&cursor, "deny");
    assert_eq!(summary(&ended(&obid, &codex)), "answer: accept");
    assert_eq!(summary(&ended(&obid, &cursor)), "answer: reject-once");
}

/// Codex wraps each command in `/bin/zsh -lc "…"` (#634): the card asks about the command out of
/// that shell, all of it, and offers Always with a rule when it's a single simple command.
#[test]
fn codex_cards_show_the_command_out_of_its_shell() {
    let folder = Folder::new("codex-cards");
    let obid = obid(&folder, false);
    let simple = dispatch(
        &obid,
        json!({"agent": "codex", "task": r#"ASK: /bin/zsh -lc "git add \"src/my notes.txt\"""#, "mode": "ask"}),
    );
    let chained = dispatch(
        &obid,
        json!({"agent": "codex", "task": r#"ASK: /bin/zsh -lc "git add src/permissions.rs src/codex.rs && git commit -m \"fix(obid): show it all\"""#, "mode": "ask"}),
    );
    let card = |id: &str| {
        within(60, "the tool waits for the owner", || {
            let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
            job["permission"]
                .is_object()
                .then(|| job["permission"].clone())
        })
    };
    let answer = |id: &str, card: &Value| {
        let answered = call(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/permission"),
            Some(&json!({"id": card["id"], "decision": "allow"})),
        );
        assert_eq!(answered.status, 200, "{}", answered.text);
    };
    let first = card(&simple);
    assert_eq!(first["title"], "Run git add", "{first}");
    assert_eq!(first["detail"], r#"git add "src/my notes.txt""#, "{first}");
    assert_eq!(first["rule"], "Bash(git add:*)", "{first}");
    assert_eq!(
        first["always"],
        "Yes, and don't ask again for git add in obi-e2e/fixture-app"
    );
    let second = card(&chained);
    let command =
        r#"git add src/permissions.rs src/codex.rs && git commit -m "fix(obid): show it all""#;
    assert_eq!(second["title"], format!("Run {command}"), "{second}");
    assert_eq!(second["detail"], command, "{second}");
    assert_eq!(second["rule"], Value::Null, "{second}");
    answer(&simple, &first);
    answer(&chained, &second);
    assert_eq!(summary(&ended(&obid, &simple)), "answer: accept");
    assert_eq!(summary(&ended(&obid, &chained)), "answer: accept");
}

/// Codex's usage reaches its Account: the `account/rateLimits/read` obid sends as the run starts,
/// then an `account/rateLimits/updated` that changes one window and keeps the other.
#[test]
fn codex_reports_its_accounts_usage() {
    let folder = Folder::new("codex-usage");
    let obid = obid(&folder, false);
    let reset = obi_protocol::time::now() + 86_400;
    let read = json!({"limitId": "codex", "primary": {"windowDurationMins": 300, "usedPercent": 20, "resetsAt": reset - 3_600},
        "secondary": {"windowDurationMins": 10080, "usedPercent": 40, "resetsAt": reset}});
    let id = dispatch(
        &obid,
        json!({"agent": "codex", "task": format!("READ: {read}")}),
    );
    assert_eq!(ended(&obid, &id)["status"], "done");
    let work = |obid: &Obid| call(obid, "GET", "/v1/status", None).body["accounts"][0].clone();
    let account = work(&obid);
    assert_eq!(account["id"], "work");
    assert_eq!(account["fiveHour"], 0.2);
    assert_eq!(account["sevenDay"], 0.4);
    assert_eq!(
        account["fiveHourResets"],
        obi_protocol::time::format(reset - 3_600)
    );
    assert_eq!(account["sevenDayResets"], obi_protocol::time::format(reset));
    assert_eq!(account["reserved"], false);

    let update = json!({"primary": {"windowDurationMins": 300, "usedPercent": 100, "resetsAt": reset - 1_800}});
    let id = dispatch(
        &obid,
        json!({"agent": "codex", "task": format!("LIMITS: {update}")}),
    );
    ended(&obid, &id);
    let account = work(&obid);
    assert_eq!(account["fiveHour"], 1.0);
    assert_eq!(account["sevenDay"], 0.4);
    assert_eq!(
        account["fullUntil"],
        obi_protocol::time::format(reset - 1_800)
    );
}
