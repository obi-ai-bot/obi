//! The runner API (docs/runner-api.md) as obid serves it. This first version has the gate every
//! request goes through and `GET /v1/status`; the rest of the API joins the same router.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::Router;
use axum::extract::{Request, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use serde::Serialize;

use crate::config::Config;
use crate::token;

/// The runner API version obid serves: the Swift runner's (Runner/API.swift), which the apps
/// already speak.
pub const API_VERSION: &str = "0.2.0";

/// What every handler shares.
pub struct Shared {
    pub config: Config,
    pub token: String,
    pub host: String,
}

/// The router: every endpoint, behind the gate.
pub fn router(shared: Arc<Shared>) -> Router {
    Router::new()
        .route("/v1/status", get(status))
        .fallback(not_found)
        .method_not_allowed_fallback(method_not_allowed)
        .layer(middleware::from_fn_with_state(shared.clone(), gate))
        .with_state(shared)
}

/// `{"error": "One line a person can read."}` with a 4xx or 5xx status.
pub struct ApiError {
    pub status: StatusCode,
    pub message: String,
}

impl ApiError {
    pub fn new(status: StatusCode, message: impl Into<String>) -> ApiError {
        ApiError {
            status,
            message: message.into(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            axum::Json(serde_json::json!({ "error": self.message })),
        )
            .into_response()
    }
}

pub const NOT_LOOPBACK: &str = "This runner answers only on 127.0.0.1.";
pub const NO_TOKEN: &str = "This runner answers only requests with its API token.";

/// Every request, before anything else: its `Host` must be a loopback name (`403` otherwise, so a
/// web page can't reach obid through a name that resolves to 127.0.0.1), then it must carry the
/// API token (`401` otherwise). As a Mac runner's gate (Runner/API.swift, `Gate.admit`), a tool's
/// OAuth discovery gets a plain `404` after the host check, without a token.
async fn gate(State(shared): State<Arc<Shared>>, request: Request, next: Next) -> Response {
    match admit(request.uri(), request.headers(), &shared.token) {
        Ok(()) => next.run(request).await,
        Err(error) => error.into_response(),
    }
}

/// Throws the refusal, or lets the request through.
pub fn admit(uri: &axum::http::Uri, headers: &HeaderMap, token: &str) -> Result<(), ApiError> {
    if !loopback_request(uri, headers) {
        return Err(ApiError::new(StatusCode::FORBIDDEN, NOT_LOOPBACK));
    }
    if is_oauth_discovery(uri.path()) {
        return Err(ApiError::new(StatusCode::NOT_FOUND, "Not found."));
    }
    let mut values = headers.get_all(header::AUTHORIZATION).iter();
    let given = match (values.next(), values.next()) {
        (Some(value), None) => value.to_str().ok().and_then(bearer),
        _ => None,
    };
    match given {
        Some(given) if token::same(given, token) => Ok(()),
        _ => Err(ApiError::new(StatusCode::UNAUTHORIZED, NO_TOKEN)),
    }
}

/// Exactly one `Host`, a loopback name; and when the request line names an authority itself
/// (absolute form), that one too.
fn loopback_request(uri: &axum::http::Uri, headers: &HeaderMap) -> bool {
    let mut hosts = headers.get_all(header::HOST).iter();
    let host = match (hosts.next(), hosts.next()) {
        (Some(host), None) => host.to_str().ok(),
        _ => None,
    };
    let Some(host) = host else { return false };
    if !is_loopback(host) {
        return false;
    }
    uri.authority().is_none_or(|a| is_loopback(a.as_str()))
}

/// `127.0.0.1`, `localhost` or `[::1]`, with or without a port, ignoring case and surrounding
/// spaces (Engine/LocalRunner.swift, `isLoopback`).
pub fn is_loopback(header: &str) -> bool {
    let host = header
        .trim_matches(|c| c == ' ' || c == '\t')
        .to_ascii_lowercase();
    if host.is_empty() {
        return false;
    }
    if let Some(rest) = host.strip_prefix('[') {
        // An IPv6 literal: `[::1]` or `[::1]:7777`.
        let Some((inside, after)) = rest.split_once(']') else {
            return false;
        };
        let port_ok = after.is_empty() || after.strip_prefix(':').is_some_and(is_port);
        return port_ok && inside == "::1";
    }
    let name = match host.rsplit_once(':') {
        Some((name, port)) => {
            if !is_port(port) {
                return false;
            }
            name
        }
        None => host.as_str(),
    };
    name == "127.0.0.1" || name == "localhost"
}

/// A port: one to five digits.
fn is_port(text: &str) -> bool {
    (1..=5).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_digit())
}

/// The paths an OAuth client asks for: the well-known documents and the registration,
/// authorization and token endpoints.
fn is_oauth_discovery(path: &str) -> bool {
    path.starts_with("/.well-known/") || matches!(path, "/register" | "/authorize" | "/token")
}

/// The token in `Authorization: Bearer <token>`, or none.
fn bearer(header: &str) -> Option<&str> {
    let token = header.strip_prefix("Bearer ")?.trim_matches(' ');
    (!token.is_empty()).then_some(token)
}

async fn not_found() -> ApiError {
    ApiError::new(StatusCode::NOT_FOUND, "There's no such endpoint.")
}

async fn method_not_allowed() -> ApiError {
    ApiError::new(
        StatusCode::METHOD_NOT_ALLOWED,
        "This endpoint doesn't take that method.",
    )
}

// ---------------------------------------------------------------------------------------------
// GET /v1/status

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub runner: RunnerJson,
    pub accounts: Vec<AccountJson>,
    pub models: Models,
    pub max_running: u32,
    pub running: u32,
    pub cleared_at: Option<String>,
    pub github: &'static str,
    pub checks: &'static str,
    pub permissions: ModeJson,
    pub cleanup: CleanupJson,
}

#[derive(Serialize)]
pub struct RunnerJson {
    pub version: &'static str,
    pub host: String,
    /// `obid`: what tells the apps and the e2e harness this runner is obid, not the Swift one.
    pub engine: &'static str,
}

/// An account (docs/runner-api.md, "Account"), as obid knows it before any job has run on it.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountJson {
    pub id: String,
    pub agent: &'static str,
    pub name: String,
    pub label: Option<String>,
    pub signed_in: bool,
    pub five_hour: Option<f64>,
    pub seven_day: Option<f64>,
    pub five_hour_resets: Option<String>,
    pub seven_day_resets: Option<String>,
    pub running: u32,
    pub full_until: Option<String>,
    pub tetrix: Option<bool>,
    pub tetrix_jobs: u32,
    pub tetrix_used: u32,
    pub reserved: bool,
    pub reserve_lifted_until: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Models {
    pub claude: Choice,
    pub codex: Choice,
    pub cursor: CursorChoice,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Choice {
    pub model: &'static str,
    pub effort: &'static str,
    pub complex_effort: &'static str,
}

#[derive(Serialize)]
pub struct CursorChoice {
    pub model: &'static str,
}

impl Models {
    /// The defaults, as Engine/Models.swift has them (`AgentModels.defaults`), until Settings ›
    /// Models changes them.
    pub fn defaults() -> Models {
        Models {
            claude: Choice {
                model: "claude-opus-5-5",
                effort: "xhigh",
                complex_effort: "xhigh",
            },
            codex: Choice {
                model: "gpt-6.1-sol",
                effort: "high",
                complex_effort: "high",
            },
            cursor: CursorChoice { model: "auto" },
        }
    }
}

#[derive(Serialize)]
pub struct ModeJson {
    pub mode: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanupJson {
    pub path: String,
    pub bytes: u64,
    pub last_run: Option<String>,
}

/// How many jobs run at once until Settings changes it (Engine/Jobs.swift, `JobSlots.standard`).
pub const MAX_RUNNING: u32 = 6;

/// Where job worktrees live under `home`.
pub fn worktrees(home: &Path) -> PathBuf {
    home.join("worktrees")
}

async fn status(State(shared): State<Arc<Shared>>) -> Result<axum::Json<Status>, ApiError> {
    let path = worktrees(&shared.config.home);
    let measured = path.clone();
    let bytes = tokio::task::spawn_blocking(move || disk_usage(&measured))
        .await
        .map_err(|e| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    let accounts = shared
        .config
        .agents
        .claude
        .iter()
        .flat_map(|claude| &claude.accounts)
        .map(|account| AccountJson {
            id: account.id.clone(),
            agent: "claude",
            name: account.name.clone(),
            label: None,
            // A listed account is usable until one of its jobs fails on its login.
            signed_in: true,
            five_hour: None,
            seven_day: None,
            five_hour_resets: None,
            seven_day_resets: None,
            running: 0,
            full_until: None,
            tetrix: None,
            tetrix_jobs: 0,
            tetrix_used: 0,
            reserved: false,
            reserve_lifted_until: None,
        })
        .collect();
    Ok(axum::Json(Status {
        runner: RunnerJson {
            version: API_VERSION,
            host: shared.host.clone(),
            engine: "obid",
        },
        accounts,
        models: Models::defaults(),
        max_running: MAX_RUNNING,
        running: 0,
        cleared_at: None,
        // obid has no GitHub app: its own GitHub calls, once it makes any, go as the owner.
        github: "owner",
        checks: "no app",
        // Settings › Permissions: bypass until the owner picks another (Engine/Permissions.swift).
        permissions: ModeJson { mode: "bypass" },
        cleanup: CleanupJson {
            path: path.to_string_lossy().into_owned(),
            bytes,
            last_run: None,
        },
    }))
}

/// The disk space allocated under `path`, each file counted once however many links it has; 0 when
/// it doesn't exist. Symbolic links are counted as themselves, never followed.
pub fn disk_usage(path: &Path) -> u64 {
    let mut seen = std::collections::HashSet::new();
    let mut total = 0u64;
    let mut stack = vec![path.to_path_buf()];
    while let Some(next) = stack.pop() {
        let Ok(meta) = std::fs::symlink_metadata(&next) else {
            continue;
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if meta.nlink() > 1 && !meta.is_dir() && !seen.insert((meta.dev(), meta.ino())) {
                continue;
            }
            total += meta.blocks() * 512;
        }
        #[cfg(not(unix))]
        {
            let _ = &mut seen;
            total += meta.len();
        }
        if meta.is_dir() {
            if let Ok(entries) = std::fs::read_dir(&next) {
                stack.extend(entries.flatten().map(|e| e.path()));
            }
        }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_names() {
        for host in [
            "127.0.0.1",
            "127.0.0.1:7777",
            "localhost",
            "Localhost:1",
            "[::1]",
            "[::1]:7777",
            "LOCALHOST",
            " 127.0.0.1 ",
        ] {
            assert!(is_loopback(host), "{host}");
        }
        for host in [
            "evil.example",
            "evil.example:7777",
            "127.0.0.2",
            "127.0.0.1:",
            "127.0.0.1:7777:1",
            "127.0.0.1:x",
            "[::1",
            "::1",
            "[::2]",
            "[::1]:x",
            "0.0.0.0",
            "localhost.",
            "127.0.0.1.evil.example",
            "localhost.evil.example",
            "tetrix-lab.tail8de49b.ts.net:8443",
            "",
            "   ",
        ] {
            assert!(!is_loopback(host), "{host}");
        }
    }

    #[test]
    fn bearer_tokens() {
        assert_eq!(bearer("Bearer abc"), Some("abc"));
        assert_eq!(bearer("Bearer  abc "), Some("abc"));
        assert_eq!(bearer("Bearer "), None);
        assert_eq!(bearer("Basic abc"), None);
        assert_eq!(bearer("abc"), None);
        assert_eq!(bearer("bearer abc"), None);
    }

    #[test]
    fn disk_usage_of_nothing_is_zero() {
        assert_eq!(disk_usage(Path::new("/nonexistent/obid/worktrees")), 0);
    }
}
