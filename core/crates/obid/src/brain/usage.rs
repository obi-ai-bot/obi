//! What the brain is told about each account's plan and use (#584): the plan (`Max`, `Team`,
//! `Plus`), how much of the 5-hour and the weekly window is used, and when each resets. It is the
//! brain's judgement what to do with it (a lighter model, another account, waiting for a reset);
//! obid only tells it, and checks that what it picks exists.
//!
//! This is the seam for #450 (usage and plan per account), which obid doesn't have yet: [`of`] is
//! the one place that knows where the numbers come from. Until #450 reports them, it reads
//! `home/usage.json`, an object by account id, so a runner (and the tests) can state them:
//!
//! ```json
//! {"personal": {"plan": "Max", "fiveHour": 0.12, "sevenDay": 0.93,
//!               "fiveHourResets": "2026-10-17T14:00:00Z", "sevenDayResets": "2026-10-20T09:00:00Z"}}
//! ```
//!
//! Shares are 0…1, as `GET /v1/accounts` has them. A missing file, account or key is "unknown",
//! never zero. When #450 lands, only [`of`] changes.

use std::path::Path;

use serde::Deserialize;

/// What obid knows of one account's plan and use; every part may be unknown.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    pub plan: Option<String>,
    pub five_hour: Option<f64>,
    pub seven_day: Option<f64>,
    pub five_hour_resets: Option<String>,
    pub seven_day_resets: Option<String>,
}

/// The use of the account with id `account`: #450's data plugs in here.
pub fn of(home: &Path, account: &str) -> Usage {
    let Ok(text) = std::fs::read_to_string(home.join("usage.json")) else {
        return Usage::default();
    };
    let Ok(mut all) = serde_json::from_str::<std::collections::BTreeMap<String, Usage>>(&text)
    else {
        return Usage::default();
    };
    let mut usage = all.remove(account).unwrap_or_default();
    // It is read into the brain's prompt: a plan is a short name, never a sentence, and a share is
    // a share.
    usage.plan = usage
        .plan
        .filter(|p| (1..=20).contains(&p.chars().count()))
        .filter(|p| {
            p.chars()
                .all(|c| c.is_alphanumeric() || c == ' ' || c == '+')
        });
    usage.five_hour = usage.five_hour.filter(|s| (0.0..=1.0).contains(s));
    usage.seven_day = usage.seven_day.filter(|s| (0.0..=1.0).contains(s));
    usage
}

impl Usage {
    pub fn is_unknown(&self) -> bool {
        self.five_hour.is_none() && self.seven_day.is_none()
    }

    /// "Max plan; 5-hour 12% used, resets in 2h; week 93% used, resets in 3d 4h", as of `now`
    /// (seconds since the epoch), or `None` when nothing is known.
    pub fn line(&self, now: i64) -> Option<String> {
        let mut parts: Vec<String> = vec![];
        if let Some(plan) = &self.plan {
            parts.push(format!("{plan} plan"));
        }
        for (name, share, resets) in [
            ("5-hour", self.five_hour, &self.five_hour_resets),
            ("week", self.seven_day, &self.seven_day_resets),
        ] {
            let Some(share) = share else { continue };
            let mut part = format!("{name} {}% used", (share * 100.0).round());
            if let Some(at) = resets.as_deref().and_then(obi_protocol::time::parse) {
                // A window that has reset counts as empty.
                if at <= now {
                    part = format!("{name} reset");
                } else {
                    part.push_str(&format!(", resets in {}", span(at - now)));
                }
            }
            parts.push(part);
        }
        (!self.is_unknown()).then(|| parts.join("; "))
    }
}

/// "45m", "2h", "3d 4h".
fn span(seconds: i64) -> String {
    let minutes = seconds / 60;
    if minutes < 60 {
        return format!("{}m", minutes.max(1));
    }
    let hours = minutes / 60;
    if hours < 24 {
        return format!("{hours}h");
    }
    match hours % 24 {
        0 => format!("{}d", hours / 24),
        rest => format!("{}d {rest}h", hours / 24),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_says_the_plan_the_use_and_how_near_the_reset_is() {
        let usage = Usage {
            plan: Some("Max".into()),
            five_hour: Some(0.12),
            seven_day: Some(0.93),
            five_hour_resets: Some("2026-10-17T14:00:00Z".into()),
            seven_day_resets: Some("2026-10-20T09:00:00Z".into()),
        };
        let now = obi_protocol::time::parse("2026-10-17T12:00:00Z").unwrap();
        assert_eq!(
            usage.line(now).unwrap(),
            "Max plan; 5-hour 12% used, resets in 2h; week 93% used, resets in 2d 21h"
        );
        assert_eq!(Usage::default().line(now), None);
    }

    #[test]
    fn a_window_that_has_reset_counts_as_empty() {
        let usage = Usage {
            five_hour: Some(0.99),
            five_hour_resets: Some("2026-10-17T11:00:00Z".into()),
            ..Usage::default()
        };
        let now = obi_protocol::time::parse("2026-10-17T12:00:00Z").unwrap();
        assert_eq!(usage.line(now).unwrap(), "5-hour reset");
    }
}
