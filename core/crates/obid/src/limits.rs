//! When a tool's usage limit resets (Engine/Jobs.swift, `Limits`): from its own events (Claude
//! Code's `rate_limit_event`, Codex's `account/rateLimits/updated`), or from its words ("…usage
//! limit reached|1760000000", "try again in 2 hours").

use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

static LIMIT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:usage|rate)[ -]?limit|hit your limit|limit (?:reached|exceeded)\b")
        .expect("a regex")
});
/// Claude Code's older line: `Claude AI usage limit reached|1760000000`.
static EPOCH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"limit reached\|(\d{10})\b").expect("a regex"));
static WAIT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\b(?:in|after)\s+\d").expect("a regex"));
static PART: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m)\b").expect("a regex")
});

/// The text says a usage limit stopped it.
pub fn is_limit(text: &str) -> bool {
    LIMIT.is_match(text)
}

/// When the limit `text` names resets, in seconds since the epoch: an epoch after `|`, or a wait
/// ("in 2 hours 15 minutes") from `now`. None when it names neither.
// ponytail: a clock time ("at 10:45 PM") needs the Mac's zone, which obid can't read without
// unsafe code; the tools' own events give the time instead, and Try again is there.
pub fn reset_in(text: &str, now: i64) -> Option<i64> {
    if let Some(at) = EPOCH.captures(text).and_then(|c| c[1].parse().ok()) {
        return Some(at);
    }
    if !WAIT.is_match(text) {
        return None;
    }
    // Saturating: a made-up number of hours never overflows (the caller bounds the wait).
    let seconds = PART
        .captures_iter(text)
        .map(|part| {
            let n: i64 = part[1].parse().unwrap_or(0);
            n.saturating_mul(if part[2].to_lowercase().starts_with('h') {
                3600
            } else {
                60
            })
        })
        .fold(0_i64, i64::saturating_add);
    (seconds > 0).then_some(now.saturating_add(seconds))
}

/// The latest epoch obid takes from a tool: 2100-01-01. Anything past it is a bad value.
const LATEST: f64 = 4_102_444_800.0;

/// An epoch in seconds, from seconds or milliseconds, or none when it isn't a plausible one.
fn epoch(value: &Value) -> Option<i64> {
    let n = value.as_f64()?;
    let seconds = if n > 1e12 { n / 1000.0 } else { n };
    (seconds > 0.0 && seconds <= LATEST).then_some(seconds as i64)
}

/// Claude Code's `rate_limit_event`: when the account resets, if it's full (refused, or a window
/// at 100%): the latest full window's reset (it has room only once every full one resets), else
/// the event's own.
pub fn claude_full_until(message: &Value) -> Option<i64> {
    let info = &message["rate_limit_info"];
    let windows = &info["unifiedWindows"];
    let full: Vec<i64> = ["five_hour", "seven_day"]
        .iter()
        .filter(|w| windows[**w]["utilization"].as_f64().unwrap_or(0.0) >= 1.0)
        .filter_map(|w| epoch(&windows[*w]["resetsAt"]))
        .collect();
    if let Some(at) = full.iter().max() {
        return Some(*at);
    }
    (info["status"] == "rejected")
        .then(|| epoch(&info["resetsAt"]))
        .flatten()
}

/// Codex's `account/rateLimits/updated` (its `rateLimits`): when its own limit resets, if a window
/// is at 100%: the latest full window's reset.
pub fn codex_full_until(limits: &Value) -> Option<i64> {
    // Other limits (a model's reserve) come with their own id and say nothing about Codex's.
    if limits["limitId"].as_str().unwrap_or("codex") != "codex" {
        return None;
    }
    ["primary", "secondary"]
        .iter()
        .filter(|w| limits[**w]["usedPercent"].as_f64().unwrap_or(0.0) >= 100.0)
        .filter_map(|w| epoch(&limits[*w]["resetsAt"]))
        .max()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_limit_says_when_it_resets() {
        let now = 1_760_000_000;
        assert!(is_limit("Codex hit an error: You've hit your usage limit."));
        assert!(is_limit("Claude AI usage limit reached|1760003600"));
        assert!(!is_limit("The check failed."));
        assert_eq!(
            reset_in("Claude AI usage limit reached|1760003600", now),
            Some(1_760_003_600)
        );
        assert_eq!(
            reset_in("Rate limit exceeded: try again in 2 hours 15 minutes.", now),
            Some(now + 2 * 3600 + 15 * 60)
        );
        assert_eq!(reset_in("You've hit your usage limit.", now), None);
        // A made-up wait saturates instead of overflowing.
        assert_eq!(reset_in("in 3000000000000000 hours", now), Some(i64::MAX));
        assert_eq!(reset_in("Try again at 10:45 PM.", now), None);
    }

    #[test]
    fn the_tools_events_say_when_a_full_account_resets() {
        let claude = |info: Value| json!({"type": "rate_limit_event", "rate_limit_info": info});
        let full = claude(json!({"status": "allowed_warning", "unifiedWindows": {
            "five_hour": {"utilization": 1.0, "resetsAt": 1_760_003_600},
            "seven_day": {"utilization": 0.4, "resetsAt": 1_760_500_000}}}));
        assert_eq!(claude_full_until(&full), Some(1_760_003_600));
        // Both windows full: it has room only once the later one resets.
        let both = claude(json!({"status": "rejected", "unifiedWindows": {
            "five_hour": {"utilization": 1.0, "resetsAt": 1_760_003_600},
            "seven_day": {"utilization": 1.0, "resetsAt": 1_760_500_000}}}));
        assert_eq!(claude_full_until(&both), Some(1_760_500_000));
        // A reset past 2100 is a bad value.
        let far = claude(json!({"status": "rejected", "resetsAt": 9e15}));
        assert_eq!(claude_full_until(&far), None);
        let refused = claude(json!({"status": "rejected", "resetsAt": 1_760_007_200_000_i64}));
        assert_eq!(claude_full_until(&refused), Some(1_760_007_200));
        let room = claude(json!({"status": "allowed", "unifiedWindows": {
            "five_hour": {"utilization": 0.5, "resetsAt": 1_760_003_600}}}));
        assert_eq!(claude_full_until(&room), None);

        let codex = json!({"limitId": "codex",
            "primary": {"usedPercent": 100.0, "windowDurationMins": 300, "resetsAt": 1_760_003_600},
            "secondary": {"usedPercent": 30.0, "windowDurationMins": 10080, "resetsAt": 1_760_500_000}});
        assert_eq!(codex_full_until(&codex), Some(1_760_003_600));
        let other =
            json!({"limitId": "gpt-reserve", "primary": {"usedPercent": 100.0, "resetsAt": 1}});
        assert_eq!(codex_full_until(&other), None);
    }
}
