//! What the brain is told before the user's words (Engine/Conversation.swift, `Briefing`).

use std::sync::OnceLock;

use regex::Regex;

use crate::job::{Job, Status};

/// One line, capped: line breaks are spaces, and a longer one ends in `…`.
pub fn line(text: &str, cap: usize) -> String {
    let joined: String = text
        .split(['\r', '\n'])
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let trimmed = joined.trim_matches([' ', '\t']);
    if trimmed.chars().count() > cap {
        let mut short: String = trimmed.chars().take(cap.saturating_sub(1)).collect();
        short.push('…');
        short
    } else {
        trimmed.to_owned()
    }
}

/// Queued behind something (`Job.isWaiting`).
pub fn is_waiting(job: &Job) -> bool {
    job.status == Status::Queued && job.waiting.is_some()
}

/// Running, or getting ready to: what every app counts as an agent working (#238).
pub fn is_working(job: &Job) -> bool {
    job.status.is_active() && !is_waiting(job)
}

/// The agents working now: the count the apps' header shows.
pub fn working(jobs: &[Job]) -> usize {
    jobs.iter().filter(|j| is_working(j)).count()
}

/// "2 agents are working: Vault secrets on tetrix-lab, Watch home on tetrix-lab.", or "No agent
/// is working right now.", and how many jobs wait: the facts a reply must agree with.
pub fn working_line(jobs: &[Job], place: &str) -> String {
    let mut active: Vec<&Job> = jobs.iter().filter(|j| is_working(j)).collect();
    active.sort_by_key(|j| std::cmp::Reverse(j.created));
    let waiting = jobs.iter().filter(|j| is_waiting(j)).count();
    let wait = match waiting {
        0 => String::new(),
        1 => " 1 job is waiting.".into(),
        n => format!(" {n} jobs are waiting."),
    };
    if active.is_empty() {
        return format!("No agent is working right now.{wait}");
    }
    let named: Vec<String> = active
        .iter()
        .take(5)
        .map(|j| format!("{} on {place}", line(&j.short_title(), 60)))
        .collect();
    let more = if active.len() > named.len() {
        format!(", and {} more", active.len() - named.len())
    } else {
        String::new()
    };
    format!(
        "{} working: {}{more}.{wait}",
        if active.len() == 1 {
            "1 agent is".to_owned()
        } else {
            format!("{} agents are", active.len())
        },
        named.join(", ")
    )
}

/// Whether a reply says no job is running ("No jobs are running right now", "nothing is
/// running", "there are no agents working"). Only that: a reply about something else ("no jobs
/// failed") is Oby's own to give (#11).
pub fn contradicts(reply: &str) -> bool {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    let patterns = PATTERNS.get_or_init(|| {
        [
            // "no jobs are running", "no agents working", "no job is currently active".
            r"\bno (?:jobs?|agents?|work|tasks?)(?: (?:is|are))?(?: currently)? (?:running|working|active|in progress|under way|underway)\b",
            // "nothing is running", "nothing's in progress", "nothing running".
            r"\bnothing(?:'s| is)?(?: currently)? (?:running|working|in progress|under way|underway)\b",
            // "isn't running anything", "is not running any jobs".
            r"\b(?:not|aren't|isn't|are not|is not)(?: currently)? (?:running|working on) (?:any|anything)\b",
            // "no running jobs", "zero active agents".
            r"\b(?:no|zero) (?:running|active|working) (?:jobs?|agents?|tasks?)\b",
        ]
        .iter()
        .map(|p| Regex::new(p).expect("a valid pattern"))
        .collect()
    });
    let text = reply.to_lowercase().replace('’', "'");
    patterns.iter().any(|p| p.is_match(&text))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ConversationTests.theReplyNeverContradictsTheHeaderAboutRunningJobs, its words.
    #[test]
    fn only_saying_nothing_runs_contradicts_the_header() {
        for said in [
            "No jobs are running right now.",
            "Nothing is running.",
            "There are no agents working.",
            "Oby isn't running anything at the moment.",
            "No running jobs.",
            "There's nothing in progress.",
            "Oby is not running any jobs.",
        ] {
            assert!(contradicts(said), "{said}");
        }
        for said in [
            "Vault secrets is running its tests.",
            "2 agents are working.",
            "No jobs failed this week.",
            "Nothing needs you.",
            "There are no jobs that failed today.",
            "There are no jobs waiting for review.",
            "No jobs failed; Vault secrets is still running.",
            "There isn't any work that needs you.",
            "No jobs are waiting for your review, and nothing failed.",
            "There are no jobs in review.",
        ] {
            assert!(!contradicts(said), "{said}");
        }
    }

    #[test]
    fn lines_are_one_line_and_capped() {
        assert_eq!(line("a\nb\r\nc ", 10), "a b c");
        assert_eq!(line("abcdef", 4), "abc…");
    }
}
