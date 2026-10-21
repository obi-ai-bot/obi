//! The routes of Obi-to-Obi work: `/v1/obid/sphere…`, `/v1/obid/decisions…`, `/v1/obid/sharing…`
//! and the inbox (`GET /v1/inbox`, `POST /v1/inbox/{id}/answer`).

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::Value;

use crate::api::{ApiError, Shared};

fn json(status: StatusCode, value: Value) -> Response {
    (status, axum::Json(value)).into_response()
}

#[derive(serde::Deserialize)]
pub struct ListQuery {
    limit: Option<String>,
    state: Option<String>,
}

/// A `limit` from 1 to `max`, `default` when it's left out.
fn limit(text: Option<&str>, default: usize, max: usize) -> Result<usize, ApiError> {
    match text {
        None => Ok(default),
        Some(text) => text
            .parse::<usize>()
            .ok()
            .filter(|n| (1..=max).contains(n))
            .ok_or_else(|| {
                ApiError::new(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    format!("limit is a number from 1 to {max}."),
                )
            }),
    }
}

/// `GET /v1/obid/sphere`.
pub async fn membership(State(shared): State<Arc<Shared>>) -> Response {
    json(StatusCode::OK, shared.link.membership_json())
}

/// `GET /v1/obid/sphere/pins`.
pub async fn pins(State(shared): State<Arc<Shared>>) -> Response {
    json(StatusCode::OK, shared.link.pins_json())
}

/// `POST /v1/obid/sphere/pins/{owner}`.
pub async fn accept_pin(
    State(shared): State<Arc<Shared>>,
    Path(owner): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    Ok(json(
        StatusCode::OK,
        shared.link.accept_pin(&owner, &body).await?,
    ))
}

/// `POST /v1/obid/sphere/key`.
pub async fn key(State(shared): State<Arc<Shared>>) -> Result<Response, ApiError> {
    Ok(json(StatusCode::OK, shared.link.make_key().await?))
}

/// `POST /v1/obid/sphere/card`.
pub async fn card(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    Ok(json(StatusCode::OK, shared.link.card(&body).await?))
}

/// `POST /v1/obid/sphere/join`.
pub async fn join(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    Ok(json(StatusCode::OK, shared.link.join(&body).await?))
}

/// `POST /v1/obid/sphere/requests`.
pub async fn request(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    Ok(json(
        StatusCode::ACCEPTED,
        shared.link.request(&body).await?,
    ))
}

/// `GET /v1/obid/sphere/exchanges?limit=50`.
pub async fn exchanges(
    State(shared): State<Arc<Shared>>,
    Query(query): Query<ListQuery>,
) -> Result<Response, ApiError> {
    let limit = limit(query.limit.as_deref(), 50, 500)?;
    Ok(json(StatusCode::OK, shared.link.exchanges_json(limit)))
}

/// `GET /v1/obid/sphere/exchanges/{correlationId}`.
pub async fn exchange(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    shared
        .link
        .exchange_json(&id)
        .map(|e| json(StatusCode::OK, e))
        .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "There's no such exchange."))
}

/// `GET /v1/obid/decisions`.
pub async fn decisions(State(shared): State<Arc<Shared>>) -> Response {
    json(StatusCode::OK, shared.link.decisions_json())
}

/// `DELETE /v1/obid/decisions/{id}`.
pub async fn forget(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    if shared.link.forget(&id) {
        Ok(StatusCode::NO_CONTENT.into_response())
    } else {
        Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "There's no such decision.",
        ))
    }
}

/// `GET /v1/inbox` and `GET /v1/inbox?state=done&limit=50`.
pub async fn inbox(
    State(shared): State<Arc<Shared>>,
    Query(query): Query<ListQuery>,
) -> Result<Response, ApiError> {
    let done = match query.state.as_deref() {
        None | Some("open") => false,
        Some("done") => true,
        Some(_) => {
            return Err(ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "state is open or done.",
            ));
        }
    };
    // As the Swift runner: 50 unless asked, at most 1,000, and 0 lists nothing.
    let limit = match query.limit.as_deref() {
        None => 50,
        Some(text) => text.parse::<usize>().map_err(|_| {
            ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "limit is a number from 0 to 1,000.",
            )
        })?,
    }
    .min(1000);
    Ok(json(StatusCode::OK, shared.link.inbox_json(done, limit)))
}

/// `POST /v1/inbox/{id}/answer`.
pub async fn answer(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    // A tap is the owner back (#594): after a while away, it gets a recap.
    crate::brain::recap::tapped(&shared);
    Ok(json(StatusCode::OK, shared.link.answer(&id, &body).await?))
}

/// `GET /v1/obid/sharing`.
pub async fn sharing(State(shared): State<Arc<Shared>>) -> Response {
    json(StatusCode::OK, shared.link.sharing_json())
}

/// `GET /v1/obid/sharing/mac`.
pub async fn mac(State(shared): State<Arc<Shared>>) -> Response {
    json(StatusCode::OK, shared.link.mac_json())
}

/// `PUT /v1/obid/sharing/mac`.
pub async fn set_mac(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    Ok(json(StatusCode::OK, shared.link.set_mac(&body)?))
}

/// `POST /v1/obid/sharing/mac/stop` with `{"job": "<correlationId>"}` for one, `{}` for all.
pub async fn stop_guests(
    State(shared): State<Arc<Shared>>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let value: Value = if body.is_empty() {
        serde_json::json!({})
    } else {
        serde_json::from_slice(&body)
            .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "The body isn't JSON."))?
    };
    let one = match value.get("job") {
        None => None,
        Some(Value::String(cid)) => Some(cid.clone()),
        Some(_) => {
            return Err(ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "job is a guest job's correlationId.",
            ));
        }
    };
    let stopped = shared.link.stop_guests(one.as_deref());
    Ok(json(
        StatusCode::OK,
        serde_json::json!({"stopped": stopped}),
    ))
}

/// `GET /v1/obid/sharing/macs`.
pub async fn macs(State(shared): State<Arc<Shared>>) -> Response {
    json(StatusCode::OK, shared.link.macs_json().await)
}

/// `GET /v1/obid/sphere/audit`.
pub async fn audit(State(shared): State<Arc<Shared>>) -> Result<Response, ApiError> {
    Ok(json(StatusCode::OK, shared.link.audit_json().await?))
}

/// `PUT /v1/obid/sphere/membership`.
pub async fn renew(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    Ok(json(StatusCode::OK, shared.link.renew(&body).await?))
}

/// `POST /v1/obid/sharing/rules`.
pub async fn add_rule(
    State(shared): State<Arc<Shared>>,
    body: Bytes,
) -> Result<Response, ApiError> {
    Ok(json(StatusCode::CREATED, shared.link.add_rule(&body)?))
}

/// `DELETE /v1/obid/sharing/rules/{id}`.
pub async fn forget_rule(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    if shared.link.forget_rule(&id) {
        Ok(StatusCode::NO_CONTENT.into_response())
    } else {
        Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "There's no such sharing rule.",
        ))
    }
}

/// `PUT /v1/obid/sharing/limits`.
pub async fn limits(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    Ok(json(StatusCode::OK, shared.link.set_limits(&body)?))
}

/// Sangam's words for an account that isn't shared (Settings › Sharing, "Kept for you").
const PERSONAL: &str =
    "A personal plan is for you alone: its terms don’t let anyone else’s work run on it.";

/// Each of the owner's accounts as Settings › Sharing sorts them (#809, Sangam's design): a
/// company API account obid can share and meter, or one kept for the owner, with why. How an
/// account pays is what its tool said (crate::usage::Usage::priced); obid never reads a login.
fn sharing_accounts(shared: &Shared) -> Vec<Value> {
    crate::api::account_list(shared)
        .into_iter()
        .map(|a| {
            let priced = shared.jobs.usage.get(&a.id).priced;
            let (plan, why) = match (a.agent, priced.as_deref()) {
                ("claude", Some("api")) => ("api", None),
                (_, Some("plan")) => ("personal", Some(PERSONAL)),
                ("codex", Some("api")) => (
                    "api",
                    Some("Oby can’t meter OpenAI’s prices yet, so it isn’t shared."),
                ),
                ("cursor", _) => (
                    "seat",
                    Some("Cursor’s team balance has no meter Oby can read, so it isn’t shared."),
                ),
                _ => (
                    "unknown",
                    Some("Oby learns how it pays the first time it runs a job."),
                ),
            };
            serde_json::json!({"id": a.id, "agent": a.agent, "name": a.name, "plan": plan, "why": why})
        })
        .collect()
}

/// `GET /v1/obid/sharing/grants`: the owner's shares, their accounts as Sharing sorts them, and
/// whether the key the shares run on is in Oby's vault.
pub async fn grants(State(shared): State<Arc<Shared>>) -> Response {
    let key = matches!(
        crate::vault::value(super::guest::key_name("claude")),
        Ok(Some(_))
    );
    json(
        StatusCode::OK,
        serde_json::json!({"grants": shared.link.grants_json(), "accounts": sharing_accounts(&shared), "key": key}),
    )
}

/// `PUT /v1/obid/sharing/grants`: a share of one of the owner's company API accounts.
pub async fn put_grant(
    State(shared): State<Arc<Shared>>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let value: Value = serde_json::from_slice(&body)
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "The body isn't JSON."))?;
    let account = value["account"].as_str().unwrap_or("");
    let name = sharing_accounts(&shared)
        .into_iter()
        .find(|a| a["id"] == account && a["why"].is_null())
        .and_then(|a| a["name"].as_str().map(str::to_owned))
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "account is one of your Claude Code accounts that pays per token (an API key).",
            )
        })?;
    Ok(json(StatusCode::OK, shared.link.put_grant(&value, &name)?))
}

/// `DELETE /v1/obid/sharing/grants/{id}`.
pub async fn delete_grant(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    shared.link.delete_grant(&id)?;
    Ok(StatusCode::NO_CONTENT.into_response())
}

/// `GET /v1/obid/sharing/shared`: the shares teammates gave this owner, and whether this Obi's
/// card takes them.
pub async fn shared_with_me(State(shared): State<Arc<Shared>>) -> Response {
    json(
        StatusCode::OK,
        serde_json::json!({"shares": shared.link.shared_with_me_json(), "takesShares": shared.link.takes_shares()}),
    )
}
