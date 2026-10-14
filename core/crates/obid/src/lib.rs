//! obid: Obi's engine as a daemon. It serves the runner API (docs/runner-api.md) on 127.0.0.1,
//! so the Mac, iPhone and Watch apps run against it unchanged, plus the endpoints in that
//! document's "obid only" section. docs/ARCHITECTURE.md says how it fits with the rest.

pub mod api;
pub mod config;
pub mod token;

use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use config::Config;

/// How long obid waits for requests under way after SIGTERM or SIGINT before it exits anyway.
/// The contract is "exits 0 within 10 seconds".
pub const SHUTDOWN_GRACE: Duration = Duration::from_secs(8);

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
}

/// Makes `home` if it isn't there yet, readable by its owner only.
pub fn prepare_home(config: &Config) -> Result<(), StartError> {
    let home = &config.home;
    let err = |source| StartError::Home {
        path: home.clone(),
        source,
    };
    if home.is_dir() {
        return Ok(());
    }
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(home).map_err(err)
}

/// Serves the API on `config.listen` until `stop` resolves, then lets requests under way finish
/// for at most [`SHUTDOWN_GRACE`]. `ready` is told the address once obid is listening.
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
    let shared = Arc::new(api::Shared {
        config,
        token,
        host,
    });
    let app = api::router(shared);

    let (stopping_tx, stopping_rx) = tokio::sync::oneshot::channel::<()>();
    let server = axum::serve(listener, app).with_graceful_shutdown(async move {
        stop.await;
        let _ = stopping_tx.send(());
    });
    ready(bound);
    let deadline = async move {
        if stopping_rx.await.is_ok() {
            tokio::time::sleep(SHUTDOWN_GRACE).await;
        } else {
            std::future::pending::<()>().await;
        }
    };
    tokio::select! {
        result = server => result.map_err(StartError::Serve),
        () = deadline => {
            tracing::warn!("requests still under way {}s after the stop; exiting anyway", SHUTDOWN_GRACE.as_secs());
            Ok(())
        }
    }
}

/// Resolves on the first SIGTERM or SIGINT.
pub async fn stop_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let mut term = signal(SignalKind::terminate()).expect("SIGTERM handler");
        let mut int = signal(SignalKind::interrupt()).expect("SIGINT handler");
        tokio::select! {
            _ = term.recv() => tracing::info!("SIGTERM: stopping"),
            _ = int.recv() => tracing::info!("SIGINT: stopping"),
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
