//! The host logs only to the `tracing` target `obi_plugin`, where `obid`'s log layer takes the
//! vault's secrets out before anything is written (docs/ARCHITECTURE.md 5.4), and writes no log
//! of its own: a plug-in's stderr, its `log` notifications and the host's own words about it
//! all go to that target, and nothing but `plugins.json` and the plug-ins' folders appears in
//! `obid`'s home.

mod common;

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use common::{Home, id, options, sandbox_made, wait_for_state};
use obi_plugin_api::PluginState;
use obi_plugin_host::PluginHost;
use serde_json::json;
use tracing::span::{Attributes, Id, Record};
use tracing::{Event, Metadata, Subscriber};

/// A subscriber that keeps the target of every event, and nothing else.
struct Targets {
    seen: Arc<Mutex<Vec<String>>>,
    next: AtomicU64,
}

impl Subscriber for Targets {
    fn enabled(&self, _: &Metadata<'_>) -> bool {
        true
    }
    fn new_span(&self, _: &Attributes<'_>) -> Id {
        Id::from_u64(self.next.fetch_add(1, Ordering::Relaxed) + 1)
    }
    fn record(&self, _: &Id, _: &Record<'_>) {}
    fn record_follows_from(&self, _: &Id, _: &Id) {}
    fn event(&self, event: &Event<'_>) {
        self.seen
            .lock()
            .unwrap()
            .push(event.metadata().target().to_owned());
    }
    fn enter(&self, _: &Id) {}
    fn exit(&self, _: &Id) {}
}

#[tokio::test]
async fn the_host_logs_only_to_the_obi_plugin_target() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    tracing::subscriber::set_global_default(Targets {
        seen: seen.clone(),
        next: AtomicU64::new(0),
    })
    .unwrap();

    let home = Home::new("logging");
    home.install("events-test", "events-test");
    home.install("context-test", "context-test");
    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    // stderr lines, a `log` notification, a method obid doesn't take, and a plug-in that fails.
    let ready = host
        .set_enabled(
            &id("events-test"),
            true,
            Some(json!({"stderrLines": 3, "emitUnasked": true})),
        )
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    host.set_enabled(
        &id("context-test"),
        true,
        Some(json!({"initialize": "crash"})),
    )
    .await
    .unwrap();
    wait_for_state(
        &host,
        "context-test",
        PluginState::Failed,
        std::time::Duration::from_secs(20),
    )
    .await;
    host.shutdown().await;

    let targets: BTreeSet<String> = seen.lock().unwrap().iter().cloned().collect();
    assert_eq!(targets, BTreeSet::from(["obi_plugin".to_owned()]));
    assert!(
        seen.lock().unwrap().len() >= 5,
        "{:?}",
        seen.lock().unwrap()
    );

    let mut files: Vec<String> = std::fs::read_dir(&home.path)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    files.sort();
    assert_eq!(files, ["plugin-data", "plugins", "plugins.json"]);
}
