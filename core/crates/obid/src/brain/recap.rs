//! The recap when the owner comes back (#594): obid keeps the time of the owner's last message or
//! tap, and on the first one after more than [`AWAY`] it sums up what happened meanwhile (jobs
//! done, merged or failed, inbox items waiting, accounts that hit their limits) in one to three
//! sentences, ending with the one thing that needs the owner, if any. A background call (#537:
//! one attempt, the quick model, never Codex) writes it from a fact list obid builds itself; the
//! facts are quoted inside a nonce fence and go through the vault first. The recap goes out as a
//! `recap` event and leads the conversation's next answer; it's never a turn the user wrote.
//!
//! Check-ins (#1116, docs/runner-api.md, "obid only: check-ins"): when the owner turned them on in
//! a conversation (`oby_check_in`, kept in `settings.json`), Oby posts there by itself, as its own
//! turn: at their time, at most once a day, a summary of what happened since the owner last
//! looked; and, in the [`AWAKE`] hours after that time, the recap once per stretch away, when
//! something finished or needs the owner. Either posts only when something happened, never starts,
//! approves or answers anything, and is written from the same fenced facts, else counted in obid's
//! own words.

use std::future::Future;
use std::sync::{Arc, Mutex};

use serde_json::json;

use crate::api::Shared;
use crate::job::{Job, Status};
use crate::settings::CheckIn;
use crate::sphere::inbox::Item;

use super::actions::Talk;
use super::briefing::{fence, fence_rule, nonce};
use super::planner::{Adapter, Failure, Planner, Room};

/// How long the owner is away before their next message or tap gets a recap: 30 minutes.
pub const AWAY: i64 = 30 * 60;
/// The longest recap obid passes on: a few sentences, never a report.
pub const LONGEST: usize = 600;
/// How long after a check-in's time the away recap may post, on its days: 12 hours. The rest is
/// quiet hours, which the next summary covers.
pub const AWAKE: i64 = 12 * 60 * 60;
/// The most job cards a check-in carries.
const CARDS: usize = 10;

/// The recap's instructions: the same on every call, so the model's server can reuse them (#534).
pub const SYSTEM: &str = "You are Oby. The owner just came back after a while away. Sum up, in one to three short sentences, what happened while they were away, from the facts you're given and nothing else. Name the jobs and items by their titles. If something waits for the owner, end with that one thing, said plainly; if nothing does, say so in a few words or not at all. No greeting, no lists, no advice, no questions. Put the sentences in `recap`.";
/// A check-in's instructions (#1116): written for an owner who isn't looking, read in a notification.
pub const CHECK_IN: &str = "You are Oby. The owner turned on check-ins and isn't looking at Oby now; they'll read this in a notification. In one to three short sentences, from the facts you're given and nothing else, say what finished, then what needs the owner, then the one thing you would do next once they say so. Name the jobs and items by their titles. No greeting, no lists, no questions. Put the sentences in `recap`.";
/// What the recap call fills.
pub const SCHEMA: &str = r#"{"type":"object","properties":{"recap":{"type":"string","description":"One to three sentences."}},"required":["recap"],"additionalProperties":false}"#;

/// When the owner was last seen, when Oby last checked in by itself, and a recap written for an
/// answer that had nothing to say.
#[derive(Default)]
pub struct Presence {
    last: Mutex<Option<i64>>,
    posted: Mutex<Option<i64>>,
    held: Mutex<Option<String>>,
}

impl Presence {
    /// The owner sent a message or tapped at `now`. When they had been away more than [`AWAY`],
    /// the time they were last seen, or Oby's check-in since: the recap covers what happened
    /// after it. Kept in memory: after obid starts, the first message or tap is a first sight,
    /// with no recap.
    pub fn seen(&self, now: i64) -> Option<i64> {
        let mut last = self.last.lock().unwrap_or_else(|e| e.into_inner());
        let before = *last;
        *last = Some(before.map_or(now, |before| before.max(now)));
        let posted = *self.posted.lock().unwrap_or_else(|e| e.into_inner());
        before
            .filter(|before| now - before > AWAY)
            .map(|before| posted.map_or(before, |posted| posted.max(before)))
    }

    /// When the owner has been away more than [`AWAY`] at `now` and Oby hasn't checked in since
    /// they left: the time they were last seen. Never seen since obid started: not away.
    pub fn away(&self, now: i64) -> Option<i64> {
        let last = (*self.last.lock().unwrap_or_else(|e| e.into_inner()))?;
        let posted = *self.posted.lock().unwrap_or_else(|e| e.into_inner());
        (now - last > AWAY && posted.is_none_or(|posted| posted < last)).then_some(last)
    }

    /// Oby checked in by itself at `now`: this stretch away has had its one.
    pub fn post(&self, now: i64) {
        *self.posted.lock().unwrap_or_else(|e| e.into_inner()) = Some(now);
    }

    /// The latest of when the owner was last seen and when Oby last checked in.
    pub fn since(&self) -> Option<i64> {
        let last = *self.last.lock().unwrap_or_else(|e| e.into_inner());
        let posted = *self.posted.lock().unwrap_or_else(|e| e.into_inner());
        last.max(posted)
    }

    /// Keeps `recap` for the next answer that has words.
    pub fn hold(&self, recap: String) {
        *self.held.lock().unwrap_or_else(|e| e.into_inner()) = Some(recap);
    }

    /// The recap kept for this answer, once.
    pub fn take(&self) -> Option<String> {
        self.held.lock().unwrap_or_else(|e| e.into_inner()).take()
    }
}

/// What happened while the owner was away, as obid knows it. Each line names one thing.
#[derive(Debug, Default, PartialEq)]
pub struct Facts {
    pub waiting: Vec<String>,
    pub done: Vec<String>,
    pub merged: Vec<String>,
    pub failed: Vec<String>,
    /// Jobs that stopped part way and need the owner, their work kept (`interrupted`).
    pub needs_you: Vec<String>,
    /// The accounts a job found out of usage: `codex · deskree`.
    pub limited: Vec<String>,
    /// How many of the items waiting came in since.
    pub fresh: usize,
    /// The jobs named, by id, oldest first: the cards a check-in carries.
    pub jobs: Vec<String>,
}

impl Facts {
    /// Whether anything happened: a job ended or merged, or an item came in. An item that was
    /// waiting already is told when something else is, never a reason on its own.
    pub fn happened(&self) -> bool {
        !(self.done.is_empty()
            && self.merged.is_empty()
            && self.failed.is_empty()
            && self.needs_you.is_empty()
            && self.fresh == 0)
    }

    /// The facts counted in obid's own words, for when no model writes them: "Since you last
    /// looked: 2 jobs done and 1 item waits in your inbox."
    pub fn count(&self) -> String {
        let n = |count: usize, one: &str, many: &str| match count {
            0 => None,
            1 => Some(format!("1 {one}")),
            n => Some(format!("{n} {many}")),
        };
        let parts: Vec<String> = [
            n(self.done.len(), "job done", "jobs done"),
            n(
                self.merged.len(),
                "pull request merged",
                "pull requests merged",
            ),
            n(self.needs_you.len(), "job needs you", "jobs need you"),
            n(
                self.failed.len(),
                "job failed or stopped",
                "jobs failed or stopped",
            ),
            n(
                self.waiting.len(),
                "item waits in your inbox",
                "items wait in your inbox",
            ),
        ]
        .into_iter()
        .flatten()
        .collect();
        let list = match parts.split_last() {
            Some((last, [])) => last.clone(),
            Some((last, rest)) => format!("{} and {last}", rest.join(", ")),
            None => "nothing new".into(),
        };
        format!("Since you last looked: {list}.")
    }

    /// The facts as a list, what needs the owner first.
    pub fn text(&self, away: i64) -> String {
        let mut out = format!(
            "The owner was away for {}.\n",
            super::briefing::elapsed(away)
        );
        for (heading, lines) in [
            ("Waiting for the owner in the inbox", &self.waiting),
            ("Jobs done", &self.done),
            ("Pull requests merged", &self.merged),
            (
                "Jobs that need the owner, their work kept on their branch",
                &self.needs_you,
            ),
            ("Jobs that failed or stopped", &self.failed),
            ("Accounts that hit their usage limits", &self.limited),
        ] {
            if lines.is_empty() {
                continue;
            }
            out.push_str(&format!("\n{heading}:\n"));
            for line in lines {
                out.push_str(&format!("- {line}\n"));
            }
        }
        out
    }
}

/// A job by its title, else the start of its task, with its repository.
fn named(job: &Job) -> String {
    let title = job
        .title
        .clone()
        .filter(|t| !t.trim().is_empty())
        .unwrap_or_else(|| job.task.chars().take(80).collect());
    format!(
        "{} ({}, job {})",
        super::briefing::line(&title, 120),
        job.repo,
        job.id
    )
}

/// Whether a job ended on its account's usage limit, as the agent said it.
fn out_of_usage(job: &Job) -> bool {
    // Why it stopped is `reason` on obid now; the summary stays the agent's.
    let summary = format!("{} {}", job.summary, job.reason.as_deref().unwrap_or("")).to_lowercase();
    ["usage limit", "rate limit", "limit reached", "out of usage"]
        .iter()
        .any(|words| summary.contains(words))
}

/// The facts since `since`: jobs that ended or merged after it, every item waiting now, and the
/// accounts a job found out of usage.
pub fn facts(jobs: &[Job], inbox: &[Item], since: i64) -> Facts {
    let mut facts = Facts::default();
    let mut items: Vec<&Item> = inbox.iter().filter(|i| i.done.is_none()).collect();
    items.sort_by_key(|i| i.created);
    facts.waiting = items
        .iter()
        .map(|i| format!("{} ({})", super::briefing::line(&i.title, 160), i.kind))
        .collect();
    facts.fresh = items.iter().filter(|i| i.created > since).count();
    let mut ended: Vec<&Job> = jobs
        .iter()
        .filter(|j| j.finished.is_some_and(|f| f > since))
        .collect();
    ended.sort_by_key(|j| j.finished);
    for job in ended {
        if !job.status.is_active() {
            facts.jobs.push(job.id.clone());
        }
        match job.status {
            Status::Done => facts.done.push(named(job)),
            Status::Failed | Status::Stopped | Status::Interrupted => {
                if job.status == Status::Interrupted {
                    facts.needs_you.push(named(job));
                } else {
                    facts.failed.push(named(job));
                }
                let account = format!("{} · {}", job.agent, job.account);
                if out_of_usage(job) && !facts.limited.contains(&account) {
                    facts.limited.push(account);
                }
            }
            Status::Queued | Status::Running => {}
        }
    }
    let mut merged: Vec<&Job> = jobs
        .iter()
        .filter(|j| {
            j.merged()
                && j.pull_request
                    .as_ref()
                    .and_then(|pr| pr.merged_at)
                    .is_some_and(|at| at > since)
        })
        .collect();
    merged.sort_by_key(|j| j.pull_request.as_ref().and_then(|pr| pr.merged_at));
    for job in &merged {
        if !facts.jobs.contains(&job.id) {
            facts.jobs.push(job.id.clone());
        }
    }
    facts.merged = merged.into_iter().map(named).collect();
    facts
}

/// The recap with `system` ([`SYSTEM`] or [`CHECK_IN`]) of what happened between `since` and
/// `now`, or none: nothing happened, the vault can't be read, the call failed, or what it wrote
/// isn't a short recap. `call` makes the background call with the system prompt and the user
/// message.
pub async fn write<F, Fut>(
    system: &str,
    facts: &Facts,
    since: i64,
    now: i64,
    call: F,
) -> Option<String>
where
    F: FnOnce(String, String) -> Fut,
    Fut: Future<Output = Result<String, Failure>>,
{
    if !facts.happened() {
        return None;
    }
    let nonce = nonce();
    // What obid knows (titles from GitHub, Slack or an alert among it) loses every secret obid
    // and the vault know, and each line the secret scan flags, before any model sees it, quoted
    // like the briefing.
    let quoted = crate::event_work::for_agent(&facts.text(now - since)).ok()?;
    let user = format!(
        "{}\n\n{}",
        fence_rule(&nonce, "obid's own records of the jobs and the inbox"),
        fence(&nonce, &quoted)
    );
    let out = call(system.to_owned(), user).await.ok()?;
    let value: serde_json::Value = serde_json::from_str(&out).ok()?;
    short(value.get("recap")?.as_str()?)
}

/// `words` on one line when they're a recap: one to three sentences, at most [`LONGEST`].
fn short(words: &str) -> Option<String> {
    let line = words.split_whitespace().collect::<Vec<_>>().join(" ");
    let sentences = line
        .split_inclusive(['.', '!', '?'])
        .filter(|s| s.chars().any(char::is_alphanumeric))
        .count();
    (!line.is_empty() && line.chars().count() <= LONGEST && (1..=3).contains(&sentences))
        .then_some(line)
}

/// The answer with the recap as its first line. An answer with no words keeps nothing.
pub fn lead(talk: Talk, recap: Option<&str>) -> Talk {
    let Some(recap) = recap else {
        return talk;
    };
    let first = |words: &str| {
        if words.trim().is_empty() {
            recap.to_owned()
        } else {
            format!("{recap}\n\n{words}")
        }
    };
    match talk {
        Talk::None => Talk::None,
        Talk::Reply { text, jobs } => Talk::Reply {
            text: first(&text),
            jobs,
        },
        Talk::Question { said, question } => Talk::Question {
            said: first(&said),
            question,
        },
    }
}

/// The recap for an owner back at `now` after being seen last at `since` (none: they weren't
/// away), written with the first Claude account's quick model and sent as a `recap` event.
/// Without Claude there's no recap: a background call never goes to Codex (#537).
pub async fn back(shared: &Shared, since: Option<i64>, now: i64) -> Option<String> {
    let since = since?;
    let facts = facts(
        &shared.jobs.list(usize::MAX),
        &shared.link.waiting_items(now),
        since,
    );
    if !facts.happened() {
        return None;
    }
    let recap = quick(shared, SYSTEM, &facts, since, now).await?;
    shared.events.send(
        "recap",
        json!({
            "text": recap,
            "since": obi_protocol::time::format(since),
            "at": obi_protocol::time::format(now),
        }),
    );
    Some(recap)
}

/// What the first Claude account's quick model writes of `facts` with `system`, or none: no Claude
/// (a background call never goes to Codex, #537), or [`write`] wrote none.
async fn quick(
    shared: &Shared,
    system: &str,
    facts: &Facts,
    since: i64,
    now: i64,
) -> Option<String> {
    let room = Room {
        root: shared.config.home.join("plans"),
        jobs: shared.jobs.clone(),
    };
    let brain =
        Planner::of(&shared.config, &room)
            .into_iter()
            .find_map(|adapter| match adapter {
                Adapter::Claude(claude) => Some(claude),
                _ => None,
            })?;
    let mut calls = vec![];
    write(system, facts, since, now, |system, user| async move {
        brain
            .background(&system, &user, None, SCHEMA, &mut calls)
            .await
    })
    .await
}

/// The check-in's time due at `now`, if one is: its first after what it counts from, at most
/// [`AWAKE`] ago. One missed by more (obid wasn't running) is skipped: the next one covers it. A
/// clock set back before what it counts from looks back [`AWAKE`]: the day's one summary still
/// holds.
pub fn due(check_in: &CheckIn, now: i64) -> Option<i64> {
    let from = Some(check_in.from)
        .filter(|from| *from <= now)
        .unwrap_or(i64::MIN)
        .max(now - AWAKE);
    check_in
        .schedule
        .next_after(&check_in.zone(), from)
        .filter(|t| *t <= now)
}

/// Whether `now` is in the [`AWAKE`] hours after one of the check-in's times: outside them it's
/// quiet hours, and the away recap waits for the next summary.
pub fn awake(check_in: &CheckIn, now: i64) -> bool {
    check_in
        .schedule
        .next_after(&check_in.zone(), now - AWAKE)
        .is_some_and(|t| t <= now)
}

/// Whether `a` and `b` are on one day in the check-in's zone.
fn same_day(check_in: &CheckIn, a: i64, b: i64) -> bool {
    let day = |t| {
        jiff::Timestamp::from_second(t)
            .map(|t| t.to_zoned(check_in.zone()).date())
            .ok()
    };
    day(a) == day(b)
}

/// What a check posts.
#[derive(Debug, PartialEq)]
pub enum Post {
    /// The summary for its time `at`, of what happened since `since`.
    Summary { at: i64, since: i64 },
    /// The away recap, of what happened since the owner was last seen.
    Recap { since: i64 },
}

/// One check at `now` of `check_in` and `sent`, the due time of the last summary (kept while
/// check-ins are off): what to post, if anything, with `check_in.from`, `sent` and `presence` left
/// as posting it leaves them. At its time, the summary of what happened since the owner last
/// looked, never two on one day; else, in its [`AWAKE`] hours, the away recap once a stretch.
/// `happened` says whether anything happened since a time: nothing did, nothing posts.
pub fn step(
    check_in: &mut CheckIn,
    sent: &mut Option<i64>,
    presence: &Presence,
    now: i64,
    happened: impl FnOnce(i64) -> bool,
) -> Option<Post> {
    if let Some(at) = due(check_in, now) {
        // The time it acts on is kept, posted or not: never twice for one time.
        let from = std::mem::replace(&mut check_in.from, at).min(at);
        if sent.is_some_and(|sent| same_day(check_in, sent, at)) {
            return None;
        }
        let since = presence.since().map_or(from, |seen| seen.max(from));
        if !happened(since) {
            return None;
        }
        *sent = Some(at);
        presence.post(now);
        return Some(Post::Summary { at, since });
    }
    let since = presence.away(now).filter(|_| awake(check_in, now))?;
    if !happened(since) {
        return None;
    }
    // One a stretch away, whatever the call does: it's tried once (#537).
    presence.post(now);
    Some(Post::Recap { since })
}

/// The owner's check-in at `now`, once a minute (crate::routines' loop): [`step`] on what
/// `settings.json` keeps, kept before anything posts, then posted. Off, nothing.
pub async fn check_in(shared: &Shared, now: i64) {
    let home = &shared.config.home;
    let settings = crate::settings::load(home);
    let Some(kept) = settings.check_in else {
        return;
    };
    let (mut check_in, mut sent) = (kept.clone(), settings.check_in_sent);
    let post = step(&mut check_in, &mut sent, &shared.presence, now, |since| {
        facts(
            &shared.jobs.list(usize::MAX),
            &shared.link.waiting_items(now),
            since,
        )
        .happened()
    });
    if check_in != kept || sent != settings.check_in_sent {
        // ponytail: changed meanwhile, this minute posts nothing, and its stretch away has had
        // its one.
        let saved = crate::settings::update(home, |s| {
            let unchanged = s.check_in.as_ref() == Some(&kept);
            if unchanged {
                s.check_in = Some(check_in.clone());
                s.check_in_sent = sent;
            }
            unchanged
        });
        match saved {
            Ok(true) => {}
            Ok(false) => return,
            Err(e) => {
                tracing::warn!("check-in: can't keep its time, so nothing posts: {e}");
                return;
            }
        }
    }
    let Some(post) = post else {
        return;
    };
    let since = match post {
        Post::Summary { since, .. } | Post::Recap { since } => since,
    };
    write_post(shared, &check_in, since, now).await;
}

/// Posts a check-in in its conversation, of what happened since `since`: the quick model's one to
/// three sentences, else obid's own count, with the jobs' cards.
async fn write_post(shared: &Shared, check_in: &CheckIn, since: i64, now: i64) {
    let facts = facts(
        &shared.jobs.list(usize::MAX),
        &shared.link.waiting_items(now),
        since,
    );
    let text = quick(shared, CHECK_IN, &facts, since, now)
        .await
        .unwrap_or_else(|| facts.count());
    let jobs = facts.jobs.iter().rev().take(CARDS).rev().cloned().collect();
    let Some(conversation) = place(shared, check_in) else {
        return;
    };
    if let Err(e) = shared
        .conversations
        .append(&conversation, "oby", text, jobs)
    {
        tracing::warn!("check-in: conversation {conversation} wasn't told: {e:?}");
    }
}

/// The conversation a check-in posts in: its own, else a new one, kept as its own from now on.
fn place(shared: &Shared, check_in: &CheckIn) -> Option<String> {
    if shared.conversations.has(&check_in.conversation) {
        return Some(check_in.conversation.clone());
    }
    let new = shared.conversations.start_for("Check-ins").ok()?;
    let moved = crate::settings::update(&shared.config.home, |s| {
        if let Some(kept) = &mut s.check_in
            && kept.conversation == check_in.conversation
        {
            kept.conversation = new.clone();
        }
    });
    if let Err(e) = moved {
        tracing::warn!("check-in: can't keep its new conversation: {e}");
    }
    Some(new)
}

/// The owner tapped (an inbox answer, done or later): when they were away, the recap is written
/// in the background, sent as an event and kept for the conversation's next answer.
pub fn tapped(shared: &Arc<Shared>) {
    let now = obi_protocol::time::now();
    if let Some(since) = shared.presence.seen(now) {
        keep(shared.clone(), since, now);
    }
}

/// Writes the recap in the background and keeps it for the next answer with words.
pub fn keep(shared: Arc<Shared>, since: i64, now: i64) {
    tokio::spawn(async move {
        if let Some(recap) = back(&shared, Some(since), now).await {
            shared.presence.hold(recap);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    const T0: i64 = 1_790_000_000;
    const MIN: i64 = 60;

    fn job(id: &str, title: &str, status: Status, finished: i64) -> Job {
        let mut job = Job::new(
            id.into(),
            "deskree-inc/oby".into(),
            "code".into(),
            title.into(),
            "claude".into(),
            "personal".into(),
        );
        job.title = Some(title.into());
        job.status = status;
        job.finished = Some(finished);
        job
    }

    fn item(id: &str, title: &str, created: i64) -> Item {
        serde_json::from_value(serde_json::json!({
            "id": id, "kind": "question", "job": "j1", "title": title,
            "text": "Which base branch?", "options": ["dev", "main"], "details": null,
            "recommended": null, "created": created, "done": null, "later": null,
            "answer": null, "obi": null,
        }))
        .unwrap()
    }

    fn reply(text: &str) -> Talk {
        Talk::Reply {
            text: text.into(),
            jobs: vec![],
        }
    }

    fn text(talk: &Talk) -> String {
        match talk {
            Talk::Reply { text, .. } => text.clone(),
            _ => panic!("not a reply"),
        }
    }

    /// What the fake background call was sent, and what it answers.
    #[derive(Default)]
    struct Fake {
        sent: Mutex<Vec<(String, String)>>,
    }

    impl Fake {
        async fn answer(
            self: Arc<Self>,
            system: String,
            user: String,
            out: Result<String, Failure>,
        ) -> Result<String, Failure> {
            self.sent.lock().unwrap().push((system, user));
            out
        }
    }

    /// One owner, gone `away` seconds, back to two jobs done and one inbox item; the brain's
    /// answer is "Ready", the background call answers `out`.
    async fn back_after(away: i64, out: Result<String, Failure>) -> (Talk, Arc<Fake>) {
        let presence = Presence::default();
        assert_eq!(presence.seen(T0), None, "the first sight is no return");
        let now = T0 + away;
        let jobs = [
            job("a1", "Fix the login redirect", Status::Done, T0 + 5 * MIN),
            job("b2", "Add the CSV export", Status::Done, T0 + 9 * MIN),
        ];
        let inbox = [item(
            "i1",
            "Pick a base branch for the release",
            T0 + 12 * MIN,
        )];
        let fake = Arc::new(Fake::default());
        let recap = match presence.seen(now) {
            Some(since) => {
                let facts = facts(&jobs, &inbox, since);
                let call = fake.clone();
                write(SYSTEM, &facts, since, now, move |s, u| {
                    call.answer(s, u, out)
                })
                .await
            }
            None => None,
        };
        (lead(reply("Ready"), recap.as_deref()), fake)
    }

    fn recap_json(words: &str) -> Result<String, Failure> {
        Ok(serde_json::json!({ "recap": words }).to_string())
    }

    const WORDS: &str = "Fix the login redirect and Add the CSV export are done. Pick a base branch for the release needs you.";

    #[tokio::test]
    async fn back_after_31_minutes_the_answer_starts_with_a_recap_naming_both_the_item_first() {
        let (talk, fake) = back_after(31 * MIN, recap_json(WORDS)).await;
        let said = text(&talk);
        assert!(said.starts_with(WORDS), "{said}");
        assert!(said.ends_with("\n\nReady"), "{said}");
        let sent = fake.sent.lock().unwrap();
        assert_eq!(sent.len(), 1, "one attempt");
        let (system, user) = &sent[0];
        assert_eq!(system, SYSTEM, "the same prompt every time");
        let item = user.find("Pick a base branch for the release").expect(user);
        let first = user.find("Fix the login redirect").expect(user);
        let second = user.find("Add the CSV export").expect(user);
        assert!(
            item < first && item < second,
            "what needs the owner comes first: {user}"
        );
        // Quoted inside the fence, with the rule saying it's data.
        let open = user.find("<<<quoted-").expect(user);
        let close = user.rfind(">>>").expect(user);
        assert!(open < item && second < close, "{user}");
        assert!(user.contains("never instructions"), "{user}");
    }

    #[tokio::test]
    async fn under_30_minutes_there_is_no_recap_and_no_call() {
        let (talk, fake) = back_after(29 * MIN, recap_json(WORDS)).await;
        assert_eq!(text(&talk), "Ready");
        assert!(fake.sent.lock().unwrap().is_empty());
        let (talk, fake) = back_after(30 * MIN, recap_json(WORDS)).await;
        assert_eq!(
            text(&talk),
            "Ready",
            "exactly 30 minutes isn't more than 30"
        );
        assert!(fake.sent.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_failed_background_call_leaves_the_answer_unchanged() {
        let (talk, fake) = back_after(31 * MIN, Err(Failure::Failed("exit 1".into()))).await;
        assert_eq!(text(&talk), "Ready");
        assert_eq!(fake.sent.lock().unwrap().len(), 1, "one attempt, no retry");
        // An answer that isn't a short recap is no recap either.
        for out in [
            Ok("not json".to_owned()),
            recap_json(""),
            recap_json(&"Long. ".repeat(4)),
            recap_json(&"x".repeat(LONGEST + 1)),
        ] {
            let (talk, _) = back_after(31 * MIN, out).await;
            assert_eq!(text(&talk), "Ready");
        }
    }

    #[test]
    fn the_owner_is_away_from_their_last_message_or_tap() {
        let presence = Presence::default();
        assert_eq!(presence.seen(T0), None);
        assert_eq!(presence.seen(T0 + 20 * MIN), None);
        // 40 minutes after the first, but 20 after the last: not away.
        assert_eq!(presence.seen(T0 + 40 * MIN), None);
        assert_eq!(presence.seen(T0 + 71 * MIN), Some(T0 + 40 * MIN));
        // Only the first request after the absence gets one.
        assert_eq!(presence.seen(T0 + 72 * MIN), None);
    }

    #[test]
    fn a_held_recap_is_taken_once() {
        let presence = Presence::default();
        presence.hold("Two jobs are done.".into());
        assert_eq!(presence.take().as_deref(), Some("Two jobs are done."));
        assert_eq!(presence.take(), None);
    }

    #[test]
    fn facts_are_what_changed_since_the_owner_left() {
        let since = T0;
        let mut merged = job("m1", "Bump the SDK", Status::Done, T0 - 60 * MIN);
        merged.pull_request = Some(crate::github::PullRequest {
            state: "MERGED".into(),
            review_decision: None,
            base: "main".into(),
            merged_at: Some(T0 + 3 * MIN),
            checked_at: T0 + 3 * MIN,
            head: None,
        });
        let mut limited = job("l1", "Port the parser", Status::Interrupted, T0 + 4 * MIN);
        limited.summary = "Codex hit an error: You've hit your usage limit.".into();
        limited.agent = "codex".into();
        limited.account = "deskree".into();
        let jobs = [
            job("old", "Before you left", Status::Done, T0 - MIN),
            job("run", "Still running", Status::Running, T0 + MIN),
            job("d1", "Fix the login redirect", Status::Done, T0 + 5 * MIN),
            job("f1", "Migrate the schema", Status::Failed, T0 + 6 * MIN),
            merged,
            limited,
        ];
        let mut answered = item("i2", "Answered already", T0);
        answered.done = Some(T0 + MIN);
        let inbox = [item("i1", "Pick a base branch", T0 + 2 * MIN), answered];
        let facts = facts(&jobs, &inbox, since);
        assert_eq!(facts.waiting.len(), 1, "{facts:?}");
        assert!(facts.waiting[0].contains("Pick a base branch"));
        assert_eq!(facts.done.len(), 1, "{facts:?}");
        assert!(facts.done[0].contains("Fix the login redirect"));
        assert_eq!(facts.merged.len(), 1, "{facts:?}");
        assert!(facts.merged[0].contains("Bump the SDK"));
        assert_eq!(facts.failed.len(), 1, "{facts:?}");
        assert_eq!(facts.needs_you.len(), 1, "{facts:?}");
        assert_eq!(facts.limited, vec!["codex · deskree".to_owned()]);
        assert!(facts.happened());
        assert_eq!(facts.fresh, 1, "the answered item isn't waiting");
        assert_eq!(
            facts.jobs,
            ["l1", "d1", "f1", "m1"],
            "by when they ended: {facts:?}"
        );
        assert!(!super::facts(&[], &[], since).happened());
    }

    #[tokio::test]
    async fn nothing_happened_means_no_call() {
        let called = Arc::new(Mutex::new(false));
        let flag = called.clone();
        let recap = write(
            SYSTEM,
            &Facts::default(),
            T0,
            T0 + 60 * MIN,
            move |_, _| async move {
                *flag.lock().unwrap() = true;
                recap_json(WORDS)
            },
        )
        .await;
        assert_eq!(recap, None);
        assert!(!*called.lock().unwrap());
    }

    #[test]
    fn a_question_says_the_recap_before_its_words() {
        let talk = Talk::Question {
            said: "About the release:".into(),
            question: serde_json::from_value(serde_json::json!({"text": "Ship it?"})).unwrap(),
        };
        match lead(talk, Some("Two jobs are done.")) {
            Talk::Question { said, .. } => {
                assert_eq!(said, "Two jobs are done.\n\nAbout the release:")
            }
            _ => panic!(),
        }
    }

    #[test]
    fn the_prompt_and_schema_never_change() {
        let schema: serde_json::Value = serde_json::from_str(SCHEMA).unwrap();
        assert_eq!(schema["required"], serde_json::json!(["recap"]));
        assert!(!SYSTEM.is_empty());
    }

    // Check-ins (#1116), each with its clock given.

    /// Mon 2026-10-19 00:00 in São Paulo (UTC-3): 03:00 UTC.
    const MONDAY: i64 = 1_792_378_800;
    const HOUR: i64 = 60 * MIN;

    /// Mon 9:00 in São Paulo.
    const NINE: i64 = MONDAY + 9 * HOUR;
    const DAY: i64 = 24 * HOUR;

    fn kept(schedule: crate::routines::Schedule, from: i64) -> CheckIn {
        CheckIn {
            schedule,
            zone: "America/Sao_Paulo".into(),
            conversation: "c1".into(),
            from,
        }
    }

    fn weekdays_at_9(from: i64) -> CheckIn {
        kept(
            crate::routines::Schedule::Weekdays { at: "09:00".into() },
            from,
        )
    }

    fn daily_at(at: &str, from: i64) -> CheckIn {
        kept(crate::routines::Schedule::Daily { at: at.into() }, from)
    }

    /// What `settings.json` and obid's memory keep from one check to the next, as the tick
    /// keeps them.
    struct Kept {
        check_in: CheckIn,
        sent: Option<i64>,
        presence: Presence,
    }

    impl Kept {
        fn new(check_in: CheckIn, sent: Option<i64>) -> Kept {
            Kept {
                check_in,
                sent,
                presence: Presence::default(),
            }
        }

        /// One check at `now`, things having happened at `happened` (a job ended, an item came).
        fn check(&mut self, now: i64, happened: &[i64]) -> Option<Post> {
            step(
                &mut self.check_in,
                &mut self.sent,
                &self.presence,
                now,
                |since| happened.iter().any(|t| *t > since && *t <= now),
            )
        }
    }

    #[test]
    fn a_check_in_is_due_at_its_time_once_and_a_long_missed_one_waits_for_the_next() {
        let nine = MONDAY + 9 * HOUR;
        // Set Monday at 8:00: due at 9:00, not a minute before.
        let set = weekdays_at_9(MONDAY + 8 * HOUR);
        assert_eq!(due(&set, nine - MIN), None);
        assert_eq!(due(&set, nine), Some(nine));
        assert_eq!(
            due(&set, nine + 2 * HOUR),
            Some(nine),
            "late, still that morning"
        );
        // Acted on: nothing more until Tuesday 9:00.
        let acted = weekdays_at_9(nine);
        assert_eq!(due(&acted, nine + MIN), None);
        assert_eq!(due(&acted, nine + 24 * HOUR - MIN), None);
        assert_eq!(due(&acted, nine + 24 * HOUR), Some(nine + 24 * HOUR));
        // Saturday and Sunday have none: Friday's acted on, Monday's next.
        let friday = acted.from + 4 * 24 * HOUR;
        let weekend = weekdays_at_9(friday);
        assert_eq!(due(&weekend, friday + 24 * HOUR), None);
        assert_eq!(due(&weekend, friday + 48 * HOUR), None);
        assert_eq!(due(&weekend, friday + 72 * HOUR), Some(friday + 72 * HOUR));
        // obid wasn't running Monday morning: at 22:00 it's past (13 hours), Tuesday's comes.
        let off = weekdays_at_9(MONDAY - 3 * 24 * HOUR);
        assert_eq!(due(&off, MONDAY + 22 * HOUR), None);
        assert_eq!(due(&off, nine + 24 * HOUR), Some(nine + 24 * HOUR));
        // A clock set back before what it counts from still finds the morning's.
        let ahead = weekdays_at_9(nine + 30 * 24 * HOUR);
        assert_eq!(due(&ahead, nine + 30 * MIN), Some(nine));
    }

    #[test]
    fn days_are_the_zones() {
        let check_in = weekdays_at_9(NINE);
        assert!(same_day(&check_in, NINE, MONDAY + 15 * HOUR));
        assert!(!same_day(&check_in, NINE, NINE + DAY));
        // 23:30 in São Paulo is the next day in UTC: the zone's day counts.
        assert!(same_day(&check_in, NINE, MONDAY + 23 * HOUR + 30 * MIN));
    }

    #[test]
    fn asleep_at_9_the_summary_comes_at_11_once_and_a_restart_sends_no_second() {
        let friday = NINE - 3 * DAY;
        let mut kept = Kept::new(weekdays_at_9(friday), Some(friday));
        let overnight = MONDAY + 3 * HOUR;
        // The Mac slept through 9:00: the first check, at 11:00, posts it.
        assert_eq!(
            kept.check(MONDAY + 11 * HOUR, &[overnight]),
            Some(Post::Summary {
                at: NINE,
                since: friday
            })
        );
        assert_eq!(kept.sent, Some(NINE), "the due time, not when it posted");
        assert_eq!(kept.check_in.from, NINE);
        assert_eq!(kept.check(MONDAY + 11 * HOUR + MIN, &[overnight]), None);
        // obid restarts: settings.json keeps the time and the day's summary, memory nothing.
        let mut kept = Kept::new(kept.check_in, kept.sent);
        assert_eq!(kept.check(MONDAY + 11 * HOUR + 5 * MIN, &[overnight]), None);
        let tuesday = MONDAY + DAY + 2 * HOUR;
        assert_eq!(
            kept.check(NINE + DAY, &[overnight, tuesday]),
            Some(Post::Summary {
                at: NINE + DAY,
                since: NINE
            })
        );
    }

    #[test]
    fn a_late_summary_across_midnight_leaves_the_next_days() {
        let mut kept = Kept::new(daily_at("23:30", MONDAY + 23 * HOUR), None);
        let monday_night = MONDAY + 23 * HOUR + 10 * MIN;
        let tuesday_noon = MONDAY + DAY + 12 * HOUR;
        let happened = [monday_night, tuesday_noon];
        let late = MONDAY + DAY + 10 * MIN;
        assert_eq!(
            kept.check(late, &happened),
            Some(Post::Summary {
                at: MONDAY + 23 * HOUR + 30 * MIN,
                since: MONDAY + 23 * HOUR
            })
        );
        assert_eq!(kept.sent, Some(MONDAY + 23 * HOUR + 30 * MIN));
        // Tuesday's comes at its time: Monday's, posted after midnight, isn't Tuesday's.
        assert_eq!(kept.check(late + HOUR, &happened), None);
        assert_eq!(
            kept.check(MONDAY + DAY + 23 * HOUR + 30 * MIN, &happened),
            Some(Post::Summary {
                at: MONDAY + DAY + 23 * HOUR + 30 * MIN,
                since: late
            })
        );
    }

    #[test]
    fn off_and_on_again_or_a_new_time_never_sends_a_second_summary_that_day() {
        let mut kept = Kept::new(weekdays_at_9(NINE - 3 * DAY), None);
        let overnight = MONDAY + 3 * HOUR;
        assert!(matches!(
            kept.check(NINE, &[overnight]),
            Some(Post::Summary { .. })
        ));
        // Turned off at 10:00 (`checkInSent` stays) and on again, every day at 15:00.
        let mut kept = Kept::new(daily_at("15:00", MONDAY + 10 * HOUR), kept.sent);
        let noon = MONDAY + 12 * HOUR;
        assert_eq!(kept.check(MONDAY + 15 * HOUR, &[overnight, noon]), None);
        assert_eq!(kept.check_in.from, MONDAY + 15 * HOUR, "its time is kept");
        let tuesday = MONDAY + DAY + 10 * HOUR;
        assert_eq!(
            kept.check(MONDAY + DAY + 15 * HOUR, &[overnight, noon, tuesday]),
            Some(Post::Summary {
                at: MONDAY + DAY + 15 * HOUR,
                since: MONDAY + 15 * HOUR
            })
        );
    }

    #[test]
    fn an_away_recap_posts_once_a_stretch_only_in_its_hours() {
        let mut kept = Kept::new(weekdays_at_9(NINE), Some(NINE));
        kept.presence.seen(MONDAY + 10 * HOUR);
        let happened = [
            MONDAY + 10 * HOUR + 20 * MIN,
            MONDAY + 11 * HOUR + 10 * MIN,
            MONDAY + 21 * HOUR + 30 * MIN,
        ];
        assert_eq!(kept.check(MONDAY + 10 * HOUR + 29 * MIN, &happened), None);
        assert_eq!(
            kept.check(MONDAY + 10 * HOUR + 31 * MIN, &happened),
            Some(Post::Recap {
                since: MONDAY + 10 * HOUR
            })
        );
        assert_eq!(kept.check(MONDAY + 10 * HOUR + 45 * MIN, &happened), None);
        // Back at 11:00: the return's recap covers only what came after Oby's.
        assert_eq!(
            kept.presence.seen(MONDAY + 11 * HOUR),
            Some(MONDAY + 10 * HOUR + 31 * MIN)
        );
        // Away again: a new stretch, a new one.
        assert_eq!(
            kept.check(MONDAY + 11 * HOUR + 31 * MIN, &happened),
            Some(Post::Recap {
                since: MONDAY + 11 * HOUR
            })
        );
        // Away from 12:00 with nothing new, then something at 21:30: quiet hours by then.
        kept.presence.seen(MONDAY + 12 * HOUR);
        assert_eq!(kept.check(MONDAY + 12 * HOUR + 31 * MIN, &happened), None);
        assert_eq!(kept.check(MONDAY + 21 * HOUR + 31 * MIN, &happened), None);
    }

    #[test]
    fn the_summary_is_its_stretchs_one_and_a_quiet_morning_posts_nothing() {
        let mut kept = Kept::new(weekdays_at_9(NINE - 3 * DAY), Some(NINE - 3 * DAY));
        kept.presence.seen(MONDAY + 8 * HOUR);
        let early = [MONDAY + 8 * HOUR + 10 * MIN];
        assert_eq!(
            kept.check(NINE, &early),
            Some(Post::Summary {
                at: NINE,
                since: MONDAY + 8 * HOUR
            })
        );
        assert_eq!(
            kept.check(NINE + MIN, &early),
            None,
            "away, but posted since"
        );
        // Tuesday: nothing by 9:00, so nothing posts. The owner never came back, so the stretch
        // had its one: what comes at 9:30 waits for Wednesday's summary.
        let later = [MONDAY + 8 * HOUR + 10 * MIN, NINE + DAY + 30 * MIN];
        assert_eq!(kept.check(NINE + DAY, &later), None);
        assert_eq!(kept.sent, Some(NINE));
        assert_eq!(kept.check(NINE + DAY + 31 * MIN, &later), None);
        assert_eq!(
            kept.check(NINE + 2 * DAY, &later),
            Some(Post::Summary {
                at: NINE + 2 * DAY,
                since: NINE + DAY
            })
        );
    }

    #[test]
    fn the_away_recap_keeps_quiet_hours() {
        let check_in = weekdays_at_9(MONDAY);
        assert!(!awake(&check_in, MONDAY + 8 * HOUR + 59 * MIN));
        assert!(awake(&check_in, MONDAY + 9 * HOUR));
        assert!(awake(&check_in, MONDAY + 20 * HOUR + 59 * MIN));
        assert!(!awake(&check_in, MONDAY + 21 * HOUR), "12 hours after 9:00");
        assert!(!awake(&check_in, MONDAY + 3 * HOUR));
        let saturday = MONDAY + 5 * 24 * HOUR + 12 * HOUR;
        assert!(!awake(&check_in, saturday), "not one of its days");
    }

    #[test]
    fn the_away_recap_posts_once_a_stretch_and_the_return_covers_what_came_after() {
        let presence = Presence::default();
        assert_eq!(presence.away(T0), None, "never seen: not away");
        presence.seen(T0);
        assert_eq!(presence.away(T0 + 30 * MIN), None);
        assert_eq!(presence.away(T0 + 31 * MIN), Some(T0));
        presence.post(T0 + 31 * MIN);
        assert_eq!(presence.away(T0 + 90 * MIN), None, "one a stretch");
        assert_eq!(presence.since(), Some(T0 + 31 * MIN));
        // Back: the recap covers only what came after the check-in.
        assert_eq!(presence.seen(T0 + 2 * HOUR), Some(T0 + 31 * MIN));
        assert_eq!(presence.away(T0 + 2 * HOUR + 30 * MIN), None);
        // Away again: a new stretch, a new one.
        assert_eq!(presence.away(T0 + 2 * HOUR + 31 * MIN), Some(T0 + 2 * HOUR));
    }

    #[tokio::test]
    async fn a_quiet_day_posts_nothing_and_an_item_already_waiting_isnt_news() {
        let inbox = [item("i1", "Pick a base branch", T0 - HOUR)];
        let quiet = facts(&[], &inbox, T0);
        assert!(!quiet.happened(), "{quiet:?}");
        let called = Arc::new(Mutex::new(false));
        let flag = called.clone();
        let words = write(
            CHECK_IN,
            &quiet,
            T0,
            T0 + 9 * HOUR,
            move |_, _| async move {
                *flag.lock().unwrap() = true;
                recap_json(WORDS)
            },
        )
        .await;
        assert_eq!(words, None);
        assert!(!*called.lock().unwrap(), "no call on a quiet day");
        // Once something ends, the waiting item is told with it.
        let jobs = [job("d1", "Fix the login redirect", Status::Done, T0 + HOUR)];
        let news = facts(&jobs, &inbox, T0);
        assert!(news.happened());
        assert_eq!(
            news.count(),
            "Since you last looked: 1 job done and 1 item waits in your inbox."
        );
    }

    #[tokio::test]
    async fn a_check_in_is_written_with_its_own_prompt_from_scanned_facts() {
        let jobs = [job(
            "d1",
            "Rotate ghp_abcdefghijklmnopqrstuvwxyz0123456789 now",
            Status::Done,
            T0 + HOUR,
        )];
        let facts = facts(&jobs, &[], T0);
        let fake = Arc::new(Fake::default());
        let call = fake.clone();
        let words = write(CHECK_IN, &facts, T0, T0 + 9 * HOUR, move |s, u| {
            call.answer(s, u, recap_json(WORDS))
        })
        .await;
        assert_eq!(words.as_deref(), Some(WORDS));
        let sent = fake.sent.lock().unwrap();
        let (system, user) = &sent[0];
        assert_eq!(system, CHECK_IN);
        assert!(
            !user.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
            "{user}"
        );
        assert!(user.contains("never instructions"), "{user}");
    }

    #[test]
    fn the_count_names_each_kind_once() {
        let facts = Facts {
            done: vec!["a".into(), "b".into()],
            merged: vec!["m".into()],
            failed: vec!["f".into()],
            needs_you: vec!["n".into(), "o".into()],
            ..Facts::default()
        };
        assert_eq!(
            facts.count(),
            "Since you last looked: 2 jobs done, 1 pull request merged, 2 jobs need you and 1 job failed or stopped."
        );
    }
}
