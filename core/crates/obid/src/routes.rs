//! The jobs' endpoints and the event stream (docs/runner-api.md, "POST /v1/jobs" to
//! "POST /v1/jobs/{id}/dismiss", and "GET /v1/events").

use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;

use axum::body::{Body, Bytes};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode, header};
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
    Ok(json(StatusCode::OK, job.detail_json()))
}

#[derive(serde::Deserialize)]
pub struct After {
    after: Option<String>,
    limit: Option<String>,
}

/// `GET /v1/jobs/{id}/transcript?after=<n>&limit=<k>`: the entries that came or changed after
/// entry `n`, at most `k`, and the `n` to ask after next when there's more.
pub async fn transcript(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
    Query(query): Query<After>,
) -> Result<Response, ApiError> {
    let number = |text: Option<&str>, default: u64, what: &str| match text {
        None => Ok(default),
        Some(text) => text.parse::<u64>().map_err(|_| {
            ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("{what} is a number."),
            )
        }),
    };
    let after = number(query.after.as_deref(), 0, "after")?;
    let limit = number(
        query.limit.as_deref(),
        crate::transcript::PAGE as u64,
        "limit",
    )?;
    let (entries, next) = shared
        .jobs
        .transcript(&id, after, usize::try_from(limit).unwrap_or(usize::MAX))
        .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, NO_JOB))?;
    Ok(json(
        StatusCode::OK,
        json!({"entries": entries, "next": next}),
    ))
}

/// `GET /v1/jobs/{id}/transcript/{n}`: the entry `n` with its `detail` (crate::detail), masked.
pub async fn transcript_entry(
    State(shared): State<Arc<Shared>>,
    Path((id, n)): Path<(String, String)>,
) -> Result<Response, ApiError> {
    let n = n
        .parse::<u64>()
        .map_err(|_| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, "n is a number."))?;
    if shared.jobs.get(&id).is_none() {
        return Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB));
    }
    let (entry, detail) = shared
        .jobs
        .transcript_entry(&id, n)
        .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "The transcript has no such entry."))?;
    let mut value = json!(entry);
    if let Some(detail) = detail {
        value["detail"] = detail;
    }
    Ok(json(StatusCode::OK, value))
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

/// `POST /v1/jobs/{id}/archive`: `{"archived": true}` (or no body) archives a job that ended and
/// needs nothing; `false` unarchives it.
pub async fn archive(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let archived = if body.iter().all(u8::is_ascii_whitespace) {
        true
    } else {
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Archive {
            archived: bool,
        }
        serde_json::from_slice::<Archive>(&body)
            .map_err(|_| {
                ApiError::new(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "The body is {\"archived\": true} or {\"archived\": false}.",
                )
            })?
            .archived
    };
    match shared.jobs.archive(&id, archived, "by you") {
        None => Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB)),
        Some(Err(refused)) => Err(ApiError::new(StatusCode::CONFLICT, refused.0)),
        Some(Ok(job)) => Ok(json(StatusCode::OK, job.to_json())),
    }
}

/// `PATCH /v1/jobs/{id}`: `{"title": "…"}` renames the job, one line of 1 to 60 characters once
/// trimmed (as a new job's `title`); `{"runsOn": "<Obi>" | null}` moves a job that isn't running to
/// a teammate's Mac, or back to this one (Sangam's "Run it here", #808). Either, or both.
pub async fn rename(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let bad = || {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            "The body is {\"title\": \"…\"} and/or {\"runsOn\": \"<Obi>\" | null}.",
        )
    };
    let Ok(Value::Object(map)) = serde_json::from_slice::<Value>(&body) else {
        return Err(bad());
    };
    if map.is_empty() || map.keys().any(|k| k != "title" && k != "runsOn") {
        return Err(bad());
    }
    let title = match map.get("title") {
        None => None,
        Some(Value::String(t)) => Some(t.trim().to_owned()),
        Some(_) => return Err(bad()),
    };
    if let Some(title) = &title
        && (title.is_empty()
            || title.chars().count() > 60
            || title
                .chars()
                .any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}')))
    {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "title is one line of 1 to 60 characters.",
        ));
    }
    let place = match map.get("runsOn") {
        None => None,
        Some(Value::Null) => Some(None),
        Some(place) => {
            Some(Some(shared.link.runs_on(place).map_err(|m| {
                ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, m)
            })?))
        }
    };
    if let Some(place) = place {
        match shared.jobs.place(&id, place) {
            None => return Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB)),
            Some(Err(refused)) => return Err(ApiError::new(StatusCode::CONFLICT, refused.0)),
            Some(Ok(_)) => {}
        }
    }
    let job = match title {
        Some(title) => shared.jobs.rename(&id, title),
        None => shared.jobs.get(&id),
    };
    match job {
        None => Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB)),
        Some(job) => Ok(json(StatusCode::OK, job.to_json())),
    }
}

/// `DELETE /v1/jobs/{id}`: a job that ended goes for good, its worktree and local branch with it;
/// nothing pushed is touched.
pub async fn delete(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    match shared.jobs.delete(&id).await {
        None => Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB)),
        Some(Err(refused)) => Err(ApiError::new(StatusCode::CONFLICT, refused.0)),
        Some(Ok(_)) => {
            shared.link.settle_job(&id);
            Ok(StatusCode::NO_CONTENT.into_response())
        }
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

/// `GET /v1/events`: every change as it happens, and a `: ping` comment every 15 seconds. A paired
/// device following it has Oby open: Oby's messages aren't pushed meanwhile (crate::push).
pub async fn events(
    State(shared): State<Arc<Shared>>,
    device: Option<axum::Extension<crate::gateway::PairedDevice>>,
) -> Sse<impl Stream<Item = Result<SseEvent, Infallible>>> {
    let following = device.map(|_| shared.push.followed());
    let receiver = shared.events.subscribe();
    let transcripts = shared.events.subscribe_transcripts();
    let stream = stream::select(
        tokio_stream::wrappers::BroadcastStream::new(receiver),
        tokio_stream::wrappers::BroadcastStream::new(transcripts),
    )
    .filter_map(|event| async move {
        let event = event.ok()?;
        Some(Ok(SseEvent::default()
            .event(event.name)
            .data(event.data.to_string())))
    });
    let stream = stream
        .take_until(stopping(shared.stopping.clone()))
        // Kept as long as the stream is.
        .inspect(move |_| {
            let _ = &following;
        });
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
    let mut new =
        new_job(job).map_err(|why| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, why))?;
    // On a teammate's Mac (#797): their Obi, which must take run_request.
    match job.get("runsOn") {
        None | Some(Value::Null) => {}
        Some(place @ (Value::String(_) | Value::Object(_))) => {
            new.runs_on = Some(
                shared
                    .link
                    .runs_on(place)
                    .map_err(|m| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, m))?,
            );
        }
        Some(_) => {
            return Err(ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "runsOn is a teammate's Obi id.",
            ));
        }
    }
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
        attachments: None,
        mode: text("mode")?,
        conversation: None,
        turn: None,
        brief: None,
        follow_up_of: None,
        earlier: None,
        start_from: None,
        runs_on: None,
        routine: None,
        rule: None,
        untrusted: false,
        split: false,
        adding: None,
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
    // What it cleared may be settled now: its worktrees go (docs/runner-api.md, `cleanup`).
    shared.jobs.clean_soon();
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

/// `GET /v1/checks/next?mac=…&kinds=…`: Apple checks first, then the oldest queued merge check
/// of a kind this Mac takes, or `{"check": null}` when none waits. Merge checks are persisted on
/// jobs; publishing/review creates their queue in a later port.
#[derive(serde::Deserialize)]
pub struct CheckQuery {
    mac: Option<String>,
    kinds: Option<String>,
}

pub async fn next_check(
    State(shared): State<Arc<Shared>>,
    Query(query): Query<CheckQuery>,
) -> Result<Response, ApiError> {
    let kinds = query.kinds.as_deref().unwrap_or("merge");
    let kinds: Vec<&str> = kinds.split(',').collect();
    if kinds.is_empty() || kinds.iter().any(|kind| !matches!(*kind, "merge" | "apple")) {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "kinds lists merge, apple or both.",
        ));
    }
    if query
        .mac
        .as_ref()
        .is_some_and(|mac| mac.chars().count() > 100)
    {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "mac is a name of up to 100 characters.",
        ));
    }
    let mac = query.mac.as_deref().unwrap_or("a Mac");
    let check = shared
        .jobs
        .held_mac_check(mac)
        .or_else(|| {
            if kinds.contains(&"apple") {
                shared.jobs.next_apple_check(mac)
            } else {
                None
            }
        })
        .or_else(|| {
            kinds
                .contains(&"merge")
                .then(|| shared.jobs.next_merge_check(mac))
                .flatten()
        });
    Ok(json(StatusCode::OK, json!({"check": check})))
}

/// `GET /v1/checks/{id}/bundle`: the commits in the job's worktree for the Mac that took it.
pub async fn check_bundle(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let data = shared
        .jobs
        .apple_check_bundle(&id)
        .map_err(check_api_error)?;
    Ok((
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/octet-stream")],
        data,
    )
        .into_response())
}

/// `POST /v1/checks/{id}/result`: a Mac's bounded report.
pub async fn check_result(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let report: Value = serde_json::from_slice(&body)
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "That isn't JSON."))?;
    let Some((_, check, _)) = shared.jobs.find_check(&id) else {
        return Err(check_api_error(crate::jobs::CheckResultError::Missing));
    };
    let mac = check["mac"].as_str().unwrap_or("").to_owned();
    let check = shared
        .jobs
        .end_mac_check(&id, &mac, report)
        .map_err(check_api_error)?;
    Ok(json(StatusCode::OK, json!({"check": check})))
}

/// `POST` asks for the current committed head; `GET` reports the job's latest one.
pub async fn apple_check(
    State(shared): State<Arc<Shared>>,
    headers: HeaderMap,
    method: axum::http::Method,
) -> Result<Response, ApiError> {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .unwrap_or("")
        .trim();
    let job_id = shared
        .jobs
        .apple_job_for_token(token)
        .ok_or_else(|| ApiError::new(StatusCode::UNAUTHORIZED, crate::api::NO_TOKEN))?;
    let answer = if method == axum::http::Method::POST {
        shared.jobs.ask_apple_check(&job_id).map_err(|why| {
            let status =
                if why.contains("running") || why.contains("commit") || why.contains("20 Apple") {
                    StatusCode::CONFLICT
                } else {
                    StatusCode::NOT_FOUND
                };
            ApiError::new(status, why)
        })?;
        shared
            .jobs
            .apple_check_answer(&job_id)
            .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "No Apple check."))?
    } else {
        shared
            .jobs
            .apple_check_answer(&job_id)
            .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "No Apple check."))?
    };
    Ok(json(StatusCode::OK, answer))
}

fn check_api_error(error: crate::jobs::CheckResultError) -> ApiError {
    match error {
        crate::jobs::CheckResultError::Missing => {
            ApiError::new(StatusCode::NOT_FOUND, "There's no such check.")
        }
        crate::jobs::CheckResultError::Conflict => ApiError::new(
            StatusCode::CONFLICT,
            "The check hasn't been taken by a Mac or already has its result.",
        ),
        crate::jobs::CheckResultError::BadRequest => {
            ApiError::new(StatusCode::BAD_REQUEST, "The check result is malformed.")
        }
    }
}

/// `GET /v1/settings/jobs`: how many jobs run at once.
pub async fn job_settings(State(shared): State<Arc<Shared>>) -> Response {
    json(
        StatusCode::OK,
        json!({"maxRunning": shared.jobs.max_running()}),
    )
}

/// `PUT /v1/settings/jobs`: `{"maxRunning": 1…20}`, kept across restarts. Raising it starts
/// waiting jobs at once; lowering it stops nothing.
pub async fn set_job_settings(
    State(shared): State<Arc<Shared>>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let value: Value = serde_json::from_slice(&body)
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "That isn't JSON."))?;
    let max = value
        .get("maxRunning")
        .and_then(Value::as_u64)
        .and_then(|n| u32::try_from(n).ok())
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "The body is {\"maxRunning\": 1 to 20}.",
            )
        })?;
    use crate::jobs::SettingsError;
    match shared.jobs.set_max_running(max) {
        Ok(max) => Ok(json(StatusCode::OK, json!({"maxRunning": max}))),
        Err(SettingsError::Refused(why)) => {
            Err(ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, why))
        }
        Err(e) => {
            tracing::error!("{e}");
            Err(ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "The setting couldn't be kept.",
            ))
        }
    }
}

/// `POST /v1/jobs/{id}/messages`: `{"text": "…"}`, the owner's words to the job's agent: `200`
/// with the job that heard them, or `201` with the follow-up a job that ended got.
pub async fn message(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    if shared.jobs.get(&id).is_none() {
        return Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB));
    }
    let bad = || ApiError::new(StatusCode::BAD_REQUEST, "The body is {\"text\": \"…\"}.");
    let value = serde_json::from_slice::<Value>(&body).map_err(|_| bad())?;
    let text = value.get("text").and_then(Value::as_str).ok_or_else(bad)?;
    let attachments = match value.get("attachments") {
        None | Some(Value::Null) => vec![],
        Some(Value::Array(items)) => {
            let paths = items
                .iter()
                .map(|p| p.as_str().map(str::to_owned))
                .collect::<Option<Vec<_>>>()
                .ok_or_else(|| ApiError::new(StatusCode::BAD_REQUEST, "attachments are paths."))?;
            crate::brain::validate_attachments(&shared.config.home, &paths)?
        }
        Some(_) => {
            return Err(ApiError::new(
                StatusCode::BAD_REQUEST,
                "attachments are paths.",
            ));
        }
    };
    let say = value.get("conversation").and_then(Value::as_bool) == Some(true);
    let first = shared.jobs.get(&id);
    let answer = shared
        .jobs
        .message_attaching(&id, text, crate::jobs::Source::Owner, &attachments);
    let job = match answer {
        None => return Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB)),
        Some(Err(refused)) => {
            return Err(ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, refused.0));
        }
        Some(Ok(job)) => job,
    };
    // Said on the task's page (Sangam's TaskView): the words and Oby's answer go on the end of the
    // job's conversation, which the app opens, as if said there.
    if let Some((first, conversation)) = first
        .filter(|_| say)
        .and_then(|j| j.conversation.clone().map(|c| (j, c)))
    {
        let said = shared
            .conversations
            .append(&conversation, "user", text.trim().to_owned(), vec![])
            .and_then(|_| {
                let line = crate::brain::actions::told_line(&shared, &first, &job);
                shared
                    .conversations
                    .append(&conversation, "oby", line, vec![job.id.clone()])
            });
        if let Err(e) = said {
            tracing::info!("words for job {id}; conversation {conversation} wasn't told: {e:?}");
        }
    }
    // A follow-up it started; one already working heard the words, and is a 200.
    let status = if job.id != id && job.heard.is_empty() {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok(json(status, job.to_json()))
}

/// `GET /v1/jobs/{id}/publish`: what publishing the job by hand would do, in obid's one sentence,
/// and its base: for a job whose own publish failed. `409` when there's nothing to publish.
pub async fn publish_action(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    match shared.jobs.offer_publish(&id) {
        None => Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB)),
        Some(Err(why)) => Err(ApiError::new(StatusCode::CONFLICT, why)),
        Some(Ok((action, base))) => Ok(json(
            StatusCode::OK,
            json!({"action": action, "base": base}),
        )),
    }
}

/// `POST /v1/jobs/{id}/publish`: publishes by hand, once a registered device approved obid's own
/// sentence for it (crate::approval): `{"url"}` (null for a remote with no pull requests), `403` for an approval that doesn't hold, `409`
/// when there's nothing to publish or publishing failed (the line says why, never a secret).
/// Never a merge.
pub async fn publish(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let value: Value = serde_json::from_slice(&body)
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "That isn't JSON."))?;
    let approval: crate::approval::Approval = serde_json::from_value(value).map_err(|_| {
        ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "An approval is {\"device\", \"action\", \"signedAt\", \"signature\"}.",
        )
    })?;
    let action = match shared.jobs.publish_action(&id) {
        None => return Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB)),
        Some(Err(why)) => return Err(ApiError::new(StatusCode::CONFLICT, why)),
        Some(Ok((action, _))) => action,
    };
    let key = shared.devices.public_key(&approval.device);
    shared
        .jobs
        .approvals()
        .check(
            &approval,
            &id,
            &action,
            key.as_deref(),
            obi_protocol::time::now(),
        )
        .map_err(|why| ApiError::new(StatusCode::FORBIDDEN, why))?;
    // Checked fresh by `check` above.
    let signed_at = obi_protocol::time::parse(&approval.signed_at).unwrap_or(i64::MAX);
    match shared.jobs.publish_by_hand(&id, &action, signed_at).await {
        Ok(url) => Ok(json(StatusCode::OK, json!({"url": url}))),
        Err(why) => Err(ApiError::new(StatusCode::CONFLICT, why)),
    }
}

/// `POST /v1/jobs/{id}/permission`: `{"id", "decision": "allow" | "always" | "deny", "message"}`,
/// the owner's answer to the job's waiting permission, or `{"id", "answer"}` to the agent's
/// question (#858). Returns the job, with the next waiting one or null.
pub async fn permission(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    if shared.jobs.get(&id).is_none() {
        return Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB));
    }
    let value: Value = serde_json::from_slice(&body)
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "That isn't JSON."))?;
    let shape = "The body is {\"id\", \"decision\": \"allow\" | \"always\" | \"deny\", \"message\"}, or {\"id\", \"answer\"} for a question.";
    let permission = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, shape))?;
    use crate::jobs::PermissionRefused;
    let answered = match value.get("answer") {
        None | Some(Value::Null) => None,
        Some(Value::String(answer)) if value.get("decision").is_none() => {
            Some(shared.jobs.answer_question(&id, permission, answer))
        }
        Some(_) => return Err(ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, shape)),
    };
    if let Some(answered) = answered {
        return match answered {
            Ok(job) => Ok(json(StatusCode::OK, job.to_json())),
            Err(PermissionRefused::NoJob) => Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB)),
            Err(PermissionRefused::NotWaiting(why)) => {
                Err(ApiError::new(StatusCode::CONFLICT, why))
            }
            Err(PermissionRefused::Refused(why)) => {
                Err(ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, why))
            }
        };
    }
    let decision = value
        .get("decision")
        .and_then(Value::as_str)
        .and_then(crate::permissions::Decision::parse)
        .ok_or_else(|| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, shape))?;
    let message = match value.get("message") {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) => Some(text.as_str()),
        Some(_) => return Err(ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, shape)),
    };
    match shared
        .jobs
        .answer_permission(&id, permission, decision, message)
    {
        Ok(job) => Ok(json(StatusCode::OK, job.to_json())),
        Err(PermissionRefused::NoJob) => Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB)),
        Err(PermissionRefused::NotWaiting(why)) => Err(ApiError::new(StatusCode::CONFLICT, why)),
        Err(PermissionRefused::Refused(why)) => {
            Err(ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, why))
        }
    }
}

/// The mode a body names: `{"mode": "ask" | "acceptEdits" | "plan" | "bypass" | "sandbox"}`.
fn mode_of(body: &Bytes) -> Result<crate::permissions::Mode, ApiError> {
    let value: Value = serde_json::from_slice(body)
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "That isn't JSON."))?;
    value
        .get("mode")
        .and_then(Value::as_str)
        .and_then(crate::permissions::Mode::parse)
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "mode is ask, acceptEdits, plan, bypass or sandbox.",
            )
        })
}

/// `POST /v1/jobs/{id}/mode`: how much the job asks, from now on.
pub async fn mode(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    if shared.jobs.get(&id).is_none() {
        return Err(ApiError::new(StatusCode::NOT_FOUND, NO_JOB));
    }
    let mode = mode_of(&body)?;
    let job = shared
        .jobs
        .set_mode(&id, mode)
        .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, NO_JOB))?;
    Ok(json(StatusCode::OK, job.to_json()))
}

/// `GET /v1/settings/permissions`: the mode new jobs get.
pub async fn permission_settings(State(shared): State<Arc<Shared>>) -> Response {
    json(
        StatusCode::OK,
        json!({"mode": shared.jobs.default_mode().as_str()}),
    )
}

/// `PUT /v1/settings/permissions`: `{"mode"}`, the mode new jobs get, kept across restarts. Jobs
/// already made keep theirs.
pub async fn set_permission_settings(
    State(shared): State<Arc<Shared>>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let mode = mode_of(&body)?;
    shared.jobs.set_default_mode(mode).map_err(|e| {
        tracing::error!("can't keep the permission mode: {e}");
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "The setting couldn't be kept.",
        )
    })?;
    Ok(json(StatusCode::OK, json!({"mode": mode.as_str()})))
}

/// `GET /v1/permissions/rules`: the saved rules, oldest first.
pub async fn permission_rules(State(shared): State<Arc<Shared>>) -> Response {
    let rules: Vec<Value> = shared.jobs.rules().iter().map(|r| r.to_json()).collect();
    json(StatusCode::OK, Value::Array(rules))
}

/// `DELETE /v1/permissions/rules/{id}`: forgets one, and answers with the rules left.
pub async fn forget_permission_rule(
    State(shared): State<Arc<Shared>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    match shared.jobs.forget_rule(&id) {
        None => Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "There's no such rule.",
        )),
        Some(Err(e)) => {
            tracing::error!("can't keep the permission rules: {e}");
            Err(ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "The rules couldn't be kept.",
            ))
        }
        Some(Ok(left)) => Ok(json(
            StatusCode::OK,
            Value::Array(left.iter().map(|r| r.to_json()).collect()),
        )),
    }
}
