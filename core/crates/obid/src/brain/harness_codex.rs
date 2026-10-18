//! Codex as a conversation's agent (docs/conversation-harness.md, step 4; docs/runner-api.md,
//! "obid only: the conversation harness"), with `"conversation": {"agent": "codex"}`. The turn runs
//! as the Claude Code session does ([`super::harness`]: the same room, sandbox, retries, events,
//! scrubbing and rule for every approval), on `codex app-server` instead: one thread per
//! conversation, kept in `session.json` and picked up with `thread/resume`, its own sandbox off
//! inside obid's as a job's (`danger-full-access`, every approval obid's: [`crate::codex`]), its
//! `CODEX_HOME` the conversation's own (`config`, with a copy of the login and nothing else). Oby's
//! MCP server comes in its `-c` settings, streamable HTTP with the turn's token in
//! `OBY_MCP_TOKEN`, never an argument.

use std::ffi::OsString;

use super::harness::{Place, orientation};
use crate::agent::{Launch, Tool};
use crate::api::Shared;

/// The `app-server` to run for one attempt of the turn, and what its thread is started with:
/// `resume`'s thread when there is one, the conversation's orientation, the configured model.
pub(super) fn launch(
    shared: &Shared,
    account: &crate::config::Account,
    place: &Place,
    url: &str,
    token: &str,
    resume: &Option<String>,
) -> Result<(Launch, Option<crate::codex::Options>), String> {
    // Oby's server as a job's broker is given ([`crate::codex::argv`]: its `-c` settings), and
    // web search, which is part of talking.
    let argv = crate::codex::argv(Default::default(), Some((url, token)));
    let mut flags: Vec<OsString> = argv[1..argv.len() - 1].to_vec();
    flags.extend(["-c".into(), "web_search=\"live\"".into()]);
    let mut launch = shared.jobs.conversation_launch(
        Tool::Codex,
        account,
        &place.room,
        &place.temp,
        // Its own CODEX_HOME, with a copy of the account's login only.
        &place.config,
        vec![place.repos.clone()],
        flags,
        place.folder.join("agent.log"),
    )?;
    launch.env.push(("OBY_MCP_TOKEN".into(), token.into()));
    let model = &shared.config.conversation.model;
    let options = crate::codex::Options {
        resume: resume.clone(),
        model: (!model.is_empty()).then(|| model.clone()),
        plan: false,
        instructions: Some(orientation(shared)),
    };
    Ok((launch, Some(options)))
}
