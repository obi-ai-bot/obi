//! Sharing rules and per-sender limits (docs/runner-api.md, "obid only: sharing rules"; spec
//! `protocol.md` section 11, "Questions" and "Rate limits"): what the owner lets their Obi tell
//! some people without being asked, and how much each sender's owner can make it do. Only the
//! owner changes them, through the runner API; nothing another Obi sends can. Kept in
//! `home/sharing.json` (0600).

use std::path::{Path, PathBuf};

use obi_protocol::time;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::store;

/// What a rule may let the Obi tell. The spec's third, published pull requests as the code host
/// shows them, needs the code host: obid offers the two it holds itself (a job's status names
/// the pull request it opened).
pub const TELLS: [&str; 2] = [JOB_STATUS, SHARED_RESULTS];
/// The title, stage and state of the owner's jobs, and the pull request each opened.
pub const JOB_STATUS: &str = "jobStatus";
/// What obid already sent that person's Obis: the results of reviews they asked for.
pub const SHARED_RESULTS: &str = "sharedResults";

/// The most rules obid keeps.
pub const MAX_RULES: usize = 100;

/// Who a rule is for, or which repositories it covers: a list, or every one (`*`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Scope {
    Every(String),
    These(Vec<String>),
}

impl Scope {
    fn every() -> Scope {
        Scope::Every("*".into())
    }

    fn is_every(&self) -> bool {
        matches!(self, Scope::Every(_))
    }

    /// Whether it names `owner` exactly, or is every one.
    fn has_owner(&self, owner: &str) -> bool {
        match self {
            Scope::Every(_) => true,
            Scope::These(list) => list.iter().any(|o| o == owner),
        }
    }

    /// Whether it covers `repo`, ignoring ASCII case, or is every one.
    pub fn has_repo(&self, repo: &str) -> bool {
        match self {
            Scope::Every(_) => true,
            Scope::These(list) => list.iter().any(|r| r.eq_ignore_ascii_case(repo)),
        }
    }

    fn to_json(&self) -> Value {
        match self {
            Scope::Every(_) => json!("*"),
            Scope::These(list) => json!(list),
        }
    }
}

/// One sharing rule.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rule {
    /// `s-` and 12 lower-case hex: a `rule_id` the spec allows in `answer.by_rule`.
    pub id: String,
    /// Owners from the Sphere's directory, or every member (`*`).
    #[serde(rename = "for")]
    pub for_owners: Scope,
    pub repos: Scope,
    /// What it lets the Obi tell: some of [`TELLS`].
    pub tells: Vec<String>,
    pub created: i64,
    /// Answers the Obi sent under it.
    pub uses: u64,
    pub last_used: Option<i64>,
}

impl Rule {
    /// Whether it is for `owner` and covers each of `repos` (none: only a rule for every
    /// repository covers a question about no repository).
    pub fn covers(&self, owner: &str, repos: &[String]) -> bool {
        self.for_owners.has_owner(owner)
            && if repos.is_empty() {
                self.repos.is_every()
            } else {
                repos.iter().all(|r| self.repos.has_repo(r))
            }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "for": self.for_owners.to_json(),
            "repos": self.repos.to_json(),
            "tells": self.tells,
            "created": time::format(self.created),
            "uses": self.uses,
            "lastUsed": self.last_used.map(time::format),
        })
    }
}

/// How much each sender's owner, and every sender together, can make the Obi do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Limits {
    /// Questions an hour from one sender's owner the Obi takes on to answer by itself (a model run
    /// on the owner's account).
    pub self_answers_per_hour: u32,
    /// The same, from every sender together: what all of them can spend of the owner's account.
    pub self_answers_per_hour_total: u32,
    /// Requests of every type waiting in the owner's inbox at once.
    pub inbox_per_owner: u32,
}

impl Default for Limits {
    /// The spec's recommended defaults.
    fn default() -> Limits {
        Limits {
            self_answers_per_hour: 30,
            self_answers_per_hour_total: 60,
            inbox_per_owner: 5,
        }
    }
}

impl Limits {
    pub fn to_json(self) -> Value {
        json!({"selfAnswersPerHour": self.self_answers_per_hour,
               "selfAnswersPerHourTotal": self.self_answers_per_hour_total,
               "inboxPerOwner": self.inbox_per_owner})
    }
}

/// Whether teammates' jobs may run on this Mac, and how (#797; docs/runner-api.md, "obid only:
/// sharing this Mac"). Off until the owner turns it on; the rest are the defaults the owner
/// accepted on 2026-10-20.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Mac {
    pub on: bool,
    /// `away` (no input for 10 minutes) and/or `schedule` (nights and weekends).
    pub when: Vec<String>,
    /// `ask` (everyone, asking the owner the first time for each person), `everyone`, or
    /// `people` (only `people`).
    pub who: String,
    pub people: Vec<String>,
    /// The owners the owner said "Allow … from now on" to.
    pub allowed: Vec<String>,
    pub jobs_at_once: u8,
    /// `small` (4 cores, 8 GB, 30 GB) or `large` (6, 12, 60).
    pub size: String,
    /// `any` job in the organisation's repositories, or `reviews` and checks only.
    pub work: String,
    pub max_minutes: u32,
}

impl Default for Mac {
    fn default() -> Mac {
        Mac {
            on: false,
            when: vec!["away".into()],
            who: "ask".into(),
            people: Vec::new(),
            allowed: Vec::new(),
            jobs_at_once: 1,
            size: "small".into(),
            work: "any".into(),
            max_minutes: 120,
        }
    }
}

impl Mac {
    pub fn to_json(&self) -> Value {
        serde_json::to_value(self).unwrap_or_default()
    }

    /// Whether a job from `owner`'s Obi may run without asking: the owner said so for everyone, or
    /// for that person once.
    pub fn allows_without_asking(&self, owner: &str) -> bool {
        match self.who.as_str() {
            "everyone" => true,
            "people" => self.people.iter().any(|p| p == owner),
            _ => self.allowed.iter().any(|p| p == owner),
        }
    }

    /// Whether `owner` may ask at all.
    pub fn offered_to(&self, owner: &str) -> bool {
        self.who != "people" || self.people.iter().any(|p| p == owner)
    }
}

fn is_owner(text: &str) -> bool {
    obi_protocol::schema::is_valid("common#/$defs/owner_id", &json!(text))
}

/// The Mac's settings from `PUT /v1/obid/sharing/mac`: exactly these keys, each checked.
pub fn mac_from(body: &Value) -> Result<Mac, String> {
    const KEYS: [&str; 9] = [
        "on",
        "when",
        "who",
        "people",
        "allowed",
        "jobsAtOnce",
        "size",
        "work",
        "maxMinutes",
    ];
    let map = body.as_object().ok_or("The body is a JSON object.")?;
    if let Some(k) = map.keys().find(|k| !KEYS.contains(&k.as_str())) {
        return Err(format!("{k} isn't a setting of this Mac's sharing."));
    }
    if let Some(k) = KEYS.iter().find(|k| !map.contains_key(**k)) {
        return Err(format!("{k} is required."));
    }
    let owners = |key: &str| -> Result<Vec<String>, String> {
        let list = body[key]
            .as_array()
            .ok_or(format!("{key} is a list of owners."))?;
        let names: Vec<String> = list
            .iter()
            .filter_map(|v| v.as_str().filter(|s| is_owner(s)).map(str::to_owned))
            .collect();
        if names.len() != list.len() || list.len() > 50 {
            return Err(format!(
                "{key} is a list of at most 50 owners from the directory."
            ));
        }
        Ok(names)
    };
    let when: Vec<String> = body["when"]
        .as_array()
        .ok_or("when is a list.")?
        .iter()
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect();
    if when.is_empty() || when.iter().any(|w| w != "away" && w != "schedule") || when.len() > 2 {
        return Err("when is away, schedule, or both.".into());
    }
    let who = body["who"]
        .as_str()
        .filter(|w| ["ask", "everyone", "people"].contains(w))
        .ok_or("who is ask, everyone or people.")?;
    let jobs = body["jobsAtOnce"]
        .as_u64()
        .filter(|n| (1..=3).contains(n))
        .ok_or("jobsAtOnce is 1 to 3.")?;
    let size = body["size"]
        .as_str()
        .filter(|s| *s == "small" || *s == "large")
        .ok_or("size is small or large.")?;
    let work = body["work"]
        .as_str()
        .filter(|s| *s == "any" || *s == "reviews")
        .ok_or("work is any or reviews.")?;
    let minutes = body["maxMinutes"]
        .as_u64()
        .filter(|n| (5..=480).contains(n))
        .ok_or("maxMinutes is 5 to 480.")?;
    Ok(Mac {
        on: body["on"].as_bool().ok_or("on is true or false.")?,
        when,
        who: who.into(),
        people: owners("people")?,
        allowed: owners("allowed")?,
        jobs_at_once: jobs as u8,
        size: size.into(),
        work: work.into(),
        max_minutes: minutes as u32,
    })
}

/// The rules and the limits, as kept, and this Mac's sharing.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sharing {
    #[serde(default)]
    pub rules: Vec<Rule>,
    #[serde(default)]
    pub limits: Limits,
    #[serde(default)]
    pub mac: Mac,
    /// Shares of the owner's company API accounts (#809, [`super::shares`]).
    #[serde(default)]
    pub grants: Vec<super::shares::Grant>,
}

impl Sharing {
    pub fn to_json(&self) -> Value {
        json!({
            "rules": self.rules.iter().map(Rule::to_json).collect::<Vec<_>>(),
            "limits": self.limits.to_json(),
        })
    }

    /// The one rule an answer by the Obi would be made under, for a question from an Obi of
    /// `owner` about `repos` (none: a question about no repository): the oldest rule for that
    /// owner that covers every one of them. A question about no repository only a rule for every
    /// repository covers.
    pub fn covering(&self, owner: &str, repos: &[String]) -> Option<&Rule> {
        self.rules.iter().find(|rule| rule.covers(owner, repos))
    }
}

/// A new rule id: `s-` and 12 lower-case hex.
pub fn new_id() -> String {
    let mut bytes = [0u8; 6];
    getrandom::fill(&mut bytes).expect("the system's random source works");
    format!("s-{}", hex::encode(bytes))
}

/// `"*"` or a list of 1 to 50 distinct values, each passing `valid`.
fn scope(
    map: &Map<String, Value>,
    key: &str,
    what: &str,
    valid: impl Fn(&str) -> bool,
) -> Result<Scope, String> {
    let shape = format!("{key} is \"*\" or a list of 1 to 50 {what}.");
    match map.get(key) {
        Some(Value::String(s)) if s == "*" => Ok(Scope::every()),
        Some(Value::Array(list)) if (1..=50).contains(&list.len()) => {
            let mut out: Vec<String> = Vec::new();
            for item in list {
                let text = item.as_str().ok_or_else(|| shape.clone())?;
                if !valid(text) {
                    return Err(format!("{text:?} isn't one of the {what}."));
                }
                if !out.iter().any(|o| o.eq_ignore_ascii_case(text)) {
                    out.push(text.to_owned());
                }
            }
            Ok(Scope::These(out))
        }
        _ => Err(shape),
    }
}

/// A new rule from the body of `POST /v1/obid/sharing/rules`: `for`, `repos` and `tells`, nothing
/// else (`Err` says why not).
pub fn rule_from(body: &Value, now: i64) -> Result<Rule, String> {
    let map = body.as_object().ok_or("The body is a JSON object.")?;
    if let Some(unknown) = map
        .keys()
        .find(|k| !["for", "repos", "tells"].contains(&k.as_str()))
    {
        return Err(format!("{unknown} isn't a field this endpoint takes."));
    }
    let owner = |t: &str| obi_protocol::schema::is_valid("common#/$defs/owner_id", &json!(t));
    let repo = |t: &str| obi_protocol::schema::is_valid("common#/$defs/repo", &json!(t));
    let for_owners = scope(map, "for", "owners", owner)?;
    let repos = scope(map, "repos", "repositories (owner/name)", repo)?;
    let tells: Vec<String> = match map.get("tells") {
        Some(Value::Array(list)) if !list.is_empty() => list
            .iter()
            .map(|t| {
                t.as_str()
                    .filter(|t| TELLS.contains(t))
                    .map(str::to_owned)
                    .ok_or_else(|| format!("tells lists some of {}.", TELLS.join(", ")))
            })
            .collect::<Result<_, _>>()?,
        _ => return Err(format!("tells lists some of {}.", TELLS.join(", "))),
    };
    let mut distinct = tells.clone();
    distinct.sort();
    distinct.dedup();
    if distinct.len() != tells.len() {
        return Err("tells names each at most once.".into());
    }
    Ok(Rule {
        id: new_id(),
        for_owners,
        repos,
        tells,
        created: now,
        uses: 0,
        last_used: None,
    })
}

/// New limits from the body of `PUT /v1/obid/sharing/limits` (`Err` says why not).
pub fn limits_from(body: &Value) -> Result<Limits, String> {
    let map = body.as_object().ok_or("The body is a JSON object.")?;
    let shape = "The body is {\"selfAnswersPerHour\": 0 to 1,000, \"selfAnswersPerHourTotal\": 0 to 10,000, \"inboxPerOwner\": 0 to 100}.";
    if map.len() != 3 {
        return Err(shape.into());
    }
    let number = |key: &str, max: u64| {
        map.get(key)
            .and_then(Value::as_u64)
            .filter(|n| *n <= max)
            .and_then(|n| u32::try_from(n).ok())
            .ok_or(shape)
    };
    Ok(Limits {
        self_answers_per_hour: number("selfAnswersPerHour", 1000)?,
        self_answers_per_hour_total: number("selfAnswersPerHourTotal", 10_000)?,
        inbox_per_owner: number("inboxPerOwner", 100)?,
    })
}

/// Where they are kept.
pub struct Kept {
    path: PathBuf,
}

impl Kept {
    pub fn open(home: &Path) -> Kept {
        Kept {
            path: home.join("sharing.json"),
        }
    }

    /// The rules and limits kept, or none and the defaults. A file that doesn't read shares
    /// nothing.
    pub fn load(&self) -> Sharing {
        match std::fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                tracing::error!(
                    "{} doesn't read, so nothing is shared: {e}",
                    self.path.display()
                );
                Sharing::default()
            }),
            Err(_) => Sharing::default(),
        }
    }

    pub fn save(&self, sharing: &Sharing) -> std::io::Result<()> {
        let text = serde_json::to_vec_pretty(sharing).map_err(std::io::Error::other)?;
        store::write_private(&self.path, &text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(body: Value) -> Rule {
        rule_from(&body, 0).unwrap()
    }

    #[test]
    fn rules_cover_their_owners_and_every_repository_asked_about() {
        let sharing = Sharing {
            rules: vec![
                rule(json!({"for": ["ernesto"], "repos": ["Acme/App"], "tells": ["jobStatus"]})),
                rule(json!({"for": "*", "repos": "*", "tells": ["sharedResults"]})),
            ],
            limits: Limits::default(),
            ..Sharing::default()
        };
        let repos = |list: &[&str]| list.iter().map(|r| (*r).to_owned()).collect::<Vec<_>>();
        let first = &sharing.rules[0].id;
        let second = &sharing.rules[1].id;
        assert_eq!(
            &sharing
                .covering("ernesto", &repos(&["acme/app"]))
                .unwrap()
                .id,
            first
        );
        // Another repository too: only the rule for every repository covers both.
        assert_eq!(
            &sharing
                .covering("ernesto", &repos(&["acme/app", "acme/web"]))
                .unwrap()
                .id,
            second
        );
        // A question about nothing: only a rule for every repository.
        assert_eq!(&sharing.covering("ernesto", &[]).unwrap().id, second);
        assert_eq!(
            &sharing
                .covering("giulia", &repos(&["acme/app"]))
                .unwrap()
                .id,
            second
        );
        let narrow = Sharing {
            rules: vec![sharing.rules[0].clone()],
            limits: Limits::default(),
            ..Sharing::default()
        };
        assert!(narrow.covering("ernesto", &[]).is_none());
        assert!(narrow.covering("giulia", &repos(&["acme/app"])).is_none());
    }

    #[test]
    fn a_rule_takes_only_what_it_may_be() {
        for (body, why) in [
            (
                json!({"for": "ernesto", "repos": "*", "tells": ["jobStatus"]}),
                "for",
            ),
            (
                json!({"for": ["Ernesto Smith"], "repos": "*", "tells": ["jobStatus"]}),
                "owner",
            ),
            (
                json!({"for": "*", "repos": ["not a repo"], "tells": ["jobStatus"]}),
                "repo",
            ),
            (
                json!({"for": "*", "repos": "*", "tells": ["files"]}),
                "tells",
            ),
            (json!({"for": "*", "repos": "*", "tells": []}), "no tells"),
            (
                json!({"for": "*", "repos": "*", "tells": ["jobStatus", "jobStatus"]}),
                "twice",
            ),
            (
                json!({"for": "*", "repos": "*", "tells": ["jobStatus"], "prompt": "x"}),
                "field",
            ),
            (
                json!({"for": [], "repos": "*", "tells": ["jobStatus"]}),
                "empty",
            ),
        ] {
            assert!(rule_from(&body, 0).is_err(), "{why}");
        }
        let made =
            rule(json!({"for": ["ernesto", "ernesto"], "repos": "*", "tells": ["jobStatus"]}));
        assert_eq!(made.for_owners, Scope::These(vec!["ernesto".into()]));
        assert!(made.id.starts_with("s-") && made.id.len() == 14);
        assert!(obi_protocol::schema::is_valid(
            "common#/$defs/rule_id",
            &json!(made.id)
        ));
        let shown = made.to_json();
        assert_eq!(shown["repos"], "*");
        assert_eq!(shown["for"], json!(["ernesto"]));
    }

    #[test]
    fn this_macs_sharing_is_off_by_default_and_takes_only_what_it_may_be() {
        let mac = Mac::default();
        assert!(!mac.on);
        assert_eq!(
            (
                mac.when.clone(),
                mac.who.as_str(),
                mac.jobs_at_once,
                mac.size.as_str(),
                mac.max_minutes
            ),
            (vec!["away".to_owned()], "ask", 1, "small", 120)
        );
        let mut body = mac.to_json();
        body["on"] = json!(true);
        assert!(mac_from(&body).unwrap().on);
        for (key, bad) in [
            ("when", json!(["always"])),
            ("who", json!("anyone")),
            ("jobsAtOnce", json!(4)),
            ("size", json!("huge")),
            ("maxMinutes", json!(481)),
            ("people", json!(["Not A Slug"])),
        ] {
            let mut wrong = body.clone();
            wrong[key] = bad;
            assert!(mac_from(&wrong).is_err(), "{key}");
        }
        let mut extra = body.clone();
        extra["away"] = json!(true);
        assert!(mac_from(&extra).is_err());
        // Asking first: allowed once by name, from then on.
        let mut ask = Mac {
            on: true,
            ..Mac::default()
        };
        assert!(!ask.allows_without_asking("sangam"));
        ask.allowed.push("sangam".into());
        assert!(ask.allows_without_asking("sangam") && ask.offered_to("ernesto"));
        let people = Mac {
            who: "people".into(),
            people: vec!["sangam".into()],
            ..Mac::default()
        };
        assert!(people.offered_to("sangam") && !people.offered_to("ernesto"));
    }

    #[test]
    fn limits_and_their_defaults() {
        assert_eq!(
            Limits::default().to_json(),
            json!({"selfAnswersPerHour": 30, "selfAnswersPerHourTotal": 60, "inboxPerOwner": 5})
        );
        assert_eq!(
            limits_from(
                &json!({"selfAnswersPerHour": 0, "selfAnswersPerHourTotal": 10000, "inboxPerOwner": 100})
            )
            .unwrap(),
            Limits {
                self_answers_per_hour: 0,
                self_answers_per_hour_total: 10_000,
                inbox_per_owner: 100
            }
        );
        for bad in [
            json!({"selfAnswersPerHour": 1001, "selfAnswersPerHourTotal": 1, "inboxPerOwner": 1}),
            json!({"selfAnswersPerHour": 1, "selfAnswersPerHourTotal": 10001, "inboxPerOwner": 1}),
            json!({"selfAnswersPerHour": 1, "selfAnswersPerHourTotal": 1, "inboxPerOwner": 101}),
            json!({"selfAnswersPerHour": 1.5, "selfAnswersPerHourTotal": 1, "inboxPerOwner": 1}),
            json!({"selfAnswersPerHour": 1, "inboxPerOwner": 1}),
            json!({"selfAnswersPerHour": 1, "inboxPerOwner": 1, "other": 1}),
        ] {
            assert!(limits_from(&bad).is_err(), "{bad}");
        }
        // A file from before the overall cap keeps its limits and gets the cap's default.
        let kept: Sharing = serde_json::from_value(json!({"rules": []})).unwrap();
        assert_eq!(kept.limits, Limits::default());
        let older: Sharing = serde_json::from_value(
            json!({"rules": [], "limits": {"selfAnswersPerHour": 3, "inboxPerOwner": 2}}),
        )
        .unwrap();
        assert_eq!(older.limits.self_answers_per_hour, 3);
        assert_eq!(older.limits.self_answers_per_hour_total, 60);
    }
}
