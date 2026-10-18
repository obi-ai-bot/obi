//! What obid does for a plan (`Desk.card`): the answers (a reply, a question, the jobs it
//! starts) and the actions that change something, each ending as an [`Outcome`] rather than a
//! reply whose first words say whether it worked (#538).

use std::sync::Arc;

use serde_json::Value;

use super::plan::{Action, Plan, Question};
use super::planner::Planned;
use crate::api::Shared;
use crate::job::Job;
use crate::jobs::{NewJob, Source};
use crate::sphere::inbox::{Confirmed, Item, action};

/// How an action that changes something ended: what Oby says about it, and whether it happened.
/// One that didn't happen ends the turn, and the user hears why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Done(String),
    /// It happened and started a job, whose card goes on the answer: a follow-up.
    Started(String, Value),
    Failed(String),
    /// Nothing happened because the plan didn't say which job or item: the user is asked to.
    NeedsWhich(String),
}

impl Outcome {
    pub fn text(&self) -> &str {
        match self {
            Outcome::Done(text)
            | Outcome::Started(text, _)
            | Outcome::Failed(text)
            | Outcome::NeedsWhich(text) => text,
        }
    }

    pub fn failed(&self) -> bool {
        !matches!(self, Outcome::Done(_) | Outcome::Started(..))
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
            brief: d.brief(),
            ..NewJob::default()
        };
        // Work found by research waits in the inbox for the user's Start (#374).
        if researched {
            let title = d
                .title
                .clone()
                .unwrap_or_else(|| super::briefing::line(&d.task, 60));
            // obid's own words for the job it keeps: mode, tool, account and check (N1); then the
            // task it planned, quoted as data, so the owner sees what would run before they Start
            // (the task is the agent's own words in a conversation; N9).
            let nonce = super::briefing::nonce();
            let text = format!(
                "Oby looked into it first. Start {}?\n\n{}\n{}",
                describe(&new),
                super::briefing::fence_rule(&nonce, "the task Oby planned"),
                super::briefing::fence(&nonce, &crate::secrets::known().redact(&d.task)),
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
    let agents = shared.config.agents.get();
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

/// Carries out an action that changes something, and says what happened. `said` is the user's
/// own words this turn, which message_job passes on; `source` is whose they are and whether the
/// turn read something untrusted, which decides what they do to a job that ended.
pub async fn act(shared: &Arc<Shared>, plan: &Plan, said: &str, source: Source) -> Outcome {
    match plan.action {
        Action::StopAgent => stop(shared, plan),
        Action::SetMode => set_mode(shared, plan),
        Action::AnswerPermission => answer_permission(shared, plan),
        Action::RetryJob | Action::DismissJob | Action::StartNow => on_jobs(shared, plan),
        Action::AnswerInbox => answer_inbox(shared, plan).await,
        Action::SetSetting => set_setting(shared, plan),
        Action::MessageJob => message_job(shared, plan, said, source),
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
            "Couldn't ask for another review: obid's brain can't ask for one yet.".into(),
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
        return Outcome::NeedsWhich("Say which job.".into());
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

/// Runs a job that failed, was stopped or was cut off again, where it left off (`Desk.retry`,
/// and the brain's prompt: "a failed, stopped or cut-off job"): obid has no
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
        crate::job::Status::Failed | crate::job::Status::Stopped | crate::job::Status::Interrupted
    ) {
        return (
            format!("Couldn't try {name} again: it didn't fail, and no round is waiting for you."),
            false,
        );
    }
    // Try again's own words pick its session up again: they never start a follow-up.
    match shared.jobs.message(&job.id, TRY_AGAIN, Source::Event) {
        Some(Ok(job)) => (
            format!("Started {name} again on {}.", place(shared, &job)),
            true,
        ),
        Some(Err(refused)) => (format!("Couldn't try {name} again: {}", refused.0), false),
        None => ("That job isn't here any more.".into(), false),
    }
}

/// message_job (#542): the user's own words reach the job's agent, with the secrets obid knows
/// taken out, never the brain's restatement of them. A running job hears them at its next turn;
/// one that ended gets a follow-up that starts with them (Sangam's design, the owner's decision of
/// 2026-10-18), and stays as it ended. After research the follow-up waits for the owner's Start;
/// an event turn's words never start one.
fn message_job(shared: &Arc<Shared>, plan: &Plan, said: &str, source: Source) -> Outcome {
    let Some(id) = plan.named().first() else {
        return Outcome::Failed("Say which job to tell.".into());
    };
    let Some(job) = shared.jobs.get(id) else {
        return Outcome::Failed("That job isn't here any more.".into());
    };
    let name = job.short_title();
    let words = match crate::vault::for_agent(said.trim()) {
        Ok(words) => crate::secrets::known().redact(&words),
        Err(why) => return Outcome::Failed(format!("Couldn't tell {name}: {why}")),
    };
    if !job.status.is_active() {
        let new = crate::jobs::follow_up(&job, &words);
        return match source {
            Source::Owner => follow_up(shared, &job, new),
            Source::Untrusted => Outcome::Done(propose_follow_up(shared, &job, &new)),
            Source::Event => Outcome::Failed(format!(
                "Couldn't tell {name}: it ended, so that starts a follow-up, which only your own words start."
            )),
        };
    }
    match shared.jobs.message(&job.id, &words, source) {
        Some(Ok(_)) => Outcome::Done(format!("Told {name} what you said.")),
        Some(Err(refused)) => Outcome::Failed(format!("Couldn't tell {name}: {}", refused.0)),
        None => Outcome::Failed("That job isn't here any more.".into()),
    }
}

/// Starts `new`, the follow-up of `job`, and says so as Sangam's design does, its card on the
/// answer.
pub(super) fn follow_up(shared: &Arc<Shared>, job: &Job, new: NewJob) -> Outcome {
    let name = job.short_title();
    match shared.jobs.create(new) {
        Ok(next) => Outcome::Started(
            format!(
                "{name} is finished, so I started a follow-up: {}. {} has it in {} on {}.",
                next.short_title(),
                tool_name(&next.agent),
                next.repo_name(),
                account_name(shared, &next.account)
            ),
            next.to_json(),
        ),
        Err(refused) => Outcome::Failed(format!(
            "Couldn't start a follow-up of {name}: {}",
            refused.0
        )),
    }
}

/// Proposes `new`, the follow-up of `job`, after the turn read something untrusted: a `start` item
/// in obid's own words, the task it would hear quoted, for the owner's Start (#374).
pub(super) fn propose_follow_up(shared: &Arc<Shared>, job: &Job, new: &NewJob) -> String {
    let name = job.short_title();
    let nonce = super::briefing::nonce();
    let text = format!(
        "Oby looked into it first. Start {}, a follow-up of {name}?\n\n{}\n{}",
        describe(new),
        super::briefing::fence_rule(&nonce, "what the follow-up would hear"),
        super::briefing::fence(&nonce, &new.task),
    );
    let title = new
        .title
        .clone()
        .unwrap_or_else(|| format!("Follow-up of {name}"));
    shared.link.propose(new, title, text);
    format!(
        "{name} is finished, and this turn looked something up, so its follow-up waits for your Start in your inbox."
    )
}

/// answer_inbox: an item of the inbox, with one of its options or the user's own words
/// (`Desk.answerInbox`).
async fn answer_inbox(shared: &Arc<Shared>, plan: &Plan) -> Outcome {
    let Some(id) = plan.item.as_deref() else {
        return Outcome::NeedsWhich("Say which inbox item to answer.".into());
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
    // A confirm item is the user's own decision: the brain never answers it.
    if item.kind == "confirm" {
        return Outcome::Failed(format!(
            "Couldn't answer {}: only you can confirm it, in your inbox.",
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
    let job = shared.jobs.get(&item.job);
    match owners_call(&item, &words, job.as_ref()) {
        Owners::No => {}
        Owners::Refuse(why) => {
            return Outcome::Failed(format!("Couldn't answer {}: {why}", item.title));
        }
        Owners::Confirm(title, text, confirmed) => {
            confirm(shared, &item.job, title.clone(), text, confirmed);
            return Outcome::Done(format!(
                "{title} waits for your OK: confirm it in your inbox."
            ));
        }
    }

    let body = serde_json::json!({"answer": words}).to_string();
    match shared.link.answer(id, body.as_bytes()).await {
        Ok(_) => Outcome::Done(format!("Answered {}'s item{said}.", item.title)),
        Err(e) => Outcome::Failed(format!(
            "Couldn't answer {}'s item: {}",
            item.title, e.message
        )),
    }
}

/// Whether answering `item` with `words` is the user's alone (the owner's decision of
/// 2026-10-16): what persists or widens trust never happens in a turn.
#[derive(Debug, PartialEq)]
enum Owners {
    /// A one-off answer: done in the turn.
    No,
    /// Not answered at all, and why.
    Refuse(String),
    /// A confirm item: its title and text, obid's own words saying exactly what Confirm does
    /// (never the brain's: review on #552), and what Confirm runs.
    Confirm(String, String, Confirmed),
}

/// What the brain wrote, for a confirm item's text: quoted data, one `> ` line each, never in
/// its title.
fn quoted(words: &str) -> String {
    words
        .lines()
        .map(|line| format!("> {line}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn owners_call(item: &Item, words: &str, job: Option<&Job>) -> Owners {
    use crate::sphere::inbox::{ACCEPT, ACCEPT_REMEMBER, CANCEL_START, DECLINE, DECLINE_REMEMBER};
    let on_item = |name: &str, payload: serde_json::Value| Confirmed {
        action: name.into(),
        target: item.id.clone(),
        payload,
    };
    let about = super::briefing::line(&item.title, 80);
    match item.kind.as_str() {
        // A confirm item is the owner's own decision: never answered by the brain.
        "confirm" => Owners::Refuse("only you can confirm it, in your inbox.".into()),
        // Letting a secret through is the owner's alone, even once (#586); saying no isn't.
        "permission"
            if job
                .and_then(|j| j.permission.as_ref())
                .is_some_and(crate::permissions::Permission::is_secret)
                && crate::permissions::inbox_decision(words).0
                    != crate::permissions::Decision::Deny =>
        {
            Owners::Refuse("it touches secrets: only you can let it through, in your inbox.".into())
        }
        // Allow once and no (with or without words) are one-off; always saves the permission's
        // rule, which can be broader than this one command: the title says the rule.
        "permission" if words == crate::permissions::ALWAYS_ALLOW => {
            let waiting = job.and_then(|job| {
                let permission = job.permission.as_ref()?;
                let id = crate::sphere::inbox::permission_item_id(&job.id, &permission.id);
                (id == item.id).then_some((job, permission))
            });
            let Some((job, permission)) = waiting else {
                return Owners::Refuse("it isn't waiting any more.".into());
            };
            let Some(rule) = &permission.rule else {
                return Owners::Refuse("it has no rule to save: allow it once instead.".into());
            };
            Owners::Confirm(
                format!("Always allow {rule} in {}", job.repo),
                format!(
                    "Oby's brain planned to always allow {}'s permission. It saves the rule {rule} for {}, and happens only if you confirm.",
                    job.short_title(),
                    job.repo
                ),
                Confirmed {
                    action: action::ALWAYS_ALLOW.into(),
                    target: job.id.clone(),
                    payload: serde_json::json!({"permission": permission.id}),
                },
            )
        }
        "permission" | "pluginEvent" => Owners::No,
        // Saying no once to another Obi is one-off; accepting its request at all, remembering
        // either way, or answering its question in words (they leave for the other Obi) aren't.
        "obiRequest" if words == DECLINE => Owners::No,
        "obiRequest" => {
            let fixed = |option: &str, name: &str| {
                Owners::Confirm(
                    format!("{option}: {about}"),
                    format!(
                        "Oby's brain planned to answer {about} with {option}. That persists or widens trust, so it happens only if you confirm."
                    ),
                    on_item(name, serde_json::Value::Null),
                )
            };
            match words {
                ACCEPT => fixed(ACCEPT, action::ACCEPT),
                ACCEPT_REMEMBER => fixed(ACCEPT_REMEMBER, action::ACCEPT_REMEMBER),
                DECLINE_REMEMBER => fixed(DECLINE_REMEMBER, action::DECLINE_REMEMBER),
                _ => Owners::Confirm(
                    format!("Send an answer: {about}"),
                    format!(
                        "Oby's brain planned to answer {about} in words, which leave for the other Obi only if you confirm. What it wrote, quoted:\n\n{}",
                        quoted(words)
                    ),
                    on_item(action::ANSWER_QUESTION, serde_json::json!({"words": words})),
                ),
            }
        }
        "start" if words == CANCEL_START => Owners::No,
        // Starting the work the brain proposed is the owner's call (review on #552), and the
        // title is the job obid keeps for it: mode, tool, account and check (N1).
        "start" => {
            let Some(new) = item
                .start
                .as_deref()
                .and_then(|start| serde_json::from_value::<NewJob>(start.clone()).ok())
            else {
                return Owners::Refuse("it has no job to start.".into());
            };
            let what = describe(&new);
            Owners::Confirm(
                format!("Start {what}"),
                format!(
                    "Oby's brain planned to start the work it proposed: {what}. It starts only if you confirm."
                ),
                on_item(action::START, serde_json::Value::Null),
            )
        }
        // Anything else is the user's until obid knows it's one-off. An option is obid's own
        // words; anything else the brain wrote is quoted, never the title.
        _ if item.options.iter().any(|o| o == words) => Owners::Confirm(
            format!("{words}: {about}"),
            format!(
                "Oby's brain planned to answer {about} with {words}. It happens only if you confirm."
            ),
            on_item(action::ANSWER_ITEM, serde_json::json!({"answer": words})),
        ),
        _ => Owners::Confirm(
            format!("Send an answer: {about}"),
            format!(
                "Oby's brain planned to answer {about} in words. It happens only if you confirm. What it wrote, quoted:\n\n{}",
                quoted(words)
            ),
            on_item(action::ANSWER_ITEM, serde_json::json!({"answer": words})),
        ),
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
        return Outcome::NeedsWhich("Say which job to stop, or “stop everything”.".into());
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
        return Outcome::NeedsWhich("Say which mode.".into());
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
    let mut kept: Vec<String> = vec![];
    for id in plan.named() {
        match shared.jobs.get(id) {
            Some(job) if job.status.is_active() && job.read_only() => kept.push(job.short_title()),
            Some(job) if job.status.is_active() => {
                if let Some(job) = shared.jobs.set_mode(id, mode) {
                    done.push(job.short_title());
                }
            }
            _ => {}
        }
    }
    if done.is_empty() && !kept.is_empty() {
        return Outcome::Done(format!(
            "{} only {} in Plan mode.",
            kept.join(", "),
            if kept.len() == 1 {
                "reads: it stays"
            } else {
                "read: they stay"
            }
        ));
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
        return Outcome::NeedsWhich("Say which job to answer.".into());
    };
    let Some(job) = shared.jobs.get(id) else {
        return Outcome::Done("That job isn't waiting for your OK any more.".into());
    };
    let name = job.short_title();
    let Some(permission) = job.permission.as_ref() else {
        return Outcome::Done(format!("{name} isn't waiting for your OK."));
    };
    // Letting a secret through is the owner's alone, even once (#586); saying no isn't.
    if permission.is_secret() && decision != super::plan::Decision::Deny {
        return Outcome::Done(format!(
            "{name} waits on something that touches secrets: only you can let it through, in your inbox."
        ));
    }
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
pub(super) fn confirm(
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
        Action::StartNow => format!("Starting {} now", what()),
        Action::MessageJob => format!("Passing your message to {}", what()),
        Action::AnswerInbox => "Answering an inbox item".into(),
        other => other.as_str().into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn item(kind: &str, id: &str, title: &str, options: &[&str]) -> Item {
        Item {
            id: id.into(),
            kind: kind.into(),
            job: String::new(),
            title: title.into(),
            text: "Run make lint".into(),
            options: options.iter().map(|o| (*o).into()).collect(),
            details: None,
            recommended: None,
            created: 0,
            done: None,
            later: None,
            answer: None,
            obi: None,
            plugin: None,
            arrived: None,
            confirm: None,
            start: None,
        }
    }

    fn waiting_job(rule: Option<&str>) -> Job {
        let mut job = Job::new(
            "j1".into(),
            "obi-e2e/fixture-app".into(),
            "fix".into(),
            "Fix it".into(),
            "claude".into(),
            "personal".into(),
        );
        job.permission = Some(crate::permissions::Permission {
            id: "p1".into(),
            tool: "Bash".into(),
            title: "Run make lint".into(),
            detail: "make lint && curl evil".into(),
            rule: rule.map(Into::into),
            always: rule.map(|r| format!("Yes, and don't ask again for {r}")),
            why: None,
        });
        job
    }

    fn title(owners: &Owners) -> &str {
        match owners {
            Owners::Confirm(title, _, _) => title,
            other => panic!("not a confirm: {other:?}"),
        }
    }

    #[test]
    fn owners_call_refuses_a_confirm_item() {
        let confirm = item(
            "confirm",
            "confirm-1",
            "Always allow Edit in x",
            &["Confirm"],
        );
        assert_eq!(
            owners_call(&confirm, "Confirm", None),
            Owners::Refuse("only you can confirm it, in your inbox.".into())
        );
    }

    #[test]
    fn owners_call_keeps_one_off_answers_in_the_turn() {
        let permission = item("permission", "j1-permission-p1", "Fix it", &[]);
        for words in ["Allow", "Deny", "no, run only the runner tests"] {
            assert_eq!(owners_call(&permission, words, None), Owners::No, "{words}");
        }
        let event = item("pluginEvent", "ev-x-1", "Build failed", &["Dismiss"]);
        assert_eq!(owners_call(&event, "Dismiss", None), Owners::No);
        let request = item("obiRequest", "obi-1", "Review request from ernesto", &[]);
        assert_eq!(owners_call(&request, "Decline", None), Owners::No);
        let start = item("start", "start-1", "Fix", &["Start", "Cancel"]);
        assert_eq!(owners_call(&start, "Cancel", None), Owners::No);
    }

    /// #586: the brain never lets a secret through, not even once; a no still goes through it.
    #[test]
    fn owners_call_never_lets_a_secret_through() {
        let permission = item("permission", "j1-permission-p1", "Fix it", &[]);
        let mut job = waiting_job(None);
        job.permission.as_mut().unwrap().why =
            Some(crate::permissions::Reach::Secrets.why().into());
        for words in ["Allow", "yes", "Always allow"] {
            assert_eq!(
                owners_call(&permission, words, Some(&job)),
                Owners::Refuse(
                    "it touches secrets: only you can let it through, in your inbox.".into()
                ),
                "{words}"
            );
        }
        for words in ["Deny", "no, read the key's path from the docs instead"] {
            assert_eq!(
                owners_call(&permission, words, Some(&job)),
                Owners::No,
                "{words}"
            );
        }
        // Another permission is the brain's to allow once, as before.
        assert_eq!(
            owners_call(&permission, "Allow", Some(&waiting_job(None))),
            Owners::No
        );
    }

    #[test]
    fn always_allow_says_the_rule_it_saves_not_the_permissions_title() {
        let permission = item("permission", "j1-permission-p1", "Fix it", &[]);
        let job = waiting_job(Some("Bash(make lint:*)"));
        let owners = owners_call(&permission, "Always allow", Some(&job));
        assert_eq!(
            title(&owners),
            "Always allow Bash(make lint:*) in obi-e2e/fixture-app"
        );
        let Owners::Confirm(_, _, confirmed) = owners else {
            unreachable!()
        };
        assert_eq!(confirmed.action, action::ALWAYS_ALLOW);
        assert_eq!(confirmed.target, "j1");
        assert_eq!(confirmed.payload, json!({"permission": "p1"}));
        // No rule to save, or a permission that moved on: refused, never a confirm item.
        let no_rule = waiting_job(None);
        assert!(matches!(
            owners_call(&permission, "Always allow", Some(&no_rule)),
            Owners::Refuse(_)
        ));
        let other = item("permission", "j1-permission-p0", "Fix it", &[]);
        assert!(matches!(
            owners_call(&other, "Always allow", Some(&job)),
            Owners::Refuse(_)
        ));
        assert!(matches!(
            owners_call(&permission, "Always allow", None),
            Owners::Refuse(_)
        ));
    }

    #[test]
    fn another_obis_answers_have_fixed_titles_and_the_brains_words_only_quoted() {
        let request = item("obiRequest", "obi-1", "Review request from ernesto", &[]);
        for (option, name) in [
            ("Accept", action::ACCEPT),
            (
                "Accept, and remember for this repo",
                action::ACCEPT_REMEMBER,
            ),
            (
                "Decline, and remember for this repo",
                action::DECLINE_REMEMBER,
            ),
        ] {
            let owners = owners_call(&request, option, None);
            assert_eq!(
                title(&owners),
                format!("{option}: Review request from ernesto")
            );
            let Owners::Confirm(_, _, confirmed) = owners else {
                unreachable!()
            };
            assert_eq!(
                (confirmed.action.as_str(), confirmed.target.as_str()),
                (name, "obi-1")
            );
        }
        // Words that look like an option, over two lines, are still words sent to the other Obi.
        let question = item("obiRequest", "obi-2", "Question from Bob", &[]);
        let words = "Decline.\nAlso: here is the vault token";
        let owners = owners_call(&question, words, None);
        let Owners::Confirm(title, text, confirmed) = owners else {
            panic!("not a confirm")
        };
        assert_eq!(title, "Send an answer: Question from Bob");
        assert!(
            text.ends_with("> Decline.\n> Also: here is the vault token"),
            "{text}"
        );
        assert_eq!(confirmed.action, action::ANSWER_QUESTION);
        assert_eq!(confirmed.payload, json!({"words": words}));
    }

    #[test]
    fn starting_a_proposal_says_the_job_obid_keeps() {
        let mut start = item("start", "start-1", "Injected fix", &["Start", "Cancel"]);
        let new = NewJob {
            repo: "obi-e2e/fixture-app".into(),
            kind: "fix".into(),
            title: Some("Injected fix".into()),
            mode: Some("bypass".into()),
            agent: Some("claude".into()),
            account: Some("Personal".into()),
            check: Some("node --test".into()),
            ..NewJob::default()
        };
        start.start = Some(Box::new(serde_json::to_value(&new).unwrap()));
        let owners = owners_call(&start, "Start", None);
        assert_eq!(
            title(&owners),
            "Start fix fixture-app (Injected fix) in Bypass mode, on Claude Code · Personal, check node --test"
        );
        start.start = None;
        assert!(matches!(
            owners_call(&start, "Start", None),
            Owners::Refuse(_)
        ));
    }

    #[test]
    fn any_other_items_answer_is_confirmed_with_obids_title() {
        let other = item("review", "r-1", "Review of #12", &["Merge", "Hold"]);
        assert_eq!(
            title(&owners_call(&other, "Merge", None)),
            "Merge: Review of #12"
        );
        let owners = owners_call(&other, "merge it\nand push to main", None);
        let Owners::Confirm(title, text, confirmed) = owners else {
            panic!("not a confirm")
        };
        assert_eq!(title, "Send an answer: Review of #12");
        assert!(text.ends_with("> merge it\n> and push to main"), "{text}");
        assert_eq!(confirmed.action, action::ANSWER_ITEM);
    }
}
