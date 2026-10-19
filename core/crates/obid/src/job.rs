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

/// The kinds that only read: they run in Plan mode, whatever the default mode. An investigation
/// isn't one: it may run a test or a build to reproduce a bug (the owner's decision of 2026-10-18).
pub const READ_ONLY: [&str; 1] = ["review"];

/// The permission modes (docs/runner-api.md, "Permission modes").
pub const MODES: [&str; 5] = ["ask", "acceptEdits", "plan", "bypass", "sandbox"];

fn is_zero(n: &u32) -> bool {
    *n == 0
}

/// The pipeline stage a job is in, as it last was (Engine/Pipeline.swift, `JobStage.ID`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Prepare,
    Work,
    Check,
    Publish,
}

/// How long what obid said about publishing a job by hand counts: the two minutes an approval is
/// fresh.
const OFFERS_KEPT: i64 = 120;

/// What obid said a publish by hand would do: when, and of which run (its `finished`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Offer {
    pub run: Option<i64>,
    pub at: i64,
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

/// One thing Oby found before the job started (#540): a file a lookup showed, the lines, and
/// what Oby saw there or ruled out.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Finding {
    pub path: String,
    #[serde(default)]
    pub lines: Option<String>,
    pub note: String,
}

/// What the brain's research handed the job (#540): where to look and what done means. Written
/// from what repositories, GitHub and the web said, so its agent reads it as quoted data.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Brief {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub findings: Vec<Finding>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub done: Option<String>,
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
    /// The pull request's URL once published.
    #[serde(default)]
    pub published: Option<String>,
    /// How many of `commits` the pull request has, or none before it's published.
    #[serde(default)]
    pub pushed: Option<u64>,
    pub publish_error: Option<String>,
    /// What publishing is doing now, while it publishes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub publish_step: Option<crate::publish::Step>,
    /// Everything obid sent out for the job, oldest first: ids only.
    #[serde(default)]
    pub outgoing: Vec<crate::publish::Outgoing>,
    /// The published pull request as obid last read it from GitHub.
    #[serde(default)]
    pub pull_request: Option<crate::github::PullRequest>,
    /// Why the last read of it failed, or none.
    #[serde(default)]
    pub pull_request_error: Option<String>,
    /// Why no review ran, or none.
    #[serde(default)]
    pub review_error: Option<String>,
    pub summaries: Option<Vec<String>>,
    pub issue: Option<u64>,
    pub rounds: Option<u32>,
    pub round: Option<u32>,
    pub check: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub notes: Option<Vec<String>>,
    pub files: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachments: Option<Vec<String>>,
    pub limit: Option<String>,
    pub start_commit: Option<String>,
    pub mode: Option<String>,
    pub waiting: Option<Waiting>,
    pub phase: Option<Phase>,
    pub dismissed: Option<i64>,
    /// The job's worktree, an absolute path, once it exists.
    pub worktree: Option<String>,
    pub obi: Option<ObiRef>,
    /// The conversation whose plan started it, or none (#493). It keeps the id when that
    /// conversation is deleted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
    /// What an Obi-to-Obi review job made: the result body for its exchange
    /// (runner-api.md, "obid only: Obi-to-Obi review jobs", step 7). Never in the API's job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_result: Option<Value>,
    /// On an Obi-to-Obi review: the request as quoted to the agent, `{from, from_owner, type,
    /// body}`, the body exactly as received. Data, never in a prompt. Never in the API's job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub obi_request: Option<Value>,
    /// The permission its agent waits on now, for the owner's OK (docs/runner-api.md, "Permission
    /// modes").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission: Option<crate::permissions::Permission>,
    /// The latest Mac checks, kept on the job and sent on its JSON/event (`runner-api.md`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mac_check: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub apple_check: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub apple_ran: Option<Value>,
    /// Per-job bearer for `POST` and `GET /v1/agent/apple-check`; never sent to the API.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub apple_token: Option<String>,
    /// What obid answered for the owner by its own rules (permissions.rs `Answered`): the latest
    /// few, with `answered_count` for all of them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub answered: Vec<crate::permissions::Answered>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub answered_count: u32,
    /// What obid saw of the agent and Tetrix, through obid's own Tetrix server (crate::tetrix).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tetrix: Option<crate::tetrix::Use>,
    /// Calls an agent made through the user's connected apps; names only, never secret values.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub connection_uses: Vec<crate::connections::ConnectionUse>,
    /// The connected apps the job started with (names, URLs and secret names, never a value):
    /// what its broker offers for as long as the job lives, across rounds, messages and restarts.
    /// Never in the API's job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub connections: Option<Vec<crate::connections::Connection>>,
    /// The owner's words (`POST /v1/jobs/{id}/messages`) the agent hasn't heard yet: its next
    /// turn's prompt. Never in the API's job (`notes` has them all).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub heard: Vec<String>,
    /// When obid said what publishing it by hand would do (`GET /v1/jobs/{id}/publish`), and
    /// which run it described (that run's `finished`): the last two minutes' worth. Never in the
    /// API's job.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub offers: Vec<Offer>,
    /// This round is one the owner asked for with their words: it may end `done` with nothing
    /// committed. Never in the API's job.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub asked: bool,
    /// What Oby found before it started, for the first prompt (#540). Never in the API's job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief: Option<Brief>,
    /// What its `.obi/artifacts/` was published as, one per entry (crate::artifacts).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub artifacts: Vec<JobArtifact>,
    /// Why an entry of its `.obi/artifacts/` wasn't published, as of its last end.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub artifact_problems: Vec<String>,
    /// The job this one follows up: the owner told that one something after it ended (Sangam's
    /// design, the owner's decision of 2026-10-18).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follow_up_of: Option<String>,
    /// What the job it follows up did, for its first prompt, quoted there. Never in the API's job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub earlier: Option<String>,
    /// The branch in obid's clone its worktree starts from instead of its base: the first job's,
    /// for a follow-up of work that isn't merged. Never in the API's job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_from: Option<String>,
    /// What its turns used, in tokens and cost, as its tool reported them (#731).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<crate::usage::Tokens>,
}

/// One artifact a job published: the entry of `.obi/artifacts/` it came from, so the job's next
/// end gives it a new version rather than a new artifact. The API shows `{id, version}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JobArtifact {
    pub id: String,
    pub version: u32,
    pub entry: String,
}

impl Job {
    /// Whether its pull request was merged, as the job's `pullRequest` says: it's finished for
    /// good. obid follows no pull request yet, so none reads merged until it does.
    pub fn merged(&self) -> bool {
        self.to_json()["pullRequest"]["state"] == "MERGED"
    }

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
            published: None,
            pushed: None,
            publish_error: None,
            publish_step: None,
            outgoing: Vec::new(),
            pull_request: None,
            pull_request_error: None,
            review_error: None,
            summaries: None,
            issue: None,
            rounds: None,
            round: None,
            check: None,
            model: None,
            effort: None,
            notes: None,
            files: None,
            attachments: None,
            limit: None,
            start_commit: None,
            mode: None,
            waiting: None,
            phase: None,
            dismissed: None,
            worktree: None,
            obi: None,
            conversation: None,
            review_result: None,
            obi_request: None,
            permission: None,
            mac_check: None,
            apple_check: None,
            apple_ran: None,
            apple_token: None,
            answered: Vec::new(),
            answered_count: 0,
            connection_uses: Vec::new(),
            tetrix: None,
            connections: None,
            heard: Vec::new(),
            offers: Vec::new(),
            asked: false,
            brief: None,
            artifacts: Vec::new(),
            artifact_problems: Vec::new(),
            follow_up_of: None,
            earlier: None,
            start_from: None,
            usage: None,
        }
    }

    /// obid said, at `now`, what publishing its latest run by hand would do.
    pub fn offered(&mut self, now: i64) {
        self.offers.retain(|offer| now - offer.at < OFFERS_KEPT);
        self.offers.push(Offer {
            run: self.finished,
            at: now,
        });
    }

    /// Whether a device's approval signed at `signed_at` can only be of the job's latest run: the
    /// run ended before it was signed, and nothing obid said in the two minutes before it was of
    /// an earlier run (one device may have shown that one while another asked again). The
    /// sentence a device signs names the branch, not its commits, so an approval that could be of
    /// either is refused; two minutes on, it can't be.
    pub fn approvable_at(&self, signed_at: i64) -> bool {
        self.finished.is_none_or(|ended| ended <= signed_at)
            && !self.offers.iter().any(|offer| {
                offer.at <= signed_at
                    && signed_at - offer.at < OFFERS_KEPT
                    && offer.run != self.finished
            })
    }

    /// The owner's review job: always in Plan mode. A review another Obi asked for
    /// runs its own way (runner-api.md, "obid only: Obi-to-Obi review jobs").
    pub fn read_only(&self) -> bool {
        READ_ONLY.contains(&self.kind.as_str()) && self.obi.is_none()
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

    /// Commits beyond its base that aren't on its pull request yet: all of them before it's
    /// published, then the ones later rounds made (Engine/Jobs.swift, `unpublished`). On a remote
    /// with no pull requests, the ones that aren't pushed; one whose pull request failed after the
    /// push has it still to open, so all of them (#627).
    pub fn unpublished(&self) -> u64 {
        let commits = self.commits.unwrap_or(0);
        let on_it = match (&self.published, &self.publish_error) {
            (Some(_), _) => self.pushed.unwrap_or(commits),
            (None, None) => self.pushed.unwrap_or(0),
            (None, Some(_)) => 0,
        };
        commits.saturating_sub(on_it)
    }

    /// Pushed, with no pull request to open: its remote has none, and it has every commit.
    pub fn pushed_only(&self) -> bool {
        self.published.is_none()
            && self.publish_error.is_none()
            && self.pushed.is_some_and(|n| n > 0)
            && self.unpublished() == 0
    }

    /// Whether its pull request, if it has one, is open as far as obid knows.
    pub fn pull_request_open(&self) -> bool {
        self.pull_request.as_ref().is_none_or(|pr| pr.is_open())
    }

    /// Done, with commits that aren't on its pull request yet: obid publishes it when it ends, and
    /// offers Publish when that failed. Not once dismissed, never on a review or research job, and
    /// never once its pull request was merged or closed.
    pub fn can_publish(&self) -> bool {
        self.status == Status::Done
            && self.kind != "research"
            && self.kind != "review"
            && self.base.is_some()
            && self.unpublished() > 0
            && self.dismissed.is_none()
            && self.pull_request_open()
    }

    /// Done with commits its pull request will never take: it was merged or closed before they
    /// went out.
    pub fn stranded(&self) -> bool {
        self.status == Status::Done
            && self.published.is_some()
            && self.unpublished() > 0
            && !self.pull_request_open()
    }

    /// The last commit obid pushed to the job's branch: its pull request's head, as obid left it.
    pub fn pushed_head(&self) -> Option<&str> {
        self.outgoing
            .iter()
            .rev()
            .find(|o| o.action == "push" && o.branch.as_deref() == Some(self.branch.as_str()))
            .map(|o| o.id.as_str())
    }

    /// It just published to `url`: an observation of another pull request no longer holds, and
    /// nothing reviews it but a person until obid runs Oby's review.
    pub fn was_published(&mut self, url: String) {
        if self.published.as_deref() != Some(url.as_str()) {
            self.pull_request = None;
        }
        self.pull_request_error = None;
        self.published = Some(url);
        self.publish_error = None;
        self.review_error = Some(crate::publish::NOT_REVIEWED.into());
    }

    /// Waiting for Publish (its own publish failed), with commits its pull request won't take,
    /// failed or interrupted, and not dismissed.
    pub fn needs_you(&self) -> bool {
        self.dismissed.is_none()
            && (self.can_publish()
                || self.stranded()
                || self.status == Status::Failed
                || self.status == Status::Interrupted)
    }

    /// The job as the runner API shows it.
    pub fn to_json(&self) -> Value {
        let date = |t: Option<i64>| t.map(obi_protocol::time::format);
        // `title` is the derived one, always a string, as the Swift runner sends it.
        let mut value = json!({
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
            "commits": self.commits,
            "published": self.published,
            "pushed": self.pushed,
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
            "pullRequest": self.pull_request.as_ref().map(crate::github::PullRequest::to_json),
            "pullRequestError": self.pull_request_error,
            "dismissed": date(self.dismissed),
            "reviewing": null,
            "review": null,
            "reviewError": self.review_error,
            "reviewOf": null,
            "files": self.files,
            "lead": null,
            "claim": null,
            "outgoing": self.outgoing.iter().map(crate::publish::Outgoing::to_json).collect::<Vec<_>>(),
            "question": null,
            "limit": self.limit,
            "startCommit": self.start_commit,
            "firstSwiftBuildSeconds": null,
            "macCheck": mac_check_json(self.mac_check.clone(), "merge"),
            // obid never merges (runner-api.md, "obid only: what obid leaves out").
            "mergeError": null,
            "appleCheck": mac_check_json(self.apple_check.clone(), "apple"),
            "appleRan": mac_check_json(self.apple_ran.clone(), "apple"),
            "tetrix": self.tetrix.as_ref().map(crate::tetrix::Use::to_json),
            "moves": [],
            "xcodeCloud": null,
            "xcodeCloudError": null,
            "startWhen": null,
            "waiting": self.waiting.as_ref().filter(|_| self.status == Status::Queued),
            "mode": self.mode.as_deref().unwrap_or("bypass"),
            "permission": self.permission,
            "answered": self.answered.iter().map(crate::permissions::Answered::to_json).collect::<Vec<_>>(),
            "answeredCount": self.answered_count,
            "connectionUses": self.connection_uses,
            "pipeline": self.pipeline(),
            "title": self.short_title(),
            "mergeNeedsYou": false,
            "reviewNeedsYou": false,
            "cloudNeedsYou": false,
            "report": false,
            "obi": self.obi,
            "worktree": self.worktree,
            "conversation": self.conversation,
            "artifacts": self.artifacts.iter().map(|a| json!({"id": a.id, "version": a.version})).collect::<Vec<_>>(),
            "artifactProblems": self.artifact_problems,
            "followUpOf": self.follow_up_of,
        });
        if let Some(step) = self.publish_step {
            value["publishStep"] = json!(step.as_str());
        }
        if let Some(usage) = &self.usage {
            value["usage"] = json!(usage);
        }
        value
    }

    /// The stages the apps draw (Engine/Pipeline.swift): prepare, work, the check, publish,
    /// review, and the merge, which obid leaves to a person (runner-api.md, "obid only: what obid
    /// leaves out"): the Merged stage is `done` only once GitHub says a person merged it.
    pub fn pipeline(&self) -> Value {
        let active = self.status.is_active();
        let stopped = matches!(
            self.status,
            Status::Failed | Status::Stopped | Status::Interrupted
        );
        let phase = self.phase.unwrap_or(
            if self.status == Status::Queued
                || (self.started.is_none()
                    && self.status != Status::Done
                    && self.published.is_none())
            {
                Phase::Prepare
            } else {
                Phase::Work
            },
        );
        let working = active && phase == Phase::Work;
        let failure = if self.summary.is_empty() {
            let mut status = self.status.as_str().to_owned();
            if let Some(first) = status.get_mut(0..1) {
                first.make_ascii_uppercase();
            }
            status
        } else {
            self.summary.clone()
        };
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
        let merge_base = self
            .pull_request
            .as_ref()
            .map(|pr| pr.base.as_str())
            .or(self.base.as_deref())
            .unwrap_or("dev");
        stages.push(json!({"id": "publish", "title": "Publish", "state": "upcoming", "detail": "Secret scan, push and pull request"}));
        stages.push(json!({"id": "review", "title": "Review", "state": "upcoming", "detail": "Waiting for review"}));
        stages.push(json!({"id": "merged", "title": format!("Merged into {merge_base}"), "state": "upcoming"}));
        let id_of = |p: Phase| match p {
            Phase::Prepare => "prepare",
            Phase::Work => "work",
            Phase::Check => "check",
            Phase::Publish => "publish",
        };
        // A stage's state, its detail when given, and its reason (none unless given).
        fn set(
            stages: &mut [Value],
            id: &str,
            state: &str,
            detail: Option<&str>,
            reason: Option<&str>,
        ) {
            if let Some(stage) = stages.iter_mut().find(|s| s["id"] == id) {
                stage["state"] = json!(state);
                if let Some(detail) = detail {
                    stage["detail"] = json!(detail);
                }
                match reason {
                    Some(reason) => stage["reason"] = json!(reason),
                    None => {
                        if let Some(object) = stage.as_object_mut() {
                            object.remove("reason");
                        }
                    }
                }
            }
        }
        let phase_id = id_of(phase);
        let phase_index = stages.iter().position(|s| s["id"] == phase_id).unwrap_or(1);
        for stage in stages.iter_mut().take(phase_index) {
            stage["state"] = json!("done");
        }
        let can_publish = self.can_publish();
        if active {
            let detail =
                (phase == Phase::Prepare && !self.step.is_empty()).then_some(self.step.as_str());
            set(&mut stages, phase_id, "current", detail, None);
            if phase == Phase::Publish {
                let detail = self
                    .publish_step
                    .map_or("Secret scan", crate::publish::Step::detail);
                set(&mut stages, "publish", "current", Some(detail), None);
            }
        } else if stopped {
            set(&mut stages, phase_id, "failed", None, Some(&failure));
            for stage in stages.iter_mut().skip(phase_index + 1) {
                stage["state"] = json!("skipped");
            }
        } else {
            for id in ["prepare", "work", "check"] {
                set(&mut stages, id, "done", None, None);
            }
            if can_publish {
                let detail = self
                    .publish_step
                    .map_or("Ready to publish", crate::publish::Step::detail);
                let state = if self.publish_error.is_some() {
                    "failed"
                } else {
                    "current"
                };
                set(
                    &mut stages,
                    "publish",
                    state,
                    Some(detail),
                    self.publish_error.as_deref(),
                );
            } else if self.pushed_only() {
                set(
                    &mut stages,
                    "publish",
                    "done",
                    Some("Secret scan clean · pushed · no pull request for this remote"),
                    None,
                );
                for id in ["review", "merged"] {
                    set(&mut stages, id, "skipped", None, None);
                }
            } else if self.published.is_none() {
                for id in ["publish", "review", "merged"] {
                    set(&mut stages, id, "skipped", None, None);
                }
            }
        }
        // A pull request from an earlier round doesn't complete the current work, check or publish.
        if self.published.is_some() && !active && !stopped && !can_publish {
            set(
                &mut stages,
                "publish",
                "done",
                Some("Secret scan clean · pushed · pull request opened"),
                None,
            );
            let decision = self
                .pull_request
                .as_ref()
                .and_then(|pr| pr.review_decision.as_deref());
            match self.pull_request.as_ref().map(|pr| pr.state.as_str()) {
                Some("MERGED") => {
                    let detail = match decision {
                        Some("APPROVED") => "Approved",
                        Some("CHANGES_REQUESTED") => "Review complete",
                        _ => "Merged without review",
                    };
                    set(&mut stages, "review", "done", Some(detail), None);
                    set(&mut stages, "merged", "done", None, None);
                }
                Some("CLOSED") => {
                    set(
                        &mut stages,
                        "review",
                        "failed",
                        None,
                        Some("Pull request closed without merging."),
                    );
                    set(&mut stages, "merged", "skipped", None, None);
                }
                _ => match decision {
                    Some("APPROVED") => {
                        set(&mut stages, "review", "done", Some("Approved"), None);
                        set(
                            &mut stages,
                            "merged",
                            "current",
                            Some("Ready for you to merge"),
                            None,
                        );
                    }
                    Some("CHANGES_REQUESTED") => {
                        set(
                            &mut stages,
                            "review",
                            "failed",
                            Some("Changes requested"),
                            Some("The reviewer requested changes."),
                        );
                    }
                    _ => {
                        let detail = match (&self.review_error, &self.pull_request) {
                            (Some(error), _) => format!("Waiting for review · {error}"),
                            (None, None) => "Waiting for GitHub status".into(),
                            (None, Some(_)) => "Waiting for review".into(),
                        };
                        set(&mut stages, "review", "current", Some(&detail), None);
                    }
                },
            }
        }
        // The owner let it go: nothing is published, reviewed or merged. A pull request from an
        // earlier round keeps its own progress; a failed publish keeps its reason.
        if self.dismissed.is_some()
            && !active
            && (self.published.is_none() || stopped)
            && let Some(publish) = stages.iter().position(|s| s["id"] == "publish")
        {
            stages[publish]["state"] = json!("skipped");
            stages[publish]["detail"] = json!("Dismissed");
            if (phase != Phase::Publish || !stopped)
                && let Some(object) = stages[publish].as_object_mut()
            {
                object.remove("reason");
            }
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

fn mac_check_json(check: Option<Value>, kind: &str) -> Value {
    let Some(mut check) = check else {
        return Value::Null;
    };
    if check["kind"].is_null() {
        check["kind"] = json!(kind);
    }
    for key in [
        "started",
        "finished",
        "mac",
        "steps",
        "failures",
        "checkRun",
        "comment",
        "postError",
    ] {
        if check.get(key).is_none() {
            check[key] = Value::Null;
        }
    }
    check
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
            "conversation",
            "followUpOf",
        ] {
            assert_eq!(object.get(key), Some(&Value::Null), "{key}");
        }
        // The Swift runner's 65 keys, and obid's eight.
        assert_eq!(object.len(), 73);
        assert_eq!(value["artifacts"], json!([]));
        assert_eq!(value["artifactProblems"], json!([]));
        assert_eq!(value["answered"], json!([]));
        assert_eq!(value["answeredCount"], 0);
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

    /// Engine/Pipeline.swift for a published job, with obid's own rule: the Merged stage is done
    /// only once a person merged it (runner-api.md, "obid only: what obid leaves out").
    #[test]
    fn a_published_pipeline_follows_github_and_never_merges() {
        let mut job = job();
        job.kind = "fix".into();
        job.pr = None;
        job.base = Some("dev".into());
        job.status = Status::Done;
        job.started = Some(job.created);
        job.commits = Some(1);
        let state = |job: &Job, id: &str| -> (String, String) {
            let stage = job.pipeline()["stages"]
                .as_array()
                .unwrap()
                .iter()
                .find(|s| s["id"] == id)
                .cloned()
                .unwrap();
            (
                stage["state"].as_str().unwrap().to_owned(),
                stage["detail"].as_str().unwrap_or("").to_owned(),
            )
        };
        // Done with a commit it couldn't publish: Publish failed, with why.
        job.publish_error = Some("Couldn't push".into());
        assert!(job.can_publish() && job.needs_you());
        assert_eq!(state(&job, "publish").0, "failed");
        assert_eq!(job.pipeline()["stages"][2]["reason"], "Couldn't push");
        // Pushed, then the pull request failed: still publishable, for the pull request (#627).
        job.pushed = Some(1);
        job.publish_error = Some("Pushed, but couldn't open the pull request: gh broke".into());
        assert!(job.can_publish() && !job.pushed_only());
        // Pushed to a remote with no pull requests: nothing left to publish.
        job.publish_error = None;
        assert!(job.pushed_only() && !job.can_publish() && !job.needs_you());
        assert_eq!(
            state(&job, "publish"),
            (
                "done".into(),
                "Secret scan clean · pushed · no pull request for this remote".into()
            )
        );
        assert_eq!(state(&job, "review").0, "skipped");
        // A new commit on it isn't pushed yet.
        job.commits = Some(2);
        assert!(job.can_publish() && !job.pushed_only());
        job.commits = Some(1);
        job.pushed = None;
        // Published: Review waits, Merged is upcoming.
        job.was_published("https://github.com/deskree-inc/oby/pull/42".into());
        job.pushed = Some(1);
        assert!(!job.can_publish() && !job.needs_you());
        assert_eq!(
            state(&job, "publish"),
            (
                "done".into(),
                "Secret scan clean · pushed · pull request opened".into()
            )
        );
        assert_eq!(state(&job, "review").0, "current");
        assert_eq!(state(&job, "merged").0, "upcoming");
        let pr = |state: &str, decision: Option<&str>| crate::github::PullRequest {
            state: state.into(),
            review_decision: decision.map(str::to_owned),
            base: "dev".into(),
            merged_at: (state == "MERGED").then_some(job.created),
            checked_at: job.created,
            head: None,
        };
        job.pull_request = Some(pr("OPEN", Some("APPROVED")));
        assert_eq!(state(&job, "review"), ("done".into(), "Approved".into()));
        assert_eq!(
            state(&job, "merged"),
            ("current".into(), "Ready for you to merge".into())
        );
        job.pull_request = Some(pr("OPEN", Some("CHANGES_REQUESTED")));
        assert_eq!(
            state(&job, "review"),
            ("failed".into(), "Changes requested".into())
        );
        job.pull_request = Some(pr("MERGED", None));
        assert_eq!(
            state(&job, "review"),
            ("done".into(), "Merged without review".into())
        );
        assert_eq!(state(&job, "merged").0, "done");
        job.pull_request = Some(pr("CLOSED", None));
        assert_eq!(state(&job, "review").0, "failed");
        assert_eq!(state(&job, "merged").0, "skipped");
        // A later round's commits the closed pull request won't take: stranded, and it needs you.
        job.commits = Some(2);
        assert!(job.stranded() && job.needs_you() && !job.can_publish());
        // Its last push is its pull request's head.
        job.outgoing.push(crate::publish::Outgoing::new(
            "push",
            &job.repo,
            "abc",
            Some("oby/other"),
        ));
        job.branch = "oby/fix-42".into();
        job.outgoing.push(crate::publish::Outgoing::new(
            "push",
            &job.repo,
            "def",
            Some("oby/fix-42"),
        ));
        assert_eq!(job.pushed_head(), Some("def"));
    }
}
