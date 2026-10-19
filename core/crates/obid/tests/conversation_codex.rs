//! Codex as a conversation's agent (docs/conversation-harness.md, step 4): `codex app-server` in
//! the conversation's room, boxed like the Claude Code session, one thread per conversation, with
//! the same Oby tools over MCP and the same rules. The agent here is a stand-in
//! (tests/agents/fake-codex-harness).
mod support;

use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use support::*;

fn agent(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/agents")
        .join(name)
}

/// obid with conversations on Codex (the stand-in), and Claude Code's stand-in for the plan loop's
/// brain; `signed_in` puts a login in the Codex account's folder.
fn obid(name: &str, signed_in: bool) -> (Folder, Obid) {
    obid_with(name, signed_in, "fake-codex-harness", None)
}

/// [`obid`] with `bin` as Codex, and `login` as the account's auth.json when there is one.
fn obid_with(name: &str, signed_in: bool, bin: &str, login: Option<Value>) -> (Folder, Obid) {
    let folder = Folder::new(name);
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &agent("fake-harness"));
    config["conversation"] = json!({"agent": "codex"});
    let account = folder.0.join("home/accounts/codex");
    config["agents"]["codex"] = json!({"bin": agent(bin),
        "accounts": [{"id": "cstub", "name": "Codex stub", "configDir": account}]});
    std::fs::create_dir_all(&account).unwrap();
    if signed_in {
        let login = login.unwrap_or_else(|| json!({}));
        std::fs::write(account.join("auth.json"), login.to_string()).unwrap();
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

/// What the stand-in recorded of each turn, oldest first: in each conversation's own CODEX_HOME.
fn turns(obid: &Obid) -> Vec<Value> {
    let mut all: Vec<Value> = std::fs::read_dir(obid.home.join("conversations"))
        .into_iter()
        .flatten()
        .flatten()
        .flat_map(|entry| {
            std::fs::read_to_string(entry.path().join("config/turns.jsonl"))
                .unwrap_or_default()
                .lines()
                .map(|l| serde_json::from_str::<Value>(l).unwrap())
                .collect::<Vec<_>>()
        })
        .collect();
    all.sort_by_key(|t| t["at"].as_u64());
    all
}

/// What the plan loop answered: a reply's or a question's words.
fn words(answer: &Answer) -> String {
    answer.body["text"]
        .as_str()
        .or(answer.body["question"]["text"].as_str())
        .unwrap_or("")
        .to_owned()
}

/// A ChatGPT access token (a JWT) that ends `seconds` from now.
fn access_token(seconds: i64) -> String {
    use base64::Engine;
    let encode = |v: Value| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(v.to_string());
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    format!(
        "{}.{}.{}",
        encode(json!({"alg": "RS256"})),
        encode(json!({"exp": now + seconds})),
        "s".repeat(40)
    )
}

fn inbox(obid: &Obid) -> Vec<Value> {
    let inbox = call(obid, "GET", "/v1/inbox", None);
    inbox.body.as_array().cloned().unwrap_or_default()
}

/// A turn on Codex streams its words as `delta` events, each tool item is a `step` with its tool
/// and detail, and the turn ends with Oby's `turn`, as on Claude Code. Codex runs `app-server` in
/// the room, its own sandbox off inside obid's, every approval obid's, with Oby's MCP server from
/// its arguments and the turn's token only in its environment.
#[test]
fn a_codex_turn_streams_its_words_and_ends_in_a_turn() {
    let (_folder, obid) = obid("codex-conv-stream", true);
    let events = follow_events(&obid);
    let answer = said(&obid, json!({"said": "HELLO", "new": true}));
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();
    assert_eq!(answer.body["kind"], "reply", "{}", answer.text);
    assert_eq!(answer.body["text"], "Hello there.", "{}", answer.text);

    let seen = until_oby_turn(&events, 30);
    let deltas: Vec<&Value> = seen
        .iter()
        .filter(|(n, _)| n == "delta")
        .map(|(_, d)| d)
        .collect();
    assert!(deltas.len() >= 2, "{seen:?}");
    assert!(
        deltas
            .iter()
            .all(|d| d["conversation"] == conversation.as_str())
    );
    let streamed: String = deltas.iter().map(|d| d["text"].as_str().unwrap()).collect();
    assert_eq!(streamed, "Hello there.");
    let steps: Vec<&Value> = seen
        .iter()
        .filter(|(n, d)| n == "step" && d["tool"].is_string())
        .map(|(_, d)| d)
        .collect();
    assert_eq!(steps.len(), 2, "{seen:?}");
    assert_eq!(steps[0]["tool"], "web_search");
    assert_eq!(steps[0]["detail"], "greetings");
    assert_eq!(steps[0]["state"], "running");
    assert_eq!(steps[1]["state"], "done");
    let (_, last) = seen.last().unwrap();
    assert_eq!(last["text"], "Hello there.");

    let recorded = turns(&obid);
    assert_eq!(recorded.len(), 1, "{recorded:?}");
    let argv: Vec<&str> = recorded[0]["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a.as_str().unwrap())
        .collect();
    assert_eq!(argv.last(), Some(&"app-server"), "{argv:?}");
    assert!(
        argv.iter().any(|a| a.starts_with("mcp_servers.oby.url=")
            && a.ends_with(&format!("/v1/agent/mcp/conversation-{conversation}\""))),
        "{argv:?}"
    );
    assert!(
        argv.contains(&r#"mcp_servers.oby.bearer_token_env_var="OBY_MCP_TOKEN""#),
        "{argv:?}"
    );
    assert!(argv.contains(&r#"web_search="live""#), "{argv:?}");
    // No shell (F2: under `untrusted` Codex runs its "safe" reads without asking), no ChatGPT apps
    // (a code-host login), and the turn's token kept out of any command's environment (F6).
    for setting in [
        "features.shell_tool=false",
        "features.shell_snapshot=false",
        "features.apps=false",
        "features.plugins=false",
        "features.multi_agent=false",
        "features.hooks=false",
        "features.browser_use=false",
        "features.browser_use_full_cdp_access=false",
        "features.computer_use=false",
        "features.in_app_browser=false",
        "features.in_app_local_automation=false",
        "features.view_image=false",
        "features.skill_mcp_dependency_install=false",
        "features.workspace_dependencies=false",
        "features.daemon_auto_start=false",
        "features.worktrees=false",
        r#"shell_environment_policy.exclude=["OBY_MCP_TOKEN"]"#,
    ] {
        assert!(argv.contains(&setting), "{setting}: {argv:?}");
    }
    assert!(recorded[0]["resumed"].is_null());
    assert_eq!(recorded[0]["sandbox"], "danger-full-access");
    assert_eq!(recorded[0]["approvalPolicy"], "untrusted");
    assert!(
        recorded[0]["instructions"]
            .as_str()
            .unwrap()
            .contains("oby_dispatch"),
        "{recorded:?}"
    );
    let folder = obid.home.join(format!("conversations/{conversation}"));
    assert_eq!(
        Path::new(recorded[0]["cwd"].as_str().unwrap())
            .canonicalize()
            .unwrap(),
        folder.join("room").canonicalize().unwrap()
    );
    // Its CODEX_HOME is the conversation's own, with a copy of the account's login and nothing
    // else of the account's; the copy goes when the turn ends.
    assert_eq!(
        recorded[0]["codexHome"].as_str().map(PathBuf::from),
        Some(folder.join("config"))
    );
    // (`threads` is the stand-in's own, made when its thread started.)
    assert_eq!(
        recorded[0]["holds"],
        json!(["auth.json", "threads"]),
        "{recorded:?}"
    );
    assert!(!folder.join("config/auth.json").exists());
}

/// What a turn leaves for the next Codex to load (its settings, instructions) is gone before the
/// next run.
#[test]
fn what_codex_plants_for_its_next_run_is_taken_out() {
    let (_folder, obid) = obid("codex-conv-scrub", true);
    let planted = said(&obid, json!({"said": "PLANT", "new": true}));
    let conversation = planted.body["conversation"].as_str().unwrap().to_owned();
    assert_eq!(planted.body["text"], "planted", "{}", planted.text);
    let look = said(&obid, json!({"said": "LOOK", "conversation": conversation}));
    assert_eq!(look.body["text"], "look: nothing", "{}", look.text);
    // A HOME whose `.config` is a link to fish's config: the link goes.
    let planted = said(
        &obid,
        json!({"said": "PLANTLINK", "conversation": conversation}),
    );
    assert_eq!(planted.body["text"], "planted", "{}", planted.text);
    let look = said(&obid, json!({"said": "LOOK", "conversation": conversation}));
    assert_eq!(look.body["text"], "look: nothing", "{}", look.text);
}

/// The tokens of Codex's login and the turn's MCP token never reach what obid sends (F3, F6).
#[test]
fn codex_tokens_never_reach_what_obid_sends() {
    let (_folder, obid) = obid("codex-conv-leak", true);
    let (access, refresh, id, key) = (
        access_token(10 * 24 * 3600),
        format!("rt_{}", "b".repeat(40)),
        format!("eyJhbGciOiJSUzI1NiJ9.{}", "c".repeat(40)),
        format!("sk-proj-{}", "d".repeat(40)),
    );
    std::fs::write(
        obid.home.join("accounts/codex/auth.json"),
        json!({"auth_mode": "chatgpt", "OPENAI_API_KEY": key,
               "tokens": {"access_token": access, "refresh_token": refresh, "id_token": id, "account_id": "acct"}})
            .to_string(),
    )
    .unwrap();
    let events = follow_events(&obid);
    let answer = said(&obid, json!({"said": "LEAK", "new": true}));
    let seen = until_oby_turn(&events, 30);
    let sent = format!("{} {seen:?}", answer.text);
    assert!(sent.contains("leak: "), "{sent}");
    for token in [&access, &refresh, &id, &key] {
        assert!(!sent.contains(token.as_str()), "{token} in {sent}");
    }
    // The three login tokens in the copy and the turn's MCP token, each taken out (the copy has
    // no refresh token).
    let said_back = answer.body["text"].as_str().unwrap();
    assert_eq!(said_back.matches("[redacted: ").count(), 4, "{said_back}");
}

/// A command item is never part of a conversation: Codex's shell is off, and if one runs anyway
/// (a setting Codex stopped knowing) the turn ends at once, isn't tried again, its thread is never
/// picked up again, and the plan loop says why (G1).
#[test]
fn a_command_ends_a_codex_turn() {
    let (_folder, obid) = obid("codex-conv-command", true);
    let answer = said(
        &obid,
        json!({"said": r#"RUN OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build"}"#,
               "new": true}),
    );
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();
    assert!(
        words(&answer).ends_with(
            "\n(Oby's plan loop answered: Codex ran a command (echo hi), which a conversation never does, so obid stopped it.)"
        ),
        "{}",
        answer.text
    );
    assert_eq!(turns(&obid).len(), 1, "not tried again");
    let jobs = call(&obid, "GET", "/v1/jobs", None);
    assert_eq!(jobs.body.as_array().map_or(0, Vec::len), 0, "{}", jobs.text);
    // Its thread is never picked up again, but the taint stays (finding 5): work the next turn
    // plans waits for the owner's Start.
    let kept: Value = serde_json::from_slice(
        &std::fs::read(
            obid.home
                .join(format!("conversations/{conversation}/session.json")),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(kept["session"], "", "{kept}");
    assert_eq!(kept["web"], true, "{kept}");
    let next = said(
        &obid,
        json!({"said": r#"OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build"}"#,
               "conversation": conversation}),
    );
    assert_eq!(next.body["jobs"], json!([]), "{}", next.text);
    assert_eq!(
        inbox(&obid).iter().filter(|i| i["kind"] == "start").count(),
        1,
        "{}",
        next.text
    );
    assert!(turns(&obid)[1]["resumed"].is_null());
}

/// However a command, a hook or another server's tool shows up (a helper's thread, output with no
/// item before it, a hook, an MCP call to a server that isn't Oby's), the turn ends (findings 2-4).
#[test]
fn whatever_runs_outside_obys_tools_ends_a_codex_turn() {
    let (_folder, obid) = obid("codex-conv-fatal", true);
    for (words_said, why) in [
        ("HELPERRUN", "Codex ran a command (echo helper)"),
        ("OUTPUT", "Codex ran a command"),
        ("HOOK", "Codex ran a hook"),
        ("ELSEWHERE", "Codex called elsewhere's run"),
        // Anything that isn't on the list of what a conversation's Codex may do, new kinds too.
        ("ITEM imageGeneration", "Codex used imageGeneration"),
        ("ITEM collabAgentToolCall", "Codex used collabAgentToolCall"),
        ("ITEM subAgentActivity", "Codex used subAgentActivity"),
        ("ITEM dynamicToolCall", "Codex used dynamicToolCall"),
        ("ITEM somethingNew", "Codex used somethingNew"),
        (
            "NOTICE process/outputDelta",
            "Codex sent process/outputDelta",
        ),
        (
            "NOTICE somethingNew/started",
            "Codex sent somethingNew/started",
        ),
    ] {
        let answer = said(&obid, json!({"said": words_said, "new": true}));
        assert!(
            words(&answer).ends_with(&format!(
                "\n(Oby's plan loop answered: {why}, which a conversation never does, so obid stopped it.)"
            )),
            "{words_said}: {}",
            answer.text
        );
    }
}

/// What's on the list ends no turn: thinking, a plan, a compaction, a pause, the owner's words.
#[test]
fn what_a_conversation_may_do_ends_no_codex_turn() {
    let (_folder, obid) = obid("codex-conv-allowed", true);
    for kind in [
        "reasoning",
        "plan",
        "contextCompaction",
        "sleep",
        "userMessage",
    ] {
        let answer = said(&obid, json!({"said": format!("ITEM {kind}"), "new": true}));
        assert_eq!(answer.body["text"], "item ran", "{kind}: {}", answer.text);
    }
    let answer = said(
        &obid,
        json!({"said": "NOTICE thread/tokenUsage/updated", "new": true}),
    );
    assert_eq!(answer.body["text"], "notice sent", "{}", answer.text);
}

/// A Codex that keeps a feature on whatever obid sets (`features list`, run in the conversation's
/// own box, says so) never runs a conversation: its shell (G1), its hooks (finding 4).
#[test]
fn codex_that_keeps_a_feature_on_is_refused() {
    for (bin, feature) in [
        ("fake-codex-on-shell_tool", "shell_tool"),
        ("fake-codex-on-hooks", "hooks"),
        ("fake-codex-on-image_generation", "image_generation"),
    ] {
        let (_folder, obid) = obid_with(&format!("codex-conv-{feature}"), true, bin, None);
        let answer = said(&obid, json!({"said": "HELLO", "new": true}));
        assert!(
            words(&answer).ends_with(&format!(
                "\n(Oby's plan loop answered: Codex's features list says {feature} is on whatever obid sets, so a conversation doesn't run on it.)"
            )),
            "{}",
            answer.text
        );
        assert!(turns(&obid).is_empty());
    }
}

/// The login copy never carries the refresh token, which the provider rotates (G2); a login whose
/// access token ends within 5 minutes is refused with the one line that says so.
#[test]
fn codex_login_copies_have_no_refresh_token() {
    let login = |seconds| {
        json!({"auth_mode": "chatgpt", "last_refresh": "2026-10-12T23:13:02Z",
               "tokens": {"access_token": access_token(seconds), "refresh_token": format!("rt_{}", "r".repeat(40)),
                          "id_token": access_token(seconds), "account_id": "acct"}})
    };
    let (_folder, obid) = obid_with(
        "codex-conv-copy",
        true,
        "fake-codex-harness",
        Some(login(10 * 24 * 3600)),
    );
    let copy = said(&obid, json!({"said": "COPY", "new": true}));
    assert_eq!(
        copy.body["text"], "copy: access=yes refresh=no",
        "{}",
        copy.text
    );

    std::fs::write(
        obid.home.join("accounts/codex/auth.json"),
        login(60).to_string(),
    )
    .unwrap();
    let ending = said(&obid, json!({"said": "COPY", "new": true}));
    assert!(
        words(&ending).ends_with(
            "\n(Oby's plan loop answered: The Mac's Codex login for Codex stub needs refreshing: run codex once.)"
        ),
        "{}",
        ending.text
    );
    assert_eq!(turns(&obid).len(), 1);
}

/// Work planned after Codex searched the web waits for the owner's Start, as on Claude Code.
#[test]
fn work_codex_plans_after_the_web_waits_for_the_owners_start() {
    let (_folder, obid) = obid("codex-conv-web", true);
    let answer = said(
        &obid,
        json!({"said": r#"WEB OBY oby_dispatch {"repo": "obi-e2e/fixture-app", "task": "Add a greeting", "kind": "build"}"#,
               "new": true}),
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
    assert_eq!(
        inbox(&obid).iter().filter(|i| i["kind"] == "start").count(),
        1
    );
}

/// Later turns resume the conversation's own thread, also after obid restarts.
#[test]
fn a_codex_conversation_resumes_its_thread() {
    let (folder, obid) = obid("codex-conv-resume", true);
    let first = said(&obid, json!({"said": "HELLO", "new": true}));
    let conversation = first.body["conversation"].as_str().unwrap().to_owned();
    let session = obid
        .home
        .join(format!("conversations/{conversation}/session.json"));
    let kept: Value = serde_json::from_slice(&std::fs::read(&session).unwrap()).unwrap();
    let id = kept["session"].as_str().unwrap().to_owned();
    assert_eq!(kept["account"], "cstub");
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
    let other = said(&restarted, json!({"said": "REMEMBER", "new": true}));
    assert_eq!(other.body["text"], "resume=none", "{}", other.text);
}

/// Codex gets the same Oby tools: oby_dispatch, approved by obid's rule, starts a job whose card
/// is on the turn.
#[test]
fn oby_dispatch_through_codex_starts_a_job() {
    let (_folder, obid) = obid("codex-conv-dispatch", true);
    let events = follow_events(&obid);
    let tools = said(&obid, json!({"said": "TOOLS", "new": true}));
    let conversation = tools.body["conversation"].as_str().unwrap().to_owned();
    assert_eq!(
        tools.body["text"],
        "tools: oby_jobs,oby_job,oby_dispatch,oby_tell_job,oby_stop_job,oby_continue_job,oby_archive_job,oby_delete_job,oby_change_job,oby_tasks,oby_inbox,oby_answer,oby_conversations,oby_artifact,oby_read,oby_search,oby_list",
        "{}",
        tools.text
    );
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
    let seen = until_oby_turn(&events, 30);
    let (_, turn) = seen.last().unwrap();
    assert_eq!(turn["jobs"], json!([id]));
    let dispatch: Vec<&Value> = seen
        .iter()
        .filter(|(n, d)| n == "step" && d["tool"] == "oby_dispatch")
        .map(|(_, d)| d)
        .collect();
    assert_eq!(dispatch.len(), 2, "{seen:?}");
    assert_eq!(dispatch[0]["detail"], "obi-e2e/fixture-app");
    assert_eq!(dispatch[1]["state"], "done");

    // #660's oby_artifact is Codex's too: a folder of the room becomes this conversation's artifact.
    let page = said(
        &obid,
        json!({"said": r#"MAKEPAGE OBY oby_artifact {"title": "Functions", "path": "page"}"#,
               "conversation": conversation}),
    );
    let text = page.body["text"].as_str().unwrap();
    assert!(
        text.starts_with("oby: Published artifact ") && text.ends_with(", version 1."),
        "{}",
        page.text
    );
    let listed = call(
        &obid,
        "GET",
        &format!("/v1/artifacts?conversation={conversation}"),
        None,
    );
    assert_eq!(
        listed.body.as_array().map_or(0, Vec::len),
        1,
        "{}",
        listed.text
    );

    // An approval for a tool that wasn't called is declined.
    let misnamed = said(
        &obid,
        json!({"said": "MISNAMED", "conversation": conversation}),
    );
    assert_eq!(
        misnamed.body["text"], "misnamed: declined (decline)",
        "{}",
        misnamed.text
    );
}

/// Codex reads through Oby's tools (its shell is off): oby_read of a repository's checkout gives
/// its lines, fenced as data, shows as a `read` step naming the file, and taints the turn, as
/// Claude Code's Read does; a path out of the room (its CODEX_HOME's login copy) is refused and
/// taints nothing.
#[test]
fn codex_reads_the_room_through_oby_read() {
    let (_folder, obid) = obid("codex-conv-read", true);
    let events = follow_events(&obid);
    let answer = said(
        &obid,
        json!({"said": r#"OBY oby_read {"path": "repos/obi-e2e/fixture-app/README.md"}"#, "new": true}),
    );
    let conversation = answer.body["conversation"].as_str().unwrap().to_owned();
    let text = answer.body["text"].as_str().unwrap();
    assert!(
        text.starts_with("oby: Everything between a line <<<quoted-"),
        "{}",
        answer.text
    );
    assert!(text.contains("     1\t# Fixture app\n"), "{}", answer.text);
    let seen = until_oby_turn(&events, 30);
    let read: Vec<&Value> = seen
        .iter()
        .filter(|(n, d)| n == "step" && d["tool"] == "read")
        .map(|(_, d)| d)
        .collect();
    assert_eq!(read.len(), 2, "{seen:?}");
    assert_eq!(read[0]["detail"], "repos/obi-e2e/fixture-app/README.md");
    assert_eq!(read[0]["text"], "Reading README.md");
    assert_eq!(read[1]["state"], "done");
    let kept = |conversation: &str| -> Value {
        serde_json::from_slice(
            &std::fs::read(
                obid.home
                    .join(format!("conversations/{conversation}/session.json")),
            )
            .unwrap(),
        )
        .unwrap()
    };
    assert_eq!(
        kept(&conversation)["web"],
        true,
        "reading repos/ taints the turn"
    );

    let prying = said(
        &obid,
        json!({"said": r#"OBY oby_read {"path": "../config/auth.json"}"#, "new": true}),
    );
    // The refusal names the agent's own path, so it comes quoted too.
    let refused = prying.body["text"].as_str().unwrap();
    assert!(
        refused.starts_with("oby: refused: Everything between a line <<<quoted-")
            && refused.contains(
                "\n../config/auth.json isn't a path in your room: name one relative to it, with no .. and no ~.\nquoted-"
            ),
        "{}",
        prying.text
    );
    let other = prying.body["conversation"].as_str().unwrap();
    assert_eq!(kept(other)["web"], false);
}

/// Codex's approvals are answered by the conversation's own rule: no command at all, not even one
/// in the room (F1); a write inside the room yes, outside and in repos/ no; never the owner's to
/// answer.
#[test]
fn codex_approvals_follow_the_conversation_rule() {
    let (_folder, obid) = obid("codex-conv-perms", true);
    let perms = said(&obid, json!({"said": "PERMS", "new": true}));
    assert_eq!(
        perms.body["text"],
        "perms: inside=decline write=accept outside=decline repos=decline secret=decline",
        "{}",
        perms.text
    );
    assert_eq!(
        inbox(&obid),
        Vec::<Value>::new(),
        "the owner is never asked mid-turn"
    );
}

/// With no Codex account signed in, or a thread that fails twice, the plan loop answers, and says
/// so in one line.
#[test]
fn the_plan_loop_answers_when_codex_cant_run() {
    let (_folder, obid) = obid("codex-conv-fallback", false);
    // What the plan loop says depends on whether its brain can run (with no usable login it's
    // keyword rules, #651); its answer, a reply or a question, ends with the line saying why.
    let answer = said(&obid, json!({"said": "HELLO", "new": true}));
    assert!(
        words(&answer).ends_with(
            "\n(Oby's plan loop answered: no Codex account is signed in for conversations.)"
        ),
        "{}",
        answer.text
    );
    assert!(turns(&obid).is_empty());

    std::fs::write(obid.home.join("accounts/codex/auth.json"), "{}").unwrap();
    let failed = said(&obid, json!({"said": "FAIL", "new": true}));
    assert!(
        words(&failed).ends_with("\n(Oby's plan loop answered: its agent session failed twice.)"),
        "{}",
        failed.text
    );
    assert_eq!(turns(&obid).len(), 2);
}
