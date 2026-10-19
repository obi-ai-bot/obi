//! The conversation's shell (docs/runner-api.md, "obid only: the conversation's shell"): Oby's
//! `oby_shell` runs each command in a box of its own (the room, no login, no network), asks the
//! owner about installs and the network even on Bypass, and about writes after the taint, and
//! ends every command with its turn. The agent is the stand-in (tests/agents/fake-harness).
mod support;

use std::path::{Path, PathBuf};
use std::thread::scope;
use std::time::Duration;

use serde_json::{Value, json};
use support::*;

fn obid(name: &str) -> (Folder, Obid) {
    let folder = Folder::new(name);
    let remote = fixture(&folder.0.join("fixture"));
    let harness = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-harness");
    let mut config = config(&folder.0, &remote, &harness);
    config["conversation"] = json!({"agent": "claude"});
    let account = folder.0.join("home/accounts/stub");
    std::fs::create_dir_all(&account).unwrap();
    std::fs::write(account.join(".credentials.json"), "{}").unwrap();
    let obid = start(&folder.0, &config, None);
    (folder, obid)
}

/// One turn calling `oby_shell` with `args` in `conversation` (a new one when none): Oby's text
/// and the conversation.
fn shell(obid: &Obid, conversation: Option<&str>, args: Value) -> (String, String) {
    let mut body = json!({"said": format!("OBY oby_shell {args}")});
    match conversation {
        Some(id) => body["conversation"] = json!(id),
        None => body["new"] = json!(true),
    }
    let answer = call(obid, "POST", "/v1/plans", Some(&body));
    assert_eq!(answer.status, 200, "{}", answer.text);
    (
        answer.body["text"].as_str().unwrap_or_default().to_owned(),
        answer.body["conversation"].as_str().unwrap().to_owned(),
    )
}

/// The open shell item of `conversation`, once it's there.
fn waiting_item(obid: &Obid, conversation: &str) -> Value {
    within(30, "the shell's ask in the inbox", || {
        call(obid, "GET", "/v1/inbox", None)
            .body
            .as_array()?
            .iter()
            .find(|i| {
                i["kind"] == "permission"
                    && i["conversation"] == conversation
                    && i["done"].is_null()
            })
            .cloned()
    })
}

fn answer(obid: &Obid, item: &Value, words: &str) -> Answer {
    call(
        obid,
        "POST",
        &format!("/v1/inbox/{}/answer", item["id"].as_str().unwrap()),
        Some(&json!({"answer": words})),
    )
}

/// A read runs at once, in the room, and shows as a `bash` step with what it wrote.
#[test]
fn a_read_only_command_runs_in_the_room() {
    let (_folder, obid) = obid("shell-read");
    let events = follow_events(&obid);
    let (text, _) = shell(
        &obid,
        None,
        json!({"command": "ls repos/obi-e2e/fixture-app && pwd"}),
    );
    assert!(text.contains("Exit status 0."), "{text}");
    assert!(text.contains("package.json"), "{text}");
    assert!(text.contains("/room"), "{text}");
    let steps = events_named(&events, "step", 10, |got| {
        got.iter()
            .any(|s| s["tool"] == "bash" && s["state"] != "running")
    });
    let done = steps
        .iter()
        .find(|s| s["tool"] == "bash" && s["state"] == "done")
        .unwrap_or_else(|| panic!("a bash step: {steps:?}"));
    assert_eq!(
        done["detail"], "ls repos/obi-e2e/fixture-app && pwd",
        "{done}"
    );
    assert!(
        done["output"].as_str().unwrap().contains("package.json"),
        "{done}"
    );
    assert!(
        call(&obid, "GET", "/v1/inbox", None)
            .body
            .as_array()
            .unwrap()
            .is_empty()
    );
}

/// The box has no login, no token and no network, and doesn't see the session's login copy: even
/// once the owner allowed a command that names it.
#[test]
fn the_box_has_no_login_and_no_network() {
    let (_folder, obid) = obid("shell-box");
    let command = "env; cat $(echo ../config/.credentials.json) || echo NO-LOGIN; ls ~/.ssh || echo NO-HOME; curl -sS -m 5 http://example.com >/dev/null || echo NO-NETWORK";
    scope(|turns| {
        let waiting = turns.spawn(|| shell(&obid, None, json!({"command": command})));
        let first = within(30, "the conversation", || {
            call(&obid, "GET", "/v1/conversations", None)
                .body
                .as_array()?
                .first()
                .cloned()
        });
        let conversation = first["id"].as_str().unwrap().to_owned();
        let item = waiting_item(&obid, &conversation);
        // Secrets: allowed once at a time, no rule to save.
        assert_eq!(item["options"], json!(["Allow", "Deny"]), "{item}");
        assert_eq!(item["job"], "", "{item}");
        assert!(item["text"].as_str().unwrap().contains("secrets"), "{item}");
        assert_eq!(answer(&obid, &item, "Allow").status, 200);
        let (text, _) = waiting.join().unwrap();
        for gone in [
            "GH_TOKEN",
            "GITHUB_TOKEN",
            "OBY_MCP_TOKEN",
            "CLAUDE_CONFIG_DIR",
            "CODEX_HOME",
            "ANTHROPIC",
            "OBY_API",
        ] {
            assert!(!text.contains(gone), "{gone} in {text}");
        }
        assert!(text.contains("GH_CONFIG_DIR="), "{text}");
        assert!(text.contains("NO-LOGIN"), "{text}");
        assert!(text.contains("NO-NETWORK"), "{text}");
        let done = call(&obid, "GET", "/v1/inbox", None);
        assert!(
            done.body
                .as_array()
                .unwrap()
                .iter()
                .all(|i| !i["done"].is_null()),
            "{}",
            done.text
        );
    });
}

/// An install asks even on Bypass, with only Allow and Deny; only the owner answers it, and a no
/// keeps it from running.
#[test]
fn an_install_asks_even_on_bypass() {
    let (_folder, obid) = obid("shell-install");
    let set = call(
        &obid,
        "PUT",
        "/v1/settings/permissions",
        Some(&json!({"mode": "bypass"})),
    );
    assert_eq!(set.status, 200, "{}", set.text);
    scope(|turns| {
        let waiting = turns.spawn(|| shell(&obid, None, json!({"command": "brew install gh"})));
        let first = within(30, "the conversation", || {
            call(&obid, "GET", "/v1/conversations", None)
                .body
                .as_array()?
                .first()
                .cloned()
        });
        let conversation = first["id"].as_str().unwrap().to_owned();
        let item = waiting_item(&obid, &conversation);
        assert_eq!(item["options"], json!(["Allow", "Deny"]), "{item}");
        assert!(
            item["text"].as_str().unwrap().contains("installs software"),
            "{item}"
        );
        // No rule saves an install.
        assert_eq!(answer(&obid, &item, "Always allow").status, 422);
        assert_eq!(answer(&obid, &item, "Deny").status, 200);
        let (text, _) = waiting.join().unwrap();
        assert!(text.contains("refused: The owner said no."), "{text}");
        // Answered once: a second answer finds it done.
        assert_eq!(answer(&obid, &item, "Allow").status, 409);
    });
}

/// The first write in Sandbox mode runs; it taints the conversation, so the next write asks;
/// "Always allow" saves a rule for conversations, which lets the next one through.
#[test]
fn writes_ask_after_the_taint_and_always_saves_a_rule() {
    let (_folder, obid) = obid("shell-taint");
    let (text, conversation) = shell(&obid, None, json!({"command": "mkdir out"}));
    assert!(text.contains("Exit status 0."), "{text}");
    scope(|turns| {
        let waiting = turns.spawn(|| {
            shell(
                &obid,
                Some(&conversation),
                json!({"command": "touch out/x"}),
            )
        });
        let item = waiting_item(&obid, &conversation);
        assert_eq!(
            item["options"],
            json!(["Allow", "Always allow", "Deny"]),
            "{item}"
        );
        assert!(
            item["text"].as_str().unwrap().contains("untrusted"),
            "{item}"
        );
        assert_eq!(answer(&obid, &item, "Always allow").status, 200);
        let (text, _) = waiting.join().unwrap();
        assert!(text.contains("Exit status 0."), "{text}");
    });
    let room = obid.home.join(format!("conversations/{conversation}/room"));
    assert!(room.join("out/x").is_file());
    let rules = call(&obid, "GET", "/v1/permissions/rules", None);
    assert!(
        rules.text.contains("Bash(touch:*)") && rules.text.contains("conversations"),
        "{}",
        rules.text
    );
    let (text, _) = shell(
        &obid,
        Some(&conversation),
        json!({"command": "touch out/y"}),
    );
    assert!(text.contains("Exit status 0."), "{text}");
    assert!(room.join("out/y").is_file());
}

/// Whether a process with `marker` in its command line runs.
fn running(marker: &str) -> bool {
    std::process::Command::new("pgrep")
        .args(["-f", marker])
        .output()
        .is_ok_and(|o| o.status.success())
}

/// A command past its timeout goes on in the background, and ends with the turn: nothing a
/// conversation started outlives it.
#[test]
fn a_long_command_goes_to_the_background_and_ends_with_the_turn() {
    let (_folder, obid) = obid("shell-long");
    let marker = format!("sleep 4{}.5", std::process::id() % 10);
    let (text, conversation) = shell(
        &obid,
        None,
        json!({"command": format!("echo started; {marker}"), "timeout": 5000}),
    );
    assert!(text.contains("Still running after 5 s"), "{text}");
    assert!(text.contains("in the background as cmd-"), "{text}");
    assert!(text.contains("started"), "{text}");
    within(15, "the command ends with its turn", || {
        (!running(&marker)).then_some(())
    });
    let shell = obid
        .home
        .join(format!("conversations/{conversation}/shell"));
    within(15, "its output goes with the turn", || {
        let left: Vec<PathBuf> = std::fs::read_dir(&shell)
            .map(|d| d.flatten().map(|e| e.path()).collect())
            .unwrap_or_default();
        left.is_empty().then_some(())
    });
    std::thread::sleep(Duration::from_millis(200));
}

/// A command sees only its own conversation's room: another's is hidden, even read by a script
/// the rules can't follow (#774's review, 10).
#[test]
fn a_command_never_reads_another_conversations_room() {
    let (_folder, obid) = obid("shell-rooms");
    let (text, other) = shell(
        &obid,
        None,
        json!({"command": "echo OTHER-ROOM-SECRET > mine.txt"}),
    );
    assert!(text.contains("Exit status 0."), "{text}");
    let (text, _) = shell(
        &obid,
        None,
        json!({"command": format!(
            "printf 'cat ../../%s/room/mine.txt\\n' {other} > peek.sh; sh peek.sh || echo NO-OTHER-ROOM"
        )}),
    );
    assert!(text.contains("NO-OTHER-ROOM"), "{text}");
    assert!(!text.contains("OTHER-ROOM-SECRET"), "{text}");
}

/// A command the owner let reach the network still never reaches this machine's loopback, where
/// obid's API and its MCP endpoints listen (#774's review, 4 and 10).
#[test]
fn an_allowed_network_command_never_reaches_obid() {
    let (_folder, obid) = obid("shell-loopback");
    let command = format!(
        "curl -sS -m 5 -o /dev/null http://127.0.0.1:{}/v1/status && echo REACHED-OBID || echo NO-LOOPBACK",
        obid.port
    );
    scope(|turns| {
        let waiting = turns.spawn(|| shell(&obid, None, json!({"command": command})));
        let first = within(30, "the conversation", || {
            call(&obid, "GET", "/v1/conversations", None)
                .body
                .as_array()?
                .first()
                .cloned()
        });
        let item = waiting_item(&obid, first["id"].as_str().unwrap());
        assert!(item["text"].as_str().unwrap().contains("network"), "{item}");
        assert_eq!(answer(&obid, &item, "Allow").status, 200);
        let (text, _) = waiting.join().unwrap();
        assert!(text.contains("NO-LOOPBACK"), "{text}");
        assert!(!text.contains("REACHED-OBID"), "{text}");
    });
}
