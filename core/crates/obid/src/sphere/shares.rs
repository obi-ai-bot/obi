//! Sharing a company-paid API account (#798, #809; spec protocol.md section 16; docs/runner-api.md,
//! "obid only: sharing your usage"). The owner gives a teammate a share of the month's budget of
//! an API key they keep in Oby's vault (`anthropic-api-key`). The teammate's jobs on it run on
//! this Mac, in a VM ([`super::hosting`]), and obid adds the key to their model calls here, outside
//! the VM: the key never leaves this Mac. obid meters each call at list price from its response's
//! usage, and the owner's own jobs on the account count against the same month.
//!
//! Only Anthropic API keys are shared so far: OpenAI's per-token prices aren't in obid yet, and
//! Cursor's team balance and Codex workspace credits have no per-key API to meter. A personal plan
//! or a seat is never shared.

use std::collections::BTreeMap;

use obi_protocol::time;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The least a share must have left for a job to start on it: a job's first calls cost about this.
// ponytail: a fixed estimate; a per-kind estimate from past jobs' costs when shares run out mid-job.
pub const START_AT_LEAST_MICROS: u64 = 500_000;
/// How often a share's status goes to its teammate when nothing else made it go.
pub const STATUS_EVERY: i64 = 3_600;

/// One share of an API account, kept in `home/sharing.json` with the sharing rules. Only the
/// owner changes it, through the runner API; nothing another Obi sends can.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Grant {
    /// `g-` and 12 lower-case hex: the spec's `grant`.
    pub id: String,
    /// `claude`: the CLI whose API the key pays for.
    pub agent: String,
    /// The account's name as the owner calls it ("Deskree API").
    pub label: String,
    /// The owner's own Oby account that uses the same key: its jobs' cost counts here too.
    #[serde(default)]
    pub account: Option<String>,
    /// `nobody`, `everyone` (each member gets the share), or one owner id.
    pub who: String,
    /// Percent of the month's budget, 10 to 100.
    pub share: u8,
    /// Added to `share` for this period only ("Share 20% more this month").
    #[serde(default)]
    pub extra: u8,
    pub budget_cents: u64,
    /// The day of the month the budget starts again, 1 to 28 (UTC).
    pub resets_day: u8,
    /// The start of the period `used` counts.
    #[serde(default)]
    pub period: i64,
    /// Micro-dollars used this period, by owner id (the key holder's own jobs under their id).
    #[serde(default)]
    pub used: BTreeMap<String, u64>,
    #[serde(default)]
    pub created: i64,
}

impl Grant {
    /// The vault secret this share's key is kept under: one per account the owner shares
    /// (`anthropic-api-key.<account>`), or `anthropic-api-key` for one with no account.
    pub fn key_name(&self) -> String {
        let Some(account) = &self.account else {
            return "anthropic-api-key".into();
        };
        let safe: String = account
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') {
                    c
                } else {
                    '-'
                }
            })
            .collect();
        format!("anthropic-api-key.{safe}")
            .chars()
            .take(64)
            .collect()
    }

    /// Starts the meter again when a new period began; whether it did.
    pub fn roll(&mut self, now: i64) -> bool {
        let (start, _) = period(now, self.resets_day);
        if self.period == start {
            return false;
        }
        self.period = start;
        self.used.clear();
        self.extra = 0;
        true
    }

    pub fn resets(&self, now: i64) -> i64 {
        period(now, self.resets_day).1
    }

    /// The most one teammate may use this period, in micro-dollars.
    pub fn limit_micros(&self) -> u64 {
        self.budget_cents * 10_000 * u64::from((self.share + self.extra).min(100)) / 100
    }

    /// What `owner` may still use: their share's rest, and never past the month's budget.
    pub fn left_for(&self, owner: &str) -> u64 {
        let all: u64 = self.used.values().sum();
        let mine = self.used.get(owner).copied().unwrap_or(0);
        self.limit_micros()
            .saturating_sub(mine)
            .min((self.budget_cents * 10_000).saturating_sub(all))
    }

    pub fn offered_to(&self, owner: &str) -> bool {
        self.who == "everyone" || self.who == owner
    }

    /// The share as the spec's `share_offer` has it.
    pub fn offer(&self, now: i64) -> Value {
        json!({"grant": self.id, "agent": self.agent, "account": self.label, "share": (self.share + self.extra).min(100),
               "limit_cents": self.limit_micros() / 10_000, "period": "month", "resets": time::format(self.resets(now))})
    }

    /// `owner`'s `share_status`.
    pub fn status(&self, owner: &str, now: i64) -> Value {
        json!({"grant": self.id, "used_cents": cents(self.used.get(owner).copied().unwrap_or(0)),
               "limit_cents": self.limit_micros() / 10_000, "resets": time::format(self.resets(now))})
    }

    pub fn to_json(&self, now: i64) -> Value {
        json!({
            "id": self.id, "agent": self.agent, "label": self.label, "account": self.account, "who": self.who,
            "share": self.share, "extra": self.extra, "budgetCents": self.budget_cents, "resetsDay": self.resets_day,
            "resets": time::format(self.resets(now)), "limitCents": self.limit_micros() / 10_000,
            "usedCents": self.used.iter().map(|(who, m)| (who.clone(), json!(cents(*m)))).collect::<serde_json::Map<_, _>>(),
            "created": time::format(self.created), "keyName": self.key_name(),
        })
    }
}

/// Micro-dollars as whole cents, rounded up: a share is never shown as less used than it is.
pub fn cents(micros: u64) -> u64 {
    micros.div_ceil(10_000)
}

/// A new grant id: `g-` and 12 lower-case hex.
pub fn new_id() -> String {
    let mut bytes = [0u8; 6];
    getrandom::fill(&mut bytes).expect("the system's random source works");
    format!("g-{}", hex::encode(bytes))
}

/// A grant from `PUT /v1/obid/sharing/grants`: exactly these keys, each checked. `id` names one to
/// change (its meter kept); without it a new one starts.
pub fn grant_from(body: &Value, kept: Option<&Grant>, now: i64) -> Result<Grant, String> {
    const KEYS: [&str; 8] = [
        "id",
        "agent",
        "label",
        "account",
        "who",
        "share",
        "budgetCents",
        "resetsDay",
    ];
    let map = body.as_object().ok_or("The body is a JSON object.")?;
    if let Some(k) = map.keys().find(|k| !KEYS.contains(&k.as_str())) {
        return Err(format!("{k} isn't a field of a share."));
    }
    if body["agent"] != "claude" {
        return Err("agent is claude: obid meters Anthropic API keys only, so far.".into());
    }
    let label = body["label"]
        .as_str()
        .map(str::trim)
        .filter(|l| (1..=100).contains(&l.chars().count()) && !l.contains(['\n', '\r']))
        .ok_or("label is the account's name, one line of 1 to 100 characters.")?;
    let who = body["who"]
        .as_str()
        .filter(|w| {
            *w == "nobody"
                || *w == "everyone"
                || obi_protocol::schema::is_valid("common#/$defs/owner_id", &json!(w))
        })
        .ok_or("who is nobody, everyone, or one owner from the directory.")?;
    let share = body["share"]
        .as_u64()
        .filter(|s| (10..=100).contains(s))
        .ok_or("share is 10 to 100 (percent).")?;
    let budget = body["budgetCents"]
        .as_u64()
        .filter(|b| (100..=100_000_000).contains(b))
        .ok_or("budgetCents is the month's budget in cents, $1 to $1,000,000.")?;
    let day = body["resetsDay"]
        .as_u64()
        .filter(|d| (1..=28).contains(d))
        .ok_or("resetsDay is the day of the month it resets, 1 to 28.")?;
    let account = match &body["account"] {
        Value::Null => None,
        Value::String(a) if !a.is_empty() && a.len() <= 200 => Some(a.clone()),
        _ => return Err("account is the id of your own Oby account on this key, or null.".into()),
    };
    let mut grant = Grant {
        id: kept.map_or_else(new_id, |k| k.id.clone()),
        agent: "claude".into(),
        label: label.into(),
        account,
        who: who.into(),
        share: share as u8,
        extra: kept.map_or(0, |k| k.extra),
        budget_cents: budget,
        resets_day: day as u8,
        period: kept.map_or(0, |k| k.period),
        used: kept.map(|k| k.used.clone()).unwrap_or_default(),
        created: kept.map_or(now, |k| k.created),
    };
    grant.roll(now);
    Ok(grant)
}

// ---------------------------------------------------------------------------------------------
// Periods

/// Days since 1970-01-01 as (year, month, day) (Howard Hinnant's `civil_from_days`).
fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

/// (year, month, day) as days since 1970-01-01 (`days_from_civil`).
fn days(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The period `now` is in, for a budget that starts again on `day` of each month, at 00:00 UTC:
/// its start and the next one's.
// ponytail: UTC; the owner's own time zone when someone's month turns at the wrong hour.
pub fn period(now: i64, day: u8) -> (i64, i64) {
    let day = i64::from(day.clamp(1, 28));
    let (y, m, d) = civil(now.div_euclid(86_400));
    let (sy, sm) = if d >= day {
        (y, m)
    } else if m == 1 {
        (y - 1, 12)
    } else {
        (y, m - 1)
    };
    let (ny, nm) = if sm == 12 { (sy + 1, 1) } else { (sy, sm + 1) };
    (days(sy, sm, day) * 86_400, days(ny, nm, day) * 86_400)
}

// ---------------------------------------------------------------------------------------------
// List prices and the meter

/// Anthropic's list prices in US dollars per million tokens: input, output, cache read. A 5-minute
/// cache write is 1.25 × input, a 1-hour one 2 ×. Claude API list prices of 2026-10-06 (a cache
/// read at a tenth of input where they name none); a model that isn't here isn't called on a share
/// (obid couldn't meter it).
// ponytail: a table in the code; read prices from Anthropic's Models API when it publishes them.
const PRICES: [(&str, f64, f64, f64); 12] = [
    ("claude-fable-5-1", 10.0, 50.0, 0.25),
    ("claude-fable-5", 10.0, 50.0, 1.0),
    ("claude-opus-5-5", 4.0, 20.0, 0.20),
    ("claude-opus-5", 5.0, 25.0, 0.50),
    ("claude-opus-4-8", 5.0, 25.0, 0.50),
    ("claude-opus-4-7", 5.0, 25.0, 0.50),
    ("claude-opus-4-6", 5.0, 25.0, 0.50),
    ("claude-sonnet-5-5", 2.0, 10.0, 0.20),
    ("claude-sonnet-5", 2.0, 10.0, 0.20),
    ("claude-sonnet-4-6", 3.0, 15.0, 0.30),
    ("claude-haiku-5-5", 0.10, 0.50, 0.01),
    ("claude-haiku-4-5", 1.0, 5.0, 0.10),
];
/// Claude Haiku 5.5 costs more past 100K tokens of prompt.
const HAIKU_LONG: (f64, f64, f64) = (0.50, 2.50, 0.05);
/// A web search through the API: $10 per 1,000.
const SEARCH_MICROS: u64 = 10_000;

/// The prices for `model` as Claude Code names it (an id, maybe with a suffix like `[1m]` or a
/// date): the longest id it starts with.
pub fn prices(model: &str) -> Option<(f64, f64, f64)> {
    PRICES
        .iter()
        .filter(|(id, ..)| model.starts_with(id))
        .max_by_key(|(id, ..)| id.len())
        .map(|(_, i, o, r)| (*i, *o, *r))
}

/// One call's usage as its response says it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Usage {
    pub model: String,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write_5m: u64,
    pub cache_write_1h: u64,
    pub searches: u64,
    pub fast: bool,
}

impl Usage {
    /// Takes in a response's `usage` (a whole answer's, or a stream event's: the most each field
    /// reached counts, since a stream's counts are cumulative).
    fn take(&mut self, usage: &Value) {
        let n = |v: &Value| v.as_u64().unwrap_or(0);
        self.input = self.input.max(n(&usage["input_tokens"]));
        self.output = self.output.max(n(&usage["output_tokens"]));
        self.cache_read = self.cache_read.max(n(&usage["cache_read_input_tokens"]));
        let split = &usage["cache_creation"];
        if split.is_object() {
            self.cache_write_5m = self
                .cache_write_5m
                .max(n(&split["ephemeral_5m_input_tokens"]));
            self.cache_write_1h = self
                .cache_write_1h
                .max(n(&split["ephemeral_1h_input_tokens"]));
        } else {
            self.cache_write_5m = self
                .cache_write_5m
                .max(n(&usage["cache_creation_input_tokens"]));
        }
        self.searches = self
            .searches
            .max(n(&usage["server_tool_use"]["web_search_requests"]));
        self.fast |= usage["speed"] == "fast";
    }

    /// What it cost at list price, in micro-dollars, rounded up; none for a model obid can't price.
    pub fn micros(&self) -> Option<u64> {
        let (mut i, mut o, mut r) = prices(&self.model)?;
        let prompt = self.input + self.cache_read + self.cache_write_5m + self.cache_write_1h;
        if self.model.starts_with("claude-haiku-5-5") && prompt > 100_000 {
            (i, o, r) = HAIKU_LONG;
        }
        let speed = if self.fast { 2.0 } else { 1.0 };
        // Dollars per million tokens times tokens is micro-dollars.
        let tokens = self.input as f64 * i
            + self.output as f64 * o
            + self.cache_read as f64 * r
            + self.cache_write_5m as f64 * i * 1.25
            + self.cache_write_1h as f64 * i * 2.0;
        Some((tokens * speed).ceil() as u64 + self.searches * SEARCH_MICROS)
    }
}

/// The server tools a call on a share may use: web search, which its usage reports and obid
/// prices. Any other (web fetch, code execution, an MCP server, a container's skills) costs what
/// obid can't meter, so the call is refused. Tools the agent runs itself cost only tokens.
const CLIENT_TOOL_TYPES: [&str; 5] = ["custom", "bash_", "text_editor_", "computer_", "memory_"];

/// Why a call on a share can't be metered, or none.
pub fn unmeterable(body: &Value) -> Option<String> {
    if body.get("mcp_servers").is_some() || body.get("container").is_some() {
        return Some("MCP servers and containers can't be metered on a share".into());
    }
    for tool in body["tools"].as_array().into_iter().flatten() {
        let kind = tool["type"].as_str().unwrap_or("custom");
        if !kind.starts_with("web_search_")
            && !CLIENT_TOOL_TYPES.iter().any(|t| kind.starts_with(t))
        {
            return Some(format!(
                "the server tool {kind} can't be metered on a share"
            ));
        }
    }
    None
}

/// The most a call can cost, in micro-dollars: every byte of the request as a token written to a
/// 1-hour cache (the dearest input), all its `max_tokens` as output, and every web search it allows
/// (20 when it doesn't say). None when the model has no price or the call says no `max_tokens`.
pub fn worst(model: &str, body: &Value, bytes: usize) -> Option<u64> {
    let searches = body["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|t| {
            t["type"]
                .as_str()
                .is_some_and(|k| k.starts_with("web_search_"))
        })
        .map(|t| t["max_uses"].as_u64().unwrap_or(20))
        .sum();
    Usage {
        model: model.into(),
        cache_write_1h: bytes as u64,
        output: body["max_tokens"].as_u64()?,
        searches,
        fast: body["speed"] == "fast",
        ..Usage::default()
    }
    .micros()
}

/// Reads a model answer as it streams by, for its usage: server-sent events (`data: {…}` lines) or
/// one JSON body. It never changes what passes.
#[derive(Default)]
pub struct Meter {
    partial: Vec<u8>,
    whole: Vec<u8>,
    pub usage: Usage,
    /// Whether the answer said its usage at all.
    reported: bool,
}

/// The most of a non-streamed answer the meter keeps to read its usage.
const MAX_WHOLE: usize = 32 * 1024 * 1024;

impl Meter {
    pub fn new(model: &str) -> Meter {
        Meter {
            usage: Usage {
                model: model.into(),
                ..Usage::default()
            },
            ..Meter::default()
        }
    }

    pub fn feed(&mut self, chunk: &[u8]) {
        if self.whole.len() + chunk.len() <= MAX_WHOLE {
            self.whole.extend_from_slice(chunk);
        }
        self.partial.extend_from_slice(chunk);
        while let Some(at) = self.partial.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.partial.drain(..=at).collect();
            if let Some(data) = line.strip_prefix(b"data:")
                && let Ok(event) = serde_json::from_slice::<Value>(data.trim_ascii())
            {
                self.event(&event);
            }
        }
    }

    fn event(&mut self, event: &Value) {
        let message = &event["message"];
        if let Some(model) = message["model"].as_str() {
            self.usage.model = model.into();
        }
        self.reported |= message["usage"].is_object() || event["usage"].is_object();
        self.usage.take(&message["usage"]);
        self.usage.take(&event["usage"]);
    }

    /// The usage once the answer ended, or none when it never said.
    pub fn finish(mut self) -> Option<Usage> {
        if let Ok(answer) = serde_json::from_slice::<Value>(&self.whole) {
            if let Some(model) = answer["model"].as_str() {
                self.usage.model = model.into();
            }
            self.reported |= answer["usage"].is_object();
            self.usage.take(&answer["usage"]);
        }
        self.reported.then_some(self.usage)
    }
}

// ---------------------------------------------------------------------------------------------
// The teammate's side

/// The shares teammates gave this owner, from the `share_offer` exchanges that haven't ended: the
/// offer as its last `share_status` left it.
pub fn shared_with_me(exchanges: &[super::exchange::Exchange]) -> Vec<Value> {
    exchanges
        .iter()
        .filter(|e| e.kind == "share_offer" && e.direction == "incoming" && !e.ended())
        .map(|e| {
            let offer = &e.request["body"];
            let status = e
                .messages
                .iter()
                .rev()
                .map(|m| &m.envelope)
                .find(|m| m["type"] == "share_status")
                .map(|m| &m["body"]);
            let pick = |k: &str| status.map_or(&offer[k], |s| &s[k]).clone();
            json!({"grant": offer["grant"], "from": e.peer, "owner": e.peer_owner, "agent": offer["agent"],
                   "account": offer["account"], "share": offer["share"], "limitCents": pick("limit_cents"),
                   "usedCents": status.map_or(json!(0), |s| s["used_cents"].clone()), "resets": pick("resets")})
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grant() -> Grant {
        grant_from(
            &json!({"agent": "claude", "label": "Deskree API", "account": null, "who": "sangam",
                    "share": 30, "budgetCents": 40_000, "resetsDay": 1}),
            None,
            time::parse("2026-10-21T16:00:00Z").unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn each_accounts_share_has_its_own_key_in_the_vault() {
        let mut g = grant();
        assert_eq!(g.key_name(), "anthropic-api-key");
        g.account = Some("deskree".into());
        assert_eq!(g.key_name(), "anthropic-api-key.deskree");
        g.account = Some("a b/c".into());
        assert_eq!(g.key_name(), "anthropic-api-key.a-b-c");
        g.account = Some("x".repeat(100));
        assert_eq!(g.key_name().len(), 64);
        assert!(crate::vault::name_problem(&g.key_name()).is_none());
    }

    #[test]
    fn a_share_of_30_percent_of_400_dollars_stops_sangam_at_120() {
        let mut g = grant();
        assert_eq!(g.limit_micros(), 120_000_000);
        assert!(g.offered_to("sangam") && !g.offered_to("dima"));
        g.used.insert("sangam".into(), 119_000_000);
        assert_eq!(g.left_for("sangam"), 1_000_000);
        g.used.insert("sangam".into(), 120_000_001);
        assert_eq!(g.left_for("sangam"), 0);
        // The owner's own jobs count against the same month: the budget is never passed.
        g.used.insert("sangam".into(), 0);
        g.used.insert("wellington".into(), 390_000_000);
        assert_eq!(g.left_for("sangam"), 10_000_000);
        // 20% more this month, then a new month starts again.
        g.extra = 20;
        assert_eq!(g.offer(0)["share"], 50);
        assert!(g.roll(time::parse("2026-11-01T00:00:01Z").unwrap()));
        assert!(g.used.is_empty() && g.extra == 0);
    }

    #[test]
    fn a_calls_worst_case_and_what_cant_be_metered() {
        let body = json!({"model": "claude-opus-5-5", "max_tokens": 1000, "tools": [{"type": "web_search_20250305", "max_uses": 2}, {"name": "Read"}]});
        // 1,000 bytes at $8 (a 1-hour cache write), 1,000 output at $20, 2 searches at a cent.
        assert_eq!(
            worst("claude-opus-5-5", &body, 1000),
            Some(8000 + 20_000 + 20_000)
        );
        assert_eq!(worst("claude-opus-5-5", &json!({}), 10), None);
        assert!(unmeterable(&body).is_none());
        assert!(unmeterable(&json!({"tools": [{"type": "code_execution_20250825"}]})).is_some());
        assert!(unmeterable(&json!({"mcp_servers": []})).is_some());
        assert!(unmeterable(&json!({"tools": [{"type": "bash_20250124"}]})).is_none());
    }

    #[test]
    fn periods_turn_on_their_day() {
        let at = |t| time::parse(t).unwrap();
        let (start, next) = period(at("2026-10-21T16:00:00Z"), 1);
        assert_eq!(
            (time::format(start), time::format(next)),
            (
                "2026-10-01T00:00:00Z".to_owned(),
                "2026-11-01T00:00:00Z".to_owned()
            )
        );
        let (start, next) = period(at("2026-01-10T00:00:00Z"), 15);
        assert_eq!(
            (time::format(start), time::format(next)),
            (
                "2025-12-15T00:00:00Z".to_owned(),
                "2026-01-15T00:00:00Z".to_owned()
            )
        );
        let (start, _) = period(at("2028-02-29T12:00:00Z"), 28);
        assert_eq!(time::format(start), "2028-02-28T00:00:00Z");
    }

    #[test]
    fn a_grant_takes_only_what_it_may_be() {
        let now = 0;
        let base = json!({"agent": "claude", "label": "A", "account": null, "who": "everyone", "share": 10, "budgetCents": 100, "resetsDay": 28});
        assert!(grant_from(&base, None, now).is_ok());
        for (k, v) in [
            ("agent", json!("codex")),
            ("label", json!("two\nlines")),
            ("who", json!("Not An Owner")),
            ("share", json!(9)),
            ("share", json!(101)),
            ("budgetCents", json!(99)),
            ("resetsDay", json!(29)),
            ("key", json!("sk-no")),
        ] {
            let mut body = base.clone();
            body[k] = v;
            assert!(grant_from(&body, None, now).is_err(), "{k}");
        }
        // Changing one keeps its id and its meter.
        let mut kept = grant();
        kept.used.insert("sangam".into(), 5);
        let mut same_day = base.clone();
        same_day["resetsDay"] = json!(1);
        let changed = grant_from(
            &same_day,
            Some(&kept),
            time::parse("2026-10-22T00:00:00Z").unwrap(),
        )
        .unwrap();
        assert_eq!((changed.id, changed.used), (kept.id, kept.used));
    }

    #[test]
    fn a_streamed_answer_is_metered_at_list_price() {
        let mut meter = Meter::new("claude-opus-5-5");
        let events = [
            json!({"type": "message_start", "message": {"model": "claude-opus-5-5", "usage": {"input_tokens": 1000, "output_tokens": 1, "cache_read_input_tokens": 10_000,
                   "cache_creation_input_tokens": 2000, "cache_creation": {"ephemeral_5m_input_tokens": 1000, "ephemeral_1h_input_tokens": 1000}}}}),
            json!({"type": "content_block_delta", "delta": {"text": "hi"}}),
            json!({"type": "message_delta", "usage": {"output_tokens": 500}}),
        ];
        let text: String = events
            .iter()
            .map(|e| format!("event: x\ndata: {e}\n\n"))
            .collect();
        // Split anywhere: chunks don't keep to lines.
        for chunk in text.as_bytes().chunks(7) {
            meter.feed(chunk);
        }
        let usage = meter.finish().unwrap();
        assert_eq!(
            (usage.input, usage.output, usage.cache_read),
            (1000, 500, 10_000)
        );
        // 1000×4 + 500×20 + 10000×0.2 + 1000×4×1.25 + 1000×4×2 = 4000+10000+2000+5000+8000.
        assert_eq!(usage.micros(), Some(29_000));
    }

    #[test]
    fn a_whole_answer_and_models_obid_cant_price() {
        let mut meter = Meter::new("");
        meter.feed(
            json!({"model": "claude-sonnet-5-5[1m]", "usage": {"input_tokens": 1_000_000, "output_tokens": 0}})
                .to_string()
                .as_bytes(),
        );
        assert_eq!(meter.finish().unwrap().micros(), Some(2_000_000));
        // An answer that never says its usage.
        let mut silent = Meter::new("claude-opus-5-5");
        silent.feed(b"data: {\"type\": \"ping\"}\n\n");
        assert!(silent.finish().is_none());
        assert_eq!(prices("claude-fable-5-1-20261001").unwrap().0, 10.0);
        assert_eq!(prices("claude-fable-5").unwrap().2, 1.0);
        assert!(prices("gpt-5").is_none());
        let long = Usage {
            model: "claude-haiku-5-5".into(),
            input: 200_000,
            ..Usage::default()
        };
        assert_eq!(long.micros(), Some(100_000));
    }
}
