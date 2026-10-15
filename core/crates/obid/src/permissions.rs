//! Permission modes (docs/runner-api.md, "Permission modes", Engine/Permissions.swift): how much a
//! job asks its owner. Whatever the mode, obid's fixed denials come first (`crate::policy`: no
//! publishing, the worktree only, no background work, only Tetrix's reads among MCP tools); then
//! the owner's saved rules for the repository (deny beats allow); then the mode allows, refuses or
//! asks. Reads and the agent's own bookkeeping never ask.
//!
//! The rules and Settings › Permissions' default mode are kept in `home/permissions.json` (0600).

use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The modes, as jobs and Settings name them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Every command and file edit waits for the owner.
    Ask,
    /// Edits inside the worktree go through; commands ask.
    AcceptEdits,
    /// The agent only reads; everything else asks, and edits are refused.
    Plan,
    /// obid answers everything by its rules: the default.
    Bypass,
}

impl Mode {
    pub const ALL: [Mode; 4] = [Mode::Ask, Mode::AcceptEdits, Mode::Plan, Mode::Bypass];

    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Ask => "ask",
            Mode::AcceptEdits => "acceptEdits",
            Mode::Plan => "plan",
            Mode::Bypass => "bypass",
        }
    }

    /// "Accept edits", as steps say it.
    pub fn title(self) -> &'static str {
        match self {
            Mode::Ask => "Ask",
            Mode::AcceptEdits => "Accept edits",
            Mode::Plan => "Plan",
            Mode::Bypass => "Bypass",
        }
    }

    pub fn parse(name: &str) -> Option<Mode> {
        Mode::ALL.into_iter().find(|m| m.as_str() == name)
    }
}

/// The mode's answer to a call obid's fixed rules let through.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Allow,
    Deny(String),
    Ask,
}

/// A tool call an agent asks about, as obid reads it: Claude Code's `can_use_tool` input, or what
/// Codex's and ACP's adapters make of theirs (`Bash` with a command, `Edit` with a file).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Call {
    pub tool: String,
    pub command: Option<String>,
    /// The files it writes, as the agent named them.
    pub paths: Vec<String>,
    pub url: Option<String>,
}

impl Call {
    pub fn new(tool: &str, input: &Value) -> Call {
        let text = |key: &str| input.get(key).and_then(Value::as_str).map(str::to_owned);
        Call {
            tool: tool.to_owned(),
            command: text("command"),
            paths: text("file_path")
                .or_else(|| text("notebook_path"))
                .into_iter()
                .collect(),
            url: text("url"),
        }
    }
}

/// A permission waiting for the owner (`permission` on the job): what the agent wants to do, the
/// rule "always" would save, and how the card says it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Permission {
    pub id: String,
    pub tool: String,
    /// "Run swift test".
    pub title: String,
    /// The whole command, the files, or the address.
    pub detail: String,
    /// The rule "always" saves, like `Bash(swift test:*)`, or none when obid can't make a safe one
    /// (a chained command, one that runs whatever follows it): then it can only be allowed once.
    pub rule: Option<String>,
    /// "Yes, and don't ask again for swift test in deskree-inc/oby", or none without a rule.
    pub always: Option<String>,
}

/// A rule the owner saved for a repository.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rule {
    pub id: String,
    /// Claude Code's syntax: `Bash(swift test:*)`, `Bash(make lint)`, `Edit`, `Edit(Engine/*)`.
    pub rule: String,
    pub repo: String,
    /// `allow` or `deny`.
    pub decision: String,
    /// Seconds since the epoch.
    pub created: i64,
}

impl Rule {
    pub fn to_json(&self) -> Value {
        json!({"id": self.id, "rule": self.rule, "repo": self.repo, "decision": self.decision,
               "created": obi_protocol::time::format(self.created)})
    }
}

/// How the owner answers a waiting permission.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Allow,
    /// Allowed, and the permission's rule saved for the repository.
    Always,
    Deny,
}

impl Decision {
    pub fn parse(name: &str) -> Option<Decision> {
        match name {
            "allow" => Some(Decision::Allow),
            "always" => Some(Decision::Always),
            "deny" => Some(Decision::Deny),
            _ => None,
        }
    }
}

/// A permission item's answers (docs/runner-api.md, "Inbox item"); any other words say no, and
/// reach the agent.
pub const ALLOW: &str = "Allow";
pub const ALWAYS_ALLOW: &str = "Always allow";
pub const DENY: &str = "Deny";

/// The decision an inbox answer stands for, and the owner's words for the agent.
pub fn inbox_decision(answer: &str) -> (Decision, Option<String>) {
    match answer.trim().to_lowercase().as_str() {
        "allow" | "yes" => (Decision::Allow, None),
        "always allow" => (Decision::Always, None),
        "deny" | "no" => (Decision::Deny, None),
        _ => (Decision::Deny, Some(answer.trim().to_owned())),
    }
}

/// What never asks: reads, and the agent's own bookkeeping (a to-do list, a helper whose own
/// actions ask).
const QUIET: [&str; 8] = [
    "Read",
    "Grep",
    "Glob",
    "LS",
    "NotebookRead",
    "TodoWrite",
    "Task",
    "Agent",
];

/// File edits: allowed in Accept edits, refused in Plan.
const EDITS: [&str; 4] = ["Edit", "MultiEdit", "Write", "NotebookEdit"];

/// What an agent in Plan hears when it tries to change something.
pub const PLAN_ONLY: &str = "Plan mode: read only, change nothing yet. Finish with your plan; the owner approves it before you go on.";

/// What the agent hears when the owner says no without words.
pub const SAID_NO: &str = "The owner said no. Don't do that; do the rest of the work another way, or say in your summary what you needed.";

/// Tools whose second word names what they do (`swift test`, `git status`): their rules keep it.
const SUBCOMMANDS: [&str; 22] = [
    "git",
    "swift",
    "npm",
    "pnpm",
    "yarn",
    "bun",
    "npx",
    "cargo",
    "go",
    "make",
    "docker",
    "uv",
    "poetry",
    "bundle",
    "rake",
    "mix",
    "dotnet",
    "gradle",
    "./gradlew",
    "xcrun",
    "brew",
    "deno",
];

/// Shells, interpreters and wrappers: what follows them is any program at all, so a rule for them
/// would allow anything. They're allowed once at a time, never always.
const RUNS_ANYTHING: [&str; 47] = [
    "sh",
    "bash",
    "zsh",
    "dash",
    "ksh",
    "fish",
    "pwsh",
    "powershell",
    "python",
    "python2",
    "python3",
    "pypy",
    "pypy3",
    "node",
    "nodejs",
    "ruby",
    "perl",
    "php",
    "lua",
    "tclsh",
    "osascript",
    "awk",
    "gawk",
    "env",
    "sudo",
    "doas",
    "su",
    "xargs",
    "nohup",
    "timeout",
    "nice",
    "ionice",
    "time",
    "exec",
    "eval",
    "command",
    "builtin",
    "watch",
    "stdbuf",
    "caffeinate",
    "script",
    "ssh",
    "parallel",
    "find",
    "open",
    "launchctl",
    "systemd-run",
];

/// The same, as a tool and its subcommand.
const RUNS_ANYTHING_AFTER: [&str; 17] = [
    "uv run",
    "poetry run",
    "bundle exec",
    "npm exec",
    "pnpm exec",
    "pnpm dlx",
    "yarn dlx",
    "yarn exec",
    "bun x",
    "bun run",
    "deno run",
    "deno eval",
    "go run",
    "cargo run",
    "docker run",
    "docker exec",
    "xcrun swift",
];

/// The mode's answer to `call`, after the owner's saved `rules` for the job's repository. obid's
/// fixed denials (`crate::policy`) come before this, in every mode.
pub fn decide(call: &Call, mode: Mode, rules: &[Rule], worktree: &Path) -> Verdict {
    // The plan's own end: in Plan the agent finishes with it, in any other mode there's nothing to
    // approve.
    if call.tool == "ExitPlanMode" || QUIET.contains(&call.tool.as_str()) {
        return Verdict::Allow;
    }
    if call.tool.starts_with("mcp__") {
        return Verdict::Allow;
    }
    if let Some(deny) = rules
        .iter()
        .find(|r| r.decision == "deny" && matches(&r.rule, call, worktree, false))
    {
        return Verdict::Deny(format!(
            "The owner's rule {} refuses this in {}. Do it another way, or say in your summary what you'd have done.",
            deny.rule, deny.repo
        ));
    }
    let edit = EDITS.contains(&call.tool.as_str());
    if mode == Mode::Plan && edit {
        return Verdict::Deny(PLAN_ONLY.into());
    }
    // Plan changes nothing: a saved allow rule doesn't let a command through while planning.
    if mode != Mode::Plan
        && rules
            .iter()
            .any(|r| r.decision == "allow" && matches(&r.rule, call, worktree, true))
    {
        return Verdict::Allow;
    }
    match mode {
        Mode::Bypass => Verdict::Allow,
        Mode::AcceptEdits if edit => Verdict::Allow,
        _ => Verdict::Ask,
    }
}

/// Every file-editing tool is `Edit`, as Claude Code's rules read them.
fn family(tool: &str) -> &str {
    if EDITS.contains(&tool) { "Edit" } else { tool }
}

/// Shell syntax that runs more than one command, or sends output somewhere: such a command never
/// matches an allow rule, and gets none suggested.
fn is_chained(command: &str) -> bool {
    command.contains("&&")
        || command.contains("||")
        || command.contains("$(")
        || command.contains(['|', ';', '&', '`', '<', '>', '\n'])
}

/// The commands a chained command runs, split where the shell would.
fn pieces(command: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut chars = command.chars().peekable();
    while let Some(c) = chars.next() {
        let split = match c {
            '|' | ';' | '&' | '`' | '<' | '>' | '\n' => true,
            '$' if chars.peek() == Some(&'(') => {
                chars.next();
                true
            }
            _ => false,
        };
        if split {
            out.push(std::mem::take(&mut current));
        } else {
            current.push(c);
        }
    }
    out.push(current);
    out.into_iter()
        .map(|p| p.trim().to_owned())
        .filter(|p| !p.is_empty())
        .collect()
}

/// `Bash(swift test:*)` is (`Bash`, `swift test:*`); `Edit` is (`Edit`, none).
fn parse(rule: &str) -> (&str, Option<&str>) {
    match (rule.find('('), rule.ends_with(')')) {
        (Some(open), true) => {
            let content = &rule[open + 1..rule.len() - 1];
            (&rule[..open], (!content.is_empty()).then_some(content))
        }
        _ => (rule, None),
    }
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

/// A path as the worktree sees it: `Engine/Jobs.swift`.
fn relative(path: &str, worktree: &Path) -> String {
    let root = normalized(worktree);
    let file = normalized(&worktree.join(path));
    match file.strip_prefix(&root) {
        Ok(inside) => inside.to_string_lossy().into_owned(),
        Err(_) => file.to_string_lossy().into_owned(),
    }
}

/// Whether `command` runs whatever follows it: a shell, an interpreter or a wrapper (by its name
/// wherever it's run from and whichever version: `/usr/bin/python3.12` is `python3`), or a tool's
/// subcommand that does. Variables set before it don't hide it.
fn runs_any_program(command: &str) -> bool {
    let words: Vec<&str> = command
        .split_whitespace()
        .skip_while(|w| is_assignment(w))
        .collect();
    let Some(first) = words.first() else {
        return false;
    };
    let program = first.rsplit('/').next().unwrap_or(first);
    let unversioned = program.trim_end_matches(|c: char| c.is_ascii_digit() || c == '.');
    if RUNS_ANYTHING.contains(&program) || RUNS_ANYTHING.contains(&unversioned) {
        return true;
    }
    words
        .get(1)
        .is_some_and(|second| RUNS_ANYTHING_AFTER.contains(&format!("{first} {second}").as_str()))
}

/// `FOO=1`: a variable set before a command.
fn is_assignment(word: &str) -> bool {
    let Some((name, _)) = word.split_once('=') else {
        return false;
    };
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Whether `rule` covers the call. An allow rule covers only a plain command (`allowing`); a deny
/// rule covers a chained one when any of its commands matches.
fn matches(rule: &str, call: &Call, worktree: &Path, allowing: bool) -> bool {
    let (name, content) = parse(rule);
    if family(name) != family(&call.tool) {
        return false;
    }
    let bash = family(&call.tool) == "Bash";
    // No allow rule covers what runs whatever follows it, even one saved before: it would allow
    // anything.
    if allowing && bash && runs_any_program(call.command.as_deref().unwrap_or("")) {
        return false;
    }
    let Some(content) = content else {
        return true;
    };
    let (pattern, prefix) = match content
        .strip_suffix(":*")
        .or_else(|| content.strip_suffix('*'))
    {
        Some(pattern) => (pattern, true),
        None => (content, false),
    };
    let fits = |text: &str| {
        let text = text.trim();
        if !prefix {
            return text == pattern;
        }
        text == pattern
            || if pattern.ends_with('/') {
                text.starts_with(pattern)
            } else {
                text.starts_with(&format!("{pattern} "))
            }
    };
    if bash {
        let Some(command) = call.command.as_deref().map(str::trim) else {
            return false;
        };
        if is_chained(command) {
            return !allowing && pieces(command).iter().any(|p| fits(p));
        }
        return fits(command);
    }
    if family(&call.tool) == "Edit" {
        let files: Vec<String> = call.paths.iter().map(|p| relative(p, worktree)).collect();
        return !files.is_empty()
            && if allowing {
                files.iter().all(|f| fits(f))
            } else {
                files.iter().any(|f| fits(f))
            };
    }
    fits(
        call.url
            .as_deref()
            .or(call.command.as_deref())
            .unwrap_or(""),
    )
}

/// The words a command's rule keeps: `swift test` for `swift test --filter X`, `ls` for `ls -la`;
/// none for a chained command, one that starts by setting a variable or with a quote, or one that
/// runs whatever follows it.
pub fn prefix(command: &str) -> Option<String> {
    let command = command.trim();
    if command.is_empty() || is_chained(command) || runs_any_program(command) {
        return None;
    }
    let words: Vec<&str> = command.split(' ').filter(|w| !w.is_empty()).collect();
    let first = *words.first()?;
    if first.contains(['=', '"', '\'']) {
        return None;
    }
    if SUBCOMMANDS.contains(&first)
        && let Some(second) = words.get(1)
        && second.starts_with(|c: char| c.is_ascii_lowercase())
        && second
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, ':' | '_' | '-'))
    {
        return Some(format!("{first} {second}"));
    }
    Some(first.to_owned())
}

/// The card for a call that waits for the owner, with the id it's answered by.
pub fn card(call: &Call, id: &str, repo: &str, worktree: &Path) -> Permission {
    let line = |text: &str, cap: usize| {
        let first = text.split('\n').next().unwrap_or(text);
        if first.chars().count() > cap {
            format!("{}…", first.chars().take(cap - 1).collect::<String>())
        } else {
            first.to_owned()
        }
    };
    let (title, detail, rule, what) = match family(&call.tool) {
        "Bash" => {
            let command = call.command.clone().unwrap_or_default();
            let detail: String = command.chars().take(2000).collect();
            match prefix(&command) {
                Some(prefix) => (
                    format!("Run {}", line(&prefix, 60)),
                    detail,
                    Some(format!("Bash({prefix}:*)")),
                    Some(prefix),
                ),
                None => (format!("Run {}", line(&command, 60)), detail, None, None),
            }
        }
        "Edit" => {
            let files: Vec<String> = call.paths.iter().map(|p| relative(p, worktree)).collect();
            let names: Vec<&str> = files
                .iter()
                .map(|f| f.rsplit('/').next().unwrap_or(f))
                .collect();
            let verb = if call.tool == "Write" {
                "Write"
            } else {
                "Edit"
            };
            let what = match names.as_slice() {
                [one] => (*one).to_owned(),
                many => format!("{} files", many.len()),
            };
            (
                format!("{verb} {what}"),
                files.join(", "),
                Some("Edit".to_owned()),
                Some("file edits".to_owned()),
            )
        }
        tool => {
            let detail = call
                .url
                .clone()
                .or_else(|| call.command.clone())
                .unwrap_or_default();
            let title = match tool {
                "WebFetch" => format!(
                    "Fetch {}",
                    host(&detail).unwrap_or_else(|| "a web page".to_owned())
                ),
                "WebSearch" => "Search the web".to_owned(),
                _ => format!("Use {tool}"),
            };
            (title, detail, Some(tool.to_owned()), Some(tool.to_owned()))
        }
    };
    Permission {
        id: id.to_owned(),
        tool: call.tool.clone(),
        title,
        detail,
        rule,
        always: what.map(|w| format!("Yes, and don't ask again for {w} in {repo}")),
    }
}

/// The host of a URL, when it has one.
fn host(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let host = rest.split(['/', '?', '#']).next()?;
    let host = host.rsplit('@').next()?;
    (!host.is_empty()).then(|| host.to_owned())
}

/// A new permission's id: `p` and six hex digits.
pub fn new_id() -> String {
    let mut bytes = [0u8; 3];
    getrandom::fill(&mut bytes).expect("the system's random source works");
    format!("p{}", hex::encode(bytes))
}

/// A new rule's id: `r` and eight hex digits.
pub fn new_rule_id() -> String {
    let mut bytes = [0u8; 4];
    getrandom::fill(&mut bytes).expect("the system's random source works");
    format!("r{}", hex::encode(bytes))
}

/// What `home/permissions.json` keeps.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Kept {
    /// Settings › Permissions: the mode new jobs get; bypass until the owner picks another.
    #[serde(default)]
    pub mode: Option<String>,
    /// The saved rules, oldest first.
    #[serde(default)]
    pub rules: Vec<Rule>,
}

impl Kept {
    pub fn default_mode(&self) -> Mode {
        self.mode
            .as_deref()
            .and_then(Mode::parse)
            .unwrap_or(Mode::Bypass)
    }
}

pub fn path(home: &Path) -> PathBuf {
    home.join("permissions.json")
}

/// What `home` keeps, or nothing yet. A file that doesn't read is logged and taken as empty.
pub fn load(home: &Path) -> Kept {
    match std::fs::read(path(home)) {
        Err(_) => Kept::default(),
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
            tracing::warn!("{} doesn't read: {e}", path(home).display());
            Kept::default()
        }),
    }
}

pub fn save(home: &Path, kept: &Kept) -> std::io::Result<()> {
    let text = serde_json::to_vec_pretty(kept).map_err(std::io::Error::other)?;
    crate::store::write_private(&path(home), &text)
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORKTREE: &str = "/tmp/oby/jobs/abc";

    fn bash(command: &str) -> Call {
        Call {
            tool: "Bash".into(),
            command: Some(command.into()),
            ..Call::default()
        }
    }

    fn tool(tool: &str, paths: &[&str]) -> Call {
        Call {
            tool: tool.into(),
            paths: paths.iter().map(|p| p.to_string()).collect(),
            ..Call::default()
        }
    }

    fn rule(rule: &str, decision: &str) -> Rule {
        Rule {
            id: rule.into(),
            rule: rule.into(),
            repo: "deskree-inc/oby".into(),
            decision: decision.into(),
            created: 0,
        }
    }

    fn decide_in(call: &Call, mode: Mode, rules: &[Rule]) -> Verdict {
        decide(call, mode, rules, Path::new(WORKTREE))
    }

    /// PermissionTests.eachModeAllowsOrAsks.
    #[test]
    fn each_mode_allows_or_asks() {
        let calls = [
            tool("Read", &["/tmp/oby/jobs/abc/a.swift"]),
            tool("Grep", &[]),
            tool("Glob", &[]),
            tool("mcp__tetrix__get_entity", &[]),
            tool("Edit", &["/tmp/oby/jobs/abc/Engine/Jobs.swift"]),
            tool("Write", &["/tmp/oby/jobs/abc/new.swift"]),
            bash("swift test"),
            Call {
                tool: "WebFetch".into(),
                url: Some("https://example.com".into()),
                ..Call::default()
            },
        ];
        let plan = Verdict::Deny(PLAN_ONLY.into());
        use Verdict::{Allow as A, Ask as Q};
        for (mode, verdicts) in [
            (Mode::Ask, vec![A, A, A, A, Q, Q, Q, Q]),
            (Mode::AcceptEdits, vec![A, A, A, A, A, A, Q, Q]),
            (Mode::Plan, vec![A, A, A, A, plan.clone(), plan, Q, Q]),
            (Mode::Bypass, vec![A, A, A, A, A, A, A, A]),
        ] {
            let got: Vec<Verdict> = calls.iter().map(|c| decide_in(c, mode, &[])).collect();
            assert_eq!(got, verdicts, "{mode:?}");
        }
        for helper in ["Agent", "Task", "TodoWrite"] {
            for mode in Mode::ALL {
                assert_eq!(decide_in(&tool(helper, &[]), mode, &[]), Verdict::Allow);
            }
        }
        assert_eq!(Mode::parse("acceptEdits"), Some(Mode::AcceptEdits));
        assert_eq!(Mode::parse("nope"), None);
    }

    /// PermissionTests.rulesDenyBeatsAllow.
    #[test]
    fn rules_deny_beats_allow() {
        let allow = rule("Bash(swift test:*)", "allow");
        let deny = rule("Bash(swift test --filter Slow:*)", "deny");
        let ask = |c: &str, rules: &[Rule]| decide_in(&bash(c), Mode::Ask, rules);
        assert_eq!(
            ask(
                "swift test --filter SpeechTests",
                std::slice::from_ref(&allow)
            ),
            Verdict::Allow
        );
        assert_eq!(
            ask("swift test", std::slice::from_ref(&allow)),
            Verdict::Allow
        );
        assert_eq!(
            ask("swift testing", std::slice::from_ref(&allow)),
            Verdict::Ask
        );
        assert_eq!(
            ask("swift test && rm -rf build", std::slice::from_ref(&allow)),
            Verdict::Ask
        );
        assert_eq!(
            ask("swift test | tee log", std::slice::from_ref(&allow)),
            Verdict::Ask
        );
        for mode in Mode::ALL {
            assert!(matches!(
                decide_in(
                    &bash("swift test --filter Slow"),
                    mode,
                    &[allow.clone(), deny.clone()]
                ),
                Verdict::Deny(_)
            ));
        }
        assert!(matches!(
            decide_in(
                &bash("swift build && swift test --filter Slow"),
                Mode::Bypass,
                std::slice::from_ref(&deny)
            ),
            Verdict::Deny(_)
        ));
        let engine = rule("Edit(Engine/*)", "allow");
        assert_eq!(
            decide_in(
                &tool("Edit", &["/tmp/oby/jobs/abc/Engine/Jobs.swift"]),
                Mode::Ask,
                std::slice::from_ref(&engine)
            ),
            Verdict::Allow
        );
        assert_eq!(
            decide_in(
                &tool("Edit", &["/tmp/oby/jobs/abc/Mac/App.swift"]),
                Mode::Ask,
                std::slice::from_ref(&engine)
            ),
            Verdict::Ask
        );
        let touch = rule("Bash(touch:*)", "allow");
        assert_eq!(
            decide_in(
                &bash("touch a.swift"),
                Mode::Ask,
                std::slice::from_ref(&touch)
            ),
            Verdict::Allow
        );
        assert_eq!(
            decide_in(
                &bash("touch a.swift"),
                Mode::Plan,
                std::slice::from_ref(&touch)
            ),
            Verdict::Ask
        );
    }

    /// PermissionTests.theCardSaysWhatAndWhichRule.
    #[test]
    fn the_card_says_what_and_which_rule() {
        assert_eq!(
            prefix("swift test --filter SpeechTests").as_deref(),
            Some("swift test")
        );
        assert_eq!(prefix("ls -la").as_deref(), Some("ls"));
        assert_eq!(prefix("cat Package.swift").as_deref(), Some("cat"));
        assert_eq!(prefix("swift build && swift test"), None);
        assert_eq!(prefix("FOO=1 swift test"), None);
        for command in [
            "bash -c 'rm -rf ~'",
            "sh -c ls",
            "python3 -c 'print(1)'",
            "/usr/bin/python3.12 x.py",
            "node -e 1",
            "env FOO=1 make",
            "sudo ls",
            "xargs rm",
            "uv run anything",
            "npm exec foo",
            "bundle exec rake",
        ] {
            assert_eq!(prefix(command), None, "{command}");
        }
        let old: Vec<Rule> = [
            "Bash(python3:*)",
            "Bash(env:*)",
            "Bash(bash:*)",
            "Bash(uv run:*)",
            "Bash",
        ]
        .iter()
        .map(|r| rule(r, "allow"))
        .collect();
        for command in [
            "python3 x.py",
            "/usr/bin/python3.12 x.py",
            "env FOO=1 make",
            "FOO=1 bash -c ls",
            "uv run x.py",
        ] {
            assert_eq!(
                decide_in(&bash(command), Mode::Ask, &old),
                Verdict::Ask,
                "{command}"
            );
        }
        assert_eq!(
            decide_in(&bash("swift test"), Mode::Ask, &old),
            Verdict::Allow
        );
        assert!(matches!(
            decide_in(
                &bash("python3 x.py"),
                Mode::Bypass,
                &[rule("Bash(python3:*)", "deny")]
            ),
            Verdict::Deny(_)
        ));
        let worktree = Path::new(WORKTREE);
        let wrapped = card(
            &bash("python3 -c 'import os'"),
            "p1",
            "deskree-inc/oby",
            worktree,
        );
        assert_eq!(
            (wrapped.rule, wrapped.always, wrapped.title.as_str()),
            (None, None, "Run python3 -c 'import os'")
        );
        assert_eq!(
            card(
                &bash("swift test --filter SpeechTests"),
                "p1",
                "deskree-inc/oby",
                worktree
            ),
            Permission {
                id: "p1".into(),
                tool: "Bash".into(),
                title: "Run swift test".into(),
                detail: "swift test --filter SpeechTests".into(),
                rule: Some("Bash(swift test:*)".into()),
                always: Some("Yes, and don't ask again for swift test in deskree-inc/oby".into()),
            }
        );
        let chained = card(
            &bash("swift build && swift test"),
            "p2",
            "deskree-inc/oby",
            worktree,
        );
        assert_eq!(
            (chained.rule, chained.title.as_str()),
            (None, "Run swift build && swift test")
        );
        let edit = card(
            &tool("Edit", &["/tmp/oby/jobs/abc/Engine/Jobs.swift"]),
            "p3",
            "deskree-inc/oby",
            worktree,
        );
        assert_eq!(
            (
                edit.title.as_str(),
                edit.detail.as_str(),
                edit.rule.as_deref()
            ),
            ("Edit Jobs.swift", "Engine/Jobs.swift", Some("Edit"))
        );
        let fetch = card(
            &Call {
                tool: "WebFetch".into(),
                url: Some("https://example.com/a".into()),
                ..Call::default()
            },
            "p4",
            "o/r",
            worktree,
        );
        assert_eq!(fetch.title, "Fetch example.com");
    }

    #[test]
    fn inbox_answers() {
        assert_eq!(inbox_decision("Allow"), (Decision::Allow, None));
        assert_eq!(inbox_decision("Always allow"), (Decision::Always, None));
        assert_eq!(inbox_decision("Deny"), (Decision::Deny, None));
        assert_eq!(
            inbox_decision("No, run only RunnerTests"),
            (Decision::Deny, Some("No, run only RunnerTests".into()))
        );
        assert!(new_id().starts_with('p') && new_id().len() == 7);
    }
}
