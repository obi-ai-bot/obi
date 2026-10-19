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
    /// The command is only a title the agent gave (`"seen": false`, Cursor without a command).
    pub unseen: bool,
    /// The plan `ExitPlanMode` presents, as the agent wrote it.
    pub plan: Option<String>,
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
            unseen: input.get("seen").and_then(Value::as_bool) == Some(false),
            plan: text("plan").filter(|_| tool == "ExitPlanMode"),
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

impl Permission {
    /// Whether it touches secrets, a login or the vault: the owner answers it one at a time, and
    /// never the brain (#586).
    pub fn is_secret(&self) -> bool {
        self.why.as_deref() == Some(Reach::Secrets.why())
    }

    /// Whether it's the agent's plan in Plan mode (`ExitPlanMode`): only the owner approves it or
    /// sends it back, never the brain, a rule or a new mode (#609).
    pub fn is_plan(&self) -> bool {
        self.tool == "ExitPlanMode"
    }
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
        bounds: &Bounds,
        refused: Option<&str>,
        at: i64,
    ) -> Answered {
        let card = card(call, &new_id(), repo, bounds);
        Answered {
            id: card.id,
            tool: card.tool,
            title: card.title,
            detail: scrubbed(&card.detail).chars().take(DETAIL_CAP).collect(),
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

/// `detail` as the job's record keeps it: a login in an address (`https://user:pass@host`) and
/// every word that looks like a token taken out.
fn scrubbed(detail: &str) -> String {
    static LOGIN: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let login = LOGIN.get_or_init(|| regex::Regex::new(r"://[^/\s@]+@").expect("a regex"));
    let detail = login.replace_all(detail, "://");
    detail
        .split(' ')
        .map(|word| {
            if crate::scan::matches(word).is_empty() {
                word.to_owned()
            } else {
                "[redacted]".to_owned()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
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

/// A `plan` item's answers (#609); any other words keep the agent planning, and reach it.
pub const APPROVE: &str = "Approve";
pub const KEEP_PLANNING: &str = "Keep planning";

/// What the agent hears when the owner sends its plan back without words.
pub const PLAN_SENT_BACK: &str =
    "The owner didn't approve the plan yet: keep planning, then present it again.";

/// The decision an inbox answer stands for, and the owner's words for the agent.
pub fn inbox_decision(answer: &str) -> (Decision, Option<String>) {
    match answer.trim().to_lowercase().as_str() {
        "allow" | "yes" | "approve" => (Decision::Allow, None),
        "always allow" => (Decision::Always, None),
        "deny" | "no" | "keep planning" => (Decision::Deny, None),
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

/// How much of a plan its card keeps.
const PLAN_CAP: usize = 20_000;

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
    "bunx",
    "gem",
    "apt",
    "apt-get",
    "pipx",
    "uvx",
    "deno",
    "gradle",
    "gradlew",
    "mvn",
    "mvnw",
    "rustup",
    "psql",
    "mysql",
    "mongosh",
    "redis-cli",
    "kubectl",
    "helm",
    "aws",
    "gcloud",
    "az",
    "terraform",
    "busybox",
    "toybox",
];

/// What comes before the program a command runs (its options and its numbers are skipped too).
/// Shells aren't here: what `bash -c` runs is read as a command of its own ([`simple_commands`]).
const WRAPPERS: &[&str] = &[
    "sudo",
    "doas",
    "env",
    "time",
    "nohup",
    "timeout",
    "nice",
    "ionice",
    "xargs",
    "exec",
    "command",
    "builtin",
    "stdbuf",
    "watch",
    "setsid",
    "caffeinate",
];

/// Shells: `-c` runs the code after it, and a here-document fed to one is code too.
const SHELLS: &[&str] = &["sh", "bash", "zsh", "dash", "ksh", "fish"];

/// Tools and the subcommands of theirs that download or install (`npm install`, `cargo add`).
/// An empty list is every subcommand. git's `remote` and `submodule` are read in [`downloads`].
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
    ("go", &["get", "install", "mod"]),
    ("pip", &["install", "download"]),
    ("pip3", &["install", "download"]),
    ("uv", &["add", "sync", "pip", "tool", "lock"]),
    ("poetry", &["add", "install", "update", "lock"]),
    ("bundle", &["install", "update", "add"]),
    ("git", &["clone", "fetch", "pull", "ls-remote"]),
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

/// How deep obid reads code inside code (`bash -c "$(…)"`); deeper, it asks.
const NESTING: usize = 4;

/// A program's name without its folder: `/usr/bin/curl` is `curl`.
fn base(word: &str) -> &str {
    word.rsplit('/').next().unwrap_or(word)
}

/// The simple commands `command` runs, each as its words with the quotes taken out, read the way
/// a shell reads it, best-effort: split at `|`, `;`, `&`, `(`, `)` and new lines outside quotes,
/// comments dropped. What `$(…)` and backticks run (inside double quotes too), what a shell runs
/// with `-c` or `eval`, and a here-document or here-string fed to a shell are read the same way.
/// Any other here-document and every quoted argument are words, not commands: a commit message
/// that says "run curl" isn't a download. None when the code nests deeper than [`NESTING`].
fn simple_commands(command: &str) -> Option<Vec<Vec<String>>> {
    let mut out = Vec::new();
    read_commands(command, 0, &mut out).then_some(out)
}

/// Where [`simple_commands`] is in a line.
#[derive(Default)]
struct Reader {
    commands: Vec<Vec<String>>,
    words: Vec<String>,
    word: String,
    in_word: bool,
    /// Here-documents waiting for the end of the line: the word that ends one, whether its lines'
    /// tabs are stripped (`<<-`), and the command it feeds.
    heredocs: Vec<(String, bool, usize)>,
    /// The text fed to a command (a here-document's, a here-string), and that command.
    fed: Vec<(String, usize)>,
    /// The next word is a here-string (`<<< word`).
    here_string: bool,
}

impl Reader {
    fn end_word(&mut self) {
        if self.in_word {
            let word = std::mem::take(&mut self.word);
            if std::mem::take(&mut self.here_string) {
                self.fed.push((word, self.commands.len()));
            } else {
                self.words.push(word);
            }
            self.in_word = false;
        }
    }

    fn end_command(&mut self) {
        self.end_word();
        if !self.words.is_empty() {
            self.commands.push(std::mem::take(&mut self.words));
        }
    }
}

/// Adds the simple commands of `text` to `out`, and those of the code inside it; false when it
/// nests deeper than [`NESTING`].
fn read_commands(text: &str, depth: usize, out: &mut Vec<Vec<String>>) -> bool {
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    read_until(&chars, &mut i, None, depth, out)
}

/// Reads the simple commands of `chars` from `*i` into `out`, up to `stop` (the `)` that closes a
/// `$(`, or the backtick that closes one), and leaves `*i` after it. False when the code nests
/// deeper than [`NESTING`].
fn read_until(
    chars: &[char],
    i: &mut usize,
    stop: Option<char>,
    depth: usize,
    out: &mut Vec<Vec<String>>,
) -> bool {
    if depth > NESTING {
        return false;
    }
    let mut r = Reader::default();
    let mut ok = true;
    // Subshells opened inside: their `)` isn't `stop`'s.
    let mut parens = 0usize;
    while *i < chars.len() {
        let c = chars[*i];
        if Some(c) == stop && (c == '`' || parens == 0) {
            *i += 1;
            break;
        }
        match c {
            '\'' => {
                r.in_word = true;
                *i += 1;
                while *i < chars.len() && chars[*i] != '\'' {
                    r.word.push(chars[*i]);
                    *i += 1;
                }
            }
            '"' => {
                r.in_word = true;
                *i += 1;
                while *i < chars.len() && chars[*i] != '"' {
                    match chars[*i] {
                        '\\' if *i + 1 < chars.len() => {
                            r.word.push(chars[*i + 1]);
                            *i += 1;
                        }
                        '$' if chars.get(*i + 1) == Some(&'(') => {
                            *i += 2;
                            ok &= read_until(chars, i, Some(')'), depth + 1, out);
                            continue;
                        }
                        '`' => {
                            *i += 1;
                            ok &= read_until(chars, i, Some('`'), depth + 1, out);
                            continue;
                        }
                        other => r.word.push(other),
                    }
                    *i += 1;
                }
            }
            '\\' => {
                // A backslash before a new line joins the lines.
                if chars.get(*i + 1).is_some_and(|&n| n != '\n') {
                    r.in_word = true;
                    r.word.push(chars[*i + 1]);
                }
                *i += 1;
            }
            '$' if chars.get(*i + 1) == Some(&'(') => {
                *i += 2;
                ok &= read_until(chars, i, Some(')'), depth + 1, out);
                r.in_word = true;
                continue;
            }
            '`' => {
                *i += 1;
                ok &= read_until(chars, i, Some('`'), depth + 1, out);
                r.in_word = true;
                continue;
            }
            '#' if !r.in_word => {
                while *i + 1 < chars.len() && chars[*i + 1] != '\n' {
                    *i += 1;
                }
            }
            ' ' | '\t' => r.end_word(),
            '\n' => {
                r.end_command();
                // The lines of each here-document the line opened, up to the word that ends it.
                for (end, strip, command) in std::mem::take(&mut r.heredocs) {
                    let mut body = String::new();
                    while *i + 1 < chars.len() {
                        let start = *i + 1;
                        let stop = chars[start..]
                            .iter()
                            .position(|&c| c == '\n')
                            .map_or(chars.len(), |n| start + n);
                        let line: String = chars[start..stop].iter().collect();
                        *i = stop;
                        let line = if strip {
                            line.trim_start_matches('\t')
                        } else {
                            &line
                        };
                        if line == end {
                            break;
                        }
                        body.push_str(line);
                        body.push('\n');
                    }
                    r.fed.push((body, command));
                }
            }
            '(' => {
                parens += 1;
                r.end_command();
            }
            ')' => {
                parens = parens.saturating_sub(1);
                r.end_command();
            }
            '|' | ';' | '&' => r.end_command(),
            '<' | '>' => {
                r.end_word();
                if c == '<' && chars.get(*i + 1) == Some(&'<') {
                    if chars.get(*i + 2) == Some(&'<') {
                        r.here_string = true;
                        *i += 3;
                        continue;
                    }
                    *i += 2;
                    let strip = chars.get(*i) == Some(&'-');
                    if strip {
                        *i += 1;
                    }
                    while chars.get(*i).is_some_and(|c| *c == ' ' || *c == '\t') {
                        *i += 1;
                    }
                    let mut end = String::new();
                    while let Some(&d) = chars.get(*i) {
                        if d.is_whitespace() || matches!(d, '|' | ';' | '&' | '(' | ')' | '<' | '>')
                        {
                            break;
                        }
                        if !matches!(d, '\'' | '"' | '\\') {
                            end.push(d);
                        }
                        *i += 1;
                    }
                    r.heredocs.push((end, strip, r.commands.len()));
                    continue;
                }
                // `2>&1`, `<&3`: the `&` names a file descriptor.
                if chars.get(*i + 1) == Some(&'&') {
                    *i += 1;
                }
            }
            other => {
                r.in_word = true;
                r.word.push(other);
            }
        }
        *i += 1;
    }
    r.end_command();
    let mut nested = Vec::new();
    for (text, command) in std::mem::take(&mut r.fed) {
        let feeds_a_shell = r.commands.get(command).is_some_and(|words| {
            program_index(words).is_some_and(|p| SHELLS.contains(&base(&words[p])))
        });
        if feeds_a_shell {
            nested.push(text);
        }
    }
    for words in &r.commands {
        let Some(p) = program_index(words) else {
            continue;
        };
        let program = base(&words[p]);
        let rest = &words[p + 1..];
        // `bash -c '…'`, `sh -ec "…"`: the code after the option.
        if SHELLS.contains(&program)
            && let Some(flag) = rest
                .iter()
                .position(|w| w.starts_with('-') && !w.starts_with("--") && w.contains('c'))
            && let Some(code) = rest.get(flag + 1)
        {
            nested.push(code.clone());
        }
        if program == "eval" {
            nested.push(rest.join(" "));
        }
    }
    out.append(&mut r.commands);
    ok && nested
        .iter()
        .all(|code| read_commands(code, depth + 1, out))
}

/// Where the program of a simple command is, after assignments (`FOO=1`) and wrappers (`sudo`,
/// `timeout 5s`, `env -i`) with their options and numbers.
fn program_index(words: &[String]) -> Option<usize> {
    words.iter().position(|w| {
        let digits = w.trim_end_matches(['s', 'm', 'h', 'd']);
        let number = digits.starts_with(|c: char| c.is_ascii_digit())
            && digits.chars().all(|c| c.is_ascii_digit() || c == '.');
        !(is_assignment(w) || w.starts_with('-') || number || WRAPPERS.contains(&base(w)))
    })
}

/// The subcommand of a tool's command: the first word after the tool's own options, and after the
/// values of git's `-C` and `-c`.
fn subcommand<'a>(program: &str, rest: &'a [String]) -> Option<(usize, &'a str)> {
    let mut i = 0;
    while i < rest.len() {
        let word = rest[i].as_str();
        if program == "git" && matches!(word, "-C" | "-c") {
            i += 2;
        } else if word.starts_with('-') {
            i += 1;
        } else {
            return Some((i, word));
        }
    }
    None
}

/// Whether a simple command reaches the network: a client, an install, a clone, a program obid
/// can't read (`$(echo curl)`, `$c`), or code it runs that obid doesn't read (`python3 -c`,
/// `node -e`, `find -exec`).
fn downloads(words: &[String], bounds: &Bounds) -> bool {
    let Some(p) = program_index(words) else {
        return false;
    };
    // A program named by a variable or a substitution could be anything.
    if words[p].is_empty() || words[p].starts_with('$') {
        return true;
    }
    let program = base(&words[p]);
    let rest = &words[p + 1..];
    let sub = subcommand(program, rest);
    if matches!(program, "npx" | "bunx") {
        // A tool the repository installed runs from it; any other is downloaded first.
        return !sub.is_some_and(|(_, tool)| {
            !tool.contains('/')
                && bounds
                    .worktree
                    .join("node_modules/.bin")
                    .join(tool)
                    .exists()
        });
    }
    if NETWORK_PROGRAMS.contains(&program) {
        return true;
    }
    let has = |flags: &[&str]| rest.iter().any(|w| flags.contains(&w.as_str()));
    let python = program.starts_with("python") || program.starts_with("pypy");
    if python {
        // The interpreter's own options end at `-m <module>` or a script: a `-c` after them is the
        // module's or the script's (`python3 -m pytest -c setup.cfg`).
        for (i, w) in rest.iter().enumerate() {
            match w.as_str() {
                "-c" => return true,
                "-m" => {
                    return rest
                        .get(i + 1)
                        .is_some_and(|m| matches!(m.as_str(), "pip" | "pip3" | "ensurepip"));
                }
                _ if !w.starts_with('-') => break,
                _ => {}
            }
        }
    }
    // Code given inline is code obid doesn't read.
    let inline = match program {
        "node" | "nodejs" | "bun" => has(&["-e", "--eval", "-p", "--print"]),
        "perl" | "ruby" => rest
            .iter()
            .any(|w| w.starts_with('-') && !w.starts_with("--") && w.contains(['e', 'E'])),
        "php" => has(&["-r"]),
        // `find … -exec <program> … ;`: what it runs, read as a command of its own.
        "find" => rest
            .iter()
            .enumerate()
            .filter(|(_, w)| matches!(w.as_str(), "-exec" | "-execdir" | "-ok" | "-okdir"))
            .any(|(i, _)| {
                let run: Vec<String> = rest[i + 1..]
                    .iter()
                    .take_while(|w| !matches!(w.as_str(), ";" | "+"))
                    .cloned()
                    .collect();
                downloads(&run, bounds)
                    || program_index(&run).is_some_and(|p| {
                        SHELLS.contains(&base(&run[p]))
                            && run[p + 1..]
                                .iter()
                                .position(|w| w.starts_with('-') && w.contains('c'))
                                .and_then(|f| run.get(p + 2 + f))
                                .is_none_or(|code| uses_network(code, bounds))
                    })
            }),
        _ => false,
    };
    if inline {
        return true;
    }
    match (program, sub) {
        // A bare `yarn` or `bundle` installs.
        ("yarn" | "bundle", None) => return true,
        ("swift", Some((i, "package"))) => {
            return matches!(
                subcommand(program, &rest[i + 1..]).map(|(_, w)| w),
                Some("resolve" | "update")
            );
        }
        // `git remote -v` and `git submodule status` stay local.
        ("git", Some((i, "remote"))) => {
            return matches!(
                subcommand(program, &rest[i + 1..]).map(|(_, w)| w),
                Some("update" | "show" | "prune")
            );
        }
        ("git", Some((i, "submodule"))) => {
            return matches!(
                subcommand(program, &rest[i + 1..]).map(|(_, w)| w),
                Some("update" | "add" | "foreach")
            );
        }
        _ => {}
    }
    let Some((_, subcommands)) = NETWORK_AFTER.iter().find(|(name, _)| *name == program) else {
        return false;
    };
    subcommands.is_empty() || sub.is_some_and(|(_, s)| subcommands.contains(&s))
}

/// Whether `command` reaches the network: a client, an install, a clone, in any of the simple
/// commands it runs ([`simple_commands`]), or bash's `/dev/tcp` anywhere. Matching words is
/// best-effort, like publishing's (`crate::policy`): neither OS sandbox limits an agent's network
/// yet, and a script that opens a socket itself isn't caught here. Code nested deeper than obid
/// reads asks.
fn uses_network(command: &str, bounds: &Bounds) -> bool {
    command.contains("/dev/tcp")
        || command.contains("/dev/udp")
        || simple_commands(command)
            .is_none_or(|commands| commands.iter().any(|w| downloads(w, bounds)))
}

/// Names that say a file holds secrets or a login, wherever it is.
const SECRET_NAMES: &[&str] = &[
    "api-token",
    "auth.json",
    "credentials.json",
    ".credentials.json",
    "id_rsa",
    "id_ed25519",
    "id_ecdsa",
    "id_dsa",
    ".netrc",
    ".npmrc",
    ".pypirc",
    ".pgpass",
    ".git-credentials",
];

/// `.env` files a repository commits for its tests and local runs: reading the worktree's own,
/// when git has it, doesn't ask (the repository already holds it).
const COMMITTED_ENV: &[&str] = &[".env.test", ".env.development"];

/// Folders that hold secrets or a login.
const SECRET_FOLDERS: &[&str] = &[".ssh", ".aws", ".gnupg", ".kube", ".docker"];

/// Variables that hold a token obid gives a job, or name where the agent's login is.
pub const SECRET_VARIABLES: &[&str] = &[
    "OBY_MCP_TOKEN",
    "OBY_CHECK_TOKEN",
    "OBID_API_TOKEN",
    "CLAUDE_CONFIG_DIR",
    "CODEX_HOME",
    "CURSOR_CONFIG_DIR",
    "GH_TOKEN",
    "GITHUB_TOKEN",
];

/// Folders the job sandbox lets every process read: the system's software and settings, devices.
const SYSTEM_FOLDERS: &[&str] = &[
    "/usr",
    "/bin",
    "/sbin",
    "/lib",
    "/lib32",
    "/lib64",
    "/libx32",
    "/etc",
    "/opt",
    "/nix",
    "/dev",
    "/proc",
    "/sys",
    "/System",
    "/Library",
    "/Applications",
    "/private/etc",
    "/private/var/select",
    "/private/var/run/resolv.conf",
    "/var/run/resolv.conf",
];

/// Where a job's sandbox ends, as [`reach`] sees it: its worktree, its temporary folder, its
/// `HOME` (the temporary folder, or the job's own login folder for Cursor), and the folders that
/// hold its agent's login (its own copy, and the account's folder, which it never gets, #655).
#[derive(Debug, Clone, Default)]
pub struct Bounds {
    pub worktree: PathBuf,
    pub temp: Option<PathBuf>,
    pub home: Option<PathBuf>,
    pub logins: Vec<PathBuf>,
}

impl Bounds {
    /// Only a worktree: a job whose folders obid doesn't know.
    pub fn of(worktree: &Path) -> Bounds {
        Bounds {
            worktree: worktree.to_path_buf(),
            ..Bounds::default()
        }
    }

    /// `word` as a path, `~` and `$HOME` taken as the job's `HOME`; none when it isn't one.
    fn path_of(&self, word: &str, base: &Path) -> Option<PathBuf> {
        let home = |rest: &str| {
            self.home
                .as_ref()
                .map(|h| h.join(rest.trim_start_matches('/')))
        };
        if word == "~" || word == "$HOME" || word == "${HOME}" {
            return self.home.clone();
        }
        if let Some(rest) = word
            .strip_prefix("~/")
            .or_else(|| word.strip_prefix("$HOME/"))
            .or_else(|| word.strip_prefix("${HOME}/"))
        {
            return home(rest);
        }
        if word.starts_with('/') {
            return Some(PathBuf::from(word));
        }
        // A relative word is a path from where the command runs: `cat link/settings.json`, `../x`.
        let plain = !word.is_empty()
            && !word.starts_with('-')
            && !word.contains("://")
            && !word.contains(['$', '`'])
            && !word.contains(char::is_whitespace);
        plain.then(|| base.join(word))
    }

    /// Where `cd` leaves a command that ran from `base`.
    fn cd(&self, words: &[String], base: &Path) -> PathBuf {
        match words.get(1) {
            None => self.home.clone().unwrap_or_else(|| base.to_path_buf()),
            Some(dir) => self
                .path_of(dir, base)
                .unwrap_or_else(|| base.to_path_buf()),
        }
    }

    /// Whether `path` is in the agent's login folders, as written or after links.
    fn in_login(&self, path: &Path) -> bool {
        let real = crate::policy::real_path(path);
        self.logins.iter().any(|login| {
            let login_real = std::fs::canonicalize(login).ok();
            path.starts_with(login)
                || login_real.as_ref().is_some_and(|l| path.starts_with(l))
                || real.as_ref().is_some_and(|r| {
                    r.starts_with(login) || login_real.as_ref().is_some_and(|l| r.starts_with(l))
                })
        })
    }

    /// Whether the job may read `path` without asking: in its worktree or its temporary folder.
    fn holds(&self, path: &str) -> bool {
        crate::policy::path_inside(path, &self.worktree)
            || self
                .temp
                .as_ref()
                .is_some_and(|temp| crate::policy::path_inside(path, temp))
    }
}

/// Whether `text` (a path, an address, a word of a command) names a secret or a login: a
/// well-known file or folder (a glob that could match one too), an `.env` file, the agent's own
/// login folder or a variable naming it, a token variable, a process's environment.
fn names_a_secret(text: &str, bounds: &Bounds, base_dir: &Path) -> bool {
    let lower = text.to_ascii_lowercase();
    if SECRET_VARIABLES
        .iter()
        .any(|v| lower.contains(&v.to_ascii_lowercase()))
        || (lower.contains("/proc/") && lower.ends_with("/environ"))
    {
        return true;
    }
    text.split(['=', ':', ',']).any(|part| {
        let path = bounds.path_of(part, base_dir);
        if path.as_deref().is_some_and(|p| bounds.in_login(p)) {
            return true;
        }
        let place = path.map_or_else(|| part.to_owned(), |p| p.to_string_lossy().into_owned());
        let part = part.to_ascii_lowercase();
        if part
            .split('/')
            .any(|folder| SECRET_FOLDERS.contains(&folder))
        {
            return true;
        }
        let name = base(&part);
        // `.cred*`, `id_*`, `.env*`: a glob that could match a secret's name.
        if let Some(glob) = name.find(['*', '?', '[']) {
            let literal = &name[..glob];
            return literal.len() >= 2
                && (SECRET_NAMES.iter().any(|s| s.starts_with(literal))
                    || ".env".starts_with(literal)
                    || literal.starts_with(".env"));
        }
        if COMMITTED_ENV.contains(&name) {
            return !committed(&place, bounds);
        }
        SECRET_NAMES.contains(&name)
            || name == ".env"
            || (name.starts_with(".env.")
                && !name.ends_with(".example")
                && !name.ends_with(".sample")
                && !name.ends_with(".template"))
    })
}

/// Whether `path` is a file of the worktree's own that git has (`git ls-files`).
fn committed(path: &str, bounds: &Bounds) -> bool {
    if !crate::policy::path_inside(path, &bounds.worktree) {
        return false;
    }
    std::process::Command::new("git")
        .arg("-C")
        .arg(&bounds.worktree)
        .args(["ls-files", "--error-unmatch", "--"])
        .arg(path)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Whether `text` holds a value the vault keeps, in any form the vault finds. When the vault can't
/// be read, it might: ask.
fn holds_a_vault_value(text: &str) -> bool {
    crate::vault::for_agent(text).map_or(true, |clean| clean != text)
}

/// Programs whose first argument is a pattern to look for, not a file.
const SEARCHES: &[&str] = &["grep", "egrep", "fgrep", "rg", "ag", "ack"];

/// The words of a simple command that may name a file: all of them, but what a command only says
/// (a commit's message, the pattern a search looks for). What `echo` prints is read too:
/// `cat $(echo ~/.ssh/id_rsa)` reads the key.
fn file_words(words: &[String]) -> Vec<&String> {
    let Some(p) = program_index(words) else {
        return words.iter().collect();
    };
    let program = base(&words[p]);
    let rest = &words[p + 1..];
    let mut said = vec![false; rest.len()];
    if program == "git" {
        for (i, w) in rest.iter().enumerate() {
            // `-m "…"`, and `-am "…"`: short options run together, the last one `-m`.
            let ends_in_m = w.starts_with('-') && !w.starts_with("--") && w.ends_with('m');
            if (ends_in_m || w == "--message") && i + 1 < rest.len() {
                said[i + 1] = true;
            }
            if w.starts_with("--message=") || (w.starts_with("-m") && w.len() > 2) {
                said[i] = true;
            }
        }
    }
    if SEARCHES.contains(&program) {
        let mut pattern_given = false;
        for (i, w) in rest.iter().enumerate() {
            if matches!(w.as_str(), "-e" | "--regexp") && i + 1 < rest.len() {
                said[i + 1] = true;
                pattern_given = true;
            }
        }
        if !pattern_given && let Some(first) = rest.iter().position(|w| !w.starts_with('-')) {
            said[first] = true;
        }
    }
    words[..=p]
        .iter()
        .chain(rest.iter().zip(&said).filter(|(_, s)| !**s).map(|(w, _)| w))
        .collect()
}

/// Whether a simple command touches secrets or a login: it prints the environment or a keychain's
/// passwords, asks for a code host's login, or names a secret's file ([`names_a_secret`]).
fn reads_a_secret(words: &[String], bounds: &Bounds, base_dir: &Path) -> bool {
    let Some(p) = program_index(words) else {
        // `env` alone prints the environment.
        return words.iter().any(|w| base(w) == "env");
    };
    let program = base(&words[p]);
    let rest = &words[p + 1..];
    let sub = subcommand(program, rest).map(|(_, s)| s);
    match program {
        "printenv" => return true,
        // `set` alone prints every variable, `export -p` the exported ones.
        "set" | "export" | "declare" | "typeset" if rest.iter().all(|w| w.starts_with('-')) => {
            return true;
        }
        "security" if sub.is_some_and(|s| s.starts_with("find-") || s.starts_with("dump-")) => {
            return true;
        }
        "gh" if sub == Some("auth") => return true,
        _ => {}
    }
    file_words(words)
        .into_iter()
        .any(|w| names_a_secret(w, bounds, base_dir))
}

/// Each simple command of `commands` with the folder it runs from: the worktree, then where each
/// `cd` (or `pushd`) before it in the same command line leaves it.
fn with_folders<'a>(commands: &'a [Vec<String>], bounds: &Bounds) -> Vec<(&'a [String], PathBuf)> {
    let mut here = bounds.worktree.clone();
    commands
        .iter()
        .map(|words| {
            let at = here.clone();
            if program_index(words).is_some_and(|p| matches!(base(&words[p]), "cd" | "pushd")) {
                here = bounds.cd(words, &here);
            }
            (words.as_slice(), at)
        })
        .collect()
}

/// Whether `command` touches secrets, a login or the vault, in any of the simple commands it runs
/// or anywhere in its text for a vault value. Code nested deeper than obid reads asks.
fn command_touches_a_secret(command: &str, bounds: &Bounds) -> bool {
    holds_a_vault_value(command)
        || simple_commands(command).is_none_or(|commands| {
            with_folders(&commands, bounds)
                .iter()
                .any(|(words, at)| reads_a_secret(words, bounds, at))
        })
}

/// git settings given on the command line (`git -c key=value`) that can't run a program: any other
/// one could (`core.sshCommand`, `core.fsmonitor`, `core.pager`, `diff.external`, `alias.*`,
/// `credential.helper`, …), so the command asks.
const GIT_SAFE_SETTINGS: &[&str] = &[
    "user.name",
    "user.email",
    "init.defaultbranch",
    "core.quotepath",
    "core.autocrlf",
    "core.safecrlf",
    "commit.gpgsign",
    "tag.gpgsign",
    "pull.rebase",
    "merge.ff",
];

/// Whether a command gives git a setting, or a variable, that can run a program obid doesn't read.
fn runs_through_git_settings(command: &str) -> bool {
    let Some(commands) = simple_commands(command) else {
        return true;
    };
    commands.iter().any(|words| {
        let runs = |name: &str| {
            let name = name.to_ascii_lowercase();
            !(GIT_SAFE_SETTINGS.contains(&name.as_str())
                || name.starts_with("color.")
                || name.starts_with("advice."))
        };
        // `GIT_SSH_COMMAND=…`, `GIT_PAGER=…`, `GIT_CONFIG_PARAMETERS=…` before the program.
        let variables = words.iter().take_while(|w| is_assignment(w)).any(|w| {
            let name = w.split('=').next().unwrap_or_default();
            name.starts_with("GIT_")
                && !matches!(
                    name,
                    "GIT_AUTHOR_NAME"
                        | "GIT_AUTHOR_EMAIL"
                        | "GIT_COMMITTER_NAME"
                        | "GIT_COMMITTER_EMAIL"
                        | "GIT_AUTHOR_DATE"
                        | "GIT_COMMITTER_DATE"
                        | "GIT_PAGER_IN_USE"
                )
        });
        let Some(p) = program_index(words).filter(|p| base(&words[*p]) == "git") else {
            return variables;
        };
        // git's own options, before its subcommand (`git log -c` is a diff's option).
        let mut i = p + 1;
        while let Some(w) = words.get(i).filter(|w| w.starts_with('-')) {
            let setting = match w.as_str() {
                "-c" => Some(words.get(i + 1).map_or("", String::as_str)),
                "-C" => None,
                _ => w.strip_prefix("-c").filter(|kv| !kv.is_empty()),
            };
            if setting.is_some_and(|kv| runs(kv.split('=').next().unwrap_or_default()))
                || w.starts_with("--config-env")
                || w.starts_with("--exec-path=")
            {
                return true;
            }
            i += if matches!(w.as_str(), "-c" | "-C") {
                2
            } else {
                1
            };
        }
        variables
    })
}

/// What [`reach`] reads of a command past the network: whether it names a file outside `bounds`
/// or runs through git's settings. A conversation lets a command reach the web only when neither
/// holds (crate::brain::harness), since `reach` says `Network` first.
pub fn reads_beyond(command: &str, bounds: &Bounds) -> bool {
    runs_through_git_settings(command) || reads_outside(command, bounds)
}

/// Whether a command names a file outside what the job may read without asking: an absolute path
/// (or one from `~`) that isn't in its worktree, its temporary folder or the system's folders.
fn reads_outside(command: &str, bounds: &Bounds) -> bool {
    let Some(commands) = simple_commands(command) else {
        return true;
    };
    with_folders(&commands, bounds).iter().any(|(words, at)| {
        file_words(words).into_iter().any(|word| {
            word.split('=').any(|part| {
                let Some(path) = bounds.path_of(part, at) else {
                    return false;
                };
                // `awk '/x/ {print}'`: a quoted program, not a file.
                if part.contains(char::is_whitespace) {
                    return false;
                }
                if bounds.holds(&path.to_string_lossy()) {
                    return false;
                }
                // A system folder as written (`..` taken out) and after links: `/home` leads into
                // `/System` on macOS, and `../../x` or a link out of the worktree is out.
                let system = |p: &Path| SYSTEM_FOLDERS.iter().any(|f| p.starts_with(f));
                let written: PathBuf = path.components().fold(PathBuf::new(), |mut out, c| {
                    match c {
                        Component::ParentDir => {
                            out.pop();
                        }
                        Component::CurDir => {}
                        other => out.push(other),
                    }
                    out
                });
                let real = crate::policy::real_path(&path).unwrap_or_else(|| written.clone());
                !(system(&written) && system(&real))
            })
        })
    })
}

/// What takes `call` out of the job's sandbox, or none when it stays inside: the files of the
/// worktree and the job's temporary folder, commands, tests.
pub fn reach(call: &Call, bounds: &Bounds) -> Option<Reach> {
    let tool = call.tool.as_str();
    let named = call.paths.iter().chain(&call.reads).chain(call.url.iter());
    let secret = named
        .clone()
        .any(|t| names_a_secret(t, bounds, &bounds.worktree) || holds_a_vault_value(t))
        || call
            .command
            .as_deref()
            .is_some_and(|c| command_touches_a_secret(c, bounds));
    if secret {
        return Some(Reach::Secrets);
    }
    match tool {
        "WebFetch" | "WebSearch" => Some(Reach::Network),
        "Bash" => {
            // Cursor didn't say what it runs, only a title.
            let Some(command) = call
                .command
                .as_deref()
                .filter(|c| !c.trim().is_empty() && !call.unseen)
            else {
                return Some(Reach::Unknown);
            };
            if runs_through_git_settings(command) {
                Some(Reach::Unknown)
            } else if uses_network(command, bounds) {
                Some(Reach::Network)
            } else if reads_outside(command, bounds) {
                Some(Reach::Outside)
            } else {
                None
            }
        }
        // Cursor didn't say what it reads.
        "Read" if call.paths.is_empty() && call.reads.is_empty() => Some(Reach::Unknown),
        _ if EDITS.contains(&tool) || READS.contains(&tool) => call
            .paths
            .iter()
            .chain(&call.reads)
            .any(|p| !bounds.holds(p))
            .then_some(Reach::Outside),
        "ExitPlanMode" | "Task" | "Agent" | "TodoWrite" => None,
        _ if tool.starts_with("mcp__") => None,
        _ => Some(Reach::Unknown),
    }
}

/// The mode's answer to `call`, after the owner's saved `rules` for the job's repository. obid's
/// fixed denials (`crate::policy`) come before this, in every mode.
pub fn decide(call: &Call, mode: Mode, rules: &[Rule], bounds: &Bounds) -> Verdict {
    let worktree = bounds.worktree.as_path();
    // Secrets, a login or the vault: in every mode, only the owner's own answer lets one through
    // (the security review of #586): no mode and no saved rule does, so a mode the brain sets
    // can't settle one. What else leaves the sandbox matters only in Sandbox mode.
    let reach = match reach(call, bounds) {
        Some(Reach::Secrets) => Some(Reach::Secrets),
        other if mode == Mode::Sandbox => other,
        _ => None,
    };
    let secret = reach == Some(Reach::Secrets);
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
    if secret {
        return Verdict::Ask;
    }
    // Plan changes nothing: a saved allow rule doesn't let a command through while planning. And
    // no rule lets secrets through in Sandbox mode: the owner answers those one at a time.
    if mode != Mode::Plan
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
    if let Some(site) = content.strip_prefix("domain:") {
        return call
            .url
            .as_deref()
            .and_then(host)
            .is_some_and(|h| h == site || h.ends_with(&format!(".{site}")));
    }
    if READS.contains(&family(&call.tool)) {
        let places: Vec<&String> = call.paths.iter().chain(&call.reads).collect();
        return !places.is_empty()
            && if allowing {
                places.iter().all(|p| fits(p))
            } else {
                places.iter().any(|p| fits(p))
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
pub fn card(call: &Call, id: &str, repo: &str, bounds: &Bounds) -> Permission {
    let worktree = bounds.worktree.as_path();
    let line = |text: &str, cap: usize| {
        let first = text.split('\n').next().unwrap_or(text);
        if first.chars().count() > cap {
            format!("{}…", first.chars().take(cap - 1).collect::<String>())
        } else {
            first.to_owned()
        }
    };
    let why = reach(call, bounds);
    let (title, detail, mut rule, mut what) = match family(&call.tool) {
        // The agent's plan, as it wrote it: data for the owner to read, with no rule to save.
        "ExitPlanMode" => (
            "Approve the plan?".to_owned(),
            call.plan
                .as_deref()
                .unwrap_or_default()
                .chars()
                .take(PLAN_CAP)
                .collect(),
            None,
            None,
        ),
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
            // "Always" covers what was asked about: a fetch's site, a search's folder.
            let (rule, what) = match tool {
                "WebFetch" => match call.url.as_deref().and_then(host) {
                    Some(site) => (
                        Some(format!("WebFetch(domain:{site})")),
                        Some(format!("fetches from {site}")),
                    ),
                    None => (None, None),
                },
                _ if READS.contains(&tool) => match call.paths.iter().chain(&call.reads).next() {
                    Some(place) => (
                        Some(format!("{tool}({place})")),
                        Some(format!("{tool} in {place}")),
                    ),
                    None => (None, None),
                },
                _ => (Some(tool.to_owned()), Some(tool.to_owned())),
            };
            (title, detail, rule, what)
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
        decide(call, mode, rules, &Bounds::of(Path::new(WORKTREE)))
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
        let worktree = &Bounds::of(Path::new(WORKTREE));
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
                super::reach(call, &Bounds::of(Path::new(WORKTREE))),
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
        let worktree = &Bounds::of(Path::new(WORKTREE));
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

    /// Commands are read as a shell reads them: what a message or a pattern only says doesn't
    /// ask, and code inside code (`$(…)`, backticks, `bash -c`, a here-document fed to a shell)
    /// is read too (#586).
    #[test]
    fn commands_are_read_as_a_shell_reads_them() {
        let worktree = &Bounds::of(Path::new(WORKTREE));
        let commit = "git commit -m \"$(cat <<'EOF'\nfix: don't run curl; ssh keys stay\n- npm install left-pad (no)\n- printenv, .env and ~/.ssh/id_rsa, api-token\nEOF\n)\"";
        let inside = [
            commit,
            "git commit -m \"use wget; curl | ssh\"",
            "git commit -m'mention .env'",
            "git commit -am \"keep .env.local and ~/.ssh out of logs\"",
            "cargo test 2>&1 | tee out.log",
            "git remote -v",
            "git submodule status",
            "grep -rn api-token docs",
            "rg -e '.env' src",
            "sh scripts/check.sh",
            "cat <<EOF > notes.txt\ncurl x\nEOF\ncargo test",
            "timeout 5s cargo test",
            "# curl x\ncargo test",
            "ls src/api-token.rs",
        ];
        for command in inside {
            assert_eq!(super::reach(&bash(command), worktree), None, "{command}");
        }
        let network = [
            "echo \"$(curl -s https://x)\"",
            "echo `wget x`",
            "bash <<EOF\ncurl x\nEOF",
            "bash <<< 'curl x'",
            "sh -ec \"npm install\"",
            "bash -o pipefail -c 'cd a && curl x'",
            "eval curl x",
            "(cd sub && git fetch)",
            "curl \"https://x?a=1&b=2\"",
            "xargs -n1 curl < urls",
            "env FOO=1 timeout 5 ssh host",
            "git remote update",
            "git submodule update --init",
            "cargo test && \\\ncurl x",
            "git commit -m \"$(curl x)\"",
        ];
        for command in network {
            assert_eq!(
                super::reach(&bash(command), worktree),
                Some(Reach::Network),
                "{command}"
            );
        }
        let secrets = [
            "cat \"$CLAUDE_CONFIG_DIR/.credentials.json\"",
            "ls $CODEX_HOME",
            "cat /proc/self/environ",
            "env",
            "export -p",
            "security find-generic-password -s x",
            "gh auth token",
            "source .env && cargo test",
            "cargo run --env-file=.env.local",
            "FILE=~/.aws/credentials cargo test",
            "grep -e x ~/.netrc",
            "cat $(echo ~/.ssh/id_ed25519)",
            // Code nested deeper than obid reads asks, one call at a time.
            "a $(b $(c $(d $(e $(f $(g))))))",
        ];
        for command in secrets {
            assert_eq!(
                super::reach(&bash(command), worktree),
                Some(Reach::Secrets),
                "{command}"
            );
        }
    }

    /// A job's folders on disk for the review's tests: a worktree that is a git repository with a
    /// committed `.env.test` and a local `vitest`, a temporary folder, and an account's folder.
    fn job_folders(name: &str) -> (PathBuf, Bounds) {
        let root = std::env::temp_dir().join(format!("obid-bounds-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let worktree = root.join("worktree");
        let temp = root.join("tmp");
        let account = root.join("accounts/stub");
        for dir in [&worktree.join("node_modules/.bin"), &temp, &account] {
            std::fs::create_dir_all(dir).unwrap();
        }
        std::fs::write(worktree.join("node_modules/.bin/vitest"), "").unwrap();
        std::fs::write(worktree.join(".env.test"), "PORT=1\n").unwrap();
        std::fs::write(worktree.join(".env.development"), "PORT=2\n").unwrap();
        let git = |args: &[&str]| {
            let ran = std::process::Command::new("git")
                .arg("-C")
                .arg(&worktree)
                .args(args)
                .output()
                .unwrap();
            assert!(ran.status.success(), "{ran:?}");
        };
        git(&["init", "-q"]);
        git(&["add", ".env.test"]);
        git(&[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "env",
        ]);
        let bounds = Bounds {
            worktree: worktree.clone(),
            temp: Some(temp.clone()),
            home: Some(temp.clone()),
            logins: vec![account, temp.join(".claude"), temp.join(".codex")],
        };
        (root, bounds)
    }

    /// Security review of #586, S2: what else reaches the network, and what isn't network after
    /// all (a tool the repository installed, run with `npx`).
    #[test]
    fn more_forms_reach_the_network() {
        let (root, bounds) = job_folders("network");
        for command in [
            "$(echo curl) https://x",
            "c=curl; $c https://x",
            "$'\\x63url' https://x",
            "exec 3<>/dev/tcp/1.2.3.4/80",
            "echo hi > /dev/udp/1.2.3.4/53",
            "python3 -m pip install requests",
            "python -m ensurepip",
            "python3 -c 'import urllib.request'",
            "node -e 'fetch(1)'",
            "perl -le 'print 1'",
            "ruby -e 'puts 1'",
            "find . -name x -exec curl {} \\;",
            "yarn",
            "bundle",
            "go mod download",
            "pipx run black",
            "uvx ruff",
            "deno run main.ts",
            "gradle build",
            "./gradlew test",
            "mvn test",
            "rustup update",
            "swift package resolve",
            "psql -h db",
            "redis-cli ping",
            "kubectl get pods",
            "aws s3 ls",
            "gcloud projects list",
            "terraform plan",
            "npx prettier --check .",
        ] {
            assert_eq!(
                super::reach(&bash(command), &bounds),
                Some(Reach::Network),
                "{command}"
            );
        }
        for command in [
            "npx vitest run",
            "yarn test",
            "bundle exec rspec",
            "swift build",
            "python3 -m pytest tests",
            "node --test",
            "find . -name '*.rs'",
        ] {
            assert_eq!(super::reach(&bash(command), &bounds), None, "{command}");
        }
        let _ = std::fs::remove_dir_all(root);
    }

    /// Security review of #586, S2: the agent's own login is named by its real folder, a glob
    /// that could match a login file, a token variable or a bare `set`.
    #[test]
    fn the_real_login_and_tokens_are_secrets() {
        let (root, bounds) = job_folders("secrets");
        let account = root.join("accounts/stub");
        for command in [
            format!("cat {}/auth.json", account.display()),
            format!("ls {}", account.display()),
            format!("cat {}/settings.json", account.display()),
            "cat auth.json".into(),
            "cat ~/.claude/.cred*".into(),
            "ls ~/.claude".into(),
            "cat $HOME/.codex/config.toml".into(),
            "echo $OBY_MCP_TOKEN".into(),
            "curl -H \"Authorization: $OBY_CHECK_TOKEN\" x".into(),
            "set".into(),
        ] {
            assert_eq!(
                super::reach(&bash(&command), &bounds),
                Some(Reach::Secrets),
                "{command}"
            );
        }
        let _ = std::fs::remove_dir_all(root);
    }

    /// Security review of #586, S3: a command that names a file outside the worktree, the job's
    /// temporary folder and the system's folders asks; Cursor's call without its command or its
    /// place asks; a committed `.env.test` and the temporary folder don't.
    #[test]
    fn outside_reads_and_unseen_calls_ask() {
        let (root, bounds) = job_folders("outside");
        let worktree = bounds.worktree.display().to_string();
        let temp = bounds.temp.clone().unwrap().display().to_string();
        for command in [
            "cat /Users/someone/notes.txt",
            "ls /tmp",
            "cp src/a.js /Volumes/usb/a.js",
            "grep -rn TODO /home/other",
            "cargo build --target-dir=/srv/cache",
        ] {
            assert_eq!(
                super::reach(&bash(command), &bounds),
                Some(Reach::Outside),
                "{command}"
            );
        }
        for command in [
            "cat /etc/hosts".to_owned(),
            "ls /usr/bin".into(),
            "cargo test > /dev/null 2>&1".into(),
            format!("cat {worktree}/src/a.js"),
            format!("cat {temp}/out.log"),
            "cat ~/out.log".into(),
            "grep -rn '/etc/passwd' src".into(),
            "git commit -m '/Users/x/notes'".into(),
        ] {
            assert_eq!(super::reach(&bash(&command), &bounds), None, "{command}");
        }
        let grep =
            |path: &str| Call::new("Grep", &serde_json::json!({"pattern": "x", "path": path}));
        assert_eq!(super::reach(&grep(&temp), &bounds), None);
        assert_eq!(super::reach(&grep("/etc"), &bounds), Some(Reach::Outside));
        // Cursor: a title in place of its command, a read with no place.
        let titled = Call::new(
            "Bash",
            &serde_json::json!({"command": "git status", "seen": false}),
        );
        assert_eq!(super::reach(&titled, &bounds), Some(Reach::Unknown));
        let nowhere = Call::new("Read", &serde_json::json!({}));
        assert_eq!(super::reach(&nowhere, &bounds), Some(Reach::Unknown));
        // `.env` files: a committed `.env.test` reads; an untracked `.env.development`, `.npmrc`,
        // `.docker/` and `.kube/` ask.
        let read = |path: &str| Call::new("Read", &serde_json::json!({"file_path": path}));
        assert_eq!(super::reach(&read(".env.test"), &bounds), None);
        assert_eq!(super::reach(&bash("cat .env.test"), &bounds), None);
        for secret in [
            ".env.development",
            ".npmrc",
            ".docker/config.json",
            ".kube/config",
        ] {
            assert_eq!(
                super::reach(&read(secret), &bounds),
                Some(Reach::Secrets),
                "{secret}"
            );
        }
        let _ = std::fs::remove_dir_all(root);
    }

    /// Security review of #586, S4: "always" covers a fetch's site and a search's place, not the
    /// whole tool, and the job's record leaves out a login in an address and a token.
    #[test]
    fn always_covers_a_site_or_a_place_and_the_record_keeps_no_token() {
        let worktree = &Bounds::of(Path::new(WORKTREE));
        let fetch = |url: &str| Call {
            tool: "WebFetch".into(),
            url: Some(url.into()),
            ..Call::default()
        };
        let site_card = card(&fetch("https://docs.example.com/a"), "p1", "o/r", worktree);
        assert_eq!(
            site_card.rule.as_deref(),
            Some("WebFetch(domain:docs.example.com)")
        );
        let site = rule("WebFetch(domain:example.com)", "allow");
        let decided =
            |call: &Call| decide(call, Mode::Sandbox, std::slice::from_ref(&site), worktree);
        assert_eq!(
            decided(&fetch("https://docs.example.com/a")),
            Verdict::Allow
        );
        assert_eq!(decided(&fetch("https://example.com/b")), Verdict::Allow);
        assert_eq!(
            decided(&fetch("https://evil.com/?example.com")),
            Verdict::Ask
        );
        assert_eq!(decided(&fetch("https://notexample.com/")), Verdict::Ask);
        let grep =
            |path: &str| Call::new("Grep", &serde_json::json!({"pattern": "x", "path": path}));
        let place_card = card(&grep("/etc"), "p2", "o/r", worktree);
        assert_eq!(place_card.rule.as_deref(), Some("Grep(/etc)"));
        let place = rule("Grep(/etc)", "allow");
        assert_eq!(
            decide(
                &grep("/etc"),
                Mode::Sandbox,
                std::slice::from_ref(&place),
                worktree
            ),
            Verdict::Allow
        );
        assert_eq!(
            decide(
                &grep("/var"),
                Mode::Sandbox,
                std::slice::from_ref(&place),
                worktree
            ),
            Verdict::Ask
        );
        let token = format!("ghp_{}", "a".repeat(36));
        let recorded = Answered::of(
            &bash(&format!(
                "git clone https://user:hunter2@example.com/r.git && echo {token}"
            )),
            "o/r",
            worktree,
            None,
            7,
        );
        assert!(!recorded.detail.contains("hunter2"), "{}", recorded.detail);
        assert!(!recorded.detail.contains(&token), "{}", recorded.detail);
        assert!(
            recorded.detail.contains("https://example.com/r.git"),
            "{}",
            recorded.detail
        );
    }

    /// Re-review of #586, S2: a secret waits for the owner in every mode, whatever rule is saved,
    /// so a mode the brain sets can't let one through. Other reads still go through.
    #[test]
    fn secrets_wait_for_the_owner_in_every_mode() {
        let worktree = &Bounds::of(Path::new(WORKTREE));
        let read = |path: &str| Call::new("Read", &serde_json::json!({"file_path": path}));
        let edit = |path: &str| tool("Edit", &[path]);
        let rules = [
            rule("Read", "allow"),
            rule("Edit", "allow"),
            rule("Bash(cat:*)", "allow"),
        ];
        for mode in Mode::ALL {
            for call in [
                read(".env"),
                read(".aws/credentials"),
                edit(".env.production"),
                bash("cat ~/.aws/credentials"),
            ] {
                for saved in [&[][..], &rules[..]] {
                    let verdict = decide(&call, mode, saved, worktree);
                    assert_ne!(verdict, Verdict::Allow, "{mode:?} {call:?} {saved:?}");
                }
            }
            assert_eq!(
                decide(&read("src/a.js"), mode, &[], worktree),
                Verdict::Allow,
                "{mode:?}"
            );
        }
    }

    /// Re-review of #586, S3 and S4: relative words are paths from where the command runs (links
    /// followed), git settings that run a program ask, busybox is network; a pytest's `-c` and a
    /// `find -exec rm` aren't.
    #[test]
    fn relative_paths_git_settings_and_what_runs() {
        let (root, bounds) = job_folders("relative");
        let account = root.join("accounts/stub");
        std::fs::write(account.join("settings.json"), "{}").unwrap();
        std::fs::create_dir_all(bounds.worktree.join("src")).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&account, bounds.worktree.join("link")).unwrap();
        for (command, reach) in [
            ("cat link/settings.json", Some(Reach::Secrets)),
            ("cat ../../x", Some(Reach::Outside)),
            ("cd src && cat ../../../x", Some(Reach::Outside)),
            ("cd src && cat ../README.md", None),
            ("cat src/a.js", None),
            ("git -c core.pager=less log", Some(Reach::Unknown)),
            (
                "git -c core.sshCommand='curl x' fetch",
                Some(Reach::Unknown),
            ),
            ("git -c alias.st=status st", Some(Reach::Unknown)),
            ("git -cdiff.external=x diff", Some(Reach::Unknown)),
            ("GIT_SSH_COMMAND=x git status", Some(Reach::Unknown)),
            ("git -c user.name=t -c user.email=t@t commit -m x", None),
            ("git log -c HEAD", None),
            ("busybox wget https://x", Some(Reach::Network)),
            ("python3 -m pytest -c setup.cfg", None),
            ("python3 -c 'print(1)'", Some(Reach::Network)),
            ("find . -name '*.o' -exec rm {} +", None),
            ("find . -exec curl {} \\;", Some(Reach::Network)),
            ("find . -exec sh -c 'curl x' \\;", Some(Reach::Network)),
        ] {
            assert_eq!(super::reach(&bash(command), &bounds), reach, "{command}");
        }
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn answers_are_kept_newest_last_and_counted() {
        let worktree = &Bounds::of(Path::new(WORKTREE));
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
