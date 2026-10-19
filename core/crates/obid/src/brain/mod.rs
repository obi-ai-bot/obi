//! `POST /v1/plans`: one turn of the conversation with Oby (Engine/Brain.swift and
//! `Desk.plan`). The brain plans with a typed schema; obid checks every plan
//! ([`plan::Plan::problems`]), tells the brain why it refused one and lets it try again, falls
//! back to Codex and then to keyword rules (which never act on the first step), and does what the
//! plan says: a reply, a question, the jobs it starts, or an action on the work.

pub mod actions;
pub mod briefing;
pub mod find;
pub mod harness;
pub mod harness_codex;
pub mod lead;
pub mod orchestrator;
pub mod plan;
pub mod planner;
pub mod read;
pub mod recap;
pub mod research;
pub mod rules;
pub mod tools;
pub mod turn;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::process::Command;

use crate::api::{ApiError, Shared};
use crate::conversation::{Target, Turn};
use actions::{Asked, Talk};
use plan::Context;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    said: String,
    answer: Option<Answer>,
    turns: Option<Vec<InputTurn>>,
    attachments: Option<Vec<String>>,
    /// The conversation it joins; left out, the latest (#493).
    conversation: Option<String>,
    /// True: it starts a new conversation.
    new: Option<bool>,
    /// The id the app gave the user's words (a lower-case UUID): sent again with an id obid has,
    /// they're the same words, and nothing new happens.
    id: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Answer {
    question: String,
    option: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InputTurn {
    who: String,
    text: String,
}

pub async fn plan(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    let req: Request = serde_json::from_slice(&body)
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "That isn't a plan request."))?;
    let words = req.said.trim();
    if words.is_empty() || words.chars().count() > 2000 {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "said is 1 to 2,000 characters.",
        ));
    }
    let id = req.id.clone();
    if id
        .as_deref()
        .is_some_and(|id| !crate::conversation::is_id(id))
    {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "id is a lower-case UUID.",
        ));
    }
    let attachments = validate_attachments(
        &shared.config.home,
        req.attachments.as_deref().unwrap_or(&[]),
    )?;
    // Left out, a request joins the latest conversation, as it did when there was only one: the
    // apps from before #493 send none and show one thread.
    let target = match (req.conversation, req.new.unwrap_or(false)) {
        (Some(_), true) => {
            return Err(ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "Send conversation or new, not both.",
            ));
        }
        (Some(id), false) => Target::Id(id),
        (None, true) => Target::New,
        (None, false) => Target::Latest,
    };
    let turns = validate_turns(req.turns)?;
    // The owner's message: after more than 30 minutes away, the answer starts with a recap (#594).
    let now = obi_protocol::time::now();
    let back = shared.presence.seen(now);
    // A bare "never mind", "stop" or "cancel" never reaches the brain: it stops the turn under
    // way, after the action it's doing, and is answered with nothing (no job stops on a word).
    if req.answer.is_none() && turn::cancels(words) {
        // The turn under way in the conversation the words name, else in the latest one; words
        // that start a new conversation have no turn to stop.
        let underway = match &target {
            Target::Id(id) => Some(id.clone()),
            Target::Latest => shared.turns.latest_conversation(),
            Target::New => None,
        };
        if let Some(id) = &underway {
            shared.turns.stop(Some(id));
        }
        // Its answer has no words: the recap waits for the next one.
        if let Some(since) = back {
            recap::keep(shared.clone(), since, now);
        }
        let conversation = underway.or_else(|| shared.conversations.latest_id());
        return Ok((
            StatusCode::OK,
            axum::Json(
                json!({"kind": "none", "jobs": [], "drafts": [], "conversation": conversation}),
            ),
        )
            .into_response());
    }
    let said = req
        .answer
        .map(|a| {
            format!(
                "{}\n\n(Oby asked: {} The user answered: {})",
                words, a.question, a.option
            )
        })
        .unwrap_or_else(|| words.to_owned());
    let begun = shared.conversations.begin(target, said.clone(), id)?;
    // The same words sent again: obid has them (and answered, or answers, them in its turn).
    if begun.repeated {
        return Ok((
            StatusCode::OK,
            axum::Json(
                json!({"kind": "none", "jobs": [], "drafts": [], "conversation": begun.conversation, "repeated": true}),
            ),
        )
            .into_response());
    }
    let given = turns.unwrap_or(begun.before);
    let control = shared.turns.begin(&begun.turn, &begun.conversation);
    // The turn goes on by itself: a client that stops waiting can't be told from a slow one, so
    // what the plan does still happens, and is kept (docs/runner-api.md, `POST /v1/plans`).
    let turn = tokio::spawn(async move {
        let conversation = begun.conversation;
        let asked = Asked {
            said: &said,
            attachments: &attachments,
            conversation: &conversation,
            turn: &control.turn,
        };
        // The recap is written while the brain thinks; a background call is bounded and
        // tried once, and when it fails the answer is the same as without it.
        let (answered, recap) = tokio::join!(
            harness::run(&shared, &said, &given, &asked, &control),
            recap::back(&shared, back, now)
        );
        shared.turns.end(&control);
        let recap = recap.or_else(|| shared.presence.take());
        let made = shared.harness.take_made(&control.turn);
        respond(
            &shared,
            &conversation,
            answered.talk,
            answered.details,
            recap,
            made,
        )
    });
    turn.await.map_err(|_| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Oby's brain stopped before it answered.",
        )
    })?
}

/// Which conversation's turn Stop or cancel is for: `{"conversation": "<id>"}`, or, with no
/// body (the apps from before #493), the conversation of the latest turn under way.
fn underway(shared: &Shared, body: &Bytes) -> Result<Option<String>, ApiError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Which {
        conversation: Option<String>,
    }
    let named = if body.iter().all(u8::is_ascii_whitespace) {
        None
    } else {
        serde_json::from_slice::<Which>(body)
            .map_err(|_| {
                ApiError::new(
                    StatusCode::BAD_REQUEST,
                    "The body is {\"conversation\": \"<id>\"}, or nothing.",
                )
            })?
            .conversation
    };
    Ok(named.or_else(|| shared.turns.latest_conversation()))
}

/// `POST /v1/conversation/stop`: the turn under way in one conversation ends after the action
/// it's doing, and its `POST /v1/plans` answers with what it did. Turns in other conversations
/// go on.
pub async fn stop(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    if let Some(id) = underway(&shared, &body)? {
        shared.turns.stop(Some(&id));
    }
    Ok((StatusCode::OK, axum::Json(json!({"stopped": true}))).into_response())
}

/// `POST /v1/plans/cancel`: the turn under way in one conversation is dropped: what its plan
/// would do doesn't happen, and its answer is `none`. What it did already stays done.
pub async fn cancel(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    if let Some(id) = underway(&shared, &body)? {
        shared.turns.cancel(Some(&id));
    }
    Ok((StatusCode::OK, axum::Json(json!({"cancelled": true}))).into_response())
}

/// The answer, as `POST /v1/plans` sends it, once Oby's words joined the conversation.
fn respond(
    shared: &Shared,
    conversation: &str,
    talk: Talk,
    details: Option<String>,
    recap: Option<String>,
    artifacts: Vec<Value>,
) -> Result<Response, ApiError> {
    // The recap is Oby's first line, never a turn the user wrote; an answer with no words keeps
    // it for the next one.
    let recap = match (&talk, recap) {
        (Talk::None, Some(recap)) => {
            shared.presence.hold(recap);
            None
        }
        (_, recap) => recap,
    };
    let talk = recap::lead(talk, recap.as_deref());
    let mut body = match &talk {
        Talk::None => json!({"kind": "none", "jobs": [], "drafts": []}),
        Talk::Reply { text, jobs } => {
            json!({"kind": "reply", "text": text, "jobs": jobs, "drafts": []})
        }
        Talk::Question { said, question } => json!({
            "kind": "question", "said": said, "jobs": [], "drafts": [],
            "question": {"text": question.text, "options": question.options,
                         "details": question.details, "recommended": question.recommended,
                         "plan": question.plan},
        }),
    };
    if let Some(details) =
        details.filter(|_| matches!(talk, Talk::Reply { .. } | Talk::Question { .. }))
    {
        body["details"] = json!(details);
    }
    let text = match &talk {
        Talk::None => None,
        Talk::Reply { text, .. } => Some(text.clone()),
        // A question keeps only its own words in the conversation: the recap goes before them.
        Talk::Question { question, .. } => Some(match &recap {
            Some(recap) => format!("{recap}\n\n{}", question.text),
            None => question.text.clone(),
        }),
    };
    if let Some(text) = text {
        let jobs = match &talk {
            Talk::Reply { jobs, .. } => jobs
                .iter()
                .filter_map(|j| j["id"].as_str().map(str::to_owned))
                .collect(),
            _ => vec![],
        };
        match shared
            .conversations
            .append_made(conversation, text, jobs, artifacts.clone())
        {
            Ok(_) => {}
            // Deleted while the brain thought: the answer still goes to the app that asked.
            Err(crate::conversation::Error::NoConversation) => {
                tracing::info!("conversation {conversation} was deleted during its turn");
            }
            Err(e) => return Err(e.into()),
        }
    }
    if let Some(recap) = recap {
        body["recap"] = json!(recap);
    }
    if !artifacts.is_empty() {
        body["artifacts"] = json!(artifacts);
    }
    body["conversation"] = json!(conversation);
    Ok((StatusCode::OK, axum::Json(body)).into_response())
}

/// A `thinking` event (#592): one call to the brain, as it begins and as its plan comes (`done`),
/// or doesn't (`failed`: the turn was cancelled, stopped or out of time). `index` is the step the
/// call plans, as the `step` events count them.
pub(super) fn thinking(
    shared: &Shared,
    control: &turn::Control,
    index: usize,
    text: &str,
    state: turn::State,
) {
    shared.events.send(
        "thinking",
        json!({"turn": control.turn, "conversation": control.conversation, "index": index,
               "text": text, "state": state.as_str(),
               "at": obi_protocol::time::format(obi_protocol::time::now())}),
    );
}

/// A `reply` event (#592): what Oby says, as soon as the plan that says it is checked and before
/// the jobs it starts are made. Never for a turn that's cancelled or stopped, nor for no words.
/// Whether it went out.
pub(super) fn acknowledge(shared: &Shared, control: &turn::Control, text: &str) -> bool {
    if text.trim().is_empty() || !control.live() {
        return false;
    }
    shared.events.send(
        "reply",
        json!({"turn": control.turn, "conversation": control.conversation, "text": text,
               "at": obi_protocol::time::format(obi_protocol::time::now())}),
    );
    true
}

/// What the brain may choose from (`Desk.brainContext`): the accounts, the repositories, the ids
/// each action may name, and the briefing with `turns` as the conversation so far, `conversation`'s.
pub(super) fn context(shared: &Shared, conversation: &str, turns: &[Turn], nonce: &str) -> Context {
    let config = &shared.config;
    let now = obi_protocol::time::now();
    let tools = tool_accounts(config);
    let mut accounts: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut every = vec!["auto".to_owned()];
    let mut move_accounts: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut told = vec![];
    for (tool, list) in &tools {
        let names: Vec<String> = list.iter().map(|a| a.name.clone()).collect();
        every.extend(names.iter().cloned());
        accounts.insert(
            (*tool).into(),
            std::iter::once("auto".to_owned())
                .chain(names.clone())
                .collect(),
        );
        move_accounts.insert((*tool).into(), names);
        told.extend(list.iter().map(|a| briefing::Account {
            id: a.id.clone(),
            agent: (*tool).into(),
            name: a.name.clone(),
            running: shared.jobs.running_on(&a.id),
        }));
    }
    accounts.insert("auto".into(), every);
    // What a job may move to: each tool's models (Engine/Move.swift, `Moves.models`).
    let mut models: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (tool, _) in &tools {
        let ids: &[&str] = match *tool {
            "claude" => &[
                "claude-fable-5-1",
                "claude-opus-5-5",
                "claude-sonnet-5-5",
                "claude-haiku-5-5",
            ],
            "codex" => &["gpt-6.1-sol", "gpt-6-astra"],
            _ => &[],
        };
        models.insert(
            (*tool).into(),
            ids.iter().map(|m| (*m).to_owned()).collect(),
        );
    }
    let briefing = briefing::Briefing {
        turns: turns.to_vec(),
        conversation: conversation.to_owned(),
        place: shared.host.clone(),
        jobs: shared.jobs.list(usize::MAX),
        inbox: shared.link.waiting_items(now),
        accounts: told,
        repos: config.repos.iter().map(|r| r.repo.clone()).collect(),
        max_running: shared.jobs.max_running(),
        default_mode: shared.jobs.default_mode().as_str(),
        failures: briefing::week(
            crate::failures::list(&config.home, crate::failures::MOST),
            now,
        ),
        now,
        nonce: nonce.to_owned(),
    };
    Context {
        accounts,
        repos: config.repos.iter().map(|r| r.repo.clone()).collect(),
        briefing: Some(briefing.text()),
        quoted: briefing.quoted(),
        jobs: briefing.stoppable(),
        movable: briefing.jobs().iter().map(|j| j.id.clone()).collect(),
        models,
        move_accounts,
        permissions: briefing.permissions(),
        // A confirm item waits for the user's own answer: the brain may never answer it.
        inbox: briefing
            .inbox
            .iter()
            .filter(|i| i.kind != "confirm")
            .map(|i| i.id.clone())
            .collect(),
        ended: briefing
            .jobs()
            .into_iter()
            .filter(|job| left_unfinished(job, now))
            .map(|job| plan::Ended {
                id: job.id.clone(),
                repo: job.repo.clone(),
                issue: job.issue.map(|n| n as i64),
                pr: job.pr.map(|n| n as i64),
            })
            .collect(),
        ..Context::default()
    }
}

/// The own instructions of the repositories the turn's words or its briefing name, the words
/// first (#543): quoted in the brain's file, never in its prompt.
pub(super) async fn own(
    shared: &Shared,
    said: &str,
    turns: &[Turn],
    nonce: &str,
) -> Vec<briefing::Own> {
    // Only the repositories it names count: whose conversation doesn't.
    let briefing = context(shared, "", turns, nonce)
        .briefing
        .unwrap_or_default();
    briefing::own_instructions(
        &shared.config.home,
        &shared.config.repos,
        &[said, &briefing],
    )
    .await
}

/// A job that failed, was stopped or ran out of rounds in the last two days, and wasn't let go:
/// its agent is the one to carry its work on (#541).
fn left_unfinished(job: &crate::job::Job, now: i64) -> bool {
    use crate::job::Status;
    let ended = matches!(
        job.status,
        Status::Failed | Status::Stopped | Status::Interrupted
    ) || (job.status == Status::Done && job.limit.is_some());
    ended
        && job.obi.is_none()
        && job.dismissed.is_none()
        && job
            .finished
            .is_some_and(|finished| now - finished < briefing::RECENT)
}

/// Each configured tool's accounts, as jobs are routed to them.
fn tool_accounts(
    config: &crate::config::Config,
) -> Vec<(&'static str, Vec<crate::config::Account>)> {
    let agents = config.agents.get();
    let mut out = vec![];
    if let Some(claude) = &agents.claude {
        out.push(("claude", crate::jobs::claude_accounts(claude)));
    }
    if let Some(codex) = &agents.codex {
        out.push((
            "codex",
            if codex.accounts.is_empty() {
                vec![crate::config::Account {
                    id: "codex".into(),
                    name: "Codex".into(),
                    config_dir: None,
                    payer: None,
                }]
            } else {
                codex.accounts.clone()
            },
        ));
    }
    if let Some(cursor) = &agents.cursor {
        out.push(("cursor", cursor.accounts.clone()));
    }
    out
}

/// The runner reads issue text with its own `gh` login. The body is data: this only extracts and
/// validates the issue's declared `Files:` paths; it is never added to the planner prompt.
async fn issue_files(repo: &str, issue: u64) -> Option<Vec<String>> {
    let gh = crate::process::resolve_bin("gh")?;
    let output = tokio::time::timeout(
        Duration::from_secs(10),
        Command::new(gh)
            .args([
                "issue",
                "view",
                &issue.to_string(),
                "--repo",
                repo,
                "--json",
                "title,body",
            ])
            .env("GH_PAGER", "cat")
            .env("GH_PROMPT_DISABLED", "1")
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    if !output.status.success() {
        return None;
    }
    let issue: Value = serde_json::from_slice(&output.stdout).ok()?;
    let title = issue["title"].as_str().unwrap_or_default();
    let body = issue["body"].as_str().unwrap_or_default();
    let line = body.lines().rev().find(|line| {
        let line = line.trim_start_matches([' ', '\t', '>', '*', '_']);
        line.get(..5)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("files"))
            && line[5..].trim_start_matches(['*', '_']).starts_with(':')
    });
    let mut paths = line.map(parse_issue_file_list).unwrap_or_default();
    if paths.is_empty() {
        paths = named_paths(&format!("{title}\n{body}"));
    }
    crate::jobs::claimed_files(&paths)
        .ok()
        .filter(|files| !files.is_empty())
}

fn parse_issue_file_list(line: &str) -> Vec<String> {
    let Some((_, rest)) = line.split_once(':') else {
        return Vec::new();
    };
    let mut listed = Vec::new();
    let mut rest = rest;
    while let Some(start) = rest.find('`') {
        rest = &rest[start + 1..];
        let Some(end) = rest.find('`') else { break };
        listed.push(rest[..end].to_owned());
        rest = &rest[end + 1..];
    }
    if listed.is_empty() {
        listed = rest
            .split([',', ';'])
            .flat_map(|part| part.split(" and "))
            .map(str::trim)
            .map(str::to_owned)
            .collect();
    }
    listed
}

fn named_paths(text: &str) -> Vec<String> {
    let mut found = Vec::new();
    for line in text.lines() {
        let words = line.split(|c: char| c.is_whitespace() || ",;()[]<>\"'|".contains(c));
        for word in words {
            let candidate = word
                .trim_matches('`')
                .trim_matches(|c: char| ".:!?*_".contains(c));
            if candidate.contains('/')
                && !candidate.contains("//")
                && !candidate.starts_with('/')
                && !candidate.split('/').any(|part| part == "..")
                && candidate.chars().any(char::is_alphabetic)
            {
                found.push(candidate.to_owned());
            }
        }
    }
    found
}
fn validate_turns(input: Option<Vec<InputTurn>>) -> Result<Option<Vec<Turn>>, ApiError> {
    let Some(turns) = input else { return Ok(None) };
    if turns.len() > 50 {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "turns holds at most 50.",
        ));
    }
    let mut out = vec![];
    for t in turns {
        if !["user", "oby"].contains(&t.who.as_str())
            || t.text.trim().is_empty()
            || t.text.chars().count() > 2000
        {
            return Err(ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "Each turn needs who user or oby and 1 to 2,000 characters of text.",
            ));
        }
        out.push(Turn {
            id: String::new(),
            who: t.who,
            text: t.text,
            at: String::new(),
            jobs: vec![],
            conversation: String::new(),
            ended: false,
            artifacts: vec![],
        });
    }
    Ok(Some(out))
}
fn validate_attachments(home: &Path, paths: &[String]) -> Result<Vec<String>, ApiError> {
    let path = home.join("attachments");
    let root = path.canonicalize().unwrap_or(path);
    let mut out = vec![];
    for p in paths {
        let file = PathBuf::from(p);
        let resolved = file.canonicalize().ok();
        if resolved
            .as_ref()
            .is_none_or(|f| !f.starts_with(&root) || f == &root || !f.is_file())
        {
            let name = file
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("attachment");
            return Err(ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!(
                    "{name} isn't one of the files the Oby app attached, so it isn't handed to the agent."
                ),
            ));
        }
        out.push(p.clone());
    }
    Ok(out)
}
