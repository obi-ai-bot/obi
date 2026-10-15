//! A job: one piece of work, where it runs and how it went (docs/runner-api.md, "Job"), as obid
//! keeps it and as the apps read it. The JSON carries every key the Swift runner's does
//! (Runner/API.swift, `JobJSON`), null where nothing is known, plus obid's own `obi` and `worktree`.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// `queued`, `running`, `done`, `failed`, `stopped` or `interrupted`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    Queued,
    Running,
    Done,
    Failed,
    Stopped,
    Interrupted,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Queued => "queued",
            Status::Running => "running",
            Status::Done => "done",
            Status::Failed => "failed",
            Status::Stopped => "stopped",
            Status::Interrupted => "interrupted",
        }
    }

    /// Queued or running.
    pub fn is_active(self) -> bool {
        matches!(self, Status::Queued | Status::Running)
    }
}

/// The kinds of work.
pub const KINDS: [&str; 6] = ["review", "fix", "build", "test", "investigate", "research"];

/// The permission modes (docs/runner-api.md, "Permission modes").
pub const MODES: [&str; 4] = ["ask", "acceptEdits", "plan", "bypass"];

/// The pipeline stage a job is in, as it last was (Engine/Pipeline.swift, `JobStage.ID`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Prepare,
    Work,
    Check,
    Publish,
}

/// Why a queued job isn't running yet (`waiting`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Waiting {
    pub kind: String,
    pub text: String,
}

/// On a review job another Obi asked for: the exchange it answers (runner-api.md, "obid only:
/// Obi-to-Obi review jobs").
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObiRef {
    pub correlation_id: String,
    pub from: String,
    pub from_owner: String,
    pub request_id: String,
}

/// A job as obid keeps it (`home/jobs/<id>.json`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    /// The user's own words.
    pub request: String,
    pub agent: String,
    pub account: String,
    pub repo: String,
    pub branch: String,
    pub base: Option<String>,
    pub pr: Option<u64>,
    pub kind: String,
    pub task: String,
    pub title: Option<String>,
    pub status: Status,
    pub step: String,
    pub summary: String,
    pub session: Option<String>,
    /// Seconds since the epoch.
    pub created: i64,
    pub started: Option<i64>,
    pub finished: Option<i64>,
    pub commits: Option<u64>,
    pub publish_error: Option<String>,
    pub summaries: Option<Vec<String>>,
    pub issue: Option<u64>,
    pub rounds: Option<u32>,
    pub round: Option<u32>,
    pub check: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub notes: Option<Vec<String>>,
    pub files: Option<Vec<String>>,
    pub limit: Option<String>,
    pub start_commit: Option<String>,
    pub mode: Option<String>,
    pub waiting: Option<Waiting>,
    pub phase: Option<Phase>,
    pub dismissed: Option<i64>,
    /// The job's worktree, an absolute path, once it exists.
    pub worktree: Option<String>,
    pub obi: Option<ObiRef>,
    /// What an Obi-to-Obi review job made: the result body for its exchange
    /// (runner-api.md, "obid only: Obi-to-Obi review jobs", step 7). Never in the API's job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_result: Option<Value>,
    /// On an Obi-to-Obi review: the request as quoted to the agent, `{from, from_owner, type,
    /// body}`, the body exactly as received. Data, never in a prompt. Never in the API's job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub obi_request: Option<Value>,
    /// The owner's words (`POST /v1/jobs/{id}/messages`) the agent hasn't heard yet: its next
    /// turn's prompt. Never in the API's job (`notes` has them all).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub heard: Vec<String>,
    /// This round is one the owner asked for with their words: it may end `done` with nothing
    /// committed. Never in the API's job.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub asked: bool,
}

impl Job {
    /// A new job, queued now.
    pub fn new(
        id: String,
        repo: String,
        kind: String,
        task: String,
        agent: String,
        account: String,
    ) -> Job {
        Job {
            id,
            request: task.clone(),
            agent,
            account,
            repo,
            branch: String::new(),
            base: None,
            pr: None,
            kind,
            task,
            title: None,
            status: Status::Queued,
            step: String::new(),
            summary: String::new(),
            session: None,
            created: obi_protocol::time::now(),
            started: None,
            finished: None,
            commits: None,
            publish_error: None,
            summaries: None,
            issue: None,
            rounds: None,
            round: None,
            check: None,
            model: None,
            effort: None,
            notes: None,
            files: None,
            limit: None,
            start_commit: None,
            mode: None,
            waiting: None,
            phase: None,
            dismissed: None,
            worktree: None,
            obi: None,
            review_result: None,
            obi_request: None,
            heard: Vec::new(),
            asked: false,
        }
    }

    pub fn max_rounds(&self) -> u32 {
        self.rounds.unwrap_or(1).max(1)
    }

    pub fn current_round(&self) -> u32 {
        self.round.unwrap_or(1).max(1)
    }

    /// The last part of `owner/name`.
    pub fn repo_name(&self) -> &str {
        self.repo.rsplit('/').next().unwrap_or(&self.repo)
    }

    /// What the apps call it (Engine/Jobs.swift, `shortTitle`): its own title, else
    /// `<Kind> <repo name> #<number>`, else the task's first line, at most 60 characters.
    pub fn short_title(&self) -> String {
        if let Some(title) = self
            .title
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty())
        {
            return title.to_owned();
        }
        if let Some(number) = self.pr.or(self.issue) {
            let mut kind = self.kind.clone();
            if let Some(first) = kind.get_mut(0..1) {
                first.make_ascii_uppercase();
            }
            return format!("{kind} {} #{number}", self.repo_name());
        }
        let source = if self.task.is_empty() {
            &self.request
        } else {
            &self.task
        };
        let line = source.split('\n').next().unwrap_or("");
        if line.chars().count() > 60 {
            format!("{}…", line.chars().take(59).collect::<String>())
        } else {
            line.to_owned()
        }
    }

    /// Done with commits it couldn't publish, failed or interrupted, and not dismissed.
    pub fn needs_you(&self) -> bool {
        self.dismissed.is_none()
            && (self.status == Status::Failed
                || self.status == Status::Interrupted
                || (self.status == Status::Done
                    && self.publish_error.is_some()
                    && self.commits.unwrap_or(0) > 0))
    }

    /// The job as the runner API shows it.
    pub fn to_json(&self) -> Value {
        let date = |t: Option<i64>| t.map(obi_protocol::time::format);
        // `title` is the derived one, always a string, as the Swift runner sends it.
        json!({
            "id": self.id,
            "request": self.request,
            "agent": self.agent,
            "account": self.account,
            "repo": self.repo,
            "branch": self.branch,
            "base": self.base,
            "pr": self.pr,
            "kind": self.kind,
            "task": self.task,
            "status": self.status.as_str(),
            "step": self.step,
            "summary": self.summary,
            "session": self.session,
            "created": obi_protocol::time::format(self.created),
            "started": date(self.started),
            "finished": date(self.finished),
            // Oby's review makes no commits of its own.
            "commits": if self.kind == "review" && self.status == Status::Done { Some(0) } else { self.commits },
            // obid publishes nothing yet: no pull request, nothing pushed.
            "published": null,
            "pushed": null,
            "publishError": self.publish_error,
            "summaries": self.summaries,
            "issue": self.issue,
            "fromPR": null,
            "rounds": self.max_rounds(),
            "round": self.current_round(),
            "check": self.check,
            "model": self.model,
            "effort": self.effort,
            "complexity": null,
            "notes": self.notes,
            "pullRequest": null,
            "pullRequestError": null,
            "dismissed": date(self.dismissed),
            "reviewing": null,
            "review": null,
            "reviewError": null,
            "reviewOf": null,
            "files": self.files,
            "lead": null,
            "claim": null,
            "outgoing": [],
            "question": null,
            "limit": self.limit,
            "startCommit": self.start_commit,
            "firstSwiftBuildSeconds": null,
            "macCheck": null,
            // obid never merges (runner-api.md, "obid only: what obid leaves out").
            "mergeError": null,
            "appleCheck": null,
            "appleRan": null,
            "tetrix": null,
            "moves": [],
            "xcodeCloud": null,
            "xcodeCloudError": null,
            "startWhen": null,
            "waiting": self.waiting.as_ref().filter(|_| self.status == Status::Queued),
            "mode": self.mode.as_deref().unwrap_or("bypass"),
            "permission": null,
            "connectionUses": [],
            "pipeline": self.pipeline(),
            "title": self.short_title(),
            "mergeNeedsYou": false,
            "reviewNeedsYou": false,
            "cloudNeedsYou": false,
            "report": false,
            "obi": self.obi,
            "worktree": self.worktree,
        })
    }

    /// The stages the apps draw (Engine/Pipeline.swift), for what obid does: prepare, work, the
    /// check, then publish, review and merge, which obid leaves to a person (it publishes nothing
    /// yet and never merges).
    pub fn pipeline(&self) -> Value {
        let active = self.status.is_active();
        let stopped = matches!(
            self.status,
            Status::Failed | Status::Stopped | Status::Interrupted
        );
        let phase =
            self.phase
                .unwrap_or(if self.status == Status::Queued || self.started.is_none() {
                    Phase::Prepare
                } else {
                    Phase::Work
                });
        let working = active && phase == Phase::Work;
        let mut stages: Vec<Value> = vec![
            json!({"id": "prepare", "title": "Prepare", "state": "upcoming", "detail": "Clone and worktree"}),
            json!({"id": "work", "title": "Work", "state": "upcoming",
                   "detail": format!("Round {} of {}{}", self.current_round(), self.current_round().max(self.max_rounds()),
                                     if working && !self.step.is_empty() { format!(" · {}", self.step) } else { String::new() })}),
        ];
        if let Some(check) = self.check.as_deref().filter(|c| !c.trim().is_empty()) {
            stages.push(
                json!({"id": "check", "title": "Check", "state": "upcoming", "detail": check}),
            );
        }
        stages.push(json!({"id": "publish", "title": "Publish", "state": "upcoming", "detail": "Secret scan, push and pull request"}));
        stages.push(json!({"id": "review", "title": "Review", "state": "upcoming", "detail": "Waiting for review"}));
        stages.push(json!({"id": "merged", "title": format!("Merged into {}", self.base.as_deref().unwrap_or("dev")), "state": "upcoming"}));
        let id_of = |p: Phase| match p {
            Phase::Prepare => "prepare",
            Phase::Work => "work",
            Phase::Check => "check",
            Phase::Publish => "publish",
        };
        let phase_id = id_of(phase);
        let phase_index = stages.iter().position(|s| s["id"] == phase_id).unwrap_or(1);
        for stage in stages.iter_mut().take(phase_index) {
            stage["state"] = json!("done");
        }
        let set = |stages: &mut Vec<Value>, id: &str, state: &str| {
            if let Some(stage) = stages.iter_mut().find(|s| s["id"] == id) {
                stage["state"] = json!(state);
            }
        };
        if active {
            set(&mut stages, phase_id, "current");
            if phase == Phase::Prepare && !self.step.is_empty() {
                stages[phase_index]["detail"] = json!(self.step);
            }
        } else if stopped {
            set(&mut stages, phase_id, "failed");
            let reason = if self.summary.is_empty() {
                let mut status = self.status.as_str().to_owned();
                if let Some(first) = status.get_mut(0..1) {
                    first.make_ascii_uppercase();
                }
                status
            } else {
                self.summary.clone()
            };
            stages[phase_index]["reason"] = json!(reason);
            for stage in stages.iter_mut().skip(phase_index + 1) {
                stage["state"] = json!("skipped");
            }
        } else {
            for id in ["prepare", "work", "check"] {
                set(&mut stages, id, "done");
            }
            if self.commits.unwrap_or(0) > 0
                && self.kind != "review"
                && self.kind != "research"
                && self.dismissed.is_none()
            {
                if let Some(publish) = stages.iter_mut().find(|s| s["id"] == "publish") {
                    publish["state"] = json!(if self.publish_error.is_some() {
                        "failed"
                    } else {
                        "current"
                    });
                    publish["detail"] = json!("Ready to publish");
                    if let Some(error) = &self.publish_error {
                        publish["reason"] = json!(error);
                    }
                }
            } else {
                for id in ["publish", "review", "merged"] {
                    set(&mut stages, id, "skipped");
                }
            }
        }
        if self.dismissed.is_some()
            && !active
            && let Some(publish) = stages.iter().position(|s| s["id"] == "publish")
        {
            stages[publish]["state"] = json!("skipped");
            stages[publish]["detail"] = json!("Dismissed");
            for stage in stages.iter_mut().skip(publish + 1) {
                stage["state"] = json!("skipped");
            }
        }
        let position = stages
            .iter()
            .position(|s| s["state"] == "current" || s["state"] == "failed")
            .or_else(|| {
                stages
                    .iter()
                    .rposition(|s| s["state"] == "done" || s["state"] == "skipped")
            })
            .unwrap_or(0);
        let total = stages.len();
        json!({"stages": stages, "number": position + 1, "total": total})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job() -> Job {
        let mut job = Job::new(
            "9f08fd10".into(),
            "deskree-inc/oby".into(),
            "review".into(),
            "Review pull request #33 in deskree-inc/oby…".into(),
            "claude".into(),
            "default".into(),
        );
        job.pr = Some(33);
        job.created = obi_protocol::time::parse("2026-10-09T21:42:53Z").unwrap();
        job
    }

    /// Ported from RunnerTests/RunnerTests.swift, `jobsHaveISODatesAndEveryKey`: every key the
    /// Swift runner sends, plus obid's `obi` and `worktree`.
    #[test]
    fn jobs_have_iso_dates_and_every_key() {
        let mut job = job();
        job.started = Some(job.created + 2);
        let value = job.to_json();
        let object = value.as_object().unwrap();
        assert_eq!(value["created"], "2026-10-09T21:42:53Z");
        assert_eq!(value["started"], "2026-10-09T21:42:55Z");
        for key in [
            "base",
            "session",
            "finished",
            "commits",
            "published",
            "pushed",
            "publishError",
            "summaries",
            "issue",
            "fromPR",
            "check",
            "model",
            "effort",
            "complexity",
            "notes",
            "pullRequest",
            "pullRequestError",
            "dismissed",
            "reviewing",
            "review",
            "reviewError",
            "reviewOf",
            "files",
            "lead",
            "claim",
            "question",
            "limit",
            "startCommit",
            "firstSwiftBuildSeconds",
            "macCheck",
            "mergeError",
            "appleCheck",
            "appleRan",
            "tetrix",
            "xcodeCloud",
            "xcodeCloudError",
            "startWhen",
            "waiting",
            "permission",
        ] {
            assert_eq!(object.get(key), Some(&Value::Null), "{key}");
        }
        // The Swift runner's 65 keys, and obid's two.
        assert_eq!(object.len(), 67);
        assert_eq!(value["report"], false);
        assert_eq!(value["cloudNeedsYou"], false);
        assert_eq!(value["mode"], "bypass");
        assert_eq!(value["outgoing"], json!([]));
        assert_eq!(value["moves"], json!([]));
        assert_eq!(value["connectionUses"], json!([]));
        assert!(value["pipeline"].is_object());
        assert_eq!(value["title"], "Review oby #33");
        assert_eq!(value["rounds"], 1);
        assert_eq!(value["round"], 1);
        assert_eq!(value["kind"], "review");
        assert_eq!(value["pr"], 33);
        assert_eq!(value["status"], "queued");
        assert_eq!(value["obi"], Value::Null);
        assert_eq!(value["worktree"], Value::Null);
    }

    #[test]
    fn titles() {
        let mut job = job();
        assert_eq!(job.short_title(), "Review oby #33");
        job.pr = None;
        job.task = format!("{}\nmore", "x".repeat(70));
        assert_eq!(job.short_title(), format!("{}…", "x".repeat(59)));
        job.title = Some("Review for ernesto: fixture-app".into());
        assert_eq!(job.short_title(), "Review for ernesto: fixture-app");
    }

    #[test]
    fn pipelines_follow_the_job() {
        let mut job = job();
        job.check = Some("node --test".into());
        let stages = |job: &Job| -> Vec<(String, String)> {
            job.pipeline()["stages"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| {
                    (
                        s["id"].as_str().unwrap().to_owned(),
                        s["state"].as_str().unwrap().to_owned(),
                    )
                })
                .collect()
        };
        assert_eq!(stages(&job)[0], ("prepare".into(), "current".into()));
        job.status = Status::Running;
        job.started = Some(job.created);
        job.phase = Some(Phase::Check);
        assert_eq!(stages(&job)[2], ("check".into(), "current".into()));
        job.status = Status::Done;
        let done = stages(&job);
        assert!(done[..3].iter().all(|(_, s)| s == "done"));
        assert!(done[3..].iter().all(|(_, s)| s == "skipped"));
        job.status = Status::Failed;
        job.summary = "the check failed".into();
        let failed = job.pipeline();
        assert_eq!(failed["stages"][2]["state"], "failed");
        assert_eq!(failed["stages"][2]["reason"], "the check failed");
        assert_eq!(failed["number"], 3);
    }
}
