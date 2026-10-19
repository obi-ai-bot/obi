//! A job's activity at a glance (#730; docs/runner-api.md, "activity"): its transcript (#381)
//! summed up as counts of what the agent did by kind, and its session cut into a few groups with
//! plain titles. A group starts at each of the agent's own words between tool calls and is titled
//! by them; tool calls with no words before them group by kind ("Read 14 files"). No model writes
//! a title. Also the job's `context`: the agent's latest words, shortened.

use serde_json::{Value, json};

use crate::transcript::Entry;

/// The kinds counted, in the order the apps show them.
pub const KINDS: [&str; 8] = [
    "read", "search", "edit", "command", "test", "tetrix", "web", "mcp",
];

/// How many of a finished group's calls it lists, its last ones; a running group lists them all.
const LAST: usize = 3;
/// How many files a group lists.
const FILES: usize = 50;
/// How long a title or the context may be.
const TITLE: usize = 80;
const CONTEXT: usize = 200;

/// What a tool call does, by its tool's name and input: `test` when a command runs the job's
/// `check` or a known test runner. `other` is counted nowhere.
pub fn kind(tool: &str, input: &Value, check: Option<&str>) -> &'static str {
    match tool {
        "Read" | "NotebookRead" | "Glob" | "LS" => "read",
        "Grep" => "search",
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => "edit",
        "WebSearch" | "WebFetch" => "web",
        "Bash" => {
            let command = input["command"].as_str().unwrap_or("");
            if is_test(command, check) {
                "test"
            } else {
                "command"
            }
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

/// Whether `command` runs the job's check or a known test runner.
fn is_test(command: &str, check: Option<&str>) -> bool {
    // ponytail: a fixed list of runners; a repository's own test script that isn't its `check`
    // counts as a command.
    const RUNNERS: [&str; 22] = [
        "cargo test",
        "cargo nextest",
        "swift test",
        "xcodebuild test",
        "go test",
        "pytest",
        "npm test",
        "npm run test",
        "pnpm test",
        "pnpm run test",
        "yarn test",
        "bun test",
        "node --test",
        "vitest",
        "jest",
        "rspec",
        "mix test",
        "gradle test",
        "gradlew test",
        "make test",
        "dotnet test",
        "oby-check",
    ];
    let check = check.map(str::trim).filter(|c| !c.is_empty());
    check.is_some_and(|c| command.contains(c)) || RUNNERS.iter().any(|r| command.contains(r))
}

/// The job's `activity`, from its transcript as it is now.
pub fn of(entries: &[Entry]) -> Value {
    let mut groups: Vec<Group> = Vec::new();
    // The words that open the next group, and whether the group now open takes more calls.
    let mut words: Option<&Entry> = None;
    let mut open = false;
    for entry in entries {
        match entry.kind.as_str() {
            "said" => {
                words = Some(entry);
                open = false;
            }
            // A round's start or the owner's words close the group: what follows is new work.
            "start" | "you" => {
                words = None;
                open = false;
            }
            "tool" => {
                let kind = entry.activity.as_deref().unwrap_or("other");
                let joins = open && groups.last().is_some_and(|g| g.titled || g.kind == kind);
                if !joins {
                    groups.push(Group {
                        first: words.unwrap_or(entry).clone(),
                        titled: words.is_some(),
                        kind: kind.to_owned(),
                        tools: vec![],
                    });
                    words = None;
                    open = true;
                }
                groups
                    .last_mut()
                    .expect("a group")
                    .tools
                    .push(entry.clone());
            }
            _ => {}
        }
    }
    let counts = count(entries.iter());
    json!({
        "counts": counts,
        "groups": groups.iter().map(Group::to_json).collect::<Vec<_>>(),
    })
}

/// The job's `context`: the agent's latest words, shortened to their first sentences.
pub fn context(entries: &[Entry]) -> Option<String> {
    let said = entries.iter().rev().find(|e| e.kind == "said")?;
    Some(crate::brain::briefing::line(&said.summary, CONTEXT))
}

struct Group {
    /// The words that opened it, or its first call.
    first: Entry,
    titled: bool,
    kind: String,
    tools: Vec<Entry>,
}

impl Group {
    fn to_json(&self) -> Value {
        let running = self
            .tools
            .iter()
            .any(|t| t.state.as_deref() == Some("running"));
        let failed = self
            .tools
            .last()
            .is_some_and(|t| matches!(t.state.as_deref(), Some("failed")));
        let state = if running {
            "running"
        } else if failed {
            "failed"
        } else {
            "done"
        };
        let mut files: Vec<&str> = Vec::new();
        for file in self.tools.iter().filter_map(|t| t.file.as_deref()) {
            if !files.contains(&file) && files.len() < FILES {
                files.push(file);
            }
        }
        let edits: Vec<&Entry> = self.tools.iter().filter(|t| t.added.is_some()).collect();
        let shown = if running {
            &self.tools[..]
        } else {
            &self.tools[self.tools.len().saturating_sub(LAST)..]
        };
        let mut group = json!({
            "id": format!("g{}", self.first.n),
            "title": self.title(),
            "state": state,
            "started": self.first.at,
            "counts": count(self.tools.iter()),
            "files": files,
            "tools": shown.iter().map(|t| json!({
                "tool": t.tool, "kind": t.activity, "summary": t.summary, "state": t.state,
                "started": t.at, "seconds": t.seconds,
            })).collect::<Vec<_>>(),
        });
        if !running {
            group["finished"] = json!(self.tools.iter().filter_map(ended).max());
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
        let n = self.tools.len();
        let files = {
            let mut seen: Vec<&str> = self
                .tools
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

fn count<'a>(entries: impl Iterator<Item = &'a Entry>) -> Value {
    let mut counts: serde_json::Map<String, Value> =
        KINDS.iter().map(|k| ((*k).to_owned(), json!(0))).collect();
    for kind in entries.filter_map(|e| e.activity.as_deref()) {
        if let Some(Value::Number(n)) = counts.get(kind) {
            let n = n.as_u64().unwrap_or(0) + 1;
            counts.insert(kind.to_owned(), json!(n));
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

    #[test]
    fn kinds_by_tool() {
        let none = Value::Null;
        assert_eq!(kind("Glob", &none, None), "read");
        assert_eq!(kind("Grep", &none, None), "search");
        assert_eq!(kind("MultiEdit", &none, None), "edit");
        assert_eq!(kind("Bash", &json!({"command": "ls"}), None), "command");
        assert_eq!(
            kind("Bash", &json!({"command": "cd x && cargo test -q"}), None),
            "test"
        );
        assert_eq!(
            kind(
                "Bash",
                &json!({"command": "./check.sh"}),
                Some("./check.sh")
            ),
            "test"
        );
        assert_eq!(
            kind("mcp__tetrix-baseline__get_entity", &none, None),
            "tetrix"
        );
        assert_eq!(kind("mcp__linear__list", &none, None), "mcp");
        assert_eq!(kind("WebFetch", &none, None), "web");
        assert_eq!(kind("Agent", &none, None), "other");
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
        assert_eq!(
            activity["counts"],
            json!({"read": 5, "search": 0, "edit": 2, "command": 0, "test": 1, "tetrix": 0, "web": 0, "mcp": 0})
        );
        let groups = activity["groups"].as_array().unwrap();
        assert_eq!(groups.len(), 2);
        assert_eq!(
            groups[0]["title"],
            "Looking for where a blocked scan ends the job"
        );
        assert_eq!(groups[0]["state"], "done");
        assert_eq!(groups[0]["files"], json!(["src/a.rs"]));
        assert_eq!(groups[0]["tools"].as_array().unwrap().len(), 3);
        assert_eq!(groups[0]["finished"], "2026-10-19T08:00:02Z");
        assert_eq!(groups[1]["title"], "Found it");
        assert_eq!(groups[1]["state"], "running");
        assert_eq!(groups[1]["tools"].as_array().unwrap().len(), 3);
        assert!(groups[1].get("finished").is_none());
        assert_eq!(groups[1]["diff"], json!({"added": 3, "removed": 1}));
        assert_eq!(context(&entries).as_deref(), Some("Found it: fixing it."));
    }

    #[test]
    fn without_words_runs_of_one_kind_group() {
        let mut entries: Vec<Entry> = (1..=14)
            .map(|n| tool(n, "Read", "read", Some(&format!("f{n}.rs")), "done"))
            .collect();
        entries.push(tool(15, "Grep", "search", None, "done"));
        entries.push(tool(16, "Grep", "search", None, "failed"));
        let groups = of(&entries)["groups"].as_array().unwrap().clone();
        let titles: Vec<&str> = groups
            .iter()
            .map(|g| g["title"].as_str().unwrap())
            .collect();
        assert_eq!(titles, ["Read 14 files", "Searched the code 2 times"]);
        assert_eq!(groups[1]["state"], "failed");
        assert_eq!(context(&entries), None);
    }
}
