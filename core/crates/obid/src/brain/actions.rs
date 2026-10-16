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
use crate::sphere::inbox::{Confirmed, action};

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
/// After research (`researched`), the jobs a plan names wait for the user's Start instead.
pub async fn answer(
    shared: &Arc<Shared>,
    planned: &Planned,
    asked: &Asked<'_>,
    researched: bool,
    live: &(dyn Fn() -> bool + Send + Sync),
) -> Talk {
    let plan = &planned.plan;
    match plan.action {
        Action::Dispatch => dispatch(shared, plan, asked, researched, live).await,
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
    researched: bool,
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
    // Jobs that would start in Bypass mode, waiting for the owner's Confirm.
    let mut waiting: Vec<String> = vec![];
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
        // Work found by research waits in the inbox for the user's Start (#374).
        if researched {
            let title = d
                .title
                .clone()
                .unwrap_or_else(|| super::briefing::line(&d.task, 60));
            let about =
                d.pr.map(|pr| format!(" PR #{pr}"))
                    .or_else(|| d.issue.map(|issue| format!(" #{issue}")))
                    .unwrap_or_default();
            let repo = d.repo.rsplit('/').next().unwrap_or(&d.repo);
            let text = format!(
                "Oby looked into it first. Start {} {repo}{about} ({title})?",
                d.kind.as_str()
            );
            shared.link.propose(&new, title, text);
            continue;
        }
        // A job that would never ask the owner anything widens trust: only their own Confirm
        // starts it (the owner's decision of 2026-10-16; review on #551).
        if new.mode.as_deref() == Some("bypass") {
            let what = describe(&new);
            confirm(
                shared,
                "",
                format!("Start {what}"),
                format!(
                    "Oby's brain planned a job that never asks you anything: {what}. It starts only if you confirm."
                ),
                Confirmed {
                    action: action::START_JOB.into(),
                    target: asked.conversation.to_owned(),
                    payload: serde_json::json!({"job": new}),
                },
            );
            waiting.push(what);
            continue;
        }
        match shared.jobs.create(new) {
            Ok(job) => {
                jobs.push(job.to_json());
                started.push(job);
            }
            // What couldn't start is said; what did start goes on.
            Err(refused) => {
                let mut text = refused.0;
                if !started.is_empty() {
                    text = format!("{} {text}", started_line(shared, &started));
                }
                return Talk::Reply { text, jobs };
            }
        }
    }
    if researched {
        return Talk::reply(
            "I looked into it first. A draft is waiting in your inbox; tap Start when you're ready.",
        );
    }
    let mut text = match (started.is_empty(), plan.reply.is_empty()) {
        (true, _) => String::new(),
        (false, true) => started_line(shared, &started),
        (false, false) => plan.reply.clone(),
    };
    if !waiting.is_empty() {
        let line = format!(
            "Starting {} in Bypass mode waits for your OK: confirm it in your inbox.",
            waiting.len().to_string() + if waiting.len() == 1 { " job" } else { " jobs" }
        );
        text = if text.is_empty() {
            line
        } else {
            format!("{text} {line}")
        };
    }
    Talk::Reply { text, jobs }
}

/// A planned job in obid's own words, for confirm and start items: what, where, how it asks,
/// on which tool and account, and its check. "fix fixture-app #12 (Login screen) in Bypass
/// mode, on Claude Code · Personal, check node --test".
pub fn describe(new: &NewJob) -> String {
    let repo = new.repo.rsplit('/').next().unwrap_or(&new.repo);
    let mut what = format!("{} {repo}", new.kind);
    if let Some(issue) = new.issue {
        what.push_str(&format!(" #{issue}"));
    } else if let Some(pr) = new.pr {
        what.push_str(&format!(" PR #{pr}"));
    }
    if let Some(title) = new.title.as_deref().filter(|t| !t.trim().is_empty()) {
        what.push_str(&format!(" ({})", super::briefing::line(title, 60)));
    }
    if let Some(mode) = new
        .mode
        .as_deref()
        .and_then(crate::permissions::Mode::parse)
    {
        what.push_str(&format!(" in {} mode", mode.title()));
    }
    let agent = new.agent.as_deref().unwrap_or("auto");
    let agent = crate::agent::Tool::from_id(agent).map_or(agent, |t| t.name());
    what.push_str(&format!(
        ", on {agent} · {}",
        super::briefing::line(new.account.as_deref().unwrap_or("auto"), 40)
    ));
    if let Some(check) = new.check.as_deref().filter(|c| !c.trim().is_empty()) {
        what.push_str(&format!(", check {}", super::briefing::line(check, 120)));
    }
    what
}

/// What started, in Oby's voice (`Desk.startedLine`): "On it. Claude Code is fixing oby #12
/// (Login screen) on Deskree, and Claude Code is reviewing oby PR #33 on Deskree."
fn started_line(shared: &Shared, jobs: &[Job]) -> String {
    let parts: Vec<String> = jobs
        .iter()
        .map(|job| {
            let doing = match job.kind.as_str() {
                "review" => "reviewing",
                "fix" => "fixing",
                "build" => "building",
                "test" => "testing",
                "investigate" => "investigating",
                "research" => "researching",
                other => other,
            };
            format!(
                "{} is {doing} {} on {}",
                tool_name(&job.agent),
                what(job),
                account_name(shared, &job.account)
            )
        })
        .collect();
    format!("On it. {}.", list(&parts))
}

/// "oby #12 (Login screen)", "oby PR #33".
fn what(job: &Job) -> String {
    let mut what = job.repo_name().to_owned();
    if let Some(pr) = job.pr {
        what.push_str(&format!(" PR #{pr}"));
    } else if let Some(issue) = job.issue {
        what.push_str(&format!(" #{issue}"));
    }
    if let Some(title) = job.title.as_deref().filter(|t| !t.trim().is_empty()) {
        what.push_str(&format!(" ({title})"));
    }
    what
}

/// "a", "a, and b", "a, b, and c".
fn list(parts: &[String]) -> String {
    match parts {
        [] => String::new(),
        [one] => one.clone(),
        [rest @ .., last] => format!("{}, and {last}", rest.join(", ")),
    }
}

fn tool_name(agent: &str) -> &str {
    crate::agent::Tool::from_id(agent).map_or(agent, |t| t.name())
}

/// An account's name, by its id.
fn account_name(shared: &Shared, id: &str) -> String {
    let agents = &shared.config.agents;
    [&agents.claude, &agents.codex, &agents.cursor]
        .into_iter()
        .flatten()
        .flat_map(|a| a.accounts.iter())
        .find(|a| a.id == id)
        .map_or_else(
            || match id {
                "default" => "Default".to_owned(),
                "codex" => "Codex".to_owned(),
                other => other.to_owned(),
            },
            |a| a.name.clone(),
        )
}

/// "Claude Code · Personal": where a job runs.
fn place(shared: &Shared, job: &Job) -> String {
    format!(
        "{} · {}",
        tool_name(&job.agent),
        account_name(shared, &job.account)
    )
}

/// What a job hears when the user tries it again (`Inbox.tryAgainMessage`).
pub const TRY_AGAIN: &str =
    "Try again, picking up where you left off. Finish with a short summary as asked.";

/// Carries out an action that changes something, and says what happened.
pub async fn act(shared: &Arc<Shared>, plan: &Plan) -> Outcome {
    match plan.action {
        Action::StopAgent => stop(shared, plan),
        Action::SetMode => set_mode(shared, plan),
        Action::AnswerPermission => answer_permission(shared, plan),
        Action::RetryJob | Action::DismissJob | Action::StartNow => on_jobs(shared, plan),
        Action::AnswerInbox => answer_inbox(shared, plan).await,
        Action::SetSetting => set_setting(shared, plan),
        Action::MoveJob => {
            let names: Vec<String> = plan
                .named()
                .iter()
                .map(|id| shared.jobs.get(id).map_or(id.clone(), |j| j.short_title()))
                .collect();
            Outcome::Failed(format!(
                "Couldn't move {}: obid can't move a job to another tool, account or model yet (#447).",
                if names.len() == 1 {
                    "it".to_owned()
                } else {
                    names.join(", ")
                }
            ))
        }
        Action::AskReviewAgain => Outcome::Failed(
            "Couldn't ask for another review: obid follows no pull request yet.".into(),
        ),
        other => Outcome::Failed(format!(
            "Couldn't do that: {} is only for Oby's event orchestrator.",
            other.as_str()
        )),
    }
}

/// retry_job, dismiss_job and start_now (Engine/JobActions.swift, `actOnJobs`), one line per
/// job. It failed when nothing happened to any of them.
fn on_jobs(shared: &Arc<Shared>, plan: &Plan) -> Outcome {
    let ids = plan.named();
    if ids.is_empty() {
        return Outcome::Failed("Say which job.".into());
    }
    let mut lines: Vec<String> = vec![];
    let mut any = false;
    for id in ids {
        let Some(job) = shared.jobs.get(id) else {
            lines.push(if ids.len() == 1 {
                "That job isn't here any more.".into()
            } else {
                format!("Couldn't do that for {id}: it isn't here any more.")
            });
            continue;
        };
        let name = job.short_title();
        let (line, done) = match plan.action {
            Action::RetryJob => retry(shared, &job),
            Action::DismissJob => match shared.jobs.dismiss(id) {
                Some(Ok(_)) => (format!("Let {name} go."), true),
                Some(Err(refused)) => (format!("Couldn't let {name} go: {}", refused.0), false),
                None => ("That job isn't here any more.".into(), false),
            },
            // obid starts every job at once (#455): none waits for a Start when.
            _ => (
                format!("Couldn't start {name}: it isn't waiting for a Start when."),
                false,
            ),
        };
        any |= done;
        lines.push(line);
    }
    let text = lines.join(" ");
    if any {
        Outcome::Done(text)
    } else {
        Outcome::Failed(text)
    }
}

/// Runs a job that failed or was cut off again, where it left off (`Desk.retry`): obid has no
/// failed-job inbox item, so it tells the job's agent to try again, which picks its session up.
fn retry(shared: &Arc<Shared>, job: &Job) -> (String, bool) {
    let name = job.short_title();
    if job.status.is_active() {
        return (
            format!("Couldn't try {name} again: it's still running."),
            false,
        );
    }
    if !matches!(
        job.status,
        crate::job::Status::Failed | crate::job::Status::Interrupted
    ) {
        return (
            format!("Couldn't try {name} again: it didn't fail, and no round is waiting for you."),
            false,
        );
    }
    match shared.jobs.message(&job.id, TRY_AGAIN) {
        Some(Ok(job)) => (
            format!("Started {name} again on {}.", place(shared, &job)),
            true,
        ),
        Some(Err(refused)) => (format!("Couldn't try {name} again: {}", refused.0), false),
        None => ("That job isn't here any more.".into(), false),
    }
}

/// answer_inbox: an item of the inbox, with one of its options or the user's own words
/// (`Desk.answerInbox`).
async fn answer_inbox(shared: &Arc<Shared>, plan: &Plan) -> Outcome {
    let Some(id) = plan.item.as_deref() else {
        return Outcome::Failed("Say which inbox item to answer.".into());
    };
    let Some(item) = shared.link.item(id) else {
        return Outcome::Failed("That inbox item isn't here any more.".into());
    };
    if item.done.is_some() {
        return Outcome::Failed(format!(
            "Couldn't answer {}: it's done already.",
            item.title
        ));
    }
    let mut words = plan.answer.as_deref().unwrap_or("").trim().to_owned();
    if let Some(option) = plan.option {
        let Some(chosen) = usize::try_from(option - 1)
            .ok()
            .and_then(|i| item.options.get(i))
        else {
            return Outcome::Failed(format!(
                "Couldn't answer {}: it has {} option{}, not {option}.",
                item.title,
                item.options.len(),
                if item.options.len() == 1 { "" } else { "s" }
            ));
        };
        words = chosen.clone();
    } else if let Some(matched) = item
        .options
        .iter()
        .find(|o| o.to_lowercase() == words.to_lowercase())
    {
        words = matched.clone();
    }
    // Every option of obid's items is Oby's own words, so it's said; the user's words aren't.
    let said = if item.options.contains(&words) {
        format!(": {words}")
    } else {
        ", with your words".to_owned()
    };
    let body = serde_json::json!({"answer": words}).to_string();
    match shared.link.answer(id, body.as_bytes()).await {
        Ok(_) => Outcome::Done(format!("Answered {}'s item{said}.", item.title)),
        Err(e) => Outcome::Failed(format!(
            "Couldn't answer {}'s item: {}",
            item.title, e.message
        )),
    }
}

/// set_setting: of what Settings has, obid keeps only how many jobs run at once.
fn set_setting(shared: &Arc<Shared>, plan: &Plan) -> Outcome {
    let Some(setting) = &plan.setting else {
        return Outcome::Failed("Couldn't change settings: the setting was missing.".into());
    };
    let Some(max) = setting.max_running else {
        return Outcome::Failed(
            "Couldn't change that: obid has no model settings or weekly reserves yet.".into(),
        );
    };
    let old = shared.jobs.max_running();
    match u32::try_from(max).map(|max| shared.jobs.set_max_running(max)) {
        Ok(Ok(new)) => Outcome::Done(format!("Changed jobs at once from {old} to {new}.")),
        Ok(Err(crate::jobs::SettingsError::Refused(why))) => {
            Outcome::Failed(format!("Couldn't change jobs at once: {why}"))
        }
        Ok(Err(crate::jobs::SettingsError::Unkept(e))) => Outcome::Failed(format!(
            "Couldn't change jobs at once: it couldn't be kept ({e})."
        )),
        Err(_) => Outcome::Failed("Couldn't change jobs at once: maxRunning is 1 to 20.".into()),
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
    // Bypass stops a job asking anything: it widens what the agent may do, so only the user's
    // own Confirm sets it (#546). The other modes are done at once: ask and plan, and
    // acceptEdits, which still asks before every command (the owner's choice).
    if mode == crate::permissions::Mode::Bypass {
        let jobs: Vec<crate::job::Job> = plan
            .named()
            .iter()
            .filter_map(|id| shared.jobs.get(id))
            .filter(|j| j.status.is_active())
            .collect();
        if jobs.is_empty() {
            return Outcome::Done("That job isn't running any more.".into());
        }
        let names: Vec<String> = jobs.iter().map(crate::job::Job::short_title).collect();
        // One item per job: each is the owner's own decision.
        for job in &jobs {
            let name = job.short_title();
            confirm(
                shared,
                &job.id,
                format!("Stop asking on {name}: Bypass mode"),
                format!(
                    "Oby's brain planned Bypass mode for {name}: obid answers everything by its rules, and the job stops asking you. It happens only if you confirm."
                ),
                Confirmed {
                    action: action::SET_MODE_BYPASS.into(),
                    target: job.id.clone(),
                    payload: serde_json::Value::Null,
                },
            );
        }
        return Outcome::Done(format!(
            "Bypass mode stops {} asking you, so it waits for your OK: confirm it in your inbox.",
            names.join(", ")
        ));
    }
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
    // Always saves a rule every later prompt of the repository's jobs follows: only the user's
    // own Confirm saves it (#546). Allow once and no are done at once.
    if decision == super::plan::Decision::Always {
        let (Some(rule), Some(always)) = (&permission.rule, &permission.always) else {
            return Outcome::Failed(format!(
                "Couldn't answer {name}: This one has no rule to save: allow it once instead."
            ));
        };
        confirm(
            shared,
            id,
            format!("Always allow {rule} in {}", job.repo),
            format!(
                "Oby's brain planned to answer {name}'s permission with always: {always}. It saves the rule {rule} for {}, and happens only if you confirm.",
                job.repo
            ),
            Confirmed {
                action: action::ALWAYS_ALLOW.into(),
                target: id.clone(),
                payload: serde_json::json!({"permission": permission.id}),
            },
        );
        return Outcome::Done(format!(
            "Always allowing saves a rule for {}, so it waits for your OK: confirm it in your inbox.",
            job.repo_name()
        ));
    }
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

/// Puts what the brain planned, which only the user may do, in the inbox as a `confirm` item:
/// carried out only on their own Confirm (`POST /v1/inbox/{id}/answer`).
fn confirm(
    shared: &Shared,
    job: &str,
    title: String,
    text: String,
    confirmed: crate::sphere::inbox::Confirmed,
) {
    let item =
        crate::sphere::inbox::confirm_item(job, title, text, confirmed, obi_protocol::time::now());
    shared.link.add_confirm(item);
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
