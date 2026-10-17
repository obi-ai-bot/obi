//! The lifecycle of a plug-in with a process (docs/ARCHITECTURE.md 5.3, steps 3 to 6): started
//! in its sandbox, initialized, pinged, restarted after its first failure in a row after 1
//! second and after its second after 2 seconds (shortened here, but in
//! `the_restart_policy_is_one_second_then_two_then_failed`), `failed` at its third failure in a
//! row (and still `failed` when `obid` starts again), and stopped with `shutdown`, then killed
//! when it doesn't stop. Whenever it stops or fails, nothing it started is left running, also
//! not what left its process group or session.

mod common;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use common::{
    Home, assert_no_slirp4netns_left, beats, id, options, sandbox_made, status, wait_for_state,
    wait_until,
};
use obi_plugin_api::{Kind, PluginState};
use obi_plugin_host::{Options, PluginHost};
use serde_json::{Value, json};

const LONG: Duration = Duration::from_secs(20);

async fn host_with(home: &Home, options: Options) -> PluginHost {
    PluginHost::start_with(&home.path, options).await.unwrap()
}

#[tokio::test]
async fn enabling_starts_it_in_its_sandbox_and_initializes_it() {
    let home = Home::new("init");
    home.install("context-test", "context-test");
    let host = host_with(&home, options()).await;
    let ready = host
        .set_enabled(&id("context-test"), true, Some(json!({})))
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    assert_eq!(ready.state, PluginState::Ready, "{ready:?}");
    assert!(ready.enabled);
    assert_eq!(ready.last_error, None);
    assert_eq!(home.starts("context-test"), 1);

    let init = home.record("context-test", "initialize.json").unwrap();
    let data_dir = home.data_dir("context-test");
    assert_eq!(
        init,
        json!({
            "protocol": "obi-plugin/0.1",
            "obid": {"version": env!("CARGO_PKG_VERSION")},
            "plugin": {"id": "context-test", "dataDir": data_dir.to_str().unwrap()},
            "config": {}
        })
    );
    assert!(data_dir.join("tmp").is_dir());

    // Pinged, it stays ready, in its first process.
    tokio::time::sleep(Duration::from_millis(1200)).await;
    assert_eq!(status(&host, "context-test").state, PluginState::Ready);
    assert_eq!(home.starts("context-test"), 1);
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn a_plugin_that_exits_is_restarted_and_failed_at_its_third_failure_in_a_row() {
    let home = Home::new("exits");
    home.install("context-test", "context-test");
    let host = host_with(&home, options()).await;
    let first = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"afterReady": "exit"})),
        )
        .await
        .unwrap();
    if !sandbox_made(&first) {
        return;
    }
    let failed = wait_for_state(&host, "context-test", PluginState::Failed, LONG).await;
    // The first start and two restarts.
    assert_eq!(home.starts("context-test"), 3);
    let reason = failed.last_error.unwrap();
    assert!(reason.contains("exited"), "{reason}");
    assert!(reason.contains("3 times in a row"), "{reason}");
    assert!(failed.enabled);

    // It stays stopped.
    tokio::time::sleep(Duration::from_millis(1000)).await;
    assert_eq!(home.starts("context-test"), 3);
    assert_eq!(status(&host, "context-test").state, PluginState::Failed);

    // Until the owner enables it again: now it fails only on its first start.
    let again = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"afterReady": "exit", "failStarts": 4})),
        )
        .await
        .unwrap();
    assert!(again.state != PluginState::Disabled);
    assert!(wait_until(LONG, || home.starts("context-test") == 5).await);
    wait_for_state(&host, "context-test", PluginState::Ready, LONG).await;
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert_eq!(status(&host, "context-test").state, PluginState::Ready);
    assert_eq!(home.starts("context-test"), 5);
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn a_failed_plugin_stays_stopped_when_obid_starts_again() {
    let home = Home::new("failedkept");
    home.install("context-test", "context-test");
    let host = host_with(&home, options()).await;
    let first = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"afterReady": "exit"})),
        )
        .await
        .unwrap();
    if !sandbox_made(&first) {
        return;
    }
    let failed = wait_for_state(&host, "context-test", PluginState::Failed, LONG).await;
    let reason = failed.last_error.unwrap();
    let kept = || {
        home.settings()
            .and_then(|s| s["context-test"]["failed"].as_str().map(str::to_owned))
    };
    assert!(
        wait_until(LONG, || kept().is_some()).await,
        "{:?}",
        home.settings()
    );
    assert_eq!(kept().as_deref(), Some(reason.as_str()));
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
    assert_eq!(home.starts("context-test"), 3);

    // obid starts again: it is listed as failed, with its reason, and not started.
    let host = host_with(&home, options()).await;
    let listed = status(&host, "context-test");
    assert_eq!(listed.state, PluginState::Failed);
    assert!(listed.enabled);
    assert_eq!(listed.last_error.as_deref(), Some(reason.as_str()));
    tokio::time::sleep(Duration::from_millis(1000)).await;
    assert_eq!(home.starts("context-test"), 3);
    assert_eq!(status(&host, "context-test").state, PluginState::Failed);

    // Until the owner enables it again (its fourth start answers, and stays).
    let again = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"afterReady": "exit", "failStarts": 3})),
        )
        .await
        .unwrap();
    assert_eq!(again.state, PluginState::Ready, "{again:?}");
    assert_eq!(home.starts("context-test"), 4);
    assert_eq!(kept(), None);
    assert_eq!(
        home.settings().unwrap()["context-test"]["enabled"],
        json!(true)
    );
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;

    // Disabling it also takes `failed` out, and a disabled plug-in is listed as disabled.
    let home = Home::new("faileddisabled");
    home.install("context-test", "context-test");
    std::fs::write(
        home.path.join("plugins.json"),
        r#"{"context-test": {"enabled": false, "failed": "an old reason"}}"#,
    )
    .unwrap();
    let host = host_with(&home, options()).await;
    assert_eq!(status(&host, "context-test").state, PluginState::Disabled);
    assert_eq!(status(&host, "context-test").last_error, None);
    host.set_enabled(&id("context-test"), false, None)
        .await
        .unwrap();
    assert_eq!(
        home.settings().unwrap(),
        json!({"context-test": {"enabled": false}})
    );
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn a_plugin_that_does_not_answer_initialize_in_time_is_restarted_then_failed() {
    let home = Home::new("silent");
    home.install("context-test", "context-test");
    let host = host_with(
        &home,
        Options {
            // Long enough for a loaded machine to start it; it never answers anyway.
            initialize_timeout: Duration::from_millis(1500),
            ..options()
        },
    )
    .await;
    let first = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"initialize": "silent"})),
        )
        .await
        .unwrap();
    if !sandbox_made(&first) {
        return;
    }
    let failed = wait_for_state(&host, "context-test", PluginState::Failed, LONG).await;
    assert_eq!(home.starts("context-test"), 3);
    let reason = failed.last_error.unwrap();
    assert!(reason.contains("no answer to initialize"), "{reason}");
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn an_answer_that_is_not_obi_plugin_0_1_fails_initialize() {
    for (mode, says) in [
        ("wrong-protocol", "obi-plugin/9"),
        ("extra-kind", "Events"),
        ("crash", "exited before answering initialize"),
    ] {
        let home = Home::new(mode);
        home.install("context-test", "context-test");
        let host = host_with(&home, options()).await;
        let first = host
            .set_enabled(&id("context-test"), true, Some(json!({"initialize": mode})))
            .await
            .unwrap();
        if !sandbox_made(&first) {
            return;
        }
        let failed = wait_for_state(&host, "context-test", PluginState::Failed, LONG).await;
        let reason = failed.last_error.unwrap();
        assert!(reason.contains(says), "{mode}: {reason}");
        assert_eq!(home.starts("context-test"), 3, "{mode}");
        host.shutdown().await;
        assert_no_slirp4netns_left(&home).await;
    }
}

#[tokio::test]
async fn a_ping_not_answered_restarts_it() {
    let home = Home::new("ping");
    home.install("context-test", "context-test");
    let host = host_with(&home, options()).await;
    let first = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"ping": "silent", "failStarts": 1})),
        )
        .await
        .unwrap();
    if !sandbox_made(&first) {
        return;
    }
    assert_eq!(first.state, PluginState::Ready);
    // Its first process never answers a ping: it is restarted, and the second one does.
    assert!(wait_until(LONG, || home.starts("context-test") == 2).await);
    wait_for_state(&host, "context-test", PluginState::Ready, LONG).await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let now = status(&host, "context-test");
    assert_eq!(now.state, PluginState::Ready);
    assert_eq!(home.starts("context-test"), 2);
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn an_answered_ping_starts_the_count_again() {
    let home = Home::new("count");
    home.install("context-test", "context-test");
    let host = host_with(&home, options()).await;
    // Six starts in a row each answer a ping and then exit: never three failures in a row
    // without an answered ping between them, so it is never failed.
    let first = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"exitAfterPings": 1, "failStarts": 6})),
        )
        .await
        .unwrap();
    if !sandbox_made(&first) {
        return;
    }
    assert!(
        wait_until(Duration::from_secs(30), || home.starts("context-test") == 7).await,
        "{} starts",
        home.starts("context-test")
    );
    wait_for_state(&host, "context-test", PluginState::Ready, LONG).await;
    tokio::time::sleep(Duration::from_millis(1000)).await;
    assert_eq!(status(&host, "context-test").state, PluginState::Ready);
    assert_eq!(home.starts("context-test"), 7);
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn disabling_sends_shutdown_and_ends_what_it_started() {
    let home = Home::new("disable");
    home.install("context-test", "context-test");
    let host = host_with(&home, options()).await;
    let ready = host
        .set_enabled(&id("context-test"), true, Some(json!({"spawnChild": true})))
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    assert!(wait_until(LONG, || beats(&home, "context-test") > 0).await);

    let started = Instant::now();
    let disabled = host
        .set_enabled(&id("context-test"), false, None)
        .await
        .unwrap();
    assert!(
        started.elapsed() < Duration::from_millis(1400),
        "{:?}",
        started.elapsed()
    );
    assert_eq!(disabled.state, PluginState::Disabled);
    assert!(!disabled.enabled);
    assert_eq!(home.record("context-test", "shutdown"), Some(json!(true)));
    assert_stopped_beating(&home, "context-test").await;
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn a_plugin_still_running_after_shutdown_is_killed_with_what_it_started() {
    let home = Home::new("kill");
    home.install("context-test", "context-test");
    let host = host_with(&home, options()).await;
    let ready = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"shutdown": "ignore", "spawnChild": true})),
        )
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    assert!(wait_until(LONG, || beats(&home, "context-test") > 0).await);
    let started = Instant::now();
    host.set_enabled(&id("context-test"), false, None)
        .await
        .unwrap();
    let took = started.elapsed();
    // The grace (1.5 s here, 5 s by default), then killed.
    assert!(took >= Duration::from_millis(1400), "{took:?}");
    assert!(took < Duration::from_secs(6), "{took:?}");
    assert_eq!(home.record("context-test", "shutdown"), Some(json!(true)));
    assert_stopped_beating(&home, "context-test").await;
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn shutdown_stops_every_plugin() {
    let home = Home::new("shutdown");
    home.install("context-test", "context-test");
    home.install("events-test", "events-test");
    let host = host_with(&home, options()).await;
    for plugin in ["context-test", "events-test"] {
        let ready = host
            .set_enabled(&id(plugin), true, Some(json!({"spawnChild": true})))
            .await
            .unwrap();
        if !sandbox_made(&ready) {
            return;
        }
    }
    assert!(
        wait_until(LONG, || beats(&home, "context-test") > 0
            && beats(&home, "events-test") > 0)
        .await
    );
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
    for plugin in ["context-test", "events-test"] {
        assert_eq!(
            home.record(plugin, "shutdown"),
            Some(json!(true)),
            "{plugin}"
        );
        assert_stopped_beating(&home, plugin).await;
        // Still enabled for the next start; nothing runs now.
        let now = status(&host, plugin);
        assert!(now.enabled);
        assert_eq!(now.state, PluginState::Disabled);
    }

    // The next host starts them again by itself.
    let host = host_with(&home, options()).await;
    for plugin in ["context-test", "events-test"] {
        wait_for_state(&host, plugin, PluginState::Ready, LONG).await;
        assert_eq!(home.starts(plugin), 2);
    }
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn enabling_again_restarts_it_only_for_other_settings() {
    let home = Home::new("again");
    home.install("context-test", "context-test");
    let host = host_with(&home, options()).await;
    let ready = host
        .set_enabled(&id("context-test"), true, Some(json!({})))
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    host.set_enabled(&id("context-test"), true, None)
        .await
        .unwrap();
    host.set_enabled(&id("context-test"), true, Some(json!({})))
        .await
        .unwrap();
    assert_eq!(home.starts("context-test"), 1);
    let restarted = host
        .set_enabled(&id("context-test"), true, Some(json!({"stderrLines": 1})))
        .await
        .unwrap();
    assert_eq!(restarted.state, PluginState::Ready);
    assert_eq!(home.starts("context-test"), 2);
    assert_eq!(
        home.record("context-test", "initialize.json").unwrap()["config"],
        json!({"stderrLines": 1})
    );
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn a_plugin_that_floods_stderr_does_not_stop() {
    let home = Home::new("stderr");
    home.install("context-test", "context-test");
    let host = host_with(&home, options()).await;
    // 1,000 lines of 1,000 bytes: past the log's 64 KB a minute, which drops the rest.
    let ready = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"stderrLines": 1000})),
        )
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    assert_eq!(ready.state, PluginState::Ready);
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert_eq!(status(&host, "context-test").state, PluginState::Ready);
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn a_run_command_outside_its_folder_is_failed() {
    let home = Home::new("command");
    home.install("context-test", "context-test");
    let mut manifest: Value = serde_json::from_str(
        &std::fs::read_to_string(home.plugin_dir("context-test").join("obi-plugin.json")).unwrap(),
    )
    .unwrap();
    manifest["run"]["command"] = json!("bin/missing");
    home.install_manifest("context-test", &manifest);
    // A link out of the folder is not inside it either.
    let outside = home.path.join("outside");
    std::fs::write(&outside, "#!/bin/sh\n").unwrap();
    std::os::unix::fs::symlink(&outside, home.plugin_dir("context-test").join("bin/link")).unwrap();

    let host = host_with(&home, options()).await;
    let failed = host
        .set_enabled(&id("context-test"), true, None)
        .await
        .unwrap();
    if !sandbox_made(&failed) {
        return;
    }
    assert_eq!(failed.state, PluginState::Failed);
    assert!(failed.last_error.unwrap().contains("bin/missing"));
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;

    manifest["run"]["command"] = json!("bin/link");
    home.install_manifest("context-test", &manifest);
    let host = host_with(&home, options()).await;
    let failed = host
        .set_enabled(&id("context-test"), true, None)
        .await
        .unwrap();
    assert_eq!(failed.state, PluginState::Failed);
    assert!(failed.last_error.unwrap().contains("not a file inside"));
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

#[tokio::test]
async fn without_a_sandbox_a_plugin_with_a_process_is_not_started() {
    let home = Home::new("nosandbox");
    home.install("context-test", "context-test");
    home.install_manifest(
        "mcp-only",
        &json!({
            "manifest": "obi-plugin/0.1", "id": "mcp-only", "name": "MCP only", "version": "1",
            "kinds": ["agent-mcp"],
            "agentMcp": {"server": {"type": "http", "url": "https://mcp.example.test/"}, "allowedTools": ["a"]}
        }),
    );
    let host = host_with(
        &home,
        Options {
            sandbox_program: Some(PathBuf::from("/nonexistent/sandbox-tool")),
            ..options()
        },
    )
    .await;
    let failed = host
        .set_enabled(&id("context-test"), true, None)
        .await
        .unwrap();
    assert_eq!(failed.state, PluginState::Failed);
    let reason = failed.last_error.unwrap();
    assert!(
        reason.starts_with("can't make the plug-in's sandbox"),
        "{reason}"
    );
    assert!(reason.contains("/nonexistent/sandbox-tool"), "{reason}");
    assert_eq!(home.starts("context-test"), 0);

    // A plug-in with no process needs no sandbox.
    let ready = host.set_enabled(&id("mcp-only"), true, None).await.unwrap();
    assert_eq!(ready.state, PluginState::Ready);
    assert_eq!(host.agent_mcp_servers().len(), 1);
    assert_eq!(status(&host, "mcp-only").kinds, [Kind::AgentMcp]);
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

/// The child the test plug-in started has stopped appending to `beats`.
async fn assert_stopped_beating(home: &Home, plugin: &str) {
    assert_file_stopped_growing(home, plugin, "beats").await;
}

/// `file` in `plugin`'s data folder has stopped growing: what appends to it has ended.
async fn assert_file_stopped_growing(home: &Home, plugin: &str, file: &str) {
    tokio::time::sleep(Duration::from_millis(300)).await;
    let before = size(home, plugin, file);
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert_eq!(
        size(home, plugin, file),
        before,
        "what {plugin} started is still appending to {file}"
    );
}

/// `file` in `plugin`'s data folder is still growing: what appends to it still runs.
async fn assert_file_growing(home: &Home, plugin: &str, file: &str) {
    let before = size(home, plugin, file);
    assert!(
        wait_until(LONG, || size(home, plugin, file) > before).await,
        "nothing appends to {plugin}'s {file} any more"
    );
}

fn size(home: &Home, plugin: &str, file: &str) -> u64 {
    std::fs::metadata(home.data_dir(plugin).join(file))
        .map(|m| m.len())
        .unwrap_or(0)
}

/// Waits until the process start `start` of `plugin` started with `spawnDetached` has left the
/// plug-in's session and been orphaned (its parent is process 1: launchd, or the first process
/// of the sandbox's PID namespace), and is appending to its `detached-beats-<start>`.
async fn wait_for_detached(home: &Home, plugin: &str, start: usize) {
    let marker = home.data_dir(plugin).join(format!("detached-{start}"));
    assert!(
        wait_until(LONG, || marker.is_file()).await,
        "{plugin}'s start {start} started no detached process"
    );
    let said = std::fs::read_to_string(&marker).unwrap();
    assert!(said.contains(" ppid=1"), "{said}");
    assert!(!said.starts_with("sid=-1"), "setsid failed: {said}");
    let beats = format!("detached-beats-{start}");
    assert!(
        wait_until(LONG, || size(home, plugin, &beats) > 0).await,
        "{plugin}'s detached process doesn't run"
    );
}

/// A plug-in that kills its watcher, then is disabled, leaves nothing it started, including
/// a process that called `setsid` (#461).
#[tokio::test]
async fn killing_the_watcher_then_disabling_ends_what_left_its_session() {
    let home = Home::new("kill-watcher");
    home.install("context-test", "context-test");
    let host = host_with(&home, options()).await;
    let ready = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"killWatcher": true})),
        )
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    wait_for_detached(&home, "context-test", 1).await;
    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
    let _ = host.set_enabled(&id("context-test"), false, None).await;
    assert_file_stopped_growing(&home, "context-test", "detached-beats-1").await;
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

/// A plug-in disabled leaves nothing it started running, also a process that called `setsid`
/// and was orphaned (docs/ARCHITECTURE.md 5.3, step 6), and nothing another plug-in started is
/// touched.
#[tokio::test]
async fn disabling_ends_what_left_its_session_and_nothing_of_another_plugin() {
    let home = Home::new("detached-disable");
    home.install("context-test", "context-test");
    home.install("events-test", "events-test");
    let host = host_with(&home, options()).await;
    for plugin in ["context-test", "events-test"] {
        let ready = host
            .set_enabled(&id(plugin), true, Some(json!({"spawnDetached": true})))
            .await
            .unwrap();
        if !sandbox_made(&ready) {
            return;
        }
        assert_eq!(ready.state, PluginState::Ready, "{ready:?}");
        wait_for_detached(&home, plugin, 1).await;
    }
    host.set_enabled(&id("context-test"), false, None)
        .await
        .unwrap();
    assert_file_stopped_growing(&home, "context-test", "detached-beats-1").await;
    assert_file_growing(&home, "events-test", "detached-beats-1").await;
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
    assert_file_stopped_growing(&home, "events-test", "detached-beats-1").await;
}

/// `obid` shutting down leaves nothing running that its plug-ins started, also processes that
/// called `setsid`: of a plug-in that stops when asked, and of one that has to be killed.
#[tokio::test]
async fn shutdown_ends_what_left_its_session() {
    let home = Home::new("detached-shutdown");
    home.install("context-test", "context-test");
    home.install("events-test", "events-test");
    let host = host_with(&home, options()).await;
    for (plugin, config) in [
        ("context-test", json!({"spawnDetached": true})),
        (
            "events-test",
            json!({"spawnDetached": true, "shutdown": "ignore"}),
        ),
    ] {
        let ready = host
            .set_enabled(&id(plugin), true, Some(config))
            .await
            .unwrap();
        if !sandbox_made(&ready) {
            return;
        }
        wait_for_detached(&home, plugin, 1).await;
    }
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
    for plugin in ["context-test", "events-test"] {
        assert_eq!(
            home.record(plugin, "shutdown"),
            Some(json!(true)),
            "{plugin}"
        );
        assert_file_stopped_growing(&home, plugin, "detached-beats-1").await;
    }
}

/// Each time a plug-in fails, what it started ends with it, also what called `setsid`: when it
/// exits by itself, and when the host ends it because it didn't answer a ping.
#[tokio::test]
async fn a_failed_start_leaves_nothing_running() {
    for (name, config) in [
        (
            "exits",
            json!({"spawnDetached": true, "afterReady": "exit", "failStarts": 1}),
        ),
        (
            "silent",
            json!({"spawnDetached": true, "ping": "silent", "failStarts": 1}),
        ),
    ] {
        let home = Home::new(&format!("detached-fail-{name}"));
        home.install("context-test", "context-test");
        let host = host_with(&home, options()).await;
        let ready = host
            .set_enabled(&id("context-test"), true, Some(config))
            .await
            .unwrap();
        if !sandbox_made(&ready) {
            return;
        }
        wait_for_detached(&home, "context-test", 1).await;
        // The first start fails and the second stays.
        wait_for_detached(&home, "context-test", 2).await;
        wait_for_state(&host, "context-test", PluginState::Ready, LONG).await;
        assert_file_stopped_growing(&home, "context-test", "detached-beats-1").await;
        assert_file_growing(&home, "context-test", "detached-beats-2").await;
        host.shutdown().await;
        assert_no_slirp4netns_left(&home).await;
        assert_file_stopped_growing(&home, "context-test", "detached-beats-2").await;
    }
}

/// docs/ARCHITECTURE.md 5.3, step 5, with its own times: after its first failure in a row a
/// plug-in is restarted after 1 second, after its second after 2 seconds, and its third
/// failure in a row makes it `failed`, with no fourth start.
#[tokio::test]
async fn the_restart_policy_is_one_second_then_two_then_failed() {
    let home = Home::new("policy");
    home.install("context-test", "context-test");
    let host = host_with(
        &home,
        Options {
            restart_delays: Options::default().restart_delays,
            ..options()
        },
    )
    .await;
    let first = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"afterReady": "exit"})),
        )
        .await
        .unwrap();
    if !sandbox_made(&first) {
        return;
    }
    let failed = wait_for_state(&host, "context-test", PluginState::Failed, LONG).await;
    assert!(
        failed
            .last_error
            .as_deref()
            .unwrap()
            .contains("3 times in a row"),
        "{failed:?}"
    );
    // No fourth start, however long it waits.
    tokio::time::sleep(Duration::from_secs(3)).await;
    let starts: Vec<u128> = std::fs::read_to_string(home.data_dir("context-test").join("starts"))
        .unwrap()
        .lines()
        .map(|line| line.trim_start_matches("start ").parse().unwrap())
        .collect();
    assert_eq!(starts.len(), 3, "{starts:?}");
    // Each start exits 100 ms after it answers initialize; what is between two starts beyond
    // the wait is that, and the time to start one.
    let gaps = [starts[1] - starts[0], starts[2] - starts[1]];
    assert!((1000..1900).contains(&gaps[0]), "{gaps:?}");
    assert!((2000..2900).contains(&gaps[1]), "{gaps:?}");
    assert_eq!(status(&host, "context-test").state, PluginState::Failed);
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
}

/// Reads every process of this user (`KERN_PROCARGS2`) and writes the bytes to `argv[1]`.
#[cfg(target_os = "macos")]
const PROCARGS_C: &str = r#"
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc < 2) return 2;
  FILE *out = fopen(argv[1], "wb");
  if (!out) return 3;
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_UID, (int)getuid()};
  size_t size = 0;
  if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return 4;
  struct kinfo_proc *kp = malloc(size);
  if (!kp || sysctl(mib, 4, kp, &size, NULL, 0) != 0) return 5;
  int n = (int)(size / sizeof(*kp));
  for (int i = 0; i < n; i++) {
    int a[3] = {CTL_KERN, KERN_PROCARGS2, kp[i].kp_proc.p_pid};
    size_t asz = 0;
    if (sysctl(a, 3, NULL, &asz, NULL, 0) != 0 || asz == 0 || asz > 1024 * 1024) continue;
    char *buf = malloc(asz);
    if (!buf) continue;
    if (sysctl(a, 3, buf, &asz, NULL, 0) == 0) fwrite(buf, 1, asz, out);
    free(buf);
  }
  free(kp);
  fclose(out);
  return 0;
}
"#;

/// Seatbelt can't block `KERN_PROCARGS2`, so a sandboxed plug-in can read other processes. The
/// API token and a vault secret exist only as files, so neither string is in any process's
/// arguments or environment. A marker in another process's arguments is, which shows the read
/// worked (docs/ARCHITECTURE.md 5.3).
#[cfg(target_os = "macos")]
#[tokio::test]
async fn a_sandboxed_plugin_reads_other_processes_but_finds_no_secret() {
    let home = Home::new("procargs");
    home.install("context-test", "context-test");
    let nonce = format!(
        "{}{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos()
    );
    let marker = format!("obi439-marker-{nonce}");
    let token = format!("obi439token{nonce}{}", "b".repeat(24));
    let vault = format!("obi439vault{nonce}{}", "c".repeat(24));
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(home.path.join("api-token"))
            .unwrap();
        writeln!(file, "{token}").unwrap();
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(home.path.join("vault.secret"))
            .unwrap();
        writeln!(file, "{vault}").unwrap();
    }
    let src = home.plugin_dir("context-test").join("procargs.c");
    std::fs::write(&src, PROCARGS_C).unwrap();
    let bin = home.plugin_dir("context-test").join("bin").join("procargs");
    let compiled = std::process::Command::new("cc")
        .args(["-O2", "-o"])
        .arg(&bin)
        .arg(&src)
        .output()
        .expect("cc");
    assert!(
        compiled.status.success(),
        "cc: {}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    let dump_path = home.data_dir("context-test").join("procargs.out");
    let mut decoy = std::process::Command::new("/usr/bin/perl")
        .args(["-e", "sleep 60", &marker])
        .env("OBI_LEAK_MARKER", &marker)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let host = host_with(&home, options()).await;
    let ready = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({
                "probe": {"run": [[bin, dump_path]]}
            })),
        )
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        let _ = decoy.kill();
        let _ = decoy.wait();
        return;
    }
    let dump =
        std::fs::read(home.data_dir("context-test").join("procargs.out")).unwrap_or_default();
    let text = String::from_utf8_lossy(&dump);
    let probe = home.record("context-test", "probe.json");
    let _ = decoy.kill();
    let _ = decoy.wait();
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
    assert!(
        text.contains(&marker),
        "a sandboxed plug-in could not read another process ({} bytes): {probe:?}",
        dump.len()
    );
    assert!(
        !text.contains(&token),
        "the API token is in a process's arguments or environment"
    );
    assert!(
        !text.contains(&vault),
        "the vault secret is in a process's arguments or environment"
    );
}

/// A plug-in has its own network namespace: an abstract Unix socket outside is unreachable, and
/// a local HTTP endpoint still answers (docs/ARCHITECTURE.md 5.3).
#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_sandboxed_plugin_reaches_the_network_but_not_an_abstract_socket() {
    use std::io::{Read, Write};
    use std::os::linux::net::SocketAddrExt;
    use std::os::unix::net::{SocketAddr, UnixListener};

    let home = Home::new("abstract");
    home.install("context-test", "context-test");
    let name = format!("obid438p-{}", std::process::id());
    let addr = SocketAddr::from_abstract_name(name.as_bytes()).unwrap();
    let abstract_listener = UnixListener::bind_addr(&addr).unwrap();
    abstract_listener.set_nonblocking(true).unwrap();
    let http = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = http.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for _ in 0..2 {
            let (mut stream, _) = http.accept().unwrap();
            let mut buf = [0; 256];
            let _ = stream.read(&mut buf);
            let _ = stream.write_all(b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok");
        }
    });
    let script = format!(
        r#"
const net = require('net');
const http = require('http');
let abs = 'abstract no';
const s = net.connect('\0{name}');
s.on('connect', () => {{ abs = 'abstract ok'; s.end(); }});
s.on('error', () => {{}});
setTimeout(() => {{
  http.get('http://10.0.2.2:{port}/', (res) => {{
    console.log(abs);
    console.log('http ' + res.statusCode);
    process.exit(0);
  }}).on('error', () => {{
    console.log(abs);
    console.log('http no');
    process.exit(1);
  }});
}}, 300);
"#
    );
    // The same probe must reach this socket outside the sandbox. Without this control,
    // a malformed abstract address could make the isolation assertion pass vacuously.
    let control = std::process::Command::new("node")
        .args([
            "-e",
            &script.replace("http://10.0.2.2:", "http://127.0.0.1:"),
        ])
        .output()
        .unwrap();
    let control_text = String::from_utf8_lossy(&control.stdout);
    assert!(control.status.success(), "{control:?}");
    assert!(control_text.contains("abstract ok"), "{control:?}");
    assert!(control_text.contains("http 200"), "{control:?}");
    abstract_listener
        .accept()
        .expect("the host probe connected");
    let host = host_with(&home, options()).await;
    let ready = host
        .set_enabled(
            &id("context-test"),
            true,
            Some(json!({"probe": {"run": [["node", "-e", script]]}})),
        )
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    assert_eq!(ready.state, PluginState::Ready, "{ready:?}");
    let probe = home
        .record("context-test", "probe.json")
        .expect("the plug-in probed");
    host.shutdown().await;
    assert_no_slirp4netns_left(&home).await;
    // Read the command's output, not the object key (which contains the probe's source).
    let result = probe.as_object().unwrap().values().next().unwrap();
    assert_eq!(result["ok"], true, "{result}");
    let text = result["got"].as_str().unwrap();
    assert!(
        text.contains("abstract no"),
        "the plug-in reached an abstract socket\n{text}"
    );
    assert!(
        text.contains("http 200"),
        "the plug-in didn't reach the local endpoint\n{text}"
    );
    assert_eq!(
        abstract_listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock,
        "the sandbox connected to the host's abstract socket"
    );
}
