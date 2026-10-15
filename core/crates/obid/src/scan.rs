//! The publish gate's secret scan (docs/ARCHITECTURE.md, "The publish gate"): what obid runs on
//! every text before it leaves, ported from Engine/Publish.swift (`Publish.rules`, `matches`,
//! `decoded`, `wrapped`, `gitleaks`). Its built-in rules on each line, in plain text and in the
//! base64, hex and URL-encoded copies a line hides; runs of encoded lines joined; and gitleaks on
//! the same lines when it's installed. If the scan can't run, nothing goes out.
//!
//! obid has no vault yet, so there are no vault secrets to look for: the scan is the built-in rules
//! and gitleaks.

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
            all.extend(matches(line.text).into_iter().map(|rule| Finding {
                name: name.clone(),
                line: Some(line.number),
                rule,
            }));
        }
        all.extend(wrapped(&lines));
    }
    let mut seen = std::collections::HashSet::new();
    all.retain(|f| seen.insert(f.clone()));
    all
}

/// gitleaks on the same lines, when it's installed: `Ok` with what it found (nothing when it isn't
/// installed), `Err` when it is and couldn't run. It runs in a folder of its own under `scratch`,
/// with only `PATH`, `HOME` and `TMPDIR` (that folder), so no configuration of the machine's or
/// the person's changes what it looks for.
pub async fn gitleaks(texts: &[(String, String)], scratch: &Path) -> Result<Vec<Finding>, String> {
    let Some(bin) = crate::process::resolve_bin("gitleaks") else {
        return Ok(Vec::new());
    };
    let folder = scratch.join(format!("scan-{}", hex::encode(random_bytes())));
    crate::store::make_private_dir(&folder)
        .map_err(|e| format!("can't make the scan's folder: {e}"))?;
    let result = run_gitleaks(&bin, texts, &folder).await;
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
    texts: &[(String, String)],
    folder: &Path,
) -> Result<Vec<Finding>, String> {
    // Every line of every text, in order, and where each came from.
    let mut places: Vec<(String, usize)> = Vec::new();
    let mut joined: Vec<&str> = Vec::new();
    for (name, text) in texts {
        for (i, line) in text.split('\n').enumerate() {
            places.push((name.clone(), i + 1));
            joined.push(line);
        }
    }
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
