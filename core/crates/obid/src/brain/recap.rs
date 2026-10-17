//! The recap when the owner comes back (#594): obid keeps the time of the owner's last message or
//! tap, and on the first one after more than [`AWAY`] it sums up what happened meanwhile (jobs
//! done, merged or failed, inbox items waiting, accounts that hit their limits) in one to three
//! sentences, ending with the one thing that needs the owner, if any. A background call (#537:
//! one attempt, the quick model, never Codex) writes it from a fact list obid builds itself; the
//! facts are quoted inside a nonce fence and go through the vault first. The recap goes out as a
//! `recap` event and leads the conversation's next answer; it's never a turn the user wrote.

use std::future::Future;
use std::sync::{Arc, Mutex};

use serde_json::json;

use crate::api::Shared;
use crate::job::{Job, Status};
use crate::sphere::inbox::Item;

use super::actions::Talk;
use super::briefing::{fence, fence_rule, nonce};
use super::planner::{Adapter, Failure, Planner, Room};

/// How long the owner is away before their next message or tap gets a recap: 30 minutes.
pub const AWAY: i64 = 30 * 60;
/// The longest recap obid passes on: a few sentences, never a report.
pub const LONGEST: usize = 600;

/// The recap's instructions: the same on every call, so the model's server can reuse them (#534).
pub const SYSTEM: &str = "You are Oby. The owner just came back after a while away. Sum up, in one to three short sentences, what happened while they were away, from the facts you're given and nothing else. Name the jobs and items by their titles. If something waits for the owner, end with that one thing, said plainly; if nothing does, say so in a few words or not at all. No greeting, no lists, no advice, no questions. Put the sentences in `recap`.";
/// What the recap call fills.
pub const SCHEMA: &str = r#"{"type":"object","properties":{"recap":{"type":"string","description":"One to three sentences."}},"required":["recap"],"additionalProperties":false}"#;

/// When the owner was last seen, and a recap written for an answer that had nothing to say.
#[derive(Default)]
pub struct Presence {
    last: Mutex<Option<i64>>,
    held: Mutex<Option<String>>,
}

impl Presence {
    /// The owner sent a message or tapped at `now`. When they had been away more than [`AWAY`],
    /// the time they were last seen: the recap covers what happened since. Kept in memory: after
    /// obid starts, the first message or tap is a first sight, with no recap.
    pub fn seen(&self, now: i64) -> Option<i64> {
        let mut last = self.last.lock().unwrap_or_else(|e| e.into_inner());
        let before = *last;
        *last = Some(before.map_or(now, |before| before.max(now)));
        before.filter(|before| now - before > AWAY)
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
    /// The accounts a job found out of usage: `codex · deskree`.
    pub limited: Vec<String>,
}

impl Facts {
    pub fn is_empty(&self) -> bool {
        self.waiting.is_empty()
            && self.done.is_empty()
            && self.merged.is_empty()
            && self.failed.is_empty()
            && self.limited.is_empty()
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
    format!("{} ({}, job {})", title.trim(), job.repo, job.id)
}

/// Whether a job ended on its account's usage limit, as the agent said it.
fn out_of_usage(job: &Job) -> bool {
    let summary = job.summary.to_lowercase();
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
        .map(|i| format!("{} ({})", i.title.trim(), i.kind))
        .collect();
    let mut ended: Vec<&Job> = jobs
        .iter()
        .filter(|j| j.finished.is_some_and(|f| f > since))
        .collect();
    ended.sort_by_key(|j| j.finished);
    for job in ended {
        match job.status {
            Status::Done => facts.done.push(named(job)),
            Status::Failed | Status::Stopped | Status::Interrupted => {
                facts.failed.push(named(job));
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
    facts.merged = merged.into_iter().map(named).collect();
    facts
}

/// The recap for an owner back at `now` after being seen last at `since`, or none: nothing
/// happened, the vault can't be read, the call failed, or what it wrote isn't a short recap.
/// `call` makes the background call with the system prompt and the user message.
pub async fn write<F, Fut>(facts: &Facts, since: i64, now: i64, call: F) -> Option<String>
where
    F: FnOnce(String, String) -> Fut,
    Fut: Future<Output = Result<String, Failure>>,
{
    if facts.is_empty() {
        return None;
    }
    let nonce = nonce();
    // What obid knows goes through the vault before any model sees it, quoted like the briefing.
    let quoted = crate::vault::for_agent(&facts.text(now - since)).ok()?;
    let user = format!(
        "{}\n\n{}",
        fence_rule(&nonce, "obid's own records of the jobs and the inbox"),
        fence(&nonce, &quoted)
    );
    let out = call(SYSTEM.to_owned(), user).await.ok()?;
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
    if facts.is_empty() {
        return None;
    }
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
    let recap = write(&facts, since, now, |system, user| async move {
        brain
            .background(&system, &user, None, SCHEMA, &mut calls)
            .await
    })
    .await?;
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
                write(&facts, since, now, move |s, u| call.answer(s, u, out)).await
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
        let mut limited = job("l1", "Port the parser", Status::Failed, T0 + 4 * MIN);
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
        assert_eq!(facts.failed.len(), 2, "{facts:?}");
        assert_eq!(facts.limited, vec!["codex · deskree".to_owned()]);
        assert!(!facts.is_empty());
        assert!(super::facts(&[], &[], since).is_empty());
    }

    #[tokio::test]
    async fn nothing_happened_means_no_call() {
        let called = Arc::new(Mutex::new(false));
        let flag = called.clone();
        let recap = write(
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
}
