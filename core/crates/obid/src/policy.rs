//! What obid answers an agent's permission prompts (Engine/Jobs.swift, `Policy`): fixed denials
//! first, in every mode; then the job's own rule. A review another Obi asked for may only read.

use std::path::{Component, Path, PathBuf};

use serde_json::Value;

use crate::agent::Answer;

/// The tools a review another Obi asked for has: it reads the change and reports. obid starts
/// the agent with only these (`--tools`), since Claude Code runs some calls without asking first
/// (read-only shell commands, reads inside its working folder), and answers its prompts with
/// only these too. No shell, no search, no edit, no web: what it was sent is data, and its answer
/// goes back through the publish gate. obid hands it the change as a diff
/// (`crate::review::DIFF_FILE`), so reading is all it needs.
pub const REVIEW_TOOLS: [&str; 1] = ["Read"];

/// Git commands an owner job may run. Anything else (`git ship`, `git send-pack`) is treated as
/// a publish: an alias or a transport command reads the same as `git push` from the words alone.
const GIT_LOCAL: &[&str] = &[
    "add",
    "am",
    "apply",
    "archive",
    "bisect",
    "blame",
    "branch",
    "checkout",
    "cherry-pick",
    "clean",
    "commit",
    "commit-tree",
    "describe",
    "diff",
    "difftool",
    "fetch",
    "for-each-ref",
    "grep",
    "hash-object",
    "init",
    "log",
    "ls-files",
    "ls-remote",
    "ls-tree",
    "merge",
    "mv",
    "notes",
    "pull",
    "range-diff",
    "read-tree",
    "rebase",
    "reflog",
    "reset",
    "restore",
    "rev-list",
    "rev-parse",
    "revert",
    "rm",
    "shortlog",
    "show",
    "stash",
    "status",
    "switch",
    "tag",
    "update-index",
    "update-ref",
    "version",
    "whatchanged",
    "worktree",
    "write-tree",
];

/// Whether `command` publishes. Matching words is best-effort: the job sandbox is what holds a
/// publish back (an invalid push URL, no code-host credentials). This still denies the forms a
/// model tries first, including a shell wrapper, a git alias, a transport command and a REST merge.
fn publishes(command: &str) -> bool {
    let flat = command.replace(['\'', '"', '`'], " ");
    let words: Vec<&str> = flat.split_whitespace().collect();
    let lower = flat.to_ascii_lowercase();
    if lower.contains("pushurl") || posts_to_a_code_host(&flat, &words) {
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
            match words.get(j).copied() {
                Some("push" | "send-pack" | "receive-pack" | "upload-pack" | "http-push") => {
                    return true;
                }
                Some("remote") => {
                    if matches!(
                        words.get(j + 1).copied(),
                        Some("set-url" | "add" | "remove" | "rm" | "rename")
                    ) {
                        return true;
                    }
                }
                Some("config") => {
                    if words[j + 1..].iter().any(|w| {
                        let w = w.to_ascii_lowercase();
                        w.contains("alias") || w.contains("pushurl") || w.contains(".url")
                    }) {
                        return true;
                    }
                }
                Some(cmd) if !cmd.starts_with('-') && !GIT_LOCAL.contains(&cmd) => return true,
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

/// A direct REST write to a code host: `curl -X PUT https://api.github.com/…/merge`.
fn posts_to_a_code_host(flat: &str, words: &[&str]) -> bool {
    let client = words.iter().any(|w| {
        matches!(
            w.rsplit('/').next().unwrap_or(w),
            "curl" | "wget" | "httpie" | "xh"
        )
    });
    if !client {
        return false;
    }
    let lower = flat.to_ascii_lowercase();
    let host = [
        "api.github.com",
        "gitlab.com/api",
        "api.bitbucket.org",
        "bitbucket.org/2.0",
    ]
    .iter()
    .any(|h| lower.contains(h));
    if !host {
        return false;
    }
    let method = words.windows(2).any(|pair| {
        (pair[0].eq_ignore_ascii_case("-X") || pair[0].eq_ignore_ascii_case("--request"))
            && matches!(
                pair[1].to_ascii_lowercase().as_str(),
                "put" | "post" | "patch" | "delete"
            )
    });
    method || lower.contains("merge")
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

/// Whether the link at `link` (relative to `worktree`) leads out of the worktree, or obid can't
/// tell where it leads: followed as the system would open it, or, when what it names doesn't
/// exist, its target taken from the folder it's in. A link inside that leads to a file inside is
/// fine, also when that file doesn't exist.
pub fn link_leads_out(worktree: &Path, link: &Path) -> bool {
    let real = real_worktree(worktree);
    let path = worktree.join(link);
    if let Some(to) = resolved(&path) {
        return !to.starts_with(&real);
    }
    let Ok(target) = std::fs::read_link(&path) else {
        return true;
    };
    let Some(folder) = path.parent().and_then(resolved) else {
        return true;
    };
    !resolved(&folder.join(target)).is_some_and(|to| to.starts_with(&real))
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

/// Where the absolute `path` leads once symlinks are followed (the part that doesn't exist yet
/// appended as written), or none when obid can't tell.
pub fn real_path(path: &Path) -> Option<PathBuf> {
    resolved(path)
}

/// Whether the path an agent names leads inside `worktree` once symlinks are followed.
pub fn path_inside(path: &str, worktree: &Path) -> bool {
    inside(path, worktree, &real_worktree(worktree))
}

/// Why a review another Obi asked for may not make this call of one of [`REVIEW_TOOLS`], or
/// `None`. Every path input must lead inside the worktree once symlinks are followed, so an
/// absolute path doesn't reach the agent's account, its login or anything else the job sandbox
/// lets the agent read. An input obid doesn't know that may name a path is refused rather than
/// let through. Claude Code reads inside its working folder without asking, so this covers only
/// what it asks for: a link in the reviewed branch that leads out fails the review before the
/// agent starts ([`link_leads_out`]).
fn review_denial(tool: &str, input: &Value, worktree: &Path) -> Option<String> {
    let stay = || {
        Some(format!(
            "This review reads only the change, inside its worktree ({}): use paths inside it.",
            worktree.display()
        ))
    };
    let Some(fields) = input.as_object() else {
        return stay();
    };
    let real = real_worktree(worktree);
    for (key, value) in fields {
        if matches!(key.as_str(), "path" | "file_path" | "notebook_path") {
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
    // The broker itself checks every upstream tool's read-only annotation and holds each login
    // outside the job sandbox. Its tool calls are therefore the only non-plug-in MCP calls Oby
    // accepts, and only in a job given the broker (its rule is in `mcp`): a plug-in whose id is
    // `oby` gets no more than the tools its manifest allows. The job-scoped broker token still
    // limits them to this job.
    if tool.starts_with("mcp__oby__")
        && mcp
            .iter()
            .any(|rule| rule == crate::connections::BROKER_RULE)
    {
        return None;
    }
    if tool.starts_with("mcp__") || tool == "mcp" {
        return (!mcp.iter().any(|rule| rule == tool)).then(|| format!(
            "obid's agents use only the MCP tools of the plug-ins the owner enabled, and only the ones each allows. Say in your summary what you'd have done with {tool}."
        ));
    }
    // A background command is fine: Claude Code wakes when it ends, obid waits for that
    // (crate::agent), and it ends with the turn. Background subagents stay refused.
    let background = match tool {
        "Agent" | "Task" => {
            input.get("run_in_background").and_then(Value::as_bool) != Some(false)
                || input.get("isolation").and_then(Value::as_str) == Some("remote")
        }
        _ => false,
    };
    if background {
        return Some("Run the helper in the foreground: a background helper's work can't ask for permissions.".into());
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
    // Another Obi's review never puts a question to this owner (#858).
    if obi_review && tool == crate::permissions::ASK_USER_QUESTION {
        return Answer::Deny(crate::permissions::NO_ONE_TO_ASK.into());
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
            // A shell wrapper, an alias, a transport command, a REST merge (#477).
            "bash -c 'git push origin HEAD'",
            "sh -c \"git push\"",
            "git ship",
            "git config alias.ship push",
            "git -c alias.ship=push ship",
            "git send-pack origin HEAD",
            "curl -X PUT https://api.github.com/repos/o/r/pulls/1/merge",
        ] {
            assert!(publishes(command), "{command}");
        }
        for command in [
            "git status",
            "git log --oneline",
            "git commit -m hello",
            "bash -c 'git status'",
            "gh pr view 3",
            "echo push",
            "curl https://example.com/merge",
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

    /// A review another Obi asked for only reads, only inside its worktree: Read, whose path
    /// inputs must lead inside after symlinks. Grep, Glob, LS and TodoWrite are refused too, even
    /// inside: obid starts the agent with Read only (`--tools`), and answers only for Read.
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
            ("Read", "not an object".into()),
            (
                "Read",
                json!({"file_path": at(&account.join(".credentials.json"))}),
            ),
            ("Read", json!({"file_path": "src/a.js", "path": "/"})),
            // Inside the worktree, but not Read: the agent doesn't have them.
            (
                "Grep",
                json!({"pattern": "average", "output_mode": "content", "-n": true}),
            ),
            ("Grep", json!({"pattern": "x", "path": at(&worktree)})),
            ("Glob", json!({"pattern": "**/*.js"})),
            ("LS", json!({"path": "src"})),
            (
                "TodoWrite",
                json!({"todos": [{"content": "Read the src/ folder", "status": "pending", "activeForm": "Reading"}]}),
            ),
        ];
        for (tool, input) in refused {
            assert!(
                matches!(decide(tool, &input, &worktree, true, &[]), Answer::Deny(_)),
                "{tool} {input}"
            );
        }
        let allowed = [
            (
                "Read",
                json!({"file_path": "src/a.js", "offset": 1, "limit": 20}),
            ),
            ("Read", json!({"file_path": "src/same.js"})),
            ("Read", json!({"file_path": at(&worktree.join("src/a.js"))})),
            (
                "Read",
                json!({"file_path": at(&worktree_by_link.join("src/a.js"))}),
            ),
            (
                "Read",
                json!({"file_path": at(&worktree.join(".obi/inputs/obi-request.json"))}),
            ),
        ];
        for (tool, input) in allowed {
            assert_eq!(
                decide(tool, &input, &worktree, true, &[]),
                Answer::Allow,
                "{tool} {input}"
            );
        }
        // Another Obi's review never asks this owner a question (#858); the owner's own job may.
        let asks = json!({"questions": [{"question": "Which?", "options": [{"label": "A"}]}]});
        assert_eq!(
            decide("AskUserQuestion", &asks, &worktree, true, &[]),
            Answer::Deny(crate::permissions::NO_ONE_TO_ASK.into())
        );
        assert_eq!(
            decide("AskUserQuestion", &asks, &worktree, false, &[]),
            Answer::Allow
        );
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

    /// The links a reviewed branch commits: one that leads out of the worktree, by any route, or
    /// that obid can't follow, leads out; one inside, to a file there or one that doesn't exist
    /// yet, doesn't.
    #[test]
    fn links_that_lead_out() {
        let disk = Disk::new("links");
        let home = disk.0.join("h");
        let worktree = home.join("worktrees/j1");
        std::fs::create_dir_all(worktree.join("src/deep")).unwrap();
        std::fs::create_dir_all(home.join("accounts/stub")).unwrap();
        std::fs::write(home.join("accounts/stub/.credentials.json"), "{}").unwrap();
        std::fs::write(worktree.join("src/a.js"), "a").unwrap();
        let link = |name: &str, to: &str| {
            std::os::unix::fs::symlink(to, worktree.join(name)).unwrap();
        };
        link("x1", "../../accounts");
        link("x2", "../../accounts/stub");
        link(
            "x3",
            home.join("accounts/stub/.credentials.json")
                .to_str()
                .unwrap(),
        );
        link("x4", "/");
        link("x5", "../../nowhere/yet");
        link("x6", "x6");
        link("x7", "x1/stub");
        link("x8", "nowhere/../../../accounts");
        link("src/deep/up", "../../..");
        link("in1", "src/a.js");
        link("in2", "src");
        link("in3", "src/missing.js");
        link("src/deep/in4", "../a.js");
        link("in5", ".");
        link("in6", "in1");
        for out in [
            "x1",
            "x2",
            "x3",
            "x4",
            "x5",
            "x6",
            "x7",
            "x8",
            "src/deep/up",
        ] {
            assert!(link_leads_out(&worktree, Path::new(out)), "{out}");
        }
        for inside in ["in1", "in2", "in3", "src/deep/in4", "in5", "in6"] {
            assert!(!link_leads_out(&worktree, Path::new(inside)), "{inside}");
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
        assert_eq!(
            decide(
                "Bash",
                &json!({"command": "sleep 9", "run_in_background": true}),
                worktree,
                false,
                &[]
            ),
            Answer::Allow
        );
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

    /// ConnectionTests.agentsMayCallTheBrokersToolsAndNoOtherServersOwn, in a job given the
    /// broker; and in a job without it, `mcp__oby__…` is any other server's tool: a plug-in whose
    /// id is `oby` gets only the tools its manifest allows.
    #[test]
    fn agents_may_call_the_brokers_tools_and_no_other_servers_own() {
        let worktree = Path::new("/tmp/work");
        let brokered = vec![
            "mcp__tetrix__get_entity".to_owned(),
            crate::connections::BROKER_RULE.to_owned(),
        ];
        for allowed in ["mcp__oby__mail_send_message", "mcp__oby__mail__weird"] {
            assert_eq!(
                decide(allowed, &json!({}), worktree, false, &brokered),
                Answer::Allow,
                "{allowed}"
            );
        }
        for refused in [
            "mcp__gmail__send_message",
            "mcp__obyx__search",
            "mcp__tetrix__x",
        ] {
            assert!(
                matches!(
                    decide(refused, &json!({}), worktree, false, &brokered),
                    Answer::Deny(_)
                ),
                "{refused}"
            );
        }
        // A review another Obi asked for never reaches the broker.
        assert!(matches!(
            decide(
                "mcp__oby__mail_search",
                &json!({}),
                worktree,
                true,
                &brokered
            ),
            Answer::Deny(_)
        ));
        // No broker: a plug-in named `oby`, with one tool allowed.
        let plugin = vec!["mcp__oby__search".to_owned()];
        assert_eq!(
            decide("mcp__oby__search", &json!({}), worktree, false, &plugin),
            Answer::Allow
        );
        for rules in [&plugin[..], &[]] {
            assert!(
                matches!(
                    decide(
                        "mcp__oby__delete_everything",
                        &json!({}),
                        worktree,
                        false,
                        rules
                    ),
                    Answer::Deny(_)
                ),
                "{rules:?}"
            );
        }
    }
}
