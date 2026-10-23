//! obid: Obi's engine as a daemon. It serves the runner API (docs/runner-api.md) on 127.0.0.1,
//! so the Mac, iPhone and Watch apps run against it unchanged, plus the endpoints in that
//! document's "obid only" section. docs/ARCHITECTURE.md says how it fits with the rest.

// The job's JSON (`job::Job::to_json`) has every key the apps expect, in one `json!`.
#![recursion_limit = "256"]

pub mod accounts;
pub mod acp;
pub mod activity;
pub mod agent;
pub mod api;
pub mod app;
pub mod approval;
pub mod artifacts;
pub mod brain;
pub mod clear;
pub mod codex;
pub mod config;
pub mod conn;
pub mod connections;
pub mod conversation;
pub mod decisions;
pub mod detail;
pub mod devices;
pub mod event_work;
pub mod events;
pub mod facts;
pub mod failures;
pub mod gateway;
pub mod git;
pub mod github;
pub mod github_login;
pub mod github_work;
pub mod hooks;
pub mod job;
pub mod jobs;
pub mod limits;
pub mod listen;
pub mod logs;
pub mod memory;
pub mod obi_dir;
pub mod permissions;
pub mod plugins;
pub mod policy;
pub mod process;
pub mod publish;
pub mod push;
pub mod review;
pub mod routes;
pub mod routines;
pub mod rules;
pub mod sandbox;
pub mod scan;
pub mod secrets;
pub mod sentry;
pub mod settings;
pub mod slack;
pub mod sphere;
pub mod store;
pub mod teammates;
pub mod tetrix;
pub mod token;
pub mod transcript;
pub mod tunnel;
pub mod usage;
pub mod vault;
pub mod watch;
pub mod web;

use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use config::Config;

/// How long obid waits for requests under way after SIGTERM or SIGINT before it exits anyway.
/// The contract is "exits 0 within 10 seconds".
pub const SHUTDOWN_GRACE: Duration = Duration::from_secs(6);

/// How long the jobs' agents and checks get to end when obid stops.
pub const JOBS_GRACE: Duration = Duration::from_secs(2);

/// How long after the stop obid waits, at most, for its plug-ins to have stopped (each gets 5
/// seconds after `shutdown` before it is killed, docs/ARCHITECTURE.md 5.3, step 6; they stop at
/// once, side by side with the jobs, from the moment obid is told to stop).
pub const PLUGINS_GRACE: Duration = Duration::from_secs(8);

/// How long obid waits for the worktrees' measurement before it answers anyway (`serve`).
pub const MEASURE_FIRST: Duration = Duration::from_millis(200);

/// How long after it starts obid runs its first cleanup pass, out of the way of the apps' first
/// calls.
pub const CLEAN_FIRST: Duration = Duration::from_secs(30);

/// How often the cleanup pass runs when no job settles meanwhile.
pub const CLEAN_EVERY: Duration = Duration::from_secs(3 * 60 * 60);

#[derive(Debug, thiserror::Error)]
pub enum StartError {
    #[error("can't make home {path}: {source}")]
    Home {
        path: std::path::PathBuf,
        source: std::io::Error,
    },
    #[error(transparent)]
    Token(#[from] token::TokenError),
    #[error("can't listen on {address}: {source}")]
    Listen {
        address: SocketAddr,
        source: std::io::Error,
    },
    #[error("the server stopped: {0}")]
    Serve(std::io::Error),
    #[error("can't open the jobs in {path}: {source}")]
    Jobs {
        path: std::path::PathBuf,
        source: std::io::Error,
    },
}

/// Makes `home` if it isn't there yet, and keeps it its owner's alone (0700): it holds the API
/// token, the Obi key, clones and the database. A home that is there already with group or
/// world access is tightened to 0700, the way `home/api-token` is to 0600.
pub fn prepare_home(config: &Config) -> Result<(), StartError> {
    let home = &config.home;
    let err = |source| StartError::Home {
        path: home.clone(),
        source,
    };
    if home.is_dir() {
        return keep_private(home).map_err(err);
    }
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(home).map_err(err)?;
    // `recursive` makes missing parents with the umask's mode; `home` itself gets 0700 even
    // when it raced into existence another way.
    keep_private(home).map_err(err)
}

/// A folder its group or others can reach is made its owner's alone again.
fn keep_private(folder: &std::path::Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(folder)?.permissions().mode();
        if mode & 0o077 != 0 {
            tracing::warn!(
                "{} was mode {:o}: making it 0700",
                folder.display(),
                mode & 0o777
            );
            std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700))?;
        }
    }
    #[cfg(not(unix))]
    let _ = folder;
    Ok(())
}

/// The cleanup pass (docs/runner-api.md, `cleanup`): [`CLEAN_FIRST`] after obid starts, then
/// whenever a job may have settled, and every [`CLEAN_EVERY`] for the jobs that settle as time
/// passes. A pass that removed a worktree measures the folder again, unless obid is stopping
/// (`cancelled`).
async fn keep_worktrees_clean(shared: Arc<api::Shared>, cancelled: Arc<AtomicBool>) {
    tokio::time::sleep(CLEAN_FIRST).await;
    loop {
        let now = obi_protocol::time::now();
        if shared.jobs.clean_worktrees(now, shared.cleared.at()).await > 0 {
            let (shared, cancelled) = (shared.clone(), cancelled.clone());
            let _ =
                tokio::task::spawn_blocking(move || shared.cleanup.remeasure_unless(&cancelled))
                    .await;
        }
        shared.jobs.wait_to_clean(CLEAN_EVERY).await;
    }
}

/// Serves the API on `config.listen` until `stop` resolves, then lets requests under way finish
/// for at most [`SHUTDOWN_GRACE`]. `ready` is told the address once obid is listening.
///
/// It measures `home/worktrees` (`status.cleanup.bytes`), a walk of every worktree, while it
/// starts: it waits for it at most [`MEASURE_FIRST`], then answers and lets the walk finish in
/// the background. A `stop` that resolves while it waits ends the walk and returns at once,
/// without `ready` being told anything: a stop while starting is a stop, not a wait.
pub async fn serve(
    config: Config,
    token: String,
    stop: impl Future<Output = ()> + Send + 'static,
    ready: impl FnOnce(SocketAddr),
) -> Result<(), StartError> {
    let mut stopwatch = Stopwatch::new();
    let address = config.listen;
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .map_err(|source| StartError::Listen { address, source })?;
    let bound = listener
        .local_addr()
        .map_err(|source| StartError::Listen { address, source })?;
    // The gateway's address is taken now too, so a busy one stops obid before anything starts.
    let gateway = match config.gateway {
        Some(address) => Some(
            tokio::net::TcpListener::bind(address)
                .await
                .map_err(|source| StartError::Listen { address, source })?,
        ),
        None => None,
    };
    let host = gethostname::gethostname().to_string_lossy().into_owned();
    let cleanup = Arc::new(api::Cleanup::unmeasured(&config.home));
    let cancelled = Arc::new(AtomicBool::new(false));
    // However `serve` returns (a stop, a start that fails, the end), the walk ends with it.
    let _end_walk = SetOnDrop(cancelled.clone());
    let mut measuring = {
        let (cleanup, cancelled) = (cleanup.clone(), cancelled.clone());
        tokio::task::spawn_blocking(move || cleanup.remeasure_unless(&cancelled))
    };
    let mut stop = Box::pin(stop);
    let measured = tokio::select! {
        // A stop that is there already wins over a measurement that is done too.
        biased;
        () = &mut stop => {
            tracing::info!("stopped while starting");
            return Ok(());
        }
        // A few worktrees are measured before the first answer; the owner's 20 GB took 4 to 28
        // seconds, so obid doesn't wait for those.
        measured = tokio::time::timeout(MEASURE_FIRST, &mut measuring) => measured.ok(),
    };
    stopwatch.lap("worktrees");
    // The API token is a secret obid's log layer takes out of plug-ins' lines (crate::logs).
    secrets::known().learn("api-token", &token);
    // claudeKeychain as the owner set it; left out, on by itself on macOS when Claude Code's default
    // login is only in the Keychain (the owner's decision of 2026-10-18).
    let keychain = config.claude_keychain.unwrap_or_else(jobs::keychain_wanted);
    jobs::use_keychain(keychain, config.claude_keychain.is_none());
    if keychain {
        if config.claude_keychain.is_none() {
            tracing::info!(
                "claudeKeychain on by itself: Claude Code's login is only in the Keychain"
            );
        }
        jobs::keep_keychain_logins();
    }
    vault::install(&config.home, &config.vault);
    stopwatch.lap("vault");
    // What the accounts API changed, over the configuration's accounts, before anything uses them;
    // and what sign-ins cut short by the last stop left behind.
    config.agents.open(&config.home);
    accounts::sweep(&config.home);
    github_login::sweep(&config.home);
    // What an older obid's boxes could have left in the accounts' folders (#655), said once.
    jobs::check_account_folders(&config.agents.get());
    stopwatch.lap("accounts");
    let events = events::Events::new();
    // The walk's end: said to the apps when it comes after obid answers (`cleanup`), and in the
    // log when it failed.
    match measured {
        Some(walked) => log_walk(walked),
        None => {
            tokio::spawn(walk_ended(measuring, events.clone(), cleanup.clone()));
        }
    }
    let sandbox = std::env::current_exe()
        .map_err(|e| format!("obid can't find its own executable: {e}"))
        .and_then(|obid| sandbox::Sandbox::detect(&obid));
    match &sandbox {
        Err(why) => tracing::warn!("no job sandbox, so no job will run: {why}"),
        Ok(boxed) if boxed.encloses() => tracing::warn!(
            "obid runs inside a job sandbox, which Seatbelt can't nest in: what it starts stays in that sandbox"
        ),
        Ok(_) => {}
    }
    stopwatch.lap("sandbox");
    let jobs = jobs::Jobs::open(config.clone(), events.clone(), sandbox).map_err(|source| {
        StartError::Jobs {
            path: config.home.join("jobs"),
            source,
        }
    })?;
    jobs.set_api_address(bound);
    stopwatch.lap("jobs");
    let (stopping_tx, stopping_rx) = tokio::sync::watch::channel(false);
    let link = sphere::Link::open(
        config.clone(),
        jobs.clone(),
        events.clone(),
        stopping_rx.clone(),
    )
    .map_err(|source| StartError::Jobs {
        path: config.home.join("exchanges"),
        source,
    })?;
    // A rule's start that a stop cut short is an offer again (#1314).
    link.reopen_claims();
    // The plug-ins obid ships, installed where missing (disabled), then the host, which starts
    // the ones the owner enabled without waiting for them.
    stopwatch.lap("sphere");
    let plugins = Arc::new(plugins::Plugins::start(&config).await);
    stopwatch.lap("plug-ins");
    jobs.use_plugins(plugins.clone());
    let cleared = clear::Cleared::open(&config.home);
    let devices = devices::Devices::open(&config.home);
    let paired = gateway::Gateway::open(&config.home);
    let broker_host = if cfg!(target_os = "linux") {
        format!("http://10.0.2.2:{}", bound.port())
    } else {
        format!("http://127.0.0.1:{}", bound.port())
    };
    let connections = connections::Connections::open(&config.home, &jobs, broker_host);
    jobs.use_connections(connections.clone());
    let tetrix = tetrix::Tetrix::open(
        &config.home,
        vault::shared().expect("the vault is installed first"),
        events.clone(),
    );
    jobs.use_tetrix(tetrix.clone());
    // A login copy a crash left in a conversation's folder goes before anything runs.
    brain::harness::forget_logins_left(&config.home);
    let conversations = conversation::Conversations::open(&config.home, events.clone());
    let artifacts = artifacts::Artifacts::open(&config.home, events.clone()).map_err(|source| {
        StartError::Jobs {
            path: config.home.join("artifacts"),
            source,
        }
    })?;
    jobs.use_artifacts(artifacts.clone());
    let routines = Arc::new(routines::Routines::open(&config.home, events.clone()));
    jobs.use_routines(routines.clone());
    let github =
        github_work::Feed::open(config.clone(), jobs.clone(), link.clone(), events.clone());
    let pushes = push::Push::open(&config.home, &config.push_relay);
    let slack = slack::Slack::open(
        &config.home,
        vault::shared().expect("the vault is installed first"),
        events.clone(),
    );
    jobs.use_slack(slack.clone());
    let sentry = sentry::Sentry::open(
        &config.home,
        vault::shared().expect("the vault is installed first"),
        events.clone(),
    );
    link.use_sentry(sentry.clone());
    let hooks = hooks::Hooks::open(
        &config.home,
        vault::shared().expect("the vault is installed first"),
        events.clone(),
    );
    let watch = watch::Watch::open(&config.home, events.clone());
    let listen = listen::Listen::open(&config.home, events.clone());
    let tunnel = tunnel::Tunnel::open(
        &config.home,
        vault::shared().expect("the vault is installed first"),
        events.clone(),
    );
    let shared = Arc::new(api::Shared {
        config,
        token,
        host,
        cleanup,
        cleared,
        devices,
        gateway: paired,
        connections,
        jobs: jobs.clone(),
        events,
        conversations,
        artifacts,
        routines,
        turns: brain::turn::Turns::default(),
        harness: brain::harness::Sessions::default(),
        presence: brain::recap::Presence::default(),
        link: link.clone(),
        plugins: plugins.clone(),
        sign_ins: accounts::SignIns::default(),
        github: github_login::GitHubLogin::default(),
        tetrix,
        pages: web::Sessions::default(),
        github_work: github.clone(),
        slack,
        sentry,
        hooks,
        watch,
        listen,
        push: pushes,
        stopping: stopping_rx.clone(),
        tunnel: tunnel.clone(),
    });
    let app = api::router(shared.clone());

    let server = axum::serve(listener, app.clone()).with_graceful_shutdown(async move {
        stop.await;
        let _ = stopping_tx.send(true);
    });
    stopwatch.lap("the rest");
    ready(bound);
    // How long each step took, so a slow start names its step.
    tracing::info!("{}", stopwatch.line());
    // The gateway (crate::gateway): paired phones' calls, forwarded to the same router.
    if let Some(listener) = gateway {
        let address = listener.local_addr().map_err(StartError::Serve)?;
        println!("obid gateway listening on http://{address}");
        tracing::info!(%address, "obid gateway listening");
        let app = gateway::router(shared.clone(), app.clone());
        let mut stopping = stopping_rx.clone();
        tokio::spawn(async move {
            let stopped = async move {
                while !*stopping.borrow() {
                    if stopping.changed().await.is_err() {
                        return;
                    }
                }
            };
            if let Err(e) = axum::serve(listener, app)
                .with_graceful_shutdown(stopped)
                .await
            {
                tracing::error!("the gateway stopped: {e}");
            }
        });
    }
    // Jobs that were queued or running when obid last stopped carry on, and so does its Sphere.
    jobs.resume();
    link.start();
    // The tunnel phones reach this Mac through, when the owner turned remote access on (#896).
    tunnel.spawn(stopping_rx.clone());
    github.spawn(stopping_rx.clone());
    // Job alerts to Android phones through FCM (crate::push).
    push::spawn(shared.clone());
    // The worktrees' cleanup pass, in the background: never before the first answer.
    tokio::spawn(keep_worktrees_clean(shared.clone(), cancelled.clone()));
    // A tool reported an account's usage: every app hears the accounts as they are now.
    {
        let shared = shared.clone();
        let mut stopping = stopping_rx.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    () = shared.jobs.usage_changed.notified() => accounts::send_accounts(&shared).await,
                    _ = stopping.changed() => return,
                }
            }
        });
    }
    // A job a conversation started tells it how it ended (#351).
    conversation::report_job_ends(shared.clone());
    // Each repository's spare tree for the conversations' rooms, so a new one
    // doesn't wait for one to be extracted (docs/fast-replies.md).
    brain::harness::prepare_rooms(&shared);
    // What a conversation's shell left running when obid last stopped without ending it.
    brain::shell::reap_leftovers(&shared.config.home);
    // A deleted conversation's waiting Claude Code ends with it.
    brain::harness::end_warm_with_conversations(shared.clone());
    // Routines run on their schedules (#395).
    shared.routines.attach(&shared);
    routines::spawn(shared.clone());
    // Sentry's followed projects, every 5 minutes (crate::sentry).
    sentry::spawn(shared.clone());
    // The watcher, every 15 minutes on weekdays (crate::watch).
    watch::spawn(shared.clone());
    // The Slack channels the owner picked, live and caught up every 15 minutes (crate::listen).
    listen::spawn(shared.clone());
    // Job, check and inbox events go to the brain first (#590).
    brain::orchestrator::spawn(shared.clone());
    // A job a conversation started that stalls goes back to that conversation, which decides.
    brain::supervisor::spawn(shared.clone());
    // Every event a plug-in emits becomes a `pluginEvent` inbox item. The receiver ends once
    // the host has shut down.
    if let Some(mut events) = plugins.take_events() {
        let shared = shared.clone();
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                rules::offer(&shared, shared.link.plugin_event_offer(&event));
            }
        });
    }
    // Once told to stop: every agent and check ends now, and its job stays as it is for the next
    // start; every plug-in stops, with everything it started; every sign-in's login ends, with
    // everything it started; the event streams and waits end, so the server's connections close.
    let stopped_at = Arc::new(std::sync::OnceLock::new());
    let ending = {
        let shared = shared.clone();
        let jobs = jobs.clone();
        let plugins = plugins.clone();
        let stopped_at = stopped_at.clone();
        let mut stopping = stopping_rx.clone();
        tokio::spawn(async move {
            while !*stopping.borrow() {
                if stopping.changed().await.is_err() {
                    return;
                }
            }
            let _ = stopped_at.set(tokio::time::Instant::now());
            cancelled.store(true, Ordering::Relaxed);
            shared.sign_ins.kill_all();
            shared.github.kill();
            shared.harness.end_all_warm();
            shared.harness.shell.end_all();
            tokio::join!(jobs.shutdown(JOBS_GRACE), plugins.shutdown());
        })
    };
    let give_up_at = {
        let mut stopping = stopping_rx;
        async move {
            while !*stopping.borrow() {
                if stopping.changed().await.is_err() {
                    std::future::pending::<()>().await;
                }
            }
            tokio::time::sleep(SHUTDOWN_GRACE).await;
        }
    };
    let result = tokio::select! {
        result = server => result.map_err(StartError::Serve),
        () = give_up_at => {
            tracing::warn!("requests still under way {}s after the stop; exiting anyway", SHUTDOWN_GRACE.as_secs());
            Ok(())
        }
    };
    // Within PLUGINS_GRACE of the stop, whatever the server took.
    let deadline = stopped_at
        .get()
        .copied()
        .unwrap_or_else(tokio::time::Instant::now)
        + PLUGINS_GRACE;
    if tokio::time::timeout_at(deadline, ending).await.is_err() {
        tracing::warn!(
            "plug-ins or jobs still stopping {}s after the stop; exiting anyway",
            PLUGINS_GRACE.as_secs()
        );
    }
    result
}

/// How long each of `serve`'s steps took until obid answers, said in one line (`obid started in
/// 312 ms: worktrees 202, vault 3, …`), as each turn's stopwatch line is (docs/fast-replies.md).
struct Stopwatch {
    started: std::time::Instant,
    last: std::time::Instant,
    laps: Vec<(&'static str, u128)>,
}

impl Stopwatch {
    fn new() -> Stopwatch {
        let now = std::time::Instant::now();
        Stopwatch {
            started: now,
            last: now,
            laps: Vec::new(),
        }
    }

    /// `step` ended now.
    fn lap(&mut self, step: &'static str) {
        let now = std::time::Instant::now();
        self.laps.push((step, (now - self.last).as_millis()));
        self.last = now;
    }

    fn line(&self) -> String {
        let laps: Vec<String> = self
            .laps
            .iter()
            .map(|(step, ms)| format!("{step} {ms}"))
            .collect();
        format!(
            "obid started in {} ms: {} (ms)",
            self.started.elapsed().as_millis(),
            laps.join(", ")
        )
    }
}

/// Sets its flag when dropped: what ends the worktrees' walk when `serve` returns.
struct SetOnDrop(Arc<AtomicBool>);

impl Drop for SetOnDrop {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

/// A walk of the worktrees that panicked (or was cancelled by the runtime) is said in the log.
fn log_walk(walked: Result<(), tokio::task::JoinError>) {
    if let Err(e) = walked {
        tracing::error!("measuring the job worktrees failed: {e}");
    }
}

/// A walk that outlasted [`MEASURE_FIRST`], once it ends: its number goes to the apps as the
/// `cleanup` event, as `status.cleanup` says it from then on. Nothing for a walk that failed or
/// was cut short.
async fn walk_ended(
    walk: tokio::task::JoinHandle<()>,
    events: events::Events,
    cleanup: Arc<api::Cleanup>,
) {
    let walked = walk.await;
    let ended = walked.is_ok();
    log_walk(walked);
    if let Some(json) = ended.then(|| api::cleanup_json(&cleanup)).flatten() {
        events.send("cleanup", serde_json::to_value(json).unwrap_or_default());
    }
}

/// SIGTERM and SIGINT, caught. [`StopSignal::install`] replaces their default action (end the
/// process) at once, so obid installs it before it does anything else: a signal that comes while
/// obid is starting, or the moment it says it listens, is kept until [`StopSignal::wait`] reads
/// it, and obid stops with exit 0 rather than being killed.
pub struct StopSignal {
    #[cfg(unix)]
    term: tokio::signal::unix::Signal,
    #[cfg(unix)]
    int: tokio::signal::unix::Signal,
}

impl StopSignal {
    /// Catches SIGTERM and SIGINT from now on. Call it inside a Tokio runtime (`Runtime::enter`).
    pub fn install() -> std::io::Result<StopSignal> {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{SignalKind, signal};
            Ok(StopSignal {
                term: signal(SignalKind::terminate())?,
                int: signal(SignalKind::interrupt())?,
            })
        }
        #[cfg(not(unix))]
        {
            Ok(StopSignal {})
        }
    }

    /// Resolves on the first SIGTERM or SIGINT since [`StopSignal::install`].
    pub async fn wait(mut self) {
        #[cfg(unix)]
        {
            tokio::select! {
                _ = self.term.recv() => tracing::info!("SIGTERM: stopping"),
                _ = self.int.recv() => tracing::info!("SIGINT: stopping"),
            }
        }
        #[cfg(not(unix))]
        {
            let _ = &mut self;
            let _ = tokio::signal::ctrl_c().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// A walk that ends after obid answers goes to the apps as `cleanup`; one that panics or is
    /// cut short sends nothing.
    #[tokio::test]
    async fn a_late_walk_is_sent_as_cleanup() {
        let events = events::Events::new();
        let mut heard = events.subscribe();
        let cleanup = Arc::new(api::Cleanup::unmeasured(Path::new("/nonexistent/obid")));
        let (go, wait) = std::sync::mpsc::channel::<()>();
        let walk = {
            let cleanup = cleanup.clone();
            tokio::task::spawn_blocking(move || {
                wait.recv().unwrap();
                cleanup.remeasure();
            })
        };
        let ended = tokio::spawn(walk_ended(walk, events.clone(), cleanup.clone()));
        go.send(()).unwrap();
        ended.await.unwrap();
        let event = heard.recv().await.unwrap();
        assert_eq!(event.name, "cleanup");
        assert_eq!(
            event.data,
            serde_json::json!({"path": "/nonexistent/obid/worktrees", "bytes": 0, "lastRun": null, "kept": []})
        );

        let silent = Arc::new(api::Cleanup::unmeasured(Path::new("/nonexistent/obid")));
        let cut_short = {
            let silent = silent.clone();
            tokio::task::spawn_blocking(move || silent.remeasure_unless(&AtomicBool::new(true)))
        };
        walk_ended(cut_short, events.clone(), silent.clone()).await;
        let panicked = tokio::task::spawn_blocking(|| panic!("a walk that fails"));
        walk_ended(panicked, events.clone(), silent).await;
        assert!(heard.try_recv().is_err(), "nothing more was sent");
    }
}
