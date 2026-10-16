//! The publish gate's secret scan (docs/ARCHITECTURE.md, "The publish gate"): what obid runs on
//! every text before it leaves, ported from Engine/Publish.swift (`Publish.rules`, `matches`,
//! `decoded`, `wrapped`, `gitleaks`). Its built-in rules on each line, in plain text and in the
//! base64, hex and URL-encoded copies a line hides; runs of encoded lines joined; and gitleaks on
//! the same lines when it's installed. If the scan can't run, nothing goes out. A diff is read as
//! the lines it adds, at their line in the new file, and the names of the files it touches
//! (`in_diff`, for publishing: crate::publish).
//!
//! A token split with spaces, dashes or zero-width characters, or written backwards, is checked
//! too: the separators come out and the line is read both ways (#476). obid has no vault yet
//! (#457); the secrets it already holds (`crate::secrets`) are looked for in those same forms.

use std::ffi::OsString;
use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

use base64::Engine as _;
use regex::Regex;

/// Where the scan found something: the text's name, the line, the rule. Never the text itself.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Finding {
    pub name: String,
    pub line: Option<usize>,
    pub rule: String,
}

impl std::fmt::Display for Finding {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.line {
            Some(line) => write!(f, "{} line {line} ({})", self.name, self.rule),
            None => write!(f, "{} ({})", self.name, self.rule),
        }
    }
}

/// What the scan said about the texts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Clean,
    Found(Vec<Finding>),
    /// The scanner couldn't run, and why: nothing goes out.
    CouldNotRun(String),
}

struct Rule {
    name: &'static str,
    pattern: Regex,
}

/// The built-in rules (Engine/Publish.swift, `Publish.rules`).
fn rules() -> &'static [Rule] {
    static RULES: OnceLock<Vec<Rule>> = OnceLock::new();
    RULES.get_or_init(|| {
        let rule = |name, pattern: &str| Rule {
            name,
            pattern: Regex::new(pattern).expect("a built-in rule compiles"),
        };
        vec![
            rule("private key", r"-----BEGIN [A-Z ]*PRIVATE KEY"),
            rule("AWS access key", r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
            rule(
                "GitHub token",
                r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}|\bgithub_pat_[A-Za-z0-9_]{60,}",
            ),
            rule("Slack token", r"\bxox[abeoprs]-[A-Za-z0-9-]{10,}"),
            rule(
                "OpenAI key",
                r"\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}|\bsk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}",
            ),
            rule("Anthropic key", r"\bsk-ant-[a-z]+[0-9]{2}-[A-Za-z0-9_-]{20,}"),
            rule("Stripe live key", r"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}"),
            rule(
                "password or secret",
                r#"(?i)(?:password|passwd|secret|api_?key|access_?key|access_?token|auth_?token|private_?key)["']?\s*(?::?=|=>|:)\s*["'][^"'\s]{12,}["']"#,
            ),
        ]
    })
}

fn regex(pattern: &'static str) -> Regex {
    Regex::new(pattern).expect("a scan pattern compiles")
}

macro_rules! cached {
    ($pattern:expr) => {{
        static CELL: OnceLock<Regex> = OnceLock::new();
        CELL.get_or_init(|| regex($pattern))
    }};
}

/// Whether `text` breaks `rule`. A "password or secret" assignment counts unless its value is only
/// a name (see [`only_names`]); every other rule counts on its own.
fn breaks(rule: &Rule, text: &str) -> bool {
    if rule.name != "password or secret" {
        return rule.pattern.is_match(text);
    }
    rule.pattern.find_iter(text).any(|found| {
        // The whole key the value is assigned to: the match starts at its keyword ("Secret" in
        // clientSecret).
        let mut start = found.start();
        while let Some(before) = text[..start].chars().next_back() {
            if before.is_alphanumeric() || before == '_' {
                start -= before.len_utf8();
            } else {
                break;
            }
        }
        let key: String = text[start..found.end()]
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        !only_names(found.as_str(), &key)
    })
}

/// The quoted value of a "password or secret" match, assigned to `key`, is a name for one, not
/// one: the key's own name, or three or more words ending in what it names.
fn only_names(assignment: &str, key: &str) -> bool {
    let Some(value) = assignment.split(['"', '\'']).rfind(|p| !p.is_empty()) else {
        return false;
    };
    if !cached!(r"^[A-Za-z]+(?:[-_.]?[A-Za-z]+)*$").is_match(value) {
        return false;
    }
    let value_words = words(value);
    if value_words.iter().any(|w| w.starts_with("pass")) {
        return false;
    }
    if value_words == words(key) {
        return true;
    }
    value_words.len() >= 3
        && value_words.last().is_some_and(|w| {
            ["id", "name", "entry", "key", "token", "secret"].contains(&w.as_str())
        })
}

/// "watch-access-client-token", "clientSecret" or "CLIENT_SECRET" as lower-case words.
fn words(text: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    for c in text.chars() {
        if matches!(c, '-' | '_' | '.' | ' ') {
            if !current.is_empty() {
                words.push(current.to_lowercase());
                current.clear();
            }
        } else if c.is_uppercase() && current.chars().last().is_some_and(char::is_lowercase) {
            words.push(current.to_lowercase());
            current = c.to_string();
        } else {
            current.push(c);
        }
    }
    if !current.is_empty() {
        words.push(current.to_lowercase());
    }
    words
}

/// Text with 15 printable ASCII characters in a row: the shortest any rule matches.
fn readable(text: &str) -> bool {
    let mut row = 0;
    for byte in text.bytes() {
        row = if (0x20..=0x7E).contains(&byte) {
            row + 1
        } else {
            0
        };
        if row >= 15 {
            return true;
        }
    }
    false
}

fn percent(run: &str) -> String {
    let bytes: Vec<u8> = run
        .split('%')
        .filter(|p| !p.is_empty())
        .filter_map(|p| u8::from_str_radix(p, 16).ok())
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

fn base64_text(run: &str) -> Option<String> {
    let mut text: String = run
        .chars()
        .take_while(|c| *c != '=')
        .map(|c| match c {
            '-' => '+',
            '_' => '/',
            c => c,
        })
        .collect();
    if text.len() % 4 == 1 {
        return None;
    }
    text.push_str(&"=".repeat((4 - text.len() % 4) % 4));
    base64::engine::general_purpose::STANDARD
        .decode(text)
        .ok()
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

fn hex_text(run: &str) -> Option<String> {
    if !run.len().is_multiple_of(2) {
        return None;
    }
    hex::decode(run)
        .ok()
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

/// The text's encoded runs, decoded: URL-encoding, base64 (standard or URL-safe) and hex, and what
/// those hide in turn (`depth` levels), labelled like "base64" or "hex in base64". Only decoded
/// texts a rule could match are kept.
fn decoded(text: &str, depth: u32) -> Vec<(String, String)> {
    if depth == 0 {
        return Vec::new();
    }
    let mut found: Vec<(String, String)> = Vec::new();
    if text.contains('%') {
        let plain = cached!(r"(?:%[0-9A-Fa-f]{2})+")
            .replace_all(text, |c: &regex::Captures<'_>| percent(&c[0]))
            .into_owned();
        if plain != text {
            found.push(("URL-encoded".into(), plain));
        }
    }
    for run in cached!(r"[A-Za-z0-9+/_-]{16,}={0,2}").find_iter(text) {
        if let Some(plain) = base64_text(run.as_str()) {
            found.push(("base64".into(), plain));
        }
    }
    for run in cached!(r"[0-9A-Fa-f]{16,}").find_iter(text) {
        let run = run.as_str();
        // An odd run has a stray digit at one end or the other.
        let tries: Vec<&str> = if run.len() % 2 == 0 {
            vec![run]
        } else {
            vec![&run[1..], &run[..run.len() - 1]]
        };
        for attempt in tries {
            if let Some(plain) = hex_text(attempt) {
                found.push(("hex".into(), plain));
            }
        }
    }
    for run in cached!(r"(?:\\x[0-9A-Fa-f]{2}){8,}|(?:0x[0-9A-Fa-f]{2}[\s,]*){8,}").find_iter(text)
    {
        let digits: String = cached!(r"(?:\\x|0x)([0-9A-Fa-f]{2})")
            .captures_iter(run.as_str())
            .map(|c| c[1].to_owned())
            .collect();
        if let Some(plain) = hex_text(&digits) {
            found.push(("hex".into(), plain));
        }
    }
    found.retain(|(_, plain)| readable(plain));
    let deeper: Vec<(String, String)> = found
        .iter()
        .flat_map(|(how, plain)| {
            decoded(plain, depth - 1)
                .into_iter()
                .map(move |(inner, text)| (format!("{inner} in {how}"), text))
        })
        .collect();
    found.extend(deeper);
    found
}

/// Separators a disguised token hides in: whitespace, the punctuation a token is split with,
/// and the zero-width characters a line can carry without showing them.
fn separator(c: char) -> bool {
    c.is_whitespace()
        || matches!(c, '-' | '_' | '.' | ',')
        || matches!(
            c,
            '\u{200b}' | '\u{200c}' | '\u{200d}' | '\u{feff}' | '\u{2060}'
        )
}

/// `text` with those separators taken out, so `s k - a n t` and `s-k-a-n-t` read as one run.
fn squeeze(text: &str) -> String {
    text.chars().filter(|c| !separator(*c)).collect()
}

/// Runs of single characters split by separators (`s k - a n t`, `A-K-I-A-…`). A whole word is
/// left as a word: squeezing an entire line glues ordinary prose into something a rule matches.
fn split_runs(text: &str) -> Vec<String> {
    let mut runs = Vec::new();
    let mut run = String::new();
    let mut word = String::new();
    let flush_word = |word: &mut String, run: &mut String, runs: &mut Vec<String>| {
        if word.is_empty() {
            return;
        }
        if word.chars().count() == 1 {
            run.push_str(word);
        } else if run.chars().count() >= 20 {
            runs.push(std::mem::take(run));
        } else {
            run.clear();
        }
        word.clear();
    };
    for c in text.chars() {
        if c.is_ascii_alphanumeric() {
            word.push(c);
        } else if separator(c) {
            flush_word(&mut word, &mut run, &mut runs);
        } else {
            flush_word(&mut word, &mut run, &mut runs);
            if run.chars().count() >= 20 {
                runs.push(std::mem::take(&mut run));
            } else {
                run.clear();
            }
        }
    }
    flush_word(&mut word, &mut run, &mut runs);
    if run.chars().count() >= 20 {
        runs.push(run);
    }
    runs
}

/// The same tokens with the separators they are written with taken out. A spaced or dashed
/// Anthropic key no longer matches `sk-ant-`, so these run on [`squeeze`]d text only.
fn compact_rules() -> &'static [Rule] {
    static RULES: OnceLock<Vec<Rule>> = OnceLock::new();
    RULES.get_or_init(|| {
        let rule = |name, pattern: &str| Rule {
            name,
            pattern: Regex::new(pattern).expect("a compact rule compiles"),
        };
        vec![
            rule("AWS access key", r"(?:AKIA|ASIA)[0-9A-Z]{16}"),
            rule(
                "GitHub token",
                r"(?:ghp|gho|ghu|ghs|ghr)[A-Za-z0-9]{36}|githubpat[A-Za-z0-9]{60,}",
            ),
            rule("Slack token", r"xox[abeoprs][A-Za-z0-9]{10,}"),
            rule(
                "OpenAI key",
                r"sk(?:proj|svcacct|admin)[A-Za-z0-9]{20,}|sk[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}",
            ),
            rule("Anthropic key", r"skant[a-z]+[0-9]{2}[A-Za-z0-9]{20,}"),
            rule("Stripe live key", r"(?:sk|rk)live[A-Za-z0-9]{20,}"),
        ]
    })
}

fn compact_hits(text: &str) -> Vec<String> {
    compact_rules()
        .iter()
        .filter(|r| r.pattern.is_match(text))
        .map(|r| r.name.to_owned())
        .collect()
}

/// The rules a line breaks, including a token written backwards or with separators between its
/// characters. The finding stays on the original line.
fn line_rules(text: &str) -> Vec<String> {
    let mut names = matches(text);
    for run in split_runs(text) {
        names.extend(compact_hits(&run));
        let reversed: String = run.chars().rev().collect();
        names.extend(compact_hits(&reversed));
        names.extend(matches(&reversed));
    }
    let reversed_line: String = text.chars().rev().collect();
    if reversed_line != text {
        names.extend(matches(&reversed_line));
    }
    for word in text.split_whitespace() {
        let reversed: String = word.chars().rev().collect();
        if reversed != word {
            names.extend(matches(&reversed));
            names.extend(compact_hits(&squeeze(&reversed)));
        }
    }
    names.sort();
    names.dedup();
    names
}

/// Whether `text`, a split-out token, or the line read backwards holds a secret obid already knows.
fn holds_known_secret(text: &str) -> bool {
    let secrets = crate::secrets::known();
    if secrets.is_empty() {
        return false;
    }
    let hit = |form: &str| !form.is_empty() && secrets.redact(form) != form;
    if hit(text) {
        return true;
    }
    for run in split_runs(text) {
        if hit(&run) {
            return true;
        }
        let reversed: String = run.chars().rev().collect();
        if hit(&reversed) {
            return true;
        }
    }
    if text.split_whitespace().any(|word| {
        let reversed: String = word.chars().rev().collect();
        reversed != word && hit(&reversed)
    }) {
        return true;
    }
    let reversed: String = text.chars().rev().collect();
    reversed != text && hit(&reversed)
}

/// The rules a line breaks, by name: in plain text, else in a base64, hex or URL-encoded copy
/// ("GitHub token, base64").
pub fn matches(text: &str) -> Vec<String> {
    let plain: Vec<String> = rules()
        .iter()
        .filter(|r| breaks(r, text))
        .map(|r| r.name.to_owned())
        .collect();
    if !plain.is_empty() {
        return plain;
    }
    let mut seen = std::collections::HashSet::new();
    decoded(text, 2)
        .into_iter()
        .flat_map(|(how, plain)| {
            rules()
                .iter()
                .filter(|r| breaks(r, &plain))
                .map(|r| format!("{}, {how}", r.name))
                .collect::<Vec<_>>()
        })
        .filter(|name| seen.insert(name.clone()))
        .collect()
}

/// One line of a text, numbered from 1.
#[derive(Debug, Clone)]
struct Line<'a> {
    name: &'a str,
    number: usize,
    text: &'a str,
}

/// Base64 or hex wrapped over several lines: runs of adjacent lines that hold nothing else,
/// joined with the end of the line before, and found at the run's first line.
fn wrapped(lines: &[Line<'_>]) -> Vec<Finding> {
    let trim = |s: &str| -> String {
        s.trim_matches(|c: char| c == ' ' || c == '\t' || matches!(c, '"' | '\'' | ',' | '\\'))
            .to_owned()
    };
    let mut found = Vec::new();
    let mut run: Vec<&Line<'_>> = Vec::new();
    let mut lead = String::new();
    let mut flush = |run: &mut Vec<&Line<'_>>, lead: &mut String| {
        if run.len() + usize::from(!lead.is_empty()) > 1
            && let Some(first) = run.first()
        {
            let joined = format!(
                "{lead}{}",
                run.iter().map(|l| trim(l.text)).collect::<String>()
            );
            found.extend(matches(&joined).into_iter().map(|rule| Finding {
                name: first.name.to_owned(),
                line: Some(first.number),
                rule,
            }));
        }
        run.clear();
        lead.clear();
    };
    let mut previous: Option<&Line<'_>> = None;
    for line in lines {
        let text = trim(line.text);
        let encoded = !text.is_empty() && cached!(r"^[A-Za-z0-9+/=_-]+$").is_match(&text);
        let adjacent = previous.is_some_and(|p| p.name == line.name && p.number + 1 == line.number);
        if encoded && adjacent && !run.is_empty() {
            run.push(line);
        } else {
            flush(&mut run, &mut lead);
            if encoded {
                run.push(line);
                // The first part may end the line before, after `=` or `:`.
                if adjacent
                    && let Some(previous) = previous
                    && let Some(tail) = cached!(r"[A-Za-z0-9+/_-]{8,}$").find(&trim(previous.text))
                {
                    lead = tail.as_str().to_owned();
                }
            }
        }
        previous = Some(line);
    }
    flush(&mut run, &mut lead);
    found
}

/// What the built-in rules find in the texts, each place once.
pub fn built_in(texts: &[(String, String)]) -> Vec<Finding> {
    let mut all = Vec::new();
    for (name, text) in texts {
        let lines: Vec<Line<'_>> = text
            .split('\n')
            .enumerate()
            .map(|(i, line)| Line {
                name,
                number: i + 1,
                text: line,
            })
            .collect();
        for line in &lines {
            all.extend(line_rules(line.text).into_iter().map(|rule| Finding {
                name: name.clone(),
                line: Some(line.number),
                rule,
            }));
            if holds_known_secret(line.text) {
                all.push(Finding {
                    name: name.clone(),
                    line: Some(line.number),
                    rule: "vault secret".into(),
                });
            }
        }
        all.extend(wrapped(&lines));
    }
    let mut seen = std::collections::HashSet::new();
    all.retain(|f| seen.insert(f.clone()));
    all
}

/// A line a diff adds, and where it lands in the new file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Added {
    pub file: String,
    pub number: usize,
    pub text: String,
}

/// The files a `git diff` or `git log -p` touches, and the lines it adds (Engine/Publish.swift,
/// `Publish.parse`).
pub fn parse_diff(diff: &str) -> (Vec<String>, Vec<Added>) {
    let mut files = Vec::new();
    let mut lines = Vec::new();
    let mut file = String::new();
    let mut number = 0usize;
    let mut in_hunk = false;
    for line in diff.split('\n') {
        if line.starts_with("diff --git ") {
            // A name with a tab, newline, quote or backslash in it, git writes quoted, with C
            // escapes.
            file = match (line.ends_with('"'), line.rfind(" \"b/")) {
                (true, Some(at)) => unquoted(&line[at + 1..])
                    .strip_prefix("b/")
                    .unwrap_or_default()
                    .to_owned(),
                _ => {
                    let names = line.replace('"', "");
                    match names.rfind(" b/") {
                        Some(at) => names[at + 3..].to_owned(),
                        None => names,
                    }
                }
            };
            files.push(file.clone());
            in_hunk = false;
        } else if let Some(captures) = cached!(r"^@@ -\d+(?:,\d+)? \+(\d+)").captures(line) {
            number = captures[1].parse().unwrap_or(0);
            in_hunk = true;
        } else if in_hunk && let Some(text) = line.strip_prefix('+') {
            lines.push(Added {
                file: file.clone(),
                number,
                text: text.to_owned(),
            });
            number += 1;
        } else if in_hunk && line.starts_with(' ') {
            number += 1;
        }
    }
    (files, lines)
}

/// A path as git quotes it (`"b/a\tb\303\251"`: C escapes, octal bytes), as it is.
fn unquoted(quoted: &str) -> String {
    let Some(inner) = quoted
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
    else {
        return quoted.to_owned();
    };
    let mut bytes = Vec::new();
    let mut rest = inner.bytes().peekable();
    while let Some(byte) = rest.next() {
        if byte != b'\\' {
            bytes.push(byte);
            continue;
        }
        let Some(next) = rest.next() else {
            bytes.push(byte);
            break;
        };
        if (b'0'..=b'7').contains(&next) {
            let mut value = u32::from(next - b'0');
            for _ in 0..2 {
                match rest.peek() {
                    Some(digit) if (b'0'..=b'7').contains(digit) => {
                        value = value * 8 + u32::from(*digit - b'0');
                        rest.next();
                    }
                    _ => break,
                }
            }
            bytes.push(value as u8);
        } else {
            bytes.push(match next {
                b't' => 9,
                b'n' => 10,
                b'r' => 13,
                b'a' => 7,
                b'b' => 8,
                b'f' => 12,
                b'v' => 11,
                other => other,
            });
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

/// A file that holds secrets by its name alone (Engine/Publish.swift, `Publish.secretFile`).
pub fn secret_file(path: &str) -> Option<&'static str> {
    let name = path.rsplit('/').next().unwrap_or(path);
    if name == ".env"
        || (name.starts_with(".env.")
            && ![".env.example", ".env.sample", ".env.template"].contains(&name))
    {
        return Some(".env file");
    }
    if ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(&name)
        || name.ends_with(".p12")
        || name.ends_with(".pfx")
    {
        return Some("private key file");
    }
    None
}

/// What the built-in rules and the secrets obid holds find in a diff, each place once: in the
/// lines it adds (at their line in the new file, runs of encoded lines joined), and in the names of
/// the files it touches. A file's name with a secret in it is given with the secret taken out.
pub fn in_diff(diff: &str) -> Vec<Finding> {
    let (files, added) = parse_diff(diff);
    let mut all = Vec::new();
    for file in &files {
        if let Some(rule) = secret_file(file) {
            all.push(Finding {
                name: file.clone(),
                line: None,
                rule: rule.into(),
            });
        }
        if holds_known_secret(file) {
            all.push(Finding {
                name: file.clone(),
                line: None,
                rule: "vault secret in the file's name".into(),
            });
        }
        // A name goes out as it is: the rules read it as they read a line.
        all.extend(line_rules(file).into_iter().map(|rule| Finding {
            name: file.clone(),
            line: None,
            rule: format!("{rule} in the file's name"),
        }));
    }
    let lines: Vec<Line<'_>> = added
        .iter()
        .map(|a| Line {
            name: &a.file,
            number: a.number,
            text: &a.text,
        })
        .collect();
    for line in &lines {
        all.extend(line_rules(line.text).into_iter().map(|rule| Finding {
            name: line.name.to_owned(),
            line: Some(line.number),
            rule,
        }));
        if holds_known_secret(line.text) {
            all.push(Finding {
                name: line.name.to_owned(),
                line: Some(line.number),
                rule: "vault secret".into(),
            });
        }
    }
    all.extend(wrapped(&lines));
    let secrets = crate::secrets::known();
    for finding in &mut all {
        finding.name = secrets.redact(&finding.name);
    }
    let mut seen = std::collections::HashSet::new();
    all.retain(|f| seen.insert(f.clone()));
    all
}

/// The secrets obid holds in a whole file (`name`), line by line, in every form [`holds_known_secret`]
/// reads: what a push sends in a file even where no hunk of the diff shows it.
pub fn known_secrets_in_file(text: &str, name: &str) -> Vec<Finding> {
    if crate::secrets::known().is_empty() {
        return Vec::new();
    }
    let name = crate::secrets::known().redact(name);
    text.split('\n')
        .enumerate()
        .filter(|(_, line)| holds_known_secret(line))
        .map(|(i, _)| Finding {
            name: name.clone(),
            line: Some(i + 1),
            rule: "vault secret".into(),
        })
        .collect()
}

/// gitleaks on the same lines, when it's installed: `Ok` with what it found (nothing when it isn't
/// installed), `Err` when it is and couldn't run. It runs in a folder of its own under `scratch`,
/// with only `PATH`, `HOME` and `TMPDIR` (that folder), so no configuration of the machine's or
/// the person's changes what it looks for.
pub async fn gitleaks(texts: &[(String, String)], scratch: &Path) -> Result<Vec<Finding>, String> {
    gitleaks_lines(&lines_of(texts), scratch).await
}

/// [`gitleaks`] on lines that already know where they are: each `(name, line, text)`, like the
/// lines a diff adds, each at its line in the new file.
pub async fn gitleaks_lines(
    lines: &[(String, usize, String)],
    scratch: &Path,
) -> Result<Vec<Finding>, String> {
    match crate::process::resolve_bin("gitleaks") {
        Some(bin) => gitleaks_with(&bin, lines, scratch).await,
        None => Ok(Vec::new()),
    }
}

/// Every line of every text, in order, numbered from 1 within its text.
fn lines_of(texts: &[(String, String)]) -> Vec<(String, usize, String)> {
    texts
        .iter()
        .flat_map(|(name, text)| {
            text.split('\n')
                .enumerate()
                .map(move |(i, line)| (name.clone(), i + 1, line.to_owned()))
        })
        .collect()
}

/// [`gitleaks_lines`] with the binary `bin`.
async fn gitleaks_with(
    bin: &Path,
    lines: &[(String, usize, String)],
    scratch: &Path,
) -> Result<Vec<Finding>, String> {
    let folder = scratch.join(format!("scan-{}", hex::encode(random_bytes())));
    crate::store::make_private_dir(&folder)
        .map_err(|e| format!("can't make the scan's folder: {e}"))?;
    let result = run_gitleaks(bin, lines, &folder).await;
    let _ = std::fs::remove_dir_all(&folder);
    result
}

fn random_bytes() -> [u8; 8] {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).expect("the system's random source works");
    bytes
}

async fn run_gitleaks(
    bin: &Path,
    lines: &[(String, usize, String)],
    folder: &Path,
) -> Result<Vec<Finding>, String> {
    // Every line, in order, and where each came from.
    let places: Vec<(String, usize)> = lines.iter().map(|(n, i, _)| (n.clone(), *i)).collect();
    let joined: Vec<&str> = lines.iter().map(|(_, _, text)| text.as_str()).collect();
    let input = folder.join("texts.txt");
    let report = folder.join("report.json");
    std::fs::write(&input, joined.join("\n")).map_err(|e| format!("can't write the texts: {e}"))?;
    let home = folder.join("home");
    crate::store::make_private_dir(&home).map_err(|e| e.to_string())?;
    let env: Vec<(OsString, OsString)> = vec![
        ("PATH".into(), crate::process::tools_path()),
        ("HOME".into(), home.clone().into_os_string()),
        ("TMPDIR".into(), home.into_os_string()),
    ];
    let mut command = tokio::process::Command::new(bin);
    command
        .arg("dir")
        .arg(&input)
        .args([
            "--no-banner",
            "--redact",
            "--exit-code=99",
            "--report-format=json",
        ])
        .arg(format!("--report-path={}", report.display()))
        .env_clear()
        .envs(env)
        .current_dir(folder)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let child = command.spawn();
    let output = match child {
        Ok(child) => tokio::time::timeout(Duration::from_secs(120), child.wait_with_output())
            .await
            .map_err(|_| "gitleaks took more than 120 seconds".to_owned())?
            .map_err(|e| format!("gitleaks: {e}"))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("gitleaks couldn't start: {e}")),
    };
    match output.status.code() {
        Some(0) => Ok(Vec::new()),
        Some(99) => {
            let leaks: Vec<serde_json::Value> = std::fs::read(&report)
                .ok()
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .unwrap_or_default();
            if leaks.is_empty() {
                return Ok(vec![Finding {
                    name: "?".into(),
                    line: None,
                    rule: "gitleaks".into(),
                }]);
            }
            Ok(leaks
                .iter()
                .map(|leak| {
                    let place = leak["StartLine"]
                        .as_u64()
                        .and_then(|n| places.get((n as usize).checked_sub(1)?));
                    Finding {
                        name: place.map_or("?".into(), |p| p.0.clone()),
                        line: place.map(|p| p.1),
                        rule: format!("gitleaks {}", leak["RuleID"].as_str().unwrap_or("")),
                    }
                })
                .collect())
        }
        _ => {
            let said = String::from_utf8_lossy(&output.stderr);
            let first = said.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
            Err(format!(
                "gitleaks couldn't run ({}{})",
                crate::process::describe(output.status),
                if first.is_empty() {
                    String::new()
                } else {
                    format!(": {}", first.chars().take(200).collect::<String>())
                }
            ))
        }
    }
}

/// The whole scan on the texts (name, text): the built-in rules, then gitleaks.
pub async fn scan(texts: &[(String, String)], scratch: &Path) -> Verdict {
    let mut found = built_in(texts);
    match gitleaks(texts, scratch).await {
        Ok(more) => found.extend(more),
        Err(why) => return Verdict::CouldNotRun(why),
    }
    let mut seen = std::collections::HashSet::new();
    found.retain(|f| seen.insert(f.clone()));
    if found.is_empty() {
        Verdict::Clean
    } else {
        Verdict::Found(found)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(text: &str) -> Vec<(String, String)> {
        vec![("summary".into(), text.into())]
    }

    #[test]
    fn the_scenarios_texts_are_clean() {
        // e2e/fixtures/messages/result.example.json: the findings' titles and details, the summary.
        let clean = [
            "average() divides by zero for an empty list",
            "Unused variable `trimmed`",
            "Two findings, no blocker: an empty list breaks average(), and greet() has an unused variable.",
            "average([]) returns NaN: values.length is 0, so the division has no meaning. Return 0 or throw a clear error for an empty list, and add a test for it.",
            "greet() computes trimmed but still greets with name, so the trim has no effect. Use trimmed in the greeting, or remove the line.",
        ];
        for text in clean {
            assert!(built_in(&texts(text)).is_empty(), "{text}");
        }
    }

    #[test]
    fn keys_and_assignments_are_found() {
        let found = |text: &str| -> Vec<String> {
            built_in(&texts(text)).into_iter().map(|f| f.rule).collect()
        };
        // A made-up key id, put together here so this file holds none a scanner flags.
        let aws = format!("{}{}", "AKIA", "ABCDEFGHIJKLMNOP");
        assert_eq!(found(&format!("key: {aws}")), ["AWS access key"]);
        assert_eq!(
            found(&format!("token ghp_{}", "a".repeat(36))),
            ["GitHub token"]
        );
        assert_eq!(found("-----BEGIN RSA PRIVATE KEY-----"), ["private key"]);
        assert_eq!(
            found(r#"password = "hunter2hunter2hunter2""#),
            ["password or secret"]
        );
        // A name for a secret isn't one.
        assert!(found(r#"clientSecret = "clientSecret""#).is_empty());
        assert!(found(r#"secret: "watch-access-client-token""#).is_empty());
        assert_eq!(
            found(r#"secret: "my-secret-password""#),
            ["password or secret"]
        );
        // Hidden in base64 and hex.
        let b64 = base64::engine::general_purpose::STANDARD.encode(&aws);
        assert_eq!(found(&b64), ["AWS access key, base64"]);
        let hexed = hex::encode(&aws);
        assert_eq!(found(&hexed), ["AWS access key, hex"]);
        assert_eq!(
            found(&format!("u=%41%4B%49%41{}", &aws[4..])),
            ["AWS access key, URL-encoded"]
        );
    }

    #[test]
    fn wrapped_base64_is_joined() {
        let b64 =
            base64::engine::general_purpose::STANDARD.encode(format!("ghp_{}", "b".repeat(36)));
        let (a, b) = b64.split_at(20);
        let found = built_in(&texts(&format!("The key, split:\n{a}\n{b}\n")));
        assert!(
            found
                .iter()
                .any(|f| f.rule == "GitHub token, base64" && f.line == Some(2)),
            "{found:?}"
        );
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("obid-scan-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    /// A stand-in gitleaks: `script` is its shell body.
    fn fake_gitleaks(folder: &Path, script: &str) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let bin = folder.join("gitleaks");
        std::fs::write(&bin, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        bin
    }

    #[tokio::test]
    async fn what_gitleaks_reports_is_placed_by_text_and_line() {
        let folder = scratch("report");
        // Its arguments: dir <file> … --report-path=<report>. It reports line 3 of what it read.
        let bin = fake_gitleaks(
            &folder,
            r#"for a in "$@"; do case "$a" in --report-path=*) report="${a#--report-path=}";; esac; done
echo '[{"StartLine": 3, "RuleID": "generic-api-key"}]' > "$report"
exit 99"#,
        );
        let texts = vec![
            ("summary".to_owned(), "one\ntwo".to_owned()),
            ("finding 1 detail".to_owned(), "three".to_owned()),
        ];
        let found = gitleaks_with(&bin, &lines_of(&texts), &folder)
            .await
            .unwrap();
        assert_eq!(
            found,
            [Finding {
                name: "finding 1 detail".into(),
                line: Some(1),
                rule: "gitleaks generic-api-key".into()
            }]
        );
        // Its folder is gone afterwards.
        let left: Vec<_> = std::fs::read_dir(&folder)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with("scan-"))
            .collect();
        assert!(left.is_empty());
        let _ = std::fs::remove_dir_all(&folder);
    }

    #[tokio::test]
    async fn a_gitleaks_that_fails_is_a_scan_that_couldnt_run() {
        let folder = scratch("broken");
        let bin = fake_gitleaks(&folder, "echo 'config is broken' >&2\nexit 1");
        let why = gitleaks_with(&bin, &lines_of(&texts("clean text")), &folder)
            .await
            .unwrap_err();
        assert!(
            why.contains("couldn't run") && why.contains("config is broken"),
            "{why}"
        );
        let clean = fake_gitleaks(&folder, "exit 0");
        assert_eq!(
            gitleaks_with(&clean, &lines_of(&texts("clean")), &folder).await,
            Ok(Vec::new())
        );
        let _ = std::fs::remove_dir_all(&folder);
    }

    #[tokio::test]
    async fn the_real_gitleaks_when_it_is_installed() {
        let folder = scratch("real");
        // Made up at run time, so this file holds no value a scanner flags: 36 varied letters and
        // digits (gitleaks skips a value with too little entropy).
        const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        let varied: String = obi_protocol::keys::sha256(b"obid scan test")
            .iter()
            .chain(obi_protocol::keys::sha256(b"more").iter())
            .take(36)
            .map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char)
            .collect();
        let token = format!("ghp_{varied}");
        let found = gitleaks(&texts(&format!("token = {token}")), &folder).await;
        match crate::process::resolve_bin("gitleaks") {
            Some(_) => assert!(!found.unwrap().is_empty(), "gitleaks found nothing"),
            None => assert_eq!(
                found,
                Ok(Vec::new()),
                "no gitleaks: the built-in rules alone"
            ),
        }
        let _ = std::fs::remove_dir_all(&folder);
    }

    /// A secret learned for one test, forgotten however the test ends.
    struct Learned;

    impl Learned {
        fn new(value: &str) -> Learned {
            crate::secrets::known().learn("scan-test", value);
            Learned
        }
    }

    impl Drop for Learned {
        fn drop(&mut self) {
            crate::secrets::known().forget("scan-test");
        }
    }

    fn between(token: &str, sep: char) -> String {
        let mut out = String::new();
        for (i, c) in token.chars().enumerate() {
            if i > 0 {
                out.push(sep);
            }
            out.push(c);
        }
        out
    }

    #[tokio::test]
    async fn disguised_tokens_and_vault_secrets_are_found() {
        let folder = scratch("disguise");
        // Made up here, so this file holds no value a scanner would flag on its own.
        let anthropic = format!("sk-ant-api03-{}", "a".repeat(24));
        let github = format!("ghp_{}", "b".repeat(36));
        let vault = format!("vaultcanary{}", "c".repeat(16));
        let _learned = Learned::new(&vault);
        let cases = [
            ("Anthropic key", anthropic),
            ("GitHub token", github),
            ("vault secret", vault),
        ];
        for (rule, token) in cases {
            let forms = [
                ("spaced", between(&token, ' ')),
                ("reversed", token.chars().rev().collect::<String>()),
                ("dashed", between(&token, '-')),
                ("zero-width", between(&token, '\u{200b}')),
            ];
            for (how, disguised) in forms {
                let text = format!("a note\n{disguised}\n");
                let verdict = scan(&texts(&text), &folder).await;
                let Verdict::Found(found) = verdict else {
                    panic!("{rule} {how}: {verdict:?}");
                };
                assert!(
                    found.iter().any(|f| f.rule == rule && f.line == Some(2)),
                    "{rule} {how}: {found:?}"
                );
            }
        }
        let _ = std::fs::remove_dir_all(&folder);
    }

    #[tokio::test]
    async fn clean_docs_and_the_fixture_result_stay_clean() {
        let folder = scratch("clean-docs");
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        for rel in [
            "README.md",
            "docs/ARCHITECTURE.md",
            "e2e/fixtures/messages/result.example.json",
        ] {
            let text = std::fs::read_to_string(root.join(rel)).unwrap();
            let verdict = scan(&texts(&text), &folder).await;
            assert!(
                matches!(verdict, Verdict::Clean),
                "{rel} is not clean: {verdict:?}"
            );
        }
        let _ = std::fs::remove_dir_all(&folder);
    }

    /// Engine/Publish.swift's `parse`: the lines a diff adds, at their line in the new file, and
    /// the names it touches, quoted ones too.
    #[test]
    fn a_diff_is_read_as_its_added_lines_and_names() {
        let aws = format!("{}{}", "AKIA", "ABCDEFGHIJKLMNOP");
        let diff = format!(
            "diff --git a/src/a.rs b/src/a.rs\n--- a/src/a.rs\n+++ b/src/a.rs\n@@ -1,3 +10,4 @@ fn x\n context\n-gone\n+let key = \"{aws}\";\n context\n+added\ndiff --git \"a/t\\tb\\303\\251\" \"b/t\\tb\\303\\251\"\n@@ -0,0 +1 @@\n+hello\ndiff --git a/config/.env b/config/.env\n"
        );
        let (files, added) = parse_diff(&diff);
        assert_eq!(files, ["src/a.rs", "t\tbé", "config/.env"]);
        assert_eq!(
            added
                .iter()
                .map(|a| (a.file.as_str(), a.number))
                .collect::<Vec<_>>(),
            [("src/a.rs", 11), ("src/a.rs", 13), ("t\tbé", 1)]
        );
        let found = in_diff(&diff);
        assert!(
            found.contains(&Finding {
                name: "src/a.rs".into(),
                line: Some(11),
                rule: "AWS access key".into()
            }),
            "{found:?}"
        );
        assert!(
            found.contains(&Finding {
                name: "config/.env".into(),
                line: None,
                rule: ".env file".into()
            }),
            "{found:?}"
        );
        assert_eq!(found.len(), 2, "{found:?}");
        assert_eq!(secret_file("keys/id_ed25519"), Some("private key file"));
        assert_eq!(secret_file(".env.example"), None);
    }

    /// A key split over added lines in base64 is found at the run's first line, and a secret obid
    /// holds is found in a file's name, which is given with it taken out.
    #[test]
    fn a_diff_hides_nothing_in_wrapped_lines_or_names() {
        let b64 =
            base64::engine::general_purpose::STANDARD.encode(format!("ghp_{}", "b".repeat(36)));
        let (a, b) = b64.split_at(20);
        let diff = format!("diff --git a/k b/k\n@@ -0,0 +4,2 @@\n+{a}\n+{b}\n");
        assert!(
            in_diff(&diff)
                .iter()
                .any(|f| f.rule == "GitHub token, base64" && f.line == Some(4)),
            "{:?}",
            in_diff(&diff)
        );
        // Learned under a name of this test's own: tests run side by side.
        struct Forget;
        impl Drop for Forget {
            fn drop(&mut self) {
                crate::secrets::known().forget("scan-diff-test");
            }
        }
        let vault = format!("vaultname{}", "d".repeat(16));
        crate::secrets::known().learn("scan-diff-test", &vault);
        let _forget = Forget;
        let named = in_diff(&format!("diff --git a/{vault}.txt b/{vault}.txt\n"));
        assert_eq!(named.len(), 1, "{named:?}");
        assert_eq!(named[0].rule, "vault secret in the file's name");
        assert!(!named[0].name.contains(&vault), "{named:?}");
        let whole = known_secrets_in_file(&format!("one\nx = {vault}\n"), "f.txt");
        assert_eq!(whole.len(), 1);
        assert_eq!(whole[0].line, Some(2));
    }

    /// A file's name goes out as it is: the rules read it like a line. And the names of this
    /// repository's own files are clean.
    #[test]
    fn a_token_in_a_files_name_is_found() {
        let token = format!("ghp_{}", "e".repeat(36));
        let found = in_diff(&format!("diff --git a/x/{token}.txt b/x/{token}.txt\n"));
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].rule, "GitHub token in the file's name");
        assert_eq!(found[0].line, None);
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let files = std::process::Command::new("git")
            .args(["ls-files"])
            .current_dir(&root)
            .output()
            .unwrap();
        let diff: String = String::from_utf8_lossy(&files.stdout)
            .lines()
            .map(|f| format!("diff --git a/{f} b/{f}\n"))
            .collect();
        let found = in_diff(&diff);
        assert!(found.is_empty(), "{found:?}");
    }

    #[test]
    fn words_split_as_engine_does() {
        assert_eq!(words("clientSecret"), ["client", "secret"]);
        assert_eq!(words("CLIENT_SECRET"), ["client", "secret"]);
        assert_eq!(
            words("watch-access-client-token"),
            ["watch", "access", "client", "token"]
        );
    }
}
