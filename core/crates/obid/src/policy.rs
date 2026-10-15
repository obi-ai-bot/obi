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

/// Where the absolute `path` leads when the agent opens it: symlinks followed and `..` taken as
/// the system takes it (after the link before it), the part that doesn't exist yet appended as
/// written. `None` when obid can't tell where it leads: a link that leads nowhere, or a `..` after
/// a folder that doesn't exist.
fn resolved(path: &Path) -> Option<PathBuf> {
    let components: Vec<Component> = path.components().collect();
    for end in (1..=components.len()).rev() {
        let prefix: PathBuf = components[..end].iter().collect();
        if std::fs::symlink_metadata(&prefix).is_err() {
            continue;
        }
        let mut real = std::fs::canonicalize(&prefix).ok()?;
        for rest in &components[end..] {
            match rest {
                Component::Normal(name) => real.push(name),
                Component::CurDir => {}
                _ => return None,
            }
        }
        return Some(real);
    }
    None
}

/// The worktree as the system sees it: links followed when it exists, as written otherwise.
fn real_worktree(worktree: &Path) -> PathBuf {
    resolved(worktree).unwrap_or_else(|| normalized(worktree))
}

/// Whether the path input `path` leads inside `worktree` (already real): relative to the worktree
/// as the agent's tools take it, after symlinks. `~` is refused, since the agent's tools take it
/// for its home.
fn inside(path: &str, worktree: &Path, real_worktree: &Path) -> bool {
    if path.starts_with('~') || path.contains('\0') {
        return false;
    }
    resolved(&worktree.join(path)).is_some_and(|real| real.starts_with(real_worktree))
}

/// Whether the glob `pattern` (Glob's `pattern`, Grep's `glob`) stays below the folder it's taken
/// from: no absolute pattern (Glob would search from its root), no `~`, no `..` and no brace
/// alternative that starts at the root or the home.
fn stays_below(pattern: &str) -> bool {
    !(pattern.starts_with('/')
        || pattern.starts_with('~')
        || pattern.contains("..")
        || ["{/", ",/", "{~", ",~", "\\"]
            .iter()
            .any(|bad| pattern.contains(bad)))
}

/// Why a review another Obi asked for may not make this call of one of [`REVIEW_TOOLS`], or
/// `None`. Every path input must lead inside the worktree once symlinks are followed, so neither
/// an absolute path nor a link in the reviewed branch reaches the agent's account, its login or
/// anything else the job sandbox lets the agent read. An input obid doesn't know that may name a
/// path is refused rather than let through.
fn review_denial(tool: &str, input: &Value, worktree: &Path) -> Option<String> {
    let stay = || {
        Some(format!(
            "This review reads only the change, inside its worktree ({}): use paths and patterns inside it.",
            worktree.display()
        ))
    };
    let Some(fields) = input.as_object() else {
        return stay();
    };
    let real = real_worktree(worktree);
    for (key, value) in fields {
        let glob = (tool == "Glob" && key == "pattern") || (tool == "Grep" && key == "glob");
        if glob {
            if !value.as_str().is_some_and(stays_below) {
                return stay();
            }
            // Glob searches from the pattern's folders before its first wildcard: they too must
            // lead inside, so a link in the branch can't take the search out.
            if tool == "Glob" {
                let base = fields.get("path").and_then(Value::as_str).unwrap_or(".");
                let pattern = value.as_str().unwrap_or("");
                let literal: Vec<&str> = pattern
                    .split('/')
                    .take_while(|part| !part.contains(['*', '?', '[', '{']))
                    .collect();
                let from = Path::new(base).join(literal.join("/"));
                if !from.to_str().is_some_and(|p| inside(p, worktree, &real)) {
                    return stay();
                }
            }
        } else if matches!(key.as_str(), "path" | "file_path" | "notebook_path") {
            if !value.as_str().is_some_and(|p| inside(p, worktree, &real)) {
                return stay();
            }
        } else if names_a_path(key) || value_names_a_path(value) {
            return Some(format!(
                "This review reads only the change: obid doesn't know {tool}'s input {key}, so it isn't available."
            ));
        }
    }
    None
}

/// Whether an input's name says it may hold a path obid would have to check.
fn names_a_path(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    ["path", "dir", "file", "cwd", "root", "folder", "glob"]
        .iter()
        .any(|word| key.contains(word))
}

/// Whether a nested input holds a field whose name says it may hold a path.
fn value_names_a_path(value: &Value) -> bool {
    match value {
        Value::Object(fields) => fields
            .iter()
            .any(|(key, value)| names_a_path(key) || value_names_a_path(value)),
        Value::Array(items) => items.iter().any(value_names_a_path),
        _ => false,
    }
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
        // After symlinks: a link in the worktree to a file outside it is outside.
        if !inside(path, worktree, &real_worktree(worktree)) {
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
    if obi_review && let Some(why) = review_denial(tool, input, worktree) {
        return Answer::Deny(why);
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

    /// A folder of the test's own on disk, removed when it ends.
    struct Disk(PathBuf);

    impl Disk {
        fn new(name: &str) -> Disk {
            let path =
                std::env::temp_dir().join(format!("obid-policy-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Disk(path)
        }
    }

    impl Drop for Disk {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A review another Obi asked for reads only inside its worktree, whatever tool and whatever
    /// path input: Grep's, Glob's and LS's `path`, Glob's pattern, Grep's `glob`, after symlinks.
    #[test]
    fn an_obi_review_stays_inside_its_worktree() {
        let disk = Disk::new("review");
        let home = disk.0.join("h");
        let worktree = home.join("worktrees/j1");
        let account = home.join("tmp/j1/.claude");
        std::fs::create_dir_all(worktree.join("src")).unwrap();
        std::fs::create_dir_all(&account).unwrap();
        std::fs::create_dir_all(home.join("logins/j1/.claude")).unwrap();
        std::fs::write(worktree.join("src/a.js"), "a").unwrap();
        // Links the reviewed branch could hold: one out to the account folder, one inside.
        std::os::unix::fs::symlink(&account, worktree.join("creds")).unwrap();
        std::os::unix::fs::symlink("../tmp", worktree.join("src/up")).unwrap();
        std::os::unix::fs::symlink("a.js", worktree.join("src/same.js")).unwrap();
        // Reaching the worktree by a path with a link in it is still the worktree.
        std::os::unix::fs::symlink(&home, disk.0.join("home-link")).unwrap();
        let worktree_by_link = disk.0.join("home-link/worktrees/j1");
        let at = |p: &Path| p.to_str().unwrap().to_owned();

        let refused = [
            (
                "Grep",
                json!({"pattern": ".", "path": at(&account), "output_mode": "content"}),
            ),
            ("Grep", json!({"pattern": "refresh", "path": "/"})),
            ("Grep", json!({"pattern": "x", "path": "creds"})),
            ("Grep", json!({"pattern": "x", "path": "src/up/j1"})),
            ("Grep", json!({"pattern": "x", "path": "~/.claude"})),
            ("Grep", json!({"pattern": "x", "path": "src/../.."})),
            ("Grep", json!({"pattern": "x", "glob": "../../tmp/**"})),
            ("Grep", json!({"pattern": "x", "glob": "/h/**"})),
            ("Grep", json!({"pattern": "x", "path": 3})),
            (
                "Glob",
                json!({"pattern": "**/*", "path": at(&home.join("tmp/j1"))}),
            ),
            ("Glob", json!({"pattern": at(&account.join("*"))})),
            ("Glob", json!({"pattern": "../../**/*"})),
            ("Glob", json!({"pattern": "src/*/../../../tmp/**"})),
            ("Glob", json!({"pattern": "~/.claude/*"})),
            ("Glob", json!({"pattern": "{/h,src}/**"})),
            ("Glob", json!({"pattern": "creds/*"})),
            ("LS", json!({"path": at(&home.join("logins/j1/.claude"))})),
            ("LS", json!({"path": "creds"})),
            ("Read", json!({"file_path": "creds/.credentials.json"})),
            (
                "Read",
                json!({"file_path": "src/up/j1/.claude/.credentials.json"}),
            ),
            ("Read", json!({"file_path": "~/.claude/.credentials.json"})),
            // A path input obid doesn't know is refused, not let through.
            ("Grep", json!({"pattern": "x", "dir": at(&account)})),
            ("LS", json!({"path": "src", "root_path": "/"})),
            (
                "Read",
                json!({"file_path": "src/a.js", "extra": {"cwd": "/"}}),
            ),
            ("Grep", "not an object".into()),
        ];
        for (tool, input) in refused {
            assert!(
                matches!(decide(tool, &input, &worktree, true, &[]), Answer::Deny(_)),
                "{tool} {input}"
            );
        }
        let allowed = [
            (
                "Grep",
                json!({"pattern": "average", "output_mode": "content", "-n": true}),
            ),
            (
                "Grep",
                json!({"pattern": "x", "path": "src", "glob": "**/*.{js,ts}", "type": "js"}),
            ),
            ("Grep", json!({"pattern": "x", "path": at(&worktree)})),
            (
                "Grep",
                json!({"pattern": "x", "path": at(&worktree_by_link)}),
            ),
            ("Glob", json!({"pattern": "**/*.js"})),
            ("Glob", json!({"pattern": "src/*.js", "path": "."})),
            (
                "Glob",
                json!({"pattern": "*.js", "path": at(&worktree.join("src"))}),
            ),
            (
                "LS",
                json!({"path": at(&worktree), "ignore": ["node_modules"]}),
            ),
            ("LS", json!({"path": "src"})),
            (
                "Read",
                json!({"file_path": "src/a.js", "offset": 1, "limit": 20}),
            ),
            ("Read", json!({"file_path": "src/same.js"})),
            (
                "Read",
                json!({"file_path": at(&worktree.join(".obi/inputs/obi-request.json"))}),
            ),
            (
                "TodoWrite",
                json!({"todos": [{"content": "Read the src/ folder", "status": "pending", "activeForm": "Reading"}]}),
            ),
        ];
        for (tool, input) in allowed {
            assert_eq!(
                decide(tool, &input, &worktree, true, &[]),
                Answer::Allow,
                "{tool} {input}"
            );
        }
        // The owner's own jobs: a file path still may not lead out through a link.
        assert!(matches!(
            decide(
                "Edit",
                &json!({"file_path": "creds/x"}),
                &worktree,
                false,
                &[]
            ),
            Answer::Deny(_)
        ));
        assert_eq!(
            decide(
                "Write",
                &json!({"file_path": "src/new/b.js"}),
                &worktree,
                false,
                &[]
            ),
            Answer::Allow
        );
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
