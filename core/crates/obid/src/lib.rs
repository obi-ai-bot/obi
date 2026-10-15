//! obid: Obi's engine as a daemon. It serves the runner API (docs/runner-api.md) on 127.0.0.1,
//! so the Mac, iPhone and Watch apps run against it unchanged, plus the endpoints in that
//! document's "obid only" section. docs/ARCHITECTURE.md says how it fits with the rest.

// The job's JSON (`job::Job::to_json`) has every key the apps expect, in one `json!`.
#![recursion_limit = "256"]

pub mod agent;
pub mod api;
pub mod clear;
pub mod config;
pub mod events;
pub mod git;
pub mod job;
pub mod jobs;
pub mod policy;
pub mod process;
pub mod review;
pub mod routes;
pub mod sandbox;
pub mod scan;
pub mod sphere;
pub mod store;
pub mod token;

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

/// Serves the API on `config.listen` until `stop` resolves, then lets requests under way finish
/// for at most [`SHUTDOWN_GRACE`]. `ready` is told the address once obid is listening.
///
/// Before it answers, obid measures `home/worktrees` (`status.cleanup.bytes`), which walks every
/// worktree and can take a while. A `stop` that resolves meanwhile ends that walk and returns at
/// once, without `ready` being told anything: a stop while starting is a stop, not a wait.
pub async fn serve(
    config: Config,
    token: String,
    stop: impl Future<Output = ()> + Send + 'static,
    ready: impl FnOnce(SocketAddr),
) -> Result<(), StartError> {
    let address = config.listen;
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .map_err(|source| StartError::Listen { address, source })?;
    let bound = listener
        .local_addr()
        .map_err(|source| StartError::Listen { address, source })?;
    let host = gethostname::gethostname().to_string_lossy().into_owned();
    let home = config.home.clone();
    let cancelled = Arc::new(AtomicBool::new(false));
    let measuring = {
        let cancelled = cancelled.clone();
        tokio::task::spawn_blocking(move || api::Cleanup::measure_unless(&home, &cancelled))
    };
    let mut stop = Box::pin(stop);
    let cleanup = tokio::select! {
        // A stop that is there already wins over a measurement that is done too.
        biased;
        () = &mut stop => {
            cancelled.store(true, Ordering::Relaxed);
            tracing::info!("stopped while starting");
            return Ok(());
        }
        measured = measuring => measured.map_err(|e| StartError::Serve(std::io::Error::other(e)))?,
    };
    let events = events::Events::new();
    let sandbox = sandbox::Sandbox::detect();
    if let Err(why) = &sandbox {
        tracing::warn!("no job sandbox, so no job will run: {why}");
    }
    let jobs = jobs::Jobs::open(config.clone(), events.clone(), sandbox).map_err(|source| {
        StartError::Jobs {
            path: config.home.join("jobs"),
            source,
        }
    })?;
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
    let cleared = clear::Cleared::open(&config.home);
    let shared = Arc::new(api::Shared {
        config,
        token,
        host,
        cleanup,
        cleared,
        jobs: jobs.clone(),
        events,
        link: link.clone(),
        stopping: stopping_rx.clone(),
    });
    let app = api::router(shared);

    let server = axum::serve(listener, app).with_graceful_shutdown(async move {
        stop.await;
        let _ = stopping_tx.send(true);
    });
    ready(bound);
    // Jobs that were queued or running when obid last stopped carry on, and so does its Sphere.
    jobs.resume();
    link.start();
    // Once told to stop: every agent and check ends now, and its job stays as it is for the next
    // start; the event streams and waits end, so the server's connections close.
    let ending = {
        let jobs = jobs.clone();
        let mut stopping = stopping_rx.clone();
        tokio::spawn(async move {
            while !*stopping.borrow() {
                if stopping.changed().await.is_err() {
                    return;
                }
            }
            jobs.shutdown(JOBS_GRACE).await;
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
    let _ = tokio::time::timeout(JOBS_GRACE, ending).await;
    result
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
