//! A job's transcript (#381; docs/runner-api.md, "GET /v1/jobs/{id}/transcript"): one entry per
//! tool call, the agent's words between them, the owner's words, its to-do list and each round's
//! start, live. Kept in `home/jobs/<id>/transcript.jsonl` (0600): one JSON line per change, each
//! entry numbered `n` in order; a tool call that ends is written again under its `n`. The agent's
//! words and thoughts are whole, and stream in as it writes them (#784). What a call took in and
//! gave back (crate::detail) is kept apart, in `transcript-detail.jsonl`, and served only when an
//! entry is opened. Everything is masked (crate::detail::mask) before it's written.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Instant;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

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
/// How much of what a job's calls took in and gave back obid keeps (crate::detail).
pub const MOST_DETAIL_BYTES: u64 = 32 * 1024 * 1024;

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
    /// The whole text of the agent's words (`said`), its thinking (`thought`) or the owner's
    /// words (`you`), masked: `summary` is its first 300 characters on one line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
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

/// What [`Transcripts::record`] changed: an entry written (new, or again), or words added to the
/// `said` entry `n` as the agent writes them, not written until the words are whole.
#[derive(Debug, Clone, PartialEq)]
pub enum Change {
    Entry(Box<Entry>),
    Append { n: u64, text: String },
}

impl From<Entry> for Change {
    fn from(entry: Entry) -> Change {
        Change::Entry(Box::new(entry))
    }
}

/// The words the agent is writing: the entry they go to once a line is whole, and what's not
/// out yet: the line not whole yet (a line is masked only once it's whole, since the scan judges
/// whole lines), and whole lines held back while a secret could go on over them.
#[derive(Default)]
struct Writing {
    n: Option<u64>,
    pending: String,
    /// The line being written went past [`crate::detail::TEXT_BYTES`]: dropped until it ends
    /// (the whole message, masked, replaces the words when it ends).
    skipping: bool,
    /// What's held back went past [`crate::detail::TEXT_BYTES`] (a message mostly of base64, a
    /// key that never ends): the message streams no more, and its whole text replaces it.
    stopped: bool,
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
    /// The calls not ended yet: their entry, when they started, and their detail so far.
    open: HashMap<String, (Entry, Instant, Value)>,
    writing: Option<Writing>,
    /// The detail file's size, where each entry's latest detail is in it, and whether it's full.
    detail_bytes: u64,
    details: HashMap<u64, (u64, u64)>,
    detail_full: bool,
    /// The call obid declined last: its end says `declined`, not `failed`.
    declined: Option<String>,
    /// Claude Code's `TaskCreate`/`TaskUpdate` list, in the order the tasks were made.
    tasks: Vec<Todo>,
    /// The `thought` entry of the thinking going on now, and when it began.
    thinking: Option<(u64, Instant)>,
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

    fn detail_path(&self, job: &str) -> PathBuf {
        self.home
            .join("jobs")
            .join(job)
            .join("transcript-detail.jsonl")
    }

    /// Takes in what the agent did in `worktree`, where the job's check is `check`; the entries
    /// it wrote or changed, in order.
    pub fn record(
        &self,
        job: &str,
        event: &Event,
        worktree: &Path,
        check: Option<&str>,
    ) -> Vec<Change> {
        let mut all = self.live.lock().unwrap_or_else(|e| e.into_inner());
        let live = self.live_for(&mut all, job);
        let mut details: Vec<(u64, Value)> = Vec::new();
        let entries = match event {
            Event::Tool { id, name, input } => {
                let entries = tool(live, id, name, input, worktree, check);
                if let Some((entry, _, detail)) = live.open.get(id) {
                    details.push((entry.n, detail.clone()));
                }
                entries
            }
            Event::ToolDone {
                id,
                failed,
                exit,
                lines,
                output,
                patches,
            } => live
                .open
                .remove(id)
                .map(|(mut entry, started, mut detail)| {
                    if let Some(output) = output {
                        detail["output"] = crate::detail::output(output, *exit);
                    }
                    if !patches.is_empty() {
                        detail["diff"] = patches
                            .iter()
                            .map(|(path, patch)| {
                                crate::detail::patch(
                                    &shown_path(path, worktree),
                                    &placed(patch, worktree),
                                )
                            })
                            .collect();
                    }
                    details.push((entry.n, detail));
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
                    .max_by_key(|(_, (e, _, _))| e.n)
                    .map(|(id, _)| id.clone());
                vec![]
            }
            Event::Delta(words) => {
                let (entries, appends) = writing(live, words);
                if !appends.is_empty() {
                    return appends;
                }
                entries
            }
            Event::Said(words) => match live.writing.take().and_then(|w| w.n) {
                // The words it was writing, now whole: the entry again, with all of them.
                Some(n) => live
                    .now
                    .get(&n)
                    .cloned()
                    .map(|mut entry| {
                        let text = crate::detail::masked(words);
                        entry.summary = crate::brain::briefing::line(&text, WORDS);
                        entry.text = Some(text);
                        vec![entry]
                    })
                    .unwrap_or_default(),
                None => said(live, "said", words),
            },
            Event::Thinking { ended: false } => {
                let mut entry = entry(live, "thought", None, "Thinking".into());
                entry.state = Some("running".into());
                live.thinking = Some((entry.n, Instant::now()));
                vec![entry]
            }
            Event::Thinking { ended: true } => live
                .thinking
                .take()
                .and_then(|(n, began)| {
                    let mut entry = live.now.get(&n)?.clone();
                    entry.state = Some("done".into());
                    entry.seconds = Some(tenths(began));
                    Some(vec![entry])
                })
                .unwrap_or_default(),
            // Its words, when the tool gives them: in the thought it just had, while that's the
            // latest entry and has none yet, else an entry of their own.
            Event::Thought { text, seconds } => match live.now.get(&live.last) {
                Some(last)
                    if last.kind == "thought" && last.text.is_none() && !text.trim().is_empty() =>
                {
                    let mut entry = last.clone();
                    let words = crate::detail::masked(text);
                    entry.summary = crate::brain::briefing::line(&words, WORDS);
                    entry.text = Some(words);
                    entry.seconds = seconds.or(entry.seconds);
                    vec![entry]
                }
                _ => {
                    let mut entries = said(live, "thought", text);
                    for entry in &mut entries {
                        entry.seconds = *seconds;
                    }
                    entries
                }
            },
            Event::Plan(todos) => vec![plan(live, todos.clone())],
            Event::Session(_) | Event::Step(_) | Event::Usage(_) | Event::Tokens(_) => vec![],
        };
        let written = self.write(job, live, entries);
        for (n, detail) in details {
            if live.now.contains_key(&n) {
                self.write_detail(job, live, n, &detail);
            }
        }
        written.into_iter().map(Change::from).collect()
    }

    /// The entry `n` as it is now, and its detail (crate::detail): none for an entry that has
    /// none, `{"kept": false}` for a call whose detail came once the job's was full. `None` for
    /// an entry the transcript doesn't have.
    pub fn detail(&self, job: &str, n: u64) -> Option<(Entry, Option<Value>)> {
        let all = self.live.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(live) = all.get(job) {
            let entry = live.now.get(&n)?.clone();
            let detail = live
                .details
                .get(&n)
                .and_then(|&(at, len)| read_at(&self.detail_path(job), at, len))
                .and_then(|line| detail_of(&line));
            let full = live.detail_full;
            return Some((entry.clone(), detail.or_else(|| not_kept(&entry, full))));
        }
        drop(all);
        // A job whose agent isn't running: its files, read once through (they're bounded).
        let entry: Entry = serde_json::from_slice(&last_line(&self.path(job), n)?).ok()?;
        let path = self.detail_path(job);
        let detail = last_line(&path, n).and_then(|line| detail_of(&line));
        let full = std::fs::metadata(&path).is_ok_and(|m| m.len() + 4096 > MOST_DETAIL_BYTES);
        let kept = detail.or_else(|| not_kept(&entry, full));
        Some((entry, kept))
    }

    /// Adds an entry's detail to the detail file, unless it's full.
    fn write_detail(&self, job: &str, live: &mut Live, n: u64, detail: &Value) {
        let line = format!("{{\"n\":{n},\"detail\":{detail}}}\n");
        if live.detail_full || live.detail_bytes + line.len() as u64 > MOST_DETAIL_BYTES {
            if !live.detail_full {
                live.detail_full = true;
                tracing::warn!("job {job}'s transcript detail is full: obid keeps no more of it");
            }
            return;
        }
        match append(&self.detail_path(job), &line) {
            Ok(()) => {
                live.details
                    .insert(n, (live.detail_bytes, line.len() as u64));
                live.detail_bytes += line.len() as u64;
            }
            Err(e) => tracing::error!("can't keep job {job}'s transcript detail: {e}"),
        }
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

    /// What the job was asked, once, as the session's first words from you (its `request`);
    /// nothing when a `you` entry is there already (a job tried again).
    pub fn asked(&self, job: &str, request: &str) -> Vec<Entry> {
        self.note(job, |live| {
            if live.now.values().any(|entry| entry.kind == "you") {
                return vec![];
            }
            said(live, "you", request)
        })
    }

    /// A round began: `summary` says which, on which tool.
    pub fn start(&self, job: &str, summary: &str) -> Vec<Entry> {
        self.note(job, |live| {
            vec![entry(live, "start", None, crate::detail::mask(summary))]
        })
    }

    /// The turn is over: a call that never ended (the agent was stopped or died) failed.
    pub fn end_turn(&self, job: &str) -> Vec<Entry> {
        self.note(job, |live| {
            // Words it was writing that never came whole: what came is what it said, masked, held
            // back lines and all. A message that stopped streaming (what it held passed the cap)
            // dropped what it held then, on purpose: past the cap, it's not kept.
            let mut words: Vec<Entry> = match live.writing.take() {
                Some(Writing {
                    n: Some(n),
                    pending,
                    ..
                }) => live
                    .now
                    .get(&n)
                    .cloned()
                    .map(|mut entry| {
                        let mut text = entry.text.clone().unwrap_or_default();
                        text.push_str(&crate::detail::mask(&pending));
                        entry.summary = crate::brain::briefing::line(&text, WORDS);
                        entry.text = Some(crate::detail::capped(&text));
                        entry
                    })
                    .into_iter()
                    .collect(),
                Some(Writing {
                    n: None, pending, ..
                }) => said(live, "said", &pending),
                None => vec![],
            };
            let mut ended: Vec<Entry> = live
                .open
                .drain()
                .map(|(_, (mut entry, started, _))| {
                    entry.state = Some("failed".into());
                    entry.seconds = Some(tenths(started));
                    entry
                })
                .collect();
            // Thinking it never stopped: it thought for as long as it went on.
            if let Some((n, began)) = live.thinking.take()
                && let Some(mut entry) = live.now.get(&n).cloned()
            {
                entry.state = Some("done".into());
                entry.seconds = Some(tenths(began));
                ended.push(entry);
            }
            ended.sort_by_key(|e| e.n);
            words.extend(ended);
            words
        })
    }

    /// A job deleted: its transcript and detail, in memory and in their files, and their folder.
    pub fn remove(&self, job: &str) {
        self.forget(job);
        let _ = std::fs::remove_file(self.path(job));
        let _ = std::fs::remove_file(self.detail_path(job));
        if let Some(folder) = self.path(job).parent() {
            let _ = std::fs::remove_dir(folder);
        }
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
        let detail = self.detail_path(job);
        live.detail_bytes = std::fs::metadata(&detail).map_or(0, |m| m.len());
        live.detail_full = live.detail_bytes + 4096 > MOST_DETAIL_BYTES;
        if let Ok(file) = std::fs::File::open(&detail) {
            let mut at = 0;
            for line in std::io::BufReader::new(file)
                .split(b'\n')
                .map_while(Result::ok)
            {
                if let Some(n) = n_of(&line) {
                    live.details.insert(n, (at, line.len() as u64 + 1));
                }
                at += line.len() as u64 + 1;
            }
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
                let _ = std::fs::remove_file(path.join("transcript-detail.jsonl"));
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

/// An entry of words (`said`, `thought`, `you`): all of them, masked, and their first line.
fn said(live: &mut Live, kind: &str, words: &str) -> Vec<Entry> {
    let text = crate::detail::masked(words);
    let summary = crate::brain::briefing::line(&text, WORDS);
    if summary.is_empty() {
        return vec![];
    }
    let mut entry = entry(live, kind, None, summary);
    entry.text = Some(text);
    vec![entry]
}

/// Words as the agent writes them: each whole line, masked, goes to its `said` entry (made with
/// the first) as an append. The entries made, or the appends.
fn writing(live: &mut Live, words: &str) -> (Vec<Entry>, Vec<Change>) {
    let open = live.writing.get_or_insert_with(Writing::default);
    if open.stopped {
        return (vec![], vec![]);
    }
    for piece in words.split_inclusive('\n') {
        if !open.skipping {
            open.pending.push_str(piece);
        }
        let line = open.pending.rsplit('\n').next().unwrap_or("");
        if !open.skipping && line.len() > crate::detail::TEXT_BYTES {
            // A line this long isn't streamed: what's pending of it is dropped.
            let start = open.pending.len() - line.len();
            open.pending.truncate(start);
            open.skipping = true;
        }
        if piece.ends_with('\n') {
            open.skipping = false;
        }
    }
    let ready = open.pending.rfind('\n').map_or(0, |cut| cut + 1);
    let lines: Vec<&str> = open.pending[..ready].split_inclusive('\n').collect();
    let out: usize = lines[..lines.len() - held(&lines)]
        .iter()
        .map(|l| l.len())
        .sum();
    if out == 0 {
        // Held back past the cap, it would be read again at every delta: it waits for the end.
        if open.pending.len() > crate::detail::TEXT_BYTES {
            open.pending.clear();
            open.stopped = true;
        }
        return (vec![], vec![]);
    }
    let lines: String = open.pending.drain(..out).collect();
    let n = open.n;
    let text = crate::detail::mask(&lines);
    match n.and_then(|n| live.now.get_mut(&n)) {
        Some(entry) => {
            let had = entry.text.get_or_insert_with(String::new);
            // Past its cap the words stop growing here; the whole message replaces them.
            if had.len() >= crate::detail::TEXT_BYTES {
                return (vec![], vec![]);
            }
            had.push_str(&text);
            (vec![], vec![Change::Append { n: entry.n, text }])
        }
        None => {
            let entries = said(live, "said", &text);
            if let (Some(entry), Some(open)) = (entries.first(), live.writing.as_mut()) {
                open.n = Some(entry.n);
            }
            (entries, vec![])
        }
    }
}

/// How many of these whole lines, at the end, wait for more before they go out: a private key not
/// ended yet (from its BEGIN line), and a run of base64 or hex lines (with the line before it,
/// which a run can continue), since a secret over lines is only found once it's all there.
fn held(lines: &[&str]) -> usize {
    let open_key = lines
        .iter()
        .rposition(|l| crate::detail::key_begins(l))
        .filter(|&begin| !lines[begin..].iter().any(|l| l.contains("-----END")))
        .map_or(0, |begin| lines.len() - begin);
    open_key.max(crate::detail::encoded_tail(lines))
}

fn plan(live: &mut Live, todos: Vec<Todo>) -> Entry {
    let todos: Vec<Todo> = todos
        .into_iter()
        .map(|t| Todo {
            text: crate::brain::briefing::line(&crate::detail::mask(&t.text), WORDS),
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
            let shown = crate::brain::briefing::line(&crate::detail::mask(name), NAME);
            let input_kept = crate::detail::input(input);
            let summary = crate::brain::briefing::line(
                &crate::detail::mask(&agent::step(&shown, &input_kept)),
                SUMMARY,
            );
            let mut entry = entry(live, "tool", Some(&shown), summary);
            entry.state = Some("running".into());
            entry.activity = Some(crate::activity::kind(name, input, check).into());
            entry.file = file_of(input, worktree);
            if let Some((added, removed)) = edited(name, input) {
                (entry.added, entry.removed) = (Some(added), Some(removed));
            }
            let mut detail = json!({"input": input_kept});
            let path = entry.file.clone().unwrap_or_default();
            if let Some(patch) = crate::detail::from_input(name, input, &path) {
                detail["diff"] = json!([crate::detail::patch(&path, &patch)]);
            }
            live.open
                .insert(id.to_owned(), (entry.clone(), Instant::now(), detail));
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
    Some(crate::brain::briefing::line(
        &crate::detail::mask(&shown),
        SUMMARY,
    ))
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

/// A file change's path as the transcript shows it: from the worktree, or only its name.
fn shown_path(path: &str, worktree: &Path) -> String {
    file_of(&json!({ "path": path }), worktree).unwrap_or_default()
}

/// A diff with the worktree's own path taken off its file names, and the home folder as `[home]`.
fn placed(patch: &str, worktree: &Path) -> String {
    let real = crate::policy::real_path(worktree).unwrap_or_else(|| worktree.to_path_buf());
    let mut patch = patch.to_owned();
    for root in [worktree, real.as_path()] {
        patch = patch.replace(&format!("{}/", root.display()), "");
    }
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() => patch.replace(&home, "[home]"),
        _ => patch,
    }
}

/// Appends `text` to the file at `path` (0600), making its folder (0700).
fn append(path: &Path, text: &str) -> std::io::Result<()> {
    crate::store::make_private_dir(path.parent().expect("a folder"))?;
    let mut options = std::fs::OpenOptions::new();
    options.append(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)?.write_all(text.as_bytes())
}

/// The `n` a transcript or detail line starts with (`{"n":12,…`), read without the rest.
fn n_of(line: &[u8]) -> Option<u64> {
    let rest = line.strip_prefix(b"{\"n\":")?;
    let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
    std::str::from_utf8(&rest[..digits]).ok()?.parse().ok()
}

/// The last line of the file at `path` for entry `n`.
fn last_line(path: &Path, n: u64) -> Option<Vec<u8>> {
    let file = std::fs::File::open(path).ok()?;
    std::io::BufReader::new(file)
        .split(b'\n')
        .map_while(Result::ok)
        .filter(|line| n_of(line) == Some(n))
        .last()
}

/// The line `len` bytes long at `at` in the file at `path`.
fn read_at(path: &Path, at: u64, len: u64) -> Option<Vec<u8>> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    file.seek(SeekFrom::Start(at)).ok()?;
    let mut line = vec![0; usize::try_from(len).ok()?];
    file.read_exact(&mut line).ok()?;
    Some(line)
}

/// A detail line's `detail`.
fn detail_of(line: &[u8]) -> Option<Value> {
    let value: Value = serde_json::from_slice(line).ok()?;
    Some(value.get("detail")?.clone())
}

/// What a call's detail says once the job's detail was full when it came.
fn not_kept(entry: &Entry, full: bool) -> Option<Value> {
    (full && entry.kind == "tool").then(|| json!({"kept": false}))
}

fn tenths(started: Instant) -> f64 {
    (started.elapsed().as_secs_f64() * 10.0).round() / 10.0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A private key's armor line, put together here so no source line holds one whole (the
    /// secret scan of this repository would take the test's made-up key for a real one).
    fn armor(kind: &str, end: bool) -> String {
        let edge = if end { "END" } else { "BEGIN" };
        format!("-----{edge} {kind}PRIVATE {}-----", "KEY")
    }
    use serde_json::json;

    impl Transcripts {
        fn rec(&self, job: &str, event: &Event) -> Vec<Entry> {
            self.record(job, event, Path::new("/w"), None)
                .into_iter()
                .filter_map(|c| match c {
                    Change::Entry(entry) => Some(*entry),
                    Change::Append { .. } => None,
                })
                .collect()
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
            output: None,
            patches: vec![],
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
        assert!(file.contains("[vault: transcript-test]"), "{file}");
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
    fn the_request_is_the_first_words_from_you_once() {
        let t = transcripts("asked");
        t.start("j", "Started on Claude Code");
        let asked = t.asked("j", "Review pull request #350.");
        assert_eq!(asked.len(), 1);
        assert_eq!((asked[0].kind.as_str(), asked[0].n), ("you", 2));
        assert_eq!(asked[0].text.as_deref(), Some("Review pull request #350."));
        // Tried again: the request isn't said twice.
        t.start("j", "Started on Claude Code");
        assert!(t.asked("j", "Review pull request #350.").is_empty());
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

    #[test]
    fn words_stream_in_whole_lines_and_end_whole() {
        let t = transcripts("stream");
        let all = |e: &Event| t.record("j", e, Path::new("/w"), None);
        assert!(all(&Event::Delta("First li".into())).is_empty());
        let made = all(&Event::Delta("ne.\nSecond".into()));
        let Change::Entry(entry) = &made[0] else {
            panic!("{made:?}")
        };
        assert_eq!(
            (entry.kind.as_str(), entry.text.as_deref()),
            ("said", Some("First line.\n"))
        );
        let n = entry.n;
        let more = all(&Event::Delta(" line.\nThird".into()));
        assert_eq!(
            more,
            [Change::Append {
                n,
                text: "Second line.\n".into()
            }]
        );
        // The whole message replaces what came, under the same n.
        let whole = "First line.\nSecond line.\nThird line, at last.";
        let ended = all(&Event::Said(whole.into()));
        let Change::Entry(entry) = &ended[0] else {
            panic!("{ended:?}")
        };
        assert_eq!((entry.n, entry.text.as_deref()), (n, Some(whole)));
        assert_eq!(
            entry.summary,
            "First line. Second line. Third line, at last."
        );
        // The next words are a new entry.
        let next = all(&Event::Delta("Again.\n".into()));
        assert!(matches!(&next[0], Change::Entry(e) if e.n == n + 1));
        // A turn that ends mid-message keeps what came.
        all(&Event::Delta("cut sh".into()));
        let ended = t.end_turn("j");
        assert_eq!(ended[0].text.as_deref(), Some("Again.\ncut sh"));
    }

    #[test]
    fn a_secret_split_across_deltas_never_streams() {
        let t = transcripts("stream-secret");
        let value = ["stream-", "secret/", "Q7m2+a=b"].concat();
        crate::secrets::known().learn("vault stream-test", &value);
        let (a, b) = value.split_at(8);
        let mut out = String::new();
        for piece in [format!("key {a}"), format!("{b} ok\n")] {
            for change in t.record("j", &Event::Delta(piece), Path::new("/w"), None) {
                out.push_str(&format!("{change:?}"));
            }
        }
        crate::secrets::known().forget("vault stream-test");
        assert!(!out.contains(a) && !out.contains(b), "{out}");
        assert!(out.contains("[vault: stream-test]"), "{out}");
    }

    #[test]
    fn thinking_shows_while_it_goes_on_with_no_words() {
        let t = transcripts("thinking");
        let began = t.rec("j", &Event::Thinking { ended: false });
        assert_eq!(
            (
                began[0].kind.as_str(),
                began[0].summary.as_str(),
                began[0].state.as_deref()
            ),
            ("thought", "Thinking", Some("running"))
        );
        assert_eq!(began[0].text, None);
        let ended = t.rec("j", &Event::Thinking { ended: true });
        assert_eq!(
            (ended[0].n, ended[0].state.as_deref()),
            (began[0].n, Some("done"))
        );
        assert!(ended[0].seconds.is_some());
        // Words that come for it afterwards fill it, rather than making a second thought.
        let words = t.rec(
            "j",
            &Event::Thought {
                text: "Maybe the scan.".into(),
                seconds: None,
            },
        );
        assert_eq!(words[0].n, began[0].n);
        assert_eq!(words[0].text.as_deref(), Some("Maybe the scan."));
        assert_eq!(words[0].seconds, ended[0].seconds);
        // A turn that ends mid-thought ends the thought too.
        let again = t.rec("j", &Event::Thinking { ended: false });
        let closed = t.end_turn("j");
        assert_eq!(
            (closed[0].n, closed[0].state.as_deref()),
            (again[0].n, Some("done"))
        );
    }

    #[test]
    fn thoughts_are_entries_of_their_own() {
        let t = transcripts("thoughts");
        let e = t.rec(
            "j",
            &Event::Thought {
                text: "Maybe the scan.\nOr the check.".into(),
                seconds: Some(1.5),
            },
        );
        assert_eq!((e[0].kind.as_str(), e[0].seconds), ("thought", Some(1.5)));
        assert_eq!(e[0].text.as_deref(), Some("Maybe the scan.\nOr the check."));
    }

    #[test]
    fn a_call_keeps_its_input_output_and_diff_apart() {
        let t = transcripts("detail");
        let w = Path::new("/w");
        t.record(
            "j",
            &tool_event("a", "Bash", json!({"command": "cargo test --all"})),
            w,
            None,
        );
        t.record(
            "j",
            &tool_event(
                "b",
                "Edit",
                json!({"file_path": "/w/src/x.rs", "old_string": "a", "new_string": "b"}),
            ),
            w,
            None,
        );
        // Running, its input is there already.
        let (_, running) = t.detail("j", 1).unwrap();
        assert_eq!(running.unwrap()["input"]["command"], "cargo test --all");
        let output: String = (1..=300).map(|i| format!("test {i} ok\n")).collect();
        t.record(
            "j",
            &Event::ToolDone {
                id: "a".into(),
                failed: true,
                exit: Some(101),
                lines: None,
                output: Some(output),
                patches: vec![],
            },
            w,
            None,
        );
        t.record("j", &done("b", false), w, None);
        let (entry, detail) = t.detail("j", 1).unwrap();
        let detail = detail.unwrap();
        assert_eq!(entry.state.as_deref(), Some("failed"));
        assert_eq!(detail["output"]["lines"], 300);
        assert_eq!(detail["output"]["exit"], 101);
        assert_eq!(detail["output"]["truncated"], true);
        assert!(
            detail["output"]["text"]
                .as_str()
                .unwrap()
                .starts_with("test 101 ok\n")
        );
        let (_, edit) = t.detail("j", 2).unwrap();
        assert_eq!(
            edit.unwrap()["diff"][0],
            json!({"path": "src/x.rs", "patch": "--- a/src/x.rs\n+++ b/src/x.rs\n@@ -1,1 +1,1 @@\n-a\n+b\n"})
        );
        // The list never carries it, and once the turn is over it's read from the files.
        assert!(
            std::fs::read_to_string(t.path("j"))
                .unwrap()
                .find("test 101")
                .is_none()
        );
        t.forget("j");
        let (_, again) = t.detail("j", 1).unwrap();
        assert_eq!(again.unwrap()["output"]["lines"], 300);
        assert!(t.detail("j", 99).is_none());
    }

    #[test]
    fn a_full_detail_file_says_so() {
        let t = transcripts("detail-full");
        let w = Path::new("/w");
        t.record(
            "j",
            &tool_event("a", "Bash", json!({"command": "ls"})),
            w,
            None,
        );
        t.live.lock().unwrap().get_mut("j").unwrap().detail_bytes = MOST_DETAIL_BYTES;
        t.record(
            "j",
            &tool_event("b", "Bash", json!({"command": "pwd"})),
            w,
            None,
        );
        assert_eq!(t.detail("j", 2).unwrap().1, Some(json!({"kept": false})));
        assert_eq!(
            t.detail("j", 1).unwrap().1.unwrap()["input"]["command"],
            "ls"
        );
    }

    #[test]
    fn a_secret_over_lines_never_streams_in_halves() {
        let t = transcripts("stream-key");
        let stream = |piece: &str| -> String {
            t.record("j", &Event::Delta(piece.into()), Path::new("/w"), None)
                .iter()
                .map(|change| format!("{change:?}"))
                .collect()
        };
        let mut out = String::new();
        out += &stream("Here it is:\n");
        out += &stream(&format!("{}\n", armor("OPENSSH ", false)));
        out += &stream("b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\n");
        out += &stream("AAAAAAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAI\n");
        assert!(!out.contains("b3BlbnNzaC1"), "{out}");
        out += &stream(&format!("{}\nThat was it.\n", armor("OPENSSH ", true)));
        assert!(
            !out.contains("b3BlbnNzaC1") && !out.contains("AAAAAAAAAAEAAAAz"),
            "{out}"
        );
        assert!(
            out.contains("[redacted: private key") && out.contains("That was it."),
            "{out}"
        );
        // A token in base64 over lines waits until a line that isn't.
        let token = ["ghp_", "abcdefghijklmnopqrstuvwxyz0123456789"].concat();
        let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &token);
        let (one, two) = b64.split_at(28);
        let mut out = String::new();
        for piece in [format!("{one}\n"), format!("{two}\n"), "Done.\n".into()] {
            for change in t.record("j", &Event::Delta(piece), Path::new("/w"), None) {
                out.push_str(&format!("{change:?}"));
            }
        }
        assert!(!out.contains(one) && !out.contains(two), "{out}");
    }

    #[test]
    fn a_line_too_long_never_streams() {
        let t = transcripts("stream-long");
        let long = "x".repeat(crate::detail::TEXT_BYTES + 10);
        assert!(t.rec("j", &Event::Delta(long.clone())).is_empty());
        assert!(t.rec("j", &Event::Delta(format!("{long}\n"))).is_empty());
        let live = t.live.lock().unwrap();
        assert!(live["j"].writing.as_ref().unwrap().pending.is_empty());
    }

    #[test]
    fn a_removed_transcript_is_gone() {
        let t = transcripts("remove");
        t.record(
            "j",
            &tool_event("a", "Bash", json!({"command": "ls"})),
            Path::new("/w"),
            None,
        );
        assert!(t.path("j").exists() && t.detail_path("j").exists());
        t.remove("j");
        assert!(!t.path("j").parent().unwrap().exists());
        assert!(t.live.lock().unwrap().get("j").is_none());
    }

    #[test]
    fn held_text_past_the_cap_stops_the_stream() {
        let t = transcripts("held-cap");
        assert_eq!(
            t.rec("j", &Event::Delta("Here's the blob:\n".into())).len(),
            1
        );
        // Line after line of base64: held back, never out, until past the cap.
        let line = format!("{}\n", "QUJD".repeat(19));
        let mut out = 0;
        for _ in 0..(crate::detail::TEXT_BYTES / line.len() + 10) {
            out += t
                .record("j", &Event::Delta(line.clone()), Path::new("/w"), None)
                .len();
        }
        assert_eq!(out, 0);
        {
            let live = t.live.lock().unwrap();
            let writing = live["j"].writing.as_ref().unwrap();
            assert!(writing.stopped && writing.pending.is_empty());
        }
        // More words of it stream no more; the whole message replaces them.
        assert!(t.rec("j", &Event::Delta("and more\n".into())).is_empty());
        let whole = t.rec("j", &Event::Said("Here's the blob:\nshort now".into()));
        assert_eq!(
            (whole[0].n, whole[0].text.as_deref()),
            (1, Some("Here's the blob:\nshort now"))
        );
        // The next message streams again.
        assert_eq!(t.rec("j", &Event::Delta("Next.\n".into()))[0].n, 2);
    }
}
