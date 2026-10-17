//! The owner's vault, on the real obid binary (#457; docs/runner-api.md, "No vault secret", and
//! "obid only: publishing the owner's work"): `obid vault` takes a value on stdin only and prints
//! names only; every answer and event has the vault's secrets taken out, and is `503` when the
//! vault can't be read; the publish gate refuses a vault secret in a file or a commit message, in
//! every encoded form, and sends nothing when the vault can't be read; and an ordinary publish
//! still goes out.
//!
//! The stand-in agent (`tests/agents/vault-claude`) knows [`value`] the way an agent might have a
//! secret from somewhere else; these tests put that value in obid's vault.

mod support;

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use base64::Engine as _;
use serde_json::{Value, json};
use support::*;

fn agent() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/vault-claude")
}

/// The stand-in agent's value, put together here as it is there, so neither file holds it whole.
fn value() -> String {
    ["vault-", "fixture/", "Q7m2+a=b?c&d"].concat()
}

/// Characters every encoding treats differently: `/`, `+`, `=`, `?`, `&`, a space and a
/// non-ASCII one (VaultTests' `secret()`).
fn secret() -> String {
    format!("tok/{}+a=b?c&d é", std::process::id() % 1_000_000 + 100_000)
}

/// `value` as a URL encodes it: every byte but `A-Z a-z 0-9 - . _ ~` as `%XX`, and with `form`,
/// spaces as `+`.
fn url(value: &str, form: bool) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            b' ' if form => "+".into(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn b64(text: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(text)
}

/// Every encoded copy of `value` an answer must not carry (VaultTests' `copies(of:)`).
fn copies(value: &str) -> Vec<(&'static str, String)> {
    let percent: String = value.bytes().map(|b| format!("%{b:02X}")).collect();
    vec![
        ("plain", value.to_owned()),
        ("base64", b64(value)),
        (
            "base64",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value),
        ),
        ("base64", b64(&format!("x{value}tail"))),
        ("base64", b64(&format!("xy{value}"))),
        ("base64", b64(&format!("TOKEN={value}\n"))),
        ("hex", hex::encode(value)),
        ("hex", hex::encode(value).to_ascii_uppercase()),
        ("URL-encoded", url(value, false)),
        ("URL-encoded", percent.clone()),
        ("URL-encoded", percent.to_ascii_lowercase()),
        ("URL-encoded", url(value, true)),
    ]
}

/// Asserts `text` holds no copy of `value`.
fn holds_none(text: &str, value: &str, what: &str) {
    for (how, copy) in copies(value) {
        assert!(
            !text.contains(&copy),
            "{what} holds the value ({how}): {text}"
        );
    }
}

/// The configuration [`start`] writes, written now, for `obid vault` before obid starts.
fn write_config(folder: &Path, config: &Value) -> PathBuf {
    put_token(config, TOKEN);
    let path = folder.join("config.json");
    std::fs::write(&path, config.to_string()).unwrap();
    path
}

/// `obid vault --config <config> <args>`, with `stdin` piped in: its exit code, stdout and stderr.
fn vault(config: &Path, args: &[&str], stdin: Option<&str>) -> (i32, String, String) {
    let mut child = Command::new(OBID)
        .arg("vault")
        .arg("--config")
        .arg(config)
        .args(args)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    {
        let mut input = child.stdin.take().unwrap();
        if let Some(text) = stdin {
            input.write_all(text.as_bytes()).unwrap();
        }
    }
    let output = child.wait_with_output().unwrap();
    (
        output.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

fn add(config: &Path, name: &str, value: &str) {
    let (code, out, err) = vault(config, &["add", name], Some(value));
    assert_eq!(code, 0, "{out}{err}");
    assert_eq!(out, format!("Saved {name}.\n"));
    holds_none(&format!("{out}{err}"), value, "obid vault add");
}

fn dispatch(obid: &Obid, job: Value) -> String {
    let answer = call(obid, "POST", "/v1/jobs", Some(&json!({"job": job})));
    assert_eq!(answer.status, 201, "{}", answer.text);
    answer.body["id"].as_str().unwrap().to_owned()
}

fn ended(obid: &Obid, id: &str) -> Value {
    let answer = call(obid, "GET", &format!("/v1/jobs/{id}/wait"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

fn vault_file(obid: &Obid) -> PathBuf {
    obid.home.join("vault/secrets.json")
}

fn chmod(path: &Path, mode: u32) {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
}

/// Ports VaultTests.theAPIsJSONHasTheVaultsSecretsTakenOut: a job's request that holds a vault
/// secret comes back with it taken out (`[vault: staging-api-key]`), in every answer and event and
/// in every encoded form; a clean answer is as it was, byte for byte; and when the vault can't be
/// read, nothing is answered (`503`, saying why). The secret is added with `obid vault` while obid
/// runs, so obid learns it from the file.
#[test]
fn the_apis_json_has_the_vaults_secrets_taken_out() {
    let folder = Folder::new("vault-api");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &agent());
    let path = write_config(&folder.0, &config);
    let obid = start(&folder.0, &config, None);
    let clean = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Nothing secret here."}),
    );
    ended(&obid, &clean);
    let before = call(&obid, "GET", &format!("/v1/jobs/{clean}"), None);
    assert_eq!(before.status, 200, "{}", before.text);

    let value = secret();
    add(&path, "staging-api-key", &value);
    // A value as an argument is never taken.
    let (code, _, err) = vault(&path, &["add", "other-key", &value], None);
    assert_eq!(code, 2, "{err}");
    assert!(err.contains("usage: obid vault"), "{err}");
    let (code, out, _) = vault(&path, &["list"], None);
    assert_eq!((code, out.as_str()), (0, "staging-api-key\n"));

    // A clean answer is as it was.
    let after = call(&obid, "GET", &format!("/v1/jobs/{clean}"), None);
    assert_eq!(after.text, before.text);

    let events = follow_events(&obid);
    let percent: String = value.bytes().map(|b| format!("%{b:02X}")).collect();
    let leaky = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate",
               "task": format!("Use {value} for the staging tests")}),
    );
    let other = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate",
               "task": format!("Ran them with {percent}, {}, {}", b64(&value), hex::encode(&value))}),
    );
    let job = ended(&obid, &leaky);
    ended(&obid, &other);
    assert_eq!(
        job["request"], "Use [vault: staging-api-key] for the staging tests",
        "{job}"
    );
    for target in [
        format!("/v1/jobs/{leaky}"),
        format!("/v1/jobs/{other}"),
        "/v1/jobs".to_owned(),
        format!("/v1/jobs/{other}/wait"),
    ] {
        let answer = call(&obid, "GET", &target, None);
        assert_eq!(answer.status, 200, "{target}: {}", answer.text);
        holds_none(&answer.text, &value, &target);
    }
    let other_job = call(&obid, "GET", &format!("/v1/jobs/{other}"), None).body;
    assert_eq!(
        other_job["request"],
        "Ran them with [vault: staging-api-key], [vault: staging-api-key], [vault: staging-api-key]",
        "{other_job}"
    );
    let mut seen = Vec::new();
    while let Ok((name, data)) = events.recv_timeout(std::time::Duration::from_secs(1)) {
        seen.push(format!("{name} {data}"));
    }
    assert!(
        seen.iter().any(|e| e.contains("[vault: staging-api-key]")),
        "{seen:?}"
    );
    holds_none(&seen.join("\n"), &value, "the event stream");
    holds_none(&obid.log(), &value, "obid's log");

    // When the vault can't be read, nothing is answered, and the answer says why.
    chmod(&vault_file(&obid), 0o644);
    for target in ["/v1/status", "/v1/jobs", &format!("/v1/jobs/{clean}")] {
        let answer = call(&obid, "GET", target, None);
        assert_eq!(answer.status, 503, "{target}: {}", answer.text);
        let error = answer.body["error"].as_str().unwrap();
        assert!(
            error.starts_with(
                "The vault can't be read, so obid answers nothing until it's fixed: Others may read the vault's"
            ),
            "{error}"
        );
        holds_none(&answer.text, &value, target);
    }
    chmod(&vault_file(&obid), 0o600);
    let answer = call(&obid, "GET", "/v1/status", None);
    assert_eq!(answer.status, 200, "{}", answer.text);
}

/// No vault secret reaches an agent: the job's task is handed on with the secret taken out, and
/// a vault that can't be read starts no agent.
#[test]
fn no_vault_secret_reaches_the_agent() {
    let folder = Folder::new("vault-agent");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &agent());
    let path = write_config(&folder.0, &config);
    let value = secret();
    add(&path, "staging-api-key", &value);
    let obid = start(&folder.0, &config, None);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate",
               "task": format!("Use {value} and {} for the staging tests", b64(&value))}),
    );
    ended(&obid, &id);
    let seen = std::fs::read_to_string(
        obid.home
            .join(format!("worktrees/{id}/.obi/seen-prompt.txt")),
    )
    .expect("the agent wrote the prompt it got");
    assert!(seen.contains("[vault: staging-api-key]"), "{seen}");
    holds_none(&seen, &value, "the agent's prompt");
}

// ---------------------------------------------------------------------------------------------
// Publishing

const PULL: &str = "https://github.com/obi-e2e/fixture-app/pull/9";

/// A stand-in `gh` in `folder/bin` that opens [`PULL`] and keeps every call in `folder/gh/calls`.
fn fake_gh(folder: &Path) -> PathBuf {
    let bin = folder.join("bin");
    let state = folder.join("gh");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&state).unwrap();
    let script = format!(
        r#"#!/bin/sh
dir='{state}'
printf '%s\n' "$*" >> "$dir/calls"
case "$1 $2" in
  "pr list") [ -f "$dir/open" ] && cat "$dir/open"; exit 0 ;;
  "pr create") echo '{PULL}'; exit 0 ;;
  "pr view") echo '{{"state":"OPEN","reviewDecision":"REVIEW_REQUIRED","mergedAt":null,"baseRefName":"main","headRefOid":""}}'; exit 0 ;;
  *) exit 0 ;;
esac
"#,
        state = state.display()
    );
    std::fs::write(bin.join("gh"), script).unwrap();
    chmod(&bin.join("gh"), 0o755);
    bin
}

fn gh_calls(folder: &Path) -> String {
    std::fs::read_to_string(folder.join("gh/calls")).unwrap_or_default()
}

/// The commit `branch` is at on the remote, or none.
fn remote_branch(remote: &Path, branch: &str) -> Option<String> {
    let output = Command::new("git")
        .args([
            "for-each-ref",
            "--format=%(objectname)",
            &format!("refs/heads/{branch}"),
        ])
        .current_dir(remote)
        .output()
        .unwrap();
    let listed = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!listed.is_empty()).then_some(listed)
}

/// obid with the fixture, the stand-in agent and `gh`, and [`value`] in its vault.
fn publishing(name: &str) -> (Folder, Obid, PathBuf) {
    let folder = Folder::new(name);
    let bin = fake_gh(&folder.0);
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &agent());
    config["repos"][0]["check"] = json!("true");
    let path = write_config(&folder.0, &config);
    add(&path, "fixture-key", &value());
    let obid = start(&folder.0, &config, Some(&bin));
    (folder, obid, remote)
}

/// An ordinary publish still goes out: an `.env.example` with names and no values, a fixture key
/// that isn't the vault's, and the vault's value cut short are no vault secret.
#[test]
fn an_ordinary_publish_still_goes_out() {
    let (folder, obid, remote) = publishing("vault-plain");
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "PLAIN"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["publishError"], Value::Null, "{job}");
    assert_eq!(job["published"], PULL, "{job}");
    assert!(remote_branch(&remote, &format!("oby/build-{id}")).is_some());
    assert!(gh_calls(&folder.0).contains("pr create"));
}

/// A vault secret in a file, plain, base64, hex or URL-encoded, sends nothing, and what obid says
/// names the file and the rule, never the value.
#[test]
fn a_vault_secret_in_a_file_is_refused_in_every_form() {
    let (folder, obid, remote) = publishing("vault-file");
    for form in ["plain", "base64", "hex", "url"] {
        let id = dispatch(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": format!("FILE: {form}")}),
        );
        let job = ended(&obid, &id);
        assert_eq!(job["status"], "failed", "{form}: {job}\n{}", obid.log());
        let summary = job["summary"].as_str().unwrap();
        assert!(
            summary.starts_with("Not published: possible secret in config.txt:1 (vault secret"),
            "{form}: {summary}"
        );
        // obid's own words never held it: the answer had nothing to take out.
        assert!(!job.to_string().contains("[vault:"), "{form}: {job}");
        assert_eq!(job["published"], Value::Null, "{form}");
        assert_eq!(job["outgoing"], json!([]), "{form}");
        assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
    }
    assert!(!gh_calls(&folder.0).contains("pr create"));
    holds_none(&obid.log(), &value(), "obid's log");
}

/// A vault secret in a commit's message, in any form, sends nothing.
#[test]
fn a_vault_secret_in_a_commit_message_is_refused() {
    let (folder, obid, remote) = publishing("vault-message");
    for form in ["plain", "base64", "hex", "url"] {
        let id = dispatch(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": format!("MESSAGE: {form}")}),
        );
        let job = ended(&obid, &id);
        let said = format!("{} {}", job["summary"], job["publishError"]);
        assert!(
            said.contains("commit message") && said.contains("vault secret"),
            "{form}: {job}\n{}",
            obid.log()
        );
        assert!(!job.to_string().contains("[vault:"), "{form}: {job}");
        assert_eq!(job["published"], Value::Null, "{form}");
        assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
    }
    assert!(!gh_calls(&folder.0).contains("pr create"));
    holds_none(&obid.log(), &value(), "obid's log");
}

/// When the vault can't be read, the publish gate sends nothing, and says why.
#[test]
fn a_vault_that_cant_be_read_publishes_nothing() {
    let (folder, obid, remote) = publishing("vault-unreadable");
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "SLOW"}),
    );
    // Once the agent has the task, the vault becomes readable by others while it works.
    let seen = obid
        .home
        .join(format!("worktrees/{id}/.obi/seen-prompt.txt"));
    within(30, "the agent got its task", || seen.exists().then_some(()));
    chmod(&vault_file(&obid), 0o644);
    within(60, "obid said the publish didn't go out", || {
        obid.log()
            .contains(&format!("job {id}: not published"))
            .then_some(())
    });
    chmod(&vault_file(&obid), 0o600);
    let job = ended(&obid, &id);
    let error = job["publishError"].as_str().unwrap_or_default();
    assert!(
        error.starts_with(
            "Not published: the secret scan couldn't run (the vault can't be read: Others may read"
        ),
        "{job}\n{}",
        obid.log()
    );
    assert_eq!(job["published"], Value::Null);
    assert_eq!(job["outgoing"], json!([]));
    assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
    assert!(!gh_calls(&folder.0).contains("pr create"));
}

/// A machine that never ran `obid vault` has an empty vault, not one that can't be read: answers
/// come, the agent gets its task as it is, and an ordinary publish goes out. No vault is made.
#[test]
fn a_fresh_install_without_a_vault_works_as_before() {
    let folder = Folder::new("vault-none");
    let bin = fake_gh(&folder.0);
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &agent());
    config["repos"][0]["check"] = json!("true");
    let obid = start(&folder.0, &config, Some(&bin));
    assert_eq!(call(&obid, "GET", "/v1/status", None).status, 200);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "PLAIN, as it is"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["published"], PULL, "{job}");
    let seen = std::fs::read_to_string(
        obid.home
            .join(format!("worktrees/{id}/.obi/seen-prompt.txt")),
    )
    .unwrap();
    assert!(seen.contains("PLAIN, as it is"), "{seen}");
    assert!(!obid.home.join("vault").exists());
}

/// A vault damaged while a job waits for a slot: when the job's turn comes, its agent gets
/// nothing, and the job says why and what to do.
#[test]
fn a_damaged_vault_gives_the_agent_nothing() {
    let (_folder, obid, _) = publishing("vault-damaged");
    let answer = call(
        &obid,
        "PUT",
        "/v1/settings/jobs",
        Some(&json!({"maxRunning": 1})),
    );
    assert_eq!(answer.status, 200, "{}", answer.text);
    let first = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "SLOW"}),
    );
    let waiting = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate",
               "task": format!("Use {} for the tests", value())}),
    );
    let seen = |id: &str| {
        obid.home
            .join(format!("worktrees/{id}/.obi/seen-prompt.txt"))
    };
    within(30, "the first job's agent got its task", || {
        seen(&first).exists().then_some(())
    });
    std::fs::write(vault_file(&obid), "not the vault").unwrap();
    let stored = obid.home.join(format!("jobs/{waiting}.json"));
    within(60, "the waiting job ended", || {
        let job: Value = serde_json::from_slice(&std::fs::read(&stored).ok()?).ok()?;
        (job["status"] == "failed").then_some(())
    });
    assert!(!seen(&waiting).exists(), "the agent got a prompt");
    // Fixed: the answers come again, and the job says what happened.
    std::fs::write(
        vault_file(&obid),
        json!({"secrets": {"fixture-key": value()}}).to_string(),
    )
    .unwrap();
    let job = call(&obid, "GET", &format!("/v1/jobs/{waiting}"), None);
    assert_eq!(job.status, 200, "{}", job.text);
    let summary = job.body["summary"].as_str().unwrap_or_default();
    assert!(
        summary.contains("The vault can't be read, so obid gave the agent nothing: The vault at ")
            && summary.contains("move it aside, then add the secrets again with `obid vault")
            && summary.contains("Once it's fixed, tell the job to go on."),
        "{}\n{}",
        job.text,
        obid.log()
    );
}
