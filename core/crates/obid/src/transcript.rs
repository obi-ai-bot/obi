//! A job's transcript (#381; docs/runner-api.md, "GET /v1/jobs/{id}/transcript"): one entry per
//! tool call, the agent's words between them, the owner's words, its to-do list and each round's
//! start, live. Kept in `home/jobs/<id>/transcript.jsonl` (0600): one JSON line per change, each
//! entry numbered `n` in order; a tool call that ends is written again under its `n`. The secrets
//! obid holds are taken out before anything is written. Never a command's output or a file's
//! contents: the tool, a short summary of its input, how it ended, how long it took, its exit code
//! and the lines it added and removed.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Instant;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent::{self, Event};

/// How long the agent's or the owner's words may be in an entry.
const WORDS: usize = 300;
/// How long a tool's name and a call's summary may be.
const NAME: usize = 64;
const SUMMARY: usize = 200;
/// How many items of a to-do list an entry keeps.
const TODOS: usize = 50;
/// How much of a job's transcript obid keeps: past either, it writes no more of it.
pub const MOST_ENTRIES: u64 = 5_000;
pub const MOST_BYTES: u64 = 8 * 1024 * 1024;
/// How many entries one read gives at most, and unless asked for fewer.
pub const PAGE: usize = 1_000;
/// How long a finished job's transcript is kept.
pub const KEPT_DAYS: i64 = 30;

/// One entry.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub n: u64,
    pub at: String,
    /// `tool`, `said` (the agent's words), `you` (the owner's), `plan` (its to-do list) or
    /// `start` (a round began).
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    pub summary: String,
    /// A tool call's: `running`, `done`, `failed` or `declined`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seconds: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed: Option<u64>,
    /// A `plan`'s items.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub todos: Option<Vec<Todo>>,
    /// A tool call's kind in the job's activity (`crate::activity::kind`): `read`, `search`,
    /// `edit`, `command`, `test`, `tetrix`, `web`, `mcp` or `other`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activity: Option<String>,
    /// The file a tool call reads or changes, from the worktree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

/// One item of the agent's to-do list.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Todo {
    pub text: String,
    /// `pending`, `running` or `done`.
    pub state: String,
}

/// What a job's transcript holds in memory while its agent runs (dropped after each turn,
/// [`Transcripts::forget`]): every entry as it is now, the order its lines were written in, and
/// the calls not ended yet.
#[derive(Default)]
struct Live {
    last: u64,
    now: std::collections::BTreeMap<u64, Entry>,
    /// The `n` of each line, in the order they were written.
    log: Vec<u64>,
    /// Where in `log` each entry first came, by `n` - 1.
    first: Vec<usize>,
    /// The file's size.
    bytes: u64,
    /// The job's activity, built as entries come.
    activity: crate::activity::Activity,
    /// The file is full ([`MOST_ENTRIES`], [`MOST_BYTES`]): said in the log once.
    full: bool,
    open: HashMap<String, (Entry, Instant)>,
    /// The call obid declined last: its end says `declined`, not `failed`.
    declined: Option<String>,
    /// Claude Code's `TaskCreate`/`TaskUpdate` list, in the order the tasks were made.
    tasks: Vec<Todo>,
}

pub struct Transcripts {
    home: PathBuf,
    live: Mutex<HashMap<String, Live>>,
}

impl Transcripts {
    pub fn new(home: &Path) -> Transcripts {
        Transcripts {
            home: home.to_path_buf(),
            live: Mutex::new(HashMap::new()),
        }
    }

    fn path(&self, job: &str) -> PathBuf {
        self.home.join("jobs").join(job).join("transcript.jsonl")
    }

    /// Takes in what the agent did in `worktree`, where the job's check is `check`; the entries
    /// it wrote or changed, in order.
    pub fn record(
        &self,
        job: &str,
        event: &Event,
        worktree: &Path,
        check: Option<&str>,
    ) -> Vec<Entry> {
        let mut all = self.live.lock().unwrap_or_else(|e| e.into_inner());
        let live = self.live_for(&mut all, job);
        let entries = match event {
            Event::Tool { id, name, input } => tool(live, id, name, input, worktree, check),
            Event::ToolDone {
                id,
                failed,
                exit,
                lines,
            } => live
                .open
                .remove(id)
                .map(|(mut entry, started)| {
                    let declined = live.declined.as_deref() == Some(id.as_str());
                    entry.state = Some(
                        match (declined, failed) {
                            (true, _) => "declined",
                            (_, true) => "failed",
                            _ => "done",
                        }
                        .into(),
                    );
                    entry.seconds = Some(tenths(started));
                    entry.exit = *exit;
                    if let Some((added, removed)) = lines {
                        (entry.added, entry.removed) = (Some(*added), Some(*removed));
                    }
                    vec![entry]
                })
                .unwrap_or_default(),
            // ponytail: a refusal names no call; it's about the latest one still running, which
            // is the one asking.
            Event::Denied(_) => {
                live.declined = live
                    .open
                    .iter()
                    .max_by_key(|(_, (e, _))| e.n)
                    .map(|(id, _)| id.clone());
                vec![]
            }
            Event::Said(words) => said(live, "said", words),
            Event::Plan(todos) => vec![plan(live, todos.clone())],
            Event::Session(_)
            | Event::Step(_)
            | Event::Delta(_)
            | Event::Usage(_)
            | Event::Tokens(_) => vec![],
        };
        self.write(job, live, entries)
    }

    /// The job's `activity` (none before its first tool call) and `context` (`crate::activity`),
    /// from its entries as they are now.
    pub fn glance(&self, job: &str) -> (Option<Value>, Option<String>) {
        let all = self.live.lock().unwrap_or_else(|e| e.into_inner());
        let loaded;
        let live = match all.get(job) {
            Some(live) => live,
            None => {
                drop(all);
                loaded = self.load(job);
                return glance(&loaded);
            }
        };
        glance(live)
    }

    /// The owner's words the agent heard.
    pub fn you(&self, job: &str, words: &str) -> Vec<Entry> {
        self.note(job, |live| said(live, "you", words))
    }

    /// A round began: `summary` says which, on which tool.
    pub fn start(&self, job: &str, summary: &str) -> Vec<Entry> {
        self.note(job, |live| vec![entry(live, "start", None, mask(summary))])
    }

    /// The turn is over: a call that never ended (the agent was stopped or died) failed.
    pub fn end_turn(&self, job: &str) -> Vec<Entry> {
        self.note(job, |live| {
            let mut ended: Vec<Entry> = live
                .open
                .drain()
                .map(|(_, (mut entry, started))| {
                    entry.state = Some("failed".into());
                    entry.seconds = Some(tenths(started));
                    entry
                })
                .collect();
            ended.sort_by_key(|e| e.n);
            ended
        })
    }

    /// Drops what's held in memory for the job: its turn is over. The file has it all.
    pub fn forget(&self, job: &str) {
        self.live
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(job);
    }

    fn note(&self, job: &str, make: impl FnOnce(&mut Live) -> Vec<Entry>) -> Vec<Entry> {
        let mut all = self.live.lock().unwrap_or_else(|e| e.into_inner());
        let live = self.live_for(&mut all, job);
        let entries = make(live);
        self.write(job, live, entries)
    }

    fn live_for<'a>(&self, all: &'a mut HashMap<String, Live>, job: &str) -> &'a mut Live {
        all.entry(job.to_owned()).or_insert_with(|| self.load(job))
    }

    /// The job's transcript as its file has it.
    fn load(&self, job: &str) -> Live {
        let path = self.path(job);
        let mut live = Live {
            bytes: std::fs::metadata(&path).map_or(0, |m| m.len()),
            ..Live::default()
        };
        for entry in lines(&path) {
            live.take(entry);
        }
        // ponytail: Claude Code's task list picks up from the last to-do list written, which
        // may have been a TodoWrite's.
        live.tasks = live
            .now
            .values()
            .rev()
            .find_map(|e| e.todos.clone())
            .unwrap_or_default();
        live
    }

    /// Keeps `entries` in the file and in memory, unless the file is full; the ones kept.
    fn write(&self, job: &str, live: &mut Live, all: Vec<Entry>) -> Vec<Entry> {
        let mut text = String::new();
        let mut entries = Vec::new();
        let mut dropped = false;
        for entry in all {
            let line = serde_json::to_string(&entry).unwrap_or_default() + "\n";
            // A call already written always gets its end, past the caps too: each call ends
            // once, so a full transcript never leaves one running.
            let end = live.now.contains_key(&entry.n);
            let fits = entry.n <= MOST_ENTRIES
                && live.bytes + (text.len() + line.len()) as u64 <= MOST_BYTES;
            if end || fits {
                text.push_str(&line);
                entries.push(entry);
            } else {
                dropped = true;
            }
        }
        if dropped && !live.full {
            live.full = true;
            tracing::warn!("job {job}'s transcript is full: obid keeps no more of it");
        }
        if entries.is_empty() {
            return entries;
        }
        let path = self.path(job);
        let written = (|| -> std::io::Result<()> {
            crate::store::make_private_dir(path.parent().expect("a folder"))?;
            let mut options = std::fs::OpenOptions::new();
            options.append(true).create(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            options.open(&path)?.write_all(text.as_bytes())
        })();
        match written {
            Ok(()) => {
                live.bytes += text.len() as u64;
                for entry in &entries {
                    live.take(entry.clone());
                }
            }
            Err(e) => {
                tracing::error!("can't keep job {job}'s transcript: {e}");
                entries.clear();
            }
        }
        entries
    }

    /// The entries that came or changed after entry `after` first did, each as it is now, in
    /// order, at most `limit` of them: everything with `after` 0. A client that saw up to `after`
    /// upserts them by `n`. When there's more, the `n` to ask after next.
    pub fn read(&self, job: &str, after: u64, limit: usize) -> (Vec<Entry>, Option<u64>) {
        let all = self.live.lock().unwrap_or_else(|e| e.into_inner());
        // A job whose agent isn't running is read from its file (no other job waits on that),
        // and not kept in memory.
        let loaded;
        let live = match all.get(job) {
            Some(live) => live,
            None => {
                drop(all);
                loaded = self.load(job);
                return page(&loaded, after, limit);
            }
        };
        page(live, after, limit)
    }

    /// Removes the transcripts `keep` says no to (by job id): those of jobs that ended more than
    /// [`KEPT_DAYS`] ago, when obid starts.
    pub fn sweep(&self, keep: impl Fn(&str) -> bool) {
        let Ok(folders) = std::fs::read_dir(self.home.join("jobs")) else {
            return;
        };
        for folder in folders.flatten() {
            let path = folder.path();
            let id = folder.file_name().to_string_lossy().into_owned();
            if path.join("transcript.jsonl").is_file() && !keep(&id) {
                let _ = std::fs::remove_file(path.join("transcript.jsonl"));
                let _ = std::fs::remove_dir(&path);
            }
        }
    }
}

fn glance(live: &Live) -> (Option<Value>, Option<String>) {
    (live.activity.to_json(), live.activity.context())
}

/// [`Transcripts::read`]'s page of `live`: the earlier entries that changed (calls that were
/// running when `after` came: few) always, then at most `limit` newer ones, so the next marker is
/// always past `after`.
fn page(live: &Live, after: u64, limit: usize) -> (Vec<Entry>, Option<u64>) {
    let from = match after {
        0 => 0,
        n => live
            .first
            .get(n as usize - 1)
            .map_or(live.log.len(), |i| i + 1),
    };
    let changed: std::collections::BTreeSet<u64> = live.log[from..].iter().copied().collect();
    let newer = changed.range(after + 1..);
    let more = newer.clone().count() > limit.clamp(1, PAGE);
    let entries: Vec<Entry> = changed
        .range(..=after)
        .chain(newer.take(limit.clamp(1, PAGE)))
        .filter_map(|n| live.now.get(n).cloned())
        .collect();
    let next = more.then(|| entries.last().map(|e| e.n)).flatten();
    (entries, next)
}

impl Live {
    /// Takes in one line.
    fn take(&mut self, entry: Entry) {
        let n = entry.n;
        if n > self.last {
            self.last = n;
        }
        if n as usize > self.first.len() {
            self.first.resize(n as usize, self.log.len());
        }
        self.log.push(n);
        self.activity.take(&entry);
        self.now.insert(n, entry);
    }
}

/// Every line of a transcript file; one that doesn't read is left out.
fn lines(path: &Path) -> Vec<Entry> {
    let Ok(file) = std::fs::File::open(path) else {
        return vec![];
    };
    std::io::BufReader::new(file)
        .split(b'\n')
        .map_while(Result::ok)
        .filter_map(|line| serde_json::from_slice(&line).ok())
        .collect()
}

fn entry(live: &mut Live, kind: &str, tool: Option<&str>, summary: String) -> Entry {
    live.last += 1;
    Entry {
        n: live.last,
        at: obi_protocol::time::format(obi_protocol::time::now()),
        kind: kind.into(),
        tool: tool.map(str::to_owned),
        summary,
        ..Entry::default()
    }
}

fn said(live: &mut Live, kind: &str, words: &str) -> Vec<Entry> {
    let words = crate::brain::briefing::line(&mask(words), WORDS);
    if words.is_empty() {
        return vec![];
    }
    vec![entry(live, kind, None, words)]
}

fn plan(live: &mut Live, todos: Vec<Todo>) -> Entry {
    let todos: Vec<Todo> = todos
        .into_iter()
        .map(|t| Todo {
            text: crate::brain::briefing::line(&mask(&t.text), WORDS),
            state: t.state,
        })
        .collect();
    let done = todos.iter().filter(|t| t.state == "done").count();
    let summary = format!("{done} of {} done", todos.len());
    let mut entry = entry(live, "plan", None, summary);
    entry.todos = Some(todos.into_iter().take(TODOS).collect());
    entry
}

/// A tool call starts: its entry, running; or the to-do list it changes.
fn tool(
    live: &mut Live,
    id: &str,
    name: &str,
    input: &Value,
    worktree: &Path,
    check: Option<&str>,
) -> Vec<Entry> {
    let text = |key: &str| input.get(key).and_then(Value::as_str).unwrap_or("");
    match name {
        // Loading a deferred tool's schema is the agent's bookkeeping (as a conversation's steps).
        "ToolSearch" => vec![],
        "TodoWrite" => {
            let todos = input["todos"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|t| Todo {
                    text: t["content"].as_str().unwrap_or("").to_owned(),
                    state: todo_state(t["status"].as_str().unwrap_or("")).into(),
                })
                .collect();
            vec![plan(live, todos)]
        }
        "TaskCreate" => {
            live.tasks.push(Todo {
                text: text("subject").to_owned(),
                state: "pending".into(),
            });
            vec![plan(live, live.tasks.clone())]
        }
        "TaskUpdate" => {
            // ponytail: Claude Code numbers tasks 1, 2, … as they're made, so the id is the
            // place; its answer (which names the id) is never read, as no tool's output is.
            let task = input["taskId"]
                .as_str()
                .and_then(|id| id.parse::<usize>().ok())
                .and_then(|i| live.tasks.get_mut(i.wrapping_sub(1)));
            match (task, input["status"].as_str()) {
                (Some(task), Some(status)) => task.state = todo_state(status).into(),
                _ => return vec![],
            }
            live.tasks.retain(|t| t.state != "deleted");
            vec![plan(live, live.tasks.clone())]
        }
        _ => {
            // Masked before they're cut short, so no part of a secret is left.
            let shown = crate::brain::briefing::line(&mask(name), NAME);
            let summary =
                crate::brain::briefing::line(&mask(&agent::step(&shown, &masked(input))), SUMMARY);
            let mut entry = entry(live, "tool", Some(&shown), summary);
            entry.state = Some("running".into());
            entry.activity = Some(crate::activity::kind(name, input, check).into());
            entry.file = file_of(input, worktree);
            if let Some((added, removed)) = edited(name, input) {
                (entry.added, entry.removed) = (Some(added), Some(removed));
            }
            live.open
                .insert(id.to_owned(), (entry.clone(), Instant::now()));
            vec![entry]
        }
    }
}

/// `pending`, `running` or `done`, from each tool's words for them (`in_progress`, `inProgress`,
/// `completed`, …). `deleted` stays, for a task that's gone.
pub fn todo_state(status: &str) -> &'static str {
    match status {
        "in_progress" | "inProgress" | "running" | "active" => "running",
        "completed" | "done" => "done",
        "deleted" => "deleted",
        _ => "pending",
    }
}

/// The file a call is about (`file_path`, `notebook_path` or `path`), masked: from the worktree
/// when it's in it, else only its name (never the home folder or another place on the Mac).
fn file_of(input: &Value, worktree: &Path) -> Option<String> {
    let path = ["file_path", "notebook_path", "path"]
        .iter()
        .find_map(|k| input[k].as_str().filter(|p| !p.is_empty()))?;
    let path = Path::new(path);
    let real = crate::policy::real_path(worktree).unwrap_or_else(|| worktree.to_path_buf());
    let inside = path
        .strip_prefix(worktree)
        .or_else(|_| path.strip_prefix(&real))
        .ok()
        .or_else(|| {
            path.is_relative().then_some(path).filter(|p| {
                p.components()
                    .all(|c| matches!(c, std::path::Component::Normal(_)))
            })
        });
    let shown = match inside {
        Some(relative) => relative.display().to_string(),
        None => path.file_name()?.to_string_lossy().into_owned(),
    };
    Some(crate::brain::briefing::line(&mask(&shown), SUMMARY))
}

/// The lines a Claude Code edit adds and removes, from its input.
fn edited(name: &str, input: &Value) -> Option<(u64, u64)> {
    let count = |v: &Value| v.as_str().map_or(0, |s| s.lines().count() as u64);
    match name {
        "Edit" if input.get("new_string").is_some() => {
            Some((count(&input["new_string"]), count(&input["old_string"])))
        }
        "MultiEdit" => Some(
            input["edits"]
                .as_array()
                .into_iter()
                .flatten()
                .fold((0, 0), |(a, r), e| {
                    (a + count(&e["new_string"]), r + count(&e["old_string"]))
                }),
        ),
        "Write" if input.get("content").is_some() => Some((count(&input["content"]), 0)),
        _ => None,
    }
}

/// The lines a unified diff adds and removes (Codex's file changes).
pub fn diff_lines(diff: &str) -> (u64, u64) {
    diff.lines().fold((0, 0), |(a, r), line| {
        if line.starts_with("+++") || line.starts_with("---") {
            (a, r)
        } else if line.starts_with('+') {
            (a + 1, r)
        } else if line.starts_with('-') {
            (a, r + 1)
        } else {
            (a, r)
        }
    })
}

/// `text` with the secrets obid holds taken out, and anything the scan calls a secret whole.
fn mask(text: &str) -> String {
    let text = crate::secrets::known().redact(text);
    if crate::scan::matches(&text).is_empty() {
        text
    } else {
        "[redacted]".into()
    }
}

/// `input` with [`mask`] on every string in it.
fn masked(input: &Value) -> Value {
    match input {
        Value::String(text) => Value::String(mask(text)),
        Value::Array(items) => Value::Array(items.iter().map(masked).collect()),
        Value::Object(fields) => {
            Value::Object(fields.iter().map(|(k, v)| (k.clone(), masked(v))).collect())
        }
        other => other.clone(),
    }
}

fn tenths(started: Instant) -> f64 {
    (started.elapsed().as_secs_f64() * 10.0).round() / 10.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    impl Transcripts {
        fn rec(&self, job: &str, event: &Event) -> Vec<Entry> {
            self.record(job, event, Path::new("/w"), None)
        }
    }

    fn transcripts(name: &str) -> Transcripts {
        let home =
            std::env::temp_dir().join(format!("obid-transcript-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        Transcripts::new(&home)
    }

    fn tool_event(id: &str, name: &str, input: Value) -> Event {
        Event::Tool {
            id: id.into(),
            name: name.into(),
            input,
        }
    }

    fn done(id: &str, failed: bool) -> Event {
        Event::ToolDone {
            id: id.into(),
            failed,
            exit: None,
            lines: None,
        }
    }

    #[test]
    fn each_call_is_one_entry_with_its_end() {
        let t = transcripts("calls");
        t.rec("j", &Event::Said("Looking at the scan.\n".into()));
        t.rec(
            "j",
            &tool_event("a", "Bash", json!({"command": "cargo test"})),
        );
        t.rec(
            "j",
            &tool_event(
                "b",
                "Edit",
                json!({"file_path": "/w/src/x.rs", "old_string": "a", "new_string": "b\nc"}),
            ),
        );
        t.rec("j", &done("b", false));
        t.rec("j", &Event::Denied("no".into()));
        t.rec("j", &done("a", true));
        t.rec("j", &done("zz", false));
        let all = t.read("j", 0, PAGE).0;
        assert_eq!(all.len(), 3, "{all:?}");
        assert_eq!(
            (all[0].kind.as_str(), all[0].summary.as_str()),
            ("said", "Looking at the scan.")
        );
        assert_eq!(all[1].summary, "Running cargo test");
        // The refusal came once `b` had ended: it's about `a`, the latest still running.
        assert_eq!(all[1].state.as_deref(), Some("declined"));
        assert_eq!(all[2].tool.as_deref(), Some("Edit"));
        assert_eq!(all[2].state.as_deref(), Some("done"));
        assert_eq!((all[2].added, all[2].removed), (Some(2), Some(1)));
        assert!(all[2].seconds.is_some());
    }

    #[test]
    fn a_refused_call_is_declined() {
        let t = transcripts("declined");
        t.rec(
            "j",
            &tool_event("a", "Bash", json!({"command": "git push"})),
        );
        t.rec("j", &Event::Denied("never".into()));
        t.rec("j", &done("a", true));
        assert_eq!(t.read("j", 0, PAGE).0[0].state.as_deref(), Some("declined"));
    }

    #[test]
    fn after_gives_what_came_or_changed_since() {
        let t = transcripts("after");
        t.rec("j", &tool_event("a", "Read", json!({"file_path": "a.rs"})));
        t.rec("j", &tool_event("b", "Read", json!({"file_path": "b.rs"})));
        t.rec("j", &tool_event("c", "Read", json!({"file_path": "c.rs"})));
        // A client saw up to 2; then `a` ended and 3 came.
        t.rec("j", &done("a", false));
        let since: Vec<(u64, Option<String>)> = t
            .read("j", 2, PAGE)
            .0
            .into_iter()
            .map(|e| (e.n, e.state))
            .collect();
        assert_eq!(
            since,
            [(1, Some("done".into())), (3, Some("running".into()))]
        );
        assert!(t.read("j", 99, PAGE).0.is_empty());
        // Another obid reading the same file numbers on.
        let again = Transcripts::new(&t.home);
        assert_eq!(again.start("j", "Round 2 on Claude Code")[0].n, 4);
    }

    #[test]
    fn todos_from_every_tool() {
        let t = transcripts("todos");
        let entries = t.rec(
            "j",
            &tool_event(
                "p",
                "TodoWrite",
                json!({"todos": [
                {"content": "Read", "status": "completed", "activeForm": "Reading"},
                {"content": "Fix", "status": "in_progress", "activeForm": "Fixing"},
                {"content": "Test", "status": "pending", "activeForm": "Testing"}]}),
            ),
        );
        assert_eq!(entries[0].kind, "plan");
        assert_eq!(entries[0].summary, "1 of 3 done");
        assert_eq!(entries[0].todos.as_ref().unwrap()[1].state, "running");
        t.rec(
            "j",
            &tool_event("t1", "TaskCreate", json!({"subject": "One"})),
        );
        t.rec(
            "j",
            &tool_event("t2", "TaskCreate", json!({"subject": "Two"})),
        );
        let updated = t.rec(
            "j",
            &tool_event(
                "t3",
                "TaskUpdate",
                json!({"taskId": "2", "status": "completed"}),
            ),
        );
        assert_eq!(updated[0].summary, "1 of 2 done");
        // Their ends make no entries.
        assert!(t.rec("j", &done("t3", false)).is_empty());
    }

    #[test]
    fn a_turn_that_ends_ends_its_calls() {
        let t = transcripts("ends");
        t.rec(
            "j",
            &tool_event("a", "Bash", json!({"command": "sleep 100"})),
        );
        let ended = t.end_turn("j");
        assert_eq!(ended[0].state.as_deref(), Some("failed"));
        assert!(t.end_turn("j").is_empty());
    }

    #[test]
    fn secrets_never_reach_the_file() {
        let t = transcripts("secrets");
        let value = ["transcript-", "secret/", "Q7m2+a=b"].concat();
        crate::secrets::known().learn("vault transcript-test", &value);
        t.rec(
            "j",
            &tool_event("a", "Bash", json!({"command": format!("echo {value}")})),
        );
        t.rec("j", &Event::Said(format!("I used {value}")));
        t.you("j", &format!("Use {value}"));
        crate::secrets::known().forget("vault transcript-test");
        let file = std::fs::read_to_string(t.path("j")).unwrap();
        assert!(!file.contains(&value), "{file}");
        assert!(file.contains("[redacted"), "{file}");
    }

    #[test]
    fn diffs_count_their_lines() {
        assert_eq!(
            diff_lines("--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-a\n+b\n+c\n d\n"),
            (2, 1)
        );
    }

    #[test]
    fn reads_come_in_pages() {
        let t = transcripts("pages");
        for n in 0..5 {
            t.rec(
                "j",
                &tool_event(&format!("c{n}"), "Read", json!({"file_path": "a.rs"})),
            );
        }
        t.rec("j", &done("c0", false));
        let (first, next) = t.read("j", 0, 2);
        assert_eq!(first.iter().map(|e| e.n).collect::<Vec<_>>(), [1, 2]);
        assert_eq!(first[0].state.as_deref(), Some("done"));
        assert_eq!(next, Some(2));
        // Call 1 ended after entry 2 came: it comes again, beside the newer page.
        let (rest, next) = t.read("j", 2, 2);
        assert_eq!(rest.iter().map(|e| e.n).collect::<Vec<_>>(), [1, 3, 4]);
        assert_eq!(next, Some(4));
        let (last, next_after) = t.read("j", 4, 2);
        assert_eq!(last.iter().map(|e| e.n).collect::<Vec<_>>(), [1, 5]);
        assert_eq!(next_after, None);
        t.rec("j", &done("c1", false));
        let (again, _) = t.read("j", 2, 2);
        assert_eq!(again.iter().map(|e| e.n).collect::<Vec<_>>(), [1, 2, 3, 4]);
        // A job whose turn is over is read from its file, the same.
        t.forget("j");
        assert_eq!(t.read("j", 0, PAGE).0.len(), 5);
        assert!(t.live.lock().unwrap().is_empty());
    }

    #[test]
    fn a_full_transcript_takes_no_more() {
        let t = transcripts("full");
        let todos: Vec<Todo> = (0..80)
            .map(|i| Todo {
                text: format!("item {i}"),
                state: "pending".into(),
            })
            .collect();
        let entry = t.rec("j", &Event::Plan(todos)).remove(0);
        assert_eq!(entry.todos.as_ref().unwrap().len(), TODOS);
        assert_eq!(entry.summary, "0 of 80 done");
        // Near its size: a line that would pass it isn't written.
        let size = std::fs::metadata(t.path("j")).unwrap().len();
        t.live.lock().unwrap().get_mut("j").unwrap().bytes = MOST_BYTES - 10;
        assert!(t.rec("j", &Event::Said("words".into())).is_empty());
        assert_eq!(std::fs::metadata(t.path("j")).unwrap().len(), size);
        // At its count: no entry past it.
        let t = transcripts("full-count");
        t.rec("j", &Event::Said("words".into()));
        t.live.lock().unwrap().get_mut("j").unwrap().last = MOST_ENTRIES - 1;
        let kept: Vec<u64> = (0..3)
            .flat_map(|_| t.rec("j", &Event::Said("words".into())))
            .map(|e| e.n)
            .collect();
        assert_eq!(kept, [MOST_ENTRIES]);
    }

    #[test]
    fn a_full_transcript_still_ends_its_calls() {
        let t = transcripts("full-ends");
        t.rec(
            "j",
            &tool_event("a", "Bash", json!({"command": "cargo test"})),
        );
        t.rec("j", &tool_event("b", "Read", json!({"file_path": "x.rs"})));
        t.live.lock().unwrap().get_mut("j").unwrap().bytes = MOST_BYTES;
        // A new call isn't kept, and neither is its end; the calls already written end.
        assert!(
            t.rec("j", &tool_event("c", "Read", json!({"file_path": "y.rs"})))
                .is_empty()
        );
        assert_eq!(
            t.rec("j", &done("a", false))[0].state.as_deref(),
            Some("done")
        );
        assert!(t.rec("j", &done("c", false)).is_empty());
        let ended = t.end_turn("j");
        assert_eq!(ended.iter().map(|e| e.n).collect::<Vec<_>>(), [2]);
        t.forget("j");
        let states: Vec<Option<String>> = t
            .read("j", 0, PAGE)
            .0
            .into_iter()
            .map(|e| e.state)
            .collect();
        assert_eq!(states, [Some("done".into()), Some("failed".into())]);
    }

    #[test]
    fn an_unknown_tools_name_is_masked_and_cut() {
        let t = transcripts("names");
        let value = ["name-", "secret/", "Z9q+r=s"].concat();
        crate::secrets::known().learn("vault transcript-name", &value);
        let long = format!("{value} {}", "x".repeat(500));
        let entry = t.rec("j", &tool_event("a", &long, json!({}))).remove(0);
        crate::secrets::known().forget("vault transcript-name");
        let tool = entry.tool.unwrap();
        assert!(
            !tool.contains(&value) && tool.chars().count() <= NAME,
            "{tool}"
        );
        assert!(
            entry.summary.chars().count() <= SUMMARY,
            "{}",
            entry.summary
        );
        assert!(!entry.summary.contains(&value), "{}", entry.summary);
    }

    #[test]
    fn the_task_list_carries_on_after_a_turn() {
        let t = transcripts("tasks");
        t.rec(
            "j",
            &tool_event("t1", "TaskCreate", json!({"subject": "One"})),
        );
        t.forget("j");
        let updated = t.rec(
            "j",
            &tool_event(
                "t2",
                "TaskUpdate",
                json!({"taskId": "1", "status": "completed"}),
            ),
        );
        assert_eq!(updated[0].summary, "1 of 1 done");
        assert_eq!(updated[0].n, 2);
    }

    #[test]
    fn old_transcripts_are_swept() {
        let t = transcripts("sweep");
        t.start("old", "Started on Claude Code");
        t.start("new", "Started on Claude Code");
        t.sweep(|id| id == "new");
        assert!(!t.path("old").exists());
        assert!(t.path("new").exists());
    }

    #[test]
    fn files_outside_the_worktree_show_only_their_name() {
        let w = Path::new("/w");
        let file = |path: &str| file_of(&json!({"file_path": path}), w);
        assert_eq!(file("/w/src/a.rs").as_deref(), Some("src/a.rs"));
        assert_eq!(file("src/a.rs").as_deref(), Some("src/a.rs"));
        assert_eq!(file("/Users/me/.ssh/config").as_deref(), Some("config"));
        assert_eq!(file("../../etc/hosts").as_deref(), Some("hosts"));
    }
}
