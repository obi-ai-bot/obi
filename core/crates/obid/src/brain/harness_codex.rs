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

/// The features a conversation's Codex runs without (codex-cli 0.162.1, `codex features list`),
/// each set off and required off before every run ([`features_off`]). No shell (`shell_tool`):
/// under `untrusted` Codex runs the commands it deems safe reads (`cat`, `ls`, `grep`) without
/// asking, and one could read its login in `CODEX_HOME`; `unified_exec` stays on whatever it's set
/// to, and is only how the shell runs. No `shell_snapshot` (it sources the shell's start-up files
/// in its `HOME` at every thread start), hooks, helpers (`multi_agent`), browser (an outside one
/// too) or computer use, image viewing or generation, skill or workspace installs, a daemon or worktrees. No ChatGPT apps (`apps`:
/// their GitHub tools are a code-host login) and no plug-ins. Its code mode stays
/// (`code_mode_host` off, Codex offers no MCP tool at all): `exec`'s JavaScript has no file,
/// process or network access. Codex takes keys it doesn't know without a word, so obid checks, and
/// ends a turn in which something runs anyway ([`crate::codex::Options::no_commands`]).
const OFF: &[&str] = &[
    "shell_tool",
    "shell_snapshot",
    "apps",
    "plugins",
    "multi_agent",
    "hooks",
    "browser_use",
    "browser_use_external",
    "browser_use_full_cdp_access",
    "computer_use",
    "in_app_browser",
    "in_app_local_automation",
    "view_image",
    "image_generation",
    "skill_mcp_dependency_install",
    "workspace_dependencies",
    "daemon_auto_start",
    "worktrees",
];

/// Its other settings: the turn's token never reaches a command's environment.
const SETTINGS: &[&str] = &[
    r#"shell_environment_policy.exclude=["OBY_MCP_TOKEN"]"#,
    // Its own default is a minute: a shell command, or one waiting for the owner, takes longer.
    "mcp_servers.oby.tool_timeout_sec=3600",
];

/// The `app-server` to run for one attempt of the turn, and what its thread is started with:
/// `resume`'s thread when there is one, the conversation's orientation, the configured model;
/// `web` false for a turn nobody watches.
/// Refuses, saying why, a Codex that keeps a feature of [`OFF`] on and a login copy near its end
/// ([`crate::jobs::codex_copy_ready`]).
pub(super) async fn launch(
    shared: &Shared,
    account: &crate::config::Account,
    place: &Place,
    url: &str,
    token: &str,
    resume: &Option<String>,
    web: bool,
) -> Result<(Launch, Option<crate::codex::Options>), String> {
    // Oby's server as a job's broker is given ([`crate::codex::argv`]: its `-c` settings).
    let argv = crate::codex::argv(Default::default(), Some((url, token)), None);
    let mut flags: Vec<OsString> = argv[1..argv.len() - 1].to_vec();
    for feature in OFF {
        flags.extend(["-c".into(), format!("features.{feature}=false").into()]);
    }
    for setting in SETTINGS {
        flags.extend(["-c".into(), (*setting).into()]);
    }
    // Web search is on, but for a turn nobody watches (super::supervisor).
    let search = if web { "live" } else { "disabled" };
    flags.extend(["-c".into(), format!(r#"web_search="{search}""#).into()]);
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
    features_off(&launch).await?;
    launch.env.push(("OBY_MCP_TOKEN".into(), token.into()));
    let model = &shared.config.conversation.model;
    let options = crate::codex::Options {
        resume: resume.clone(),
        model: (!model.is_empty()).then(|| model.clone()),
        plan: false,
        instructions: Some(orientation(shared)),
        no_commands: true,
        usage: false,
        priced: None,
    };
    Ok((launch, Some(options)))
}

/// Whether Codex says every feature of [`OFF`] is off: `features list` run as the real run is,
/// in the same box, environment, `CODEX_HOME` and folder (`launch`, its `app-server` swapped for
/// `features list`), so both see the same settings, managed ones included.
async fn features_off(launch: &Launch) -> Result<(), String> {
    let mut argv = launch.argv.clone();
    if argv.last().map(|a| a.as_os_str()) != Some("app-server".as_ref()) {
        return Err(
            "obid couldn't make Codex's features list, so a conversation doesn't run on it".into(),
        );
    }
    argv.pop();
    argv.extend(["features".into(), "list".into()]);
    let listed = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        tokio::process::Command::new(&argv[0])
            .args(&argv[1..])
            .env_clear()
            .envs(launch.env.iter().map(|(k, v)| (k, v)))
            .current_dir(&launch.cwd)
            // As the run's: a pipe (closed at once), never /dev/null, which the box doesn't open.
            .stdin(std::process::Stdio::piped())
            .kill_on_drop(true)
            .output(),
    )
    .await;
    // Its status says nothing: the box's first process ends everything in it (`kill -1` on
    // macOS) once Codex exits. What it printed does, and every feature must read false in it.
    let out = match listed {
        Ok(Ok(out)) => {
            if !out.stderr.is_empty() {
                tracing::info!(
                    "Codex's features list said on stderr: {}",
                    crate::secrets::known().redact(String::from_utf8_lossy(&out.stderr).trim())
                );
            }
            String::from_utf8_lossy(&out.stdout).into_owned()
        }
        _ => {
            return Err(
                "Codex's features list couldn't be read, so a conversation doesn't run on it"
                    .into(),
            );
        }
    };
    for name in OFF {
        match feature(&out, name) {
            Some(false) => {}
            Some(true) => {
                return Err(format!(
                    "Codex's features list says {name} is on whatever obid sets, so a conversation doesn't run on it"
                ));
            }
            None => {
                return Err(format!(
                    "Codex's features list doesn't name {name}, so a conversation doesn't run on it"
                ));
            }
        }
    }
    Ok(())
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
