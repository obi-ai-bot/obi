//! Each account's subscription usage, its plan and the owner's weekly reserve, kept privately
//! across restarts in `home/account-usage.json` (0600), and the pick of an account with room for a
//! job (Engine/Accounts.swift is the behaviour it follows).
//!
//! All of it comes from the tools' own reports: Claude Code's `rate_limit_event` during a job, and
//! Codex's `account/rateLimits/read` and `account/rateLimits/updated`, whose snapshot also names
//! the plan (`planType`). Where a tool doesn't say its plan (Claude Code), the account shows the
//! plan its owner set. obid never reads a login to find any of it out.
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
/// From this share of either window an account takes no work at all, its reserve lifted or not.
pub const NEARLY_FULL: f64 = 0.95;
/// Accounts under this share of their 5-hour window go first: one above it may stop mid-job.
pub const BUSY: f64 = 0.8;
/// Accounts this close in weekly room per day count as even; the fewer running jobs wins.
const EVEN: f64 = 0.01;
const WEEK: i64 = 7 * 86_400;
/// How long a refused account is held when its tool didn't say when it resets: its next report
/// says more.
const UNKNOWN_RESET: i64 = 3_600;
/// The last second `time::format` writes with four digits (9999-12-31T23:59:59Z).
const LAST: i64 = 253_402_300_799;

/// One account's usage as its tool last reported it, and what its owner set. Shares are 0...1;
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
    /// The plan the tool last reported, like `plus`; `None` while it never said.
    pub plan: Option<String>,
    /// The plan the owner set for the account, shown when the tool doesn't say.
    pub owner_plan: Option<String>,
}

/// An account's plan and who said so.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Plan {
    pub name: String,
    pub source: PlanSource,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PlanSource {
    /// The tool's own report.
    Tool,
    /// The owner's setting, for a tool that doesn't say.
    Owner,
}

/// Why an account can't take a job now.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Hold {
    /// Refused by its tool, or at 100% of a window, until then.
    Full(i64),
    /// At 95% of its 5-hour window, until its reset (`None`: the tool didn't say).
    FiveHour(f64, Option<i64>),
    /// At 95% of its week.
    Week(f64, Option<i64>),
    /// In its weekly reserve, which only a job sent to it by name may use.
    Reserve(f64, Option<i64>),
}

impl Hold {
    /// "Personal is at 96% of its week until 2026-10-20T09:00:00Z".
    pub fn describe(&self, name: &str) -> String {
        let until = |at: &Option<i64>| match at {
            Some(at) => format!(" until {}", time::format(*at)),
            None => String::new(),
        };
        let percent = |used: &f64| (used * 100.0).round() as i64;
        match self {
            Hold::Full(at) => format!("{name} hit its usage limit until {}", time::format(*at)),
            Hold::FiveHour(used, at) => format!(
                "{name} is at {}% of its 5-hour window{}",
                percent(used),
                until(at)
            ),
            Hold::Week(used, at) => {
                format!("{name} is at {}% of its week{}", percent(used), until(at))
            }
            Hold::Reserve(used, at) => format!(
                "{name} is in its weekly reserve ({}% of its week used){}",
                percent(used),
                until(at)
            ),
        }
    }
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
    pub fn full(&self, now: i64) -> bool {
        self.full_until.is_some_and(|at| at > now)
    }
    /// Until when the owner lifted its reserve, while that is still ahead.
    pub fn lifted_until(&self, now: i64) -> Option<i64> {
        self.reserve_lifted_until.filter(|at| *at > now)
    }
    /// At 80% of its week: Claude Code reports usage only during a job, so the share stays until
    /// its week resets.
    pub fn in_reserve(&self, now: i64) -> bool {
        self.seven_day_at(now).unwrap_or(0.0) >= RESERVE
    }
    /// In its weekly reserve and not lifted by the owner.
    pub fn reserved(&self, now: i64) -> bool {
        self.in_reserve(now) && self.lifted_until(now).is_none()
    }
    /// Why it can't take a job now, or `None` when it can. A job the owner sent to it by name
    /// (`named`) may use its weekly reserve; nothing takes an account marked full or at 95% of
    /// either window.
    pub fn held(&self, named: bool, now: i64) -> Option<Hold> {
        if let Some(at) = self.full_until.filter(|at| *at > now) {
            return Some(Hold::Full(at));
        }
        let five = self.five_hour_at(now).unwrap_or(0.0);
        if five >= NEARLY_FULL {
            return Some(Hold::FiveHour(five, self.five_hour_resets));
        }
        let week = self.seven_day_at(now).unwrap_or(0.0);
        if week >= NEARLY_FULL {
            return Some(Hold::Week(week, self.week_resets(now)));
        }
        (!named && self.reserved(now)).then(|| Hold::Reserve(week, self.week_resets(now)))
    }
    pub fn eligible(&self, named: bool, now: i64) -> bool {
        self.held(named, now).is_none()
    }
    /// Lifting its reserve would let it take work: only the reserve holds it.
    pub fn liftable(&self, now: i64) -> bool {
        self.reserved(now) && self.held(true, now).is_none()
    }
    /// How much of its week has passed, 0...1, or `None` while the reset time is unknown.
    pub fn week_gone(&self, now: i64) -> Option<f64> {
        self.week_resets(now)
            .map(|at| (1.0 - (at - now) as f64 / WEEK as f64).clamp(0.0, 1.0))
    }
    /// How fast the week burns against its pace: the share used over the share of the week gone,
    /// counting at least a seventh gone so a week's first hours don't swing it. Above 1 it runs
    /// out before its reset.
    pub fn pace(&self, now: i64) -> Option<f64> {
        Some(self.seven_day_at(now)? / self.week_gone(now)?.max(1.0 / 7.0))
    }
    pub fn ahead(&self, now: i64) -> bool {
        self.pace(now).unwrap_or(0.0) > 1.0
    }
    /// The week's room per day until it resets: 57% left with 4.8 days to go is 0.12/day. At
    /// least a quarter of a day counts as left; without a reset time, the whole week.
    pub fn room_per_day(&self, now: i64) -> Option<f64> {
        let used = self.seven_day_at(now)?;
        let days = self
            .week_resets(now)
            .map_or(7.0, |at| ((at - now) as f64 / 86_400.0).max(0.25));
        Some((1.0 - used).max(0.0) / days)
    }
    /// The plan shown: the tool's report, else the owner's setting.
    pub fn plan(&self) -> Option<Plan> {
        let plan = |name: &Option<String>, source| name.clone().map(|name| Plan { name, source });
        plan(&self.plan, PlanSource::Tool).or_else(|| plan(&self.owner_plan, PlanSource::Owner))
    }
}

/// One account `choose` may pick.
#[derive(Debug, Clone)]
pub struct Candidate<'a> {
    pub id: &'a str,
    /// The owner's label, like "Personal".
    pub name: &'a str,
    /// "claude", "codex" or "cursor".
    pub agent: &'a str,
    pub usage: Usage,
    /// Jobs queued or running on it.
    pub running: u32,
}

/// The account `choose` picked, and why.
#[derive(Debug, Clone, PartialEq)]
pub struct Route<'a> {
    pub id: &'a str,
    pub reason: String,
}

/// Whether the tool reports usage at all: Cursor doesn't.
fn reports_usage(agent: &str) -> bool {
    agent != "cursor"
}

fn agent_name(agent: &str) -> &str {
    match agent {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "cursor" => "Cursor",
        other => other,
    }
}

/// "2.3×".
fn times(pace: f64) -> String {
    format!("{pace:.1}×")
}

/// The account for a new job no one named, budgeted by each account's weekly pace: one that can
/// take work (`Usage::held`, its weekly reserve included). Of those, in order:
/// - one under 80% of its 5-hour window, when there is one;
/// - one on pace with its usage known, then one whose usage isn't known yet, then one ahead of
///   pace; a tool that reports no usage (Cursor) only when nothing else can;
/// - the most weekly room per day left; within 0.01/day of it, the fewest running jobs, then the
///   most room, then list order.
///
/// Each account's usage is measured against its own plan. With none, why each account is held.
pub fn choose<'a>(candidates: &[Candidate<'a>], now: i64) -> Result<Route<'a>, String> {
    let open: Vec<(usize, &Candidate<'a>)> = candidates
        .iter()
        .enumerate()
        .filter(|(_, c)| c.usage.eligible(false, now))
        .collect();
    if open.is_empty() {
        return Err(no_room(candidates, now));
    }
    let calm: Vec<_> = open
        .iter()
        .copied()
        .filter(|(_, c)| c.usage.five_hour_at(now).unwrap_or(0.0) < BUSY)
        .collect();
    let pool = if calm.is_empty() { &open } else { &calm };
    let tier = |c: &Candidate| {
        if !reports_usage(c.agent) {
            3
        } else if c.usage.seven_day_at(now).is_none() {
            1
        } else if c.usage.ahead(now) {
            2
        } else {
            0
        }
    };
    let room = |c: &Candidate| c.usage.room_per_day(now).unwrap_or(0.0);
    let first = pool.iter().map(|(_, c)| tier(c)).min().unwrap_or(0);
    let tied: Vec<_> = pool.iter().filter(|(_, c)| tier(c) == first).collect();
    let most = tied.iter().map(|(_, c)| room(c)).fold(0.0, f64::max);
    let close: Vec<_> = tied
        .into_iter()
        .filter(|(_, c)| room(c) >= most - EVEN)
        .collect();
    let (_, chosen) = close
        .iter()
        .min_by(|(a_index, a), (b_index, b)| {
            a.running
                .cmp(&b.running)
                .then(room(b).total_cmp(&room(a)))
                .then(a_index.cmp(b_index))
        })
        .expect("an open account");
    Ok(Route {
        id: chosen.id,
        reason: reason(chosen, &open, close.len(), now),
    })
}

/// Why `chosen` was taken over the other `open` accounts.
fn reason(chosen: &Candidate, open: &[(usize, &Candidate)], close: usize, now: i64) -> String {
    if !reports_usage(chosen.agent) {
        return format!(
            "{} reports no usage: fewest jobs running",
            agent_name(chosen.agent)
        );
    }
    let mut reasons = Vec::new();
    match chosen.usage.room_per_day(now) {
        Some(room) => {
            let mut line = format!("most weekly room per day left ({room:.2}/day)");
            if close > 1 {
                line += " and the fewest jobs running";
            }
            if chosen.usage.ahead(now)
                && let Some(pace) = chosen.usage.pace(now)
            {
                line += &format!(", though {} ahead of pace: none is on pace", times(pace));
            }
            reasons.push(line);
        }
        None => reasons.push(format!(
            "its usage isn't known yet{}",
            if close > 1 {
                ", and the fewest jobs running"
            } else {
                ""
            }
        )),
    }
    if chosen.usage.five_hour_at(now).unwrap_or(0.0) >= BUSY {
        reasons.push("every account is above 80% of its 5-hour window".into());
    }
    let ahead = open
        .iter()
        .filter(|(_, c)| c.id != chosen.id && c.usage.ahead(now))
        .filter_map(|(_, c)| Some((c, c.usage.pace(now)?)))
        .max_by(|a, b| a.1.total_cmp(&b.1));
    if let Some((other, pace)) = ahead {
        reasons.push(format!("{} is {} ahead of pace", other.name, times(pace)));
    }
    reasons.join("; ")
}

/// Why no account takes a new job no one named. When only weekly reserves stand in the way, it
/// says which, and that the owner can use one anyway.
fn no_room(candidates: &[Candidate], now: i64) -> String {
    let held: Vec<&str> = candidates
        .iter()
        .filter(|c| c.usage.liftable(now))
        .map(|c| c.name)
        .collect();
    if !held.is_empty() {
        let listed = match held.as_slice() {
            [one] => format!("{one} is in its weekly reserve"),
            [rest @ .., last] => {
                format!("{} and {last} are in their weekly reserve", rest.join(", "))
            }
            [] => unreachable!(),
        };
        let one = if held.len() == 1 { "it" } else { "one" };
        return format!(
            "No account has room: {listed}. Use {one} anyway from Settings › Accounts."
        );
    }
    let why: Vec<String> = candidates
        .iter()
        .filter_map(|c| Some(c.usage.held(false, now)?.describe(c.name)))
        .collect();
    if why.is_empty() {
        return "No account has room.".into();
    }
    format!("No account has room: {}.", why.join("; "))
}

/// Every account's usage, by id.
pub struct Accounts {
    file: PathBuf,
    state: Mutex<HashMap<String, Usage>>,
}

impl Accounts {
    /// Reads what was kept. A file that doesn't read is set aside as `account-usage.json.unreadable`
    /// and obid starts over (as the Swift runner does): every reserve the owner lifted is back, and
    /// usage is unknown until each tool reports again.
    pub fn open(home: &Path) -> Self {
        let file = home.join("account-usage.json");
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

    pub fn eligible(&self, id: &str, named: bool) -> bool {
        self.get(id).eligible(named, time::now())
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
    /// one reported without a reset keeps the last reset. Only the tool's own fields are taken:
    /// a report never lifts a reserve or sets the owner's plan.
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
            if usage.plan.is_some() {
                kept.plan.clone_from(&usage.plan);
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

    /// The owner's plan for an account whose tool doesn't say, like "Max 20x"; `None` clears it.
    /// At most 40 letters, digits, spaces, `+`, `-`, `_`, `.` or `×`.
    pub fn set_plan(&self, id: &str, plan: Option<&str>) -> std::io::Result<Usage> {
        let plan = match plan.map(str::trim) {
            None | Some("") => None,
            Some(plan) => Some(plan_name(plan).ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "A plan is at most 40 letters, digits, spaces, +, -, _, . or ×.",
                )
            })?),
        };
        self.change(id, true, |usage| usage.owner_plan = plan)
    }
}

/// A plan's name as obid keeps it, or `None` for one that isn't a plain short name.
fn plan_name(text: &str) -> Option<String> {
    let text = text.trim();
    let plain = |c: char| c.is_alphanumeric() || matches!(c, ' ' | '+' | '-' | '_' | '.' | '×');
    (!text.is_empty() && text.chars().count() <= 40 && text.chars().all(plain))
        .then(|| text.to_owned())
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
/// Claude Code doesn't say its plan.
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
    usage.plan = codex_plan(&limits["planType"]);
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

/// The plan from the answer to `account/read`; only `planType` is read, never who is signed in.
pub fn codex_account_plan(result: &Value) -> Option<String> {
    codex_plan(&result["account"]["planType"])
}

fn codex_plan(value: &Value) -> Option<String> {
    value
        .as_str()
        .filter(|plan| *plan != "unknown")
        .and_then(plan_name)
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

    fn candidate<'a>(id: &'a str, agent: &'a str, usage: Usage, running: u32) -> Candidate<'a> {
        Candidate {
            id,
            name: id,
            agent,
            usage,
            running,
        }
    }

    #[test]
    fn disk_failure_keeps_fresh_limits_but_does_not_apply_an_unsaved_lift() {
        let home = Home::new("disk-usage");
        let accounts = Accounts::open(&home.0);
        std::fs::create_dir(home.0.join("account-usage.json")).unwrap();
        assert!(accounts.record("a", &week(0.82, i64::MAX)).is_err());
        assert!(accounts.get("a").reserved(time::now()));
        assert!(accounts.lift("a", true).is_err());
        assert!(accounts.get("a").reserved(time::now()));
        assert!(accounts.set_plan("a", Some("Max")).is_err());
        assert_eq!(accounts.get("a").plan(), None);
    }

    #[test]
    fn an_unreadable_file_is_set_aside_and_obid_starts_over() {
        let home = Home::new("bad-usage");
        let file = home.0.join("account-usage.json");
        std::fs::write(&file, "{").unwrap();
        let accounts = Accounts::open(&home.0);
        assert!(accounts.eligible("a", false));
        assert_eq!(
            std::fs::read_to_string(home.0.join("account-usage.json.unreadable")).unwrap(),
            "{"
        );
        accounts.record("a", &week(0.82, i64::MAX)).unwrap();
        assert!(Accounts::open(&home.0).get("a").reserved(time::now()));
    }

    #[test]
    fn codex_windows_plan_and_partial_updates() {
        let limits = json!({"primary": {"windowDurationMins": 10080, "usedPercent": 82, "resetsAt": "2000000000"}, "secondary": {"windowDurationMins": 300, "usedPercent": 20, "resetsAt": 1900000000}, "planType": "plus"});
        let usage = codex(&limits).unwrap();
        assert_eq!(usage.seven_day, Some(0.82));
        assert_eq!(usage.five_hour, Some(0.2));
        assert_eq!(usage.seven_day_resets, Some(2000000000));
        assert_eq!(usage.full_until, None);
        assert_eq!(usage.plan.as_deref(), Some("plus"));
        assert!(codex(&json!({"limitId": "model", "primary": limits["primary"]})).is_none());
        assert!(
            codex(&json!({"primary": {"windowDurationMins": 300, "usedPercent": "NaN"}})).is_none()
        );
        assert_eq!(codex(&json!({"planType": "unknown"})), None);
        let home = Home::new("usage");
        let accounts = Accounts::open(&home.0);
        accounts.record("a", &usage).unwrap();
        accounts
            .record(
                "a",
                &Usage {
                    five_hour: Some(0.4),
                    ..Usage::default()
                },
            )
            .unwrap();
        let kept = Accounts::open(&home.0).get("a");
        assert_eq!(kept.seven_day, Some(0.82));
        assert_eq!(kept.five_hour, Some(0.4));
        assert_eq!(kept.five_hour_resets, Some(1900000000));
        assert_eq!(kept.plan.as_deref(), Some("plus"));
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(home.0.join("account-usage.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    /// The answer `codex app-server` 0.163 gave on 2026-10-17 for a Plus account at 100% of its
    /// 5-hour window (its `accountId`, credits and upsell taken out).
    #[test]
    fn a_real_codex_answer_marks_the_account_full_with_its_plan() {
        let snapshot = json!({"limitId": "codex", "limitName": null, "primary": {"usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1792260805}, "secondary": {"usedPercent": 70, "windowDurationMins": 10080, "resetsAt": 1792724553}, "planType": "plus", "rateLimitReachedType": "rate_limit_reached", "spendControlReached": false});
        let mut model = snapshot.clone();
        model["limitId"] = json!("gpt-5-codex-mini");
        model["primary"]["usedPercent"] = json!(3);
        let read = json!({"ordinaryUsageAllowed": false, "rateLimits": model, "rateLimitsByLimitId": {"codex": snapshot, "gpt-5-codex-mini": model}});
        let usage = codex_read(&read).unwrap();
        assert_eq!(usage.five_hour, Some(1.0));
        assert_eq!(usage.seven_day, Some(0.7));
        assert_eq!(usage.full_until, Some(1792260805));
        assert_eq!(usage.plan.as_deref(), Some("plus"));
        let now = 1792250000;
        assert_eq!(usage.held(true, now), Some(Hold::Full(1792260805)));
        assert!(usage.eligible(true, 1792260806));
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
        let account = json!({"account": {"type": "chatgpt", "email": "someone@example.com", "planType": "pro"}, "requiresOpenaiAuth": true});
        assert_eq!(codex_account_plan(&account).as_deref(), Some("pro"));
        assert_eq!(codex_account_plan(&json!({"account": null})), None);
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
        assert_eq!(usage.plan, None);
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
    fn reserves_expire_and_near_full_limits_always_hold() {
        let mut usage = week(0.82, 200);
        assert!(usage.reserved(100));
        assert_eq!(usage.held(false, 100), Some(Hold::Reserve(0.82, Some(200))));
        assert!(usage.eligible(true, 100));
        assert!(usage.liftable(100));
        usage.reserve_lifted_until = Some(200);
        assert!(usage.eligible(false, 100));
        assert!(!usage.liftable(100));
        usage.five_hour = Some(0.95);
        assert!(!usage.eligible(true, 100));
        usage.five_hour_resets = Some(99);
        assert!(usage.eligible(false, 100));
        usage.seven_day = Some(0.95);
        assert_eq!(usage.held(true, 100), Some(Hold::Week(0.95, Some(200))));
        assert!(usage.eligible(false, 201));
        usage.full_until = Some(300);
        assert!(!usage.eligible(true, 201));
        assert!(usage.eligible(true, 300));
    }

    #[test]
    fn a_window_past_its_reset_starts_over() {
        let usage = week(0.9, 1000);
        assert_eq!(usage.seven_day_at(999), Some(0.9));
        assert_eq!(usage.seven_day_at(1000), Some(0.0));
        assert!(!usage.in_reserve(1000));
        assert_eq!(usage.room_per_day(1000), Some(1.0 / 7.0));
        assert_eq!(Usage::default().seven_day_at(1000), None);
    }

    #[test]
    fn pace_and_room_per_day() {
        let now = 1_000_000;
        // 33% used with 7.6% of the week gone burns 2.3× too fast (counted at least a seventh gone).
        let usage = week(0.33, now + (WEEK as f64 * 0.924) as i64);
        assert!((usage.pace(now).unwrap() - 0.33 * 7.0).abs() < 1e-9);
        assert!(usage.ahead(now));
        // 57% left with 4.8 days to go is 0.12 a day.
        let usage = week(0.43, now + (4.8 * 86_400.0) as i64);
        assert!((usage.room_per_day(now).unwrap() - 0.57 / 4.8).abs() < 1e-9);
        // ...and with 2.2 of its 7 days gone, 43% used is 1.4× its pace.
        assert!((usage.pace(now).unwrap() - 0.43 / (2.2 / 7.0)).abs() < 1e-9);
        assert!(usage.ahead(now));
        assert!(!week(0.3, now + (4.8 * 86_400.0) as i64).ahead(now));
        assert_eq!(Usage::default().pace(now), None);
    }

    #[test]
    fn the_plan_is_the_tools_report_else_the_owners_setting() {
        let home = Home::new("plans");
        let accounts = Accounts::open(&home.0);
        assert_eq!(accounts.get("a").plan(), None);
        accounts.set_plan("a", Some("  Max 20x ")).unwrap();
        assert_eq!(
            accounts.get("a").plan(),
            Some(Plan {
                name: "Max 20x".into(),
                source: PlanSource::Owner
            })
        );
        // A report without a plan keeps the owner's; one with a plan wins, and the owner's stays
        // underneath for when the tool stops saying.
        accounts.record("a", &week(0.1, i64::MAX)).unwrap();
        assert_eq!(accounts.get("a").plan().unwrap().source, PlanSource::Owner);
        let reported = Usage {
            plan: Some("pro".into()),
            owner_plan: Some("forged".into()),
            reserve_lifted_until: Some(i64::MAX),
            ..Usage::default()
        };
        accounts.record("a", &reported).unwrap();
        let kept = Accounts::open(&home.0).get("a");
        assert_eq!(
            kept.plan(),
            Some(Plan {
                name: "pro".into(),
                source: PlanSource::Tool
            })
        );
        assert_eq!(kept.owner_plan.as_deref(), Some("Max 20x"));
        assert_eq!(kept.reserve_lifted_until, None);
        for bad in ["x".repeat(41), "Max\n20x".into(), "<b>".into()] {
            let error = accounts.set_plan("a", Some(&bad)).unwrap_err();
            assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
        }
        accounts.set_plan("a", Some(" ")).unwrap();
        assert_eq!(accounts.get("a").owner_plan, None);
    }

    #[test]
    fn lifting_lasts_until_the_week_resets() {
        let home = Home::new("lift");
        let accounts = Accounts::open(&home.0);
        let resets = time::now() + 2 * 86_400;
        accounts.record("a", &week(0.82, resets)).unwrap();
        let lifted = accounts.lift("a", true).unwrap();
        assert_eq!(lifted.reserve_lifted_until, Some(resets));
        assert!(Accounts::open(&home.0).eligible("a", false));
        let restored = accounts.lift("a", false).unwrap();
        assert_eq!(restored.reserve_lifted_until, None);
        assert!(!accounts.eligible("a", false));
        // Unknown reset: a week from now.
        let until = accounts
            .lift("b", true)
            .unwrap()
            .reserve_lifted_until
            .unwrap();
        assert!((until - (time::now() + WEEK)).abs() <= 2);
    }

    #[test]
    fn a_new_job_goes_to_an_account_with_room() {
        let now = 1_000_000;
        let resets = now + 3 * 86_400;
        let reserved = candidate("personal", "claude", week(0.82, resets), 0);
        let nearly_full = candidate("work", "claude", week(0.96, resets), 0);
        let roomy = candidate("deskree", "codex", week(0.3, resets), 4);
        let route = choose(&[reserved.clone(), nearly_full.clone(), roomy], now).unwrap();
        assert_eq!(route.id, "deskree");
        assert!(
            route
                .reason
                .starts_with("most weekly room per day left (0.23/day)"),
            "{}",
            route.reason
        );
        // The most room per day wins over list order, the fewest jobs among even ones.
        let a = candidate("a", "claude", week(0.5, resets), 0);
        let b = candidate("b", "claude", week(0.2, resets), 2);
        assert_eq!(choose(&[a.clone(), b.clone()], now).unwrap().id, "b");
        let c = candidate("c", "claude", week(0.2, resets), 1);
        assert_eq!(choose(&[b.clone(), c], now).unwrap().id, "c");
        // An account near its 5-hour limit goes after one that isn't, whatever its week.
        let mut busy = b.clone();
        busy.usage.five_hour = Some(0.85);
        assert_eq!(choose(&[busy.clone(), a.clone()], now).unwrap().id, "a");
        // On pace before unknown before ahead of pace; Cursor only when nothing else can.
        let unknown = candidate("unknown", "codex", Usage::default(), 0);
        let ahead = candidate("ahead", "claude", week(0.6, now + 6 * 86_400), 0);
        assert_eq!(
            choose(&[ahead.clone(), unknown.clone(), a], now)
                .unwrap()
                .id,
            "a"
        );
        let route = choose(&[ahead.clone(), unknown.clone()], now).unwrap();
        assert_eq!(
            (route.id, route.reason.as_str()),
            (
                "unknown",
                "its usage isn't known yet; ahead is 4.2× ahead of pace"
            )
        );
        let cursor = candidate("cursor", "cursor", Usage::default(), 0);
        assert_eq!(choose(&[cursor.clone(), ahead], now).unwrap().id, "ahead");
        assert_eq!(
            choose(&[cursor], now).unwrap().reason,
            "Cursor reports no usage: fewest jobs running"
        );
        // None with room: reserves alone say so, with what the owner can do.
        assert_eq!(
            choose(&[reserved.clone(), nearly_full.clone()], now).unwrap_err(),
            "No account has room: personal is in its weekly reserve. Use it anyway from Settings › Accounts."
        );
        let mut other = reserved.clone();
        other.name = "other";
        assert!(
            choose(&[reserved, other], now)
                .unwrap_err()
                .contains("personal and other are in their weekly reserve. Use one anyway")
        );
        assert_eq!(
            choose(&[nearly_full], now).unwrap_err(),
            "No account has room: work is at 96% of its week until 1970-01-15T13:46:40Z."
        );
    }
}
