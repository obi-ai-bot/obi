//! The accounts API (docs/runner-api.md, "POST /v1/accounts" to "GET /v1/accounts/{id}/sign-in"),
//! on the real obid binary: accounts are added, renamed and removed, kept across restarts, with a
//! folder obid makes and removes only when it made it; bad input is refused; and each tool's own
//! login runs for an account (the stand-in agents' fake-login.mjs), obid passing on only the link
//! to open and the code to type, never what the login printed.

mod support;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use support::*;

/// What the stand-in logins print and must never come back (tests/agents/fake-login.mjs).
const SECRET: &str = "FAKE-LOGIN-SECRET-7f3a9c";

fn agent(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("tests/agents/{name}"))
}

/// The tests' configuration with the three stand-in agents; on macOS `claudeKeychain` is on, as
/// signing a Claude Code account in there needs it (its login goes to the Keychain).
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

    // A restart keeps all of it, from obid's own home/accounts.json (0600).
    assert!(obid.stop().success());
    assert_eq!(mode(&obid.home.join("accounts.json")), 0o600);
    let mut obid = start(&folder.0, &config, None);
    let kept = account(&obid, &id).expect("the account is still there");
    assert_eq!(
        (&kept["name"], &kept["agent"]),
        (&json!("Deskree"), &json!("codex"))
    );
    assert_eq!(account(&obid, "stub").unwrap()["payer"], "Deskree");

    // Removed: its folder (obid made it) goes with it.
    let events = follow_events(&obid);
    let removed = call(&obid, "DELETE", &format!("/v1/accounts/{id}"), None);
    assert_eq!(removed.status, 204, "{}", removed.text);
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
    // A folder the owner named isn't removed either.
    let named = folder.0.join("mine/cursor-work");
    let mine = add(
        &obid,
        json!({"agent": "cursor", "name": "Work", "configDir": named}),
    );
    assert_eq!(mine.status, 201, "{}", mine.text);
    std::fs::create_dir_all(&named).unwrap();
    std::fs::write(named.join("keep"), "the owner's").unwrap();
    let mine_id = mine.body["id"].as_str().unwrap();
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/accounts/{mine_id}"), None).status,
        204
    );
    assert!(
        named.join("keep").is_file(),
        "obid removed the owner's folder"
    );

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
    let person = folder.0.join("env-home");
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
        (
            json!({"agent": "claude", "name": "A", "configDir": "relative/dir"}),
            "configDir",
        ),
        (
            json!({"agent": "claude", "name": "A", "configDir": person.join(".claude")}),
            "configDir",
        ),
        (
            json!({"agent": "claude", "name": "A", "configDir": person.join(".claude/work")}),
            "configDir",
        ),
        (
            json!({"agent": "codex", "name": "A", "configDir": person.join(".codex")}),
            "configDir",
        ),
        (
            json!({"agent": "cursor", "name": "A", "configDir": person}),
            "configDir",
        ),
        (
            json!({"agent": "claude", "name": "A", "configDir": folder.0}),
            "configDir",
        ),
        (
            json!({"agent": "claude", "name": "A", "configDir": obid.home.join("accounts/x")}),
            "configDir",
        ),
        (
            json!({"agent": "claude", "name": "A", "configDir": obid.home}),
            "configDir",
        ),
        (
            json!({"agent": "claude", "name": "A", "configDir": format!("{}/a/../../home/x", folder.0.display())}),
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
    // A link to the person's own ~/.claude is ~/.claude.
    std::fs::create_dir_all(person.join(".claude")).unwrap();
    std::os::unix::fs::symlink(person.join(".claude"), folder.0.join("sneaky")).unwrap();
    let answer = add(
        &obid,
        json!({"agent": "claude", "name": "A", "configDir": folder.0.join("sneaky/work")}),
    );
    assert_eq!(answer.status, 422, "{}", answer.text);
    // Two accounts never share a folder.
    let shared = folder.0.join("shared");
    assert_eq!(
        add(
            &obid,
            json!({"agent": "codex", "name": "One", "configDir": shared})
        )
        .status,
        201
    );
    assert_eq!(
        add(
            &obid,
            json!({"agent": "claude", "name": "Two", "configDir": shared})
        )
        .status,
        422
    );
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
    // The stub, the one added, and Codex's own login, which `accounts: []` stood for and which
    // stays beside what's added.
    let ids: Vec<Value> = accounts(&obid).iter().map(|a| a["id"].clone()).collect();
    assert_eq!(ids.len(), 3, "{ids:?}");
    assert_eq!(&ids[..2], &[json!("stub"), json!("codex")]);
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

/// Claude Code's own login: obid gives the link it printed, the code goes back on its stdin, and
/// its login lands in the account's place, never read from or through the account's folder.
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

    // The login is the account's, written privately; Claude Code ran in a folder of obid's own,
    // gone now, with the account's folder named only as where its login is kept (on macOS, the
    // Keychain item's name).
    let login = dir.join(".credentials.json");
    assert_eq!(mode(&login), 0o600);
    let saw: Value = serde_json::from_slice(&std::fs::read(&login).unwrap()).unwrap();
    let saw = &saw["saw"];
    assert_eq!(saw["argv"], json!(["auth", "login"]));
    let config_dir = saw["env"]["CLAUDE_CONFIG_DIR"].as_str().unwrap();
    assert!(
        !Path::new(config_dir).starts_with(&dir),
        "Claude Code read the account's folder: {config_dir}"
    );
    assert!(
        !Path::new(config_dir).exists(),
        "obid's sign-in folder stayed"
    );
    assert_eq!(saw["env"]["HOME"], json!(folder.0.join("env-home")));
    if cfg!(target_os = "macos") {
        assert_eq!(
            saw["env"]["CLAUDE_SECURESTORAGE_CONFIG_DIR"],
            json!(dir),
            "{saw}"
        );
    }
    assert_eq!(saw["env"]["BROWSER"], "true");

    // Nothing the login printed, nor the code, came back or reached obid's log.
    for text in [&started.text, &wrong.text, &signed.text, &obid.log()] {
        assert!(!text.contains(SECRET), "the login's output leaked: {text}");
        assert!(!text.contains("good-code"), "the code leaked: {text}");
        assert!(!text.contains("Request failed"), "{text}");
    }
}

/// Codex's device login and Cursor's: obid gives the link (and Codex's one-time code); each ends
/// by itself once the person signed in in their browser.
#[test]
fn codex_and_cursor_sign_in_with_their_own_logins() {
    let folder = Folder::new("accounts-codex");
    let config = accounts_config(&folder.0);
    let obid = start(&folder.0, &config, None);
    let events = follow_events(&obid);

    let codex = add(&obid, json!({"agent": "codex", "name": "Work"}));
    let codex_id = codex.body["id"].as_str().unwrap().to_owned();
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
    // Codex wrote its login in a folder of obid's, which obid copied into the account's.
    let login = obid.home.join("accounts").join(&codex_id).join("auth.json");
    assert_eq!(mode(&login), 0o600);
    let saw: Value = serde_json::from_slice(&std::fs::read(&login).unwrap()).unwrap();
    let codex_home = saw["saw"]["env"]["CODEX_HOME"].as_str().unwrap();
    assert!(!Path::new(codex_home).starts_with(obid.home.join("accounts")));
    assert!(
        !Path::new(codex_home).exists(),
        "obid's sign-in folder stayed"
    );

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
    let login = dir.join(".config/cursor/auth.json");
    within(15, "Cursor's login was written", || {
        login.is_file().then_some(())
    });
    let saw: Value = serde_json::from_slice(&std::fs::read(&login).unwrap()).unwrap();
    assert_eq!(saw["saw"]["env"]["CURSOR_CONFIG_DIR"], json!(dir));
    assert_eq!(saw["saw"]["env"]["HOME"], json!(dir));

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
