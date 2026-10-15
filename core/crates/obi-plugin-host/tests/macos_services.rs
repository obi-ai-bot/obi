//! The macOS services a plug-in's sandbox keeps from it (docs/ARCHITECTURE.md 5.3, step 3,
//! "macOS services"), tried from inside the sandbox: the person's preferences through `cfprefsd`
//! (read and write), the pasteboard (read and write), and the keychain through `securityd`. Each
//! check first shows that the same thing works outside the sandbox, so a refusal inside means
//! the sandbox refused it.
//!
//! The preferences are a throwaway domain (`obi.test.<pid>.<n>`) and the pasteboard is the find
//! pasteboard, put back as it was; both are cleaned up when the test ends, failed or not.
#![cfg(target_os = "macos")]

mod common;

use std::process::{Command, Stdio};

use common::{Home, id, options, sandbox_made};
use obi_plugin_api::PluginState;
use obi_plugin_host::PluginHost;
use serde_json::{Value, json};

/// What a command printed (stdout and stderr) and whether it exited with 0.
fn run(argv: &[&str], input: Option<&str>) -> (bool, String) {
    let mut child = Command::new(argv[0])
        .args(&argv[1..])
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
        use std::io::Write;
        stdin.write_all(input.as_bytes()).unwrap();
    }
    let output = child.wait_with_output().unwrap();
    (
        output.status.success(),
        format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ),
    )
}

/// Takes the throwaway preference domains out and puts the find pasteboard back.
struct Cleanup {
    domains: Vec<String>,
    find_pasteboard: Option<String>,
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        // cfprefsd keeps the person's preferences in their account's home, whatever this
        // process's HOME is; `defaults delete` empties a domain and leaves its file.
        let (_, account) = run(&["/usr/bin/id", "-P"], None);
        let account_home = account.trim().split(':').nth(8).unwrap_or("").to_owned();
        for domain in &self.domains {
            let _ = run(&["/usr/bin/defaults", "delete", domain], None);
            if account_home.starts_with('/') {
                let file = std::path::Path::new(&account_home)
                    .join("Library/Preferences")
                    .join(format!("{domain}.plist"));
                let _ = std::fs::remove_file(file);
            }
        }
        if let Some(saved) = &self.find_pasteboard {
            let _ = run(&["/usr/bin/pbcopy", "-pboard", "find"], Some(saved));
        }
    }
}

fn sh(script: &str) -> Vec<String> {
    vec!["/bin/sh".into(), "-c".into(), script.into()]
}

/// What the probe's command `argv` gave: whether it exited with 0, and what it printed.
fn probed(probe: &Value, argv: &[String]) -> (bool, String) {
    let key = format!("run {}", argv.join(" "));
    let result = probe
        .get(&key)
        .unwrap_or_else(|| panic!("{key} was not probed: {probe:#}"));
    (
        result["ok"] == json!(true),
        result["got"].as_str().unwrap_or("").to_owned(),
    )
}

#[tokio::test]
async fn no_preferences_pasteboard_or_keychain_reach_a_plugin() {
    let pid = std::process::id();
    let readable = format!("obi.test.{pid}.1");
    let writable = format!("obi.test.{pid}.2");
    let pref_canary = format!("obi-pref-canary-{pid}");
    let board_canary = format!("obi-pasteboard-canary-{pid}");
    let inside_canary = format!("obi-pasteboard-inside-{pid}");
    let mut cleanup = Cleanup {
        domains: vec![readable.clone(), writable.clone()],
        find_pasteboard: None,
    };

    // Outside the sandbox each of them works.
    let (saved_ok, saved) = run(&["/usr/bin/pbpaste", "-pboard", "find"], None);
    if saved_ok {
        cleanup.find_pasteboard = Some(saved);
    }
    assert!(
        run(
            &[
                "/usr/bin/defaults",
                "write",
                &readable,
                "canary",
                &pref_canary
            ],
            None
        )
        .0
    );
    let (ok, got) = run(&["/usr/bin/defaults", "read", &readable, "canary"], None);
    assert!(ok && got.contains(&pref_canary), "outside: {got}");
    assert!(run(&["/usr/bin/pbcopy", "-pboard", "find"], Some(&board_canary)).0);
    let (ok, got) = run(&["/usr/bin/pbpaste", "-pboard", "find"], None);
    assert!(
        ok && got == board_canary,
        "outside, the find pasteboard has {got:?}"
    );
    let system_keychain = "/Library/Keychains/System.keychain";
    let roots = "/System/Library/Keychains/SystemRootCertificates.keychain";
    let (ok, got) = run(
        &["/usr/bin/security", "show-keychain-info", system_keychain],
        None,
    );
    assert!(ok && got.contains("Keychain \""), "outside: {got}");
    let (ok, got) = run(
        &[
            "/usr/bin/security",
            "find-certificate",
            "-c",
            "Apple Root CA",
            roots,
        ],
        None,
    );
    assert!(ok && got.contains("keychain:"), "outside: {got}");

    // Inside it, none of them.
    let read_pref: Vec<String> = ["/usr/bin/defaults", "read", &readable, "canary"]
        .map(str::to_owned)
        .to_vec();
    let write_pref: Vec<String> = ["/usr/bin/defaults", "write", &writable, "w", "written"]
        .map(str::to_owned)
        .to_vec();
    let paste = sh("/usr/bin/pbpaste -pboard find; echo \"pbpaste=$?\"");
    let copy = sh(&format!(
        "printf %s {inside_canary} | /usr/bin/pbcopy -pboard find; echo \"pbcopy=$?\""
    ));
    let keychain_info: Vec<String> = ["/usr/bin/security", "show-keychain-info", system_keychain]
        .map(str::to_owned)
        .to_vec();
    let root_certificate: Vec<String> = [
        "/usr/bin/security",
        "find-certificate",
        "-c",
        "Apple Root CA",
        roots,
    ]
    .map(str::to_owned)
    .to_vec();
    let config = json!({"probe": {"run": [
        read_pref, write_pref, paste, copy, keychain_info, root_certificate,
    ]}});

    let options = obi_plugin_host::Options {
        initialize_timeout: std::time::Duration::from_secs(60),
        ..options()
    };
    let home = Home::new("macos-services");
    home.install("context-test", "services");
    let host = PluginHost::start_with(&home.path, options).await.unwrap();
    let ready = host
        .set_enabled(&id("services"), true, Some(config))
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    assert_eq!(ready.state, PluginState::Ready, "{ready:?}");
    let probe = home.record("services", "probe.json").unwrap();
    host.shutdown().await;

    // Preferences: the person's can't be read, and a write reaches nothing.
    let (_, got) = probed(&probe, &read_pref);
    assert!(
        !got.contains(&pref_canary),
        "it read the person's preferences: {probe:#}"
    );
    let (ok, got) = run(&["/usr/bin/defaults", "read", &writable], None);
    assert!(
        !ok && !got.contains("written"),
        "its preference write reached the person's preferences ({got}): {probe:#}"
    );
    // The pasteboard: what the person copied can't be read, and nothing it copies lands.
    let (_, got) = probed(&probe, &paste);
    assert!(
        !got.contains(&board_canary),
        "it read the pasteboard: {probe:#}"
    );
    let (_, got) = probed(&probe, &copy);
    assert!(got.contains("pbcopy=1"), "{probe:#}");
    let (_, now) = run(&["/usr/bin/pbpaste", "-pboard", "find"], None);
    assert_eq!(now, board_canary, "it wrote the pasteboard: {probe:#}");
    // The keychain: securityd answers it nothing, not even for the system's own keychains,
    // whose files it may read.
    let (ok, got) = probed(&probe, &keychain_info);
    assert!(
        !ok && !got.contains("Keychain \""),
        "securityd answered it: {probe:#}"
    );
    let (_, got) = probed(&probe, &root_certificate);
    assert!(
        !got.contains("keychain:"),
        "securityd answered it: {probe:#}"
    );
    drop(cleanup);
}
