//! The plug-in sandbox (docs/ARCHITECTURE.md 5.3, step 3), seen from inside: the test plug-in
//! tries reads, listings and writes and reports what each gave, and the test checks what
//! happened on the machine.

mod common;

use std::collections::BTreeSet;
use std::path::Path;

use common::{Home, id, options, sandbox_made};
use obi_plugin_host::PluginHost;
use obi_plugin_host::api::PluginState;
use serde_json::{Value, json};

fn path(p: &Path) -> String {
    p.to_str().unwrap().to_owned()
}

/// What the probe said about `key`: `Some(what it got)` when it worked, `None` when it didn't.
fn probed(probe: &Value, key: &str) -> Option<String> {
    let result = probe
        .get(key)
        .unwrap_or_else(|| panic!("{key} was not probed: {probe:#}"));
    (result["ok"] == json!(true)).then(|| result["got"].as_str().unwrap_or("").to_owned())
}

#[tokio::test]
async fn a_plugin_reads_and_writes_only_what_the_spec_lets_it() {
    let home = Home::new("probe");
    let own = home.install("context-test", "probe");
    let other = home.install("context-test", "other");
    let h = &home.path;
    std::fs::write(
        h.join("api-token"),
        "obid-api-token-0123456789abcdef0123456789",
    )
    .unwrap();
    std::fs::create_dir_all(h.join("keys")).unwrap();
    std::fs::write(h.join("keys/obi.key"), "private key").unwrap();
    std::fs::create_dir_all(h.join("worktrees/job1")).unwrap();
    std::fs::write(h.join("worktrees/job1/main.rs"), "fn main() {}").unwrap();
    std::fs::create_dir_all(home.data_dir("other")).unwrap();
    std::fs::write(home.data_dir("other").join("notes"), "other's data").unwrap();
    let data = home.data_dir("probe");
    let outside = std::env::temp_dir().join(format!("obi-plugin-escape-{}", std::process::id()));
    let _ = std::fs::remove_file(&outside);
    let real_home = std::env::var("HOME").ok().filter(|h| h != "/");

    let mut list = vec![path(h), path(&data)];
    list.extend(real_home.clone());
    let config = json!({"probe": {
        "read": [
            path(&own.join("obi-plugin.json")),
            path(&other.join("obi-plugin.json")),
            path(&h.join("api-token")),
            path(&h.join("keys/obi.key")),
            path(&h.join("worktrees/job1/main.rs")),
            path(&home.data_dir("other").join("notes")),
            "/etc/hosts",
        ],
        "list": list,
        "write": [
            path(&data.join("written")),
            path(&data.join("tmp/written")),
            path(&own.join("written")),
            path(&h.join("written")),
            path(&h.join("api-token")),
            path(&home.data_dir("other").join("written")),
            path(&outside),
        ],
    }});

    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    let ready = host
        .set_enabled(&id("probe"), true, Some(config))
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    assert_eq!(ready.state, PluginState::Ready, "{ready:?}");
    let probe = home.record("probe", "probe.json").unwrap();
    let read = |p: &Path| probed(&probe, &format!("read {}", path(p)));

    // Its own folder (read-only) and its data folder, and the system's files.
    assert!(read(&own.join("obi-plugin.json")).unwrap().starts_with('{'));
    assert!(probed(&probe, "read /etc/hosts").is_some(), "{probe:#}");
    assert_eq!(
        probed(&probe, &format!("list {}", path(&data))).map(|_| ()),
        Some(())
    );
    assert!(data.join("written").is_file());
    assert!(data.join("tmp/written").is_file());

    // Nothing else of obid's home.
    for secret in [
        other.join("obi-plugin.json"),
        h.join("api-token"),
        h.join("keys/obi.key"),
        h.join("worktrees/job1/main.rs"),
        home.data_dir("other").join("notes"),
    ] {
        assert_eq!(
            read(&secret),
            None,
            "{} was readable: {probe:#}",
            secret.display()
        );
    }
    // A listing of home shows none of what it holds.
    if let Some(listing) = probed(&probe, &format!("list {}", path(h))) {
        // On Linux the empty folder over home holds the two folders bound back in.
        for name in ["api-token", "keys", "worktrees", "plugins.json"] {
            assert!(
                !listing.split(',').any(|n| n == name),
                "home listed {listing}"
            );
        }
        let names: BTreeSet<&str> = listing.split(',').filter(|n| !n.is_empty()).collect();
        assert!(
            names.is_subset(&BTreeSet::from(["plugins", "plugin-data"])),
            "{listing}"
        );
    }
    // Nor the person's real HOME.
    if let Some(real_home) = &real_home {
        let outside_view = std::fs::read_dir(real_home).map(|d| d.count()).unwrap_or(0);
        if let Some(listing) = probed(&probe, &format!("list {real_home}")) {
            assert!(
                listing.is_empty() || outside_view == 0,
                "the real HOME was listed: {listing}"
            );
        }
    }

    // No write reached anything outside its data folder.
    assert!(!own.join("written").exists());
    assert!(!h.join("written").exists());
    assert!(!home.data_dir("other").join("written").exists());
    assert!(!outside.exists());
    assert_eq!(
        std::fs::read_to_string(h.join("api-token")).unwrap(),
        "obid-api-token-0123456789abcdef0123456789"
    );
    for refused in [own.join("written"), outside.clone()] {
        assert_eq!(
            probed(&probe, &format!("write {}", path(&refused))),
            None,
            "{probe:#}"
        );
    }
    host.shutdown().await;
}

#[tokio::test]
async fn its_environment_is_path_home_lang_and_tmpdir_only() {
    let home = Home::new("env");
    home.install("events-test", "events-test");
    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    let ready = host
        .set_enabled(&id("events-test"), true, None)
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    let seen = home.record("events-test", "env.json").unwrap();
    let env = seen["env"].as_object().unwrap();
    let names: BTreeSet<&str> = env.keys().map(String::as_str).collect();
    assert_eq!(
        names,
        BTreeSet::from(["HOME", "LANG", "PATH", "TMPDIR"]),
        "{seen:#}"
    );
    let data = home.data_dir("events-test");
    assert_eq!(env["HOME"], json!(path(&data)));
    assert_eq!(env["TMPDIR"], json!(path(&data.join("tmp"))));
    assert_eq!(seen["cwd"], json!(path(&data)));
    assert!(!env["PATH"].as_str().unwrap().is_empty());
    assert!(!env["LANG"].as_str().unwrap().is_empty());
    host.shutdown().await;
}
