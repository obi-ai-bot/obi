//! The runner API (docs/runner-api.md) as obid serves it: the gate every request goes through,
//! `GET /v1/status`, the jobs (`/v1/jobs…`, their messages, `POST /v1/stop-all`), `POST
//! /v1/clear`, `POST /v1/devices`, `GET /v1/checks/next`, `/v1/settings/jobs` and the event
//! stream, plans and conversation. The rest of the API joins the same router.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use axum::Router;
use axum::extract::{Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use serde::Serialize;

use crate::config::Config;
use crate::events::Events;
use crate::jobs::Jobs;
use crate::token;

/// The runner API version obid serves: the Swift runner's (Runner/API.swift), which the apps
/// already speak.
pub const API_VERSION: &str = "0.2.0";

/// What every handler shares.
pub struct Shared {
    pub config: Config,
    pub token: String,
    pub host: String,
    pub cleanup: Cleanup,
    /// When Clear done was last pressed (`POST /v1/clear`).
    pub cleared: crate::clear::Cleared,
    /// The devices that may approve publishing (`POST /v1/devices`).
    pub devices: crate::devices::Devices,
    /// The phones paired with the gateway, and the open invitation (crate::gateway).
    pub gateway: crate::gateway::Gateway,
    /// Connected apps and their job-scoped MCP broker.
    pub connections: Arc<crate::connections::Connections>,
    pub jobs: Arc<Jobs>,
    pub events: Events,
    /// The conversations, shared by every device and plan request (#493).
    pub conversations: crate::conversation::Conversations,
    /// What agents made to be looked at (crate::artifacts).
    pub artifacts: Arc<crate::artifacts::Artifacts>,
    /// The conversation turns under way, for Stop and cancel (#546).
    pub turns: crate::brain::turn::Turns,
    /// The conversation turns under way in an agent session, by their MCP token
    /// (crate::brain::harness).
    pub harness: crate::brain::harness::Sessions,
    /// When the owner last sent a message or tapped, and the recap kept for the next answer (#594).
    pub presence: crate::brain::recap::Presence,
    /// Its Sphere: membership, exchanges, the inbox and decisions.
    pub link: Arc<crate::sphere::Link>,
    /// The plug-in host (`GET` and `PUT /v1/obid/plugins`).
    pub plugins: Arc<crate::plugins::Plugins>,
    /// The accounts' sign-ins under way (crate::accounts).
    pub sign_ins: crate::accounts::SignIns,
    /// The browsers signed in to the web app's own files (crate::web): nothing under `/v1`.
    pub pages: crate::web::Sessions,
    /// What GitHub wants from the owner (crate::github_work).
    pub github: Arc<crate::github_work::Feed>,
    /// True once obid is stopping: streams end.
    pub stopping: tokio::sync::watch::Receiver<bool>,
}

/// What `status.cleanup` says: the job worktrees' folder and the disk space it took when last
/// measured. As Engine/Cleanup.swift, it's measured when obid starts and again after each cleanup
/// pass, never per request: a walk of every worktree, `node_modules` and all, on each status poll
/// from each app would cost far more than the number is worth.
pub struct Cleanup {
    pub path: PathBuf,
    bytes: AtomicU64,
}

impl Cleanup {
    /// Measures `home/worktrees` now. It walks the whole tree, so call it off the async threads.
    pub fn measure(home: &Path) -> Cleanup {
        Cleanup::measure_unless(home, &AtomicBool::new(false))
    }

    /// [`Cleanup::measure`], that gives up as soon as `cancelled` is set (obid was told to stop
    /// while it measured); the bytes are then what it had counted, and nobody should use them.
    pub fn measure_unless(home: &Path, cancelled: &AtomicBool) -> Cleanup {
        let path = worktrees(home);
        let bytes = AtomicU64::new(disk_usage_unless(&path, cancelled));
        Cleanup { path, bytes }
    }

    /// The disk space as last measured.
    pub fn bytes(&self) -> u64 {
        self.bytes.load(Ordering::Relaxed)
    }

    /// Measures again, as a cleanup pass does when it ends. Walks the whole tree, like `measure`.
    pub fn remeasure(&self) {
        self.bytes.store(disk_usage(&self.path), Ordering::Relaxed);
    }
}

/// The router: every endpoint, behind the gate.
pub fn router(shared: Arc<Shared>) -> Router {
    Router::new()
        .route("/v1/status", get(status))
        .route("/v1/accounts", post(crate::accounts::add))
        .route(
            "/v1/accounts/{id}",
            axum::routing::patch(crate::accounts::change).delete(crate::accounts::remove),
        )
        .route(
            "/v1/accounts/{id}/sign-in",
            get(crate::accounts::sign_in)
                .post(crate::accounts::sign_in_code)
                .delete(crate::accounts::end_sign_in),
        )
        .route(
            "/v1/jobs",
            get(crate::routes::jobs).post(crate::routes::dispatch),
        )
        .route("/v1/jobs/{id}", get(crate::routes::job))
        .route("/v1/jobs/{id}/wait", get(crate::routes::wait))
        .route("/v1/jobs/{id}/stop", post(crate::routes::stop))
        .route("/v1/jobs/{id}/dismiss", post(crate::routes::dismiss))
        .route("/v1/jobs/{id}/messages", post(crate::routes::message))
        .route("/v1/jobs/{id}/permission", post(crate::routes::permission))
        .route("/v1/jobs/{id}/mode", post(crate::routes::mode))
        .route(
            "/v1/settings/permissions",
            get(crate::routes::permission_settings).put(crate::routes::set_permission_settings),
        )
        .route(
            "/v1/permissions/rules",
            get(crate::routes::permission_rules),
        )
        .route(
            "/v1/permissions/rules/{id}",
            axum::routing::delete(crate::routes::forget_permission_rule),
        )
        .route(
            "/v1/jobs/{id}/publish",
            get(crate::routes::publish_action).post(crate::routes::publish),
        )
        .route("/v1/stop-all", post(crate::routes::stop_all))
        .route("/v1/clear", post(crate::routes::clear))
        .route("/v1/devices", post(crate::routes::register_device))
        .merge(crate::connections::router())
        .route("/v1/checks/next", get(crate::routes::next_check))
        .route("/v1/checks/{id}/bundle", get(crate::routes::check_bundle))
        .route("/v1/checks/{id}/result", post(crate::routes::check_result))
        .route(
            "/v1/agent/apple-check",
            get(crate::routes::apple_check).post(crate::routes::apple_check),
        )
        .route(
            "/v1/settings/jobs",
            get(crate::routes::job_settings).put(crate::routes::set_job_settings),
        )
        .route("/v1/events", get(crate::routes::events))
        .route("/v1/conversation", get(crate::conversation::get))
        .route("/v1/conversations", get(crate::conversation::list))
        .route(
            "/v1/conversations/{id}",
            axum::routing::patch(crate::conversation::update).delete(crate::conversation::remove),
        )
        .route("/v1/artifacts", get(crate::artifacts::list))
        .route(
            "/v1/artifacts/{id}",
            get(crate::artifacts::get)
                .patch(crate::artifacts::update)
                .delete(crate::artifacts::remove),
        )
        .route(
            "/v1/artifacts/{id}/{version}/{*path}",
            get(crate::artifacts::file),
        )
        .route("/v1/plans", post(crate::brain::plan))
        .route("/v1/plans/cancel", post(crate::brain::cancel))
        .route("/v1/conversation/stop", post(crate::brain::stop))
        .route("/v1/github/work", get(crate::github_work::get))
        .route("/v1/github/work/refresh", post(crate::github_work::refresh))
        .route(
            "/v1/github/work/{id}/start",
            post(crate::github_work::start),
        )
        .route("/v1/inbox", get(crate::sphere::routes::inbox))
        .route("/v1/failures", get(crate::failures::list_route))
        .route("/v1/failures/{id}", get(crate::failures::get_route))
        .route("/v1/failures/{id}/fix", post(crate::failures::fix_route))
        .route("/v1/inbox/{id}/answer", post(crate::sphere::routes::answer))
        .route("/v1/obid/sphere", get(crate::sphere::routes::membership))
        .route("/v1/obid/sphere/key", post(crate::sphere::routes::key))
        .route("/v1/obid/sphere/card", post(crate::sphere::routes::card))
        .route("/v1/obid/sphere/join", post(crate::sphere::routes::join))
        .route(
            "/v1/obid/sphere/requests",
            post(crate::sphere::routes::request),
        )
        .route(
            "/v1/obid/sphere/exchanges",
            get(crate::sphere::routes::exchanges),
        )
        .route(
            "/v1/obid/sphere/exchanges/{id}",
            get(crate::sphere::routes::exchange),
        )
        .route("/v1/obid/plugins", get(crate::plugins::list))
        .route(
            "/v1/obid/plugins/{id}",
            axum::routing::put(crate::plugins::set),
        )
        // The web app (apps/web) and how a browser signs in to it (crate::web).
        .route("/app", get(crate::web::bare))
        .route("/app/", get(crate::web::index))
        .route("/app/{*path}", get(crate::web::file))
        .route(crate::web::SIGN_IN, post(crate::web::sign_in))
        .route(crate::web::SIGN_OUT, post(crate::web::sign_out))
        .route("/v1/obid/decisions", get(crate::sphere::routes::decisions))
        .route(
            "/v1/obid/decisions/{id}",
            axum::routing::delete(crate::sphere::routes::forget),
        )
        .route("/v1/obid/sharing", get(crate::sphere::routes::sharing))
        .route(
            "/v1/obid/sharing/rules",
            post(crate::sphere::routes::add_rule),
        )
        .route(
            "/v1/obid/sharing/rules/{id}",
            axum::routing::delete(crate::sphere::routes::forget_rule),
        )
        .route(
            "/v1/obid/sharing/limits",
            axum::routing::put(crate::sphere::routes::limits),
        )
        .route("/v1/pairing/invite", post(crate::gateway::invite))
        .route("/v1/pairing/devices", get(crate::gateway::devices))
        .route(
            "/v1/pairing/devices/{id}",
            axum::routing::delete(crate::gateway::revoke),
        )
        .fallback(not_found)
        .method_not_allowed_fallback(method_not_allowed)
        .layer(middleware::from_fn(crate::vault::answers))
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
/// API token (`401` otherwise). Unlike a Mac runner's gate (Runner/API.swift, `Gate.admit`), OAuth
/// discovery paths get no exception: runner-api.md, "obid only: configuration", says anything
/// without the token is `401`, so they are `401` without it and `404` with it. The one exception
/// is the web app's own files (crate::web): a browser that signed in with the token opens them
/// with its page session, which admits nothing else; signing in and out pass on a loopback `Host`
/// alone. Without the token or a session, a page under `/app` is the sign-in form, still `401`.
/// Every `/v1` answer is `Cache-Control: no-store` (unless it says otherwise) and `nosniff`.
async fn gate(State(shared): State<Arc<Shared>>, request: Request, next: Next) -> Response {
    if crate::web::is_open(request.method(), request.uri())
        && loopback_request(request.uri(), request.headers())
    {
        return next.run(request).await;
    }
    let api = request.uri().path().starts_with("/v1/");
    let agent_check = request.uri().path() == "/v1/agent/apple-check";
    let agent_mcp = request
        .uri()
        .path()
        .strip_prefix("/v1/agent/mcp/")
        .filter(|id| !id.is_empty() && !id.contains('/'));
    let admitted = admit(request.uri(), request.headers(), &shared.token).or_else(|error| {
        if (!agent_check && agent_mcp.is_none())
            || (!loopback_request(request.uri(), request.headers())
                && !agent_mcp
                    .is_some_and(|_| agent_gateway_request(request.uri(), request.headers())))
        {
            return Err(error);
        }
        let mut values = request.headers().get_all(header::AUTHORIZATION).iter();
        let given = match (values.next(), values.next()) {
            (Some(value), None) => value.to_str().ok().and_then(bearer),
            _ => None,
        };
        if given.is_some_and(|token| {
            (agent_check && shared.jobs.is_apple_check_token(token))
                || agent_mcp.is_some_and(|id| {
                    shared.connections.allows(id, token)
                        || shared.harness.session(id, token).is_some()
                })
        }) {
            Ok(())
        } else {
            Err(error)
        }
    });
    let admitted = admitted.or_else(|error| {
        let (method, uri, headers) = (request.method(), request.uri(), request.headers());
        if error.status == StatusCode::UNAUTHORIZED
            && crate::web::admitted(method, uri, headers, &shared.pages)
        {
            Ok(())
        } else {
            Err(error)
        }
    });
    let mut response = match admitted {
        Ok(()) => next.run(request).await,
        Err(error)
            if error.status == StatusCode::UNAUTHORIZED
                && request.method() == axum::http::Method::GET
                && crate::web::is_app(request.uri().path()) =>
        {
            crate::web::sign_in_page(None)
        }
        Err(error) => error.into_response(),
    };
    if api {
        let headers = response.headers_mut();
        if !headers.contains_key(header::CACHE_CONTROL) {
            headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
        }
        headers.insert(
            header::X_CONTENT_TYPE_OPTIONS,
            HeaderValue::from_static("nosniff"),
        );
    }
    response
}

/// On Linux, sandboxed agents reach the host through slirp4netns at 10.0.2.2. Admit that fixed
/// host only for the job-token MCP route; normal app API requests still require a loopback Host.
fn agent_gateway_request(uri: &axum::http::Uri, headers: &HeaderMap) -> bool {
    cfg!(target_os = "linux") && gateway_host(uri, headers)
}

/// The request names the slirp4netns host alias, `10.0.2.2` (any port), in its one `Host`, and
/// no other authority.
fn gateway_host(uri: &axum::http::Uri, headers: &HeaderMap) -> bool {
    if uri.authority().is_some() {
        return false;
    }
    let mut hosts = headers.get_all(header::HOST).iter();
    let Some(host) = hosts.next().and_then(|h| h.to_str().ok()) else {
        return false;
    };
    if hosts.next().is_some() {
        return false;
    }
    let host = host.trim_matches(|c| c == ' ' || c == '\t');
    host == "10.0.2.2" || host.strip_prefix("10.0.2.2:").is_some_and(is_port)
}

/// Throws the refusal, or lets the request through.
pub fn admit(uri: &axum::http::Uri, headers: &HeaderMap, token: &str) -> Result<(), ApiError> {
    if !loopback_request(uri, headers) {
        return Err(ApiError::new(StatusCode::FORBIDDEN, NOT_LOOPBACK));
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
    /// Who pays for it, as the owner put it, or null.
    pub payer: Option<String>,
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

/// Every account, as `GET /v1/status` and the `accounts` event send them.
pub fn account_list(shared: &Shared) -> Vec<AccountJson> {
    let agents = shared.config.agents.get();
    crate::agent::Tool::ALL
        .into_iter()
        .filter_map(|tool| {
            match tool {
                crate::agent::Tool::Claude => &agents.claude,
                crate::agent::Tool::Codex => &agents.codex,
                crate::agent::Tool::Cursor => &agents.cursor,
            }
            .as_ref()
            .map(|configured| (tool, configured))
        })
        .flat_map(|(tool, configured)| {
            configured
                .accounts
                .iter()
                .map(move |account| account_json(shared, tool, account))
        })
        .collect()
}

/// An account (docs/runner-api.md, "Account"), as obid knows it before any job has run on it.
pub fn account_json(
    shared: &Shared,
    tool: crate::agent::Tool,
    account: &crate::config::Account,
) -> AccountJson {
    let home = crate::jobs::login_home();
    AccountJson {
        id: account.id.clone(),
        agent: tool.id(),
        name: account.name.clone(),
        payer: account.payer.clone(),
        label: None,
        // Whether its login file is there (#626); Cursor's is found out when it runs.
        signed_in: crate::jobs::signed_in(tool, account, home.as_deref()),
        five_hour: None,
        seven_day: None,
        five_hour_resets: None,
        seven_day_resets: None,
        running: shared.jobs.running_on(&account.id) as u32,
        full_until: None,
        tetrix: None,
        tetrix_jobs: 0,
        tetrix_used: 0,
        reserved: false,
        reserve_lifted_until: None,
    }
}

async fn status(State(shared): State<Arc<Shared>>) -> Result<axum::Json<Status>, ApiError> {
    let accounts = crate::accounts::list_now(&shared).await;
    Ok(axum::Json(Status {
        runner: RunnerJson {
            version: API_VERSION,
            host: shared.host.clone(),
            engine: "obid",
        },
        accounts,
        models: Models::defaults(),
        max_running: shared.jobs.max_running() as u32,
        running: shared.jobs.running() as u32,
        cleared_at: shared.cleared.at().map(obi_protocol::time::format),
        // obid has no GitHub app: its own GitHub calls, once it makes any, go as the owner.
        github: "owner",
        checks: "no app",
        // Settings › Permissions: sandbox until the owner picks another (docs/runner-api.md, "Permission modes").
        permissions: ModeJson {
            mode: shared.jobs.default_mode().as_str(),
        },
        cleanup: CleanupJson {
            path: shared.cleanup.path.to_string_lossy().into_owned(),
            bytes: shared.cleanup.bytes(),
            // obid has no cleanup pass yet; when it does, it sets this and calls `remeasure`.
            last_run: None,
        },
    }))
}

/// The disk space allocated under `path`, each file counted once however many links it has; 0 when
/// it doesn't exist. Symbolic links are counted as themselves, never followed.
pub fn disk_usage(path: &Path) -> u64 {
    disk_usage_unless(path, &AtomicBool::new(false))
}

/// [`disk_usage`], stopping early once `cancelled` is set.
fn disk_usage_unless(path: &Path, cancelled: &AtomicBool) -> u64 {
    let mut seen = std::collections::HashSet::new();
    let mut total = 0u64;
    let mut stack = vec![path.to_path_buf()];
    while let Some(next) = stack.pop() {
        if cancelled.load(Ordering::Relaxed) {
            break;
        }
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
        if meta.is_dir()
            && let Ok(entries) = std::fs::read_dir(&next)
        {
            stack.extend(entries.flatten().map(|e| e.path()));
        }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Only the slirp4netns host alias, alone in one `Host`, is the agents' gateway; the gate
    /// admits it on Linux, and only on `/v1/agent/mcp/{job}` with that job's token.
    #[test]
    fn the_agents_gateway_is_only_the_slirp_host() {
        let ask = |uri: &str, hosts: &[&str]| {
            let mut headers = HeaderMap::new();
            for host in hosts {
                headers.append(header::HOST, host.parse().unwrap());
            }
            gateway_host(&uri.parse().unwrap(), &headers)
        };
        for host in ["10.0.2.2", "10.0.2.2:7777", " 10.0.2.2:1 "] {
            assert!(ask("/v1/agent/mcp/job1", &[host]), "{host}");
        }
        for hosts in [
            &["10.0.2.3"][..],
            &["10.0.2.2.evil.example"],
            &["10.0.2.2:"],
            &["10.0.2.2:x"],
            &["10.0.2.2:7777:1"],
            &["evil.example"],
            &["127.0.0.1"],
            &["10.0.2.2", "10.0.2.2"],
            &[],
        ] {
            assert!(!ask("/v1/agent/mcp/job1", hosts), "{hosts:?}");
        }
        assert!(!ask("http://evil.example/v1/agent/mcp/job1", &["10.0.2.2"]));
        assert_eq!(
            agent_gateway_request(&"/v1/agent/mcp/job1".parse().unwrap(), &{
                let mut headers = HeaderMap::new();
                headers.insert(header::HOST, "10.0.2.2".parse().unwrap());
                headers
            }),
            cfg!(target_os = "linux"),
            "the gateway is Linux's alone"
        );
    }

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
