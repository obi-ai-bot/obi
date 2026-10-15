//! What obid answers an agent's permission prompts (Engine/Jobs.swift, `Policy`): fixed denials
//! first, in every mode; then the job's own rule. A review another Obi asked for may only read.

use std::path::{Component, Path, PathBuf};

use serde_json::Value;

use crate::agent::Answer;

/// The tools a review another Obi asked for may use: it reads the change and reports. No shell,
/// no edit, no web: what it was sent is data, and its answer goes back through the publish gate.
pub const REVIEW_TOOLS: [&str; 5] = ["Read", "Grep", "Glob", "LS", "TodoWrite"];

/// Whether `command` publishes: a push, a remote changed, the GitHub CLI posting or calling the API.
fn publishes(command: &str) -> bool {
    let words: Vec<&str> = command.split_whitespace().collect();
    let lower = command.to_ascii_lowercase();
    if lower.contains("pushurl") {
        return true;
    }
    for (i, word) in words.iter().enumerate() {
        let base = word.rsplit('/').next().unwrap_or(word);
        if base == "git" {
            // Skip git's own options (`-C dir`, `-c k=v`, `--no-pager`), then look at the command.
            let mut j = i + 1;
            while j < words.len() && words[j].starts_with('-') {
                j += if matches!(words[j], "-C" | "-c") {
                    2
                } else {
                    1
                };
            }
            match (words.get(j), words.get(j + 1)) {
                (Some(&"push"), _) => return true,
                (Some(&"remote"), Some(&("set-url" | "add"))) => return true,
                _ => {}
            }
        }
        if base == "gh" {
            match (words.get(i + 1), words.get(i + 2)) {
                (
                    Some(&"pr"),
                    Some(
                        &("create" | "merge" | "review" | "comment" | "close" | "edit" | "ready"
                        | "reopen"),
                    ),
                ) => return true,
                (
                    Some(&"issue"),
                    Some(&("create" | "comment" | "close" | "edit" | "reopen" | "delete")),
                ) => return true,
                (
                    Some(&"repo"),
                    Some(&("create" | "delete" | "edit" | "fork" | "rename" | "archive")),
                ) => return true,
                (Some(&("release" | "api" | "auth")), _) => return true,
                _ => {}
            }
        }
    }
    false
}

/// `path` with `.` and `..` taken out, without touching the disk.
fn normalized(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// Why a tool call is refused whatever the job, or `None`. `mcp` is the job's permission rules
/// for MCP tools: `mcp__<plugin id>__<tool>`, one per tool an enabled `agent-mcp` plug-in allows
/// (`crate::plugins::rules`). Every other MCP tool is refused (Engine/Jobs.swift's
/// `Policy.tetrixTools`, made per plug-in: docs/ARCHITECTURE.md 5.1).
pub fn fixed_denial(tool: &str, input: &Value, worktree: &Path, mcp: &[String]) -> Option<String> {
    if tool.starts_with("mcp__") || tool == "mcp" {
        return (!mcp.iter().any(|rule| rule == tool)).then(|| format!(
            "obid's agents use only the MCP tools of the plug-ins the owner enabled, and only the ones each allows. Say in your summary what you'd have done with {tool}."
        ));
    }
    let background = match tool {
        "Bash" => input.get("run_in_background").and_then(Value::as_bool) == Some(true),
        "Agent" | "Task" => {
            input.get("run_in_background").and_then(Value::as_bool) != Some(false)
                || input.get("isolation").and_then(Value::as_str) == Some("remote")
        }
        _ => false,
    };
    if background {
        return Some("Run it in the foreground: obid ends the session when your turn ends, and background work can't ask for permissions.".into());
    }
    if tool == "Bash"
        && let Some(command) = input.get("command").and_then(Value::as_str)
        && publishes(command)
    {
        return Some("obid publishes the job's work itself. Don't push or post; say in your summary what you'd publish.".into());
    }
    if let Some(path) = input
        .get("file_path")
        .or_else(|| input.get("notebook_path"))
        .and_then(Value::as_str)
    {
        let file = normalized(&worktree.join(path));
        if !file.starts_with(normalized(worktree)) {
            return Some(format!(
                "Stay inside this job's worktree ({}).",
                worktree.display()
            ));
        }
    }
    None
}

/// What obid answers for a job of `kind`, and whether it is a review another Obi asked for; `mcp`
/// is the job's MCP permission rules ([`fixed_denial`]).
pub fn decide(
    tool: &str,
    input: &Value,
    worktree: &Path,
    obi_review: bool,
    mcp: &[String],
) -> Answer {
    if let Some(why) = fixed_denial(tool, input, worktree, mcp) {
        return Answer::Deny(why);
    }
    if obi_review && !REVIEW_TOOLS.contains(&tool) {
        return Answer::Deny(format!(
            "This review only reads the change: {tool} isn't available. Report what you'd have checked with it as a finding or in your summary."
        ));
    }
    Answer::Allow
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn publishing_commands_are_refused() {
        for command in [
            "git push origin HEAD",
            "git -C x push",
            "cd a && git remote set-url origin x",
            "gh pr create --fill",
            "gh api repos/x",
            "git config remote.origin.pushurl x",
        ] {
            assert!(publishes(command), "{command}");
        }
        for command in [
            "git status",
            "git log --oneline",
            "gh pr view 3",
            "echo push",
        ] {
            assert!(!publishes(command), "{command}");
        }
    }

    #[test]
    fn decisions() {
        let worktree = Path::new("/h/worktrees/j1");
        assert_eq!(
            decide(
                "Read",
                &json!({"file_path": "src/a.js"}),
                worktree,
                true,
                &[]
            ),
            Answer::Allow
        );
        assert!(matches!(
            decide(
                "Read",
                &json!({"file_path": "../j2/a.js"}),
                worktree,
                false,
                &[]
            ),
            Answer::Deny(_)
        ));
        assert!(matches!(
            decide(
                "Read",
                &json!({"file_path": "/h/api-token"}),
                worktree,
                false,
                &[]
            ),
            Answer::Deny(_)
        ));
        assert!(matches!(
            decide(
                "Bash",
                &json!({"command": "node --test"}),
                worktree,
                true,
                &[]
            ),
            Answer::Deny(_)
        ));
        assert_eq!(
            decide(
                "Bash",
                &json!({"command": "node --test"}),
                worktree,
                false,
                &[]
            ),
            Answer::Allow
        );
        assert!(matches!(
            decide(
                "Bash",
                &json!({"command": "sleep 9", "run_in_background": true}),
                worktree,
                false,
                &[]
            ),
            Answer::Deny(_)
        ));
        assert!(matches!(
            decide("Task", &json!({"description": "x"}), worktree, false, &[]),
            Answer::Deny(_)
        ));
        assert!(matches!(
            decide("mcp__github__create_pr", &json!({}), worktree, false, &[]),
            Answer::Deny(_)
        ));
        // An MCP tool only by the job's rules: one rule per tool an enabled plug-in allows.
        let rules = vec![
            "mcp__tetrix__get_entity".to_owned(),
            "mcp__tetrix__save_session".to_owned(),
        ];
        assert_eq!(
            decide(
                "mcp__tetrix__get_entity",
                &json!({}),
                worktree,
                false,
                &rules
            ),
            Answer::Allow
        );
        for refused in [
            "mcp__tetrix__resume_session",
            "mcp__tetrix__get_entity_x",
            "mcp__claude_ai_Tetrix__get_entity",
            "mcp__github__create_pr",
            "mcp",
        ] {
            assert!(
                matches!(
                    decide(refused, &json!({}), worktree, false, &rules),
                    Answer::Deny(_)
                ),
                "{refused}"
            );
        }
        // With no plug-in enabled, no MCP tool at all.
        assert!(matches!(
            decide("mcp__tetrix__get_entity", &json!({}), worktree, false, &[]),
            Answer::Deny(_)
        ));
        // A review another Obi asked for only reads, whatever the rules.
        assert!(matches!(
            decide(
                "mcp__tetrix__get_entity",
                &json!({}),
                worktree,
                true,
                &rules
            ),
            Answer::Deny(_)
        ));
    }
}
