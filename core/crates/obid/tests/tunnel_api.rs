//! obid runs the Cloudflare Tunnel phones reach this Mac through (#896; docs/runner-api.md, "obid
//! only: the tunnel"): the app hands the run token over, obid keeps it in its vault and runs
//! cloudflared (here tests/agents/fake-cloudflared) with the token in a file only, restarts it,
//! and stops it when told. The token never shows in an answer, a log line or an argument.

mod support;

use std::path::{Path, PathBuf};

use serde_json::json;
use support::*;

/// A run token as the control plane hands one out: one line of base64.
const TOKEN_VALUE: &str =
    "eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwiLCJzIjoiZmFrZXR1bm5lbHNlY3JldDEyMyJ9";

fn fake() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-cloudflared")
}

fn with_cloudflared(folder: &Folder) -> Obid {
    let remote = fixture(&folder.0.join("fixture"));
    again(folder, &config(&folder.0, &remote, &stub_agent()))
}

/// obid started (again) with `config`, the fake cloudflared its own.
fn again(folder: &Folder, config: &serde_json::Value) -> Obid {
    start_with(
        &folder.0,
        config,
        None,
        &[("OBID_CLOUDFLARED", fake().to_str().unwrap())],
    )
}

fn config_of(folder: &Folder) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(folder.0.join("config.json")).unwrap()).unwrap()
}

fn state(obid: &Obid) -> String {
    call(obid, "GET", "/v1/status", None).body["tunnel"]["state"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

fn wait_for(obid: &Obid, wanted: &str) {
    within(20, &format!("the tunnel is {wanted}"), || {
        (state(obid) == wanted).then_some(())
    });
}

/// What the fake was started with, one block a start.
fn starts(obid: &Obid) -> Vec<String> {
    std::fs::read_to_string(obid.home.join("tunnel/seen"))
        .unwrap_or_default()
        .split("start\n")
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect()
}

fn put_token(obid: &Obid) {
    let put = call(
        obid,
        "PUT",
        "/v1/obid/tunnel",
        Some(&json!({"token": TOKEN_VALUE})),
    );
    assert_eq!(put.status, 204, "{}", put.text);
}

#[test]
fn putting_a_token_starts_cloudflared_with_a_token_file_and_no_environment() {
    use std::os::unix::fs::PermissionsExt as _;
    let folder = Folder::new("tunnel-start");
    let obid = with_cloudflared(&folder);
    assert_eq!(state(&obid), "off");
    let bad = call(
        &obid,
        "PUT",
        "/v1/obid/tunnel",
        Some(&json!({"token": "two\nlines"})),
    );
    assert_eq!(bad.status, 422, "{}", bad.text);
    put_token(&obid);
    wait_for(&obid, "connected");
    let seen = starts(&obid);
    assert_eq!(seen.len(), 1, "{seen:?}");
    let file = obid.home.join("tunnel/token");
    assert!(
        seen[0].contains(&format!(
            "args: tunnel --no-autoupdate run --token-file {}",
            file.display()
        )),
        "{}",
        seen[0]
    );
    assert!(
        !seen[0].contains(TOKEN_VALUE),
        "the token is in an argument or the environment"
    );
    assert!(!seen[0].contains("TUNNEL_TOKEN"));
    // Its environment: PATH and HOME (the shell adds its own few), nothing of obid's.
    for line in seen[0].lines().filter_map(|l| l.strip_prefix("env: ")) {
        let name = line.split('=').next().unwrap();
        assert!(
            ["PATH", "HOME", "PWD", "SHLVL", "_", "OLDPWD"].contains(&name),
            "{line}"
        );
    }
    assert_eq!(std::fs::read_to_string(&file).unwrap(), TOKEN_VALUE);
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&file), 0o600);
    assert_eq!(mode(&obid.home.join("tunnel")), 0o700);
}

#[test]
fn the_token_never_appears_in_an_answer_a_log_line_or_an_argument() {
    let folder = Folder::new("tunnel-secret");
    let obid = with_cloudflared(&folder);
    put_token(&obid);
    wait_for(&obid, "connected");
    let status = call(&obid, "GET", "/v1/status", None);
    assert!(!status.text.contains(TOKEN_VALUE));
    // The fake printed an ERR line holding the token: obid logged it with the token taken out.
    within(10, "obid logged cloudflared's ERR line", || {
        std::fs::read_to_string(&obid.stderr)
            .ok()
            .filter(|log| log.contains("checking with token"))
    });
    let log = std::fs::read_to_string(&obid.stderr).unwrap();
    assert!(!log.contains(TOKEN_VALUE), "the token is in obid's log");
}

#[test]
fn cloudflared_starts_again_when_obid_restarts() {
    let folder = Folder::new("tunnel-restart");
    let mut obid = with_cloudflared(&folder);
    put_token(&obid);
    wait_for(&obid, "connected");
    obid.stop();
    drop(obid);
    let obid = again(&folder, &config_of(&folder));
    wait_for(&obid, "connected");
    assert_eq!(starts(&obid).len(), 2);
}

#[test]
fn a_crashed_cloudflared_is_started_again() {
    let folder = Folder::new("tunnel-crash");
    let obid = with_cloudflared(&folder);
    put_token(&obid);
    wait_for(&obid, "connected");
    let pid: i32 = std::fs::read_to_string(obid.home.join("tunnel/pid"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    let _ = nix::sys::signal::kill(
        nix::unistd::Pid::from_raw(pid),
        nix::sys::signal::Signal::SIGKILL,
    );
    within(20, "cloudflared started again", || {
        (starts(&obid).len() == 2).then_some(())
    });
    wait_for(&obid, "connected");
}

#[test]
fn deleting_the_tunnel_stops_cloudflared_and_forgets_the_token() {
    let folder = Folder::new("tunnel-delete");
    let obid = with_cloudflared(&folder);
    put_token(&obid);
    wait_for(&obid, "connected");
    let deleted = call(&obid, "DELETE", "/v1/obid/tunnel", None);
    assert_eq!(deleted.status, 204, "{}", deleted.text);
    wait_for(&obid, "off");
    assert!(!obid.home.join("tunnel/token").exists());
    within(10, "cloudflared stopped", || {
        (!obid.home.join("tunnel/pid").exists()).then_some(())
    });
    // Forgotten: obid starting again runs no tunnel.
    drop(obid);
    let obid = again(&folder, &config_of(&folder));
    std::thread::sleep(std::time::Duration::from_secs(1));
    assert_eq!(state(&obid), "off");
    assert_eq!(starts(&obid).len(), 1);
}

#[test]
fn status_and_events_say_how_the_tunnel_is() {
    let folder = Folder::new("tunnel-events");
    let obid = with_cloudflared(&folder);
    let events = follow_events(&obid);
    std::fs::create_dir_all(obid.home.join("tunnel")).unwrap();
    std::fs::write(obid.home.join("tunnel/fail"), "").unwrap();
    put_token(&obid);
    let seen = events_named(&events, "tunnel", 20, |got| {
        got.iter().any(|e| e["state"] == "failed")
    });
    let failed = seen.iter().find(|e| e["state"] == "failed").unwrap();
    assert!(
        failed["detail"]
            .as_str()
            .unwrap()
            .contains("Couldn't start tunnel"),
        "{failed}"
    );
    std::fs::remove_file(obid.home.join("tunnel/fail")).unwrap();
    events_named(&events, "tunnel", 70, |got| {
        got.iter().any(|e| e["state"] == "connected")
    });
    assert_eq!(
        call(&obid, "GET", "/v1/status", None).body["tunnel"],
        json!({"state": "connected", "detail": null})
    );
}

#[test]
fn an_obid_without_cloudflared_refuses_with_why() {
    let folder = Folder::new("tunnel-none");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote, &stub_agent()), None);
    let refused = call(
        &obid,
        "PUT",
        "/v1/obid/tunnel",
        Some(&json!({"token": TOKEN_VALUE})),
    );
    assert_eq!(refused.status, 409, "{}", refused.text);
    assert!(
        refused
            .text
            .contains("remote access needs a full build of Oby's Mac app"),
        "{}",
        refused.text
    );
}
