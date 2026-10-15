//! What the host's tests share: a home of their own, the test plug-ins (`tests/plugins/`, one of
//! each kind, all run by the `obi-plugin-test` program) installed into it, and short times.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use obi_plugin_api::{PluginState, PluginStatus};
use obi_plugin_host::{Options, PluginHost, PluginId};
use serde_json::Value;

/// Set (to anything) where the sandbox must be made, as in the plug-ins workflow: then a test
/// fails when it can't be, instead of checking that the plug-in is `failed` for that reason.
pub const REQUIRE_SANDBOX: &str = "OBI_PLUGIN_HOST_REQUIRE_SANDBOX";

/// A home of the test's own, outside the person's real `HOME`, removed when the test ends.
pub struct Home {
    pub path: PathBuf,
}

impl Home {
    pub fn new(name: &str) -> Home {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "obi-plugin-host-{name}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Home {
            path: std::fs::canonicalize(&path).unwrap(),
        }
    }

    /// Installs the test plug-in `tests/plugins/<kind>` as `id`: its manifest (with `id`) and
    /// the test program as `bin/obi-plugin-test`.
    pub fn install(&self, kind: &str, id: &str) -> PathBuf {
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/plugins")
            .join(kind)
            .join("obi-plugin.json");
        let mut manifest: Value =
            serde_json::from_str(&std::fs::read_to_string(source).unwrap()).unwrap();
        manifest["id"] = Value::from(id);
        self.install_manifest(id, &manifest);
        let bin = self.plugin_dir(id).join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let program = bin.join("obi-plugin-test");
        std::fs::copy(env!("CARGO_BIN_EXE_obi-plugin-test"), &program).unwrap();
        warm_up(&program);
        self.plugin_dir(id)
    }

    /// Writes `home/plugins/<id>/obi-plugin.json` as given.
    pub fn install_manifest(&self, id: &str, manifest: &Value) {
        let dir = self.plugin_dir(id);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("obi-plugin.json"),
            serde_json::to_string_pretty(manifest).unwrap(),
        )
        .unwrap();
    }

    pub fn plugin_dir(&self, id: &str) -> PathBuf {
        self.path.join("plugins").join(id)
    }

    pub fn data_dir(&self, id: &str) -> PathBuf {
        self.path.join("plugin-data").join(id)
    }

    /// A JSON file the test plug-in `id` wrote into its data folder, when it has.
    pub fn record(&self, id: &str, file: &str) -> Option<Value> {
        let text = std::fs::read_to_string(self.data_dir(id).join(file)).ok()?;
        serde_json::from_str(&text).ok()
    }

    /// How many times the test plug-in `id` started.
    pub fn starts(&self, id: &str) -> usize {
        std::fs::read_to_string(self.data_dir(id).join("starts"))
            .map(|s| s.lines().count())
            .unwrap_or(0)
    }

    pub fn settings(&self) -> Option<Value> {
        let text = std::fs::read_to_string(self.path.join("plugins.json")).ok()?;
        Some(serde_json::from_str(&text).unwrap())
    }
}

/// Runs a program just copied once, outside any sandbox, with nothing on its stdin (the test
/// plug-in then ends at once), in a folder thrown away after. macOS checks a program the first
/// time it runs from a new place, which under load can take longer than the short
/// `initialize` time the tests give; paid here, it doesn't count against a test's first start.
fn warm_up(program: &Path) {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir().join(format!(
        "obi-plugin-host-warm-up-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let status = std::process::Command::new(program)
        .current_dir(&dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        status.is_ok_and(|s| s.success()),
        "{} doesn't run",
        program.display()
    );
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// Short times, so a test sees restarts and pings without waiting minutes.
pub fn options() -> Options {
    Options {
        initialize_timeout: Duration::from_secs(5),
        ping_interval: Duration::from_millis(300),
        ping_timeout: Duration::from_millis(700),
        context_timeout: Duration::from_millis(1500),
        restart_delays: vec![
            Duration::from_millis(100),
            Duration::from_millis(200),
            Duration::from_millis(400),
        ],
        stop_grace: Duration::from_millis(1500),
        sandbox_program: None,
    }
}

pub fn id(id: &str) -> PluginId {
    PluginId::new(id).unwrap()
}

pub fn status(host: &PluginHost, id: &str) -> PluginStatus {
    host.list()
        .into_iter()
        .find(|status| status.id.as_str() == id)
        .unwrap_or_else(|| panic!("{id} is not listed"))
}

/// Waits up to `limit` for `done`, checking every 50 ms.
pub async fn wait_until(limit: Duration, mut done: impl FnMut() -> bool) -> bool {
    let end_at = tokio::time::Instant::now() + limit;
    loop {
        if done() {
            return true;
        }
        if tokio::time::Instant::now() >= end_at {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Waits for `id` to be in `state`, and answers its status then.
pub async fn wait_for_state(
    host: &PluginHost,
    id: &str,
    state: PluginState,
    limit: Duration,
) -> PluginStatus {
    let reached = wait_until(limit, || status(host, id).state == state).await;
    let now = status(host, id);
    assert!(reached, "{id} never became {state:?}: {now:?}");
    now
}

/// Whether the plug-in sandbox can be made on this machine. When it can't, a plug-in with a
/// process must be `failed` with the reason, which this checks (the specified behavior on such
/// a machine), unless [`REQUIRE_SANDBOX`] is set, which makes it a failure.
pub fn sandbox_made(status: &PluginStatus) -> bool {
    let missing = status.state == PluginState::Failed
        && status
            .last_error
            .as_deref()
            .is_some_and(|reason| reason.starts_with("can't make the plug-in's sandbox"));
    if missing {
        assert!(
            std::env::var_os(REQUIRE_SANDBOX).is_none(),
            "the sandbox must be made here, and it can't be: {status:?}"
        );
        eprintln!(
            "NOTE: no plug-in sandbox on this machine, so the plug-in is failed, as specified: {:?}",
            status.last_error
        );
    }
    !missing
}

/// The file `beats` the test plug-in's child appends to while it runs, by length.
pub fn beats(home: &Home, id: &str) -> u64 {
    std::fs::metadata(home.data_dir(id).join("beats"))
        .map(|m| m.len())
        .unwrap_or(0)
}
