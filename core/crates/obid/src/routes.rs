//! The jobs' endpoints and the event stream (docs/runner-api.md, "POST /v1/jobs" to
//! "POST /v1/jobs/{id}/dismiss", and "GET /v1/events").

use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;

use axum::body::{Body, Bytes};
use axum::extract::{Path, Query, State};
use axum::http::{StatusCode, header};
use axum::response::sse::{Event as SseEvent, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use futures_util::stream::{self, Stream, StreamExt};
use serde_json::{Map, Value, json};

use crate::api::{ApiError, Shared};
use crate::jobs::NewJob;

const NO_JOB: &str = "There's no such job.";

/// Resolves once obid is stopping: a stream that would otherwise stay open ends.
async fn stopping(mut receiver: tokio::sync::watch::Receiver<bool>) {
    while !*receiver.borrow() {
        if receiver.changed().await.is_err() {
            return;
        }
    }
}

fn json(status: StatusCode, value: Value) -> Response {
    (status, axum::Json(value)).into_response()
}

#[derive(serde::Deserialize)]
pub struct Limit {
    limit: Option<String>,
}

/// `GET /v1/jobs?limit=50`: the latest jobs, newest first.
pub async fn jobs(
    State(shared): State<Arc<Shared>>,
    Query(query): Query<Limit>,
) -> Result<Response, ApiError> {
    let limit = match query.limit.as_deref() {
        None => 50,
        Some(text) => text
            .parse::<usize>()
            .map_err(|_| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, "limit is a number."))?,
    };
    let list: Vec<Value> = shared
        .jobs
        .list(limit.min(1000))
        .iter()
        .map(|j| j.to_json())
        .collect();
    Ok(json(StatusCode::OK, Value::Array(list)))
}

/// `GET /v1/jobs/{id}`.
pub async fn job(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let job = shared
        .jobs
        .get(&id)
        .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, NO_JOB))?;
    Ok(json(StatusCode::OK, job.to_json()))
}

/// `POST /v1/jobs/{id}/stop`: a job that already ended comes back as it is.
pub async fn stop(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let job = shared
        .jobs
        .stop(&id)
        .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, NO_JOB))?;
    Ok(json(StatusCode::OK, job.to_json()))
}

/// `POST /v1/stop-all`.
pub async fn stop_all(State(shared): State<Arc<Shared>>) -> Response {
    let stopped = shared.jobs.stop_all();
    json(
        StatusCode::OK,
        json!({"stopped": stopped.len(), "jobs": stopped.iter().map(|j| j.to_json()).collect::<Vec<_>>()}),
    )
}

/// `POST /v1/jobs/{id}/dismiss`.
pub async fn dismiss(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    match shared.jobs.dismiss(&id) {
        None => Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB)),
        Some(Err(refused)) => Err(ApiError::new(StatusCode::CONFLICT, refused.0)),
        Some(Ok(job)) => Ok(json(StatusCode::OK, job.to_json())),
    }
}

/// `GET /v1/jobs/{id}/wait`: the job once it has ended; a space every 15 seconds until then.
pub async fn wait(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    if shared.jobs.get(&id).is_none() {
        return Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB));
    }
    enum Step {
        Waiting,
        Done,
    }
    let jobs = shared.jobs.clone();
    let stop = shared.stopping.clone();
    let ended = Box::pin(async move {
        tokio::select! {
            job = jobs.wait(&id) => job,
            // obid is stopping: the job as it is now.
            () = stopping(stop) => jobs.get(&id),
        }
    });
    let body = stream::unfold((Step::Waiting, Some(ended)), |(step, ended)| async move {
        match (step, ended) {
            (Step::Done, _) | (_, None) => None,
            (Step::Waiting, Some(mut ended)) => {
                tokio::select! {
                    job = &mut ended => {
                        let text = job.map(|j| j.to_json().to_string()).unwrap_or_else(|| "null".into());
                        Some((Ok::<Bytes, Infallible>(Bytes::from(text)), (Step::Done, None)))
                    }
                    () = tokio::time::sleep(Duration::from_secs(15)) => {
                        Some((Ok(Bytes::from_static(b" ")), (Step::Waiting, Some(ended))))
                    }
                }
            }
        }
    });
    // A space first, at once: the connection is open and the client knows to wait.
    let body =
        stream::once(async { Ok::<Bytes, Infallible>(Bytes::from_static(b" ")) }).chain(body);
    Ok((
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/json"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        Body::from_stream(body),
    )
        .into_response())
}

/// `GET /v1/events`: every change as it happens, and a `: ping` comment every 15 seconds.
pub async fn events(
    State(shared): State<Arc<Shared>>,
) -> Sse<impl Stream<Item = Result<SseEvent, Infallible>>> {
    let receiver = shared.events.subscribe();
    let stream =
        tokio_stream::wrappers::BroadcastStream::new(receiver).filter_map(|event| async move {
            let event = event.ok()?;
            Some(Ok(SseEvent::default()
                .event(event.name)
                .data(event.data.to_string())))
        });
    let stream = stream.take_until(stopping(shared.stopping.clone()));
    Sse::new(stream).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("ping"),
    )
}

/// `POST /v1/jobs`: a job described whole (`{"job": {"repo", "kind", "task", …}}`).
pub async fn dispatch(
    State(shared): State<Arc<Shared>>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let value: Value = serde_json::from_slice(&body)
        .map_err(|e| ApiError::new(StatusCode::BAD_REQUEST, format!("The body isn't JSON: {e}")))?;
    let Some(job) = value.get("job").and_then(Value::as_object) else {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "The body is {\"job\": {…}}.",
        ));
    };
    let whole = ["repo", "kind", "task"]
        .iter()
        .all(|k| job.contains_key(*k));
    if !whole {
        if job.contains_key("id") {
            return Err(ApiError::new(
                StatusCode::GONE,
                "Oby starts planned work by itself now: POST /v1/plans starts it and answers the jobs. POST /v1/jobs takes a whole job (repo, kind, task).",
            ));
        }
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "A job needs repo, kind and task.",
        ));
    }
    let new = new_job(job).map_err(|why| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, why))?;
    let job = shared
        .jobs
        .create(new)
        .map_err(|refused| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, refused.0))?;
    Ok(json(StatusCode::CREATED, job.to_json()))
}

/// The body's fields, by type; what they mean is checked when the job is made.
fn new_job(job: &Map<String, Value>) -> Result<NewJob, String> {
    let text = |key: &str| -> Result<Option<String>, String> {
        match job.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) => Ok(Some(s.clone())),
            Some(_) => Err(format!("{key} is a string.")),
        }
    };
    let number = |key: &str| -> Result<Option<u64>, String> {
        match job.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(value) => value
                .as_u64()
                .filter(|n| *n >= 1)
                .map(Some)
                .ok_or_else(|| format!("{key} is a positive whole number.")),
        }
    };
    let files = match job.get("files") {
        None | Some(Value::Null) => None,
        Some(Value::Array(items)) => Some(
            items
                .iter()
                .map(|f| f.as_str().map(str::to_owned).ok_or("files are paths."))
                .collect::<Result<Vec<_>, _>>()?,
        ),
        Some(_) => return Err("files is a list of paths.".into()),
    };
    match job.get("startWhen") {
        None | Some(Value::Null) => {}
        Some(Value::Array(items)) if items.is_empty() => {}
        Some(_) => return Err(
            "obid doesn't wait for a start condition yet: leave startWhen out to start at once."
                .into(),
        ),
    }
    if job.get("reads").is_some_and(|r| !r.is_null()) {
        return Err(
            "obid doesn't run research jobs with other repositories yet: leave reads out.".into(),
        );
    }
    let rounds = number("rounds")?;
    Ok(NewJob {
        repo: text("repo")?.unwrap_or_default(),
        kind: text("kind")?.unwrap_or_default(),
        task: text("task")?.unwrap_or_default(),
        title: text("title")?,
        request: text("request")?,
        pr: number("pr")?,
        issue: number("issue")?,
        account: text("account")?,
        agent: text("agent")?,
        branch: text("branch")?,
        base: text("base")?,
        rounds: rounds.map(|r| u32::try_from(r).unwrap_or(u32::MAX)),
        check: text("check")?,
        model: text("model")?,
        files,
        mode: text("mode")?,
    })
}

/// `POST /v1/clear`: Clear done, on any app. obid records now, on its own clock (never earlier than
/// the last clear), answers it, and every app following events hears it.
pub async fn clear(State(shared): State<Arc<Shared>>) -> Result<Response, ApiError> {
    let time = shared
        .cleared
        .clear(obi_protocol::time::now())
        .map_err(|e| {
            tracing::error!("can't keep the clear: {e}");
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "The clear couldn't be kept.",
            )
        })?;
    let body = json!({"clearedAt": obi_protocol::time::format(time)});
    shared.events.send("clear", body.clone());
    Ok(json(StatusCode::OK, body))
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct NewDevice {
    name: String,
    public_key: String,
}

/// `POST /v1/devices`: a device's publishing key, `{"id"}` (crate::devices).
pub async fn register_device(
    State(shared): State<Arc<Shared>>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let value: Value = serde_json::from_slice(&body)
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "That isn't JSON."))?;
    let device: NewDevice = serde_json::from_value(value).map_err(|_| {
        ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "A device is {\"name\", \"publicKey\"}.",
        )
    })?;
    use crate::devices::Refused;
    match shared.devices.register(
        &device.name,
        &device.public_key,
        std::time::SystemTime::now(),
    ) {
        Ok(id) => Ok(json(StatusCode::OK, json!({"id": id}))),
        Err(Refused::Malformed(why)) => Err(ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, why)),
        Err(Refused::PairingClosed(why)) => Err(ApiError::new(StatusCode::FORBIDDEN, why)),
        Err(Refused::Unkept(why)) => {
            tracing::error!("can't keep a device: {why}");
            Err(ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "The device couldn't be kept.",
            ))
        }
    }
}

/// `GET /v1/checks/next?mac=…&kinds=…`: the oldest queued Mac check for a Mac that runs them, or
/// `{"check": null}` when none waits. obid queues none: it publishes nothing yet (so no merge
/// check), and its agents don't ask for Apple checks; a Mac following obid hears so instead of a
/// 404.
pub async fn next_check() -> Response {
    json(StatusCode::OK, json!({"check": null}))
}
