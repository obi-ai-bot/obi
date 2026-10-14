//! The values that cross the boundary: context queries and items, events, and a plug-in's
//! status as `GET /v1/obid/plugins` lists it (docs/ARCHITECTURE.md 5.4, docs/runner-api.md
//! "obid only: plug-ins").

use serde::{Deserialize, Serialize};

use crate::{Kind, PluginError, PluginId};

/// At most this many context items count from one plug-in's answer.
pub const MAX_CONTEXT_ITEMS: usize = 20;
/// The `maxBytes` `obid` asks for: the items' `text`, in all.
pub const DEFAULT_MAX_BYTES: usize = 16_384;

/// `context/query`'s params.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ContextRequest {
    pub request_id: String,
    pub purpose: Purpose,
    pub job: ContextJob,
    pub max_bytes: usize,
}

/// Why `obid` asks: it is dispatching, planning or reviewing the job.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Purpose {
    Dispatch,
    Plan,
    Review,
}

/// The job a context query is about, by typed fields only: no prompt, no summary, no file
/// contents.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContextJob {
    pub id: String,
    pub kind: String,
    pub repo: String,
    pub branch: String,
    pub base: String,
    pub issue: Option<u64>,
    pub pr: Option<u64>,
    /// Paths in the repository, not their contents.
    pub files: Vec<String>,
}

/// One context item: data, written to `.obi/context/<plugin id>.md` in the job's worktree,
/// fenced and labeled as quoted data. Never part of a prompt's instructions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContextItem {
    pub title: String,
    pub source: String,
    pub uri: String,
    pub text: String,
}

/// Holds a plug-in's answer to the limits of `obi-plugin/0.1`: the first
/// [`MAX_CONTEXT_ITEMS`] items, and their `text` cut (at a character boundary) so that in all it
/// is at most `max_bytes`. Items after the one that reached the limit are left out.
pub fn limit_items(items: Vec<ContextItem>, max_bytes: usize) -> Vec<ContextItem> {
    let mut room = max_bytes;
    let mut kept = Vec::new();
    for mut item in items.into_iter().take(MAX_CONTEXT_ITEMS) {
        if item.text.len() > room {
            let mut end = room;
            while !item.text.is_char_boundary(end) {
                end -= 1;
            }
            item.text.truncate(end);
            kept.push(item);
            break;
        }
        room -= item.text.len();
        kept.push(item);
    }
    kept
}

/// The event kinds of `obi-plugin/0.1`. Any other is refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum EventKind {
    #[serde(rename = "pull_request.review_requested")]
    PullRequestReviewRequested,
    #[serde(rename = "pull_request.changes_requested")]
    PullRequestChangesRequested,
    #[serde(rename = "issue.assigned")]
    IssueAssigned,
    #[serde(rename = "check.failed")]
    CheckFailed,
    #[serde(rename = "mention")]
    Mention,
}

impl EventKind {
    pub const ALL: [EventKind; 5] = [
        EventKind::PullRequestReviewRequested,
        EventKind::PullRequestChangesRequested,
        EventKind::IssueAssigned,
        EventKind::CheckFailed,
        EventKind::Mention,
    ];

    /// The name on the wire.
    pub fn as_str(self) -> &'static str {
        match self {
            EventKind::PullRequestReviewRequested => "pull_request.review_requested",
            EventKind::PullRequestChangesRequested => "pull_request.changes_requested",
            EventKind::IssueAssigned => "issue.assigned",
            EventKind::CheckFailed => "check.failed",
            EventKind::Mention => "mention",
        }
    }

    /// The fixed phrase a `pluginEvent` inbox item's title starts with (docs/runner-api.md).
    pub fn phrase(self) -> &'static str {
        match self {
            EventKind::PullRequestReviewRequested => "Review requested",
            EventKind::PullRequestChangesRequested => "Changes requested",
            EventKind::IssueAssigned => "Issue assigned",
            EventKind::CheckFailed => "Check failed",
            EventKind::Mention => "Mentioned",
        }
    }
}

/// `events/emit`'s params: one event, as the plug-in sent it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Event {
    /// The plug-in's own id for it; an id seen before is accepted and ignored.
    pub id: String,
    pub kind: EventKind,
    /// RFC 3339, like `2026-10-14T12:00:09Z`.
    pub occurred_at: String,
    pub subject: EventSubject,
    /// Data: shown to the owner as quoted text.
    pub actor: String,
    /// Data: shown to the owner as quoted text.
    pub data: EventData,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EventSubject {
    pub repo: String,
    pub pr: Option<u64>,
    pub issue: Option<u64>,
    pub head_sha: Option<String>,
}

/// Data, never instructions: quoted unchanged, never a link that opens by itself.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EventData {
    pub title: String,
    pub url: String,
}

impl Event {
    /// The checks the host makes before it accepts an event from a plug-in whose manifest
    /// declares `allowed` (`events.kinds`).
    pub fn check(&self, allowed: &[EventKind]) -> Result<(), PluginError> {
        if self.id.is_empty() {
            return Err(PluginError::Protocol("the event has an empty id".into()));
        }
        if !allowed.contains(&self.kind) {
            return Err(PluginError::Protocol(format!(
                "the event's kind {} is not in the manifest's events.kinds",
                self.kind.as_str()
            )));
        }
        if !is_rfc3339(&self.occurred_at) {
            return Err(PluginError::Protocol(format!(
                "occurredAt {:?} is not an RFC 3339 time",
                self.occurred_at
            )));
        }
        Ok(())
    }
}

/// An event the host accepted, with the plug-in it came from: what `obid` turns into one
/// `pluginEvent` inbox item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginEvent {
    pub plugin: PluginId,
    pub event: Event,
}

/// Where a plug-in is in its lifecycle (docs/ARCHITECTURE.md 5.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PluginState {
    Disabled,
    Starting,
    Ready,
    /// Its manifest is invalid, its sandbox can't be made, or it failed three times in a row.
    Failed,
}

/// One plug-in as `GET /v1/obid/plugins` lists it, and as `PUT /v1/obid/plugins/{id}` answers.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginStatus {
    pub id: PluginId,
    pub name: String,
    pub version: String,
    pub kinds: Vec<Kind>,
    pub enabled: bool,
    pub state: PluginState,
    pub last_error: Option<String>,
}

/// `YYYY-MM-DDTHH:MM:SS`, optional fraction, then `Z` or `±HH:MM` (RFC 3339 section 5.6).
fn is_rfc3339(s: &str) -> bool {
    let b = s.as_bytes();
    let digits = |range: std::ops::Range<usize>| {
        b.get(range.clone())
            .is_some_and(|d| d.iter().all(u8::is_ascii_digit))
    };
    let number = |range: std::ops::Range<usize>| {
        s.get(range)
            .and_then(|d| d.parse::<u32>().ok())
            .unwrap_or(99)
    };
    let shape = b.len() >= 20
        && digits(0..4)
        && b[4] == b'-'
        && digits(5..7)
        && b[7] == b'-'
        && digits(8..10)
        && matches!(b[10], b'T' | b't')
        && digits(11..13)
        && b[13] == b':'
        && digits(14..16)
        && b[16] == b':'
        && digits(17..19);
    if !shape {
        return false;
    }
    let ranges = (1..=12).contains(&number(5..7))
        && (1..=31).contains(&number(8..10))
        && number(11..13) <= 23
        && number(14..16) <= 59
        && number(17..19) <= 60;
    if !ranges {
        return false;
    }
    let mut i = 19;
    if b[i] == b'.' {
        i += 1;
        let start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == start {
            return false;
        }
    }
    match &b[i..] {
        [b'Z' | b'z'] => true,
        [b'+' | b'-', h1, h2, b':', m1, m2] => {
            [h1, h2, m1, m2].iter().all(|d| d.is_ascii_digit())
                && number(i + 1..i + 3) <= 23
                && number(i + 4..i + 6) <= 59
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::is_rfc3339;

    #[test]
    fn rfc3339_times() {
        for good in [
            "2026-10-14T12:00:09Z",
            "2026-10-14T12:00:09.123Z",
            "2026-10-14t12:00:09z",
            "2026-10-14T12:00:09+02:00",
            "2026-10-14T12:00:09.5-07:30",
        ] {
            assert!(is_rfc3339(good), "{good}");
        }
        for bad in [
            "",
            "2026-10-14",
            "2026-10-14 12:00:09Z",
            "2026-13-14T12:00:09Z",
            "2026-10-14T24:00:09Z",
            "2026-10-14T12:00:09",
            "2026-10-14T12:00:09.Z",
            "2026-10-14T12:00:09+0200",
            "2026-10-14T12:00:09Zjunk",
        ] {
            assert!(!is_rfc3339(bad), "{bad}");
        }
    }
}
