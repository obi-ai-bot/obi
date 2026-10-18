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

/// What a conversation's Codex runs with besides Oby's server (codex-cli 0.162.1, `codex features
/// list`). No shell (`shell_tool`): under `untrusted` Codex runs the commands it deems safe reads
/// (`cat`, `ls`, `grep`) without asking, and one could read its login in `CODEX_HOME`. With it off
/// Codex has no tool that runs a command (`unified_exec` stays on whatever it's set to, and is
/// only how the shell runs). Codex takes keys it doesn't know without a word, so obid also checks
/// `features list` before every run ([`shell_off`]) and ends a turn in which a command runs anyway
/// ([`crate::codex::Options::no_commands`]). Its code mode stays (`code_mode_host`: off, Codex
/// offers no MCP tool at all): `exec`'s JavaScript has no file, process or network access. No
/// ChatGPT apps (`apps`: their GitHub tools are a code-host login) and no plug-ins. The turn's
/// token never reaches a command's environment. Web search is on.
const SETTINGS: &[&str] = &[
    "features.shell_tool=false",
    "features.apps=false",
    "features.plugins=false",
    r#"shell_environment_policy.exclude=["OBY_MCP_TOKEN"]"#,
    r#"web_search="live""#,
];

/// The `app-server` to run for one attempt of the turn, and what its thread is started with:
/// `resume`'s thread when there is one, the conversation's orientation, the configured model.
/// Refuses, saying why, a Codex whose shell stays on and a login that ends within the turn.
pub(super) async fn launch(
    shared: &Shared,
    account: &crate::config::Account,
    place: &Place,
    url: &str,
    token: &str,
    resume: &Option<String>,
) -> Result<(Launch, Option<crate::codex::Options>), String> {
    // Oby's server as a job's broker is given ([`crate::codex::argv`]: its `-c` settings).
    let argv = crate::codex::argv(Default::default(), Some((url, token)));
    let mut flags: Vec<OsString> = argv[1..argv.len() - 1].to_vec();
    for setting in SETTINGS {
        flags.extend(["-c".into(), (*setting).into()]);
    }
    let bin = shared
        .jobs
        .agent_bin(Tool::Codex)
        .ok_or("obid can't find Codex's binary.")?;
    shell_off(&bin, &flags, place).await?;
    // Whatever repeats the turn's token (a tool's answer, the agent) is redacted.
    crate::secrets::known().learn(
        &format!("conversation {} MCP token", place.folder.display()),
        token,
    );
    let mut launch = shared.jobs.conversation_launch(
        Tool::Codex,
        account,
        &place.room,
        &place.temp,
        // Its own CODEX_HOME, with a copy of the account's login only, never its refresh token.
        &place.config,
        vec![place.repos.clone()],
        flags,
        place.folder.join("agent.log"),
    )?;
    // The copy can't be refreshed: it must outlast the turn.
    let login = std::fs::read(place.config.join("auth.json")).unwrap_or_default();
    let turn_ends = now() + shared.config.conversation.budget.as_secs() + 5 * 60;
    if ends(&login).is_some_and(|ends| ends <= turn_ends) {
        return Err(format!(
            "Codex's login for {} ends within this turn, and obid doesn't refresh a conversation's copy: run codex on that account to refresh it",
            account.name
        ));
    }
    launch.env.push(("OBY_MCP_TOKEN".into(), token.into()));
    let model = &shared.config.conversation.model;
    let options = crate::codex::Options {
        resume: resume.clone(),
        model: (!model.is_empty()).then(|| model.clone()),
        plan: false,
        instructions: Some(orientation(shared)),
        no_commands: true,
    };
    Ok((launch, Some(options)))
}

/// Whether Codex, run with `flags`, says its shell is off (`codex <flags> features list`), with
/// the conversation's own `CODEX_HOME` and nothing of obid's environment that matters.
async fn shell_off(bin: &std::path::Path, flags: &[OsString], place: &Place) -> Result<(), String> {
    let listed = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        tokio::process::Command::new(bin)
            .args(flags)
            .args(["features", "list"])
            .env_clear()
            .env("PATH", crate::process::tools_path())
            .env("HOME", &place.temp)
            .env("CODEX_HOME", &place.config)
            .current_dir(&place.room)
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await;
    let out = match listed {
        Ok(Ok(out)) if out.status.success() => String::from_utf8_lossy(&out.stdout).into_owned(),
        _ => {
            return Err(
                "Codex's features list couldn't be read, so a conversation doesn't run on it"
                    .into(),
            );
        }
    };
    match feature(&out, "shell_tool") {
        Some(false) => Ok(()),
        Some(true) => Err("Codex's shell couldn't be turned off (its features list says shell_tool is on), so a conversation doesn't run on it".into()),
        None => Err("Codex's features list doesn't name shell_tool, so a conversation doesn't run on it".into()),
    }
}

/// A feature's effective state in `codex features list`'s table (`name  stage  true|false`).
fn feature(listed: &str, name: &str) -> Option<bool> {
    listed.lines().find_map(|line| {
        let words: Vec<&str> = line.split_whitespace().collect();
        (words.first() == Some(&name))
            .then(|| words.last().and_then(|w| w.parse().ok()))
            .flatten()
    })
}

/// When the access token in Codex's `auth.json` ends, in seconds since 1970, if it says (a JWT's
/// `exp`).
fn ends(login: &[u8]) -> Option<u64> {
    use base64::Engine;
    let login: serde_json::Value = serde_json::from_slice(login).ok()?;
    let payload = login["tokens"]["access_token"]
        .as_str()?
        .split('.')
        .nth(1)?;
    let claims = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    serde_json::from_slice::<serde_json::Value>(&claims).ok()?["exp"].as_u64()
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_features_list_says_whether_the_shell_is_off() {
        let listed = "apps                                     stable             false\n\
                      shell_tool                               stable             false\n\
                      shell_tool_v2                            under development  true\n\
                      unified_exec                             stable             true\n";
        assert_eq!(feature(listed, "shell_tool"), Some(false));
        assert_eq!(feature(listed, "unified_exec"), Some(true));
        assert_eq!(feature(listed, "nowhere"), None);
    }
}
