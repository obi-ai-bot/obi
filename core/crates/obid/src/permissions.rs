//! Permission modes (docs/runner-api.md, "Permission modes", Engine/Permissions.swift): how much a
//! job asks its owner. Whatever the mode, obid's fixed denials come first (`crate::policy`: no
//! publishing, the worktree only, no background work, only Tetrix's reads among MCP tools); then
//! the owner's saved rules for the repository (deny beats allow); then the mode allows, refuses or
//! asks. Reads and the agent's own bookkeeping never ask, except in Sandbox mode (the default),
//! where obid answers whatever stays inside the job's OS sandbox and asks only about what leaves
//! it or sticks (`reach`).
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
    /// obid answers everything by its rules, the network and secrets too.
    Bypass,
    /// obid answers what stays inside the job's OS sandbox (edits in the worktree, commands, tests,
    /// reads) by its rules and records it on the job; it asks about what leaves the sandbox
    /// (the network beyond the model's API, secrets and the vault, a read outside the worktree):
    /// the default.
    Sandbox,
}

impl Mode {
    pub const ALL: [Mode; 5] = [
        Mode::Ask,
        Mode::AcceptEdits,
        Mode::Plan,
        Mode::Bypass,
        Mode::Sandbox,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Ask => "ask",
            Mode::AcceptEdits => "acceptEdits",
            Mode::Plan => "plan",
            Mode::Bypass => "bypass",
            Mode::Sandbox => "sandbox",
        }
    }

    /// "Accept edits", as steps say it.
    pub fn title(self) -> &'static str {
        match self {
            Mode::Ask => "Ask",
            Mode::AcceptEdits => "Accept edits",
            Mode::Plan => "Plan",
            Mode::Bypass => "Bypass",
            Mode::Sandbox => "Sandbox",
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
    /// What a search or listing looks at (`path`, a glob), as the agent named it.
    pub reads: Vec<String>,
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
            reads: ["path", "pattern", "glob"]
                .iter()
                // A Grep's pattern is a regular expression, not a place.
                .filter(|key| !(tool == "Grep" && **key == "pattern"))
                .filter_map(|key| text(key))
                .collect(),
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
    /// Why it asks when the job's mode would have answered it, like "It reaches the network beyond
    /// the model's API."; none otherwise.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
}

/// A permission obid answered by its own rules, without the owner, kept on the job (`answered`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Answered {
    pub id: String,
    pub tool: String,
    /// "Run cargo test", "Edit permissions.rs".
    pub title: String,
    /// The command, the files or the address, cut to [`DETAIL_CAP`] characters.
    pub detail: String,
    /// `allowed` or `refused`.
    pub decision: String,
    /// Why it was refused, in the words the agent heard; none when allowed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Seconds since the epoch.
    pub at: i64,
}

/// How many answers a job keeps, newest last; `answeredCount` counts them all.
pub const KEPT_ANSWERED: usize = 50;

/// How much of a command a kept answer holds.
const DETAIL_CAP: usize = 300;

impl Answered {
    /// `answer` to `call`, as the job's page says it.
    pub fn of(
        call: &Call,
        repo: &str,
        worktree: &Path,
        refused: Option<&str>,
        at: i64,
    ) -> Answered {
        let card = card(call, &new_id(), repo, worktree);
        Answered {
            id: card.id,
            tool: card.tool,
            title: card.title,
            detail: card.detail.chars().take(DETAIL_CAP).collect(),
            decision: if refused.is_some() {
                "refused"
            } else {
                "allowed"
            }
            .into(),
            reason: refused.map(str::to_owned),
            at,
        }
    }

    pub fn to_json(&self) -> Value {
        let mut value = json!({"id": self.id, "tool": self.tool, "title": self.title,
                               "detail": self.detail, "decision": self.decision,
                               "at": obi_protocol::time::format(self.at)});
        if let Some(reason) = &self.reason {
            value["reason"] = json!(reason);
        }
        value
    }
}

/// Whether obid's answer to `tool` is worth the owner's seeing: the agent's own bookkeeping isn't.
pub fn is_noted(tool: &str) -> bool {
    !matches!(tool, "ExitPlanMode" | "Task" | "Agent" | "TodoWrite")
}

/// `entry` added to a job's answers, which keep the latest [`KEPT_ANSWERED`].
pub fn keep_answered(kept: &mut Vec<Answered>, count: &mut u32, entry: Answered) {
    kept.push(entry);
    *count += 1;
    if kept.len() > KEPT_ANSWERED {
        kept.drain(..kept.len() - KEPT_ANSWERED);
    }
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

/// What makes a call leave the job's OS sandbox or stick, so Sandbox mode asks the owner about it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    /// Secrets, the vault or a login: never covered by a saved allow rule, never saved as one.
    Secrets,
    /// The network beyond the model's API: a download, an install, a web page.
    Network,
    /// A read outside the job's worktree.
    Outside,
    /// A tool obid doesn't know stays inside the sandbox.
    Unknown,
}

impl Reach {
    pub fn why(self) -> &'static str {
        match self {
            Reach::Secrets => "It touches secrets or the vault.",
            Reach::Network => "It reaches the network beyond the model's API.",
            Reach::Outside => "It reads outside the job's worktree.",
            Reach::Unknown => "obid doesn't know this tool stays inside the job's sandbox.",
        }
    }
}

/// Tools that look at files without changing them.
const READS: &[&str] = &["Read", "Grep", "Glob", "LS", "NotebookRead"];

/// Programs that reach the network whatever follows them.
const NETWORK_PROGRAMS: &[&str] = &[
    "curl",
    "wget",
    "nc",
    "ncat",
    "netcat",
    "telnet",
    "ssh",
    "scp",
    "sftp",
    "rsync",
    "ftp",
    "socat",
    "nmap",
    "dig",
    "nslookup",
    "ping",
    "traceroute",
    "aria2c",
    "http",
    "xh",
    "gh",
    "npx",
    "gem",
    "apt",
    "apt-get",
];

/// What comes before the program a command runs: a shell or a wrapper (its flags and its numbers
/// are skipped too).
const WRAPPERS: &[&str] = &[
    "sh", "bash", "zsh", "dash", "ksh", "sudo", "doas", "env", "time", "nohup", "timeout", "nice",
    "ionice", "xargs", "exec", "command", "builtin", "stdbuf", "watch", "setsid",
];

/// Tools and the subcommands of theirs that download or install (`npm install`, `cargo add`).
/// An empty list is every subcommand.
const NETWORK_AFTER: &[(&str, &[&str])] = &[
    (
        "npm",
        &[
            "install", "i", "ci", "add", "update", "upgrade", "publish", "exec", "create",
        ],
    ),
    (
        "pnpm",
        &[
            "install", "i", "add", "update", "up", "upgrade", "publish", "dlx", "create",
        ],
    ),
    (
        "yarn",
        &[
            "install", "add", "up", "upgrade", "publish", "dlx", "create",
        ],
    ),
    ("bun", &["install", "i", "add", "update", "x", "create"]),
    (
        "cargo",
        &[
            "install", "add", "fetch", "update", "publish", "search", "login",
        ],
    ),
    ("go", &["get", "install"]),
    ("pip", &["install", "download"]),
    ("pip3", &["install", "download"]),
    ("uv", &["add", "sync", "pip", "tool", "lock"]),
    ("poetry", &["add", "install", "update", "lock"]),
    ("bundle", &["install", "update", "add"]),
    (
        "git",
        &["clone", "fetch", "pull", "ls-remote", "submodule", "remote"],
    ),
    ("docker", &[]),
    ("podman", &[]),
    (
        "brew",
        &["install", "update", "upgrade", "reinstall", "tap"],
    ),
    ("dotnet", &["restore", "add"]),
    ("mix", &["deps.get", "deps.update"]),
    ("composer", &[]),
    ("dnf", &[]),
    ("yum", &[]),
    ("conda", &["install", "update", "create"]),
];

/// Whether `command` reaches the network: a client, an install, a clone. Matching words is
/// best-effort, like publishing's (`crate::policy`): the job sandbox is what confines the files,
/// and a script that opens a socket itself isn't caught here. Each chained command is looked at,
/// through the wrappers before it (`sudo`, `timeout 5`, a quoted `bash -c`).
fn uses_network(command: &str) -> bool {
    let flat = command.replace(['\'', '"', '`', '(', ')', '{', '}'], " ");
    flat.split(['|', ';', '&', '<', '>', '\n']).any(|piece| {
        let words: Vec<&str> = piece
            .split_whitespace()
            .skip_while(|w| {
                is_assignment(w)
                    || w.starts_with('-')
                    || w.chars().all(|c| c.is_ascii_digit())
                    || WRAPPERS.contains(&w.rsplit('/').next().unwrap_or(w))
            })
            .collect();
        let Some(first) = words.first() else {
            return false;
        };
        let program = first.rsplit('/').next().unwrap_or(first);
        if NETWORK_PROGRAMS.contains(&program) {
            return true;
        }
        let Some((_, subcommands)) = NETWORK_AFTER.iter().find(|(name, _)| *name == program) else {
            return false;
        };
        // The subcommand: after the tool's own options, and the values of git's `-C` and `-c`.
        let mut rest = words[1..].iter();
        let mut next = None;
        while let Some(word) = rest.next() {
            if program == "git" && matches!(*word, "-C" | "-c") {
                rest.next();
            } else if !word.starts_with('-') {
                next = Some(*word);
                break;
            }
        }
        subcommands.is_empty() || next.is_some_and(|n| subcommands.contains(&n))
    })
}

/// Names that say a file holds secrets or a login, wherever it is.
const SECRET_NAMES: &[&str] = &[
    "api-token",
    "credentials.json",
    ".credentials",
    "id_rsa",
    "id_ed25519",
    ".netrc",
    ".npmrc",
    ".pypirc",
    ".git-credentials",
    "/proc/self/environ",
];

/// Folders that hold secrets or a login.
const SECRET_FOLDERS: &[&str] = &[".ssh", ".aws", ".gnupg", ".kube", ".docker"];

/// Whether `text` (a command, a path or an address) names a secret, a login or the vault: a
/// well-known file or folder, an `.env` file, or a value the vault keeps, in any form.
fn names_a_secret(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    if SECRET_NAMES.iter().any(|name| lower.contains(name))
        || lower.contains("printenv")
        || lower.contains("security find-")
        || lower.contains("gh auth")
    {
        return true;
    }
    for word in
        lower.split(|c: char| c.is_whitespace() || matches!(c, '\'' | '"' | '=' | ':' | ','))
    {
        if word.split('/').any(|part| SECRET_FOLDERS.contains(&part)) {
            return true;
        }
        let name = word.rsplit('/').next().unwrap_or(word);
        if name == ".env"
            || (name.starts_with(".env.")
                && !name.ends_with(".example")
                && !name.ends_with(".sample")
                && !name.ends_with(".template"))
        {
            return true;
        }
    }
    // A vault value inside the text comes out redacted. When the vault can't be read, ask.
    crate::vault::for_agent(text).map_or(true, |clean| clean != text)
}

/// What takes `call` out of the job's sandbox, or none when it stays inside: the files of the
/// worktree, commands, tests. Reads and searches look only at the worktree (`crate::policy`).
pub fn reach(call: &Call, worktree: &Path) -> Option<Reach> {
    let tool = call.tool.as_str();
    let mut texts: Vec<&str> = call.paths.iter().map(String::as_str).collect();
    texts.extend(call.reads.iter().map(String::as_str));
    texts.extend(call.command.as_deref());
    texts.extend(call.url.as_deref());
    if texts.iter().any(|t| names_a_secret(t)) {
        return Some(Reach::Secrets);
    }
    match tool {
        "WebFetch" | "WebSearch" => Some(Reach::Network),
        "Bash" => call
            .command
            .as_deref()
            .is_some_and(uses_network)
            .then_some(Reach::Network),
        _ if EDITS.contains(&tool) || READS.contains(&tool) => call
            .paths
            .iter()
            .chain(&call.reads)
            .any(|p| !crate::policy::path_inside(p, worktree))
            .then_some(Reach::Outside),
        "ExitPlanMode" | "Task" | "Agent" | "TodoWrite" => None,
        _ if tool.starts_with("mcp__") => None,
        _ => Some(Reach::Unknown),
    }
}

/// The mode's answer to `call`, after the owner's saved `rules` for the job's repository. obid's
/// fixed denials (`crate::policy`) come before this, in every mode.
pub fn decide(call: &Call, mode: Mode, rules: &[Rule], worktree: &Path) -> Verdict {
    let sandbox = mode == Mode::Sandbox;
    let reach = if sandbox { reach(call, worktree) } else { None };
    // The plan's own end: in Plan the agent finishes with it, in any other mode there's nothing to
    // approve. Reads never ask, but in Sandbox mode one that leaves the worktree does.
    if call.tool == "ExitPlanMode" || (QUIET.contains(&call.tool.as_str()) && reach.is_none()) {
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
    // Plan changes nothing: a saved allow rule doesn't let a command through while planning. And
    // no rule lets secrets through in Sandbox mode: the owner answers those one at a time.
    if mode != Mode::Plan
        && reach != Some(Reach::Secrets)
        && rules
            .iter()
            .any(|r| r.decision == "allow" && matches(&r.rule, call, worktree, true))
    {
        return Verdict::Allow;
    }
    match mode {
        Mode::Bypass => Verdict::Allow,
        Mode::Sandbox if reach.is_none() => Verdict::Allow,
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
    let why = reach(call, worktree);
    let (title, detail, mut rule, mut what) = match family(&call.tool) {
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
                .or_else(|| {
                    let looked: Vec<&str> = call
                        .paths
                        .iter()
                        .chain(&call.reads)
                        .map(String::as_str)
                        .collect();
                    (!looked.is_empty()).then(|| looked.join(", "))
                })
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
    // Secrets are answered one at a time, never by a rule that would cover the next.
    if why == Some(Reach::Secrets) {
        rule = None;
        what = None;
    }
    Permission {
        id: id.to_owned(),
        tool: call.tool.clone(),
        title,
        detail,
        rule,
        always: what.map(|w| format!("Yes, and don't ask again for {w} in {repo}")),
        why: why.map(|r| r.why().to_owned()),
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
    /// Settings › Permissions: the mode new jobs get; sandbox until the owner picks another.
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
            .unwrap_or(Mode::Sandbox)
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
                why: None,
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

    /// Sandbox mode: what stays inside the job's sandbox is answered; the network, secrets and a
    /// read outside the worktree ask, and no saved rule lets secrets through.
    #[test]
    fn sandbox_mode_asks_only_about_what_leaves_the_sandbox() {
        let inside = [
            bash("cargo test --workspace"),
            bash("npm test"),
            bash("make lint && cargo fmt --all -- --check"),
            bash("python3 -m pytest tests"),
            bash("git status"),
            bash("git commit -m hello"),
            bash("grep -rn curl src"),
            bash("cargo test ping"),
            tool("Edit", &["/tmp/oby/jobs/abc/Engine/Jobs.swift"]),
            tool("Write", &["new.swift"]),
            tool("Read", &["/tmp/oby/jobs/abc/a.swift"]),
            tool("Read", &["src/a.swift"]),
            tool("Edit", &["docs/.env.example"]),
            tool("mcp__tetrix__get_entity", &[]),
            tool("TodoWrite", &[]),
        ];
        for call in &inside {
            assert_eq!(
                decide_in(call, Mode::Sandbox, &[]),
                Verdict::Allow,
                "{call:?}"
            );
        }
        let search = |tool: &str, key: &str, value: &str| {
            Call::new(tool, &serde_json::json!({ key: value }))
        };
        let leaves = [
            (bash("curl https://example.com"), Reach::Network),
            (bash("npm install left-pad"), Reach::Network),
            (bash("cargo add serde"), Reach::Network),
            (bash("pip3 install requests"), Reach::Network),
            (bash("git fetch origin"), Reach::Network),
            (bash("git -C sub pull"), Reach::Network),
            (bash("cargo test && wget x"), Reach::Network),
            (bash("bash -c 'cd a && curl x'"), Reach::Network),
            (bash("timeout 5 ssh host"), Reach::Network),
            (bash("FOO=1 docker pull alpine"), Reach::Network),
            (
                Call {
                    tool: "WebFetch".into(),
                    url: Some("https://example.com".into()),
                    ..Call::default()
                },
                Reach::Network,
            ),
            (tool("WebSearch", &[]), Reach::Network),
            (bash("cat ~/.ssh/id_rsa"), Reach::Secrets),
            (bash("cat /h/api-token"), Reach::Secrets),
            (bash("printenv"), Reach::Secrets),
            (bash("cat .env"), Reach::Secrets),
            (tool("Edit", &[".env.production"]), Reach::Secrets),
            (
                tool("Read", &["/tmp/oby/jobs/abc/.aws/credentials"]),
                Reach::Secrets,
            ),
            (tool("Read", &["/etc/hosts"]), Reach::Outside),
            (tool("Read", &["../other/a.swift"]), Reach::Outside),
            (search("Grep", "path", "/etc"), Reach::Outside),
            (search("Glob", "pattern", "/etc/*"), Reach::Outside),
            (search("Glob", "pattern", "../*"), Reach::Outside),
            (search("LS", "path", "~"), Reach::Outside),
            (tool("SomethingNew", &[]), Reach::Unknown),
        ];
        for (call, reach) in &leaves {
            assert_eq!(
                decide_in(call, Mode::Sandbox, &[]),
                Verdict::Ask,
                "{call:?}"
            );
            assert_eq!(
                super::reach(call, Path::new(WORKTREE)),
                Some(*reach),
                "{call:?}"
            );
        }
        // A grep's pattern isn't a place to read.
        assert_eq!(
            decide_in(
                &search("Grep", "pattern", "/etc/passwd"),
                Mode::Sandbox,
                &[]
            ),
            Verdict::Allow
        );
        // A saved rule the owner made covers the network (their decision), never secrets.
        let curl = rule("Bash(curl:*)", "allow");
        assert_eq!(
            decide_in(&bash("curl https://example.com"), Mode::Sandbox, &[curl]),
            Verdict::Allow
        );
        let cat = rule("Bash(cat:*)", "allow");
        assert_eq!(
            decide_in(&bash("cat ~/.ssh/id_rsa"), Mode::Sandbox, &[cat]),
            Verdict::Ask
        );
        // A deny rule still refuses.
        assert!(matches!(
            decide_in(
                &bash("cargo test"),
                Mode::Sandbox,
                &[rule("Bash(cargo test:*)", "deny")]
            ),
            Verdict::Deny(_)
        ));
        // The other modes are as they were: Bypass lets the network go, Accept edits asks.
        assert_eq!(
            decide_in(&bash("curl https://example.com"), Mode::Bypass, &[]),
            Verdict::Allow
        );
        assert_eq!(
            decide_in(&bash("cargo test"), Mode::AcceptEdits, &[]),
            Verdict::Ask
        );
        // The card says why it asks, and offers no rule for a secret.
        let worktree = Path::new(WORKTREE);
        let net = card(&bash("npm install left-pad"), "p1", "o/r", worktree);
        assert_eq!(
            net.why.as_deref(),
            Some("It reaches the network beyond the model's API.")
        );
        assert_eq!(net.rule.as_deref(), Some("Bash(npm install:*)"));
        let secret = card(&bash("cat ~/.ssh/id_rsa"), "p2", "o/r", worktree);
        assert_eq!(
            (secret.rule, secret.always, secret.why.as_deref()),
            (None, None, Some("It touches secrets or the vault."))
        );
        assert_eq!(Mode::parse("sandbox"), Some(Mode::Sandbox));
        assert_eq!(Kept::default().default_mode(), Mode::Sandbox);
    }

    #[test]
    fn answers_are_kept_newest_last_and_counted() {
        let worktree = Path::new(WORKTREE);
        let mut kept = Vec::new();
        let mut count = 0;
        for n in 0..KEPT_ANSWERED + 5 {
            let entry = Answered::of(&bash(&format!("cargo test {n}")), "o/r", worktree, None, 7);
            keep_answered(&mut kept, &mut count, entry);
        }
        assert_eq!(kept.len(), KEPT_ANSWERED);
        assert_eq!(count as usize, KEPT_ANSWERED + 5);
        assert_eq!(kept[0].detail, "cargo test 5");
        let refused = Answered::of(&bash("make deploy"), "o/r", worktree, Some("No."), 7);
        assert_eq!(
            (refused.decision.as_str(), refused.reason.as_deref()),
            ("refused", Some("No."))
        );
        assert!(!is_noted("TodoWrite") && is_noted("Bash"));
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
