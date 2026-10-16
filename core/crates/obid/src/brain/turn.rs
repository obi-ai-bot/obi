//! One turn of the conversation, like Claude Code's loop (`Desk.plan`): the brain picks one
//! action, obid does it and tells the brain what happened, and the brain picks the next, until
//! the request is done ("Deskree is full, move its jobs to Personal and Codex" is several
//! moves). It ends on an answer, an action it already took, one that couldn't happen, a later
//! step only rules could plan, eight actions, or the turn's budget. Each action that changes
//! something is a `step` event when it starts and when it ends; Stop finishes the action under
//! way and starts nothing more.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::json;

use super::actions::{self, Asked, Outcome, Talk};
use super::plan::{Action, Plan};
use super::planner::{Planner, Record, Room};
use crate::api::Shared;
use crate::conversation::Turn;

/// The most actions one turn takes.
pub const MOST_STEPS: usize = 8;
/// How long a turn may act (`Desk.turnBudget`), under the apps' 120-second wait.
pub const TURN_BUDGET: Duration = Duration::from_secs(110);
/// What a turn says when it ran out of time.
pub const AS_FAR_AS: &str = "That's as far as Oby got in one go: say “continue” for the rest.";

/// A turn under way, as Stop and cancel reach it.
#[derive(Debug)]
pub struct Control {
    /// The user's turn: what its step events name.
    pub turn: String,
    pub conversation: String,
    /// Stop (`POST /v1/conversation/stop`, or a bare "stop"): finish the action under way, then
    /// answer with what was done.
    stopped: AtomicBool,
    /// Cancel (`POST /v1/plans/cancel`, or new words in the same conversation): nothing more
    /// happens for it, and its answer is `none`.
    cancelled: AtomicBool,
}

impl Control {
    pub fn stopped(&self) -> bool {
        self.stopped.load(Ordering::SeqCst)
    }

    pub fn cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// Whether what the brain plans may still happen.
    pub fn live(&self) -> bool {
        !self.stopped() && !self.cancelled()
    }
}

/// The turns under way.
#[derive(Debug, Default)]
pub struct Turns {
    underway: Mutex<Vec<Arc<Control>>>,
}

impl Turns {
    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Arc<Control>>> {
        self.underway.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A new turn in `conversation`: it replaces the one under way there, whose plan, when it
    /// comes, does nothing.
    pub fn begin(&self, turn: &str, conversation: &str) -> Arc<Control> {
        let control = Arc::new(Control {
            turn: turn.into(),
            conversation: conversation.into(),
            stopped: AtomicBool::new(false),
            cancelled: AtomicBool::new(false),
        });
        let mut underway = self.lock();
        for earlier in underway.iter().filter(|c| c.conversation == conversation) {
            earlier.cancelled.store(true, Ordering::SeqCst);
        }
        underway.push(control.clone());
        control
    }

    pub fn end(&self, control: &Arc<Control>) {
        self.lock().retain(|c| !Arc::ptr_eq(c, control));
    }

    /// Asks the turns under way (in `conversation`, or all) to stop after the action under way.
    /// True when there was one.
    pub fn stop(&self, conversation: Option<&str>) -> bool {
        self.mark(conversation, |c| c.stopped.store(true, Ordering::SeqCst))
    }

    /// Drops the turns under way (in `conversation`, or all): their plans do nothing.
    pub fn cancel(&self, conversation: Option<&str>) -> bool {
        self.mark(conversation, |c| c.cancelled.store(true, Ordering::SeqCst))
    }

    fn mark(&self, conversation: Option<&str>, mark: impl Fn(&Control)) -> bool {
        let underway = self.lock();
        let mut any = false;
        for control in underway
            .iter()
            .filter(|c| conversation.is_none_or(|id| c.conversation == id))
        {
            mark(control);
            any = true;
        }
        any
    }

    /// The conversation of the latest turn under way.
    pub fn latest_conversation(&self) -> Option<String> {
        self.lock().last().map(|c| c.conversation.clone())
    }
}

/// Words that end the turn under way instead of starting one: "never mind", "stop", "cancel",
/// "forget it", with any punctuation after them (`Conversation.cancels`). They never reach the
/// brain, so no job stops on a bare word: "stop the vault job" or "stop everything" do that.
pub fn cancels(said: &str) -> bool {
    let lower = said.to_lowercase();
    let cleaned: String = lower
        .chars()
        .map(|c| {
            if c.is_ascii_lowercase() || c == '\'' || c == ' ' {
                c
            } else {
                ' '
            }
        })
        .collect();
    let words = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    [
        "never mind",
        "nevermind",
        "stop",
        "cancel",
        "cancel that",
        "forget it",
        "no wait",
        "wait",
        "nothing",
        "leave it",
    ]
    .contains(&words.as_str())
}

/// The user's words, with what Oby did so far this turn, for the brain's next step.
pub fn continued(said: &str, done: &[String]) -> String {
    format!(
        "{said}\n\n(Oby already did this for the request, step by step: {}\nPlan the next action the request still needs, using the briefing as it is now. When everything the user asked for is done, answer reply_only with an empty reply: Oby tells the user what it did.)",
        done.join(" ")
    )
}

/// The turn's answer, after what it did: the brain's last words follow Oby's (`Desk.after`).
pub fn after(done: &[String], talk: Talk) -> Talk {
    if done.is_empty() {
        return talk;
    }
    let did = done.join(" ");
    match talk {
        Talk::Reply { text, jobs } => Talk::Reply {
            text: if text.is_empty() || done.contains(&text) {
                did
            } else {
                format!("{did} {text}")
            },
            jobs,
        },
        Talk::Question { said, mut question } => {
            question.text = format!("{did} {}", question.text);
            Talk::Question { said, question }
        }
        Talk::None => Talk::reply(did),
    }
}

/// What a turn ended with when it said nothing more: what it did, or nothing.
fn finish(done: &[String]) -> Talk {
    if done.is_empty() {
        Talk::None
    } else {
        Talk::reply(done.join(" "))
    }
}

/// Rules stood in after the brain asked for a setting obid refused: the user hears why
/// instead of a guess.
fn setting_refusal(refused: &[String]) -> Option<String> {
    let last = refused.last()?;
    let start = last.find("plan refused (")? + "plan refused (".len();
    let reason = &last[start..start + last[start..].find(')')?];
    [
        "maxRunning goes",
        "unknown model",
        "unknown effort",
        "setting needs",
        "reserve setting",
    ]
    .iter()
    .any(|r| reason.contains(r))
    .then(|| reason.to_owned())
}

/// What a turn answers, and the longer Markdown under it when the brain gave some.
pub struct Answered {
    pub talk: Talk,
    pub details: Option<String>,
}

/// Runs one turn for `said`, the conversation so far being `given`.
pub async fn run(
    shared: &Arc<Shared>,
    said: &str,
    given: &[Turn],
    asked: &Asked<'_>,
    control: &Arc<Control>,
) -> Answered {
    let room = Room {
        root: shared.config.home.join("plans"),
        jobs: shared.jobs.clone(),
    };
    let home = &shared.config.home;
    let deadline = Instant::now() + TURN_BUDGET;
    let live = || control.live();
    let halted = || !control.live();
    let mut done: Vec<String> = vec![];
    let mut taken: HashSet<String> = HashSet::new();
    let mut request = said.to_owned();
    let mut details: Option<String> = None;
    let answered = |talk: Talk, details: Option<String>| Answered { talk, details };
    for step in 0..MOST_STEPS {
        // A stop is checked before the brain is asked for another action.
        if control.stopped() {
            return answered(finish(&done), details);
        }
        let mut context = super::context(shared, given);
        context.turn_step = step;
        context.turn_length = Some(said.chars().count());
        let planner = Planner {
            adapters: Planner::of(&shared.config, &room),
            falls_back_to_rules: step == 0,
        };
        let mut planned = planner.plan(&request, &context, &halted).await;
        if !live() {
            planned
                .refused
                .push("the turn was cancelled before the plan came: nothing done".into());
            Record::new(&request, &planned).keep(home);
            let talk = if control.cancelled() {
                Talk::None
            } else {
                finish(&done)
            };
            return answered(talk, details);
        }
        Record::new(&request, &planned).keep(home);
        if let Some(refusal) = super::rules::acting_refusal(&planned, step) {
            return answered(after(&done, Talk::reply(refusal)), details);
        }
        if planned.by == "rules"
            && let Some(reason) = setting_refusal(&planned.refused)
        {
            let talk = Talk::reply(format!("I couldn't use that setting: {reason}."));
            return answered(after(&done, talk), details);
        }
        // Rules only stand in for the brain on the user's own words: a later step they planned
        // is a guess.
        if step > 0 && planned.by == "rules" {
            break;
        }
        let plan = &planned.plan;
        if matches!(plan.action, Action::ReadJob | Action::Research) {
            let talk = Talk::reply("Oby can't read jobs or look things up on this runner yet.");
            return answered(after(&done, talk), details);
        }
        if matches!(plan.action, Action::ReplyOnly | Action::AskUser) {
            details = plan.details.clone();
        }
        let acting = plan.action.acts();
        // The same action twice in one turn: it's done; the brain only repeated itself.
        if acting && !taken.insert(plan.signature()) {
            break;
        }
        if !acting {
            let talk = actions::answer(shared, &planned, asked, &live).await;
            return answered(after(&done, talk), details);
        }
        let outcome = act(shared, control, plan, step + 1).await;
        if !outcome.text().is_empty() {
            done.push(outcome.text().to_owned());
        }
        // An action that couldn't happen ends the turn: the user hears why.
        if outcome.failed() {
            break;
        }
        if Instant::now() >= deadline {
            done.push(AS_FAR_AS.into());
            break;
        }
        request = continued(said, &done);
    }
    answered(finish(&done), details)
}

/// Does one action that changes something, with its step events around it (`Desk.step`).
async fn act(shared: &Arc<Shared>, control: &Control, plan: &Plan, index: usize) -> Outcome {
    let text = actions::step_text(shared, plan);
    step(shared, control, index, plan.action, &text, "running");
    let outcome = actions::act(shared, plan).await;
    let state = if outcome.failed() { "failed" } else { "done" };
    step(shared, control, index, plan.action, &text, state);
    outcome
}

/// A `step` event: one action of the turn, as it starts and ends.
pub fn step(
    shared: &Shared,
    control: &Control,
    index: usize,
    action: Action,
    text: &str,
    state: &str,
) {
    shared.events.send(
        "step",
        json!({"turn": control.turn, "conversation": control.conversation, "index": index,
               "action": action.as_str(), "text": text, "state": state,
               "at": obi_protocol::time::format(obi_protocol::time::now())}),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ConversationTests.wordsThatCancelAreKnown
    #[test]
    fn words_that_cancel_are_known() {
        for words in [
            "never mind",
            "Never mind!",
            "nevermind",
            "stop",
            "STOP.",
            "cancel",
            "cancel that",
            "forget it",
            "wait",
            "no, wait",
        ] {
            assert!(cancels(words), "{words}");
        }
        for words in [
            "stop everything",
            "stop the vault job",
            "cancel the review",
            "never mind that, review PR 12",
            "how is it going?",
        ] {
            assert!(!cancels(words), "{words}");
        }
    }

    #[test]
    fn what_was_done_comes_first() {
        let done = vec!["Stopped Vault secrets.".to_owned()];
        assert_eq!(
            after(&done, Talk::reply("")),
            Talk::reply("Stopped Vault secrets.")
        );
        assert_eq!(
            after(&done, Talk::reply("Stopped Vault secrets.")),
            Talk::reply("Stopped Vault secrets.")
        );
        assert_eq!(
            after(&done, Talk::reply("Done.")),
            Talk::reply("Stopped Vault secrets. Done.")
        );
        assert_eq!(
            after(&done, Talk::None),
            Talk::reply("Stopped Vault secrets.")
        );
        assert_eq!(after(&[], Talk::None), Talk::None);
        assert!(continued("move them", &done).starts_with(
            "move them\n\n(Oby already did this for the request, step by step: Stopped Vault secrets.\n"
        ));
        assert_eq!(
            setting_refusal(&["claude plan refused (maxRunning goes from 1 to 20): {}".into()]),
            Some("maxRunning goes from 1 to 20".into())
        );
        assert_eq!(setting_refusal(&["claude failed: x".into()]), None);
    }

    #[test]
    fn a_new_turn_replaces_the_one_under_way_in_its_conversation_only() {
        let turns = Turns::default();
        let first = turns.begin("t1", "c1");
        let other = turns.begin("t2", "c2");
        let second = turns.begin("t3", "c1");
        assert!(first.cancelled() && !first.stopped());
        assert!(other.live() && second.live());
        assert!(turns.stop(Some("c2")));
        assert!(other.stopped() && second.live());
        turns.end(&second);
        assert!(!turns.cancel(Some("c3")));
        assert_eq!(turns.latest_conversation(), Some("c2".into()));
    }
}
