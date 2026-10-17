//! Agent-authored questions are data. Only an owner API answer can resume the waiting job.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Question {
    pub text: String,
    pub options: Vec<String>,
    pub details: Option<Vec<String>>,
    pub recommended: Option<usize>,
    pub plan: Option<String>,
}

pub const HOW_TO_ASK: &str = "If you need a decision only the user can make, end your summary with a line `QUESTION: <one question>` and optionally a last line `OPTIONS: <answer> — <what choosing it does> | <answer> — <what choosing it does>`. Give 2 or 3 short labels, the recommended one first with `(Recommended)` after its label. obid puts it in the owner's inbox and your job waits. Their answer comes back as your next message.";
pub const PLAN_FIRST: &str = "Plan first: only read in this turn (no edits, commits or commands that change anything). Present your plan with ExitPlanMode if available, otherwise as your summary, and stop. The owner approves it and chooses how to continue before you change anything.";

fn cap(text: &str, n: usize) -> String {
    text.chars().take(n).collect()
}

impl Question {
    pub fn plan(text: &str) -> Self {
        Self {
            text: "Approve the plan?".into(),
            options: vec![
                "Approve: Accept edits".into(),
                "Approve: Bypass".into(),
                "Change it".into(),
            ],
            details: None,
            recommended: Some(0),
            plan: Some(cap(text, 20_000)),
        }
    }

    /// Swift Inbox.question: only the last nonempty lines count; preserve question Markdown.
    pub fn parse(summary: &str) -> Option<Self> {
        fn value<'a>(line: &'a str, label: &str) -> Option<&'a str> {
            let rest = line.trim_start_matches(['*', '_', '`']);
            let opening = &line[..line.len() - rest.len()];
            if !rest
                .get(..label.len() + 1)?
                .eq_ignore_ascii_case(&format!("{label}:"))
            {
                return None;
            }
            let mut text = rest[label.len() + 1..]
                .trim_start_matches(['*', '_'])
                .trim();
            if !opening.is_empty()
                && let Some(inner) = text.strip_suffix(opening)
            {
                text = inner.trim();
            }
            Some(text)
        }
        let mut lines: Vec<_> = summary
            .split('\n')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .collect();
        let mut options = Vec::new();
        let mut details = Vec::new();
        let mut recommended = None;
        if let Some(list) = lines.last().and_then(|s| value(s, "OPTIONS")) {
            for part in list.split('|') {
                let (label, detail) = part
                    .trim()
                    .split_once(" — ")
                    .map_or((part.trim(), None), |(a, b)| (a.trim(), Some(b.trim())));
                let mark = "(Recommended)";
                let label = if label.to_lowercase().ends_with(&mark.to_lowercase()) {
                    let label = label[..label.len() - mark.len()].trim();
                    if !label.is_empty() && recommended.is_none() {
                        recommended = Some(options.len());
                    }
                    label
                } else {
                    label
                };
                if label.is_empty() {
                    continue;
                }
                options.push(cap(label, 80));
                details.push(detail.filter(|s| !s.is_empty()).map(|s| cap(s, 160)));
            }
            options.truncate(6);
            details.truncate(6);
            lines.pop();
        }
        let text = value(lines.last()?, "QUESTION")?;
        if text.is_empty() {
            return None;
        }
        let recommended = recommended.filter(|i| *i < options.len());
        let details = if !details.is_empty() {
            details.into_iter().collect()
        } else {
            None
        };
        Some(Self {
            text: cap(text, 500),
            options,
            details,
            recommended,
            plan: None,
        })
    }
}

/// These strings are interpreted only at the direct owner API boundary, never by an agent.
pub fn approval(text: &str) -> Option<crate::permissions::Mode> {
    use crate::permissions::Mode;
    match text.trim().to_lowercase().as_str() {
        "approve: accept edits" | "approve" => Some(Mode::AcceptEdits),
        "approve: bypass" => Some(Mode::Bypass),
        "approve: ask" => Some(Mode::Ask),
        s if s.starts_with("approve,") => Some(Mode::AcceptEdits),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_trailing_question_lines_count_and_unicode_stays_data() {
        assert!(Question::parse("QUESTION: quoted\nThe report continues.").is_none());
        let q = Question::parse("`QUESTION: Keep *.swift\u{2028}files?`\nOPTIONS: Keep (Recommended) — Keep files. | Change").unwrap();
        assert_eq!(q.text, "Keep *.swift\u{2028}files?");
        assert_eq!(q.options, ["Keep", "Change"]);
        assert_eq!(q.recommended, Some(0));
        assert!(q.details.is_none()); // A partial description must not appear under the wrong option.
        assert!(Question::parse("QUESTION:   ").is_none());
    }
}
