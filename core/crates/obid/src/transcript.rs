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
}

/// One item of the agent's to-do list.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Todo {
    pub text: String,
    /// `pending`, `running` or `done`.
    pub state: String,
}

/// What a running job's transcript holds in memory: the last `n`, the calls not ended yet.
#[derive(Default)]
struct Live {
    last: u64,
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

    /// Takes in what the agent did; the entries it wrote or changed, in order.
    pub fn record(&self, job: &str, event: &Event) -> Vec<Entry> {
        let mut all = self.live.lock().unwrap_or_else(|e| e.into_inner());
        let live = self.live_for(&mut all, job);
        let entries = match event {
            Event::Tool { id, name, input } => tool(live, id, name, input),
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
            Event::Session(_) | Event::Step(_) | Event::Delta(_) => vec![],
        };
        self.write(job, &entries);
        entries
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

    fn note(&self, job: &str, make: impl FnOnce(&mut Live) -> Vec<Entry>) -> Vec<Entry> {
        let mut all = self.live.lock().unwrap_or_else(|e| e.into_inner());
        let entries = make(self.live_for(&mut all, job));
        self.write(job, &entries);
        entries
    }

    fn live_for<'a>(&self, all: &'a mut HashMap<String, Live>, job: &str) -> &'a mut Live {
        all.entry(job.to_owned()).or_insert_with(|| Live {
            last: lines(&self.path(job))
                .iter()
                .map(|e| e.n)
                .max()
                .unwrap_or(0),
            ..Live::default()
        })
    }

    fn write(&self, job: &str, entries: &[Entry]) {
        if entries.is_empty() {
            return;
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
            let mut text = String::new();
            for entry in entries {
                text.push_str(&serde_json::to_string(entry).map_err(std::io::Error::other)?);
                text.push('\n');
            }
            options.open(&path)?.write_all(text.as_bytes())
        })();
        if let Err(e) = written {
            tracing::error!("can't keep job {job}'s transcript: {e}");
        }
    }

    /// The entries that came or changed after entry `after` first did, each as it is now, in
    /// order: everything with `after` 0. A client that saw up to `after` upserts them by `n`.
    pub fn read(&self, job: &str, after: u64) -> Vec<Entry> {
        let lines = lines(&self.path(job));
        let from = if after == 0 {
            0
        } else {
            lines
                .iter()
                .position(|e| e.n == after)
                .map_or(lines.len(), |i| i + 1)
        };
        let changed: std::collections::HashSet<u64> = lines[from..].iter().map(|e| e.n).collect();
        let mut now: HashMap<u64, Entry> = HashMap::new();
        for entry in lines {
            if changed.contains(&entry.n) {
                now.insert(entry.n, entry);
            }
        }
        let mut entries: Vec<Entry> = now.into_values().collect();
        entries.sort_by_key(|e| e.n);
        entries
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
    entry.todos = Some(todos);
    entry
}

/// A tool call starts: its entry, running; or the to-do list it changes.
fn tool(live: &mut Live, id: &str, name: &str, input: &Value) -> Vec<Entry> {
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
            // Masked before it's cut short, so no part of a secret is left.
            let summary = mask(&agent::step(name, &masked(input)));
            let mut entry = entry(live, "tool", Some(name), summary);
            entry.state = Some("running".into());
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
        t.record("j", &Event::Said("Looking at the scan.\n".into()));
        t.record(
            "j",
            &tool_event("a", "Bash", json!({"command": "cargo test"})),
        );
        t.record(
            "j",
            &tool_event(
                "b",
                "Edit",
                json!({"file_path": "/w/src/x.rs", "old_string": "a", "new_string": "b\nc"}),
            ),
        );
        t.record("j", &done("b", false));
        t.record("j", &Event::Denied("no".into()));
        t.record("j", &done("a", true));
        t.record("j", &done("zz", false));
        let all = t.read("j", 0);
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
        t.record(
            "j",
            &tool_event("a", "Bash", json!({"command": "git push"})),
        );
        t.record("j", &Event::Denied("never".into()));
        t.record("j", &done("a", true));
        assert_eq!(t.read("j", 0)[0].state.as_deref(), Some("declined"));
    }

    #[test]
    fn after_gives_what_came_or_changed_since() {
        let t = transcripts("after");
        t.record("j", &tool_event("a", "Read", json!({"file_path": "a.rs"})));
        t.record("j", &tool_event("b", "Read", json!({"file_path": "b.rs"})));
        t.record("j", &tool_event("c", "Read", json!({"file_path": "c.rs"})));
        // A client saw up to 2; then `a` ended and 3 came.
        t.record("j", &done("a", false));
        let since: Vec<(u64, Option<String>)> =
            t.read("j", 2).into_iter().map(|e| (e.n, e.state)).collect();
        assert_eq!(
            since,
            [(1, Some("done".into())), (3, Some("running".into()))]
        );
        assert!(t.read("j", 99).is_empty());
        // Another obid reading the same file numbers on.
        let again = Transcripts::new(&t.home);
        assert_eq!(again.start("j", "Round 2 on Claude Code")[0].n, 4);
    }

    #[test]
    fn todos_from_every_tool() {
        let t = transcripts("todos");
        let entries = t.record(
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
        t.record(
            "j",
            &tool_event("t1", "TaskCreate", json!({"subject": "One"})),
        );
        t.record(
            "j",
            &tool_event("t2", "TaskCreate", json!({"subject": "Two"})),
        );
        let updated = t.record(
            "j",
            &tool_event(
                "t3",
                "TaskUpdate",
                json!({"taskId": "2", "status": "completed"}),
            ),
        );
        assert_eq!(updated[0].summary, "1 of 2 done");
        // Their ends make no entries.
        assert!(t.record("j", &done("t3", false)).is_empty());
    }

    #[test]
    fn a_turn_that_ends_ends_its_calls() {
        let t = transcripts("ends");
        t.record(
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
        t.record(
            "j",
            &tool_event("a", "Bash", json!({"command": format!("echo {value}")})),
        );
        t.record("j", &Event::Said(format!("I used {value}")));
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
}
