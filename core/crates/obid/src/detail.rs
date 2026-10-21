//! What a job's transcript shows when an entry is opened (#784; docs/runner-api.md,
//! "GET /v1/jobs/{id}/transcript/{n}"): a call's input as the tool gave it, its output (the last
//! [`OUTPUT_LINES`] lines or [`OUTPUT_BYTES`], whichever is less) and an edit's unified diff. Masked
//! before anything is written: the secrets obid holds, in every form it knows, become
//! `[vault: NAME]` (`[redacted: NAME]` for obid's own); then a line the secret scan flags becomes
//! `[redacted: <rule>]`, and only that line, except where a secret goes on over lines: a private
//! key hides through its END line, and a run of base64 or hex lines that holds one hides whole.
//! Text is masked before it's cut short, never after. It never reaches the brain.

use serde_json::{Value, json};

/// How much of a call's output is kept: its last lines, at most this many bytes.
pub const OUTPUT_LINES: usize = 200;
pub const OUTPUT_BYTES: usize = 64 * 1024;
/// How long one string of a call's input, the agent's words or a diff may be.
pub const TEXT_BYTES: usize = 64 * 1024;
/// How much more than is kept is masked first, so a secret that crosses the cut is found whole.
const MARGIN: usize = 16 * 1024;

/// `text` as it may leave obid: the secrets obid holds out, then each line the secret scan
/// flags replaced by `[redacted: <rule>]`; a private key from its BEGIN line through its END line
/// (or the end), and every line of a base64 or hex run over lines that a rule finds in. Line
/// breaks stay. Bound the text before: the work grows with it.
pub fn mask(text: &str) -> String {
    let text = vault_markers(&crate::secrets::known().redact(text));
    let lines: Vec<&str> = text.split_inclusive('\n').collect();
    let bodies: Vec<String> = lines
        .iter()
        .map(|l| l.trim_end_matches(['\n', '\r']).to_owned())
        .collect();
    let mut hidden: Vec<Option<Vec<String>>> = vec![None; lines.len()];
    let mut i = 0;
    while i < bodies.len() {
        let rules = crate::scan::matches(&bodies[i]);
        if rules.is_empty() {
            i += 1;
            continue;
        }
        let last = if rules.iter().any(|r| r.starts_with("private key")) {
            (i..bodies.len())
                .find(|&j| key_end(&bodies[j]))
                .unwrap_or(bodies.len() - 1)
        } else {
            i
        };
        for line in &mut hidden[i..=last] {
            line.get_or_insert_with(|| rules.clone());
        }
        i = last + 1;
    }
    // A token wrapped over lines is on no line whole. A word on its own line next to the run
    // looks like part of it, so the run is tried with a line off either end too.
    for marked in [false, true] {
        for (first, last, joined) in crate::secrets::encoded_runs(&bodies, marked) {
            let trimmed = |from: usize, to: usize| -> String {
                bodies[from..=to]
                    .iter()
                    .map(|b| {
                        b.trim_matches(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | ','))
                    })
                    .collect()
            };
            // The narrowest that holds a secret is what's hidden.
            let mut tries: Vec<(usize, usize, String)> = Vec::new();
            for (from, to) in [
                (first + 1, last.saturating_sub(1)),
                (first + 1, last),
                (first, last.saturating_sub(1)),
            ] {
                if from < to && to <= last {
                    tries.push((from, to, trimmed(from, to)));
                }
            }
            tries.push((first, last, joined));
            if let Some((from, to, mut rules)) = tries
                .into_iter()
                .map(|(from, to, text)| (from, to, crate::scan::matches(&text)))
                .find(|(_, _, rules)| !rules.is_empty())
            {
                rules.dedup();
                for line in &mut hidden[from..=to] {
                    line.get_or_insert_with(|| rules.clone());
                }
            }
        }
    }
    let mut masked = String::with_capacity(text.len());
    for ((line, body), hidden) in lines.iter().zip(&bodies).zip(hidden) {
        match hidden {
            None => masked.push_str(line),
            Some(rules) => {
                masked.push_str(&format!("[redacted: {}]", rules.join(", ")));
                masked.push_str(&line[body.len()..]);
            }
        }
    }
    masked
}

/// A private key's last line: `-----END … PRIVATE KEY-----`.
fn key_end(line: &str) -> bool {
    line.contains("-----END") && line.contains("PRIVATE KEY")
}

/// A private key's first line.
pub fn key_begins(line: &str) -> bool {
    line.contains("-----BEGIN") && line.contains("PRIVATE KEY")
}

/// `text` masked, at most [`TEXT_BYTES`] (with `…` when it was longer): cut a little past that
/// first, masked, then cut again, so a secret that crosses the cut is found whole.
pub fn masked(text: &str) -> String {
    if text.len() <= TEXT_BYTES {
        return mask(text);
    }
    // Masking can shrink the text enough to bring a piece cut off at the end under the cap, and
    // what's left of a secret there isn't one: back to the last character no token holds, and
    // off a run of base64 or hex lines at the end, which a wrapped secret could go on past.
    let reach = prefix(text, TEXT_BYTES + MARGIN);
    let end = reach
        .char_indices()
        .rev()
        .find(|&(_, c)| !token_char(c))
        .map_or(0, |(at, c)| at + c.len_utf8());
    let mut whole = &reach[..end];
    let lines: Vec<&str> = whole.split_inclusive('\n').collect();
    let run: usize = lines[lines.len() - encoded_tail(&lines)..]
        .iter()
        .map(|l| l.len())
        .sum();
    whole = &whole[..whole.len() - run];
    let kept = capped(&mask(whole));
    if kept.ends_with('…') {
        kept
    } else {
        format!("{kept}…")
    }
}

/// A character a token can hold (base64, hex, URL-encoded, a JWT's dots).
fn token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=' | '_' | '-' | '.' | '~' | '%')
}

/// How many of these lines, at the end, are a run of base64 or hex, with the line before it
/// (which a run can continue): a secret wrapped over them is only whole once the run has ended.
pub fn encoded_tail(lines: &[&str]) -> usize {
    let run = lines
        .iter()
        .rev()
        .take_while(|l| {
            let text = l.trim_matches(|c: char| {
                c.is_whitespace() || matches!(c, '"' | '\'' | ',' | '\\' | '+' | '-' | '>')
            });
            !text.is_empty()
                && text.bytes().all(|b| {
                    b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'=' | b'_' | b'-')
                })
        })
        .count();
    if run > 0 {
        (run + 1).min(lines.len())
    } else {
        0
    }
}

/// The first `bytes` of `text` at most, at a character.
fn prefix(text: &str, bytes: usize) -> &str {
    let mut cut = bytes.min(text.len());
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    &text[..cut]
}

/// The last `bytes` of `text` at most, at a character.
fn suffix(text: &str, bytes: usize) -> &str {
    let mut from = text.len().saturating_sub(bytes);
    while !text.is_char_boundary(from) {
        from += 1;
    }
    &text[from..]
}

/// `[redacted: vault NAME]` as `[vault: NAME]`: a vault secret says it's the vault's.
fn vault_markers(text: &str) -> String {
    static MARKER: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let marker =
        MARKER.get_or_init(|| regex::Regex::new(r"\[redacted: ([^\]]+)\]").expect("a regex"));
    marker
        .replace_all(text, |c: &regex::Captures| {
            let names: Vec<&str> = c[1].split(", ").collect();
            match names
                .iter()
                .map(|n| n.strip_prefix("vault "))
                .collect::<Option<Vec<_>>>()
            {
                Some(vault) => format!("[vault: {}]", vault.join(", ")),
                None => c[0].to_owned(),
            }
        })
        .into_owned()
}

/// Masked `text` cut to [`TEXT_BYTES`] at a character, with `…` when it was longer. Only for
/// text already masked ([`masked`] for any other).
pub fn capped(text: &str) -> String {
    if text.len() <= TEXT_BYTES {
        return text.to_owned();
    }
    format!("{}…", prefix(text, TEXT_BYTES))
}

/// A call's input with every string in it masked and capped.
pub fn input(value: &Value) -> Value {
    match value {
        Value::String(text) => Value::String(masked(text)),
        Value::Array(items) => Value::Array(items.iter().map(input).collect()),
        Value::Object(fields) => {
            Value::Object(fields.iter().map(|(k, v)| (k.clone(), input(v))).collect())
        }
        other => other.clone(),
    }
}

/// A call's output as it's kept: `{text, lines, truncated, exit}`, `text` its last
/// [`OUTPUT_LINES`] lines (at most [`OUTPUT_BYTES`]), masked; `lines` the whole output's count.
pub fn output(raw: &str, exit: Option<i64>) -> Value {
    let count = raw.lines().count();
    // Only the end is read on: a few times what's kept, so a huge output costs no more to mask.
    let tail = suffix(raw, OUTPUT_BYTES + 4 * MARGIN);
    let mut all: Vec<&str> = tail.lines().collect();
    let mut cut = false;
    // A line the window starts inside is left out: what's left of a secret in it isn't one.
    if tail.len() < raw.len() && !raw[..raw.len() - tail.len()].ends_with('\n') && !all.is_empty() {
        all.remove(0);
        cut = true;
    }
    // A few lines more than are kept are masked, so a secret over lines that starts just above
    // the cut is still found whole; and a private key from its BEGIN line, when it's in view.
    let mut from = all.len().saturating_sub(OUTPUT_LINES + 20);
    if let Some(begin) = (0..from)
        .rev()
        .take_while(|&j| !all[j].contains("-----END"))
        .find(|&j| key_begins(all[j]))
    {
        from = begin;
    }
    let masked = mask(&all[from..].join("\n"));
    let kept: Vec<&str> = masked.lines().collect();
    let mut kept = kept[kept.len().saturating_sub(OUTPUT_LINES)..].to_vec();
    let mut text = kept.join("\n");
    while text.len() > OUTPUT_BYTES && kept.len() > 1 {
        kept.remove(0);
        text = kept.join("\n");
        cut = true;
    }
    if text.len() > OUTPUT_BYTES {
        text = suffix(&text, OUTPUT_BYTES).to_owned();
        cut = true;
    }
    json!({
        "text": text,
        "lines": count,
        "truncated": cut || count > kept.len(),
        "exit": exit,
    })
}

/// A file change as `{path, patch}`, its patch masked and capped.
pub fn patch(path: &str, patch: &str) -> Value {
    json!({"path": masked(path), "patch": masked(patch)})
}

/// The unified diff that replaces `old` with `new` in `path`, as one hunk (an edit names no line
/// numbers, so it starts at line 1).
pub fn replaced(path: &str, old: &str, new: &str) -> String {
    let (old, new): (Vec<&str>, Vec<&str>) = (old.lines().collect(), new.lines().collect());
    let start = |lines: &[&str]| if lines.is_empty() { 0 } else { 1 };
    let mut patch = format!(
        "--- a/{path}\n+++ b/{path}\n@@ -{},{} +{},{} @@\n",
        start(&old),
        old.len(),
        start(&new),
        new.len()
    );
    for line in &old {
        patch.push_str(&format!("-{line}\n"));
    }
    for line in &new {
        patch.push_str(&format!("+{line}\n"));
    }
    patch
}

/// Claude Code's `structuredPatch` (its `tool_use_result` for an edit) as a unified diff.
pub fn structured(path: &str, hunks: &[Value]) -> String {
    let mut patch = format!("--- a/{path}\n+++ b/{path}\n");
    for hunk in hunks {
        let n = |k: &str| hunk[k].as_u64().unwrap_or(0);
        patch.push_str(&format!(
            "@@ -{},{} +{},{} @@\n",
            n("oldStart"),
            n("oldLines"),
            n("newStart"),
            n("newLines")
        ));
        for line in hunk["lines"].as_array().into_iter().flatten() {
            patch.push_str(line.as_str().unwrap_or(""));
            patch.push('\n');
        }
    }
    patch
}

/// The diff a Claude Code edit's input describes (Edit, MultiEdit, Write), by file.
pub fn from_input(name: &str, input: &Value, path: &str) -> Option<String> {
    let text = |v: &Value| v.as_str().unwrap_or("").to_owned();
    match name {
        "Edit" if input.get("new_string").is_some() => Some(replaced(
            path,
            &text(&input["old_string"]),
            &text(&input["new_string"]),
        )),
        "MultiEdit" => Some(
            input["edits"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|e| replaced(path, &text(&e["old_string"]), &text(&e["new_string"])))
                .collect::<Vec<_>>()
                .join(""),
        ),
        "Write" if input.get("content").is_some() => {
            Some(replaced(path, "", &text(&input["content"])))
        }
        _ => None,
    }
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

    #[test]
    fn a_vault_secret_says_its_name_and_a_flagged_line_hides_alone() {
        let value = ["detail-", "secret/", "Q7m2+a=b"].concat();
        crate::secrets::known().learn("vault detail-test", &value);
        let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &value);
        let token = ["ghp_", "abcdefghijklmnopqrstuvwxyz0123456789"].concat();
        let masked = mask(&format!(
            "first {value}\nsecond {b64}\nthird {token}\nfourth fine\n"
        ));
        crate::secrets::known().forget("vault detail-test");
        assert!(
            !masked.contains(&value) && !masked.contains(&b64),
            "{masked}"
        );
        let lines: Vec<&str> = masked.lines().collect();
        assert_eq!(lines[0], "first [vault: detail-test]");
        assert_eq!(lines[1], "second [vault: detail-test]");
        assert!(
            lines[2].starts_with("[redacted: ") && !lines[2].contains("ghp_"),
            "{}",
            lines[2]
        );
        assert_eq!(lines[3], "fourth fine");
    }

    #[test]
    fn output_keeps_its_last_lines() {
        let raw: String = (1..=1000).map(|i| format!("line {i}\n")).collect();
        let out = output(&raw, Some(1));
        let text = out["text"].as_str().unwrap();
        assert_eq!(text.lines().count(), OUTPUT_LINES);
        assert!(text.starts_with("line 801\n") && text.ends_with("line 1000"));
        assert_eq!(out["lines"], 1000);
        assert_eq!(out["truncated"], true);
        assert_eq!(out["exit"], 1);
        let short = output("a\nb\n", None);
        assert_eq!(
            (short["text"].as_str(), short["truncated"].as_bool()),
            (Some("a\nb"), Some(false))
        );
        // At most OUTPUT_BYTES, even of a few long lines.
        let wide = output(
            &format!("{}\n{}", "x".repeat(50_000), "y".repeat(50_000)),
            None,
        );
        assert!(wide["text"].as_str().unwrap().len() <= OUTPUT_BYTES);
        assert_eq!(wide["truncated"], true);
    }

    #[test]
    fn edits_are_unified_diffs() {
        assert_eq!(
            replaced("src/a.rs", "a\nb", "c"),
            "--- a/src/a.rs\n+++ b/src/a.rs\n@@ -1,2 +1,1 @@\n-a\n-b\n+c\n"
        );
        let hunks = [
            json!({"oldStart": 3, "oldLines": 1, "newStart": 3, "newLines": 2, "lines": ["-x", "+y", "+z"]}),
        ];
        assert_eq!(
            structured("a.rs", &hunks),
            "--- a/a.rs\n+++ b/a.rs\n@@ -3,1 +3,2 @@\n-x\n+y\n+z\n"
        );
        assert_eq!(
            from_input("Write", &json!({"content": "hi\n"}), "n.txt").unwrap(),
            "--- a/n.txt\n+++ b/n.txt\n@@ -0,0 +1,1 @@\n+hi\n"
        );
    }

    #[test]
    fn a_whole_private_key_hides_through_its_end() {
        let body: Vec<String> = (0..6)
            .map(|i| format!("b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB{i}AAAAMwAAAAtzc2gtZWQyNTUxOQ"))
            .collect();
        let text = format!(
            "cat ~/.ssh/id_ed25519\n{}\n{}\n{}\ndone\n",
            armor("OPENSSH ", false),
            body.join("\n"),
            armor("OPENSSH ", true)
        );
        let masked = mask(&text);
        let lines: Vec<&str> = masked.lines().collect();
        assert_eq!(lines.len(), 10, "{masked}");
        assert_eq!(lines[0], "cat ~/.ssh/id_ed25519");
        for line in &lines[1..9] {
            assert!(line.starts_with("[redacted: private key"), "{masked}");
        }
        assert_eq!(lines[9], "done");
        // With no END in view, to the end.
        let open = mask(&format!("{}\n{}\n", armor("RSA ", false), body[0]));
        assert!(!open.contains(&body[0]), "{open}");
    }

    #[test]
    fn a_token_wrapped_over_lines_hides_whole() {
        let token = ["ghp_", "abcdefghijklmnopqrstuvwxyz0123456789"].concat();
        let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &token);
        let wrapped: Vec<&str> = b64
            .as_bytes()
            .chunks(20)
            .map(|c| std::str::from_utf8(c).unwrap())
            .collect();
        let masked = mask(&format!("before\n{}\nafter\n", wrapped.join("\n")));
        for piece in &wrapped {
            assert!(!masked.contains(piece), "{masked}");
        }
        assert!(
            masked.starts_with("before\n") && masked.ends_with("after\n"),
            "{masked}"
        );
    }

    #[test]
    fn a_secret_across_the_cut_is_found_before_the_cut() {
        let value = ["cut-", "secret/", "Q7m2+a=b"].concat();
        crate::secrets::known().learn("vault cut-test", &value);
        let text = format!("{}{value} and more", "a".repeat(TEXT_BYTES - 6));
        let kept = masked(&text);
        crate::secrets::known().forget("vault cut-test");
        assert!(!kept.contains(&value[..6]), "{}", &kept[kept.len() - 40..]);
        assert!(kept.ends_with('…'));
        // A call's input is masked whole too.
        crate::secrets::known().learn("vault cut-test", &value);
        let input = input(&json!({"content": text}));
        crate::secrets::known().forget("vault cut-test");
        assert!(!input["content"].as_str().unwrap().contains(&value[..6]));
    }

    #[test]
    fn a_huge_output_costs_only_its_end() {
        let token = ["ghp_", "abcdefghijklmnopqrstuvwxyz0123456789"].concat();
        // One 20 MB line, then a few: the long line is cut where the window starts, so it's left
        // out, whatever its end held.
        let raw = format!("{}{token}\nlast one\n", "x".repeat(20 * 1024 * 1024));
        let started = std::time::Instant::now();
        let out = output(&raw, None);
        assert!(started.elapsed() < std::time::Duration::from_secs(5));
        assert_eq!(out["text"], "last one");
        assert_eq!(
            (&out["lines"], &out["truncated"]),
            (&json!(2), &json!(true))
        );
        // A private key whose BEGIN is above the 200 lines kept is still found.
        let key: String = (0..250)
            .map(|i| format!("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo{i:03}\n"))
            .collect();
        let raw = format!("{}\n{key}{}\nok\n", armor("", false), armor("", true));
        let out = output(&raw, None);
        let text = out["text"].as_str().unwrap();
        assert!(
            !text.contains("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo"),
            "{text}"
        );
        assert!(text.ends_with("\nok"));
    }

    /// Text that masking shrinks a lot: lines of a vault value, `sep` after each, to a few bytes
    /// short of where the first cut falls (TEXT_BYTES + MARGIN), padded with `pad` to there.
    fn shrinking(value: &str, sep: char, pad: char, short: usize) -> String {
        let mut text = String::new();
        while text.len() + value.len() + 1 < TEXT_BYTES + MARGIN - short - 40 {
            text.push_str(value);
            text.push(sep);
        }
        while text.len() < TEXT_BYTES + MARGIN - short {
            text.push(pad);
        }
        text
    }

    #[test]
    fn a_piece_cut_off_never_slips_under_the_cap() {
        let value = ["shrink-", "secret/"].concat() + &"Q7m2+a=b".repeat(12);
        let token = ["ghp_", "abcdefghijklmnopqrstuvwxyz0123456789"].concat();
        crate::secrets::known().learn("vault shrink-test", &value);
        // A token the first cut falls inside, 8 bytes in: after a line break, and on one line
        // with no space or line break at all (commas between the values).
        let cases = [
            (shrinking(&value, '\n', ' ', 8), token.clone()),
            (shrinking(&value, ',', ',', 8), token.clone()),
        ];
        let mut kept = Vec::new();
        for (mut text, tail) in cases {
            assert!(text.len() + 8 == TEXT_BYTES + MARGIN);
            text.push_str(&tail);
            text.push_str(" and the rest\n");
            kept.push(masked(&text));
        }
        // A token in base64 wrapped over lines, the cut at a line break inside the run.
        let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &token);
        let wrapped: Vec<&str> = b64
            .as_bytes()
            .chunks(20)
            .map(|c| std::str::from_utf8(c).unwrap())
            .collect();
        let mut text = shrinking(&value, '\n', '\n', 2 * 21);
        text.push_str(&format!("{}\nafter\n", wrapped.join("\n")));
        kept.push(masked(&text));
        crate::secrets::known().forget("vault shrink-test");
        for kept in &kept {
            assert!(kept.len() < TEXT_BYTES, "it shrank: {}", kept.len());
            assert!(!kept.contains("ghp_"), "{}", &kept[kept.len() - 80..]);
            for piece in &wrapped {
                assert!(!kept.contains(piece), "{}", &kept[kept.len() - 80..]);
            }
            assert!(kept.ends_with('…'));
        }
    }
}
