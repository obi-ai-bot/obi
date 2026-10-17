//! The failure records (docs/runner-api.md, "Failure record", `GET /v1/failures`, `GET
//! /v1/failures/{id}`, `POST /v1/failures/{id}/fix`; Engine/Failures.swift). Whenever a job fails,
//! stops at a limit or its publish fails, obid keeps a record of it with the evidence, in
//! `home/failures/<id>.json` (0600), for good: after the job list forgets the job.
//!
//! What obid doesn't do yet, and so never sends: the post-mortem (a model turn reading Oby's own
//! source), the `oby-failure` issues filed from it, their inbox items and the fix job. Every
//! record's `postMortem` is null, so Fix it always answers that it isn't studied yet.

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::extract::{Path as UrlPath, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::{ApiError, Shared};
use crate::job::{Job, Status};

/// Only what happened this recently is recorded: a job that failed weeks ago isn't new.
pub const FRESH: i64 = 86_400;

/// The most records one list sends.
pub const MOST: usize = 1000;

const NOT_STUDIED: &str = "Oby hasn't studied this failure yet.";

/// What obid saw happen: the triggers of the Swift runner that obid's jobs can show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Trigger {
    /// The job failed.
    Failed,
    /// obid stopped it at one of its limits.
    Limit,
    /// Publishing it failed.
    PublishError,
}

impl Trigger {
    fn as_str(self) -> &'static str {
        match self {
            Trigger::Failed => "failed",
            Trigger::Limit => "limit",
            Trigger::PublishError => "publishError",
        }
    }
}

/// What obid kept to study it, with the secrets it knows taken out (so are the record's `title`
/// and `what`: a limit names the check's command).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Evidence {
    /// The job's report (its summary), its end.
    pub summary: String,
    /// Where it was: its stage, phase, step and round.
    pub step: String,
    /// The end of what its check printed, and why its publish failed, or none.
    pub check: Option<String>,
}

/// A failure record as obid keeps it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub id: String,
    pub trigger: Trigger,
    /// Seconds since the epoch: when the job ended.
    pub date: i64,
    pub job: String,
    pub repo: String,
    pub title: String,
    /// What obid saw, in its own words, like "Stopped at a limit: …".
    pub what: String,
    /// The rounds the job had used.
    pub rounds: u32,
    pub evidence: Evidence,
}

impl Record {
    /// The record with every key the API promises, null for what obid doesn't do yet.
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "trigger": self.trigger.as_str(),
            "date": obi_protocol::time::format(self.date),
            "job": self.job,
            "repo": self.repo,
            "title": self.title,
            "what": self.what,
            "rounds": self.rounds,
            "intervention": false,
            "evidence": {
                "summary": self.evidence.summary,
                "step": self.evidence.step,
                "check": self.evidence.check,
                "reviews": [],
                "log": [],
                "worktree": null,
                "source": null,
            },
            "postMortem": null,
            "tries": 0,
            "acted": false,
            "studyError": null,
            "issue": null,
            "issueError": null,
            "fix": null,
            "fixedBy": null,
            "fixedAt": null,
        })
    }
}

/// What `job`'s state says went wrong, and when, or none: the trigger, an id that's the same
/// every time the same thing is seen, and obid's words. A job that ended more than [`FRESH`]
/// seconds before `now` isn't news.
pub fn found(job: &Job, now: i64) -> Option<(String, Trigger, String)> {
    let finished = job.finished?;
    if now - finished >= FRESH {
        return None;
    }
    let (trigger, what) = match job.status {
        Status::Failed => match &job.limit {
            Some(limit) => (Trigger::Limit, format!("Stopped at a limit: {limit}")),
            None if job.summary.starts_with("Not published:") => (
                Trigger::PublishError,
                "It failed, not published.".to_owned(),
            ),
            None => (Trigger::Failed, "It failed.".to_owned()),
        },
        Status::Done if job.publish_error.is_some() => (
            Trigger::PublishError,
            "Its publish failed; Publish by hand is offered.".to_owned(),
        ),
        // A job the owner stopped isn't a failure, and obid leaves none interrupted.
        _ => return None,
    };
    Some((
        format!("{}-{}-{finished}", job.id, trigger.as_str()),
        trigger,
        what,
    ))
}

fn folder(home: &Path) -> PathBuf {
    home.join("failures")
}

/// A record's id names a file: only letters, digits and dashes, as obid makes them.
fn path(home: &Path, id: &str) -> Option<PathBuf> {
    let safe = !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    safe.then(|| folder(home).join(format!("{id}.json")))
}

/// A job changed: what went wrong is recorded, once (jobs.rs calls it for every change).
pub fn observe(home: &Path, job: &Job) {
    let Some((id, trigger, what)) = found(job, obi_protocol::time::now()) else {
        return;
    };
    let Some(path) = path(home, &id) else {
        return;
    };
    if path.exists() {
        return;
    }
    let record = Record {
        id: id.clone(),
        trigger,
        date: job.finished.unwrap_or(job.created),
        job: job.id.clone(),
        repo: job.repo.clone(),
        title: crate::secrets::known().redact(&job.short_title()),
        what: crate::secrets::known().redact(&what),
        rounds: job.current_round(),
        evidence: evidence(home, job),
    };
    let kept = serde_json::to_vec_pretty(&record)
        .map_err(std::io::Error::other)
        .and_then(|bytes| {
            crate::store::make_private_dir(&folder(home))?;
            crate::store::write_private(&path, &bytes)
        });
    match kept {
        Ok(()) => tracing::info!(
            "failure {id} recorded: {} on job {}",
            trigger.as_str(),
            job.id
        ),
        Err(e) => tracing::error!("can't keep failure {id}: {e}"),
    }
}

/// The job's evidence, with every secret obid knows taken out.
fn evidence(home: &Path, job: &Job) -> Evidence {
    let secrets = crate::secrets::known();
    let mut check = Vec::new();
    let log = home.join("logs").join(&job.id).join("check.log");
    if let Some(output) = tail(&log, 3000) {
        check.push(format!(
            "`{}` printed (its end):\n{output}",
            job.check.as_deref().unwrap_or("the check")
        ));
    }
    if let Some(error) = &job.publish_error {
        check.push(format!("Publish: {error}"));
    }
    Evidence {
        summary: secrets.redact(&tail_chars(&job.summary, 4000)),
        step: secrets.redact(&step(job)),
        check: (!check.is_empty()).then(|| secrets.redact(&check.join("\n\n"))),
    }
}

/// "Stage 3 of 5, Check: node --test · phase check · step Checking · round 2 of 2"
pub fn step(job: &Job) -> String {
    let pipeline = job.pipeline();
    let stages = pipeline["stages"].as_array().cloned().unwrap_or_default();
    let mut parts = Vec::new();
    if let Some((index, stage)) = stages
        .iter()
        .enumerate()
        .find(|(_, s)| s["state"] == "current" || s["state"] == "failed")
    {
        let mut part = format!(
            "Stage {} of {}, {}",
            index + 1,
            stages.len(),
            stage["title"].as_str().unwrap_or("")
        );
        if let Some(detail) = stage["detail"].as_str() {
            part.push_str(&format!(": {detail}"));
        }
        parts.push(part);
    }
    if let Some(phase) = job.phase.and_then(|p| serde_json::to_value(p).ok()) {
        parts.push(format!("phase {}", phase.as_str().unwrap_or("")));
    }
    if !job.step.is_empty() {
        parts.push(format!("step {}", job.step));
    }
    parts.push(format!(
        "round {} of {}",
        job.current_round(),
        job.max_rounds()
    ));
    parts.join(" · ")
}

/// The last `chars` characters of the file, or none when it can't be read or is empty.
fn tail(path: &Path, chars: usize) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    // A character is 4 bytes at most.
    let from = length.saturating_sub(chars as u64 * 4);
    file.seek(SeekFrom::Start(from)).ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let text = tail_chars(&text, chars);
    (!text.trim().is_empty()).then_some(text)
}

fn tail_chars(text: &str, limit: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    chars[chars.len().saturating_sub(limit)..].iter().collect()
}

/// The records kept, newest first, at most `limit`.
pub fn list(home: &Path, limit: usize) -> Vec<Record> {
    let mut records: Vec<Record> = crate::store::load_dir(&folder(home));
    records.sort_by(|a, b| b.date.cmp(&a.date).then_with(|| b.id.cmp(&a.id)));
    records.truncate(limit);
    records
}

/// One record, or none for one obid doesn't have.
pub fn get(home: &Path, id: &str) -> Option<Record> {
    let bytes = std::fs::read(path(home, id)?).ok()?;
    serde_json::from_slice(&bytes).ok()
}

#[derive(Deserialize)]
pub struct Limit {
    limit: Option<String>,
}

/// `GET /v1/failures?limit=50`: newest first, at most 1,000; a limit below 0 sends none.
pub async fn list_route(
    State(shared): State<Arc<Shared>>,
    Query(query): Query<Limit>,
) -> Result<Response, ApiError> {
    let limit = match query.limit.as_deref() {
        None => 50,
        Some(text) => text
            .parse::<i64>()
            .map_err(|_| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, "limit is a number."))?
            .clamp(0, MOST as i64) as usize,
    };
    let list: Vec<Value> = list(&shared.config.home, limit)
        .iter()
        .map(Record::to_json)
        .collect();
    Ok((StatusCode::OK, axum::Json(Value::Array(list))).into_response())
}

/// Swift's words for a record it doesn't know.
fn no_failure(id: &str) -> ApiError {
    ApiError::new(StatusCode::NOT_FOUND, format!("There's no failure {id}."))
}

/// `GET /v1/failures/{id}`.
pub async fn get_route(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    let record = get(&shared.config.home, &id).ok_or_else(|| no_failure(&id))?;
    Ok((StatusCode::OK, axum::Json(record.to_json())).into_response())
}

/// `POST /v1/failures/{id}/fix`: obid has no post-mortem yet, so there's nothing to fix from.
pub async fn fix_route(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    get(&shared.config.home, &id).ok_or_else(|| no_failure(&id))?;
    Err(ApiError::new(StatusCode::CONFLICT, NOT_STUDIED))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(status: Status) -> Job {
        let mut job: Job = serde_json::from_value(json!({
            "id": "ab12cd34", "request": "r", "agent": "claude", "account": "a", "repo": "o/r",
            "branch": "b", "base": null, "pr": null, "kind": "build", "task": "Do it",
            "title": null, "status": "queued", "step": "", "summary": "", "session": null,
            "created": 100, "started": null, "finished": null, "commits": null,
            "publishError": null, "summaries": null, "issue": null, "rounds": null,
            "round": null, "check": null, "model": null, "effort": null, "notes": null,
            "files": null, "limit": null, "startCommit": null, "mode": null, "waiting": null,
            "phase": null, "dismissed": null, "worktree": null, "obi": null
        }))
        .unwrap();
        job.status = status;
        job.finished = Some(1_000);
        job
    }

    #[test]
    fn each_trigger_is_found_once_and_only_while_it_is_news() {
        let failed = job(Status::Failed);
        assert_eq!(
            found(&failed, 1_001),
            Some((
                "ab12cd34-failed-1000".into(),
                Trigger::Failed,
                "It failed.".into()
            ))
        );
        assert_eq!(found(&failed, 1_000 + FRESH), None);

        let mut limit = job(Status::Failed);
        limit.limit = Some("the round ran past 45 minutes".into());
        assert_eq!(found(&limit, 1_001).unwrap().1, Trigger::Limit);

        let mut unpublished = job(Status::Failed);
        unpublished.summary = "Not published: a possible secret".into();
        assert_eq!(found(&unpublished, 1_001).unwrap().1, Trigger::PublishError);

        let mut by_hand = job(Status::Done);
        by_hand.publish_error = Some("gh isn't there".into());
        assert_eq!(
            found(&by_hand, 1_001).unwrap().0,
            "ab12cd34-publishError-1000"
        );

        for quiet in [
            Status::Done,
            Status::Stopped,
            Status::Queued,
            Status::Running,
        ] {
            assert_eq!(found(&job(quiet), 1_001), None, "{quiet:?}");
        }
    }

    #[test]
    fn only_ids_obid_makes_name_a_file() {
        let home = Path::new("/home");
        assert!(path(home, "ab12cd34-failed-1000").is_some());
        for bad in ["", "..", "../jobs/ab12cd34", "a/b", "a.json", "a b"] {
            assert_eq!(path(home, bad), None, "{bad}");
        }
    }
}
