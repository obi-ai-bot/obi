//! What a job's transcript shows when an entry is opened (#784; docs/runner-api.md,
//! "GET /v1/jobs/{id}/transcript/{n}"): a call's input as the tool gave it, its output (the last
//! [`OUTPUT_LINES`] lines or [`OUTPUT_BYTES`], whichever is less) and an edit's unified diff. Masked
//! before anything is written: the secrets obid holds, in every form it knows, become
//! `[vault: NAME]` (`[redacted: NAME]` for obid's own); then a line the secret scan flags becomes
//! `[redacted: <rule>]`, and only that line. It never reaches the brain.

use serde_json::{Value, json};

/// How much of a call's output is kept: its last lines, at most this many bytes.
pub const OUTPUT_LINES: usize = 200;
pub const OUTPUT_BYTES: usize = 64 * 1024;
/// How long one string of a call's input, the agent's words or a diff may be.
pub const TEXT_BYTES: usize = 64 * 1024;

/// `text` as it may leave obid: the secrets obid holds out, then each line the secret scan
/// flags replaced by `[redacted: <rule>]`. Line breaks stay.
pub fn mask(text: &str) -> String {
    let text = vault_markers(&crate::secrets::known().redact(text));
    let mut masked = String::with_capacity(text.len());
    for line in text.split_inclusive('\n') {
        let body = line.trim_end_matches(['\n', '\r']);
        let rules = crate::scan::matches(body);
        if rules.is_empty() {
            masked.push_str(line);
        } else {
            masked.push_str(&format!("[redacted: {}]", rules.join(", ")));
            masked.push_str(&line[body.len()..]);
        }
    }
    masked
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

/// `text` cut to [`TEXT_BYTES`] at a character, with `…` when it was longer.
pub fn capped(text: &str) -> String {
    if text.len() <= TEXT_BYTES {
        return text.to_owned();
    }
    let mut cut = TEXT_BYTES;
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    format!("{}…", &text[..cut])
}

/// A call's input with every string in it capped and masked.
pub fn input(value: &Value) -> Value {
    match value {
        Value::String(text) => Value::String(mask(&capped(text))),
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
    let all: Vec<&str> = raw.lines().collect();
    // A few lines more than are kept are masked, so a secret over lines that starts just above
    // the cut is still found whole.
    let from = all.len().saturating_sub(OUTPUT_LINES + 20);
    let masked = mask(&all[from..].join("\n"));
    let kept: Vec<&str> = masked.lines().collect();
    let mut kept = kept[kept.len().saturating_sub(OUTPUT_LINES)..].to_vec();
    let mut text = kept.join("\n");
    let mut cut = false;
    while text.len() > OUTPUT_BYTES && kept.len() > 1 {
        kept.remove(0);
        text = kept.join("\n");
        cut = true;
    }
    if text.len() > OUTPUT_BYTES {
        let mut from = text.len() - OUTPUT_BYTES;
        while !text.is_char_boundary(from) {
            from += 1;
        }
        text = text[from..].to_owned();
        cut = true;
    }
    json!({
        "text": text,
        "lines": all.len(),
        "truncated": cut || all.len() > kept.len(),
        "exit": exit,
    })
}

/// A file change as `{path, patch}`, its patch masked and capped.
pub fn patch(path: &str, patch: &str) -> Value {
    json!({"path": mask(path), "patch": mask(&capped(patch))})
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
}
