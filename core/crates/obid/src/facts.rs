//! What the job page shows of a job beyond its pipeline (#739): how big its change is (#736),
//! paths and counts only, never what a file holds; and how its own check ran (#734).

use std::time::Instant;

use serde::{Deserialize, Serialize};

/// The most files a diff lists by name; its totals count them all.
const BY_FILE_MAX: usize = 200;

/// One file's lines added and removed. A binary file counts 0 and 0.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileDiff {
    pub path: String,
    pub added: u64,
    pub removed: u64,
}

/// A change's size: files, lines added and removed, and each file's (the first
/// [`BY_FILE_MAX`], a path that holds a possible secret named as the scan names it). `round` is
/// the round it was read after.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Diff {
    pub files: u64,
    pub added: u64,
    pub removed: u64,
    pub by_file: Vec<FileDiff>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub round: Option<u32>,
}

/// `git diff --numstat -z --no-renames`: `<added>\t<removed>\t<path>\0` per file, `-` for a
/// binary file's counts.
pub fn numstat(text: &str) -> Diff {
    let mut diff = Diff::default();
    for entry in text.split('\0').filter(|e| !e.is_empty()) {
        let mut parts = entry.splitn(3, '\t');
        let (Some(added), Some(removed), Some(path)) = (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        let added = added.trim().parse().unwrap_or(0);
        let removed = removed.parse().unwrap_or(0);
        diff.files += 1;
        diff.added += added;
        diff.removed += removed;
        if diff.by_file.len() < BY_FILE_MAX {
            diff.by_file.push(FileDiff {
                // A path that itself holds a possible secret is never repeated.
                path: crate::scan::shown_name(path),
                added,
                removed,
            });
        }
    }
    diff
}

/// The most failing tests a check run lists.
const FAILING_MAX: usize = 20;
/// What a failing test's line the secret scan flags reads instead.
const HIDDEN_LINE: &str = "[possible secret hidden]";
/// The lines and characters a failing test's message keeps.
const MESSAGE_LINES: usize = 3;
const MESSAGE_MAX: usize = 300;

/// A step's tests as its runner said: counted live where it prints each test, else from its
/// summary. `total` when the runner said how many there are.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tests {
    pub passed: u64,
    pub failed: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total: Option<u64>,
}

/// One step of a check run: a part of its command line between top-level `&&`s. `passed` is
/// none for a step that hasn't ended (`running`) or never ran; `started` (RFC 3339) once it
/// started, and `seconds` once it ended: a running one's would change every second.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckStep {
    pub command: String,
    pub passed: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seconds: Option<u64>,
    pub running: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tests: Option<Tests>,
}

/// A failing test by name, its message cut to its first lines with vault secrets masked.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Failing {
    pub test: String,
    pub message: String,
}

/// One run of the job's own check (#734): the round it ran after, its steps, its failing tests.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckRecord {
    pub round: u32,
    pub steps: Vec<CheckStep>,
    pub failing: Vec<Failing>,
}

/// The parts of a command line between top-level `&&`s, or the whole line as one part when it
/// has any other top-level operator (`;`, `||`, `|`, `&`, a newline), quotes and brackets that
/// don't close, or what this doesn't read: a `[[ … ]]` test (whose `&&` is its own), a comment or
/// a heredoc.
pub fn steps(command: &str) -> Vec<String> {
    let whole = vec![command.trim().to_owned()];
    if ["[[", "#", "<<"].iter().any(|s| command.contains(s)) {
        return whole;
    }
    let mut parts = Vec::new();
    let (mut depth, mut quote, mut start) = (0i32, None::<char>, 0usize);
    let bytes: Vec<(usize, char)> = command.char_indices().collect();
    let mut i = 0;
    while i < bytes.len() {
        let (at, c) = bytes[i];
        let next = bytes.get(i + 1).map(|&(_, c)| c);
        match (quote, c) {
            (Some('\''), '\'') => quote = None,
            (Some('\''), _) => {}
            (_, '\\') => i += 1,
            (Some('"'), '"') | (Some('`'), '`') => quote = None,
            (Some(_), _) => {}
            (None, '\'' | '"' | '`') => quote = Some(c),
            (None, '(' | '{') => depth += 1,
            (None, ')' | '}') => depth -= 1,
            (None, '&') if depth == 0 && next == Some('&') => {
                parts.push(command[start..at].trim().to_owned());
                start = at + 2;
                i += 1;
            }
            (None, ';' | '|' | '&' | '\n') if depth == 0 => return whole,
            _ => {}
        }
        i += 1;
    }
    parts.push(command[start..].trim().to_owned());
    if quote.is_some() || depth != 0 || parts.iter().any(String::is_empty) {
        return whole;
    }
    parts
}

/// One step's test counts as they come: `block_*` is the cargo test binary running now, counted
/// test by test until its `test result:` line says how it ended.
#[derive(Debug, Clone, Copy, Default)]
struct Counter {
    seen: bool,
    passed: u64,
    failed: u64,
    total: Option<u64>,
    block_passed: u64,
    block_failed: u64,
}

impl Counter {
    fn tests(&self) -> Option<Tests> {
        self.seen.then_some(Tests {
            passed: self.passed + self.block_passed,
            failed: self.failed + self.block_failed,
            total: self.total,
        })
    }

    /// A runner's own summary: what it says is the count.
    fn said(&mut self, passed: Option<u64>, failed: Option<u64>, total: Option<u64>) {
        self.seen = true;
        self.block_passed = 0;
        self.block_failed = 0;
        self.passed = passed.unwrap_or(self.passed);
        self.failed = failed.unwrap_or(self.failed);
        self.total = total.or(self.total);
    }
}

/// The number next to `word` in a summary line: before it (`791 passed`) or, with `after`,
/// after it (`# tests 793`). Punctuation around either is ignored.
fn count(line: &str, word: &str, after: bool) -> Option<u64> {
    let words: Vec<&str> = line
        .split_whitespace()
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()))
        .filter(|w| !w.is_empty())
        .collect();
    let at = words.iter().position(|w| *w == word)?;
    let other = if after { at + 1 } else { at.checked_sub(1)? };
    words.get(other)?.parse().ok()
}

/// What a check run prints, read as it prints (#734): where each step starts (the line
/// `<marker> <step>` obid prints before each step after the first), each step's tests, and the
/// failing tests, best-effort, from what `cargo test`, `swift test`/`xcodebuild test`, pytest,
/// jest, vitest and `node --test` print. Another runner's steps get their times only.
pub struct CheckWatch {
    marker: String,
    commands: Vec<String>,
    started: Vec<Instant>,
    /// When each started step started, in seconds since the epoch.
    started_at: Vec<i64>,
    counters: Vec<Counter>,
    failing: Vec<Failing>,
    /// The failing test the next lines are the message of.
    message_of: Option<usize>,
    partial: Vec<u8>,
}

impl CheckWatch {
    /// A run of `commands` (from [`steps`]), its first one starting now.
    pub fn new(marker: String, commands: Vec<String>) -> CheckWatch {
        CheckWatch {
            marker,
            counters: vec![Counter::default(); commands.len()],
            commands,
            started: vec![Instant::now()],
            started_at: vec![obi_protocol::time::now()],
            failing: Vec::new(),
            message_of: None,
            partial: Vec::new(),
        }
    }

    /// The command line that runs the steps as the one line would, printing a marker before each
    /// step after the first: `a && b` runs `a && printf … && b` in the same shell.
    pub fn script(&self) -> String {
        let mut script = String::new();
        for (i, command) in self.commands.iter().enumerate() {
            if i > 0 {
                script.push_str(&format!(" && printf '\\n%s\\n' '{} {i}' && ", self.marker));
            }
            script.push_str(command);
        }
        script
    }

    /// Whether `line` is one of the markers, which the check's output leaves out.
    pub fn is_marker(&self, line: &str) -> bool {
        line.starts_with(&self.marker)
    }

    /// More of what it printed.
    pub fn feed(&mut self, bytes: &[u8]) {
        self.partial.extend_from_slice(bytes);
        while let Some(end) = self.partial.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.partial.drain(..=end).collect();
            let text = String::from_utf8_lossy(&line);
            // A line a progress bar rewrote with `\r`: what it shows last.
            let shown = text.trim_end().rsplit('\r').next().unwrap_or("").to_owned();
            self.line(&shown);
        }
        // ponytail: a line longer than this is no runner's summary.
        if self.partial.len() > 64 * 1024 {
            self.partial.clear();
        }
    }

    fn fail(&mut self, test: &str, message: &str) {
        let index = match self.failing.iter().position(|f| f.test == test) {
            Some(index) => index,
            None if self.failing.len() < FAILING_MAX => {
                self.failing.push(Failing {
                    test: test.to_owned(),
                    message: String::new(),
                });
                self.failing.len() - 1
            }
            None => {
                self.message_of = None;
                return;
            }
        };
        self.message_of = Some(index);
        self.add_message(message);
    }

    fn add_message(&mut self, text: &str) {
        let Some(failing) = self.message_of.and_then(|i| self.failing.get_mut(i)) else {
            return;
        };
        let text = text.trim();
        if text.is_empty() || failing.message.lines().count() >= MESSAGE_LINES {
            return;
        }
        if !failing.message.is_empty() {
            failing.message.push('\n');
        }
        failing.message.push_str(text);
    }

    fn line(&mut self, raw: &str) {
        if let Some(step) = raw.strip_prefix(&self.marker) {
            if step
                .trim()
                .parse::<usize>()
                .is_ok_and(|n| n == self.started.len())
            {
                self.started.push(Instant::now());
                self.started_at.push(obi_protocol::time::now());
            }
            self.message_of = None;
            return;
        }
        let step = self.started.len() - 1;
        let Some(counter) = self.counters.get_mut(step) else {
            return;
        };
        let line = raw.trim();
        let between = |from: &str, to: &str| -> Option<String> {
            let rest = &line[line.find(from)? + from.len()..];
            Some(rest[..rest.find(to)?].to_owned())
        };
        // cargo test: a binary's tests one by one, then its result.
        if let Some(n) = line
            .strip_prefix("running ")
            .and_then(|r| r.strip_suffix(" tests").or(r.strip_suffix(" test")))
            .and_then(|n| n.parse::<u64>().ok())
        {
            counter.seen = true;
            counter.passed += counter.block_passed;
            counter.failed += counter.block_failed;
            counter.block_passed = 0;
            counter.block_failed = 0;
            counter.total = Some(counter.total.unwrap_or(0) + n);
        } else if line.starts_with("test result: ") {
            counter.seen = true;
            counter.passed += count(line, "passed", false).unwrap_or(counter.block_passed);
            counter.failed += count(line, "failed", false).unwrap_or(counter.block_failed);
            counter.block_passed = 0;
            counter.block_failed = 0;
        } else if line.starts_with("test ") && line.ends_with(" ... ok") {
            counter.seen = true;
            counter.block_passed += 1;
        } else if let Some(name) = line
            .strip_prefix("test ")
            .and_then(|r| r.strip_suffix(" ... FAILED"))
        {
            counter.seen = true;
            counter.block_failed += 1;
            let name = name.to_owned();
            self.fail(&name, "");
            self.message_of = None;
        } else if let Some(name) = line
            .strip_prefix("---- ")
            .and_then(|r| r.strip_suffix(" stdout ----"))
        {
            let name = name.to_owned();
            self.fail(&name, "");
        }
        // XCTest (swift test, xcodebuild test): each case, and an assertion's error before it.
        else if between("Test Case '", "' passed (").is_some() {
            counter.seen = true;
            counter.passed += 1;
        } else if let Some(name) = between("Test Case '", "' failed (") {
            counter.seen = true;
            counter.failed += 1;
            self.fail(&name, "");
            self.message_of = None;
        } else if let Some(name) = between(": error: ", " : ") {
            let message = line[line.find(" : ").unwrap_or(0) + 3..].to_owned();
            self.fail(&name, &message);
            self.message_of = None;
        }
        // Swift Testing: the run's size, each test, and an issue a test recorded.
        else if line.contains("Test run with ") {
            let total = count(line, "with", true);
            counter.seen = true;
            counter.total = total.or(counter.total);
        } else if line.contains("Test ") && line.contains(" passed after ") {
            counter.seen = true;
            counter.passed += 1;
        } else if let Some(name) = between("Test ", " recorded an issue") {
            let message = line.split_once(": ").map_or("", |(_, m)| m).to_owned();
            self.fail(&name, &message);
            self.message_of = None;
        } else if let Some(name) = between("Test ", " failed after ") {
            counter.seen = true;
            counter.failed += 1;
            self.fail(&name, "");
            self.message_of = None;
        }
        // pytest: how many it collected, the summary line, and the short summary's failures.
        else if line.starts_with("collected ") {
            counter.seen = true;
            counter.total = count(line, "collected", true).or(counter.total);
        } else if line.starts_with('=')
            && line.contains(" in ")
            && (line.contains(" passed") || line.contains(" failed"))
        {
            counter.said(
                count(line, "passed", false),
                count(line, "failed", false),
                None,
            );
        } else if let Some(rest) = line.strip_prefix("FAILED ").filter(|r| r.contains("::")) {
            let (name, message) = rest.split_once(" - ").unwrap_or((rest, ""));
            let (name, message) = (name.to_owned(), message.to_owned());
            self.fail(&name, &message);
            self.message_of = None;
        }
        // jest and vitest: the summary, and each failing test's header with its message after it.
        else if line.starts_with("Tests:") {
            counter.said(
                count(line, "passed", false),
                count(line, "failed", false),
                count(line, "total", false),
            );
        } else if line.starts_with("Tests ")
            && (line.contains(" passed") || line.contains(" failed"))
        {
            let total = line
                .rsplit('(')
                .next()
                .and_then(|t| t.trim_end_matches(')').parse().ok());
            counter.said(
                count(line, "passed", false),
                count(line, "failed", false),
                total,
            );
        } else if let Some(name) = line.strip_prefix("● ") {
            let name = name.to_owned();
            self.fail(&name, "");
        } else if let Some(name) = line.strip_prefix("FAIL ").filter(|r| r.contains(" > ")) {
            let name = name.trim().to_owned();
            self.fail(&name, "");
        }
        // node --test: TAP's or the spec reporter's summary, and TAP's failing tests.
        else if let Some(rest) = line.strip_prefix("# ").or(line.strip_prefix("ℹ ")) {
            match rest.split_once(' ') {
                Some(("tests", n)) => counter.said(None, None, n.parse().ok()),
                Some(("pass", n)) => counter.said(n.parse().ok(), None, None),
                Some(("fail", n)) => counter.said(None, n.parse().ok(), None),
                _ => self.add_message(line),
            }
        } else if let Some(rest) = line.strip_prefix("not ok ") {
            let name = rest.split_once(" - ").map_or(rest, |(_, n)| n).to_owned();
            self.fail(&name, "");
        } else if line.is_empty() {
            self.message_of = None;
        } else if !line.starts_with("thread '") && !line.starts_with("note: ") {
            self.add_message(line);
        }
    }

    /// The run as the job shows it: `ended` with whether it passed, or none while it runs.
    pub fn record(&self, round: u32, ended: Option<bool>) -> CheckRecord {
        let last = self.started.len() - 1;
        let now = Instant::now();
        let steps = self
            .commands
            .iter()
            .enumerate()
            .map(|(i, command)| {
                let started = self.started.get(i);
                let until = self.started.get(i + 1).copied().unwrap_or(now);
                let running = i == last && ended.is_none();
                CheckStep {
                    command: command.clone(),
                    passed: match i.cmp(&last) {
                        std::cmp::Ordering::Less => Some(true),
                        std::cmp::Ordering::Equal => ended,
                        std::cmp::Ordering::Greater => None,
                    },
                    started: self
                        .started_at
                        .get(i)
                        .map(|&at| obi_protocol::time::format(at)),
                    seconds: started
                        .filter(|_| !running)
                        .map(|s| until.duration_since(*s).as_secs()),
                    running,
                    tests: self.counters[i].tests(),
                }
            })
            .collect();
        let known = crate::secrets::known();
        // A line holding a vault secret or anything the secret scan's rules flag (in any form it
        // reads) taken out whole; vault values masked in the rest.
        let masked = |text: &str| -> String {
            text.split('\n')
                .map(|line| {
                    if crate::scan::risky_name(line) {
                        HIDDEN_LINE.to_owned()
                    } else {
                        known.redact(line)
                    }
                })
                .collect::<Vec<_>>()
                .join("\n")
        };
        let failing = self
            .failing
            .iter()
            .map(|f| Failing {
                test: masked(&f.test),
                message: masked(&f.message).chars().take(MESSAGE_MAX).collect(),
            })
            .collect();
        CheckRecord {
            round,
            steps,
            failing,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numstat_counts_every_file_and_reads_binaries_as_none() {
        let diff = numstat("3\t1\tsrc/a b.rs\0-\t-\tlogo.png\0\n10\t0\tnew.txt\0");
        assert_eq!((diff.files, diff.added, diff.removed), (3, 13, 1));
        assert_eq!(diff.by_file[0].path, "src/a b.rs");
        assert_eq!((diff.by_file[1].added, diff.by_file[1].removed), (0, 0));
        assert_eq!(numstat(""), Diff::default());
    }

    #[test]
    fn a_command_line_splits_at_its_top_level_ands_only() {
        assert_eq!(
            steps("cargo fmt --check && cargo clippy -- -D warnings && cargo test -p obid"),
            [
                "cargo fmt --check",
                "cargo clippy -- -D warnings",
                "cargo test -p obid"
            ]
        );
        assert_eq!(steps("cd core && cargo test"), ["cd core", "cargo test"]);
        for whole in [
            "a && b || c",
            "a; b",
            "cargo test 2>&1 | tail",
            "sh -c 'a && b'",
            "echo \"a && b\"",
            "(a && b)",
            "a &&",
            "[[ -f a && -f b ]] && cargo test",
            "cargo test # && not a step",
            "cat <<EOF && cargo test",
        ] {
            assert_eq!(steps(whole), [whole.trim()], "{whole}");
        }
    }

    fn watch(commands: &[&str], output: &str) -> CheckWatch {
        let mut watch = CheckWatch::new(
            "obid-step-1234".into(),
            commands.iter().map(|c| c.to_string()).collect(),
        );
        watch.feed(output.as_bytes());
        watch
    }

    #[test]
    fn cargo_tests_are_counted_live_and_their_failures_named() {
        let output =
            "obid-step-1234 1\nrunning 3 tests\ntest a::one ... ok\ntest a::two ... FAILED\n";
        let mut w = watch(&["cargo fmt --check", "cargo test"], output);
        let live = w.record(1, None);
        assert_eq!(live.steps[0].passed, Some(true));
        assert!(live.steps[1].running);
        assert_eq!(
            live.steps[1].tests,
            Some(Tests {
                passed: 1,
                failed: 1,
                total: Some(3)
            })
        );
        // A running step has when it started, and no time of its own yet.
        assert!(live.steps[1].started.is_some() && live.steps[1].seconds.is_none());
        assert!(live.steps[0].seconds.is_some());
        w.feed(b"test a::three ... FAILED\n\nfailures:\n\n---- a::two stdout ----\nthread 'a::two' panicked at src/a.rs:9:5:\nassertion `left == right` failed\n  left: 1\n right: 2\nnote: run with `RUST_BACKTRACE=1`\n\n---- a::three stdout ----\nboom\n\ntest result: FAILED. 1 passed; 2 failed; 0 ignored\n");
        let ended = w.record(1, Some(false));
        assert_eq!(ended.steps[1].passed, Some(false));
        assert!(!ended.steps[1].running);
        assert_eq!(
            ended.steps[1].tests,
            Some(Tests {
                passed: 1,
                failed: 2,
                total: Some(3)
            })
        );
        assert_eq!(ended.failing.len(), 2);
        assert_eq!(ended.failing[0].test, "a::two");
        assert_eq!(
            ended.failing[0].message,
            "assertion `left == right` failed\nleft: 1\nright: 2"
        );
        assert_eq!(ended.failing[1].message, "boom");
    }

    #[test]
    fn other_runners_summaries_are_read() {
        let tests = |output: &str| watch(&["x"], output).record(1, Some(true)).steps[0].tests;
        let t = |passed, failed, total| {
            Some(Tests {
                passed,
                failed,
                total,
            })
        };
        assert_eq!(
            tests("collected 793 items\n===== 2 failed, 791 passed in 3.21s =====\n"),
            t(791, 2, Some(793))
        );
        assert_eq!(
            tests("Tests:       2 failed, 791 passed, 793 total\n"),
            t(791, 2, Some(793))
        );
        assert_eq!(
            tests("      Tests  2 failed | 791 passed (793)\n"),
            t(791, 2, Some(793))
        );
        assert_eq!(tests("# tests 3\n# pass 2\n# fail 1\n"), t(2, 1, Some(3)));
        assert_eq!(tests("ℹ tests 3\nℹ pass 3\nℹ fail 0\n"), t(3, 0, Some(3)));
        assert_eq!(
            tests(
                "Test Case '-[M.A testOne]' passed (0.001 seconds).\nT.swift:3: error: -[M.A testTwo] : XCTAssertEqual failed: (\"1\") is not equal to (\"2\")\nTest Case '-[M.A testTwo]' failed (0.002 seconds).\n"
            ),
            t(1, 1, None)
        );
        assert_eq!(
            tests(
                "◇ Test run started.\n✔ Test one() passed after 0.001 seconds.\n✘ Test two() recorded an issue at A.swift:3:5: Expectation failed: 1 == 2\n✘ Test two() failed after 0.002 seconds with 1 issue.\n✘ Test run with 2 tests failed after 0.003 seconds with 1 issue.\n"
            ),
            t(1, 1, Some(2))
        );
        assert_eq!(tests("hello\n"), None);
        let w = watch(
            &["x"],
            "T.swift:3: error: -[M.A testTwo] : XCTAssertEqual failed\nTest Case '-[M.A testTwo]' failed (0.002 seconds).\nFAILED tests/t.py::test_x - AssertionError: no\n",
        );
        let failing = w.record(1, Some(false)).failing;
        assert_eq!(
            failing[0],
            Failing {
                test: "-[M.A testTwo]".into(),
                message: "XCTAssertEqual failed".into()
            }
        );
        assert_eq!(
            failing[1],
            Failing {
                test: "tests/t.py::test_x".into(),
                message: "AssertionError: no".into()
            }
        );
    }

    /// A failing test's line the secret scan's rules flag is taken out whole, even reversed.
    #[test]
    fn a_failing_tests_secret_never_reaches_the_record() {
        let key = ["AK", "IA", "QWERTYUIOPASDFGH"].concat();
        let backwards: String = key.chars().rev().collect();
        let output = format!(
            "running 1 test\ntest a ... FAILED\n---- a stdout ----\nkey was {key}\nand {backwards}\nexpected 2\n"
        );
        let failing = watch(&["cargo test"], &output)
            .record(1, Some(false))
            .failing;
        assert_eq!(
            failing[0].message,
            "[possible secret hidden]\n[possible secret hidden]\nexpected 2"
        );
    }
}
