//! The conversation's shell (docs/runner-api.md, "obid only: the conversation's shell"): Oby's
//! `oby_shell`, `oby_shell_output` and `oby_shell_stop`, shaped like Claude Code's Bash, BashOutput
//! and KillShell. obid runs every command itself, `bash -c` in a box of its own: it writes only the
//! room (never `repos/`) and its own temporary folder, has no account, no login and no network,
//! unless the owner allowed that very command. Not the agent's own Bash or Codex's shell: those
//! run in the agent's box, which reads the session's login copy and has the network.
//!
//! The rules, part by part of a chained command, the strictest deciding: refused (pushing, a path
//! outside the room), the owner's deny rules, always asked (installs and the network, Bypass too;
//! secrets), read-only commands run, the owner's allow rules, then the conversation's mode, which
//! asks after the conversation read something untrusted. Every command taints the turn. An ask is
//! a `permission` inbox item only the owner answers; the command waits for it. Every command ends
//! with its turn.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::{oneshot, watch};

use super::harness::{Place, Session};
use crate::api::Shared;
use crate::permissions::{self, Bounds, Call, Decision, Mode, Reach, Rule};
use crate::sphere::inbox::Item;

/// What the owner's rules for every conversation's shell are saved under, as a repository's are
/// under its name (`GET /v1/permissions/rules`).
pub const RULES_FOR: &str = "conversations";
/// Claude Code's Bash: 2 minutes unless asked, at most 10.
const TIMEOUT_MS: u64 = 120_000;
const MOST_MS: u64 = 600_000;
/// The most of a command's output one answer carries.
const INLINE: usize = 30_000;
/// The most of a conversation's commands running at once.
const RUNNING_MOST: usize = 8;
/// What a step's `output` keeps: the end of what the command wrote.
const STEP_LINES: usize = 20;
const STEP_CHARS: usize = 2_000;
/// The most a command writes before obid stops it.
const LOG_MOST: u64 = 64 * 1024 * 1024;
/// The most of a command the owner's card shows: a longer one is never asked about.
pub const CARD_CHARS: usize = 2_000;
/// The longest command obid takes.
const COMMAND_CHARS: usize = 20_000;

/// Why a command waits for the owner.
pub const NETWORK: &str = "It installs software or reaches the network.";
pub const TAINTED: &str = "It may change files in this conversation's room, after the conversation read something untrusted.";

/// What the rules say of a command, before it runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Judged {
    Run,
    Refuse(String),
    Ask(Ask),
}

/// Why a command asks, whether it runs with the network once allowed, and the rule "Always allow"
/// saves (none for installs, the network and secrets: they're asked every time).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ask {
    pub why: String,
    pub network: bool,
    pub rule: Option<String>,
}

/// The owner's rules for conversations of `decision` (`allow` or `deny`).
fn rules_of<'a>(rules: &'a [Rule], decision: &'a str) -> impl Iterator<Item = &'a Rule> {
    rules
        .iter()
        .filter(move |r| r.repo == RULES_FOR && r.decision == decision)
}

/// What obid's rules say of `command` (docs/runner-api.md, "obid only: the conversation's shell",
/// "The rules"), in their order: refused, deny rules, always asked, read-only, allow rules, the
/// mode and the taint.
pub fn judge(command: &str, mode: Mode, rules: &[Rule], bounds: &Bounds, tainted: bool) -> Judged {
    match by_rules(command, mode, rules, bounds, tainted) {
        // The owner reads what they allow, whole.
        Judged::Ask(_) if command.chars().count() > CARD_CHARS => Judged::Refuse(format!(
            "It would wait for the owner's OK, but it's longer than the {CARD_CHARS} characters their card shows whole: split it into shorter commands."
        )),
        judged => judged,
    }
}

fn by_rules(command: &str, mode: Mode, rules: &[Rule], bounds: &Bounds, tainted: bool) -> Judged {
    let room = bounds.worktree.as_path();
    let input = json!({"command": command});
    // 1. Pushing or posting: only Publish does, whatever the mode.
    if crate::policy::fixed_denial("Bash", &input, room, &[]).is_some() {
        return Judged::Refuse(
            "Oby publishes work itself, through a job's checks: the shell never pushes or posts. Start a job with oby_dispatch.".into(),
        );
    }
    let call = Call::new("Bash", &input);
    let reach = permissions::reach(&call, bounds);
    if reach == Some(Reach::Outside) {
        return Judged::Refuse(
            "It reaches outside this conversation's room: the shell sees only the room (repos/ read-only), its own temporary folder and the system's software.".into(),
        );
    }
    // 2. The owner's deny rules: one part they cover refuses the whole line.
    if let Some(deny) =
        rules_of(rules, "deny").find(|r| permissions::covers(&r.rule, &call, room, false))
    {
        return Judged::Refuse(format!(
            "The owner's rule {} refuses this in conversations.",
            deny.rule
        ));
    }
    // 3. Secrets, installs and the network: asked in every mode, Bypass too, never by a rule.
    match reach {
        Some(Reach::Secrets) => {
            return Judged::Ask(Ask {
                why: Reach::Secrets.why().into(),
                network: false,
                rule: None,
            });
        }
        Some(Reach::Network) => {
            return Judged::Ask(Ask {
                why: NETWORK.into(),
                network: true,
                rule: None,
            });
        }
        _ => {}
    }
    let Some(parts) = permissions::command_words(command) else {
        // Deeper than obid reads: `uses_network` counts it as the network already; a backstop.
        return Judged::Ask(Ask {
            why: NETWORK.into(),
            network: true,
            rule: None,
        });
    };
    // 4. Only reads: in every mode, Plan too.
    if !parts.is_empty() && parts.iter().all(|w| reads_only(w)) && !writes_a_file(command) {
        return Judged::Run;
    }
    // 5. The owner's allow rules, when they cover every part.
    let covered = !parts.is_empty()
        && parts.iter().all(|words| {
            let part = Call::new("Bash", &json!({"command": words.join(" ")}));
            rules_of(rules, "allow").any(|r| permissions::covers(&r.rule, &part, room, true))
        });
    if covered && !writes_a_file(command) {
        return Judged::Run;
    }
    // 6. It may write, in the room: the mode, and the taint.
    let rule = permissions::card(&call, "", RULES_FOR, bounds).rule;
    match mode {
        Mode::Plan => Judged::Refuse(permissions::PLAN_ONLY.into()),
        _ if tainted => Judged::Ask(Ask {
            why: TAINTED.into(),
            network: false,
            rule,
        }),
        Mode::Ask | Mode::AcceptEdits => Judged::Ask(Ask {
            why: format!(
                "It may change files in this conversation's room, and the mode is {}.",
                mode.title()
            ),
            network: false,
            rule,
        }),
        Mode::Sandbox | Mode::Bypass => Judged::Run,
    }
}

/// The options a read-only program may be given: any (none of its options writes a file or runs
/// a program), or only these: single letters that may be bunched (`-la`), options whose value may
/// follow them or be attached (`-k2`, `-g '*.rs'`), and whole words (`--hidden`, `-name`; one
/// ending in `=` takes its value attached, `--glob=*.rs`). Anything else, an abbreviated long
/// option too (`--compress=` for `--compress-program`), makes the command one that may write.
struct Options {
    any: bool,
    letters: &'static str,
    valued: &'static [&'static str],
    words: &'static [&'static str],
}

const ANY: Options = Options {
    any: true,
    letters: "",
    valued: &[],
    words: &[],
};

/// The programs that only read, by name, and the options each may be given. Not git: the room's
/// own git settings, which the agent can write with a command, name programs git runs.
fn read_options(program: &str) -> Option<Options> {
    Some(match program {
        "ls" | "cat" | "head" | "tail" | "wc" | "grep" | "egrep" | "fgrep" | "du" | "df"
        | "pwd" | "echo" | "printf" | "which" | "type" | "stat" | "cut" | "tr" | "nl" | "od"
        | "jq" | "diff" | "cmp" | "comm" | "basename" | "dirname" | "realpath" | "readlink"
        | "whoami" | "id" | "uname" | "true" | "false" | "test" | "[" | "shasum" | "sha256sum"
        | "md5" | "md5sum" | "cksum" | "column" => ANY,
        // Not -o (it writes), -T (a folder it writes in) or --compress-program (it runs one).
        "sort" => Options {
            any: false,
            letters: "bdfghiMnRrsuVcCmz",
            valued: &["-k", "-t"],
            words: &[
                "--reverse",
                "--numeric-sort",
                "--unique",
                "--ignore-case",
                "--human-numeric-sort",
                "--general-numeric-sort",
                "--version-sort",
                "--stable",
                "--check",
                "--zero-terminated",
                "--key=",
                "--field-separator=",
            ],
        },
        // Tests and printing only: not -exec, -ok, -delete or -fprint.
        "find" => Options {
            any: false,
            letters: "",
            valued: &[],
            words: &[
                "-name",
                "-iname",
                "-path",
                "-ipath",
                "-wholename",
                "-lname",
                "-ilname",
                "-regex",
                "-iregex",
                "-type",
                "-maxdepth",
                "-mindepth",
                "-size",
                "-mtime",
                "-mmin",
                "-atime",
                "-amin",
                "-ctime",
                "-cmin",
                "-newer",
                "-empty",
                "-perm",
                "-user",
                "-group",
                "-links",
                "-inum",
                "-samefile",
                "-print",
                "-print0",
                "-ls",
                "-prune",
                "-o",
                "-a",
                "-or",
                "-and",
                "-not",
                "-true",
                "-false",
                "-depth",
                "-xdev",
                "-mount",
                "-L",
                "-H",
                "-P",
            ],
        },
        // Not --pre (it runs a program on each file) or -z (it runs decompressors).
        "rg" => Options {
            any: false,
            letters: "iInlcwvFxsSHhuLo0qUp",
            valued: &[
                "-g", "-t", "-T", "-e", "-A", "-B", "-C", "-m", "-M", "-j", "-d",
            ],
            words: &[
                "--hidden",
                "--no-ignore",
                "--files",
                "--files-with-matches",
                "--files-without-match",
                "--count",
                "--line-number",
                "--ignore-case",
                "--smart-case",
                "--fixed-strings",
                "--word-regexp",
                "--invert-match",
                "--only-matching",
                "--json",
                "--column",
                "--heading",
                "--no-heading",
                "--follow",
                "--multiline",
                "--no-messages",
                "--null",
                "--vimgrep",
                "--trim",
                "--type-list",
                "--glob=",
                "--type=",
                "--max-count=",
                "--context=",
                "--after-context=",
                "--before-context=",
                "--max-depth=",
                "--max-columns=",
                "--sort=",
                "--color=",
            ],
        },
        // Not -o (it writes).
        "tree" => Options {
            any: false,
            letters: "adfislhDCFrtpugNQ",
            valued: &["-L", "-I", "-P"],
            words: &[],
        },
        // Not -C (it writes) or -m.
        "file" => Options {
            any: false,
            letters: "bLhiIkNnr",
            valued: &[],
            words: &[],
        },
        _ => return None,
    })
}

/// Where a program that only reads may come from: the system's software, which nothing in a box
/// writes, never the room or the person's folders.
const SYSTEM_SOFTWARE: &[&str] = &["/bin/", "/sbin/", "/usr/", "/opt/", "/nix/", "/System/"];

/// bash's own commands, which no file on `PATH` stands in for.
const BUILTINS: &[&str] = &[
    "pwd", "echo", "printf", "type", "test", "[", "true", "false",
];

/// Whether `name`, as bash finds it on the box's `PATH`, is the system's software. A name with a
/// folder in it (`./cat`, `bin/git`) never is: the agent could have written it.
fn system_program(name: &str) -> bool {
    system_program_on(name, &crate::process::tools_path())
}

/// [`system_program`] with `path` as the box's `PATH`. A `PATH` with a relative or empty entry
/// (`.`, `bin`, `::`) makes nothing a system program: bash looks those up from the room, where the
/// agent writes, and they may come before the system's folder.
fn system_program_on(name: &str, path: &std::ffi::OsStr) -> bool {
    if name.contains('/') || name.is_empty() {
        return false;
    }
    if BUILTINS.contains(&name) {
        return true;
    }
    let dirs: Vec<PathBuf> = std::env::split_paths(path).collect();
    if dirs.iter().any(|d| !d.is_absolute()) {
        return false;
    }
    let Some(found) = dirs
        .iter()
        .map(|dir| dir.join(name))
        .find(|p| crate::sandbox::is_executable(p))
    else {
        return false;
    };
    found.is_absolute()
        && std::fs::canonicalize(&found).is_ok_and(|real| {
            SYSTEM_SOFTWARE.iter().any(|s| {
                real.to_string_lossy().starts_with(s) && found.to_string_lossy().starts_with(s)
            })
        })
}

/// Whether one simple command only reads: a program [`read_options`] names, as its first word (no
/// variable set before it, no wrapper, no folder), found among the system's software, given only
/// the options it allows. Best-effort; whatever passes still runs boxed.
pub fn reads_only(words: &[String]) -> bool {
    let Some(program) = words.first() else {
        return false;
    };
    let Some(options) = read_options(program) else {
        return false;
    };
    if !system_program(program) {
        return false;
    }
    if options.any {
        return true;
    }
    let mut operands = false;
    words[1..].iter().all(|word| {
        if operands || !word.starts_with('-') || word == "-" {
            return true;
        }
        if word == "--" {
            operands = true;
            return true;
        }
        options
            .words
            .iter()
            .any(|w| word == w || (w.ends_with('=') && word.starts_with(w)))
            || options.valued.iter().any(|v| word.starts_with(v))
            || (!word.starts_with("--")
                && !options.letters.is_empty()
                && word[1..].chars().all(|c| options.letters.contains(c)))
    })
}

/// Whether the line sends output to a file: any `>` but one to `/dev/null` or to another
/// descriptor (`2>&1`), each read whole (`>&1foo` writes the file `1foo`), and `>(…)`.
pub fn writes_a_file(command: &str) -> bool {
    static HARMLESS: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^>?(?:&[0-9]+|&-|\s*/dev/null)").expect("a regex"));
    let ends = |rest: &str| {
        rest.chars()
            .next()
            .is_none_or(|c| c.is_whitespace() || matches!(c, ';' | '|' | '&' | ')'))
    };
    command.match_indices('>').any(|(at, _)| {
        // The second of `>>` is read with the first.
        if at > 0 && command.as_bytes()[at - 1] == b'>' {
            return false;
        }
        let rest = &command[at + 1..];
        match HARMLESS.find(rest) {
            Some(found) => !ends(&rest[found.end()..]),
            None => true,
        }
    })
}

/// Every conversation's commands, by conversation: what `oby_shell_output` reads and
/// `oby_shell_stop` ends, and what ends with the turn.
#[derive(Default)]
pub struct Tasks {
    by: Mutex<Kept>,
}

#[derive(Default)]
struct Kept {
    tasks: HashMap<String, Vec<Arc<Task>>>,
    /// Each conversation's turn that ended last: a command of it that comes after never starts.
    ended: HashMap<String, String>,
}

/// One command, running or ended.
pub struct Task {
    pub id: String,
    /// Its process group (obid starts each in a session of its own).
    pgid: Option<u32>,
    /// What it wrote (obid's, never in a box) and its own temporary folder.
    log: PathBuf,
    temp: PathBuf,
    /// How far its output was read.
    read: AtomicU64,
    /// How it ended: its exit code (none when killed) and the words for it.
    ended: watch::Receiver<Option<(Option<i32>, String)>>,
}

impl Task {
    fn running(&self) -> bool {
        self.ended.borrow().is_none()
    }

    /// Waits up to `most` for it to end; how it ended, or none while it runs.
    async fn wait(&self, most: Duration) -> Option<(Option<i32>, String)> {
        let mut ended = self.ended.clone();
        let _ = tokio::time::timeout(most, ended.wait_for(Option::is_some)).await;
        ended.borrow().clone()
    }

    /// What it wrote since the last read, at most [`INLINE`] bytes, cut at a character's end, and
    /// whether more is there already.
    fn read_on(&self) -> (String, bool) {
        use std::io::{Read, Seek, SeekFrom};
        let from = self.read.load(Ordering::SeqCst);
        let Ok(mut file) = std::fs::File::open(&self.log) else {
            return (String::new(), false);
        };
        let size = file.metadata().map(|m| m.len()).unwrap_or(0);
        let mut bytes = vec![];
        let _ = file
            .seek(SeekFrom::Start(from))
            .and_then(|_| file.take(INLINE as u64).read_to_end(&mut bytes));
        let whole = match std::str::from_utf8(&bytes) {
            Ok(_) => bytes.len(),
            // A character cut at the end is read next time; a broken one isn't waited for.
            Err(e) if e.error_len().is_none() => e.valid_up_to(),
            Err(_) => bytes.len(),
        };
        self.read.store(from + whole as u64, Ordering::SeqCst);
        let text = String::from_utf8_lossy(&bytes[..whole]).into_owned();
        (text, from + (whole as u64) < size)
    }

    /// Ends it and everything it started; its watcher sees it end.
    async fn end(&self) {
        if let Some(pgid) = self.pgid {
            crate::process::end_group(pgid, crate::process::STOPPING).await;
        }
    }

    fn forget(&self) {
        let _ = std::fs::remove_file(self.log.with_extension("pgid"));
        let _ = std::fs::remove_file(&self.log);
        let _ = std::fs::remove_dir_all(&self.temp);
    }
}

impl Tasks {
    fn of(&self, conversation: &str) -> Vec<Arc<Task>> {
        self.lock()
            .tasks
            .get(conversation)
            .cloned()
            .unwrap_or_default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Kept> {
        self.by.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The turn `turn` of `conversation` ended: each of its commands ends with everything it
    /// started, and what they wrote goes; a command waiting for the owner never runs, and one about
    /// to start doesn't.
    pub fn end(&self, conversation: &str, turn: &str) {
        let tasks = {
            let mut kept = self.lock();
            kept.ended.insert(conversation.to_owned(), turn.to_owned());
            kept.tasks.remove(conversation).unwrap_or_default()
        };
        forget_asks(conversation);
        if tasks.is_empty() {
            return;
        }
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            // No runtime to wait in: SIGKILL now, the files stay for the conversation's folder.
            for pgid in tasks.iter().filter_map(|t| t.pgid) {
                crate::process::signal_group(pgid, nix::sys::signal::Signal::SIGKILL);
            }
            return;
        };
        runtime.spawn(async move {
            for task in &tasks {
                if task.running() {
                    task.end().await;
                }
                task.forget();
            }
        });
    }

    /// obid stops: every conversation's commands end.
    pub fn end_all(&self) {
        let conversations: Vec<String> = self.lock().tasks.keys().cloned().collect();
        for conversation in conversations {
            self.end(&conversation, "");
        }
    }
}

/// What names a shell command's processes (bash's `$0`), for [`reap_leftovers`].
pub const NAME: &str = "oby-shell";

/// At obid's start: the commands an obid that crashed left running end, with everything they
/// started, and what they wrote goes. A process group is ended only while its leader is still
/// one of the shell's boxes (its command line names [`NAME`]), never another that took its id.
pub fn reap_leftovers(home: &Path) {
    let conversations = home.join("conversations");
    for entry in std::fs::read_dir(&conversations)
        .into_iter()
        .flatten()
        .flatten()
    {
        let folder = entry.path().join("shell");
        if !std::fs::symlink_metadata(&folder).is_ok_and(|m| m.is_dir()) {
            continue;
        }
        for file in std::fs::read_dir(&folder).into_iter().flatten().flatten() {
            let path = file.path();
            if path.extension().is_none_or(|e| e != "pgid") {
                continue;
            }
            let Some(pgid) = std::fs::read_to_string(&path)
                .ok()
                .and_then(|t| t.trim().parse::<u32>().ok())
            else {
                continue;
            };
            let leader = std::process::Command::new("ps")
                .args(["-o", "command=", "-p", &pgid.to_string()])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
                .unwrap_or_default();
            if leader.contains(NAME) {
                crate::process::signal_group(pgid, nix::sys::signal::Signal::SIGTERM);
                std::thread::sleep(crate::process::STOPPING);
                crate::process::signal_group(pgid, nix::sys::signal::Signal::SIGKILL);
                tracing::info!("ended a shell command left running ({pgid})");
            }
        }
        let _ = std::fs::remove_dir_all(&folder);
    }
}

/// The commands waiting for the owner, by their inbox item's id: the conversation, and where the
/// owner's answer goes (none: done without one).
type Waiting = HashMap<String, (String, oneshot::Sender<Option<String>>)>;
static ASKS: LazyLock<Mutex<Waiting>> = LazyLock::new(Mutex::default);

fn asks() -> std::sync::MutexGuard<'static, Waiting> {
    ASKS.lock().unwrap_or_else(|e| e.into_inner())
}

/// A conversation's turn ended: its waiting commands hear it and never run.
fn forget_asks(conversation: &str) {
    asks().retain(|_, (c, _)| c != conversation);
}

/// Whether `item` is a command of a conversation's shell waiting for the owner.
pub fn is_item(item: &Item) -> bool {
    item.kind == "permission" && item.job.is_empty() && item.id.starts_with("shell-")
}

/// The conversation a shell item is about: its id is `shell-<conversation>-<permission>`.
pub fn conversation_of(id: &str) -> Option<&str> {
    let (conversation, _) = id.strip_prefix("shell-")?.rsplit_once('-')?;
    Some(conversation)
}

/// The owner answered (or settled) a shell item: its command hears it. False when no command waits
/// for it any more (its turn ended, or it was answered already).
pub fn answered(id: &str, answer: Option<String>) -> bool {
    match asks().remove(id) {
        Some((_, waiting)) => waiting.send(answer).is_ok(),
        None => false,
    }
}

/// Settles a shell item that no one answered, however its wait ends.
struct Settle {
    link: Arc<crate::sphere::Link>,
    id: String,
}

impl Drop for Settle {
    fn drop(&mut self) {
        asks().remove(&self.id);
        self.link.settle(&self.id);
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Shell {
    command: String,
    timeout: Option<u64>,
    run_in_background: Option<bool>,
    #[allow(dead_code)]
    description: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Output {
    id: String,
    wait: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Stop {
    id: String,
}

/// What a shell tool answers: its words for the agent (what the command wrote quoted by the caller)
/// and whether that's an error. `Err` is a refusal, before anything ran.
pub struct Shown {
    pub head: String,
    pub output: String,
    pub failed: bool,
}

/// `oby_shell`, `oby_shell_output` or `oby_shell_stop`.
pub async fn tool(
    shared: &Arc<Shared>,
    session: &Session,
    name: &str,
    args: Value,
) -> Result<Shown, String> {
    let tasks = &shared.harness.shell;
    match name {
        "oby_shell_output" => {
            let Output { id, wait } = parse(args)?;
            let task = find(tasks, session, &id)?;
            let wait = Duration::from_secs(wait.unwrap_or(0).min(MOST_MS / 1000));
            let ended = task.wait(wait).await;
            Ok(shown(session, &task, ended, &id, &id))
        }
        "oby_shell_stop" => {
            let Stop { id } = parse(args)?;
            let task = find(tasks, session, &id)?;
            if task.running() {
                task.end().await;
            }
            let ended = task.wait(Duration::from_secs(2)).await;
            let mut shown = shown(session, &task, ended, &id, &id);
            shown.head = format!("Stopped {id}. {}", shown.head);
            shown.failed = false;
            Ok(shown)
        }
        "oby_shell" => run(shared, session, args).await,
        other => Err(format!("Oby has no tool {other}.")),
    }
}

fn parse<T: serde::de::DeserializeOwned>(args: Value) -> Result<T, String> {
    serde_json::from_value(args).map_err(|e| format!("The tool's arguments don't fit: {e}"))
}

fn find(tasks: &Tasks, session: &Session, id: &str) -> Result<Arc<Task>, String> {
    tasks
        .of(&session.conversation)
        .into_iter()
        .find(|t| t.id == id)
        .ok_or_else(|| {
            format!("No command {id} runs in this turn (every command ends with its turn).")
        })
}

/// What a command wrote since the last read and how it stands; the step's tail is kept under `key`
/// (the command, or its id: what the step's call named).
fn shown(
    session: &Session,
    task: &Task,
    ended: Option<(Option<i32>, String)>,
    id: &str,
    key: &str,
) -> Shown {
    let (output, more) = task.read_on();
    let mut head = match &ended {
        Some((_, how)) => how.clone(),
        None => format!(
            "Still running in the background as {id}: read on with oby_shell_output, stop it with oby_shell_stop."
        ),
    };
    if more {
        head.push_str(&format!(
            " (The output goes on: read the rest with oby_shell_output {id}.)"
        ));
    }
    session.shell_said(key, tail(&output));
    Shown {
        head,
        output,
        failed: ended.is_some_and(|(code, _)| code != Some(0)),
    }
}

/// The end of `output` a step shows: its last [`STEP_LINES`] lines, at most [`STEP_CHARS`].
fn tail(output: &str) -> String {
    let lines: Vec<&str> = output.trim_end().lines().collect();
    let kept = lines[lines.len().saturating_sub(STEP_LINES)..].join("\n");
    let skip = kept.chars().count().saturating_sub(STEP_CHARS);
    kept.chars().skip(skip).collect()
}

async fn run(shared: &Arc<Shared>, session: &Session, args: Value) -> Result<Shown, String> {
    let Shell {
        command,
        timeout,
        run_in_background,
        ..
    } = parse(args)?;
    if command.trim().is_empty() || command.chars().count() > COMMAND_CHARS {
        return Err("command is 1 to 20,000 characters.".into());
    }
    let place = Place::of(&shared.config.home, &session.conversation);
    let folder = place.folder.join("shell");
    let id = format!("cmd-{}", &uuid::Uuid::new_v4().simple().to_string()[..8]);
    let temp = folder.join(&id);
    let bounds = Bounds {
        worktree: place.room.clone(),
        temp: Some(temp.clone()),
        home: Some(temp.clone()),
        logins: place.bounds().logins,
    };
    let rules = shared.jobs.rules();
    let tainted = session.web.load(Ordering::SeqCst);
    let network = match judge(
        &command,
        shared.jobs.default_mode(),
        &rules,
        &bounds,
        tainted,
    ) {
        Judged::Run => false,
        Judged::Refuse(why) => return Err(format!("Oby refused that: {why}")),
        Judged::Ask(ask) => ask_owner(shared, session, &command, &ask, &bounds).await?,
    };
    let task = {
        // Under the lock the turn's end takes: a command never starts after it.
        let mut kept = shared.harness.shell.lock();
        if !session.control.live()
            || kept.ended.get(&session.conversation) == Some(&session.control.turn)
        {
            return Err("The turn ended: the command didn't run.".into());
        }
        let running = kept
            .tasks
            .get(&session.conversation)
            .map_or(0, |t| t.iter().filter(|t| t.running()).count());
        if running >= RUNNING_MOST {
            return Err(format!(
                "{RUNNING_MOST} commands of this conversation run already: wait for one, or stop one with oby_shell_stop."
            ));
        }
        // What it prints may be the repositories', an attachment's or the web's.
        session.taint();
        let task = start(shared, &place, &folder, &id, &temp, &command, network)?;
        kept.tasks
            .entry(session.conversation.clone())
            .or_default()
            .push(task.clone());
        task
    };
    if run_in_background == Some(true) {
        return Ok(Shown {
            head: format!(
                "Running in the background as {id}: read its output with oby_shell_output, stop it with oby_shell_stop."
            ),
            output: String::new(),
            failed: false,
        });
    }
    let limit = timeout.unwrap_or(TIMEOUT_MS).clamp(1, MOST_MS);
    let ended = task.wait(Duration::from_millis(limit)).await;
    let mut shown = shown(session, &task, ended.clone(), &id, &command);
    if ended.is_none() {
        shown.head = format!(
            "Still running after {} s: it goes on in the background as {id}. Read its output with oby_shell_output, stop it with oby_shell_stop.",
            limit.div_ceil(1000)
        );
    }
    Ok(shown)
}

/// Starts `command` in its box, its output to its log; a watcher notes how it ends.
fn start(
    shared: &Shared,
    place: &Place,
    folder: &Path,
    id: &str,
    temp: &Path,
    command: &str,
    network: bool,
) -> Result<Arc<Task>, String> {
    let made = |e: std::io::Error| format!("obid couldn't make the command's folder: {e}");
    crate::jobs::not_a_link(&place.folder)?;
    crate::store::make_private_dir(folder).map_err(made)?;
    crate::store::make_private_dir(temp).map_err(made)?;
    let log = folder.join(format!("{id}.log"));
    let file = {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(nix::fcntl::OFlag::O_NOFOLLOW.bits())
            .open(&log)
            .map_err(made)?
    };
    let launch = shared.jobs.shell_launch(
        &place.room,
        temp,
        vec![place.repos.clone()],
        network,
        command,
    )?;
    let errors = file.try_clone().map_err(made)?;
    let mut child = tokio::process::Command::new(&launch.argv[0])
        .args(&launch.argv[1..])
        .env_clear()
        .envs(launch.env.iter().map(|(k, v)| (k, v)))
        .current_dir(&launch.cwd)
        .stdin(std::process::Stdio::null())
        .stdout(file)
        .stderr(errors)
        .spawn()
        .map_err(|e| format!("obid couldn't start the command: {e}"))?;
    let pgid = child.id();
    // For the sweep after a crash of obid's (reap_leftovers).
    if let Some(pgid) = pgid {
        let _ =
            crate::store::write_private(&log.with_extension("pgid"), pgid.to_string().as_bytes());
    }
    let (said, ended) = watch::channel(None);
    let status_file = temp.join(".obid-status");
    let written = log.clone();
    tokio::spawn(async move {
        // A command that writes without end would fill the disk before its turn ends.
        let mut too_much = false;
        let status = loop {
            tokio::select! {
                status = child.wait() => break status,
                () = tokio::time::sleep(Duration::from_secs(1)) => {
                    if !too_much && std::fs::metadata(&written).is_ok_and(|m| m.len() > LOG_MOST) {
                        too_much = true;
                        if let Some(pgid) = pgid {
                            crate::process::end_group(pgid, crate::process::STOPPING).await;
                        }
                    }
                }
            }
        };
        // On macOS the box's first process ends everything once the command exits, and may be
        // killed itself: the command's own status is what it wrote down first.
        let recorded = std::fs::read_to_string(&status_file)
            .ok()
            .and_then(|s| s.trim().parse::<i32>().ok());
        let code = recorded.or_else(|| status.as_ref().ok().and_then(|s| s.code()));
        let how = match (code, &status) {
            _ if too_much => "obid stopped it: it wrote more than 64 MB.".to_owned(),
            (Some(code), _) => format!("Exit status {code}."),
            (None, Ok(status)) => format!("It ended: {}.", crate::process::describe(*status)),
            (None, Err(e)) => format!("obid lost track of it: {e}."),
        };
        let _ = said.send(Some((code, how)));
    });
    Ok(Arc::new(Task {
        id: id.to_owned(),
        pgid,
        log,
        temp: temp.to_path_buf(),
        read: AtomicU64::new(0),
        ended,
    }))
}

/// Asks the owner about `command` with a `permission` inbox item, and waits for their answer
/// while the turn lives: whether it runs with the network, or why it doesn't run.
async fn ask_owner(
    shared: &Arc<Shared>,
    session: &Session,
    command: &str,
    ask: &Ask,
    bounds: &Bounds,
) -> Result<bool, String> {
    use crate::permissions::{ALLOW, ALWAYS_ALLOW, DENY};
    let permission = permissions::new_id();
    let id = format!("shell-{}-{permission}", session.conversation);
    let call = Call::new("Bash", &json!({"command": command}));
    let card = permissions::card(&call, &permission, RULES_FOR, bounds);
    let secrets = crate::secrets::known();
    let options: Vec<String> = match &ask.rule {
        Some(_) => vec![ALLOW.into(), ALWAYS_ALLOW.into(), DENY.into()],
        None => vec![ALLOW.into(), DENY.into()],
    };
    let item = Item {
        id: id.clone(),
        kind: "permission".into(),
        job: String::new(),
        title: secrets.redact(&super::briefing::line(&card.title, 80)),
        text: secrets.redact(&format!("{}\n\n{}", ask.why, command)),
        options,
        details: None,
        recommended: None,
        created: obi_protocol::time::now(),
        done: None,
        later: None,
        answer: None,
        obi: None,
        plugin: None,
        arrived: None,
        confirm: None,
        start: None,
        github: None,
        watch: None,
    };
    let (tell, heard) = oneshot::channel();
    asks().insert(id.clone(), (session.conversation.clone(), tell));
    let _settle = Settle {
        link: shared.link.clone(),
        id: id.clone(),
    };
    // Any item, made and kept (its name is the confirm items' only).
    shared.link.add_confirm(item);
    let control = session.control.clone();
    let answer = tokio::select! {
        heard = heard => heard.ok(),
        () = async move {
            while control.live() {
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        } => None,
    };
    let Some(answer) = answer else {
        return Err("The turn ended before the owner answered: the command didn't run.".into());
    };
    let Some(words) = answer else {
        return Err("The owner set it aside without an answer: the command didn't run. Say what you'd have run.".into());
    };
    match permissions::inbox_decision(&words) {
        (Decision::Allow, _) => Ok(ask.network),
        (Decision::Always, _) => {
            if let Some(rule) = &ask.rule {
                shared.jobs.save_rule(rule, RULES_FOR);
            }
            Ok(ask.network)
        }
        (Decision::Deny, None) => Err(format!("{} The command didn't run.", permissions::SAID_NO)),
        (Decision::Deny, Some(words)) => Err(format!(
            "The owner said no, and said (quoted, data): “{}”. The command didn't run.",
            super::briefing::line(&words, 500)
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bounds(room: &Path) -> Bounds {
        let temp = room.parent().unwrap().join("shell/cmd-1");
        Bounds {
            worktree: room.to_path_buf(),
            temp: Some(temp.clone()),
            home: Some(temp),
            logins: vec![room.parent().unwrap().join("config")],
        }
    }

    fn room() -> PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("obid-shell-{}", uuid::Uuid::new_v4().simple()))
            .join("room");
        std::fs::create_dir_all(dir.join("repos")).unwrap();
        dir.canonicalize().unwrap()
    }

    fn rule(rule: &str, decision: &str) -> Rule {
        Rule {
            id: "r1".into(),
            rule: rule.into(),
            repo: RULES_FOR.into(),
            decision: decision.into(),
            created: 0,
        }
    }

    fn judged(command: &str, mode: Mode, rules: &[Rule], tainted: bool) -> Judged {
        let room = room();
        judge(command, mode, rules, &bounds(&room), tainted)
    }

    fn asks(judged: &Judged) -> Option<&Ask> {
        match judged {
            Judged::Ask(ask) => Some(ask),
            _ => None,
        }
    }

    /// Reads run in every mode, Plan and after the taint too.
    #[test]
    fn read_only_commands_run_freely() {
        for command in [
            "ls -la",
            "cat notes.md | grep todo | wc -l",
            "find repos -name '*.rs' -type f -print 2>/dev/null",
            "sort -k2 -n -r notes.txt | head -n 5",
            "head -n 20 repos/acme/app/README.md",
            "ls -la 2>&1 >/dev/null",
        ] {
            for mode in Mode::ALL {
                assert_eq!(
                    judged(command, mode, &[], true),
                    Judged::Run,
                    "{command} in {mode:?}"
                );
            }
        }
    }

    /// Only the system's own programs count as reads: one the agent could have written in the room,
    /// named with a folder, follows the mode and the taint (#774's review, 1).
    #[test]
    fn a_program_in_the_room_is_never_a_read() {
        assert_eq!(judged("cat notes.md", Mode::Plan, &[], true), Judged::Run);
        for command in ["./cat notes.md", "bin/cat notes.md", "./ls", "/tmp/cat x"] {
            let plan = judged(command, Mode::Plan, &[], false);
            assert!(matches!(plan, Judged::Refuse(_)), "{command}: {plan:?}");
            let tainted = judged(command, Mode::Sandbox, &[], true);
            assert!(
                matches!(tainted, Judged::Refuse(_) | Judged::Ask(_)),
                "{command}: {tainted:?}"
            );
        }
        assert!(!reads_only(&["./cat".into(), "x".into()]));
        assert!(!reads_only(&["no-such-program-anywhere".into()]));
        // A relative entry in PATH is looked up from the room: then nothing is the system's
        // (#774's re-review, 3).
        assert!(system_program_on("cat", "/bin:/usr/bin".as_ref()));
        for path in [".:/bin", "/bin:.", "/bin::/usr/bin", "bin:/bin", ""] {
            assert!(!system_program_on("cat", path.as_ref()), "{path:?}");
        }
    }

    /// Options are allowed by name, per program: an attached short one or an abbreviated long one
    /// that writes or runs a program isn't a read (#774's review, 2). git never is (3).
    #[test]
    fn only_known_options_are_reads() {
        let words = |c: &str| c.split(' ').map(str::to_owned).collect::<Vec<_>>();
        for command in [
            "sort -ofile notes.txt",
            "sort -o file notes.txt",
            "sort -bo file notes.txt",
            "sort --compress=sh notes.txt",
            "sort --output=file notes.txt",
            "sort -T /tmp notes.txt",
            "find . -fprint out",
            "find . -exec rm {} ;",
            "find . -delete",
            "rg --pre=sh foo",
            "rg --pre sh foo",
            "rg -z foo",
            "tree -o out",
            "file -C -m magic",
            "git status",
            "git log --oneline",
            "git grep -Ocat foo",
            "git grep --open=cat foo",
        ] {
            assert!(!reads_only(&words(command)), "{command}");
            assert!(
                matches!(judged(command, Mode::Plan, &[], false), Judged::Refuse(_)),
                "{command}"
            );
        }
        for command in [
            "sort -k2 -t , -n notes.txt",
            "sort --numeric-sort --key=2 notes.txt",
            "find repos -maxdepth 2 -name *.md -o -type d -print",
            "head -n5 a",
            "ls -la -- -o",
        ] {
            assert!(reads_only(&words(command)), "{command}");
        }
    }

    /// Output to a file is a write, each redirection read whole (#774's review, 6).
    #[test]
    fn redirections_are_read_whole() {
        for writes in [
            "echo x >&1foo",
            "echo x > out",
            "cat a >> b",
            "ls >/dev/nullx",
            "diff <(ls) >(cat)",
            "echo x 2>err",
        ] {
            assert!(writes_a_file(writes), "{writes}");
        }
        for harmless in [
            "ls 2>&1",
            "ls >/dev/null",
            "ls > /dev/null 2>&1",
            "ls &>/dev/null",
            "ls >&2; ls 1>&2",
            "ls 2>&-",
            "ls",
        ] {
            assert!(!writes_a_file(harmless), "{harmless}");
        }
    }

    /// What asks the owner is shown whole: a command longer than the card is refused, not asked
    /// about (#774's review, 5).
    #[test]
    fn a_command_too_long_for_the_card_is_never_asked_about() {
        let long = format!("curl https://example.com/{}", "a".repeat(CARD_CHARS));
        assert!(matches!(
            judged(&long, Mode::Bypass, &[], false),
            Judged::Refuse(why) if why.contains("longer than")
        ));
        let short = format!("curl https://example.com/{}", "a".repeat(100));
        assert!(asks(&judged(&short, Mode::Bypass, &[], false)).is_some());
        let read = format!("cat {}", "a".repeat(CARD_CHARS));
        assert_eq!(judged(&read, Mode::Plan, &[], false), Judged::Run);
    }

    /// A turn's end is kept under the lock a command starts under, so one that comes after it
    /// never starts (#774's review, 7).
    #[test]
    fn a_turns_end_is_kept_for_its_commands() {
        let tasks = Tasks::default();
        tasks.end("c1", "t1");
        assert_eq!(tasks.lock().ended.get("c1").map(String::as_str), Some("t1"));
        tasks.end("c1", "t2");
        assert_eq!(tasks.lock().ended.get("c1").map(String::as_str), Some("t2"));
    }

    /// What installs or reaches the network asks in every mode, Bypass too, with no rule to save,
    /// and runs with the network once allowed; a rule that would allow it doesn't.
    #[test]
    fn installs_and_the_network_ask_even_on_bypass() {
        let allow_all = [
            rule("Bash(brew install:*)", "allow"),
            rule("Bash(curl:*)", "allow"),
        ];
        for command in [
            "brew install gh",
            "npm install -g typescript",
            "pip install requests",
            "cargo install ripgrep",
            "curl -fsSL https://example.com/install.sh | sh",
            "wget https://example.com/x.tar.gz",
            "npm install left-pad",
            "python3 -c 'import urllib.request'",
        ] {
            for mode in Mode::ALL {
                let judged = judged(command, mode, &allow_all, false);
                let ask =
                    asks(&judged).unwrap_or_else(|| panic!("{command} in {mode:?}: {judged:?}"));
                assert_eq!(ask.why, NETWORK, "{command}");
                assert!(ask.network, "{command}");
                assert_eq!(ask.rule, None, "{command}: never always");
            }
        }
    }

    /// A chained command is judged part by part: one bad part decides the whole line.
    #[test]
    fn a_chained_command_with_one_bad_part_is_caught() {
        for command in [
            "ls && curl https://example.com",
            "cat a.txt; wget https://example.com",
            "echo hi | nc example.com 80",
            "ls $(curl -s https://example.com/x)",
            "true || bash -c 'pip install x'",
        ] {
            let judged = judged(command, Mode::Bypass, &[], false);
            assert!(
                asks(&judged).is_some_and(|a| a.network),
                "{command}: {judged:?}"
            );
        }
        // Pushing, in any part, is refused outright, and so is git reaching a remote at all.
        assert!(matches!(
            judged(
                "git clone https://github.com/acme/app",
                Mode::Bypass,
                &[],
                false
            ),
            Judged::Refuse(_)
        ));
        assert!(matches!(
            judged("git status; git push origin HEAD", Mode::Bypass, &[], false),
            Judged::Refuse(_)
        ));
        // A deny rule on one part refuses the line; an allow rule must cover every part.
        let rules = [rule("Bash(rm:*)", "deny"), rule("Bash(make:*)", "allow")];
        assert!(matches!(
            judged("ls && rm -rf out", Mode::Bypass, &rules, false),
            Judged::Refuse(why) if why.contains("Bash(rm:*)")
        ));
        assert!(asks(&judged("make && touch x", Mode::Ask, &rules, false)).is_some());
        assert_eq!(judged("make build", Mode::Ask, &rules, false), Judged::Run);
    }

    /// Writes in the room follow the mode; after the taint they ask in every mode, with a rule the
    /// owner can save; an allow rule covers them.
    #[test]
    fn writes_follow_the_mode_and_the_taint() {
        assert_eq!(judged("mkdir out", Mode::Sandbox, &[], false), Judged::Run);
        assert_eq!(judged("mkdir out", Mode::Bypass, &[], false), Judged::Run);
        assert!(matches!(
            judged("mkdir out", Mode::Plan, &[], false),
            Judged::Refuse(why) if why == permissions::PLAN_ONLY
        ));
        for mode in [Mode::Ask, Mode::AcceptEdits] {
            let judged = judged("npm test", mode, &[], false);
            let ask = asks(&judged).unwrap();
            assert!(!ask.network);
            assert_eq!(ask.rule.as_deref(), Some("Bash(npm test:*)"));
        }
        for mode in [Mode::Sandbox, Mode::Bypass, Mode::AcceptEdits] {
            let judged = judged("npm test", mode, &[], true);
            assert_eq!(asks(&judged).unwrap().why, TAINTED, "{mode:?}");
        }
        let rules = [rule("Bash(npm test:*)", "allow")];
        assert_eq!(judged("npm test", Mode::Sandbox, &rules, true), Judged::Run);
        // Output to a file is a write, whatever the program.
        assert!(asks(&judged("ls > files.txt", Mode::Ask, &[], false)).is_some());
        assert_eq!(
            judged("ls 2>&1 >/dev/null", Mode::Ask, &[], false),
            Judged::Run
        );
    }

    /// Secrets ask, once at a time; what leaves the room is refused.
    #[test]
    fn secrets_ask_and_outside_is_refused() {
        let judged = judged("cat .env", Mode::Bypass, &[], false);
        let ask = asks(&judged).unwrap();
        assert_eq!(ask.why, Reach::Secrets.why());
        assert_eq!(ask.rule, None);
        assert!(matches!(
            self::judged("cat /Users/someone/notes.txt", Mode::Bypass, &[], false),
            Judged::Refuse(_)
        ));
        assert!(matches!(
            self::judged("cat ../config/.credentials.json", Mode::Bypass, &[], false),
            Judged::Refuse(_) | Judged::Ask(_)
        ));
    }

    #[test]
    fn shell_items_name_their_conversation() {
        let id = "shell-5b0e2c4d-1111-2222-3333-444455556666-pa1b2c3";
        assert_eq!(
            conversation_of(id),
            Some("5b0e2c4d-1111-2222-3333-444455556666")
        );
        assert_eq!(conversation_of("j1-permission-p1"), None);
    }

    #[test]
    fn a_steps_tail_is_the_end_of_the_output() {
        let long: String = (1..=50).map(|n| format!("line {n}\n")).collect();
        let kept = tail(&long);
        assert!(
            kept.starts_with("line 31\n") && kept.ends_with("line 50"),
            "{kept}"
        );
        assert_eq!(tail(&"x".repeat(5000)).chars().count(), STEP_CHARS);
    }
}
