//! The accounts API (docs/runner-api.md, "POST /v1/accounts" to "GET /v1/accounts/{id}/sign-in"),
//! on the real obid binary: accounts are added, renamed and removed, kept across restarts, each
//! with a folder obid makes and removes; bad input is refused; and each tool's own login runs in
//! the account's folder (the stand-in agents' fake-login.mjs), obid passing on only the link to
//! open and the code to type, never what the login printed, and keeping jobs off the account while
//! it signs in or is removed.

mod support;

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use support::*;

/// What the stand-in logins print and must never come back (tests/agents/fake-login.mjs).
const SECRET: &str = "FAKE-LOGIN-SECRET-7f3a9c";

fn agent(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("tests/agents/{name}"))
}

/// The tests' configuration with the three stand-in agents; on macOS `claudeKeychain` is on, as
/// signing a Claude Code account in there needs it (its login goes to the Keychain). obid then asks
/// the stand-in `security` (support::start), never the person's real Keychain.
fn accounts_config(folder: &Path) -> Value {
    let remote = folder.join("remote.git");
    let mut config = config(folder, &remote, &agent("fake-claude"));
    config["agents"]["codex"] = json!({"bin": agent("fake-codex"), "accounts": []});
    config["agents"]["cursor"] = json!({"bin": agent("fake-cursor"), "accounts": []});
    if cfg!(target_os = "macos") {
        config["claudeKeychain"] = json!(true);
    }
    config
}

fn accounts(obid: &Obid) -> Vec<Value> {
    call(obid, "GET", "/v1/status", None).body["accounts"]
        .as_array()
        .unwrap()
        .clone()
}

fn account(obid: &Obid, id: &str) -> Option<Value> {
    accounts(obid).into_iter().find(|a| a["id"] == id)
}

fn add(obid: &Obid, body: Value) -> Answer {
    call(obid, "POST", "/v1/accounts", Some(&body))
}

fn mode(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

fn alive(pid: i32) -> bool {
    nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).is_ok()
}

#[test]
fn accounts_are_added_renamed_and_removed_and_kept_across_restarts() {
    let folder = Folder::new("accounts-crud");
    let config = accounts_config(&folder.0);
    let mut obid = start(&folder.0, &config, None);
    let events = follow_events(&obid);

    let added = add(
        &obid,
        json!({"agent": "codex", "name": "Personal", "payer": "Wellington"}),
    );
    assert_eq!(added.status, 201, "{}", added.text);
    let id = added.body["id"].as_str().unwrap().to_owned();
    assert_eq!(added.body["agent"], "codex");
    assert_eq!(added.body["name"], "Personal");
    assert_eq!(added.body["payer"], "Wellington");
    assert_eq!(added.body["signedIn"], false);
    // Its folder is obid's own, made private.
    let dir = obid.home.join("accounts").join(&id);
    assert!(dir.is_dir(), "{} wasn't made", dir.display());
    assert_eq!(mode(&dir), 0o700);
    let sent = events_named(&events, "accounts", 10, |got| {
        got.iter()
            .any(|list| list.as_array().unwrap().iter().any(|a| a["id"] == id))
    });
    assert!(sent.last().unwrap().is_array());
    assert_eq!(account(&obid, &id).unwrap()["payer"], "Wellington");

    // Renamed; the payer cleared.
    let renamed = call(
        &obid,
        "PATCH",
        &format!("/v1/accounts/{id}"),
        Some(&json!({"name": "Deskree", "payer": null})),
    );
    assert_eq!(renamed.status, 200, "{}", renamed.text);
    assert_eq!(renamed.body["name"], "Deskree");
    assert_eq!(renamed.body["payer"], Value::Null);
    events_named(&events, "accounts", 10, |got| {
        got.iter().any(|list| {
            list.as_array()
                .unwrap()
                .iter()
                .any(|a| a["id"] == id && a["name"] == "Deskree")
        })
    });
    // The account from the configuration can be renamed and given a payer too.
    let stub = call(
        &obid,
        "PATCH",
        "/v1/accounts/stub",
        Some(&json!({"payer": "Deskree"})),
    );
    assert_eq!(stub.status, 200, "{}", stub.text);
    assert_eq!(stub.body["name"], "Stub");
    assert_eq!(stub.body["payer"], "Deskree");

    // A restart keeps all of it, from obid's own home/accounts.json (0600), and sweeps what a
    // sign-in cut short left in home/tmp.
    assert!(obid.stop().success());
    assert_eq!(mode(&obid.home.join("accounts.json")), 0o600);
    let stale = obid.home.join("tmp/sign-in-1-0");
    std::fs::create_dir_all(&stale).unwrap();
    let mut obid = start(&folder.0, &config, None);
    assert!(!stale.exists(), "a sign-in's folder outlived the restart");
    let kept = account(&obid, &id).expect("the account is still there");
    assert_eq!(
        (&kept["name"], &kept["agent"]),
        (&json!("Deskree"), &json!("codex"))
    );
    assert_eq!(account(&obid, "stub").unwrap()["payer"], "Deskree");

    // Removed: its folder (obid made it) goes with it, and its id is never made again.
    let events = follow_events(&obid);
    let removed = call(&obid, "DELETE", &format!("/v1/accounts/{id}"), None);
    assert_eq!(removed.status, 204, "{}", removed.text);
    let kept: Value =
        serde_json::from_slice(&std::fs::read(obid.home.join("accounts.json")).unwrap()).unwrap();
    assert!(
        kept["removed"].as_array().unwrap().contains(&json!(id)),
        "{kept}"
    );
    assert!(!dir.exists(), "obid's folder for the account stayed");
    assert!(account(&obid, &id).is_none());
    events_named(&events, "accounts", 10, |got| {
        got.iter()
            .any(|list| !list.as_array().unwrap().iter().any(|a| a["id"] == id))
    });
    // The configuration's account goes too, but its folder isn't obid's to remove.
    let stub_dir = obid.home.join("accounts/stub");
    assert!(stub_dir.is_dir());
    assert_eq!(call(&obid, "DELETE", "/v1/accounts/stub", None).status, 204);
    assert!(stub_dir.is_dir(), "obid removed a folder it didn't make");

    assert!(obid.stop().success());
    let obid = start(&folder.0, &config, None);
    assert!(account(&obid, &id).is_none(), "a removed account came back");
    assert!(
        account(&obid, "stub").is_none(),
        "a removed configured account came back"
    );
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/accounts/{id}"), None).status,
        404
    );
}

#[test]
fn bad_accounts_are_refused() {
    let folder = Folder::new("accounts-refused");
    let config = accounts_config(&folder.0);
    let obid = start(&folder.0, &config, None);
    let long = "x".repeat(61);
    for (body, why) in [
        (json!({"agent": "gemini", "name": "A"}), "agent"),
        (json!({"name": "A"}), "agent"),
        (json!({"agent": "claude", "name": "  "}), "name"),
        (json!({"agent": "claude", "name": long}), "name"),
        (json!({"agent": "claude", "name": "Two\nlines"}), "name"),
        (
            json!({"agent": "claude", "name": "A", "payer": "x\u{7}"}),
            "payer",
        ),
        (json!({"agent": "claude", "name": "Stub"}), "name"),
        (json!({"agent": "claude", "name": "stub"}), "name"),
        // obid makes every account's folder itself: none is named in the API.
        (
            json!({"agent": "claude", "name": "A", "configDir": folder.0.join("mine")}),
            "configDir",
        ),
        (json!({"agent": "claude", "name": "A", "extra": 1}), "extra"),
    ] {
        let answer = add(&obid, body.clone());
        assert_eq!(answer.status, 422, "{body} was taken: {}", answer.text);
        assert!(
            answer.body["error"].as_str().unwrap().contains(why),
            "{body}: {}",
            answer.text
        );
    }
    // Not JSON, unknown accounts, a rename to nothing.
    assert_eq!(
        call(
            &obid,
            "PATCH",
            "/v1/accounts/nobody",
            Some(&json!({"name": "A"}))
        )
        .status,
        404
    );
    assert_eq!(
        call(&obid, "DELETE", "/v1/accounts/nobody", None).status,
        404
    );
    assert_eq!(
        call(&obid, "GET", "/v1/accounts/nobody/sign-in", None).status,
        404
    );
    assert_eq!(
        call(
            &obid,
            "PATCH",
            "/v1/accounts/stub",
            Some(&json!({"name": ""}))
        )
        .status,
        422
    );
    assert_eq!(accounts(&obid).len(), 1, "{:?}", accounts(&obid));
    // At most 32 accounts, the configuration's among them.
    for n in 1..32 {
        let answer = add(&obid, json!({"agent": "cursor", "name": format!("C{n}")}));
        assert_eq!(answer.status, 201, "{n}: {}", answer.text);
    }
    let full = add(&obid, json!({"agent": "cursor", "name": "One too many"}));
    assert_eq!(full.status, 422, "{}", full.text);
    assert!(full.text.contains("at most 32"), "{}", full.text);
}

#[test]
fn an_account_with_a_job_isnt_removed() {
    let folder = Folder::new("accounts-busy");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &agent("fake-claude"));
    let obid = start(&folder.0, &config, None);
    let job = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "SLEEP", "account": "stub"}}),
        ),
    );
    assert_eq!(job.status, 201, "{}", job.text);
    let id = job.body["id"].as_str().unwrap().to_owned();
    let refused = call(&obid, "DELETE", "/v1/accounts/stub", None);
    assert_eq!(refused.status, 409, "{}", refused.text);
    let signing = call(&obid, "GET", "/v1/accounts/stub/sign-in", None);
    assert_eq!(signing.status, 409, "{}", signing.text);
    assert!(account(&obid, "stub").is_some());
    call(&obid, "POST", &format!("/v1/jobs/{id}/stop"), None);
    within(10, "the job stopped", || {
        (call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body["status"] == "stopped")
            .then_some(())
    });
    assert_eq!(call(&obid, "DELETE", "/v1/accounts/stub", None).status, 204);
}

/// Claude Code's own login, in the account's folder: obid gives the link it printed, the code goes
/// back on its stdin, and the login is written where Claude Code keeps it, by Claude Code. While
/// it waits, no job goes to the account; removing the account ends it.
#[test]
fn claude_code_signs_in_with_its_own_login() {
    let folder = Folder::new("accounts-claude");
    let config = accounts_config(&folder.0);
    let obid = start(&folder.0, &config, None);
    let added = add(&obid, json!({"agent": "claude", "name": "Personal"}));
    assert_eq!(added.status, 201, "{}", added.text);
    let id = added.body["id"].as_str().unwrap().to_owned();
    let dir = obid.home.join("accounts").join(&id);
    let target = format!("/v1/accounts/{id}/sign-in");

    // No sign-in under way: there's nothing to take a code.
    assert_eq!(
        call(
            &obid,
            "POST",
            &target,
            Some(&json!({"code": "good-code#fake"}))
        )
        .status,
        409
    );
    let started = call(&obid, "GET", &target, None);
    assert_eq!(started.status, 200, "{}", started.text);
    assert_eq!(
        started.body["url"],
        "https://claude.com/cai/oauth/authorize?code=true&state=fake"
    );
    assert_eq!(started.body["pasteCode"], true);
    assert_eq!(started.body["userCode"], Value::Null);
    assert_eq!(started.body["account"], id.as_str());
    assert!(started.body["expiresAt"].is_string());
    // Asked again, the same sign-in.
    let again = call(&obid, "GET", &target, None);
    assert_eq!(again.body["url"], started.body["url"]);
    // While it waits, a job named to the account isn't dispatched.
    let job = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Hi", "account": id}}),
        ),
    );
    assert_ne!(job.status, 201, "{}", job.text);
    assert!(job.text.contains("being signed in"), "{}", job.text);

    // A wrong code ends it: Claude Code said no.
    let wrong = call(&obid, "POST", &target, Some(&json!({"code": "bad#fake"})));
    assert_eq!(wrong.status, 422, "{}", wrong.text);
    assert_eq!(account(&obid, &id).unwrap()["signedIn"], false);
    // A code that isn't one line is refused before it reaches the login.
    call(&obid, "GET", &target, None);
    let two_lines = call(
        &obid,
        "POST",
        &target,
        Some(&json!({"code": "a\ngood-code#fake"})),
    );
    assert_eq!(two_lines.status, 422, "{}", two_lines.text);

    let events = follow_events(&obid);
    let signed = call(
        &obid,
        "POST",
        &target,
        Some(&json!({"code": "good-code#fake"})),
    );
    assert_eq!(signed.status, 200, "{}", signed.text);
    assert_eq!(signed.body["id"], id.as_str());
    assert_eq!(signed.body["signedIn"], true);
    events_named(&events, "accounts", 10, |got| {
        got.iter().any(|list| {
            list.as_array()
                .unwrap()
                .iter()
                .any(|a| a["id"] == id && a["signedIn"] == true)
        })
    });
    // On macOS obid looked in the Keychain through the stand-in, never the real one.
    if cfg!(target_os = "macos") {
        let asked = std::fs::read_to_string(folder.0.join("tmp/obid-test-security-calls"))
            .expect("the stand-in security was asked");
        assert!(asked.contains("find-generic-password"), "{asked}");
    }

    // Claude Code ran in the account's folder, by its absolute path, with the system's folders,
    // its own and (a `#!/usr/bin/env node` script) node's on its PATH, and wrote its login there
    // itself.
    let saw: Value =
        serde_json::from_slice(&std::fs::read(dir.join(".credentials.json")).unwrap()).unwrap();
    let saw = &saw["saw"];
    assert_eq!(saw["argv"], json!(["auth", "login"]));
    assert_eq!(saw["env"]["CLAUDE_CONFIG_DIR"], json!(dir));
    assert!(
        saw["env"].get("CLAUDE_SECURESTORAGE_CONFIG_DIR").is_none(),
        "{saw}"
    );
    assert_eq!(saw["env"]["HOME"], json!(folder.0.join("env-home")));
    assert_eq!(saw["env"]["BROWSER"], "true");
    let agents = agent("fake-claude").canonicalize().unwrap();
    let node = std::process::Command::new("sh")
        .args(["-c", "command -v node"])
        .output()
        .unwrap();
    let node = PathBuf::from(String::from_utf8(node.stdout).unwrap().trim());
    assert_eq!(
        saw["env"]["PATH"],
        json!(format!(
            "/usr/bin:/bin:/usr/sbin:/sbin:{}:{}",
            agents.parent().unwrap().display(),
            node.parent().unwrap().display()
        ))
    );
    // What it started ended with it.
    let pids = std::fs::read_to_string(dir.join("login-pids")).unwrap();
    for pid in pids.split_whitespace() {
        let pid: i32 = pid.parse().unwrap();
        within(5, "the login's processes ended", || {
            (!alive(pid)).then_some(())
        });
    }

    // Nothing the login printed, nor the code, came back or reached obid's log.
    for text in [&started.text, &wrong.text, &signed.text, &obid.log()] {
        assert!(!text.contains(SECRET), "the login's output leaked: {text}");
        assert!(!text.contains("good-code"), "the code leaked: {text}");
        assert!(!text.contains("Request failed"), "{text}");
    }

    // Removing the account ends a sign-in under way.
    let again = call(&obid, "GET", &target, None);
    assert_eq!(again.status, 200, "{}", again.text);
    let removed = call(&obid, "DELETE", &format!("/v1/accounts/{id}"), None);
    assert_eq!(removed.status, 204, "{}", removed.text);
    assert_eq!(call(&obid, "GET", &target, None).status, 404);
}

/// A sign-in the person walked away from can be ended (`DELETE …/sign-in`): the account takes jobs
/// again at once, not after 15 minutes.
#[test]
fn an_abandoned_sign_in_can_be_ended() {
    let folder = Folder::new("accounts-abandon");
    let config = accounts_config(&folder.0);
    let obid = start(&folder.0, &config, None);
    let added = add(&obid, json!({"agent": "claude", "name": "Personal"}));
    let id = added.body["id"].as_str().unwrap().to_owned();
    let target = format!("/v1/accounts/{id}/sign-in");
    assert_eq!(call(&obid, "GET", &target, None).status, 200);
    let pids = obid.home.join("accounts").join(&id).join("login-pids");
    let pids = within(5, "the login said its pids", || {
        std::fs::read_to_string(&pids).ok()
    });
    let ended = call(&obid, "DELETE", &target, None);
    assert_eq!(ended.status, 204, "{}", ended.text);
    for pid in pids.split_whitespace() {
        let pid: i32 = pid.parse().unwrap();
        within(5, "the login ended", || (!alive(pid)).then_some(()));
    }
    // Nothing under way: ending it again is fine, and the code has nowhere to go.
    assert_eq!(call(&obid, "DELETE", &target, None).status, 204);
    assert_eq!(
        call(
            &obid,
            "POST",
            &target,
            Some(&json!({"code": "good-code#fake"}))
        )
        .status,
        409
    );
    assert_eq!(
        call(&obid, "DELETE", "/v1/accounts/nobody/sign-in", None).status,
        404
    );
    // A new one starts.
    assert_eq!(call(&obid, "GET", &target, None).status, 200);
}

/// A login file (or its lock) that is a link, or not the person's, in an account's folder is never
/// signed in through: the tool's login would write the new sign-in wherever the link leads.
#[test]
fn a_login_file_that_is_a_link_is_never_signed_in_through() {
    let folder = Folder::new("accounts-link");
    let config = accounts_config(&folder.0);
    let obid = start(&folder.0, &config, None);
    let added = add(&obid, json!({"agent": "codex", "name": "Work"}));
    let id = added.body["id"].as_str().unwrap().to_owned();
    let dir = obid.home.join("accounts").join(&id);
    std::fs::write(folder.0.join("elsewhere.json"), "{}").unwrap();
    std::os::unix::fs::symlink(folder.0.join("elsewhere.json"), dir.join("auth.json")).unwrap();
    let refused = call(&obid, "GET", &format!("/v1/accounts/{id}/sign-in"), None);
    assert_eq!(refused.status, 409, "{}", refused.text);
    assert!(refused.text.contains("auth.json"), "{}", refused.text);
    assert_eq!(
        std::fs::read_to_string(folder.0.join("elsewhere.json")).unwrap(),
        "{}"
    );
}

/// obid stopping ends a sign-in's login with everything it started.
#[test]
fn a_sign_in_ends_with_obid() {
    let folder = Folder::new("accounts-stop");
    let config = accounts_config(&folder.0);
    let mut obid = start(&folder.0, &config, None);
    let added = add(&obid, json!({"agent": "claude", "name": "Personal"}));
    let id = added.body["id"].as_str().unwrap().to_owned();
    let started = call(&obid, "GET", &format!("/v1/accounts/{id}/sign-in"), None);
    assert_eq!(started.status, 200, "{}", started.text);
    let pids = obid.home.join("accounts").join(&id).join("login-pids");
    let pids = within(5, "the login said its pids", || {
        std::fs::read_to_string(&pids).ok()
    });
    assert!(obid.stop().success());
    for pid in pids.split_whitespace() {
        let pid: i32 = pid.parse().unwrap();
        within(5, "the login's processes ended with obid", || {
            (!alive(pid)).then_some(())
        });
    }
}

/// Codex's device login and Cursor's, in the account's folder: obid gives the link (and Codex's
/// one-time code); each ends by itself once the person signed in in their browser.
#[test]
fn codex_and_cursor_sign_in_with_their_own_logins() {
    let folder = Folder::new("accounts-codex");
    let config = accounts_config(&folder.0);
    let obid = start(&folder.0, &config, None);
    let events = follow_events(&obid);

    let codex = add(&obid, json!({"agent": "codex", "name": "Work"}));
    let codex_id = codex.body["id"].as_str().unwrap().to_owned();
    let dir = obid.home.join("accounts").join(&codex_id);
    let started = call(
        &obid,
        "GET",
        &format!("/v1/accounts/{codex_id}/sign-in"),
        None,
    );
    assert_eq!(started.status, 200, "{}", started.text);
    assert_eq!(started.body["url"], "https://auth.openai.com/codex/device");
    assert_eq!(started.body["userCode"], "ABCD-EFGHI");
    assert_eq!(started.body["pasteCode"], false);
    // Codex takes no code back.
    let pasted = call(
        &obid,
        "POST",
        &format!("/v1/accounts/{codex_id}/sign-in"),
        Some(&json!({"code": "ABCD-EFGHI"})),
    );
    assert_eq!(pasted.status, 409, "{}", pasted.text);
    events_named(&events, "accounts", 15, |got| {
        got.iter().any(|list| {
            list.as_array()
                .unwrap()
                .iter()
                .any(|a| a["id"] == codex_id && a["signedIn"] == true)
        })
    });
    // Codex wrote its login in the account's folder itself.
    let saw: Value =
        serde_json::from_slice(&std::fs::read(dir.join("auth.json")).unwrap()).unwrap();
    assert_eq!(saw["saw"]["env"]["CODEX_HOME"], json!(dir));
    assert_eq!(saw["saw"]["env"]["HOME"], json!(dir));

    let cursor = add(&obid, json!({"agent": "cursor", "name": "Cursor"}));
    let cursor_id = cursor.body["id"].as_str().unwrap().to_owned();
    let dir = obid.home.join("accounts").join(&cursor_id);
    let started_cursor = call(
        &obid,
        "GET",
        &format!("/v1/accounts/{cursor_id}/sign-in"),
        None,
    );
    assert_eq!(started_cursor.status, 200, "{}", started_cursor.text);
    assert_eq!(
        started_cursor.body["url"],
        "https://cursor.com/loginDeepControl?challenge=fake&mode=login"
    );
    assert_eq!(started_cursor.body["userCode"], Value::Null);
    assert_eq!(started_cursor.body["pasteCode"], false);
    let login = dir.join(if cfg!(target_os = "macos") {
        ".cursor/auth.json"
    } else {
        ".config/cursor/auth.json"
    });
    within(15, "Cursor's login was written", || {
        login.is_file().then_some(())
    });
    let saw: Value = serde_json::from_slice(&std::fs::read(&login).unwrap()).unwrap();
    let env = &saw["saw"]["env"];
    assert_eq!(env["CURSOR_CONFIG_DIR"], json!(dir));
    assert_eq!(env["HOME"], json!(dir));
    assert_eq!(env["AGENT_CLI_CREDENTIAL_STORE"], "file");
    // Its caches are in obid's own folder for the sign-in, never the account's.
    for cache in ["NODE_COMPILE_CACHE", "XDG_CACHE_HOME"] {
        let path = PathBuf::from(env[cache].as_str().unwrap());
        assert!(path.starts_with(obid.home.join("tmp")), "{cache}={path:?}");
    }

    std::thread::sleep(Duration::from_millis(200));
    for text in [&started.text, &started_cursor.text, &obid.log()] {
        assert!(!text.contains(SECRET), "the login's output leaked: {text}");
    }
}

/// The tool's own default login (no folder of its own) is the person's: obid never runs a login
/// over it.
#[test]
fn the_default_login_is_never_signed_in_by_obid() {
    let folder = Folder::new("accounts-default");
    let mut config = accounts_config(&folder.0);
    config["agents"]["claude"]["accounts"] =
        json!([{"id": "default", "name": "Default", "configDir": null}]);
    let obid = start(&folder.0, &config, None);
    let refused = call(&obid, "GET", "/v1/accounts/default/sign-in", None);
    assert_eq!(refused.status, 409, "{}", refused.text);
    assert!(
        refused.body["error"]
            .as_str()
            .unwrap()
            .contains("own login")
    );
}

/// Removing a tool's own login isn't for good: `{"agent", "default": true}` lists it again, as it
/// was. Only once removed, and never for Cursor, which has none outside an account.
#[test]
fn a_removed_default_login_comes_back() {
    let folder = Folder::new("accounts-restore");
    let obid = start(&folder.0, &accounts_config(&folder.0), None);
    let lab = add(&obid, json!({"agent": "codex", "name": "Lab"}));
    assert_eq!(lab.status, 201, "{}", lab.text);
    assert!(account(&obid, "codex").is_some(), "{:?}", accounts(&obid));
    let early = add(&obid, json!({"agent": "codex", "default": true}));
    assert_eq!(early.status, 409, "{}", early.text);
    assert_eq!(
        call(&obid, "DELETE", "/v1/accounts/codex", None).status,
        204
    );
    assert!(account(&obid, "codex").is_none());
    for bad in [
        json!({"agent": "codex", "default": false}),
        json!({"agent": "codex", "default": true, "name": "X"}),
    ] {
        assert_eq!(add(&obid, bad).status, 422);
    }
    assert_eq!(
        add(&obid, json!({"agent": "cursor", "default": true})).status,
        422
    );
    let back = add(&obid, json!({"agent": "codex", "default": true}));
    assert_eq!(back.status, 201, "{}", back.text);
    assert_eq!(back.body["id"], "codex");
    assert!(account(&obid, "codex").is_some(), "{:?}", accounts(&obid));
    assert!(account(&obid, lab.body["id"].as_str().unwrap()).is_some());
}

/// A `default` the configuration gives a folder of its own isn't the tool's own login: removed,
/// it stays removed.
#[test]
fn a_configured_default_with_a_folder_doesnt_come_back() {
    let folder = Folder::new("accounts-restore-folder");
    let mut config = accounts_config(&folder.0);
    let dir = folder.0.join("claude-default");
    std::fs::create_dir_all(&dir).unwrap();
    let stub = config["agents"]["claude"]["accounts"][0].clone();
    config["agents"]["claude"]["accounts"] =
        json!([{"id": "default", "name": "Default", "configDir": dir}, stub]);
    let obid = start(&folder.0, &config, None);
    assert_eq!(
        call(&obid, "DELETE", "/v1/accounts/default", None).status,
        204
    );
    let refused = add(&obid, json!({"agent": "claude", "default": true}));
    assert_eq!(refused.status, 409, "{}", refused.text);
    assert!(
        refused.text.contains("folder of its own"),
        "{}",
        refused.text
    );
    assert!(account(&obid, "default").is_none());
}

/// A fresh sign-in may be another kind of login: obid forgets how the account paid (`priced`, kept
/// with its usage), so its next Codex job asks again; its windows stay.
#[test]
fn a_new_sign_in_forgets_how_the_account_paid() {
    let folder = Folder::new("accounts-priced");
    let config = accounts_config(&folder.0);
    let mut obid = start(&folder.0, &config, None);
    let id = add(&obid, json!({"agent": "codex", "name": "Work"})).body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    obid.stop();
    let usage = folder.0.join("home/usage.json");
    std::fs::write(
        &usage,
        json!({&id: {"fiveHour": 0.3, "priced": "plan"}}).to_string(),
    )
    .unwrap();
    let obid = start(&folder.0, &config, None);
    assert_eq!(account(&obid, &id).unwrap()["fiveHour"], 0.3);
    let started = call(&obid, "GET", &format!("/v1/accounts/{id}/sign-in"), None);
    assert_eq!(started.status, 200, "{}", started.text);
    within(15, "the account signed in", || {
        (account(&obid, &id)?["signedIn"] == true).then_some(())
    });
    // signedIn can show before the sign-in's own end forgets `priced`: wait for the file.
    let kept = within(15, "the sign-in forgot how the account paid", || {
        let kept: Value = serde_json::from_slice(&std::fs::read(&usage).ok()?).ok()?;
        kept[&id]["priced"].is_null().then_some(kept)
    });
    assert_eq!(kept[&id]["fiveHour"], 0.3);
}
