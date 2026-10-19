//! A job's activity at a glance (#730; docs/runner-api.md, "activity"): its transcript (#381)
//! summed up as counts of what the agent did by kind, and its session cut into a few groups. A
//! group starts at each of the agent's own words between tool calls and is titled by them (marked
//! as the agent's: `by: "agent"`); tool calls with no words before them group by kind under obid's
//! own fixed title ("Read 14 files", `by: "obid"`). No model writes a title. Also the job's
//! `context`: the agent's latest words, shortened. Built one entry at a time, and bounded: it goes
//! into every `job` event and the saved job.

use std::collections::{HashMap, VecDeque};

use serde_json::{Value, json};

use crate::transcript::Entry;

/// The kinds counted, in the order the apps show them.
pub const KINDS: [&str; 8] = [
    "read", "search", "edit", "command", "test", "tetrix", "web", "mcp",
];

/// How many calls a group takes: past it, the next call starts a group of its own.
const CALLS: usize = 50;
/// How many of its calls a group lists: its last ones.
const SHOWN_RUNNING: usize = 10;
const SHOWN_DONE: usize = 3;
/// How many groups are kept: the latest ones (the counts are the whole job's).
const GROUPS: usize = 20;
/// How many files a group lists.
const FILES: usize = 20;
/// How large the activity may be as JSON: past it, the oldest groups are left out.
const MOST_BYTES: usize = 32 * 1024;
/// How long a title or the context may be.
const TITLE: usize = 80;
const CONTEXT: usize = 200;

/// What a tool call does, by what the tool reports (Claude Code's tool name, Codex's item type,
/// Cursor's call kind), never by words the agent writes: `test` only for a command that is the
/// job's `check` (alone, or the last step of a `&&` chain). `other` is counted nowhere.
pub fn kind(tool: &str, input: &Value, check: Option<&str>) -> &'static str {
    match tool {
        "Read" | "NotebookRead" | "Glob" | "LS" => "read",
        "Grep" => "search",
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => "edit",
        "WebSearch" | "WebFetch" => "web",
        "Bash" => {
            let command = input["command"].as_str().unwrap_or("");
            let check = check.map(str::trim).filter(|c| !c.is_empty());
            let runs_check = check.is_some_and(|c| {
                command.trim() == c || command.rsplit("&&").next().map(str::trim) == Some(c)
            });
            if runs_check { "test" } else { "command" }
        }
        _ => match tool.strip_prefix("mcp__") {
            Some(rest)
                if rest
                    .split("__")
                    .next()
                    .is_some_and(|s| s.contains("tetrix")) =>
            {
                "tetrix"
            }
            Some(_) => "mcp",
            None => "other",
        },
    }
}

/// A job's activity, taken in one transcript entry (new or changed) at a time.
#[derive(Default)]
pub struct Activity {
    counts: HashMap<&'static str, u64>,
    /// The latest groups, the oldest first; `dropped` came before them.
    groups: VecDeque<Group>,
    dropped: usize,
    /// Where each call is: its group (by its place among all groups) and its place in it.
    calls: HashMap<u64, (usize, usize)>,
    /// The agent's words that open the next group.
    words: Option<Entry>,
    /// The last group takes more calls.
    open: bool,
    context: Option<String>,
}

struct Group {
    /// The words that opened it, or its first call.
    first: Entry,
    titled: bool,
    kind: String,
    calls: Vec<Entry>,
}

impl Activity {
    /// Takes in an entry that came or changed.
    pub fn take(&mut self, entry: &Entry) {
        match entry.kind.as_str() {
            "said" => {
                self.words = Some(entry.clone());
                self.open = false;
                self.context = Some(crate::brain::briefing::line(&entry.summary, CONTEXT));
            }
            // A round's start or the owner's words close the group: what follows is new work.
            "start" | "you" => {
                self.words = None;
                self.open = false;
            }
            "tool" => self.call(entry),
            _ => {}
        }
    }

    fn call(&mut self, entry: &Entry) {
        if let Some(&(group, place)) = self.calls.get(&entry.n) {
            if let Some(call) = group
                .checked_sub(self.dropped)
                .and_then(|g| self.groups.get_mut(g))
                .and_then(|g| g.calls.get_mut(place))
            {
                *call = entry.clone();
            }
            return;
        }
        let kind = entry.activity.as_deref().unwrap_or("other");
        if let Some(kind) = KINDS.iter().find(|k| **k == kind) {
            *self.counts.entry(kind).or_default() += 1;
        }
        let joins = self.open
            && self
                .groups
                .back()
                .is_some_and(|g| (g.titled || g.kind == kind) && g.calls.len() < CALLS);
        if !joins {
            self.groups.push_back(Group {
                first: self.words.take().unwrap_or_else(|| entry.clone()),
                titled: false,
                kind: kind.to_owned(),
                calls: vec![],
            });
            let group = self.groups.back_mut().expect("a group");
            group.titled = group.first.kind == "said";
            self.open = true;
            if self.groups.len() > GROUPS {
                self.groups.pop_front();
                self.dropped += 1;
            }
        }
        let index = self.dropped + self.groups.len() - 1;
        let group = self.groups.back_mut().expect("a group");
        group.calls.push(entry.clone());
        let place = (index, group.calls.len() - 1);
        self.calls.insert(entry.n, place);
    }

    /// The job's `activity`: none before its first tool call.
    pub fn to_json(&self) -> Option<Value> {
        if self.groups.is_empty() {
            return None;
        }
        let mut groups: VecDeque<Value> = self.groups.iter().map(Group::to_json).collect();
        let mut size: usize = groups.iter().map(|g| g.to_string().len()).sum();
        while size > MOST_BYTES && groups.len() > 1 {
            size -= groups.pop_front().map_or(0, |g| g.to_string().len());
        }
        Some(json!({"counts": counts(self.counts.iter().map(|(k, n)| (*k, *n))), "groups": groups}))
    }

    /// The job's `context`: the agent's latest words, shortened.
    pub fn context(&self) -> Option<String> {
        self.context.clone()
    }
}

impl Group {
    fn to_json(&self) -> Value {
        let running = self
            .calls
            .iter()
            .any(|t| t.state.as_deref() == Some("running"));
        let failed = self
            .calls
            .last()
            .is_some_and(|t| t.state.as_deref() == Some("failed"));
        let state = if running {
            "running"
        } else if failed {
            "failed"
        } else {
            "done"
        };
        let mut files: Vec<&str> = Vec::new();
        for file in self.calls.iter().filter_map(|t| t.file.as_deref()) {
            if !files.contains(&file) && files.len() < FILES {
                files.push(file);
            }
        }
        let edits: Vec<&Entry> = self.calls.iter().filter(|t| t.added.is_some()).collect();
        let shown = if running { SHOWN_RUNNING } else { SHOWN_DONE };
        let mut group = json!({
            "id": format!("g{}", self.first.n),
            "title": self.title(),
            "by": if self.titled { "agent" } else { "obid" },
            "state": state,
            "started": self.first.at,
            "counts": counts(self.calls.iter().filter_map(|t| t.activity.as_deref()).map(|k| (k, 1))),
            "files": files,
            "tools": self.calls[self.calls.len().saturating_sub(shown)..].iter().map(|t| json!({
                "tool": t.tool, "kind": t.activity, "summary": t.summary, "state": t.state,
                "started": t.at, "seconds": t.seconds,
            })).collect::<Vec<_>>(),
        });
        if !running {
            group["finished"] = json!(self.calls.iter().filter_map(ended).max());
        }
        if !edits.is_empty() {
            group["diff"] = json!({
                "added": edits.iter().filter_map(|t| t.added).sum::<u64>(),
                "removed": edits.iter().filter_map(|t| t.removed).sum::<u64>(),
            });
        }
        group
    }

    fn title(&self) -> String {
        if self.titled {
            return title(&self.first.summary);
        }
        let n = self.calls.len();
        let files = {
            let mut seen: Vec<&str> = self
                .calls
                .iter()
                .filter_map(|t| t.file.as_deref())
                .collect();
            seen.sort_unstable();
            seen.dedup();
            seen.len().max(1)
        };
        let times = |what: &str| {
            if n == 1 {
                what.to_owned()
            } else {
                format!("{what} {n} times")
            }
        };
        let plural = |n: usize, word: &str| format!("{n} {word}{}", if n == 1 { "" } else { "s" });
        match self.kind.as_str() {
            "read" => format!("Read {}", plural(files, "file")),
            "edit" => format!("Edited {}", plural(files, "file")),
            "search" => times("Searched the code"),
            "command" => format!("Ran {}", plural(n, "command")),
            "test" => times("Ran the tests"),
            "tetrix" => times("Asked Tetrix"),
            "web" => times("Looked on the web"),
            _ => format!("Used {}", plural(n, "tool")),
        }
    }
}

/// The agent's words as a title: their first sentence, without its full stop, at most
/// [`TITLE`] characters.
fn title(words: &str) -> String {
    let first = words
        .split_inclusive(['.', '!', '?', ':'])
        .next()
        .unwrap_or(words)
        .trim()
        .trim_end_matches(['.', ':'])
        .to_owned();
    crate::brain::briefing::line(&first, TITLE)
}

/// When a call ended: its start and how long it ran.
fn ended(tool: &Entry) -> Option<String> {
    let start = obi_protocol::time::parse(&tool.at)?;
    Some(obi_protocol::time::format(
        start + tool.seconds?.round() as i64,
    ))
}

/// Every kind with its count, 0 for those not seen.
fn counts<'a>(seen: impl Iterator<Item = (&'a str, u64)>) -> Value {
    let mut counts: serde_json::Map<String, Value> =
        KINDS.iter().map(|k| ((*k).to_owned(), json!(0))).collect();
    for (kind, n) in seen {
        if let Some(Value::Number(was)) = counts.get(kind) {
            let now = was.as_u64().unwrap_or(0) + n;
            counts.insert(kind.to_owned(), json!(now));
        }
    }
    Value::Object(counts)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(n: u64, tool: &str, activity: &str, file: Option<&str>, state: &str) -> Entry {
        Entry {
            n,
            at: "2026-10-19T08:00:00Z".into(),
            kind: "tool".into(),
            tool: Some(tool.into()),
            summary: format!("Using {tool}"),
            state: Some(state.into()),
            seconds: (state != "running").then_some(2.0),
            activity: Some(activity.into()),
            file: file.map(str::to_owned),
            ..Entry::default()
        }
    }

    fn said(n: u64, words: &str) -> Entry {
        Entry {
            n,
            at: "2026-10-19T08:00:00Z".into(),
            kind: "said".into(),
            summary: words.into(),
            ..Entry::default()
        }
    }

    fn of(entries: &[Entry]) -> Activity {
        let mut activity = Activity::default();
        for entry in entries {
            activity.take(entry);
        }
        activity
    }

    #[test]
    fn kinds_by_tool() {
        let none = Value::Null;
        let bash =
            |command: &str, check: Option<&str>| kind("Bash", &json!({"command": command}), check);
        assert_eq!(kind("Glob", &none, None), "read");
        assert_eq!(kind("Grep", &none, None), "search");
        assert_eq!(kind("MultiEdit", &none, None), "edit");
        assert_eq!(bash("ls", None), "command");
        // Only the job's check is a test run, never a command that looks like one.
        assert_eq!(bash("cargo test", None), "command");
        assert_eq!(bash("cargo test", Some("node --test")), "command");
        assert_eq!(bash("node --test", Some("node --test")), "test");
        assert_eq!(
            bash("export A=1 && node --test", Some("node --test")),
            "test"
        );
        assert_eq!(
            bash("node --test && rm -rf x", Some("node --test")),
            "command"
        );
        assert_eq!(
            kind("mcp__tetrix-baseline__get_entity", &none, None),
            "tetrix"
        );
        assert_eq!(kind("mcp__linear__list", &none, None), "mcp");
        assert_eq!(kind("WebFetch", &none, None), "web");
        assert_eq!(kind("Tool", &none, None), "other");
    }

    #[test]
    fn words_split_the_groups() {
        let mut entries = vec![said(
            1,
            "Looking for where a blocked scan ends the job. Then more.",
        )];
        entries.extend((2..=6).map(|n| tool(n, "Read", "read", Some("src/a.rs"), "done")));
        entries.push(said(7, "Found it: fixing it."));
        entries.push(tool(8, "Edit", "edit", Some("src/a.rs"), "done"));
        let mut edit = tool(9, "Edit", "edit", Some("src/b.rs"), "done");
        (edit.added, edit.removed) = (Some(3), Some(1));
        entries.push(edit);
        entries.push(tool(10, "Bash", "test", None, "running"));
        let activity = of(&entries);
        let json = activity.to_json().unwrap();
        assert_eq!(
            json["counts"],
            json!({"read": 5, "search": 0, "edit": 2, "command": 0, "test": 1, "tetrix": 0, "web": 0, "mcp": 0})
        );
        let groups = json["groups"].as_array().unwrap();
        assert_eq!(groups.len(), 2);
        assert_eq!(
            groups[0]["title"],
            "Looking for where a blocked scan ends the job"
        );
        assert_eq!(groups[0]["by"], "agent");
        assert_eq!(groups[0]["state"], "done");
        assert_eq!(groups[0]["files"], json!(["src/a.rs"]));
        assert_eq!(groups[0]["tools"].as_array().unwrap().len(), 3);
        assert_eq!(groups[0]["finished"], "2026-10-19T08:00:02Z");
        assert_eq!(groups[1]["title"], "Found it");
        assert_eq!(groups[1]["state"], "running");
        assert_eq!(groups[1]["tools"].as_array().unwrap().len(), 3);
        assert!(groups[1].get("finished").is_none());
        assert_eq!(groups[1]["diff"], json!({"added": 3, "removed": 1}));
        assert_eq!(activity.context().as_deref(), Some("Found it: fixing it."));
    }

    #[test]
    fn a_call_that_ends_changes_its_group() {
        let mut activity = of(&[tool(1, "Bash", "test", None, "running")]);
        assert_eq!(activity.to_json().unwrap()["groups"][0]["state"], "running");
        activity.take(&tool(1, "Bash", "test", None, "failed"));
        let json = activity.to_json().unwrap();
        assert_eq!(json["groups"][0]["state"], "failed");
        // An end isn't a second call.
        assert_eq!(json["counts"]["test"], 1);
    }

    #[test]
    fn without_words_runs_of_one_kind_group() {
        let mut entries: Vec<Entry> = (1..=14)
            .map(|n| tool(n, "Read", "read", Some(&format!("f{n}.rs")), "done"))
            .collect();
        entries.push(tool(15, "Grep", "search", None, "done"));
        entries.push(tool(16, "Grep", "search", None, "failed"));
        let activity = of(&entries);
        let json = activity.to_json().unwrap();
        let groups = json["groups"].as_array().unwrap();
        let titles: Vec<&str> = groups
            .iter()
            .map(|g| g["title"].as_str().unwrap())
            .collect();
        assert_eq!(titles, ["Read 14 files", "Searched the code 2 times"]);
        assert_eq!(groups[0]["by"], "obid");
        assert_eq!(groups[1]["state"], "failed");
        assert_eq!(activity.context(), None);
        assert_eq!(Activity::default().to_json(), None);
    }

    #[test]
    fn it_stays_small_however_long_the_job() {
        let mut activity = Activity::default();
        let long = "w".repeat(300);
        let mut n = 0;
        for round in 0..200 {
            n += 1;
            activity.take(&said(n, &format!("Step {round}. {long}")));
            for _ in 0..120 {
                n += 1;
                let mut call = tool(
                    n,
                    "Read",
                    "read",
                    Some(&format!("src/{n}/{long}.rs")),
                    "running",
                );
                call.summary = long.clone();
                activity.take(&call);
            }
        }
        let json = activity.to_json().unwrap();
        assert!(
            json.to_string().len() <= MOST_BYTES + 1024,
            "{}",
            json.to_string().len()
        );
        let groups = json["groups"].as_array().unwrap();
        assert!(groups.len() <= GROUPS);
        for group in groups {
            assert!(group["tools"].as_array().unwrap().len() <= SHOWN_RUNNING);
            assert!(group["files"].as_array().unwrap().len() <= FILES);
            assert!(group["counts"]["read"].as_u64().unwrap() <= CALLS as u64);
        }
        // The counts are the whole job's.
        assert_eq!(json["counts"]["read"], 200 * 120);
        // A long run without words is cut into groups of at most CALLS.
        let mut quiet = Activity::default();
        for n in 1..=120 {
            quiet.take(&tool(n, "Read", "read", None, "done"));
        }
        assert_eq!(
            quiet.to_json().unwrap()["groups"].as_array().unwrap().len(),
            3
        );
    }
}
