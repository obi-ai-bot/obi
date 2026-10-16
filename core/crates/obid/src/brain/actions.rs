//! What obid does for a plan (`Desk.card`): the answers (a reply, a question, the jobs it
//! starts) and the actions that change something, each ending as an [`Outcome`] rather than a
//! reply whose first words say whether it worked (#538).

use std::sync::Arc;

use serde_json::Value;

use super::plan::{Action, Plan, Question};
use super::planner::Planned;
use crate::api::Shared;
use crate::job::Job;
use crate::jobs::NewJob;

/// How an action that changes something ended: what Oby says about it, and whether it happened.
/// A failed one ends the turn, and the user hears why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Done(String),
    Failed(String),
}

impl Outcome {
    pub fn text(&self) -> &str {
        match self {
            Outcome::Done(text) | Outcome::Failed(text) => text,
        }
    }

    pub fn failed(&self) -> bool {
        matches!(self, Outcome::Failed(_))
    }
}

/// What a turn answers.
#[derive(Debug, Clone, PartialEq)]
pub enum Talk {
    /// Nothing to say.
    None,
    /// A reply, with the jobs its plan started.
    Reply { text: String, jobs: Vec<Value> },
    /// A question, with the words it asks about.
    Question { said: String, question: Question },
}

impl Talk {
    pub fn reply(text: impl Into<String>) -> Talk {
        Talk::Reply {
            text: text.into(),
            jobs: vec![],
        }
    }
}

/// What the plan's answer started its jobs with.
pub struct Asked<'a> {
    pub said: &'a str,
    pub attachments: &'a [String],
    pub conversation: &'a str,
}

/// A plan that answers rather than acts: a reply, a question, or jobs it starts (#269). `live` is
/// asked right before the jobs start: the issues' files take network time, and a turn cancelled
/// meanwhile starts nothing.
pub async fn answer(
    shared: &Arc<Shared>,
    planned: &Planned,
    asked: &Asked<'_>,
    live: &(dyn Fn() -> bool + Send + Sync),
) -> Talk {
    let plan = &planned.plan;
    match plan.action {
        Action::Dispatch => dispatch(shared, plan, asked, live).await,
        Action::AskUser => match &plan.question {
            Some(question) => Talk::Question {
                said: asked.said.to_owned(),
                question: question.clone(),
            },
            None => Talk::reply(plan.reply.clone()),
        },
        Action::ReplyOnly | Action::Ignore => {
            if plan.reply.is_empty() {
                return Talk::None;
            }
            // The brain counted wrong: with agents working, Oby never says nothing is running.
            // The facts come from the jobs the header counts (#11).
            let jobs = shared.jobs.list(usize::MAX);
            if super::briefing::working(&jobs) > 0 && super::briefing::contradicts(&plan.reply) {
                return Talk::reply(super::briefing::working_line(&jobs, &shared.host));
            }
            Talk::reply(plan.reply.clone())
        }
        // Read in the turn's loop: one that gets here changes nothing and says nothing.
        _ => Talk::None,
    }
}

/// Starts the plan's jobs, each with its issue's files, linked to the conversation.
async fn dispatch(
    shared: &Arc<Shared>,
    plan: &Plan,
    asked: &Asked<'_>,
    live: &(dyn Fn() -> bool + Send + Sync),
) -> Talk {
    let mut files = vec![];
    for d in &plan.dispatches {
        files.push(match d.issue {
            Some(issue) if issue > 0 => super::issue_files(&d.repo, issue as u64).await,
            _ => None,
        });
    }
    // Cancelled while the files were read: nothing starts, and nothing asks.
    if !live() {
        tracing::info!(
            "{:?}: the turn ended while its jobs were made; nothing started",
            asked.said
        );
        return Talk::None;
    }
    let mut jobs = vec![];
    let mut started: Vec<Job> = vec![];
    for (d, files) in plan.dispatches.iter().zip(files) {
        // An issue and a pull request is the issue's work started from the pull request (#219):
        // obid has no `fromPR` yet, so the job is the issue's, from its repository's base.
        let new = NewJob {
            repo: d.repo.clone(),
            kind: d.kind.as_str().into(),
            task: d.task.clone(),
            title: d.title.clone(),
            request: Some(asked.said.into()),
            pr: if d.issue.is_some() {
                None
            } else {
                d.pr.map(|pr| pr as u64)
            },
            issue: d.issue.map(|issue| issue as u64),
            account: Some(d.account.clone()),
            agent: Some(d.agent.clone()),
            rounds: Some(d.rounds as u32),
            check: d.check.clone(),
            files,
            attachments: (!asked.attachments.is_empty()).then(|| asked.attachments.to_vec()),
            conversation: Some(asked.conversation.to_owned()),
            base: d.base_branch.clone(),
            mode: d.mode.map(|m| m.as_str().to_owned()),
            ..NewJob::default()
        };
        match shared.jobs.create(new) {
            Ok(job) => {
                jobs.push(job.to_json());
                started.push(job);
            }
            // What couldn't start is said; what did start goes on.
            Err(refused) => {
                let mut text = refused.0;
                if !started.is_empty() {
                    text = format!("{} {text}", started_line(&started));
                }
                return Talk::Reply { text, jobs };
            }
        }
    }
    let text = if plan.reply.is_empty() {
        started_line(&started)
    } else {
        plan.reply.clone()
    };
    Talk::Reply { text, jobs }
}

/// "Started 2 jobs: Vault secrets, Watch home."
fn started_line(jobs: &[Job]) -> String {
    let names: Vec<String> = jobs.iter().map(Job::short_title).collect();
    format!(
        "Started {} job{}: {}.",
        jobs.len(),
        if jobs.len() == 1 { "" } else { "s" },
        names.join(", ")
    )
}

/// Carries out an action that changes something, and says what happened.
pub async fn act(shared: &Arc<Shared>, plan: &Plan) -> Outcome {
    match plan.action {
        Action::StopAgent => stop(shared, plan),
        Action::SetMode => set_mode(shared, plan),
        Action::AnswerPermission => answer_permission(shared, plan),
        other => Outcome::Failed(format!(
            "Couldn't do that: obid can't {} yet.",
            other.as_str().replace('_', " ")
        )),
    }
}

/// The jobs the brain named ("cancel it"), or everything only when the user asked for all of
/// it in so many words. Says what stopped, not the brain's reply: it doesn't know what ran.
fn stop(shared: &Arc<Shared>, plan: &Plan) -> Outcome {
    let named = plan.named();
    if named.is_empty() && plan.all != Some(true) {
        return Outcome::Failed("Say which job to stop, or “stop everything”.".into());
    }
    if named.is_empty() {
        let stopped = shared.jobs.stop_all();
        return Outcome::Done(if stopped.is_empty() {
            "Nothing is running.".into()
        } else {
            format!(
                "Stopped {} job{}.",
                stopped.len(),
                if stopped.len() == 1 { "" } else { "s" }
            )
        });
    }
    let mut stopped: Vec<String> = vec![];
    for id in named {
        if let Some(job) = shared.jobs.get(id).filter(|j| j.status.is_active()) {
            shared.jobs.stop(&job.id);
            stopped.push(job.short_title());
        }
    }
    Outcome::Done(if stopped.is_empty() {
        "That job isn't running any more.".into()
    } else {
        format!("Stopped {}.", stopped.join(", "))
    })
}

/// "Stop asking on the Watch job": a running job's mode, as `POST /v1/jobs/{id}/mode` sets it.
fn set_mode(shared: &Arc<Shared>, plan: &Plan) -> Outcome {
    let Some(mode) = plan.mode else {
        return Outcome::Failed("Say which mode.".into());
    };
    let mode = mode.to_permissions();
    let mut done: Vec<String> = vec![];
    for id in plan.named() {
        if shared.jobs.get(id).is_some_and(|j| j.status.is_active())
            && let Some(job) = shared.jobs.set_mode(id, mode)
        {
            done.push(job.short_title());
        }
    }
    if done.is_empty() {
        return Outcome::Done("That job isn't running any more.".into());
    }
    Outcome::Done(format!(
        "{} {} in {} mode now.",
        done.join(", "),
        if done.len() == 1 { "is" } else { "are" },
        mode.title()
    ))
}

/// "Allow it", "always allow that", "no, run only the runner tests": the permission waiting on
/// the job the conversation is about.
fn answer_permission(shared: &Arc<Shared>, plan: &Plan) -> Outcome {
    let (Some(id), Some(decision)) = (plan.named().first(), plan.decision) else {
        return Outcome::Failed("Say which job to answer.".into());
    };
    let Some(job) = shared.jobs.get(id) else {
        return Outcome::Done("That job isn't waiting for your OK any more.".into());
    };
    let name = job.short_title();
    let Some(permission) = job.permission.as_ref() else {
        return Outcome::Done(format!("{name} isn't waiting for your OK."));
    };
    let message = plan
        .message
        .as_deref()
        .map(str::trim)
        .filter(|m| !m.is_empty());
    use crate::jobs::PermissionRefused;
    match shared
        .jobs
        .answer_permission(id, &permission.id, decision.to_permissions(), message)
    {
        Ok(_) => Outcome::Done(match decision {
            super::plan::Decision::Allow => format!("Allowed it for {name}."),
            super::plan::Decision::Always => format!(
                "Allowed it for {name}, and saved the rule for {}: it won't ask again for that.",
                job.repo_name()
            ),
            super::plan::Decision::Deny => format!(
                "Told {name} no{}",
                if message.is_some() {
                    ", with your words."
                } else {
                    "."
                }
            ),
        }),
        Err(PermissionRefused::NoJob) => {
            Outcome::Done("That job isn't waiting for your OK any more.".into())
        }
        Err(PermissionRefused::NotWaiting(why) | PermissionRefused::Refused(why)) => {
            Outcome::Failed(format!("Couldn't answer {name}: {why}"))
        }
    }
}

/// What a step event says the action does (`Desk.stepText`).
pub fn step_text(shared: &Shared, plan: &Plan) -> String {
    let names = || -> Vec<String> {
        plan.named()
            .iter()
            .filter_map(|id| shared.jobs.get(id).map(|j| j.short_title()))
            .collect()
    };
    let what = || {
        let names = names();
        if names.is_empty() {
            "the selected jobs".to_owned()
        } else {
            names.join(", ")
        }
    };
    match plan.action {
        Action::MoveJob => {
            let names = names();
            let destination = plan
                .destination
                .as_ref()
                .map(|m| {
                    let tool = crate::agent::Tool::from_id(&m.agent).map(|t| t.name());
                    let account = (m.account != "auto").then_some(m.account.as_str());
                    [tool, account]
                        .into_iter()
                        .flatten()
                        .collect::<Vec<_>>()
                        .join(" · ")
                })
                .filter(|d| !d.is_empty())
                .unwrap_or_else(|| "the selected destination".into());
            format!(
                "Moving {} to {destination}",
                if names.is_empty() {
                    "jobs".to_owned()
                } else {
                    names.join(", ")
                }
            )
        }
        Action::StopAgent => if plan.all == Some(true) {
            "Stopping all running work"
        } else {
            "Stopping the selected work"
        }
        .into(),
        Action::AnswerPermission => "Answering a permission request".into(),
        Action::SetMode => "Changing permission mode".into(),
        Action::Research => "Looking up context".into(),
        Action::RetryJob => format!("Trying {} again", what()),
        Action::DismissJob => format!("Letting {} go", what()),
        Action::AskReviewAgain => format!("Asking for another review of {}", what()),
        Action::StartNow | Action::MessageJob => format!("Starting {} now", what()),
        Action::AnswerInbox => "Answering an inbox item".into(),
        other => other.as_str().into(),
    }
}
