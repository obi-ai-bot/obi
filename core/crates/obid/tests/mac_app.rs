//! The existing Mac app against obid: tests/mac-app/main.swift is built with the app's own client
//! code (apps/shared/Runner.swift and what it needs: apps/shared/Harness.swift, apps/shared/Decisions.swift, apps/shared/JobPage.swift, apps/shared/JobList.swift,
//! apps/shared/Elapsed.swift, apps/shared/DeviceKey.swift, apps/shared/GitHubWorkModel.swift, apps/shared/PhoneRelay.swift and Engine/, compiled as the Oby target compiles
//! them) and follows a running obid as apps/mac/app/RunnerFeed.swift follows the runner on this Mac
//! (Settings › Runner › This Mac, #283): the token through `LocalRunner.token(home:fallback:)`, `GET
//! /v1/events`, then status, the jobs, the inbox (open and done), the conversation and a job by
//! id, read into the app's types; Clear done; and Stop all from the island on a job that started
//! while it followed. macOS only: the app is a Mac app, and swiftc comes with Xcode.
//!
//! The app's own `LocalRunner.url` is `http://127.0.0.1:7777`: to follow obid, the app needs obid
//! listening there (`"listen": "127.0.0.1:7777"`) with its home set to `LocalRunner.home`.
//! This test gives the client an isolated obid home and address, so it reads the private token
//! file without touching the keychain or a port another runner may hold.

#![cfg(target_os = "macos")]

mod support;

use std::hash::{Hash, Hasher};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use serde_json::json;
use support::*;

/// The app's files the client is built from, under the repository root.
const APP_SOURCES: &[&str] = &[
    "apps/shared/Runner.swift",
    "apps/shared/Harness.swift",
    "apps/shared/Decisions.swift",
    "apps/shared/JobPage.swift",
    "apps/shared/JobList.swift",
    "apps/shared/Elapsed.swift",
    "apps/shared/DeviceKey.swift",
    "apps/shared/TetrixStatus.swift",
    "apps/shared/GitHubWorkModel.swift",
    "apps/shared/SlackStatus.swift",
    "apps/shared/SentryStatus.swift",
    "apps/shared/PhoneRelay.swift",
    "apps/shared/RemoteRoute.swift",
];

/// What Package.swift and the Xcode project compile Oby's Swift with.
const SWIFT_FLAGS: [&str; 18] = [
    "-swift-version",
    "5",
    "-enable-upcoming-feature",
    "MemberImportVisibility",
    "-enable-upcoming-feature",
    "BareSlashRegexLiterals",
    "-enable-upcoming-feature",
    "DisableOutwardActorInference",
    "-enable-upcoming-feature",
    "GlobalActorIsolatedTypesUsability",
    "-enable-upcoming-feature",
    "InferIsolatedConformances",
    "-enable-upcoming-feature",
    "InferSendableFromCaptures",
    "-enable-upcoming-feature",
    "NonisolatedNonsendingByDefault",
    "-default-isolation",
    "MainActor",
];

/// Every Swift file the client is built from.
fn sources() -> Vec<PathBuf> {
    let root = obi();
    let mut files = vec![Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/mac-app/main.swift")];
    files.extend(APP_SOURCES.iter().map(|f| root.join(f)));
    let mut engine: Vec<PathBuf> = std::fs::read_dir(root.join("Engine"))
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "swift"))
        .collect();
    engine.sort();
    files.extend(engine);
    files
}

/// The client, built once for these sources and shared by the
/// tests in this file.
fn client() -> PathBuf {
    static BUILT: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    BUILT.get_or_init(build).clone()
}

fn build() -> PathBuf {
    let files = sources();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for file in &files {
        file.hash(&mut hasher);
        std::fs::read(file).unwrap().hash(&mut hasher);
    }
    let built = Path::new(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("mac-app-client-{:016x}", hasher.finish()));
    if built.exists() {
        return built;
    }
    let partial = built.with_extension("building");
    let output = Command::new("xcrun")
        .arg("swiftc")
        .args(SWIFT_FLAGS)
        .args(["-Onone", "-module-name", "ObyMacClient", "-o"])
        .arg(&partial)
        .args(&files)
        .output()
        .expect("xcrun swiftc runs (Xcode is installed)");
    assert!(
        output.status.success(),
        "the app's client didn't build: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    std::fs::rename(&partial, &built).unwrap();
    built
}

/// The client's lines, as they come.
fn lines(child: &mut std::process::Child) -> Receiver<String> {
    let stdout = child.stdout.take().unwrap();
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { return };
            eprintln!("mac app: {line}");
            if sender.send(line).is_err() {
                return;
            }
        }
    });
    receiver
}

/// The next line that starts with `prefix`, within `seconds`; the lines before it go to `seen`.
fn next(lines: &Receiver<String>, prefix: &str, seconds: u64, seen: &mut Vec<String>) -> String {
    let give_up_at = Instant::now() + Duration::from_secs(seconds);
    loop {
        let left = give_up_at.saturating_duration_since(Instant::now());
        match lines.recv_timeout(left) {
            Ok(line) if line.starts_with(prefix) => return line,
            Ok(line) => seen.push(line),
            Err(_) => panic!("no {prefix:?} line within {seconds} seconds; before it: {seen:#?}"),
        }
    }
}

fn fake_claude() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude")
}

/// The Mac app's client follows obid, lists its jobs, clears and stops all, every answer read into
/// the app's own types.
#[test]
fn the_mac_app_follows_obid_and_lists_its_jobs() {
    let client = client();
    let folder = Folder::new("mac-app");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote, &fake_claude()), None);
    let made = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "investigate",
                             "task": "Look around", "title": "Job progress screen"}}),
        ),
    );
    assert_eq!(made.status, 201, "{}", made.text);
    let id = made.body["id"].as_str().unwrap().to_owned();
    let done = call(&obid, "GET", &format!("/v1/jobs/{id}/wait"), None).body;
    assert_eq!(done["status"], "done");

    // obid has measured its worktrees (it may answer before), so the client's status has `cleanup`.
    let deadline = Instant::now() + Duration::from_secs(10);
    while call(&obid, "GET", "/v1/status", None)
        .body
        .get("cleanup")
        .is_none()
    {
        assert!(
            Instant::now() < deadline,
            "obid never measured its worktrees"
        );
        std::thread::sleep(Duration::from_millis(20));
    }

    // The owner opens pairing on obid's machine, so the Mac's key registers (POST /v1/devices).
    std::fs::write(obid.home.join("pairing"), "").unwrap();
    let mut child = Command::new(&client)
        .env("OBID_URL", format!("http://127.0.0.1:{}", obid.port))
        .env("OBID_HOME", &obid.home)
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let lines = lines(&mut child);
    let mut seen = Vec::new();
    let host = gethostname();
    assert_eq!(
        next(&lines, "status ", 60, &mut seen),
        format!(
            "status host={host} version=0.2.0 accounts=stub clearedAt=null mode=sandbox cleanup=true"
        )
    );
    assert_eq!(
        next(&lines, "jobs ", 30, &mut seen),
        format!("jobs {id}:done:Job progress screen")
    );
    assert_eq!(next(&lines, "extras ", 30, &mut seen), "extras 1");
    assert_eq!(next(&lines, "inbox ", 30, &mut seen), "inbox 0");
    assert_eq!(next(&lines, "inbox-done ", 30, &mut seen), "inbox-done 0");
    // obid has no conversation (no brain): the app reads its 404 as an empty thread.
    assert_eq!(
        next(&lines, "conversation ", 30, &mut seen),
        "conversation 0"
    );
    assert_eq!(
        next(&lines, "job ", 30, &mut seen),
        format!("job {id} done heading=Job progress screen")
    );
    // The Mac's merge checks (none waits on obid) and its publishing key, registered while
    // pairing is open.
    assert_eq!(
        next(&lines, "checks-next ", 30, &mut seen),
        "checks-next 200"
    );
    assert_eq!(next(&lines, "devices ", 30, &mut seen), "devices 200");
    assert!(
        !obid.home.join("pairing").exists(),
        "the Mac used pairing up"
    );
    assert!(
        std::fs::read_to_string(obid.home.join("devices.json"))
            .unwrap()
            .contains("\"Test Mac\"")
    );
    let cleared = next(&lines, "cleared ", 30, &mut seen);
    let time = cleared.strip_prefix("cleared ").unwrap().to_owned();
    assert_eq!(
        call(&obid, "GET", "/v1/status", None).body["clearedAt"],
        time.as_str()
    );
    next(&lines, "ready", 30, &mut seen);
    assert_eq!(
        next(&lines, "event clear ", 30, &mut seen),
        format!("event clear {time}")
    );

    // A job that starts while the app follows: it hears it run, stops all, and hears it stop.
    let sleeper = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "SLEEP"}}),
        ),
    );
    assert_eq!(sleeper.status, 201, "{}", sleeper.text);
    let sleeper = sleeper.body["id"].as_str().unwrap().to_owned();
    assert_eq!(
        next(
            &lines,
            &format!("event job {sleeper} running"),
            60,
            &mut seen
        ),
        format!("event job {sleeper} running")
    );
    assert_eq!(
        next(&lines, "stop-all ", 30, &mut seen),
        format!("stop-all 1 {sleeper}")
    );
    next(
        &lines,
        &format!("event job {sleeper} stopped"),
        30,
        &mut seen,
    );
    next(&lines, "done", 30, &mut seen);
    let status = child.wait().unwrap();
    assert!(status.success(), "{status}");
    assert_eq!(
        call(&obid, "GET", &format!("/v1/jobs/{sleeper}"), None).body["status"],
        "stopped"
    );
}

/// File discovery accepts obid's visible ASCII tokens, including a non-hex owner token,
/// but refuses malformed credentials without making an HTTP request or printing their value.
#[test]
fn the_mac_app_discovers_only_usable_private_file_tokens() {
    use std::os::unix::fs::PermissionsExt;
    let client = client();
    let folder = Folder::new("mac-app-file-token");
    let path = folder.0.join("api-token");
    for (text, accepted) in [
        ("x".repeat(40), true),
        ("x".repeat(31), false),
        (format!("{} ", "x".repeat(40)), false),
    ] {
        std::fs::write(&path, text).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let output = Command::new(&client)
            .env("OBID_HOME", &folder.0)
            .env("OBID_TOKEN_ONLY", "1")
            .output()
            .unwrap();
        assert_eq!(output.status.success(), accepted, "{output:?}");
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            if accepted {
                "token read\n"
            } else {
                "token refused\n"
            }
        );
    }
}

fn gethostname() -> String {
    let output = Command::new("hostname").output().unwrap();
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}
