//! Routines (docs/runner-api.md, "obid only: routines (#395)"): a saved request with a schedule.
//! obid checks every minute; a routine that's due starts an ordinary job through `Jobs::create`,
//! so routing, the permission mode, the checks, the secret scan and the review are a job's, and
//! adds a turn to its conversation, with the job's card. One file per routine in `home/routines/`
//! (0600), its runs inside.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::{Path as UrlPath, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use jiff::tz::TimeZone;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::{ApiError, Shared};
use crate::events::Events;
use crate::job::{Job, RoutineMark};
use crate::jobs::{Jobs, NewJob};

/// The most routines obid keeps.
pub const MOST: usize = 20;
/// The runs each routine keeps, the latest.
const RUNS: usize = 50;
/// How far back a missed run is still caught up.
const CATCH_UP: i64 = 7 * 24 * 60 * 60;
/// How often obid looks for routines that are due.
const EVERY: Duration = Duration::from_secs(60);
/// A run acted on later than this after its time ran late: a catch-up.
const LATE: i64 = 5 * 60;
/// Failed runs in a row after which a routine is paused.
const PAUSE_AFTER: u32 = 3;
/// The days of a weekly schedule, Monday first.
const DAYS: [&str; 7] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
const DAY_NAMES: [&str; 7] = [
    "Mondays",
    "Tuesdays",
    "Wednesdays",
    "Thursdays",
    "Fridays",
    "Saturdays",
    "Sundays",
];

/// When a routine runs, in its zone's wall-clock time.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "every", rename_all = "lowercase")]
pub enum Schedule {
    Hourly { minute: u8 },
    Daily { at: String },
    Weekdays { at: String },
    Weekly { days: Vec<String>, at: String },
}

impl Schedule {
    /// Why it isn't a schedule obid runs, or nothing. Days come back in order, once each.
    pub fn checked(mut self) -> Result<Schedule, String> {
        if let Schedule::Hourly { minute } = self {
            if minute > 59 {
                return Err("minute is 0 to 59.".into());
            }
            return Ok(self);
        }
        if self.at().is_none() {
            return Err("at is a time of day, HH:MM, like 09:00.".into());
        }
        if let Schedule::Weekly { days, .. } = &mut self {
            let mut seen: Vec<String> = vec![];
            for day in days.iter() {
                let day = day.trim().to_ascii_lowercase();
                if !DAYS.contains(&day.as_str()) {
                    return Err(format!(
                        "days are mon, tue, wed, thu, fri, sat or sun, not {day}."
                    ));
                }
                if !seen.contains(&day) {
                    seen.push(day);
                }
            }
            if seen.is_empty() {
                return Err("A weekly routine runs on at least one day.".into());
            }
            seen.sort_by_key(|d| DAYS.iter().position(|x| x == d));
            *days = seen;
        }
        Ok(self)
    }

    /// The hour and minute of `at`, when it's `HH:MM`.
    fn at(&self) -> Option<(i8, i8)> {
        let at = match self {
            Schedule::Hourly { .. } => return None,
            Schedule::Daily { at } | Schedule::Weekdays { at } | Schedule::Weekly { at, .. } => at,
        };
        let (hour, minute) = at.split_once(':')?;
        if hour.len() != 2 || minute.len() != 2 {
            return None;
        }
        let (hour, minute): (i8, i8) = (hour.parse().ok()?, minute.parse().ok()?);
        ((0..24).contains(&hour) && (0..60).contains(&minute)).then_some((hour, minute))
    }

    /// Whether it runs on a day, Monday 1 to Sunday 7.
    fn on(&self, weekday: i8) -> bool {
        match self {
            Schedule::Hourly { .. } | Schedule::Daily { .. } => true,
            Schedule::Weekdays { .. } => weekday <= 5,
            Schedule::Weekly { days, .. } => days
                .iter()
                .any(|d| DAYS.iter().position(|x| x == d) == Some(weekday as usize - 1)),
        }
    }

    /// Its first time strictly after `after` (seconds since the epoch), in `zone`. A time the
    /// clocks skip runs right after the jump; one they go through twice runs the first time
    /// (jiff's `compatible`).
    pub fn next_after(&self, zone: &TimeZone, after: i64) -> Option<i64> {
        let start = jiff::Timestamp::from_second(after).ok()?;
        if let Schedule::Hourly { minute } = self {
            // ponytail: a minute at a time, at most a day and two hours of them.
            let mut t = after - after.rem_euclid(60) + 60;
            for _ in 0..26 * 60 {
                let local = jiff::Timestamp::from_second(t).ok()?.to_zoned(zone.clone());
                if local.minute() == *minute as i8 {
                    return Some(t);
                }
                t += 60;
            }
            return None;
        }
        let (hour, minute) = self.at()?;
        let mut date = start.to_zoned(zone.clone()).date();
        for _ in 0..9 {
            if self.on(date.weekday().to_monday_one_offset()) {
                let when = date
                    .at(hour, minute, 0, 0)
                    .to_zoned(zone.clone())
                    .ok()?
                    .timestamp()
                    .as_second();
                if when > after {
                    return Some(when);
                }
            }
            date = date.tomorrow().ok()?;
        }
        None
    }

    /// obid's words for it: "Weekdays at 9:00".
    pub fn words(&self) -> String {
        let at = || {
            self.at()
                .map(|(h, m)| format!("{h}:{m:02}"))
                .unwrap_or_default()
        };
        match self {
            Schedule::Hourly { minute } => format!("Every hour at :{minute:02}"),
            Schedule::Daily { .. } => format!("Every day at {}", at()),
            Schedule::Weekdays { .. } => format!("Weekdays at {}", at()),
            Schedule::Weekly { days, .. } => {
                let names: Vec<&str> = days
                    .iter()
                    .filter_map(|d| DAYS.iter().position(|x| x == d).map(|i| DAY_NAMES[i]))
                    .collect();
                let list = match names.split_last() {
                    Some((last, [])) => (*last).to_owned(),
                    Some((last, rest)) => format!("{} and {last}", rest.join(", ")),
                    None => String::new(),
                };
                format!("{list} at {}", at())
            }
        }
    }
}

/// One run: the time it was due, when obid acted on it, and what came of it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Run {
    pub scheduled: i64,
    pub at: i64,
    /// `started`, `skipped`, `missed` or `failed` (it couldn't start).
    pub outcome: String,
    pub reason: Option<String>,
    pub job: Option<String>,
    pub catch_up: bool,
    /// Its job's end once it ended: `done`, `failed`, `stopped`, `interrupted`, or `gone`.
    pub ended: Option<String>,
}

impl Run {
    fn to_json(&self) -> Value {
        json!({"scheduled": obi_protocol::time::format(self.scheduled),
               "at": obi_protocol::time::format(self.at), "outcome": self.outcome,
               "reason": self.reason, "job": self.job, "catchUp": self.catch_up,
               "ended": self.ended})
    }
}

/// A routine as obid keeps it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Routine {
    pub id: String,
    pub name: String,
    pub repo: String,
    pub kind: String,
    pub task: String,
    pub agent: String,
    pub account: String,
    pub mode: Option<String>,
    pub check: Option<String>,
    pub rounds: u32,
    pub schedule: Schedule,
    pub zone: String,
    pub enabled: bool,
    pub created: i64,
    pub created_by: String,
    pub conversation: Option<String>,
    /// The latest due time obid acted on: the next run is the first time after it.
    pub last_fire: Option<i64>,
    pub failures_in_a_row: u32,
    /// Oldest first.
    pub runs: Vec<Run>,
}

impl Routine {
    fn zone(&self) -> TimeZone {
        TimeZone::get(&self.zone).unwrap_or(TimeZone::UTC)
    }

    /// When it runs next, or none while paused.
    pub fn next_run(&self) -> Option<i64> {
        if !self.enabled {
            return None;
        }
        self.schedule
            .next_after(&self.zone(), self.last_fire.unwrap_or(self.created))
    }

    /// `at` as the routine's zone reads it: "9:00".
    fn local(&self, at: i64) -> String {
        jiff::Timestamp::from_second(at)
            .map(|t| {
                let z = t.to_zoned(self.zone());
                format!("{}:{:02}", z.hour(), z.minute())
            })
            .unwrap_or_default()
    }

    /// As `GET /v1/routines` lists it and the `routine` event sends it.
    pub fn to_json(&self) -> Value {
        json!({"id": self.id, "name": self.name, "repo": self.repo, "kind": self.kind,
               "task": self.task, "agent": self.agent, "account": self.account, "mode": self.mode,
               "check": self.check, "rounds": self.rounds, "schedule": self.schedule,
               "zone": self.zone, "when": self.schedule.words(), "enabled": self.enabled,
               "created": obi_protocol::time::format(self.created), "createdBy": self.created_by,
               "conversation": self.conversation,
               "nextRun": self.next_run().map(obi_protocol::time::format),
               "failuresInARow": self.failures_in_a_row,
               "lastRun": self.runs.last().map(Run::to_json)})
    }

    /// The job a run starts.
    pub fn job(&self, scheduled: i64, catch_up: bool) -> NewJob {
        NewJob {
            repo: self.repo.clone(),
            kind: self.kind.clone(),
            task: self.task.clone(),
            title: Some(self.name.clone()),
            request: Some(self.task.clone()),
            agent: Some(self.agent.clone()),
            account: Some(self.account.clone()),
            mode: self.mode.clone(),
            check: self.check.clone(),
            rounds: Some(self.rounds),
            conversation: self.conversation.clone(),
            routine: Some(RoutineMark {
                id: self.id.clone(),
                name: self.name.clone(),
                scheduled,
                catch_up,
            }),
            ..NewJob::default()
        }
    }

    /// Why it isn't a routine obid runs: its name, zone, schedule, and the job it would start,
    /// as `POST /v1/jobs` checks one.
    fn vet(&mut self, jobs: &Jobs) -> Result<(), String> {
        self.name = self.name.trim().to_owned();
        if self.name.is_empty()
            || self.name.chars().count() > 60
            || self.name.contains(['\n', '\r'])
        {
            return Err("name is one line of 1 to 60 characters.".into());
        }
        TimeZone::get(&self.zone)
            .map_err(|_| format!("{} isn't a time zone obid knows.", self.zone))?;
        self.schedule = self.schedule.clone().checked()?;
        for field in [&mut self.mode, &mut self.check] {
            if field.as_deref().is_some_and(|f| f.trim().is_empty()) {
                *field = None;
            }
        }
        jobs.vet(&self.job(0, false)).map_err(|refused| refused.0)
    }
}

/// A routine as `POST /v1/routines` takes it, and the `create_routine` confirm item keeps it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Draft {
    pub name: String,
    pub repo: String,
    pub task: String,
    pub schedule: Schedule,
    pub zone: String,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub check: Option<String>,
    #[serde(default)]
    pub rounds: Option<u32>,
    #[serde(default)]
    pub created_by: Option<String>,
    #[serde(default)]
    pub conversation: Option<String>,
}

/// What `PATCH /v1/routines/{id}` changes.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Change {
    pub name: Option<String>,
    pub task: Option<String>,
    pub schedule: Option<Schedule>,
    pub zone: Option<String>,
    pub enabled: Option<bool>,
    pub agent: Option<String>,
    pub account: Option<String>,
    pub mode: Option<String>,
    pub check: Option<String>,
    pub rounds: Option<u32>,
}

/// Why Run now didn't start one.
#[derive(Debug, PartialEq)]
pub enum NotRun {
    NoRoutine,
    /// Its previous run's job is still queued or running.
    Busy,
    /// The job couldn't start: why.
    Refused(String),
}

/// Every routine, kept and announced.
pub struct Routines {
    dir: PathBuf,
    kept: Mutex<BTreeMap<String, Routine>>,
    events: Events,
    /// Held from a run's busy check until its run is kept: a scheduled run and Run now never
    /// both start. ponytail: one lock for every routine; per routine if runs ever queue on it.
    firing: Mutex<()>,
    /// What runs a run the owner confirmed (`create_routine`'s sibling `change_routine`, from the
    /// inbox, which has no conversations of its own).
    shared: std::sync::OnceLock<std::sync::Weak<Shared>>,
}

impl Routines {
    /// The routines in `home/routines`, made if it isn't there (0700).
    pub fn open(home: &Path, events: Events) -> Routines {
        let dir = home.join("routines");
        if let Err(e) = crate::store::make_private_dir(&dir) {
            tracing::warn!("can't make {}: {e}", dir.display());
        }
        let kept = crate::store::load_dir::<Routine>(&dir)
            .into_iter()
            .map(|r| (r.id.clone(), r))
            .collect();
        Routines {
            dir,
            kept: Mutex::new(kept),
            events,
            firing: Mutex::new(()),
            shared: std::sync::OnceLock::new(),
        }
    }

    /// Lets [`Routines::run`] reach the conversations and the jobs.
    pub fn attach(&self, shared: &Arc<Shared>) {
        let _ = self.shared.set(Arc::downgrade(shared));
    }

    /// Run now, from the owner's Confirm in the inbox: as `POST /v1/routines/{id}/run`.
    pub fn run(&self, id: &str, now: i64) -> Result<(Routine, Job), NotRun> {
        let shared = self
            .shared
            .get()
            .and_then(std::sync::Weak::upgrade)
            .ok_or_else(|| NotRun::Refused("obid is stopping.".into()))?;
        run_now(&shared, id, now)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, Routine>> {
        self.kept.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Writes it and says so. A routine that can't be written stays as it was on disk; the one in
    /// memory runs on, so a full disk never runs a routine twice in a minute.
    fn save(&self, routine: &Routine) {
        let path = self.dir.join(format!("{}.json", routine.id));
        let written = serde_json::to_vec_pretty(routine)
            .map_err(std::io::Error::other)
            .and_then(|bytes| crate::store::write_private(&path, &bytes));
        if let Err(e) = written {
            tracing::error!("can't keep routine {}: {e}", routine.id);
        }
        self.events.send("routine", routine.to_json());
    }

    /// Every routine, by name.
    pub fn list(&self) -> Vec<Routine> {
        let mut list: Vec<Routine> = self.lock().values().cloned().collect();
        list.sort_by_key(|r| r.name.to_lowercase());
        list
    }

    pub fn get(&self, id: &str) -> Option<Routine> {
        self.lock().get(id).cloned()
    }

    /// The routine `draft` makes, checked, not kept: what `create` would save.
    pub fn draft(&self, jobs: &Jobs, draft: Draft, now: i64) -> Result<Routine, String> {
        let mut routine = Routine {
            id: hex_id(),
            name: draft.name,
            repo: draft.repo,
            kind: draft.kind.unwrap_or_else(|| "investigate".into()),
            task: draft.task,
            agent: draft.agent.unwrap_or_else(|| "auto".into()),
            account: draft.account.unwrap_or_else(|| "auto".into()),
            mode: draft.mode,
            check: draft.check,
            rounds: draft.rounds.unwrap_or(1),
            schedule: draft.schedule,
            zone: draft.zone,
            enabled: true,
            created: now,
            created_by: match draft.created_by.as_deref() {
                Some(by @ ("chat" | "mac" | "iphone")) => by.to_owned(),
                _ => "app".into(),
            },
            conversation: draft.conversation,
            last_fire: None,
            failures_in_a_row: 0,
            runs: vec![],
        };
        routine.vet(jobs)?;
        Ok(routine)
    }

    /// Makes and keeps the routine `draft` says: `POST /v1/routines`, or the owner's Confirm.
    pub fn create(&self, jobs: &Jobs, draft: Draft, now: i64) -> Result<Routine, String> {
        let routine = self.draft(jobs, draft, now)?;
        let mut kept = self.lock();
        if kept.len() >= MOST {
            return Err(format!(
                "obid keeps at most {MOST} routines: delete one first."
            ));
        }
        kept.insert(routine.id.clone(), routine.clone());
        drop(kept);
        self.save(&routine);
        Ok(routine)
    }

    /// `PATCH`: the routine with `change`, checked, or none when there's no such one. Resuming it,
    /// or a new schedule or zone, counts from `now`.
    pub fn change(
        &self,
        jobs: &Jobs,
        id: &str,
        change: Change,
        now: i64,
    ) -> Option<Result<Routine, String>> {
        let mut kept = self.lock();
        let routine = match self.changed(&kept, jobs, id, change, now)? {
            Ok(routine) => routine,
            Err(why) => return Some(Err(why)),
        };
        kept.insert(routine.id.clone(), routine.clone());
        drop(kept);
        self.save(&routine);
        Some(Ok(routine))
    }

    /// What `change` would make of the routine `id`, checked, not kept.
    pub fn check_change(
        &self,
        jobs: &Jobs,
        id: &str,
        change: Change,
        now: i64,
    ) -> Option<Result<Routine, String>> {
        self.changed(&self.lock(), jobs, id, change, now)
    }

    fn changed(
        &self,
        kept: &BTreeMap<String, Routine>,
        jobs: &Jobs,
        id: &str,
        change: Change,
        now: i64,
    ) -> Option<Result<Routine, String>> {
        let mut routine = kept.get(id)?.clone();
        let restarts = change.schedule.is_some()
            || change.zone.is_some()
            || (change.enabled == Some(true) && !routine.enabled);
        if let Some(name) = change.name {
            routine.name = name;
        }
        if let Some(task) = change.task {
            routine.task = task;
        }
        if let Some(schedule) = change.schedule {
            routine.schedule = schedule;
        }
        if let Some(zone) = change.zone {
            routine.zone = zone;
        }
        if let Some(enabled) = change.enabled {
            routine.enabled = enabled;
            if enabled {
                routine.failures_in_a_row = 0;
            }
        }
        if let Some(agent) = change.agent {
            routine.agent = agent;
        }
        if let Some(account) = change.account {
            routine.account = account;
        }
        if let Some(mode) = change.mode {
            routine.mode = Some(mode);
        }
        if let Some(check) = change.check {
            routine.check = Some(check);
        }
        if let Some(rounds) = change.rounds {
            routine.rounds = rounds;
        }
        if let Err(why) = routine.vet(jobs) {
            return Some(Err(why));
        }
        if restarts {
            routine.last_fire = Some(now);
        }
        Some(Ok(routine))
    }

    /// Forgets it; whether it was there. The jobs its runs started stay.
    pub fn delete(&self, id: &str) -> bool {
        if self.lock().remove(id).is_none() {
            return false;
        }
        if let Err(e) = std::fs::remove_file(self.dir.join(format!("{id}.json"))) {
            tracing::warn!("can't remove routine {id}'s file: {e}");
        }
        self.events
            .send("routine", json!({"id": id, "deleted": true}));
        true
    }

    /// The routine `id` with what `change` does, kept.
    fn update(&self, id: &str, change: impl FnOnce(&mut Routine)) -> Option<Routine> {
        let mut kept = self.lock();
        let routine = kept.get_mut(id)?;
        change(routine);
        let routine = routine.clone();
        drop(kept);
        self.save(&routine);
        Some(routine)
    }

    /// `run` added to the routine `id`, kept to the last [`RUNS`], with whatever `also` changes.
    fn record(&self, id: &str, run: Run, also: impl FnOnce(&mut Routine)) -> Option<Routine> {
        let mut kept = self.lock();
        let routine = kept.get_mut(id)?;
        routine.runs.push(run);
        let excess = routine.runs.len().saturating_sub(RUNS);
        routine.runs.drain(..excess);
        also(routine);
        let routine = routine.clone();
        drop(kept);
        self.save(&routine);
        Some(routine)
    }
}

/// Eight lower-case hex characters.
fn hex_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..8].to_owned()
}

/// What's due for a routine at one check.
#[derive(Debug, PartialEq)]
enum Due {
    Nothing,
    /// Run for `scheduled`, its latest time; `missed` says what was missed before it: the first
    /// time, how many in the last 7 days, and whether older ones were too.
    Run {
        scheduled: i64,
        catch_up: bool,
        missed: Option<(i64, usize, bool)>,
    },
}

/// What's due for `routine` at `now`, from its last fire (or when it was made). Every schedule
/// runs at least weekly, so times older than [`CATCH_UP`] always come with a newer one: they're
/// counted as missed, never run.
fn due(routine: &Routine, now: i64) -> Due {
    let zone = routine.zone();
    // A clock set back leaves no time in the future to wait for.
    let from = routine.last_fire.unwrap_or(routine.created).min(now);
    let Some(first) = routine
        .schedule
        .next_after(&zone, from)
        .filter(|t| *t <= now)
    else {
        return Due::Nothing;
    };
    let older = first <= now - CATCH_UP;
    let mut times = vec![];
    let mut next = if older {
        routine.schedule.next_after(&zone, now - CATCH_UP)
    } else {
        Some(first)
    };
    // ponytail: every time in the last 7 days, at most 24 × 7 of them for an hourly routine.
    while let Some(t) = next.filter(|t| *t <= now && times.len() <= 24 * 8) {
        times.push(t);
        next = routine.schedule.next_after(&zone, t);
    }
    let Some(&scheduled) = times.last() else {
        return Due::Nothing;
    };
    let earlier = times.len() - 1;
    Due::Run {
        scheduled,
        catch_up: earlier > 0 || older || now - scheduled > LATE,
        missed: (earlier > 0 || older).then_some((first, earlier, older)),
    }
}

/// Starts the job of a run of `routine` due at `scheduled`, unless its previous run is still
/// going: the run's record, and the job when one started.
fn fire(
    shared: &Shared,
    routine: &Routine,
    scheduled: i64,
    catch_up: bool,
    now: i64,
) -> (Run, Option<String>) {
    let mut run = Run {
        scheduled,
        at: now,
        outcome: "started".into(),
        reason: None,
        job: None,
        catch_up,
        ended: None,
    };
    let busy = routine
        .runs
        .iter()
        .rev()
        .find_map(|r| r.job.as_deref())
        .is_some_and(|id| shared.jobs.get(id).is_some_and(|j| j.status.is_active()));
    if busy {
        run.outcome = "skipped".into();
        run.reason = Some("The previous run was still going.".into());
        return (run, routine.conversation.clone());
    }
    let mut routine = routine.clone();
    // Where the run shows up: its conversation, or a new one when it has none or it's gone.
    if !routine
        .conversation
        .as_deref()
        .is_some_and(|c| shared.conversations.has(c))
    {
        routine.conversation = shared.conversations.start_for(&routine.name).ok();
    }
    match shared.jobs.create(routine.job(scheduled, catch_up)) {
        Ok(job) => run.job = Some(job.id),
        Err(refused) => {
            run.outcome = "failed".into();
            run.reason = Some(refused.0);
        }
    }
    (run, routine.conversation)
}

/// The turn a run adds to its routine's conversation, in obid's own words.
fn say(shared: &Shared, routine: &Routine, run: &Run, text: String) {
    let Some(conversation) = routine.conversation.as_deref() else {
        return;
    };
    let mark = json!({"id": routine.id, "name": routine.name, "outcome": run.outcome,
                      "scheduled": obi_protocol::time::format(run.scheduled), "catchUp": run.catch_up});
    let jobs = run.job.iter().cloned().collect();
    if let Err(e) = shared
        .conversations
        .routine_turn(conversation, text, jobs, mark)
    {
        tracing::warn!(
            "routine {} couldn't tell its conversation: {e:?}",
            routine.id
        );
    }
}

/// What a run says in the conversation.
fn words(routine: &Routine, run: &Run, now_asked: bool) -> String {
    let name = &routine.name;
    let time = routine.local(run.scheduled);
    let why = run.reason.as_deref().unwrap_or("");
    match run.outcome.as_str() {
        "started" if now_asked => format!("{name} started a run now, as you asked."),
        "started" if run.catch_up => {
            format!("{name} started its {time} run, which it missed while Oby wasn't running.")
        }
        "started" => format!("{name} started its {time} run."),
        "skipped" => format!("{name} skipped its {time} run: {}", lower_first(why)),
        "missed" => format!("{name} {}", lower_first(why)),
        _ => format!("{name} couldn't start its {time} run: {why}"),
    }
}

fn lower_first(text: &str) -> String {
    let mut chars = text.chars();
    chars
        .next()
        .map(|c| c.to_lowercase().chain(chars).collect())
        .unwrap_or_default()
}

/// One check of every routine at `now`: the jobs of runs that ended are read (3 failures in a
/// row pause it), then each routine that's due runs, once, for its latest time.
pub fn tick(shared: &Shared, now: i64) {
    let routines = &shared.routines;
    // Taken apart from the loop: a guard in its head would be held through it.
    let ids: Vec<String> = routines.lock().keys().cloned().collect();
    for id in ids {
        ended(shared, &id);
        let Some(mut routine) = routines.get(&id).filter(|r| r.enabled) else {
            continue;
        };
        // The clock went back past the time it last acted on: it counts from now.
        if routine.last_fire.is_some_and(|t| t > now) {
            match routines.update(&id, |r| r.last_fire = Some(now)) {
                Some(clamped) => routine = clamped,
                None => continue,
            }
        }
        let Due::Run {
            scheduled,
            catch_up,
            missed,
        } = due(&routine, now)
        else {
            continue;
        };
        let missed_run = missed.map(|(first, count, older)| Run {
            scheduled: first,
            at: now,
            outcome: "missed".into(),
            reason: Some(match (count, older) {
                (_, true) => {
                    "Missed runs while Oby wasn't running, some more than 7 days ago.".into()
                }
                (1, false) => "Missed 1 run while Oby wasn't running.".into(),
                (n, false) => format!("Missed {n} runs while Oby wasn't running."),
            }),
            job: None,
            catch_up: false,
            ended: None,
        });
        // The time it acts on is kept before the job starts: never twice for one time.
        let kept = match &missed_run {
            Some(run) => routines.record(&id, run.clone(), |r| r.last_fire = Some(scheduled)),
            None => routines.update(&id, |r| r.last_fire = Some(scheduled)),
        };
        let Some(routine) = kept else {
            continue;
        };
        if let Some(run) = &missed_run {
            say(shared, &routine, run, words(&routine, run, false));
        }
        let _ = fire_kept(shared, &id, scheduled, catch_up, now, false);
    }
}

/// Keeps a run that just happened, with the conversation `fire` gave it, and says it.
fn finish(
    shared: &Shared,
    id: &str,
    run: Run,
    conversation: Option<String>,
    now_asked: bool,
) -> Option<Routine> {
    let failed = run.outcome == "failed";
    let routine = shared.routines.record(id, run.clone(), |r| {
        if conversation.is_some() {
            r.conversation = conversation;
        }
        if failed {
            r.failures_in_a_row += 1;
        }
    })?;
    say(shared, &routine, &run, words(&routine, &run, now_asked));
    if failed {
        pause_if_failing(shared, &routine);
    }
    Some(routine)
}

/// Reads the end of each run's job that ended since the last check, oldest first.
fn ended(shared: &Shared, id: &str) {
    let routines = &shared.routines;
    let mut kept = routines.lock();
    let Some(routine) = kept.get_mut(id) else {
        return;
    };
    let mut changed = false;
    for run in routine.runs.iter_mut().filter(|r| r.ended.is_none()) {
        let Some(job) = run.job.as_deref() else {
            continue;
        };
        let end = match shared.jobs.get(job) {
            Some(job) if job.status.is_active() => continue,
            Some(job) => job.status.as_str(),
            None => "gone",
        };
        run.ended = Some(end.to_owned());
        match end {
            "failed" => routine.failures_in_a_row += 1,
            "done" => routine.failures_in_a_row = 0,
            _ => {}
        }
        changed = true;
    }
    if !changed {
        return;
    }
    let routine = routine.clone();
    drop(kept);
    routines.save(&routine);
    pause_if_failing(shared, &routine);
}

/// After [`PAUSE_AFTER`] failures in a row, the routine is paused and its conversation told.
fn pause_if_failing(shared: &Shared, routine: &Routine) {
    if !routine.enabled || routine.failures_in_a_row < PAUSE_AFTER {
        return;
    }
    let Some(routine) = shared.routines.update(&routine.id, |r| r.enabled = false) else {
        return;
    };
    if let Some(conversation) = routine.conversation.as_deref() {
        let mark = json!({"id": routine.id, "name": routine.name, "outcome": "paused",
                          "scheduled": null, "catchUp": false});
        let text = format!(
            "{} failed {PAUSE_AFTER} times in a row, so it's paused. Turn it back on in Settings › Routines.",
            routine.name
        );
        if let Err(e) = shared
            .conversations
            .routine_turn(conversation, text, vec![], mark)
        {
            tracing::warn!(
                "routine {} couldn't tell its conversation: {e:?}",
                routine.id
            );
        }
    }
}

/// Run now: a run for `now`, paused or not, that leaves its next time as it was.
pub fn run_now(shared: &Shared, id: &str, now: i64) -> Result<(Routine, Job), NotRun> {
    ended(shared, id);
    let (run, routine) = fire_kept(shared, id, now, false, now, true).ok_or(NotRun::NoRoutine)?;
    if run.outcome == "skipped" {
        return Err(NotRun::Busy);
    }
    let routine = routine.ok_or(NotRun::NoRoutine)?;
    let job = run.job.as_deref().and_then(|j| shared.jobs.get(j));
    job.map(|job| (routine, job))
        .ok_or_else(|| NotRun::Refused(run.reason.unwrap_or_default()))
}

/// A run of the routine `id` started and kept under the firing lock, from its busy check to its
/// record, so a scheduled run and Run now never both start. Run now's skip isn't kept: the owner
/// hears it instead. None when there's no such routine.
fn fire_kept(
    shared: &Shared,
    id: &str,
    scheduled: i64,
    catch_up: bool,
    now: i64,
    now_asked: bool,
) -> Option<(Run, Option<Routine>)> {
    let _firing = shared
        .routines
        .firing
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let routine = shared.routines.get(id)?;
    let (run, conversation) = fire(shared, &routine, scheduled, catch_up, now);
    if now_asked && run.outcome == "skipped" {
        return Some((run, None));
    }
    let kept = finish(shared, id, run.clone(), conversation, now_asked);
    Some((run, kept))
}

/// Checks every routine once now, then every minute, until obid stops.
pub fn spawn(shared: Arc<Shared>) {
    let mut stopping = shared.stopping.clone();
    tokio::spawn(async move {
        loop {
            let tick_shared = shared.clone();
            let _ =
                tokio::task::spawn_blocking(move || tick(&tick_shared, obi_protocol::time::now()))
                    .await;
            // The owner's check-in, on the same minute (#1116). ponytail: its one background
            // call holds the next routine check up to its timeout, once a summary or a stretch
            // away at most.
            crate::brain::recap::check_in(&shared, obi_protocol::time::now()).await;
            tokio::select! {
                () = tokio::time::sleep(EVERY) => {}
                _ = stopping.changed() => {
                    if *stopping.borrow() {
                        return;
                    }
                }
            }
        }
    });
}

fn answer(status: StatusCode, value: Value) -> Response {
    (status, axum::Json(value)).into_response()
}

fn unprocessable(why: impl Into<String>) -> ApiError {
    ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, why)
}

const NO_ROUTINE: &str = "There's no such routine.";

/// `GET /v1/routines`.
pub async fn list(State(shared): State<Arc<Shared>>) -> Response {
    let list: Vec<Value> = shared
        .routines
        .list()
        .iter()
        .map(Routine::to_json)
        .collect();
    answer(StatusCode::OK, Value::Array(list))
}

/// `POST /v1/routines`.
pub async fn create(State(shared): State<Arc<Shared>>, body: Bytes) -> Result<Response, ApiError> {
    let mut draft: Draft = serde_json::from_slice(&body).map_err(|e| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            format!("That isn't a routine: {e}"),
        )
    })?;
    // Only the owner's Confirm of what the brain planned makes a chat routine.
    draft.created_by = draft.created_by.filter(|by| by != "chat");
    if let Some(conversation) = &draft.conversation
        && !shared.conversations.has(conversation)
    {
        return Err(unprocessable("There's no such conversation."));
    }
    let routine = shared
        .routines
        .create(&shared.jobs, draft, obi_protocol::time::now())
        .map_err(unprocessable)?;
    Ok(answer(StatusCode::CREATED, routine.to_json()))
}

/// `GET /v1/routines/{id}`: the routine with its runs, newest first.
pub async fn get(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    let routine = shared
        .routines
        .get(&id)
        .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, NO_ROUTINE))?;
    let mut value = routine.to_json();
    value["runs"] = routine.runs.iter().rev().map(Run::to_json).collect();
    Ok(answer(StatusCode::OK, value))
}

/// `PATCH /v1/routines/{id}`.
pub async fn change(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let change: Change = serde_json::from_slice(&body).map_err(|e| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            format!("That isn't a change to a routine: {e}"),
        )
    })?;
    match shared
        .routines
        .change(&shared.jobs, &id, change, obi_protocol::time::now())
    {
        None => Err(ApiError::new(StatusCode::NOT_FOUND, NO_ROUTINE)),
        Some(Err(why)) => Err(unprocessable(why)),
        Some(Ok(routine)) => Ok(answer(StatusCode::OK, routine.to_json())),
    }
}

/// `DELETE /v1/routines/{id}`.
pub async fn delete(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    if shared.routines.delete(&id) {
        Ok(StatusCode::NO_CONTENT.into_response())
    } else {
        Err(ApiError::new(StatusCode::NOT_FOUND, NO_ROUTINE))
    }
}

/// `POST /v1/routines/{id}/run`.
pub async fn run(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    // Off the async threads: a run takes the firing lock and starts its job.
    let ran = tokio::task::spawn_blocking(move || run_now(&shared, &id, obi_protocol::time::now()))
        .await
        .map_err(|_| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "The run stopped."))?;
    match ran {
        Ok((routine, job)) => Ok(answer(
            StatusCode::CREATED,
            json!({"routine": routine.to_json(), "job": job.to_json()}),
        )),
        Err(NotRun::NoRoutine) => Err(ApiError::new(StatusCode::NOT_FOUND, NO_ROUTINE)),
        Err(NotRun::Busy) => Err(ApiError::new(
            StatusCode::CONFLICT,
            "Its previous run is still going.",
        )),
        Err(NotRun::Refused(why)) => Err(unprocessable(why)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(text: &str) -> i64 {
        obi_protocol::time::parse(text).unwrap()
    }

    fn zone(name: &str) -> TimeZone {
        TimeZone::get(name).unwrap()
    }

    fn daily(time: &str) -> Schedule {
        Schedule::Daily { at: time.into() }
    }

    fn times(schedule: &Schedule, zone: &TimeZone, from: &str, count: usize) -> Vec<String> {
        let mut t = at(from);
        (0..count)
            .map(|_| {
                t = schedule.next_after(zone, t).unwrap();
                obi_protocol::time::format(t)
            })
            .collect()
    }

    #[test]
    fn daily_fires_once_per_local_date_across_dst() {
        let ny = zone("America/New_York");
        // 9:00 in New York is 14:00Z before the spring change (EST) and 13:00Z after (EDT).
        assert_eq!(
            times(&daily("09:00"), &ny, "2026-03-07T00:00:00Z", 3),
            [
                "2026-03-07T14:00:00Z",
                "2026-03-08T13:00:00Z",
                "2026-03-09T13:00:00Z"
            ]
        );
        assert_eq!(
            times(&daily("09:00"), &ny, "2026-10-31T00:00:00Z", 3),
            [
                "2026-10-31T13:00:00Z",
                "2026-11-01T14:00:00Z",
                "2026-11-02T14:00:00Z"
            ]
        );
    }

    #[test]
    fn skipped_local_time_runs_once_after_the_jump() {
        let ny = zone("America/New_York");
        // 02:30 doesn't exist on 2026-03-08 in New York: it runs once, after the jump, then at
        // 02:30 again the next day.
        assert_eq!(
            times(&daily("02:30"), &ny, "2026-03-08T00:00:00Z", 2),
            ["2026-03-08T07:30:00Z", "2026-03-09T06:30:00Z"]
        );
    }

    #[test]
    fn repeated_local_time_runs_once() {
        let ny = zone("America/New_York");
        // 01:30 happens twice on 2026-11-01: once, the first time (EDT, 05:30Z).
        assert_eq!(
            times(&daily("01:30"), &ny, "2026-11-01T00:00:00Z", 2),
            ["2026-11-01T05:30:00Z", "2026-11-02T06:30:00Z"]
        );
    }

    #[test]
    fn weekdays_skip_the_weekend_and_weekly_takes_its_days() {
        let sp = zone("America/Sao_Paulo");
        // 2026-10-16 is a Friday; São Paulo is UTC-3.
        assert_eq!(
            times(
                &Schedule::Weekdays { at: "09:00".into() },
                &sp,
                "2026-10-16T13:00:00Z",
                2
            ),
            ["2026-10-19T12:00:00Z", "2026-10-20T12:00:00Z"]
        );
        let weekly = Schedule::Weekly {
            days: vec!["thu".into(), "mon".into()],
            at: "08:30".into(),
        }
        .checked()
        .unwrap();
        assert_eq!(weekly.words(), "Mondays and Thursdays at 8:30");
        assert_eq!(
            times(&weekly, &sp, "2026-10-19T12:00:00Z", 2),
            ["2026-10-22T11:30:00Z", "2026-10-26T11:30:00Z"]
        );
    }

    #[test]
    fn hourly_runs_at_its_local_minute() {
        // India is UTC+5:30: :15 local is :45 UTC.
        let india = zone("Asia/Kolkata");
        assert_eq!(
            times(
                &Schedule::Hourly { minute: 15 },
                &india,
                "2026-10-19T00:00:00Z",
                2
            ),
            ["2026-10-19T00:45:00Z", "2026-10-19T01:45:00Z"]
        );
        assert_eq!(Schedule::Hourly { minute: 5 }.words(), "Every hour at :05");
    }

    #[test]
    fn bad_schedules_are_refused() {
        for schedule in [
            Schedule::Hourly { minute: 60 },
            daily("9:00"),
            daily("24:00"),
            daily("09:60"),
            Schedule::Weekly {
                days: vec![],
                at: "09:00".into(),
            },
            Schedule::Weekly {
                days: vec!["funday".into()],
                at: "09:00".into(),
            },
        ] {
            assert!(schedule.clone().checked().is_err(), "{schedule:?}");
        }
        let parsed: Schedule =
            serde_json::from_value(json!({"every": "weekdays", "at": "09:00"})).unwrap();
        assert_eq!(parsed.words(), "Weekdays at 9:00");
    }

    fn routine(schedule: Schedule, created: &str) -> Routine {
        Routine {
            id: "a1b2c3d4".into(),
            name: "Review open PRs".into(),
            repo: "o/r".into(),
            kind: "review".into(),
            task: "Review them.".into(),
            agent: "auto".into(),
            account: "auto".into(),
            mode: None,
            check: None,
            rounds: 1,
            schedule,
            zone: "UTC".into(),
            enabled: true,
            created: at(created),
            created_by: "mac".into(),
            conversation: None,
            last_fire: None,
            failures_in_a_row: 0,
            runs: vec![],
        }
    }

    #[test]
    fn missed_runs_catch_up_once_for_the_latest() {
        let mut r = routine(daily("09:00"), "2026-10-10T00:00:00Z");
        r.last_fire = Some(at("2026-10-15T09:00:00Z"));
        // Down from the 15th's run to the 18th at noon: the 16th, 17th and 18th were due.
        assert_eq!(
            due(&r, at("2026-10-18T12:00:00Z")),
            Due::Run {
                scheduled: at("2026-10-18T09:00:00Z"),
                catch_up: true,
                missed: Some((at("2026-10-16T09:00:00Z"), 2, false)),
            }
        );
        // On time: no catch-up, nothing missed; and once fired, nothing more that minute.
        assert_eq!(
            due(&r, at("2026-10-16T09:00:30Z")),
            Due::Run {
                scheduled: at("2026-10-16T09:00:00Z"),
                catch_up: false,
                missed: None,
            }
        );
        r.last_fire = Some(at("2026-10-16T09:00:00Z"));
        assert_eq!(due(&r, at("2026-10-16T09:00:50Z")), Due::Nothing);
    }

    #[test]
    fn a_last_run_in_the_future_waits_for_nothing() {
        // The clock jumped ahead, then back: the time it acted on is ahead of now.
        let mut r = routine(daily("09:00"), "2026-10-10T00:00:00Z");
        r.last_fire = Some(at("2026-10-25T09:00:00Z"));
        // Nothing runs for the times it seems to have done already, and nothing waits for them:
        // the check sets it to now (tick), and the next time runs.
        assert_eq!(due(&r, at("2026-10-18T09:00:30Z")), Due::Nothing);
        r.last_fire = Some(at("2026-10-18T09:00:30Z"));
        assert_eq!(
            due(&r, at("2026-10-19T09:00:30Z")),
            Due::Run {
                scheduled: at("2026-10-19T09:00:00Z"),
                catch_up: false,
                missed: None,
            }
        );
    }

    #[test]
    fn older_than_seven_days_is_missed_never_run() {
        // A daily routine down 30 days runs once, for the latest, and the rest are missed: 6 in
        // the last 7 days, and older ones.
        let mut r = routine(daily("09:00"), "2026-09-01T00:00:00Z");
        r.last_fire = Some(at("2026-09-10T09:00:00Z"));
        assert_eq!(
            due(&r, at("2026-10-10T12:00:00Z")),
            Due::Run {
                scheduled: at("2026-10-10T09:00:00Z"),
                catch_up: true,
                missed: Some((at("2026-09-11T09:00:00Z"), 6, true)),
            }
        );
    }

    #[test]
    fn a_paused_routine_has_no_next_run() {
        let mut r = routine(daily("09:00"), "2026-10-10T00:00:00Z");
        assert_eq!(r.next_run(), Some(at("2026-10-10T09:00:00Z")));
        r.enabled = false;
        assert_eq!(r.next_run(), None);
        assert_eq!(r.to_json()["nextRun"], Value::Null);
        assert_eq!(r.to_json()["when"], "Every day at 9:00");
    }
}
