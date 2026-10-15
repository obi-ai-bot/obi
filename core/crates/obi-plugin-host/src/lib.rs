//! The plug-in host: all `obid` calls to find, start, sandbox and talk to plug-ins
//! (docs/ARCHITECTURE.md 5.3 and 5.5). `obid` makes one [`PluginHost`] at start, takes its event
//! receiver once, serves `GET /v1/obid/plugins` with [`PluginHost::list`] and
//! `PUT /v1/obid/plugins/{id}` with [`PluginHost::set_enabled`], and calls
//! [`PluginHost::shutdown`] when it stops.
//!
//! - **Discovered.** [`PluginHost::start`] reads every `home/plugins/<id>/obi-plugin.json`. A
//!   manifest that doesn't parse or match is listed with `state` `failed` and its reason; a
//!   folder whose name is not a plug-in id is left out.
//! - **Enabled or not.** Only [`PluginHost::set_enabled`] enables one, and it keeps the choice
//!   and the owner's settings in `home/plugins.json`. Disabled is the default for every plug-in:
//!   a home with no `plugins.json` runs none.
//! - **Started.** An enabled plug-in with `run` is started in its sandbox (bubblewrap on Linux,
//!   Seatbelt on macOS; see the `sandbox` module). When the sandbox can't be made, it isn't
//!   started and its `state` is `failed`, with the reason. An enabled `agent-mcp` plug-in
//!   without `run` has no process: it is `ready` at once.
//! - **Initialized.** `initialize`, answered within 10 seconds, makes it `ready`.
//! - **Running.** `ping` every 60 seconds. A plug-in that doesn't answer `initialize` or a ping
//!   within its time, or exits, has failed. After its first failure in a row it is restarted
//!   after 1 second, after its second after 2 seconds, and its third failure in a row makes its
//!   `state` `failed`: it stays stopped until the owner enables it again, across `obid` restarts
//!   too (`home/plugins.json` keeps that it failed). An answered ping ends the run of failures.
//! - **Stopped.** On disable and at shutdown: `shutdown`, then stdin closes; a plug-in still
//!   running 5 seconds after `shutdown` was sent is killed. Either way no process it started is
//!   left running, also none that left its process group or session (`setsid`): on Linux the
//!   sandbox's PID namespace ends with it, on macOS the sandbox's watcher kills every process in
//!   the sandbox (see the `sandbox` module). The same happens each time it fails.
//!
//! A plug-in never blocks Obi: [`PluginHost::start`] doesn't wait for plug-ins to come up, a
//! context query that fails or is late gives nothing, and a failed plug-in only shows in
//! [`PluginHost::list`].
//!
//! `home/plugins.json` holds one entry per plug-in the owner enabled or disabled:
//! `{"tetrix": {"enabled": true, "config": {}}}`, and `"failed": "<reason>"` in the entry of an
//! enabled plug-in that failed, which [`PluginHost::start`] then lists as `failed` without
//! starting it. Enabling or disabling it takes `failed` out. Entries for plug-ins that aren't
//! installed are kept as they are.

mod conn;
mod sandbox;
mod schema;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::process::Child;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

use obi_plugin_api::rpc::{self, Empty, InitializeParams, InitializeResult, method};
use obi_plugin_api::{
    ContextItem, ContextRequest, Kind, MANIFEST_FILE, Manifest, McpServerSpec, PROTOCOL,
    PluginError, PluginEvent, PluginState, limit_items,
};
pub use obi_plugin_api::{PluginId, PluginStatus};

use conn::{Conn, Peer};
use sandbox::{Launch, Sandbox};

/// How many accepted events wait for `obid` before a plug-in sending more is told to wait.
const EVENT_BUFFER: usize = 256;
/// The largest `obi-plugin.json` the host reads.
const MAX_MANIFEST_BYTES: u64 = 1 << 20;
/// The largest `plugins.json` the host reads.
const MAX_SETTINGS_BYTES: u64 = 4 << 20;

#[cfg(feature = "test-support")]
pub use options::Options;
#[cfg(not(feature = "test-support"))]
use options::Options;

mod options {
    use std::path::PathBuf;
    use std::time::Duration;

    /// The lifecycle's times and the sandbox tool. [`Options::default`] is docs/ARCHITECTURE.md
    /// 5.3 and 5.4, which is what [`PluginHost::start`](crate::PluginHost::start) uses. Only the
    /// host's own tests use others (shorter times, a missing sandbox tool), through the
    /// `test-support` feature: `obid` has no way to change them, and none to pick another sandbox
    /// tool.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct Options {
        /// How long a plug-in has to answer `initialize`: 10 seconds.
        pub initialize_timeout: Duration,
        /// How often a ready plug-in is pinged: every 60 seconds.
        pub ping_interval: Duration,
        /// How long it has to answer a ping: 5 seconds.
        pub ping_timeout: Duration,
        /// How long it has to answer `context/query`: 5 seconds.
        pub context_timeout: Duration,
        /// The waits before each restart in a row: 1, then 2 seconds. A failure with no wait
        /// left (the third in a row) makes the plug-in `failed`.
        pub restart_delays: Vec<Duration>,
        /// How long after `shutdown` a plug-in still running is killed: 5 seconds.
        pub stop_grace: Duration,
        /// The sandbox tool, when not the system's: `None` is `/usr/bin/sandbox-exec` on macOS and
        /// `bwrap` on `PATH` on Linux.
        pub sandbox_program: Option<PathBuf>,
    }

    impl Default for Options {
        fn default() -> Options {
            Options {
                initialize_timeout: Duration::from_secs(10),
                ping_interval: Duration::from_secs(60),
                ping_timeout: Duration::from_secs(5),
                context_timeout: Duration::from_secs(5),
                restart_delays: vec![Duration::from_secs(1), Duration::from_secs(2)],
                stop_grace: Duration::from_secs(5),
                sandbox_program: None,
            }
        }
    }
}

/// The plug-ins `obid` found in `home/plugins/`, and the ones it runs.
pub struct PluginHost {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for PluginHost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PluginHost")
            .field("home", &self.inner.home)
            .field("plugins", &self.list())
            .finish()
    }
}

struct Inner {
    /// `obid`'s home, resolved: plug-ins live in `home/plugins/<id>/`, their data in
    /// `home/plugin-data/<id>/`, and which are enabled in `home/plugins.json`.
    home: PathBuf,
    /// The person's real `HOME`, resolved, which the sandbox hides.
    real_home: Option<PathBuf>,
    options: Options,
    plugins: BTreeMap<PluginId, Arc<Plugin>>,
    /// `home/plugins.json`. Held while a plug-in is enabled or disabled, so those happen one
    /// at a time.
    settings: tokio::sync::Mutex<Settings>,
    events: Mutex<Events>,
    sandbox: tokio::sync::OnceCell<Result<Sandbox, String>>,
    closed: AtomicBool,
}

/// The one channel every plug-in's accepted events go to.
struct Events {
    /// Dropped at shutdown, which (with the connections' copies, dropped as they end) is what
    /// ends the receiver.
    sender: Option<mpsc::Sender<PluginEvent>>,
    /// Handed over by the first `take_events`.
    receiver: Option<mpsc::Receiver<PluginEvent>>,
}

/// One folder under `home/plugins/`.
struct Plugin {
    id: PluginId,
    dir: PathBuf,
    data_dir: PathBuf,
    found: Found,
    peer: Arc<Peer>,
    live: Mutex<Live>,
    /// Bumped on every change of `live`'s state, for [`PluginHost::set_enabled`] to wait on.
    changes: watch::Sender<u64>,
    supervisor: tokio::sync::Mutex<Option<Supervisor>>,
}

enum Found {
    Valid(Box<Manifest>),
    /// What could be read of a manifest that doesn't parse or match, and why.
    Invalid {
        name: String,
        version: String,
        kinds: Vec<Kind>,
        reason: String,
    },
}

struct Live {
    enabled: bool,
    config: Value,
    state: PluginState,
    last_error: Option<String>,
    /// The kinds it serves now: its `initialize` answer, or the manifest's for a plug-in with
    /// no process.
    served: Vec<Kind>,
    conn: Option<Arc<Conn>>,
    /// How many start attempts have ended, either way.
    resolved: u64,
}

struct Supervisor {
    stop: watch::Sender<bool>,
    task: JoinHandle<()>,
}

impl PluginHost {
    /// Discovers the plug-ins in `home/plugins/` and starts the enabled ones, without waiting
    /// for them to be ready, with docs/ARCHITECTURE.md 5.3's and 5.4's times and the system's
    /// sandbox tool.
    pub async fn start(home: &Path) -> Result<PluginHost, PluginError> {
        PluginHost::start_options(home, Options::default()).await
    }

    /// [`PluginHost::start`] with other times or another sandbox tool: for the host's own tests
    /// only (the `test-support` feature), not part of docs/ARCHITECTURE.md 5.5.
    #[cfg(feature = "test-support")]
    pub async fn start_with(home: &Path, options: Options) -> Result<PluginHost, PluginError> {
        PluginHost::start_options(home, options).await
    }

    async fn start_options(home: &Path, options: Options) -> Result<PluginHost, PluginError> {
        let home = std::fs::canonicalize(home).unwrap_or_else(|_| home.to_path_buf());
        let real_home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .and_then(|path| std::fs::canonicalize(path).ok())
            .filter(|path| path.parent().is_some());
        let settings = Settings::load(home.join("plugins.json"));
        let plugins = discover(&home);

        let (sender, receiver) = mpsc::channel(EVENT_BUFFER);
        let mut map = BTreeMap::new();
        for (id, found) in plugins {
            let (enabled, config) = settings.entry(&id);
            let failed_before = settings.failed(&id).filter(|_| enabled);
            let kinds = match &found {
                Found::Valid(manifest) => manifest.kinds.clone(),
                Found::Invalid { .. } => Vec::new(),
            };
            let event_kinds = match &found {
                Found::Valid(manifest) => manifest
                    .events
                    .as_ref()
                    .map(|events| events.kinds.clone())
                    .unwrap_or_default(),
                Found::Invalid { .. } => Vec::new(),
            };
            let (state, last_error) = match &found {
                Found::Invalid { reason, .. } => (PluginState::Failed, Some(reason.clone())),
                // It failed when obid last ran: it stays stopped until the owner enables it.
                Found::Valid(_) => match failed_before {
                    Some(reason) => (PluginState::Failed, Some(reason)),
                    None => (PluginState::Disabled, None),
                },
            };
            let plugin = Plugin {
                dir: home.join("plugins").join(id.as_str()),
                data_dir: home.join("plugin-data").join(id.as_str()),
                peer: Arc::new(Peer::new(id.clone(), kinds, event_kinds)),
                found,
                live: Mutex::new(Live {
                    enabled,
                    config: config.unwrap_or_else(|| json!({})),
                    state,
                    last_error,
                    served: Vec::new(),
                    conn: None,
                    resolved: 0,
                }),
                changes: watch::Sender::new(0),
                supervisor: tokio::sync::Mutex::new(None),
                id: id.clone(),
            };
            map.insert(id, Arc::new(plugin));
        }

        let inner = Arc::new(Inner {
            home,
            real_home,
            options,
            plugins: map,
            settings: tokio::sync::Mutex::new(settings),
            events: Mutex::new(Events {
                sender: Some(sender),
                receiver: Some(receiver),
            }),
            sandbox: tokio::sync::OnceCell::new(),
            closed: AtomicBool::new(false),
        });
        for plugin in inner.plugins.values() {
            let (enabled, failed) = {
                let live = lock(&plugin.live);
                (live.enabled, live.state == PluginState::Failed)
            };
            if enabled && !failed && matches!(plugin.found, Found::Valid(_)) {
                let config = lock(&plugin.live).config.clone();
                match plugin.check_config(&config) {
                    Ok(()) => inner.launch(plugin).await,
                    Err(reason) => plugin.update(|live| {
                        live.state = PluginState::Failed;
                        live.last_error = Some(format!(
                            "its saved settings don't match its config schema: {reason}"
                        ));
                    }),
                }
            }
        }
        Ok(PluginHost { inner })
    }

    /// Every plug-in found, enabled or not, by id: `GET /v1/obid/plugins`.
    pub fn list(&self) -> Vec<PluginStatus> {
        self.inner.plugins.values().map(|p| p.status()).collect()
    }

    /// Enables or disables one plug-in, with the owner's settings when given:
    /// `PUT /v1/obid/plugins/{id}`. [`PluginError::Unknown`] is that route's `404`,
    /// [`PluginError::Config`] its `422`; nothing is changed or kept then.
    ///
    /// The choice and the settings are kept in `home/plugins.json`. Settings left out keep the
    /// ones kept before, or `{}`; when enabling, those must match the schema too. Enabling
    /// answers once the plug-in is ready or its first start failed (at most the `initialize`
    /// time and the stop time); enabling one that is running with the same settings changes
    /// nothing, with other settings restarts it, and enabling a `failed` one starts it again.
    /// Disabling answers once it has stopped.
    pub async fn set_enabled(
        &self,
        id: &PluginId,
        enabled: bool,
        config: Option<serde_json::Value>,
    ) -> Result<PluginStatus, PluginError> {
        let inner = &self.inner;
        let plugin = inner
            .plugins
            .get(id)
            .ok_or_else(|| PluginError::Unknown(id.clone()))?;
        let mut settings = inner.settings.lock().await;
        if inner.closed.load(Ordering::SeqCst) {
            return Err(PluginError::Stopped);
        }
        let (_, saved) = settings.entry(id);

        if let Found::Invalid { reason, .. } = &plugin.found {
            if config.is_some() {
                return Err(PluginError::Config(format!(
                    "its manifest is invalid, so settings for it can't be checked: {reason}"
                )));
            }
            settings.set(id, enabled, saved)?;
            plugin.update(|live| live.enabled = enabled);
            return Ok(plugin.status());
        }

        let given = config.is_some();
        let new_config = config
            .or_else(|| saved.clone())
            .unwrap_or_else(|| json!({}));
        if given || enabled {
            plugin
                .check_config(&new_config)
                .map_err(PluginError::Config)?;
        }
        settings.set(
            id,
            enabled,
            if given {
                Some(new_config.clone())
            } else {
                saved
            },
        )?;

        let (changed, running) = {
            let mut live = lock(&plugin.live);
            let changed = live.config != new_config;
            live.config = new_config;
            live.enabled = enabled;
            let running = matches!(live.state, PluginState::Ready | PluginState::Starting);
            (changed, running)
        };
        if enabled {
            if !running || changed {
                inner.stop(plugin).await;
                let before = lock(&plugin.live).resolved;
                let mut changes = plugin.changes.subscribe();
                inner.launch(plugin).await;
                let limit = inner.options.initialize_timeout + inner.options.stop_grace;
                let _ = tokio::time::timeout(limit, async {
                    loop {
                        {
                            let live = lock(&plugin.live);
                            if live.state != PluginState::Starting || live.resolved > before {
                                break;
                            }
                        }
                        if changes.changed().await.is_err() {
                            break;
                        }
                    }
                })
                .await;
            }
        } else {
            inner.stop(plugin).await;
            plugin.update(|live| {
                live.state = PluginState::Disabled;
                live.last_error = None;
            });
        }
        Ok(plugin.status())
    }

    /// Asks every ready context plug-in at once, each answer held to `obi-plugin/0.1`'s limits
    /// ([`limit_items`] with the request's `maxBytes`). Never fails: a plug-in that fails or
    /// doesn't answer within 5 seconds gives nothing, and the job goes on. Plug-ins that gave no
    /// item are left out; the rest come by id.
    pub async fn context(&self, request: ContextRequest) -> Vec<(PluginId, Vec<ContextItem>)> {
        if self.inner.closed.load(Ordering::SeqCst) {
            return Vec::new();
        }
        let limit = self.inner.options.context_timeout;
        let mut asks = tokio::task::JoinSet::new();
        for plugin in self.inner.plugins.values() {
            let conn = {
                let live = lock(&plugin.live);
                let ready = live.enabled && live.state == PluginState::Ready;
                live.conn
                    .clone()
                    .filter(|conn| ready && conn.serves(Kind::Context))
            };
            if let Some(conn) = conn {
                let id = plugin.id.clone();
                let request = request.clone();
                asks.spawn(async move {
                    let answer = conn
                        .request(method::CONTEXT_QUERY, &request, limit)
                        .await
                        .and_then(rpc::from_value::<rpc::ContextResult>);
                    (id, answer)
                });
            }
        }
        let mut answers = Vec::new();
        while let Some(joined) = asks.join_next().await {
            let Ok((id, answer)) = joined else { continue };
            match answer {
                Ok(result) => {
                    let items = limit_items(result.items, request.max_bytes);
                    if !items.is_empty() {
                        answers.push((id, items));
                    }
                }
                Err(error) => {
                    tracing::warn!(target: "obi_plugin", plugin = %id, "context/query gave nothing: {error}");
                }
            }
        }
        answers.sort_by(|a, b| a.0.cmp(&b.0));
        answers
    }

    /// The MCP server of every ready `agent-mcp` plug-in, with the only tools agents may call.
    pub fn agent_mcp_servers(&self) -> Vec<(PluginId, McpServerSpec, Vec<String>)> {
        if self.inner.closed.load(Ordering::SeqCst) {
            return Vec::new();
        }
        let mut servers = Vec::new();
        for plugin in self.inner.plugins.values() {
            let Found::Valid(manifest) = &plugin.found else {
                continue;
            };
            let Some(spec) = &manifest.agent_mcp else {
                continue;
            };
            let live = lock(&plugin.live);
            if live.enabled
                && live.state == PluginState::Ready
                && live.served.contains(&Kind::AgentMcp)
            {
                servers.push((
                    plugin.id.clone(),
                    spec.server.clone(),
                    spec.allowed_tools.clone(),
                ));
            }
        }
        servers
    }

    /// The receiver every accepted event from every plug-in arrives on: `Some` on the first call
    /// only, `None` after, so no event is split between two consumers. It ends (`recv` gives
    /// `None`) only after [`PluginHost::shutdown`].
    pub fn take_events(&self) -> Option<tokio::sync::mpsc::Receiver<PluginEvent>> {
        lock(&self.inner.events).receiver.take()
    }

    /// Stops every plug-in (each gets `shutdown`, and is killed if it is still running 5
    /// seconds later) and ends the event receiver. Calling it again does nothing. After it,
    /// [`PluginHost::list`] still answers, each running plug-in `disabled` (nothing runs), and
    /// [`PluginHost::set_enabled`] answers [`PluginError::Stopped`].
    pub async fn shutdown(&self) {
        let inner = &self.inner;
        let _settings = inner.settings.lock().await;
        if !inner.closed.swap(true, Ordering::SeqCst) {
            let mut stops = tokio::task::JoinSet::new();
            for plugin in inner.plugins.values() {
                let inner = inner.clone();
                let plugin = plugin.clone();
                stops.spawn(async move {
                    inner.stop(&plugin).await;
                    if matches!(plugin.found, Found::Valid(_)) {
                        plugin.update(|live| {
                            if live.state != PluginState::Failed {
                                live.state = PluginState::Disabled;
                            }
                        });
                    }
                });
            }
            while stops.join_next().await.is_some() {}
        }
        lock(&inner.events).sender = None;
    }
}

impl Drop for PluginHost {
    /// A host dropped without [`PluginHost::shutdown`] still tells every plug-in to stop; their
    /// processes end with the runtime at the latest (they are killed on drop).
    fn drop(&mut self) {
        for plugin in self.inner.plugins.values() {
            if let Ok(supervisor) = plugin.supervisor.try_lock() {
                if let Some(supervisor) = supervisor.as_ref() {
                    let _ = supervisor.stop.send(true);
                }
            }
        }
    }
}

impl Inner {
    /// Starts an enabled plug-in: at once `ready` without a process, or in its sandbox.
    async fn launch(self: &Arc<Inner>, plugin: &Arc<Plugin>) {
        let Found::Valid(manifest) = &plugin.found else {
            return;
        };
        let Some(run) = &manifest.run else {
            let kinds = manifest.kinds.clone();
            plugin.update(|live| {
                live.state = PluginState::Ready;
                live.last_error = None;
                live.served = kinds;
                live.resolved += 1;
            });
            return;
        };
        let fail = |reason: String| {
            plugin.update(|live| {
                live.state = PluginState::Failed;
                live.last_error = Some(reason);
                live.served.clear();
                live.resolved += 1;
            })
        };
        let sandbox = self
            .sandbox
            .get_or_init(|| Sandbox::detect(self.options.sandbox_program.as_deref()))
            .await
            .clone();
        let sandbox = match sandbox {
            Ok(sandbox) => sandbox,
            Err(reason) => return fail(PluginError::Sandbox(reason).to_string()),
        };
        let launch = match self.launch_spec(plugin, &run.command, &run.args) {
            Ok(launch) => launch,
            Err(reason) => return fail(reason),
        };
        plugin.update(|live| {
            live.state = PluginState::Starting;
            live.last_error = None;
        });
        let (stop, stopped) = watch::channel(false);
        let task = tokio::spawn(supervise(
            self.clone(),
            plugin.clone(),
            sandbox,
            launch,
            stopped,
        ));
        *plugin.supervisor.lock().await = Some(Supervisor { stop, task });
    }

    /// The folders a plug-in's sandbox is made of, made where they don't exist yet.
    fn launch_spec(
        &self,
        plugin: &Plugin,
        command: &str,
        args: &[String],
    ) -> Result<Launch, String> {
        let tmp_dir = plugin.data_dir.join("tmp");
        make_private_dir(&tmp_dir)
            .map_err(|error| format!("can't make its data folder: {error}"))?;
        let resolve = |path: &Path| {
            std::fs::canonicalize(path)
                .map_err(|error| format!("can't resolve {}: {error}", path.display()))
        };
        let plugin_dir = resolve(&plugin.dir)?;
        let data_dir = resolve(&plugin.data_dir)?;
        let tmp_dir = resolve(&tmp_dir)?;
        let program = resolve(&plugin_dir.join(command))
            .map_err(|_| format!("run.command {command:?} is not in the plug-in's folder"))?;
        if !program.starts_with(&plugin_dir) || !program.is_file() {
            return Err(format!(
                "run.command {command:?} is not a file inside the plug-in's folder"
            ));
        }
        Ok(Launch {
            obid_home: self.home.clone(),
            real_home: self.real_home.clone(),
            plugin_dir,
            data_dir,
            tmp_dir,
            program,
            args: args.to_vec(),
        })
    }

    /// Stops the plug-in's process, if it has one, and waits until it has.
    async fn stop(&self, plugin: &Plugin) {
        let supervisor = plugin.supervisor.lock().await.take();
        if let Some(supervisor) = supervisor {
            let _ = supervisor.stop.send(true);
            let _ = supervisor.task.await;
        }
        plugin.update(|live| {
            live.conn = None;
            live.served.clear();
        });
    }
}

impl Plugin {
    fn status(&self) -> PluginStatus {
        let (name, version, kinds) = match &self.found {
            Found::Valid(manifest) => (
                manifest.name.clone(),
                manifest.version.clone(),
                manifest.kinds.clone(),
            ),
            Found::Invalid {
                name,
                version,
                kinds,
                ..
            } => (name.clone(), version.clone(), kinds.clone()),
        };
        let live = lock(&self.live);
        PluginStatus {
            id: self.id.clone(),
            name,
            version,
            kinds,
            enabled: live.enabled,
            state: live.state,
            last_error: live.last_error.clone(),
        }
    }

    fn update(&self, change: impl FnOnce(&mut Live)) {
        change(&mut lock(&self.live));
        self.changes.send_modify(|n| *n += 1);
    }

    /// Whether `config` matches the manifest's `config` schema. A plug-in whose manifest has
    /// none takes no settings: only `{}`.
    fn check_config(&self, config: &Value) -> Result<(), String> {
        let Found::Valid(manifest) = &self.found else {
            return Err("the manifest is invalid".into());
        };
        match &manifest.config {
            Some(schema) => schema::validate(schema, config),
            None if config == &json!({}) => Ok(()),
            None => Err("the plug-in takes no settings: only {}".into()),
        }
    }
}

/// How one start of a plug-in's process ended.
enum Outcome {
    /// It was told to stop, and has.
    Stopped,
    /// It failed: it didn't start, didn't answer `initialize` or a ping in time, or exited.
    /// `pinged` is whether it answered a ping before that.
    Failed { reason: String, pinged: bool },
}

/// Runs one plug-in's process until it is told to stop, restarting it after a failure with the
/// waits in [`Options::restart_delays`]; with no wait left, it is `failed`.
async fn supervise(
    inner: Arc<Inner>,
    plugin: Arc<Plugin>,
    sandbox: Sandbox,
    launch: Launch,
    mut stop: watch::Receiver<bool>,
) {
    let mut failures = 0usize;
    loop {
        plugin.update(|live| live.state = PluginState::Starting);
        let (reason, pinged) = match run_once(&inner, &plugin, &sandbox, &launch, &mut stop).await {
            Outcome::Stopped => return,
            Outcome::Failed { reason, pinged } => (reason, pinged),
        };
        if pinged {
            failures = 0;
        }
        failures += 1;
        tracing::warn!(target: "obi_plugin", plugin = %plugin.id, "{reason}");
        let delay = inner.options.restart_delays.get(failures - 1).copied();
        plugin.update(|live| {
            live.conn = None;
            live.served.clear();
            live.resolved += 1;
            match delay {
                Some(_) => {
                    live.state = PluginState::Starting;
                    live.last_error = Some(reason);
                }
                None => {
                    live.state = PluginState::Failed;
                    live.last_error = Some(format!(
                        "{reason}; it failed {failures} times in a row, so it stays stopped until it is enabled again"
                    ));
                }
            }
        });
        let Some(delay) = delay else {
            // Kept apart from this task: enabling or disabling it waits for this task to end
            // while holding the settings.
            let resolved = lock(&plugin.live).resolved;
            tokio::spawn(remember_failed(inner.clone(), plugin.clone(), resolved));
            return;
        };
        tokio::select! {
            _ = stopped(&mut stop) => return,
            _ = tokio::time::sleep(delay) => {}
        }
    }
}

/// Keeps in `home/plugins.json` that `plugin` failed, so that the next `obid` start leaves it
/// stopped too, unless the owner enabled or disabled it since (`resolved` is how many starts
/// had ended when it failed).
async fn remember_failed(inner: Arc<Inner>, plugin: Arc<Plugin>, resolved: u64) {
    let mut settings = inner.settings.lock().await;
    let reason = {
        let live = lock(&plugin.live);
        if !live.enabled || live.state != PluginState::Failed || live.resolved != resolved {
            return;
        }
        live.last_error.clone().unwrap_or_default()
    };
    if let Err(error) = settings.mark_failed(&plugin.id, &reason) {
        tracing::warn!(target: "obi_plugin", plugin = %plugin.id, "can't keep that it failed in plugins.json: {error}");
    }
}

async fn run_once(
    inner: &Inner,
    plugin: &Plugin,
    sandbox: &Sandbox,
    launch: &Launch,
    stop: &mut watch::Receiver<bool>,
) -> Outcome {
    let failed = |reason: String, pinged: bool| Outcome::Failed { reason, pinged };
    let options = &inner.options;
    let mut child = match sandbox.command(launch).spawn() {
        Ok(child) => child,
        Err(error) => return failed(format!("can't start it: {error}"), false),
    };
    let pgid = child.id().unwrap_or(0);
    let (Some(stdin), Some(stdout), Some(stderr)) =
        (child.stdin.take(), child.stdout.take(), child.stderr.take())
    else {
        end(None, &mut child, pgid, sandbox).await;
        return failed("its pipes weren't made".into(), false);
    };
    let events = lock(&inner.events).sender.clone();
    let conn = Conn::start(plugin.peer.clone(), stdin, stdout, stderr, events);

    let config = lock(&plugin.live).config.clone();
    let params = InitializeParams {
        protocol: PROTOCOL.to_owned(),
        obid: rpc::ObidInfo {
            version: env!("CARGO_PKG_VERSION").to_owned(),
        },
        plugin: rpc::PluginInfo {
            id: plugin.id.clone(),
            data_dir: launch.data_dir.to_string_lossy().into_owned(),
        },
        config,
    };
    let answer = tokio::select! {
        _ = stopped(stop) => {
            stop_gracefully(&conn, &mut child, pgid, sandbox, options.stop_grace).await;
            return Outcome::Stopped;
        }
        status = child.wait() => {
            end(Some(&conn), &mut child, pgid, sandbox).await;
            return failed(format!("it exited before answering initialize ({})", exit(status)), false);
        }
        answer = conn.request(method::INITIALIZE, &params, options.initialize_timeout) => answer,
    };
    let kinds = match answer
        .and_then(rpc::from_value::<InitializeResult>)
        .and_then(|result| check_initialize(plugin, result))
    {
        Ok(kinds) => kinds,
        Err(PluginError::Stopped) => {
            // Its stdout ended before the answer: it is exiting.
            let status = exited(&mut child).await;
            end(Some(&conn), &mut child, pgid, sandbox).await;
            return failed(
                format!("it exited before answering initialize ({status})"),
                false,
            );
        }
        Err(error) => {
            end(Some(&conn), &mut child, pgid, sandbox).await;
            return failed(format!("initialize: {error}"), false);
        }
    };
    conn.set_served(kinds.clone());
    plugin.update(|live| {
        live.state = PluginState::Ready;
        live.last_error = None;
        live.served = kinds;
        live.conn = Some(conn.clone());
        live.resolved += 1;
    });

    let mut pinged = false;
    loop {
        tokio::select! {
            _ = stopped(stop) => {
                stop_gracefully(&conn, &mut child, pgid, sandbox, options.stop_grace).await;
                return Outcome::Stopped;
            }
            status = child.wait() => {
                end(Some(&conn), &mut child, pgid, sandbox).await;
                return failed(format!("it exited ({})", exit(status)), pinged);
            }
            _ = tokio::time::sleep(options.ping_interval) => {}
        }
        let answer = tokio::select! {
            _ = stopped(stop) => {
                stop_gracefully(&conn, &mut child, pgid, sandbox, options.stop_grace).await;
                return Outcome::Stopped;
            }
            answer = conn.request(method::PING, &Empty {}, options.ping_timeout) => answer,
        };
        match answer.and_then(rpc::from_value::<Empty>) {
            Ok(_) => {}
            Err(PluginError::Stopped) => {
                let status = exited(&mut child).await;
                end(Some(&conn), &mut child, pgid, sandbox).await;
                return failed(format!("it exited ({status})"), pinged);
            }
            Err(error) => {
                end(Some(&conn), &mut child, pgid, sandbox).await;
                return failed(format!("ping: {error}"), pinged);
            }
        }
        pinged = true;
    }
}

/// The kinds an `initialize` answer says it serves, when it is a valid answer.
fn check_initialize(plugin: &Plugin, result: InitializeResult) -> Result<Vec<Kind>, PluginError> {
    let Found::Valid(manifest) = &plugin.found else {
        return Err(PluginError::Protocol("its manifest is invalid".into()));
    };
    conn::initialize_kinds(&manifest.kinds, result)
}

/// `shutdown`, then stdin closes; still running `grace` after `shutdown` was sent, it is
/// killed. Whatever it started is ended either way.
async fn stop_gracefully(
    conn: &Arc<Conn>,
    child: &mut Child,
    pgid: u32,
    sandbox: &Sandbox,
    grace: Duration,
) {
    let end_at = tokio::time::Instant::now() + grace;
    let _ = tokio::time::timeout_at(end_at, conn.request(method::SHUTDOWN, &Empty {}, grace)).await;
    conn.close_stdin();
    let _ = tokio::time::timeout_at(end_at, child.wait()).await;
    end(Some(conn), child, pgid, sandbox).await;
}

/// Ends the plug-in's process and everything it started, and its connection. On macOS the
/// process is the sandbox's watcher: told to (`SIGTERM`), it kills everything in the sandbox,
/// also what left the plug-in's process group or session. Then whatever is left of the process
/// group is killed.
async fn end(conn: Option<&Arc<Conn>>, child: &mut Child, pgid: u32, sandbox: &Sandbox) {
    if sandbox.has_watcher() {
        match child.try_wait() {
            Ok(None) => {
                sandbox::tell_watcher(pgid).await;
                let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
            }
            Ok(Some(status)) => {
                use std::os::unix::process::ExitStatusExt;
                if let Some(signal) = status.signal() {
                    tracing::warn!(
                        target: "obi_plugin",
                        "the plug-in's watcher was killed (signal {signal}): processes it started that left its process group may still run"
                    );
                }
            }
            Err(_) => {}
        }
    }
    let _ = child.start_kill();
    if sandbox.has_watcher() {
        sandbox::kill_group(pgid).await;
    }
    let _ = tokio::time::timeout(Duration::from_secs(5), child.wait()).await;
    if let Some(conn) = conn {
        conn.cancel();
    }
}

/// How the plug-in's process ended, once it has (within a second), for a reason to show.
async fn exited(child: &mut Child) -> String {
    match tokio::time::timeout(Duration::from_secs(1), child.wait()).await {
        Ok(status) => exit(status),
        Err(_) => "its output ended".to_owned(),
    }
}

fn exit(status: std::io::Result<std::process::ExitStatus>) -> String {
    match status {
        Ok(status) => status.to_string(),
        Err(error) => error.to_string(),
    }
}

/// Returns once `stop` says to stop, or once nobody can say it any more.
async fn stopped(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|stop| *stop).await;
}

/// Reads every `home/plugins/<id>/obi-plugin.json`, by id.
fn discover(home: &Path) -> Vec<(PluginId, Found)> {
    let Ok(entries) = std::fs::read_dir(home.join("plugins")) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !entry.path().is_dir() {
            continue;
        }
        let Ok(id) = PluginId::new(name) else {
            tracing::warn!(target: "obi_plugin", "home/plugins/{name:?} is left out: its name is not a plug-in id");
            continue;
        };
        found.push((id, read_manifest(&entry.path(), name)));
    }
    found.sort_by(|a, b| a.0.cmp(&b.0));
    found
}

fn read_manifest(dir: &Path, folder: &str) -> Found {
    let invalid = |reason: String, json: Option<&Value>| {
        let text = |key: &str| {
            json.and_then(|json| json.get(key))
                .and_then(Value::as_str)
                .map(|text| text.chars().take(200).collect::<String>())
        };
        let kinds = json
            .and_then(|json| json.get("kinds"))
            .and_then(|kinds| serde_json::from_value::<Vec<Kind>>(kinds.clone()).ok())
            .unwrap_or_default();
        Found::Invalid {
            name: text("name").unwrap_or_else(|| folder.to_owned()),
            version: text("version").unwrap_or_default(),
            kinds,
            reason: PluginError::Manifest(reason).to_string(),
        }
    };
    let path = dir.join(MANIFEST_FILE);
    let bytes = match read_bounded(&path, MAX_MANIFEST_BYTES) {
        Ok(bytes) => bytes,
        Err(reason) => return invalid(format!("{MANIFEST_FILE}: {reason}"), None),
    };
    match Manifest::from_slice(&bytes, folder) {
        Ok(manifest) => match manifest.config.as_ref().map(schema::supported) {
            Some(Err(reason)) => {
                let json = serde_json::from_slice::<Value>(&bytes).ok();
                invalid(reason, json.as_ref())
            }
            _ => Found::Valid(Box::new(manifest)),
        },
        Err(PluginError::Manifest(reason)) => {
            let json = serde_json::from_slice::<Value>(&bytes).ok();
            invalid(reason, json.as_ref())
        }
        Err(error) => {
            let json = serde_json::from_slice::<Value>(&bytes).ok();
            invalid(error.to_string(), json.as_ref())
        }
    }
}

fn read_bounded(path: &Path, max: u64) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let file = std::fs::File::open(path).map_err(|error| error.to_string())?;
    let mut bytes = Vec::new();
    file.take(max + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() as u64 > max {
        return Err(format!("larger than {max} bytes"));
    }
    Ok(bytes)
}

/// `home/plugins.json`.
struct Settings {
    path: PathBuf,
    entries: serde_json::Map<String, Value>,
}

impl Settings {
    /// Reads it. A file that is missing gives no entries; one that can't be read or isn't a
    /// JSON object is logged and treated as no entries, so every plug-in is disabled.
    fn load(path: PathBuf) -> Settings {
        let entries = match read_bounded(&path, MAX_SETTINGS_BYTES) {
            Err(_) if !path.exists() => serde_json::Map::new(),
            Err(reason) => {
                tracing::warn!(target: "obi_plugin", "{} can't be read ({reason}): every plug-in is disabled", path.display());
                serde_json::Map::new()
            }
            Ok(bytes) => match serde_json::from_slice::<Value>(&bytes) {
                Ok(Value::Object(entries)) => entries,
                _ => {
                    tracing::warn!(target: "obi_plugin", "{} is not a JSON object: every plug-in is disabled", path.display());
                    serde_json::Map::new()
                }
            },
        };
        Settings { path, entries }
    }

    /// Whether `id` is enabled, and its settings, as kept.
    fn entry(&self, id: &PluginId) -> (bool, Option<Value>) {
        let Some(entry) = self.entries.get(id.as_str()) else {
            return (false, None);
        };
        let enabled = entry.get("enabled") == Some(&Value::Bool(true));
        let config = entry.get("config").filter(|c| !c.is_null()).cloned();
        (enabled, config)
    }

    /// Why `id` failed when it last ran, when it did and hasn't been enabled or disabled since.
    fn failed(&self, id: &PluginId) -> Option<String> {
        self.entries
            .get(id.as_str())?
            .get("failed")?
            .as_str()
            .map(str::to_owned)
    }

    /// Keeps `id`'s choice and settings, without `failed`.
    fn set(
        &mut self,
        id: &PluginId,
        enabled: bool,
        config: Option<Value>,
    ) -> Result<(), PluginError> {
        let mut entry = serde_json::Map::new();
        entry.insert("enabled".into(), Value::Bool(enabled));
        if let Some(config) = config {
            entry.insert("config".into(), config);
        }
        let mut entries = self.entries.clone();
        entries.insert(id.as_str().to_owned(), Value::Object(entry));
        self.write(entries)
    }

    /// Keeps that `id` failed, and why, beside its choice and settings.
    fn mark_failed(&mut self, id: &PluginId, reason: &str) -> Result<(), PluginError> {
        let mut entries = self.entries.clone();
        let entry = entries
            .entry(id.as_str().to_owned())
            .or_insert_with(|| json!({"enabled": true}));
        if let Value::Object(entry) = entry {
            entry.insert("failed".into(), Value::String(reason.to_owned()));
        }
        self.write(entries)
    }

    /// Writes the file whole (a new file renamed over the old one, readable by its owner
    /// only), then keeps `entries` as what it holds.
    fn write(&mut self, entries: serde_json::Map<String, Value>) -> Result<(), PluginError> {
        let mut text = serde_json::to_string_pretty(&Value::Object(entries.clone()))
            .map_err(|error| PluginError::Io(error.to_string()))?;
        text.push('\n');
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let new = self.path.with_extension("json.new");
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&new)?;
            file.write_all(text.as_bytes())?;
            file.sync_all()?;
        }
        std::fs::rename(&new, &self.path)?;
        self.entries = entries;
        Ok(())
    }
}

/// Makes `dir` and its parents, `dir` readable by its owner only.
fn make_private_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
}

/// Locks `mutex`. Nothing panics while holding one of the host's locks, so a poisoned lock
/// still holds sound data.
pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}
