//! The host as `obid` sees it in this version, which finds no plug-ins (docs/ARCHITECTURE.md
//! 5.5): `list` is empty, `context` and `agent_mcp_servers` give nothing, `set_enabled` knows no
//! id, and the one event receiver yields nothing until `shutdown` ends it.

use std::path::PathBuf;
use std::time::Duration;

use obi_plugin_host::api::{ContextJob, ContextRequest, DEFAULT_MAX_BYTES, PluginError, Purpose};
use obi_plugin_host::{PluginHost, PluginId};
use serde_json::json;

/// A home of the test's own, empty, removed when it ends.
struct Home(PathBuf);

impl Home {
    fn new(name: &str) -> Home {
        let path = std::env::temp_dir().join(format!(
            "obi-plugin-host-test-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Home(path)
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn request() -> ContextRequest {
    ContextRequest {
        request_id: "q1".into(),
        purpose: Purpose::Review,
        job: ContextJob {
            id: "ab12cd34".into(),
            kind: "review".into(),
            repo: "obi-e2e/fixture-app".into(),
            pr: Some(12),
            ..Default::default()
        },
        max_bytes: DEFAULT_MAX_BYTES,
    }
}

#[tokio::test]
async fn an_empty_home_has_no_plugins() {
    let home = Home::new("empty");
    let host = PluginHost::start(&home.0).await.unwrap();
    assert!(host.list().is_empty());
    assert!(host.context(request()).await.is_empty());
    assert!(host.agent_mcp_servers().is_empty());
    host.shutdown().await;
}

#[tokio::test]
async fn enabling_a_plugin_it_did_not_find_is_unknown() {
    let home = Home::new("unknown");
    let host = PluginHost::start(&home.0).await.unwrap();
    let tetrix = PluginId::new("tetrix").unwrap();
    for (enabled, config) in [(true, None), (false, None), (true, Some(json!({})))] {
        assert_eq!(
            host.set_enabled(&tetrix, enabled, config).await,
            Err(PluginError::Unknown(tetrix.clone()))
        );
    }
    // Nothing was enabled, and nothing was written to home.
    assert!(host.list().is_empty());
    assert_eq!(std::fs::read_dir(&home.0).unwrap().count(), 0);
    host.shutdown().await;
}

#[tokio::test]
async fn take_events_hands_the_receiver_over_once() {
    let home = Home::new("take");
    let host = PluginHost::start(&home.0).await.unwrap();
    let receiver = host.take_events();
    assert!(receiver.is_some());
    assert!(host.take_events().is_none());
    assert!(host.take_events().is_none());
    host.shutdown().await;
}

#[tokio::test]
async fn the_receiver_yields_nothing_and_ends_only_after_shutdown() {
    let home = Home::new("events");
    let host = PluginHost::start(&home.0).await.unwrap();
    let mut events = host.take_events().unwrap();

    // Before shutdown: nothing arrives, and the receiver hasn't ended.
    let waited = tokio::time::timeout(Duration::from_millis(300), events.recv()).await;
    assert!(waited.is_err(), "the receiver yielded {waited:?}");
    assert!(!events.is_closed());

    host.shutdown().await;
    let ended = tokio::time::timeout(Duration::from_secs(5), events.recv()).await;
    assert_eq!(ended.unwrap(), None);

    // A second shutdown does nothing, and the host still answers.
    host.shutdown().await;
    assert!(host.list().is_empty());
    assert!(host.take_events().is_none());
}

#[tokio::test]
async fn shutdown_before_take_events_still_hands_over_an_ended_receiver() {
    let home = Home::new("late");
    let host = PluginHost::start(&home.0).await.unwrap();
    host.shutdown().await;
    let mut events = host.take_events().unwrap();
    assert_eq!(events.recv().await, None);
}

#[tokio::test]
async fn obid_can_share_one_host_between_tasks() {
    fn shareable<T: Send + Sync + 'static>() {}
    shareable::<PluginHost>();

    let home = Home::new("shared");
    let host = std::sync::Arc::new(PluginHost::start(&home.0).await.unwrap());
    let task = {
        let host = host.clone();
        tokio::spawn(async move { host.context(request()).await })
    };
    assert!(task.await.unwrap().is_empty());
    host.shutdown().await;
}
