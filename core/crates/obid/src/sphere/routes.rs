//! The routes of Obi-to-Obi work: `/v1/obid/sphere…`, `/v1/obid/decisions…` and the inbox
//! (`GET /v1/inbox`, `POST /v1/inbox/{id}/answer`).

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
    let limit = limit(query.limit.as_deref(), 50, 1000)?;
    Ok(json(StatusCode::OK, shared.link.inbox_json(done, limit)))
}

/// `POST /v1/inbox/{id}/answer`.
pub async fn answer(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    Ok(json(StatusCode::OK, shared.link.answer(&id, &body).await?))
}
