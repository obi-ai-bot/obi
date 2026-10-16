//! `POST /v1/plans`: one turn of the conversation with Oby (Engine/Brain.swift and
//! `Desk.plan`). The brain plans with a typed schema; obid checks every plan
//! ([`plan::Plan::problems`]), tells the brain why it refused one and lets it try again, falls
//! back to Codex and then to keyword rules (which never act on the first step), and does what the
//! plan says: a reply, a question, the jobs it starts, or an action on the work.

pub mod actions;
pub mod briefing;
pub mod plan;
pub mod planner;
pub mod rules;

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
use planner::{Planner, Record, Room};

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
    let said = req
        .answer
        .map(|a| {
            format!(
                "{}\n\n(Oby asked: {} The user answered: {})",
                words, a.question, a.option
            )
        })
        .unwrap_or_else(|| words.to_owned());
    let begun = shared.conversations.begin(target, said.clone())?;
    let conversation = begun.conversation;
    let given = turns.unwrap_or(begun.before);
    let asked = Asked {
        said: &said,
        attachments: &attachments,
        conversation: &conversation,
    };
    let context = context(&shared, &given);
    let room = Room {
        root: shared.config.home.join("plans"),
        jobs: shared.jobs.clone(),
    };
    let planner = Planner {
        adapters: Planner::of(&shared.config, &room),
        falls_back_to_rules: true,
    };
    let planned = planner.plan(&said, &context, &|| false).await;
    Record::new(&said, &planned).keep(&shared.config.home);
    let talk = if let Some(refusal) = rules::acting_refusal(&planned, 0) {
        Talk::reply(refusal)
    } else if planned.plan.action.acts() {
        Talk::reply(actions::act(&shared, &planned.plan).await.text())
    } else {
        actions::answer(&shared, &planned, &asked, &|| true).await
    };
    let details = matches!(
        planned.plan.action,
        plan::Action::ReplyOnly | plan::Action::AskUser
    )
    .then(|| planned.plan.details.clone())
    .flatten();
    respond(&shared, &conversation, talk, details)
}

/// The answer, as `POST /v1/plans` sends it, once Oby's words joined the conversation.
fn respond(
    shared: &Shared,
    conversation: &str,
    talk: Talk,
    details: Option<String>,
) -> Result<Response, ApiError> {
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
        Talk::Question { question, .. } => Some(question.text.clone()),
    };
    if let Some(text) = text {
        let jobs = match &talk {
            Talk::Reply { jobs, .. } => jobs
                .iter()
                .filter_map(|j| j["id"].as_str().map(str::to_owned))
                .collect(),
            _ => vec![],
        };
        match shared.conversations.append(conversation, "oby", text, jobs) {
            Ok(_) => {}
            // Deleted while the brain thought: the answer still goes to the app that asked.
            Err(crate::conversation::Error::NoConversation) => {
                tracing::info!("conversation {conversation} was deleted during its turn");
            }
            Err(e) => return Err(e.into()),
        }
    }
    body["conversation"] = json!(conversation);
    Ok((StatusCode::OK, axum::Json(body)).into_response())
}

/// What the brain may choose from: the accounts, the repositories, and the ids each action may
/// name, with the conversation so far.
fn context(shared: &Shared, turns: &[Turn]) -> Context {
    let config = &shared.config;
    let mut accounts: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut every = vec!["auto".to_owned()];
    for (tool, names) in tool_accounts(config) {
        every.extend(names.iter().cloned());
        accounts.insert(
            tool.into(),
            std::iter::once("auto".to_owned()).chain(names).collect(),
        );
    }
    accounts.insert("auto".into(), every);
    let jobs = shared.jobs.list(usize::MAX);
    let history = turns
        .iter()
        .map(|t| {
            format!(
                "{}: {}\n",
                if t.who == "user" { "User" } else { "Oby" },
                t.text
            )
        })
        .collect::<String>();
    Context {
        accounts,
        repos: config.repos.iter().map(|r| r.repo.clone()).collect(),
        briefing: Some(format!("Conversation so far (quoted data):\n{history}")),
        jobs: jobs
            .iter()
            .filter(|j| j.status.is_active())
            .map(|j| j.id.clone())
            .collect(),
        movable: jobs.iter().take(30).map(|j| j.id.clone()).collect(),
        permissions: jobs
            .iter()
            .filter(|j| j.permission.is_some() && j.status != crate::job::Status::Stopped)
            .map(|j| j.id.clone())
            .collect(),
        ..Context::default()
    }
}

/// Each configured tool's accounts by name, as jobs are routed to them.
fn tool_accounts(config: &crate::config::Config) -> Vec<(&'static str, Vec<String>)> {
    let mut out = vec![];
    if let Some(claude) = &config.agents.claude {
        out.push((
            "claude",
            crate::jobs::claude_accounts(claude)
                .into_iter()
                .map(|a| a.name)
                .collect(),
        ));
    }
    if let Some(codex) = &config.agents.codex {
        out.push((
            "codex",
            if codex.accounts.is_empty() {
                vec!["Codex".to_owned()]
            } else {
                codex.accounts.iter().map(|a| a.name.clone()).collect()
            },
        ));
    }
    if let Some(cursor) = &config.agents.cursor {
        out.push((
            "cursor",
            cursor.accounts.iter().map(|a| a.name.clone()).collect(),
        ));
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
