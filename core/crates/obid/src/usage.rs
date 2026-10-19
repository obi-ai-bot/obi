//! Each account's subscription usage and the owner's weekly reserve, kept privately across
//! restarts in `home/usage.json` (0600) (Engine/Accounts.swift is the behaviour it follows).
//!
//! All of it comes from the tools' own reports: Claude Code's `rate_limit_event` during a job, and
//! Codex's `account/rateLimits/read` and `account/rateLimits/updated`. obid never reads a login to
//! find any of it out.
use obi_protocol::time;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Mutex,
};

/// From this share of its week an account is in its weekly reserve: automatic work leaves it
/// alone until the week resets or the owner lifts the reserve (#278).
pub const RESERVE: f64 = 0.8;
/// From this share of either window an account takes no automatic work, its reserve lifted or not.
pub const NEARLY_FULL: f64 = 0.95;
const WEEK: i64 = 7 * 86_400;
/// How long a refused account is held when its tool didn't say when it resets: its next report
/// says more.
const UNKNOWN_RESET: i64 = 3_600;
/// The last second `time::format` writes with four digits (9999-12-31T23:59:59Z).
const LAST: i64 = 253_402_300_799;

/// One account's usage as its tool last reported it, and the owner's lift. Shares are 0...1;
/// times are seconds since the epoch.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Usage {
    pub five_hour: Option<f64>,
    pub seven_day: Option<f64>,
    pub five_hour_resets: Option<i64>,
    pub seven_day_resets: Option<i64>,
    /// The tool refused work, or a window reached 100%: the account takes nothing until then.
    pub full_until: Option<i64>,
    /// The owner let it past its weekly reserve until then, its week's reset.
    pub reserve_lifted_until: Option<i64>,
}

/// A window's share now: one whose reset has passed starts again from nothing.
fn current(used: Option<f64>, resets: Option<i64>, now: i64) -> Option<f64> {
    used.map(|used| {
        if resets.is_some_and(|at| at <= now) {
            0.0
        } else {
            used
        }
    })
}

impl Usage {
    pub fn five_hour_at(&self, now: i64) -> Option<f64> {
        current(self.five_hour, self.five_hour_resets, now)
    }
    pub fn seven_day_at(&self, now: i64) -> Option<f64> {
        current(self.seven_day, self.seven_day_resets, now)
    }
    /// The week's reset while it is still ahead.
    fn week_resets(&self, now: i64) -> Option<i64> {
        self.seven_day_resets.filter(|at| *at > now)
    }
    pub fn full_until_at(&self, now: i64) -> Option<i64> {
        self.full_until.filter(|at| *at > now)
    }
    /// Until when the owner lifted its reserve, while that is still ahead.
    pub fn lifted_until(&self, now: i64) -> Option<i64> {
        self.reserve_lifted_until.filter(|at| *at > now)
    }
    /// At 80% of its week and not lifted by the owner. Claude Code reports usage only during a
    /// job, so the share stays until its week resets.
    pub fn reserved(&self, now: i64) -> bool {
        self.seven_day_at(now).unwrap_or(0.0) >= RESERVE && self.lifted_until(now).is_none()
    }
    /// Why it can't take automatic work now ("is at 96% of its week"), or `None` when it can.
    pub fn held(&self, now: i64) -> Option<String> {
        let percent = |used: f64| (used * 100.0).round() as i64;
        let until =
            |at: Option<i64>| at.map_or(String::new(), |at| format!(" until {}", time::format(at)));
        if let Some(at) = self.full_until_at(now) {
            return Some(format!("hit its usage limit{}", until(Some(at))));
        }
        let five = self.five_hour_at(now).unwrap_or(0.0);
        if five >= NEARLY_FULL {
            return Some(format!(
                "is at {}% of its 5-hour window{}",
                percent(five),
                until(self.five_hour_resets)
            ));
        }
        let week = self.seven_day_at(now).unwrap_or(0.0);
        if week >= NEARLY_FULL {
            return Some(format!(
                "is at {}% of its week{}",
                percent(week),
                until(self.week_resets(now))
            ));
        }
        self.reserved(now).then(|| {
            format!(
                "is in its weekly reserve ({}% of its week used){}; use it anyway from Settings › Accounts",
                percent(week),
                until(self.week_resets(now))
            )
        })
    }
}

/// Every account's usage, by id.
pub struct Usages {
    file: PathBuf,
    state: Mutex<HashMap<String, Usage>>,
}

impl Usages {
    /// Reads what was kept. A file that doesn't read is set aside as `usage.json.unreadable` and
    /// obid starts over (as the Swift runner does): every reserve the owner lifted is back, and
    /// usage is unknown until each tool reports again.
    pub fn open(home: &Path) -> Self {
        let file = home.join("usage.json");
        let state = match std::fs::read(&file) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|error| {
                let aside = file.with_extension("json.unreadable");
                let moved = std::fs::rename(&file, &aside);
                tracing::warn!(
                    "account usage doesn't read ({error}); starting over{}",
                    match moved {
                        Ok(()) => format!(", the old file is {}", aside.display()),
                        Err(e) => format!(" (it couldn't be set aside: {e})"),
                    }
                );
                HashMap::new()
            }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
            Err(error) => {
                tracing::warn!("account usage doesn't read ({error}); starting over");
                HashMap::new()
            }
        };
        Self {
            file,
            state: Mutex::new(state),
        }
    }

    pub fn get(&self, id: &str) -> Usage {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(id)
            .cloned()
            .unwrap_or_default()
    }

    /// Applies `update` to one account and saves every account. With `require_saved`, a change
    /// that isn't saved isn't applied either: the owner's changes are acknowledged only when kept.
    /// A tool's report is applied anyway, so a fresh limit holds for this process.
    fn change(
        &self,
        id: &str,
        require_saved: bool,
        update: impl FnOnce(&mut Usage),
    ) -> std::io::Result<Usage> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut next = state.clone();
        let value = next.entry(id.to_owned()).or_default();
        update(value);
        let value = value.clone();
        let saved = serde_json::to_vec_pretty(&next)
            .map_err(std::io::Error::other)
            .and_then(|bytes| crate::store::write_private(&self.file, &bytes));
        if saved.is_ok() || !require_saved {
            *state = next;
        }
        saved?;
        Ok(value)
    }

    /// Keeps what a tool just reported. A window it didn't report keeps its last share and reset;
    /// one reported without a reset keeps the last reset. A report never lifts a reserve.
    pub fn record(&self, id: &str, usage: &Usage) -> std::io::Result<Usage> {
        self.change(id, false, |kept| {
            if let Some(used) = usage.five_hour {
                kept.five_hour = Some(used);
                if usage.five_hour_resets.is_some() {
                    kept.five_hour_resets = usage.five_hour_resets;
                }
            }
            if let Some(used) = usage.seven_day {
                kept.seven_day = Some(used);
                if usage.seven_day_resets.is_some() {
                    kept.seven_day_resets = usage.seven_day_resets;
                }
            }
            if usage.full_until.is_some() {
                kept.full_until = usage.full_until;
            }
        })
    }

    /// "Use anyway" (#278): with `lift`, the account takes automatic work past its weekly reserve
    /// until its week resets (a week from now while the reset is unknown), then it's reserved
    /// again by itself; without, it's reserved again now.
    pub fn lift(&self, id: &str, lift: bool) -> std::io::Result<Usage> {
        let now = time::now();
        self.change(id, true, |usage| {
            usage.reserve_lifted_until = lift.then(|| usage.week_resets(now).unwrap_or(now + WEEK));
        })
    }
}

fn number(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str()?.trim().parse().ok())
        .filter(|v| v.is_finite())
}

/// A time a tool reported, in seconds or milliseconds since the epoch.
fn epoch(value: &Value) -> Option<i64> {
    let seconds = number(value).filter(|v| *v > 0.0)?;
    let seconds = if seconds > 1e11 {
        seconds / 1000.0
    } else {
        seconds
    };
    Some((seconds as i64).min(LAST))
}

fn share(value: &Value, divisor: f64) -> Option<f64> {
    number(value).map(|n| (n / divisor).clamp(0.0, 1.0))
}

/// Until when a refused account is full: the soonest reset of a window at 100%, else the reset
/// the refusal named, else an hour from now. `None` when nothing is full.
fn full_until(
    windows: [(Option<f64>, Option<i64>); 2],
    refused: bool,
    named: Option<i64>,
) -> Option<i64> {
    let full: Vec<Option<i64>> = windows
        .into_iter()
        .filter(|(used, _)| used.is_some_and(|n| n >= 1.0))
        .map(|(_, resets)| resets)
        .collect();
    (refused || !full.is_empty()).then(|| {
        full.into_iter()
            .flatten()
            .min()
            .or(named)
            .unwrap_or_else(|| time::now() + UNKNOWN_RESET)
    })
}

/// Claude Code's `rate_limit_event`: its `unifiedWindows` (`five_hour`, `seven_day`), each with a
/// `utilization` of 0...1 and a `resetsAt` in epoch seconds. Older versions name one window at the
/// top (`rateLimitType`, `utilization`, `resetsAt`). `status` `rejected` means it refused work.
pub fn claude(message: &Value) -> Usage {
    let info = &message["rate_limit_info"];
    let windows = &info["unifiedWindows"];
    let window = |key: &str| -> (Option<f64>, Option<i64>) {
        let w = if windows.is_object() {
            &windows[key]
        } else if info["rateLimitType"] == key {
            info
        } else {
            &Value::Null
        };
        (share(&w["utilization"], 1.0), epoch(&w["resetsAt"]))
    };
    let (five_hour, five_hour_resets) = window("five_hour");
    let (seven_day, seven_day_resets) = window("seven_day");
    Usage {
        five_hour,
        seven_day,
        five_hour_resets,
        seven_day_resets,
        full_until: full_until(
            [(five_hour, five_hour_resets), (seven_day, seven_day_resets)],
            info["status"] == "rejected",
            epoch(&info["resetsAt"]),
        ),
        ..Usage::default()
    }
}

/// One snapshot of Codex's limits (`RateLimitSnapshot`, from `account/rateLimits/read` or a sparse
/// `account/rateLimits/updated`). Only Codex's own limit counts (`limitId` `codex` or none): a
/// model's has its own id. Windows are told apart by length (300 minutes, 10080), `usedPercent`
/// is 0...100; a `rateLimitReachedType` means Codex refuses work. `None` when it says nothing.
pub fn codex(limits: &Value) -> Option<Usage> {
    if limits
        .get("limitId")
        .and_then(Value::as_str)
        .is_some_and(|id| id != "codex")
    {
        return None;
    }
    let mut usage = Usage::default();
    for key in ["primary", "secondary"] {
        let w = &limits[key];
        match w["windowDurationMins"].as_u64() {
            Some(300) => {
                usage.five_hour = share(&w["usedPercent"], 100.0);
                usage.five_hour_resets = epoch(&w["resetsAt"]);
            }
            Some(10080) => {
                usage.seven_day = share(&w["usedPercent"], 100.0);
                usage.seven_day_resets = epoch(&w["resetsAt"]);
            }
            _ => {}
        }
    }
    usage.full_until = full_until(
        [
            (usage.five_hour, usage.five_hour_resets),
            (usage.seven_day, usage.seven_day_resets),
        ],
        limits["rateLimitReachedType"].is_string(),
        None,
    );
    (usage != Usage::default()).then_some(usage)
}

/// The answer to `account/rateLimits/read`: Codex's own bucket from `rateLimitsByLimitId` when the
/// server has it, else the single-bucket `rateLimits`.
pub fn codex_read(result: &Value) -> Option<Usage> {
    match &result["rateLimitsByLimitId"]["codex"] {
        own @ Value::Object(_) => codex(own),
        _ => codex(&result["rateLimits"]),
    }
}

/// What a job's turns used, summed as the tools reported them (#731). A count no tool reported
/// stays `None`, never 0. `input` is the input not read from the cache.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tokens {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write: Option<u64>,
    /// What the tool says it cost at API prices.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    /// `api`: the account pays per token (an API key); `plan`: a subscription covers it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priced: Option<String>,
}

fn plus<T: std::ops::Add<Output = T> + Default>(a: Option<T>, b: Option<T>) -> Option<T> {
    match (a, b) {
        (None, None) => None,
        (a, b) => Some(a.unwrap_or_default() + b.unwrap_or_default()),
    }
}

impl Tokens {
    /// `self` and `other` together; `other`'s `priced` when it says.
    pub fn plus(&self, other: &Tokens) -> Tokens {
        Tokens {
            input: plus(self.input, other.input),
            output: plus(self.output, other.output),
            cache_read: plus(self.cache_read, other.cache_read),
            cache_write: plus(self.cache_write, other.cache_write),
            cost_usd: plus(self.cost_usd, other.cost_usd),
            priced: other.priced.clone().or_else(|| self.priced.clone()),
        }
    }

    fn minus(&self, other: &Tokens) -> Tokens {
        let less = |a: Option<u64>, b: Option<u64>| a.map(|a| a.saturating_sub(b.unwrap_or(0)));
        Tokens {
            input: less(self.input, other.input),
            output: less(self.output, other.output),
            cache_read: less(self.cache_read, other.cache_read),
            ..self.clone()
        }
    }
}

/// A Claude Code `result` line's counts: its `modelUsage` summed over the models when it's there
/// (it counts the subagents' models too), else its `usage`, and `total_cost_usd`. `priced` from
/// the run's `init` line: `apiKeySource` `none` is the account's subscription login.
pub fn claude_tokens(result: &Value, api_key_source: Option<&str>) -> Tokens {
    let count = |v: &Value| v.as_u64();
    let mut tokens = match result["modelUsage"].as_object().filter(|m| !m.is_empty()) {
        Some(models) => models.values().fold(Tokens::default(), |sum, m| {
            sum.plus(&Tokens {
                input: count(&m["inputTokens"]),
                output: count(&m["outputTokens"]),
                cache_read: count(&m["cacheReadInputTokens"]),
                cache_write: count(&m["cacheCreationInputTokens"]),
                ..Tokens::default()
            })
        }),
        None => {
            let usage = &result["usage"];
            Tokens {
                input: count(&usage["input_tokens"]),
                output: count(&usage["output_tokens"]),
                cache_read: count(&usage["cache_read_input_tokens"]),
                cache_write: count(&usage["cache_creation_input_tokens"]),
                ..Tokens::default()
            }
        }
    };
    tokens.cost_usd = result["total_cost_usd"]
        .as_f64()
        .filter(|c| c.is_finite() && *c >= 0.0);
    tokens.priced =
        api_key_source.map(|source| if source == "none" { "plan" } else { "api" }.into());
    tokens
}

/// One of Codex's `tokenUsage` breakdowns (`total` or `last`, from `thread/tokenUsage/updated`).
/// Its `inputTokens` include the cached ones; Codex reports no cache writes or cost.
fn codex_breakdown(b: &Value) -> Option<Tokens> {
    let input = b["inputTokens"].as_u64()?;
    let cached = b["cachedInputTokens"].as_u64();
    Some(Tokens {
        input: Some(input.saturating_sub(cached.unwrap_or(0))),
        output: b["outputTokens"].as_u64(),
        cache_read: cached,
        ..Tokens::default()
    })
}

/// A Codex turn's counts so far, from a `thread/tokenUsage/updated`'s `tokenUsage`: its thread's
/// `total` less what the thread had used before this turn (`before`, worked out from the turn's
/// first update as its `total` less its `last`). A thread resumed in a new round keeps its total,
/// and an update sent twice counts once.
// ponytail: assumes the turn's first update is for a new response; an update Codex repeats
// before the turn's first response would count its `last` twice.
pub fn codex_turn(usage: &Value, before: &mut Option<Tokens>) -> Option<Tokens> {
    let total = codex_breakdown(&usage["total"])?;
    let base = before.get_or_insert_with(|| {
        codex_breakdown(&usage["last"]).map_or_else(Tokens::default, |last| total.minus(&last))
    });
    Some(total.minus(base))
}

/// Codex's `account/read` answer: `apiKey` pays per token, `chatgpt` is a plan. Only the type is
/// read, never who is signed in.
pub fn codex_priced(result: &Value) -> Option<String> {
    match result["account"]["type"].as_str()? {
        "apiKey" => Some("api".into()),
        "chatgpt" => Some("plan".into()),
        _ => None,
    }
}

/// An ACP `session/prompt` answer's `usage`, when the agent reports one.
pub fn acp_tokens(answer: &Value) -> Option<Tokens> {
    let usage = answer.get("usage").filter(|u| u.is_object())?;
    let count = |key: &str| usage[key].as_u64();
    Some(Tokens {
        input: count("inputTokens"),
        output: count("outputTokens"),
        cache_read: count("cachedReadTokens"),
        cache_write: count("cachedWriteTokens"),
        ..Tokens::default()
    })
    .filter(|t| t != &Tokens::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct Home(PathBuf);
    impl Home {
        fn new(name: &str) -> Self {
            let home = std::env::temp_dir().join(format!("obid-{name}-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&home).unwrap();
            Self(home)
        }
    }
    impl Drop for Home {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn week(used: f64, resets: i64) -> Usage {
        Usage {
            seven_day: Some(used),
            seven_day_resets: Some(resets),
            ..Usage::default()
        }
    }

    #[test]
    fn disk_failure_keeps_fresh_limits_but_does_not_apply_an_unsaved_lift() {
        let home = Home::new("disk-usage");
        let usages = Usages::open(&home.0);
        std::fs::create_dir(home.0.join("usage.json")).unwrap();
        assert!(usages.record("a", &week(0.82, i64::MAX)).is_err());
        assert!(usages.get("a").reserved(time::now()));
        assert!(usages.lift("a", true).is_err());
        assert!(usages.get("a").reserved(time::now()));
    }

    #[test]
    fn an_unreadable_file_is_set_aside_and_obid_starts_over() {
        let home = Home::new("bad-usage");
        std::fs::write(home.0.join("usage.json"), "{").unwrap();
        let usages = Usages::open(&home.0);
        assert_eq!(usages.get("a"), Usage::default());
        assert_eq!(
            std::fs::read_to_string(home.0.join("usage.json.unreadable")).unwrap(),
            "{"
        );
        usages.record("a", &week(0.82, i64::MAX)).unwrap();
        assert!(Usages::open(&home.0).get("a").reserved(time::now()));
    }

    #[test]
    fn codex_windows_and_partial_updates() {
        let limits = json!({"primary": {"windowDurationMins": 10080, "usedPercent": 82, "resetsAt": "2000000000"}, "secondary": {"windowDurationMins": 300, "usedPercent": 20, "resetsAt": 1900000000}, "planType": "plus"});
        let usage = codex(&limits).unwrap();
        assert_eq!(usage.seven_day, Some(0.82));
        assert_eq!(usage.five_hour, Some(0.2));
        assert_eq!(usage.seven_day_resets, Some(2000000000));
        assert_eq!(usage.full_until, None);
        assert!(codex(&json!({"limitId": "model", "primary": limits["primary"]})).is_none());
        assert!(
            codex(&json!({"primary": {"windowDurationMins": 300, "usedPercent": "NaN"}})).is_none()
        );
        let home = Home::new("usage");
        let usages = Usages::open(&home.0);
        usages.record("a", &usage).unwrap();
        usages
            .record(
                "a",
                &Usage {
                    five_hour: Some(0.4),
                    ..Usage::default()
                },
            )
            .unwrap();
        let kept = Usages::open(&home.0).get("a");
        assert_eq!(kept.seven_day, Some(0.82));
        assert_eq!(kept.five_hour, Some(0.4));
        assert_eq!(kept.five_hour_resets, Some(1900000000));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(home.0.join("usage.json"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    /// The answer `codex app-server` 0.163 gave on 2026-10-17 for a Plus account at 100% of its
    /// 5-hour window (its `accountId`, credits and upsell taken out).
    #[test]
    fn a_real_codex_answer_marks_the_account_full() {
        let snapshot = json!({"limitId": "codex", "limitName": null, "primary": {"usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1792260805}, "secondary": {"usedPercent": 70, "windowDurationMins": 10080, "resetsAt": 1792724553}, "planType": "plus", "rateLimitReachedType": "rate_limit_reached", "spendControlReached": false});
        let mut model = snapshot.clone();
        model["limitId"] = json!("gpt-5-codex-mini");
        model["primary"]["usedPercent"] = json!(3);
        let read = json!({"ordinaryUsageAllowed": false, "rateLimits": model, "rateLimitsByLimitId": {"codex": snapshot, "gpt-5-codex-mini": model}});
        let usage = codex_read(&read).unwrap();
        assert_eq!(usage.five_hour, Some(1.0));
        assert_eq!(usage.seven_day, Some(0.7));
        assert_eq!(usage.full_until, Some(1792260805));
        assert!(
            usage
                .held(1792250000)
                .unwrap()
                .starts_with("hit its usage limit until")
        );
        assert_eq!(usage.held(1792260806), None);
        // An older server has only the single bucket.
        assert_eq!(
            codex_read(&json!({"rateLimits": snapshot}))
                .unwrap()
                .full_until,
            Some(1792260805)
        );
        // Refused below 100% (credits ran out): held until its next report says more.
        let refused = codex(&json!({"rateLimitReachedType": "workspace_owner_credits_depleted"}))
            .unwrap()
            .full_until
            .unwrap();
        assert!(refused > time::now() && refused <= time::now() + UNKNOWN_RESET);
    }

    /// The event `claude -p` 2.x sent on 2026-10-17.
    #[test]
    fn a_real_claude_event_and_an_older_one() {
        let event = json!({"type": "rate_limit_event", "rate_limit_info": {"status": "allowed_warning", "resetsAt": 1792764000, "rateLimitType": "seven_day", "utilization": 0.54, "overageStatus": "rejected", "isUsingOverage": false, "unifiedWindows": {"five_hour": {"utilization": 0.45, "resetsAt": 1792260000}, "seven_day": {"utilization": 0.54, "resetsAt": 1792764000}}}});
        let usage = claude(&event);
        assert_eq!(usage.five_hour, Some(0.45));
        assert_eq!(usage.seven_day, Some(0.54));
        assert_eq!(usage.five_hour_resets, Some(1792260000));
        assert_eq!(usage.seven_day_resets, Some(1792764000));
        assert_eq!(usage.full_until, None);
        let older = json!({"rate_limit_info": {"status": "rejected", "rateLimitType": "five_hour", "utilization": 1, "resetsAt": 1792260000000_i64}});
        let usage = claude(&older);
        assert_eq!(usage.five_hour, Some(1.0));
        assert_eq!(usage.seven_day, None);
        assert_eq!(usage.five_hour_resets, Some(1792260000));
        assert_eq!(usage.full_until, Some(1792260000));
        let full = claude(
            &json!({"rate_limit_info": {"unifiedWindows": {"five_hour": {"utilization": 1, "resetsAt": 400}}}}),
        );
        assert_eq!(full.full_until, Some(400));
    }

    #[test]
    fn times_are_seconds_or_milliseconds_and_never_zero() {
        assert_eq!(epoch(&json!(1792260000)), Some(1792260000));
        assert_eq!(epoch(&json!(1792260000123_i64)), Some(1792260000));
        assert_eq!(epoch(&json!("1792260000")), Some(1792260000));
        assert_eq!(epoch(&json!(0)), None);
        assert_eq!(epoch(&json!(-5)), None);
        assert_eq!(epoch(&json!(1e300)), Some(LAST));
        assert_eq!(epoch(&Value::Null), None);
    }

    #[test]
    fn reserves_expire_and_near_full_limits_hold() {
        let mut usage = week(0.82, 200);
        assert!(usage.reserved(100));
        assert!(
            usage
                .held(100)
                .unwrap()
                .contains("weekly reserve (82% of its week used)")
        );
        usage.reserve_lifted_until = Some(200);
        assert_eq!(usage.held(100), None);
        usage.five_hour = Some(0.95);
        assert!(
            usage
                .held(100)
                .unwrap()
                .contains("95% of its 5-hour window")
        );
        usage.five_hour_resets = Some(99);
        assert_eq!(usage.held(100), None);
        usage.seven_day = Some(0.95);
        assert!(usage.held(100).unwrap().contains("95% of its week"));
        // Past the week's reset it starts over.
        assert_eq!(usage.seven_day_at(200), Some(0.0));
        assert_eq!(usage.held(201), None);
        usage.full_until = Some(300);
        assert!(usage.held(201).is_some());
        assert_eq!(usage.held(300), None);
    }

    #[test]
    fn lifting_lasts_until_the_week_resets() {
        let home = Home::new("lift");
        let usages = Usages::open(&home.0);
        let resets = time::now() + 2 * 86_400;
        usages.record("a", &week(0.82, resets)).unwrap();
        assert_eq!(
            usages.lift("a", true).unwrap().reserve_lifted_until,
            Some(resets)
        );
        assert!(!Usages::open(&home.0).get("a").reserved(time::now()));
        assert_eq!(usages.lift("a", false).unwrap().reserve_lifted_until, None);
        assert!(usages.get("a").reserved(time::now()));
        // Unknown reset: a week from now.
        let until = usages
            .lift("b", true)
            .unwrap()
            .reserve_lifted_until
            .unwrap();
        assert!((until - (time::now() + WEEK)).abs() <= 2);
    }

    #[test]
    fn claude_results_count_their_models_and_cost() {
        let result = json!({"type": "result", "total_cost_usd": 0.25,
            "usage": {"input_tokens": 10, "output_tokens": 2, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 5},
            "modelUsage": {
                "claude-opus-5-5": {"inputTokens": 10, "outputTokens": 2, "cacheReadInputTokens": 100, "cacheCreationInputTokens": 5, "costUSD": 0.2},
                "claude-haiku-5-5": {"inputTokens": 3, "outputTokens": 1, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "costUSD": 0.05}}});
        let tokens = claude_tokens(&result, Some("none"));
        assert_eq!(
            tokens,
            Tokens {
                input: Some(13),
                output: Some(3),
                cache_read: Some(100),
                cache_write: Some(5),
                cost_usd: Some(0.25),
                priced: Some("plan".into()),
            }
        );
        let older = json!({"usage": {"input_tokens": 10, "output_tokens": 2}});
        let tokens = claude_tokens(&older, Some("ANTHROPIC_API_KEY"));
        assert_eq!(
            (tokens.input, tokens.cache_read, tokens.cost_usd),
            (Some(10), None, None)
        );
        assert_eq!(tokens.priced.as_deref(), Some("api"));
        assert_eq!(claude_tokens(&json!({}), None), Tokens::default());
        // Summing keeps what no tool reported absent.
        let sum = tokens.plus(&Tokens {
            cache_read: Some(4),
            ..Tokens::default()
        });
        assert_eq!(
            (sum.input, sum.cache_read, sum.cache_write),
            (Some(10), Some(4), None)
        );
        assert_eq!(serde_json::to_value(Tokens::default()).unwrap(), json!({}));
    }

    #[test]
    fn a_codex_turn_counts_what_its_thread_used_since_it_began() {
        let update = |total: u64, last: u64| {
            json!({"total": {"inputTokens": total, "cachedInputTokens": total / 2, "outputTokens": total / 10},
                   "last": {"inputTokens": last, "cachedInputTokens": last / 2, "outputTokens": last / 10}})
        };
        // A resumed thread had used 1000 before this turn; the turn's two responses use 400 and
        // 600, and the second update comes twice.
        let mut before = None;
        assert_eq!(
            codex_turn(&update(1400, 400), &mut before).unwrap().input,
            Some(200)
        );
        let turn = codex_turn(&update(2000, 600), &mut before).unwrap();
        assert_eq!(
            codex_turn(&update(2000, 600), &mut before),
            Some(turn.clone())
        );
        assert_eq!(
            (turn.input, turn.cache_read, turn.output),
            (Some(500), Some(500), Some(100))
        );
        assert_eq!(codex_turn(&json!({}), &mut None), None);
        assert_eq!(
            codex_priced(&json!({"account": {"type": "apiKey"}})).as_deref(),
            Some("api")
        );
        assert_eq!(
            codex_priced(&json!({"account": {"type": "chatgpt", "planType": "plus"}})).as_deref(),
            Some("plan")
        );
        assert_eq!(codex_priced(&json!({"account": null})), None);
        let acp = json!({"stopReason": "end_turn", "usage": {"inputTokens": 7, "outputTokens": 3, "totalTokens": 10}});
        assert_eq!(acp_tokens(&acp).unwrap().input, Some(7));
        assert_eq!(acp_tokens(&json!({"stopReason": "end_turn"})), None);
    }
}
