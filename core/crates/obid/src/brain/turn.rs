//! One turn of the conversation, like Claude Code's loop (`Desk.plan`): the brain picks one
//! action, obid does it and tells the brain what happened, and the brain picks the next, until
//! the request is done ("Deskree is full, move its jobs to Personal and Codex" is several
//! moves). It ends on an answer, an action it already took, one that couldn't happen, a later
//! step only rules could plan, eight actions, or the turn's budget, and says which as an [`End`]
//! (#538). Before it answers, it checks that everything the user named was handled, and asks
//! the brain once more when it wasn't (#539). Each action that changes something is a `step`
//! event when it starts and when it ends; Stop finishes the action under way and starts nothing
//! more.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use serde_json::json;

use super::actions::{self, Asked, Outcome, Talk};
use super::find::{self, Finds};
use super::orchestrator::{self, Orchestration};
use super::plan::{Action, Plan};
use super::planner::{LEAST, Planner, Record, Room};
use super::read::{self, JobReads};
use super::research;
use super::rules::{self, Number};
use crate::api::Shared;
use crate::conversation::Turn;

/// The most actions one turn takes.
pub const MOST_STEPS: usize = 8;
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

/// What a conversation's last turn looked up, for a "continue" to pick up (#632).
#[derive(Debug, Clone)]
pub struct Carried {
    /// The words the lookups were for.
    pub said: String,
    pub entries: Vec<(String, super::plan::Lookup, research::Found)>,
}

/// The most conversations whose last research is kept.
const CARRIED: usize = 20;

/// The turns under way.
#[derive(Debug, Default)]
pub struct Turns {
    underway: Mutex<Vec<Arc<Control>>>,
    // ponytail: in memory, so a restart forgets it; "continue" then looks things up again.
    carried: Mutex<Vec<(String, Carried)>>,
}

impl Turns {
    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Arc<Control>>> {
        self.underway.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Keeps what `conversation`'s turn looked up, or forgets it when it looked nothing up.
    fn carry(&self, conversation: &str, carried: Option<Carried>) {
        let mut kept = self.carried.lock().unwrap_or_else(|e| e.into_inner());
        kept.retain(|(id, _)| id != conversation);
        if let Some(carried) = carried {
            kept.push((conversation.to_owned(), carried));
        }
        if kept.len() > CARRIED {
            kept.remove(0);
        }
    }

    fn carried(&self, conversation: &str) -> Option<Carried> {
        self.carried
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .find(|(id, _)| id == conversation)
            .map(|(_, carried)| carried.clone())
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
        // A user's words preempt the event orchestrator's turn: it stops after the action under
        // way (#590).
        if conversation != super::orchestrator::CONVERSATION {
            for event in underway
                .iter()
                .filter(|c| c.conversation == super::orchestrator::CONVERSATION)
            {
                event.stopped.store(true, Ordering::SeqCst);
            }
        }
        underway.push(control.clone());
        control
    }

    /// A turn in `conversation` only when none is under way there, checked as it begins: a
    /// supervisor turn (super::supervisor) never replaces the owner's.
    pub fn begin_if_idle(&self, turn: &str, conversation: &str) -> Option<Arc<Control>> {
        let mut underway = self.lock();
        if underway.iter().any(|c| c.conversation == conversation) {
            return None;
        }
        let control = Arc::new(Control {
            turn: turn.into(),
            conversation: conversation.into(),
            stopped: AtomicBool::new(false),
            cancelled: AtomicBool::new(false),
        });
        underway.push(control.clone());
        Some(control)
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

    /// Whether a user's turn is under way: the event orchestrator waits for it (#590).
    pub fn user_turn_underway(&self) -> bool {
        self.lock()
            .iter()
            .any(|c| c.conversation != super::orchestrator::CONVERSATION)
    }

    /// Whether a turn is under way in `conversation`: a supervisor turn waits for it to end.
    pub fn underway_in(&self, conversation: &str) -> bool {
        self.lock().iter().any(|c| c.conversation == conversation)
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
    .contains(&plain(said).as_str())
}

/// Words that ask Oby to pick up its last turn (#632): "continue", "go on", "keep going".
pub fn continues(said: &str) -> bool {
    [
        "continue",
        "continue please",
        "please continue",
        "go on",
        "keep going",
        "carry on",
    ]
    .contains(&plain(said).as_str())
}

/// `said` in lower-case words, with no punctuation.
fn plain(said: &str) -> String {
    let cleaned: String = said
        .to_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_lowercase() || c == '\'' || c == ' ' {
                c
            } else {
                ' '
            }
        })
        .collect();
    cleaned.split_whitespace().collect::<Vec<_>>().join(" ")
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

/// How a turn that looked things up says what's left (#615).
const PICK_UP: &str = "say “continue” to pick up from there.";

/// What a turn ended with when the brain's words didn't end it (#615): what it did, else what it
/// `looked` at, then what's left. A cancelled turn says nothing, and so does one stopped before it
/// did or looked at anything.
fn finish(end: &End, done: &[String], looked: &[String]) -> Talk {
    if *end == End::Cancelled {
        return Talk::None;
    }
    let mut words = done.join(" ");
    if words.is_empty() && !looked.is_empty() {
        let looked = format!("Oby {}", listed(looked));
        words = match end {
            End::Stopped => format!("{looked}, then stopped."),
            End::BrainFailed => format!("{looked}, then couldn't think it through: {PICK_UP}"),
            End::Repeated => format!("{looked}, then kept going over the same ground: {PICK_UP}"),
            _ => format!("{looked}."),
        };
    } else if words.is_empty() && *end == End::BrainFailed {
        words = "Oby couldn't think that through: say it again.".into();
    }
    if matches!(end, End::BudgetSpent | End::MostSteps) {
        words = format!("{words} {AS_FAR_AS}").trim_start().to_owned();
    }
    if words.is_empty() {
        Talk::None
    } else {
        Talk::reply(words)
    }
}

/// Adds what the turn looked at, once; an event turn, which `speaks` to no one, keeps none.
fn look(looked: &mut Vec<String>, speaks: bool, words: String) {
    if speaks && !looked.contains(&words) {
        looked.push(words);
    }
}

/// Counts a read or lookup the brain asked for again: the second one ends the turn (#632), the
/// first having told it to answer from what's in work.md.
fn repeated(repeats: &mut usize) -> bool {
    *repeats += 1;
    *repeats >= 2
}

/// "a", "a and b", "a, b and c", "a, b, c, d and 2 more lookups".
fn listed(things: &[String]) -> String {
    let mut shown: Vec<String> = things.iter().take(4).cloned().collect();
    if things.len() > 4 {
        shown.push(format!("{} more lookups", things.len() - 4));
    }
    match shown.as_slice() {
        [rest @ .., last] if !rest.is_empty() => format!("{} and {last}", rest.join(", ")),
        _ => shown.concat(),
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

/// Why a turn ended (#538), as Claude Code's loop records why it stopped (`next_turn`,
/// `max_turns`, `aborted`…): the loop, its step events and its tests go by this, never by the
/// words the user hears, which a clearer message or a translation can change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum End {
    /// The brain answered: a reply, or nothing more to say once the work was done.
    Answered,
    /// The brain asked the user something.
    AskedUser,
    /// The plan started these jobs, by id.
    StartedJobs(Vec<String>),
    /// An action couldn't happen, or the plan's jobs couldn't start.
    CouldNot,
    /// An action didn't say which job or item: the user is asked to.
    NeedsWhich,
    /// The brain planned an action the turn already took.
    Repeated,
    /// The turn's budget ran out.
    BudgetSpent,
    /// Stop: the action under way finished, and nothing more started.
    Stopped,
    /// Cancelled, or replaced by new words: nothing more happens, and the answer is none.
    Cancelled,
    /// The brain couldn't plan, and rules stood in.
    BrainFailed,
    /// The turn took its eight actions.
    MostSteps,
    /// The completion check's one extra step went on to another action or a read: the turn
    /// asks no more (#539).
    Checked,
}

impl End {
    pub fn as_str(&self) -> &'static str {
        match self {
            End::Answered => "answered",
            End::AskedUser => "asked_user",
            End::StartedJobs(_) => "started_jobs",
            End::CouldNot => "could_not",
            End::NeedsWhich => "needs_which",
            End::Repeated => "repeated",
            End::BudgetSpent => "budget_spent",
            End::Stopped => "stopped",
            End::Cancelled => "cancelled",
            End::BrainFailed => "brain_failed",
            End::MostSteps => "most_steps",
            End::Checked => "checked",
        }
    }
}

/// A step's state, as its `step` event says it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Running,
    Done,
    Failed,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Running => "running",
            State::Done => "done",
            State::Failed => "failed",
        }
    }
}

/// What an action's outcome means for its step and for the turn: one that happened goes on to
/// the next step; one that didn't fails its step and ends the turn, saying why.
pub fn settle(outcome: &Outcome) -> (State, Option<End>) {
    match outcome {
        Outcome::Done(_) | Outcome::Started(..) => (State::Done, None),
        Outcome::Failed(_) => (State::Failed, Some(End::CouldNot)),
        Outcome::NeedsWhich(_) => (State::Failed, Some(End::NeedsWhich)),
    }
}

/// Why a turn whose plan answered ended: a question, the jobs it started, or a reply.
fn answered_end(plan: &Plan, talk: &Talk, researched: bool, control: &Control) -> End {
    if control.cancelled() {
        return End::Cancelled;
    }
    match talk {
        // Stopped while the jobs' issues were read: nothing started.
        Talk::None if plan.action == Action::Dispatch && control.stopped() => End::Stopped,
        Talk::Question { .. } => End::AskedUser,
        Talk::Reply { jobs, .. } if !jobs.is_empty() => End::StartedJobs(
            jobs.iter()
                .filter_map(|job| job["id"].as_str().map(str::to_owned))
                .collect(),
        ),
        // Jobs research found wait in the inbox; others that didn't start say why.
        _ if plan.action == Action::Dispatch && !researched => End::CouldNot,
        _ => End::Answered,
    }
}

/// Something the user's words name, which the turn is to handle (#539).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Named {
    /// An issue, pull request or epic.
    Number(Number),
    /// A repository, by its full name.
    Repo(String),
    /// A job of the briefing, by its title, with its issue and pull request.
    Job {
        id: String,
        title: String,
        numbers: Vec<i64>,
    },
}

impl Named {
    /// How Oby says it: "#18", "PR #33", "fixture-app", "Vault secrets".
    fn label(&self) -> String {
        match self {
            Named::Number(number) => number.label(),
            Named::Repo(repo) => repo.rsplit('/').next().unwrap_or(repo).to_owned(),
            Named::Job { title, .. } => title.clone(),
        }
    }
}

/// What the user's words name: the numbers and repositories rules read in them, and the jobs of
/// the briefing by their titles. The assistant's own name is how people talk to it, so a
/// repository named like it ("Oby, fix #12") isn't counted.
fn asked_for(shared: &Shared, said: &str, context: &super::plan::Context) -> Vec<Named> {
    let mut named: Vec<Named> = rules::numbers(said)
        .into_iter()
        .map(Named::Number)
        .collect();
    named.extend(
        rules::repos_named(&rules::words(said), &context.repos)
            .into_iter()
            .filter(|repo| {
                let own = repo.rsplit('/').next().unwrap_or(repo).to_lowercase();
                own != "oby" && own != "obi"
            })
            .map(|repo| Named::Repo(repo.clone())),
    );
    for id in &context.movable {
        let Some(job) = shared.jobs.get(id) else {
            continue;
        };
        let Some(title) = job
            .title
            .as_deref()
            .map(str::trim)
            .filter(|t| t.chars().count() >= 3)
        else {
            continue;
        };
        if says(said, title) {
            named.push(Named::Job {
                id: job.id.clone(),
                title: title.to_owned(),
                numbers: job
                    .issue
                    .into_iter()
                    .chain(job.pr)
                    .map(|n| n as i64)
                    .collect(),
            });
        }
    }
    named
}

/// Whether `text` says `phrase` as words of its own, whatever the case.
fn says(text: &str, phrase: &str) -> bool {
    let text = text.to_lowercase();
    let phrase = phrase.to_lowercase();
    text.match_indices(&phrase).any(|(at, _)| {
        let before = text[..at].chars().next_back();
        let after = text[at + phrase.len()..].chars().next();
        !before.is_some_and(char::is_alphanumeric) && !after.is_some_and(char::is_alphanumeric)
    })
}

/// What the turn acted on (#539): the work its plans started, and the jobs its actions named.
#[derive(Debug, Default)]
pub struct Handled {
    numbers: HashSet<i64>,
    repos: HashSet<String>,
    jobs: HashSet<String>,
    /// stop_agent with `all`.
    all_jobs: bool,
}

impl Handled {
    /// A dispatch plan: each job's repository, issue, pull request and epic.
    fn dispatched(&mut self, plan: &Plan) {
        for d in &plan.dispatches {
            self.numbers
                .extend(d.issue.into_iter().chain(d.pr).chain(d.epic));
            self.repos.insert(d.repo.clone());
        }
    }

    /// An action on jobs: each job, its repository, issue and pull request.
    fn acted(&mut self, shared: &Shared, plan: &Plan) {
        self.all_jobs |= plan.all == Some(true);
        for id in plan.named() {
            self.jobs.insert(id.clone());
            if let Some(job) = shared.jobs.get(id) {
                self.repos.insert(job.repo.clone());
                self.numbers
                    .extend(job.issue.into_iter().chain(job.pr).map(|n| n as i64));
            }
        }
    }

    /// Whether the turn did anything: a turn that only answered isn't checked.
    fn any(&self) -> bool {
        self.all_jobs || !self.numbers.is_empty() || !self.repos.is_empty() || !self.jobs.is_empty()
    }
}

/// What of `named` the turn neither acted on nor mentioned in `reply`.
fn unhandled(named: &[Named], handled: &Handled, reply: &str) -> Vec<Named> {
    let mentioned: HashSet<i64> = rules::numbers(reply).iter().map(|n| n.value()).collect();
    let done = |n: &i64| handled.numbers.contains(n) || mentioned.contains(n);
    let words = rules::words(reply);
    named
        .iter()
        .filter(|thing| match thing {
            Named::Number(number) => !done(&number.value()),
            Named::Repo(repo) => {
                !handled.repos.contains(repo)
                    && rules::repos_named(&words, std::slice::from_ref(repo)).is_empty()
            }
            Named::Job { id, title, numbers } => {
                !handled.all_jobs
                    && !handled.jobs.contains(id)
                    && !numbers.iter().any(done)
                    && !says(reply, title)
            }
        })
        .cloned()
        .collect()
}

/// What an answer says, for the completion check.
fn spoken(talk: &Talk) -> &str {
    match talk {
        Talk::Reply { text, .. } => text,
        Talk::Question { question, .. } => &question.text,
        Talk::None => "",
    }
}

/// The brain's one more step when something named isn't handled (#539), after what was done.
pub fn unfinished(said: &str, done: &[String], missing: &[Named]) -> String {
    let labels: Vec<String> = missing.iter().map(Named::label).collect();
    let so_far = if done.is_empty() {
        said.to_owned()
    } else {
        continued(said, done)
    };
    format!(
        "{so_far}\n\nYou haven't handled: {}. Plan it, or reply saying why not.",
        labels.join(", ")
    )
}

/// "I didn't start #18.", in Oby's words, for what the brain left out even when asked again.
pub fn not_started(missing: &[Named]) -> String {
    let (jobs, work): (Vec<&Named>, Vec<&Named>) =
        missing.iter().partition(|n| matches!(n, Named::Job { .. }));
    let mut lines = vec![];
    if !work.is_empty() {
        lines.push(format!("I didn't start {}.", either(&work)));
    }
    if !jobs.is_empty() {
        lines.push(format!("I didn't act on {}.", either(&jobs)));
    }
    lines.join(" ")
}

/// "a", "a or b", "a, b or c".
fn either(things: &[&Named]) -> String {
    let labels: Vec<String> = things.iter().map(|n| n.label()).collect();
    match labels.as_slice() {
        [] => String::new(),
        [one] => one.clone(),
        [rest @ .., last] => format!("{} or {last}", rest.join(", ")),
    }
}

/// The turn's end after the completion check's step: the jobs started before it join the answer,
/// and what's still left out is said.
fn checked(
    end: End,
    talk: Talk,
    earlier: Vec<serde_json::Value>,
    named: &[Named],
    handled: &Handled,
) -> (End, Talk) {
    let end = match end {
        End::StartedJobs(ids) => End::StartedJobs(
            earlier
                .iter()
                .filter_map(|job| job["id"].as_str().map(str::to_owned))
                .chain(ids)
                .collect(),
        ),
        other => other,
    };
    let Talk::Reply { text, jobs } = talk else {
        // Cancelled answers nothing; a question asks about what's left.
        return (end, talk);
    };
    let missing = unhandled(named, handled, &text);
    let text = match (text.is_empty(), missing.is_empty()) {
        (_, true) => text,
        (true, false) => not_started(&missing),
        (false, false) => format!("{text} {}", not_started(&missing)),
    };
    (
        end,
        Talk::Reply {
            text,
            jobs: earlier.into_iter().chain(jobs).collect(),
        },
    )
}

/// `talk` with the cards of the jobs its actions started first (a follow-up).
fn with_jobs(talk: Talk, started: Vec<serde_json::Value>) -> Talk {
    match talk {
        Talk::Reply { text, jobs } if !started.is_empty() => Talk::Reply {
            text,
            jobs: started.into_iter().chain(jobs).collect(),
        },
        talk => talk,
    }
}

/// What a turn answers, the longer Markdown under it when the brain gave some, and why it ended.
pub struct Answered {
    pub talk: Talk,
    pub details: Option<String>,
    pub end: End,
}

/// Runs one turn for `said`, the conversation so far being `given`.
pub async fn run(
    shared: &Arc<Shared>,
    said: &str,
    given: &[Turn],
    asked: &Asked<'_>,
    control: &Arc<Control>,
) -> Answered {
    // "Work on the roadmap" and the like are the Lead's (#589): it reads the board, not the
    // briefing.
    if super::lead::leads(said) {
        // It says it's thinking first, like every turn (#592).
        let thought = "Reading the roadmap";
        super::thinking(shared, control, 1, thought, State::Running);
        let answered = super::lead::run(shared, said, asked, control).await;
        let state = match answered.end {
            End::Cancelled | End::Stopped | End::BudgetSpent => State::Failed,
            _ => State::Done,
        };
        super::thinking(shared, control, 1, thought, state);
        return answered;
    }
    run_with(shared, said, given, asked, control, None).await
}

/// Runs one turn of the event orchestrator (#590): no user's words, the events in the prompt,
/// and obid's checks on every plan before it acts.
pub async fn run_event(
    shared: &Arc<Shared>,
    orchestration: &Orchestration,
    asked: &Asked<'_>,
    control: &Arc<Control>,
) -> Answered {
    run_with(shared, "", &[], asked, control, Some(orchestration)).await
}

async fn run_with(
    shared: &Arc<Shared>,
    said: &str,
    given: &[Turn],
    asked: &Asked<'_>,
    control: &Arc<Control>,
    orchestration: Option<&Orchestration>,
) -> Answered {
    let room = Room {
        root: shared.config.home.join("plans"),
        jobs: shared.jobs.clone(),
    };
    let home = &shared.config.home;
    let deadline = Instant::now() + shared.config.turn_budget;
    let live = || control.live();
    let halted = || !control.live();
    // The turn says it's thinking before anything else (#592): the first brain call's line now,
    // each later call's as it begins.
    let mut thought = "Thinking".to_owned();
    super::thinking(shared, control, 1, &thought, State::Running);
    let mut announced = true;
    let mut acknowledged = false;
    // The turn's own word, which fences everything quoted for the brain.
    let nonce = super::briefing::nonce();
    let mut done: Vec<String> = vec![];
    // What the turn looked at, in Oby's words, for an end the brain didn't answer (#615). An
    // event turn keeps none: its answer is for the log.
    let mut looked: Vec<String> = vec![];
    let speaks = orchestration.is_none();
    // Reads and lookups the brain asked for again: the second time, the turn ends (#632).
    let mut repeats = 0;
    let mut taken: HashSet<String> = HashSet::new();
    let mut details: Option<String> = None;
    let mut reads = JobReads::default();
    let mut finds = Finds::default();
    // The jobs this turn read, which an event turn must have done before it acts (#590).
    let mut read_ids: HashSet<String> = HashSet::new();
    let mut research = research::Log::default();
    // "continue" picks up what the last turn looked up, quoted again (#632).
    let mut asked_for_words = said.to_owned();
    let mut told = said.to_owned();
    if orchestration.is_none()
        && continues(said)
        && let Some(carried) = shared.turns.carried(&control.conversation)
    {
        told = format!(
            "{said}\n\n(What Oby looked up for “{}” last turn is quoted in work.md: go on from it, and look up only what's still missing.)",
            carried.said
        );
        research = research::Log::carry(carried.entries);
        asked_for_words = carried.said;
    }
    let mut request = told.clone();
    let tools = research::Tools::new(shared.jobs.clone());
    // Work the brain wants after looking things up waits for the user's Start.
    let mut researched = false;
    // The own instructions of the repositories the turn names, read once from their clones (#543).
    let own = super::own(shared, said, given, &nonce).await;
    let mut step = 0;
    // What the user's words name, what the turn did about it, and whether the brain was asked
    // once more (#539).
    let mut named: Option<Vec<Named>> = None;
    let mut handled = Handled::default();
    let mut checking = false;
    // The jobs started before the completion check, for the answer.
    let mut earlier: Vec<serde_json::Value> = vec![];
    let (end, talk) = 'turn: loop {
        let (end, talk) = 'step: {
            // A stop is checked before the brain is asked for another action.
            if control.stopped() {
                break 'step (End::Stopped, finish(&End::Stopped, &done, &looked));
            }
            // The completion check's one extra step may come after the eighth.
            if step >= MOST_STEPS && !checking {
                break 'step (End::MostSteps, finish(&End::MostSteps, &done, &looked));
            }
            if Instant::now() >= deadline {
                break 'step (End::BudgetSpent, finish(&End::BudgetSpent, &done, &looked));
            }
            let mut context = super::context(shared, &control.conversation, given, &nonce);
            context.turn_step = step;
            context.turn_length = Some(said.chars().count());
            context.said = said.to_owned();
            context.found = research.found();
            if let Some(orchestration) = orchestration {
                context.orchestrator = true;
                context.orchestrator_context = Some(orchestration.context(&nonce));
            }
            // What the turn read and looked up goes into the next step's quoted file.
            context.quoted = research.quoted(
                finds.quoted(
                    reads.quoted(
                        super::briefing::with_own(context.quoted.take(), &own, &nonce),
                        &nonce,
                    ),
                    &nonce,
                ),
                &nonce,
            );
            let planner = Planner {
                adapters: Planner::of(&shared.config, &room),
                // Rules never stand in for an event turn: they read a person's words.
                falls_back_to_rules: step == 0 && orchestration.is_none(),
                deadline: Some(deadline),
            };
            if named.is_none() {
                named = Some(asked_for(shared, said, &context));
            }
            if !announced {
                super::thinking(shared, control, step + 1, &thought, State::Running);
            }
            announced = false;
            let mut planned = planner.plan(&request, &context, &halted).await;
            let thought_state = if live() && Instant::now() < deadline {
                State::Done
            } else {
                State::Failed
            };
            super::thinking(shared, control, step + 1, &thought, thought_state);
            if !live() {
                planned
                    .refused
                    .push("the turn was cancelled before the plan came: nothing done".into());
                Record::new(&request, &planned).of(control, step).keep(home);
                if control.cancelled() {
                    break 'step (End::Cancelled, Talk::None);
                }
                break 'step (End::Stopped, finish(&End::Stopped, &done, &looked));
            }
            // The turn's budget ran out while the brain thought: its plan does nothing.
            if Instant::now() >= deadline {
                planned
                    .refused
                    .push("the plan came after the turn's budget: nothing done".into());
                Record::new(&request, &planned).of(control, step).keep(home);
                break 'step (End::BudgetSpent, finish(&End::BudgetSpent, &done, &looked));
            }
            Record::new(&request, &planned).of(control, step).keep(home);
            if let Some(refusal) = super::rules::acting_refusal(&planned, step) {
                break 'step (End::BrainFailed, after(&done, Talk::reply(refusal)));
            }
            if planned.by == "rules"
                && let Some(reason) = setting_refusal(&planned.refused)
            {
                let talk = Talk::reply(format!("I couldn't use that setting: {reason}."));
                break 'step (End::CouldNot, after(&done, talk));
            }
            // Rules only stand in for the brain on the user's own words: a later step they planned
            // is a guess. With too little time left for any brain to think, it's the budget that
            // ended the turn, not the brain (#615).
            if step > 0 && planned.by == "rules" {
                let end = if deadline.saturating_duration_since(Instant::now()) <= LEAST {
                    End::BudgetSpent
                } else {
                    End::BrainFailed
                };
                let talk = finish(&end, &done, &looked);
                break 'step (end, talk);
            }
            let plan = &planned.plan;
            let index = step + 1;
            step += 1;
            // obid's checks on an event turn's plan, before it reads or acts (#590).
            if let Some(orchestration) = orchestration
                && let Err(escalation) = orchestration.check(
                    plan,
                    &read_ids,
                    obi_protocol::time::now(),
                    |id| {
                        shared.link.item(id).map(|i| orchestrator::ItemView {
                            open: i.done.is_none(),
                            job: i.job,
                            kind: i.kind,
                            options: i.options,
                        })
                    },
                    |id| {
                        crate::failures::get(home, id)
                            .map(|r| r.job)
                            .filter(|j| !j.is_empty())
                    },
                    |id| shared.jobs.get(id).map(|j| orchestrator::signature(&j)),
                )
            {
                orchestration.escalate(shared, &escalation);
                break 'step (End::CouldNot, after(&done, Talk::reply(escalation.reply)));
            }
            let so_far = || {
                if done.is_empty() {
                    told.clone()
                } else {
                    continued(&told, &done)
                }
            };
            // The chat reads before it answers (#302): what's read is in the next step's file.
            if plan.action == Action::ReadJob {
                let id = plan.named().first().map(String::as_str);
                let again = id.is_some_and(|id| reads.sections.iter().any(|(r, _)| r == id));
                read_ids.extend(plan.named().iter().cloned());
                let before = reads.sections.len();
                reads.read(id, |id| {
                    shared
                        .jobs
                        .get(id)
                        .map(|job| read::section(&job, &shared.config.home))
                });
                let title = id
                    .and_then(|id| shared.jobs.get(id))
                    .and_then(|job| job.title.filter(|t| !t.trim().is_empty()));
                if reads.sections.len() > before {
                    let job = title
                        .clone()
                        .unwrap_or_else(|| format!("job {}", id.unwrap_or("")));
                    look(&mut looked, speaks, format!("read {job}"));
                }
                if Instant::now() >= deadline {
                    break 'step (End::BudgetSpent, finish(&End::BudgetSpent, &done, &looked));
                }
                if checking {
                    break 'step (End::Checked, finish(&End::Checked, &done, &looked));
                }
                if again && repeated(&mut repeats) {
                    break 'step (End::Repeated, finish(&End::Repeated, &done, &looked));
                }
                thought = title.map_or_else(
                    || "Looking at the jobs".to_owned(),
                    |t| format!("Looking at {t}"),
                );
                request = finds.continued(&reads.continued(&so_far()));
                continue 'turn;
            }
            // The chat finds past conversations before it answers (#593), never the one asking.
            if plan.action == Action::FindConversation {
                let again = finds.has(plan.message.as_deref());
                if let Some(words) = plan.message.as_deref().filter(|w| !w.trim().is_empty()) {
                    look(
                        &mut looked,
                        speaks,
                        format!("searched past conversations for “{}”", words.trim()),
                    );
                }
                finds.find(plan.message.as_deref(), |words| {
                    shared.conversations.search(
                        words,
                        Some(asked.conversation),
                        None,
                        find::CONVERSATIONS,
                    )
                });
                if Instant::now() >= deadline {
                    break 'step (End::BudgetSpent, finish(&End::BudgetSpent, &done, &looked));
                }
                if checking {
                    break 'step (End::Checked, finish(&End::Checked, &done, &looked));
                }
                if again && repeated(&mut repeats) {
                    break 'step (End::Repeated, finish(&End::Repeated, &done, &looked));
                }
                thought = "Going over past conversations".to_owned();
                request = finds.continued(&reads.continued(&so_far()));
                continue 'turn;
            }
            if plan.action == Action::Research {
                let lookups = plan.lookups.clone().unwrap_or_default();
                researched |= !lookups.is_empty();
                let texts: Vec<String> = lookups.iter().map(research::step_text).collect();
                let text = if texts.is_empty() {
                    "Looking up context".to_owned()
                } else {
                    texts.join(", ")
                };
                step_event(
                    shared,
                    control,
                    index,
                    Action::Research,
                    &text,
                    State::Running,
                );
                let again = research.has_all(&lookups);
                // Stopped or cancelled: no lookup runs.
                if control.live() && Instant::now() < deadline {
                    let before = research.entries.len();
                    research.run(&lookups, &tools, said).await;
                    for (_, lookup, _) in &research.entries[before..] {
                        look(&mut looked, speaks, research::looked(lookup));
                    }
                }
                let cut = if control.cancelled() {
                    Some(End::Cancelled)
                } else if control.stopped() {
                    Some(End::Stopped)
                } else if Instant::now() >= deadline {
                    Some(End::BudgetSpent)
                } else {
                    None
                };
                let state = if cut.is_some() {
                    State::Failed
                } else {
                    State::Done
                };
                step_event(shared, control, index, Action::Research, &text, state);
                if let Some(end) = cut {
                    let talk = finish(&end, &done, &looked);
                    break 'step (end, talk);
                }
                if checking {
                    break 'step (End::Checked, finish(&End::Checked, &done, &looked));
                }
                if again && repeated(&mut repeats) {
                    break 'step (End::Repeated, finish(&End::Repeated, &done, &looked));
                }
                thought = "Going over what it found".to_owned();
                request = research.continued(&finds.continued(&reads.continued(&so_far())));
                continue 'turn;
            }
            if matches!(plan.action, Action::ReplyOnly | Action::AskUser) {
                details = plan.details.clone();
            }
            let acting = plan.action.acts();
            // The same action twice in one turn: it's done; the brain only repeated itself.
            if acting && !taken.insert(plan.signature()) {
                break 'step (End::Repeated, finish(&End::Repeated, &done, &looked));
            }
            if !acting {
                // The reply goes out as soon as the plan is checked, before its jobs are made
                // (#592); a turn's other answers are said once they're known.
                if plan.action == Action::Dispatch && !acknowledged {
                    acknowledged = super::acknowledge(shared, control, &plan.reply);
                }
                let talk = actions::answer(shared, &planned, asked, researched, &live).await;
                if !acknowledged {
                    acknowledged = super::acknowledge(shared, control, spoken(&talk));
                }
                if plan.action == Action::Dispatch {
                    handled.dispatched(plan);
                }
                let end = if planned.by == "rules" {
                    End::BrainFailed
                } else {
                    answered_end(plan, &talk, researched, control)
                };
                break 'step (end, after(&done, talk));
            }
            // The orchestrator's message to a job is its own, about the error it read; a person's
            // message is their own words (#542).
            let words = match (orchestration, plan.action) {
                (Some(_), Action::MessageJob) => plan.message.clone().unwrap_or_default(),
                _ => said.to_owned(),
            };
            // Whose words they are: an event turn's are the brain's own, and a turn that looked
            // something up read what isn't the owner's.
            let source = match (orchestration, researched) {
                (Some(_), _) => crate::jobs::Source::Event,
                (None, true) => crate::jobs::Source::Untrusted,
                (None, false) => crate::jobs::Source::Owner,
            };
            let outcome = act(shared, control, plan, &words, index, source).await;
            handled.acted(shared, plan);
            // A follow-up it started: its card goes on the answer.
            if let Outcome::Started(_, job) = &outcome {
                earlier.push(job.clone());
            }
            if !outcome.text().is_empty() {
                done.push(outcome.text().to_owned());
            }
            // An action that didn't happen ends the turn: the user hears why.
            if let (_, Some(end)) = settle(&outcome) {
                let talk = finish(&end, &done, &looked);
                break 'step (end, talk);
            }
            if Instant::now() >= deadline {
                break 'step (End::BudgetSpent, finish(&End::BudgetSpent, &done, &looked));
            }
            if checking {
                break 'step (End::Checked, finish(&End::Checked, &done, &looked));
            }
            thought = "Deciding what's next".to_owned();
            request = finds.continued(&reads.continued(&continued(&told, &done)));
            continue 'turn;
        };
        // Before Oby answers, everything the user named was handled (#539): what's left goes
        // back to the brain once. Not after a failure, a stop or a spent budget, nor when the turn
        // did nothing (a question answered isn't checked).
        if !checking
            && matches!(end, End::Answered | End::StartedJobs(_) | End::Repeated)
            && handled.any()
        {
            let missing = unhandled(named.as_deref().unwrap_or(&[]), &handled, spoken(&talk));
            if !missing.is_empty() {
                if let Talk::Reply { text, jobs } = talk {
                    earlier.extend(jobs);
                    done = if text.is_empty() { vec![] } else { vec![text] };
                }
                request = finds.continued(&reads.continued(&unfinished(&told, &done, &missing)));
                thought = "Checking nothing was missed".to_owned();
                checking = true;
                continue 'turn;
            }
        }
        break (end, talk);
    };
    // Ended before its first call (stopped or cancelled meanwhile): the line it sent fails.
    if announced {
        super::thinking(shared, control, 1, &thought, State::Failed);
    }
    let (end, talk) = if checking {
        checked(
            end,
            talk,
            earlier,
            named.as_deref().unwrap_or(&[]),
            &handled,
        )
    } else {
        (end, with_jobs(talk, earlier))
    };
    if speaks {
        let carried = (!research.entries.is_empty()).then_some(Carried {
            said: asked_for_words,
            entries: research.entries,
        });
        shared.turns.carry(&control.conversation, carried);
    }
    tracing::info!("turn {} ended: {}", control.turn, end.as_str());
    Answered { talk, details, end }
}

/// Does one action that changes something, with its step events around it (`Desk.step`).
async fn act(
    shared: &Arc<Shared>,
    control: &Control,
    plan: &Plan,
    said: &str,
    index: usize,
    source: crate::jobs::Source,
) -> Outcome {
    let text = actions::step_text(shared, plan);
    step_event(shared, control, index, plan.action, &text, State::Running);
    let outcome = actions::act(shared, plan, said, source, &control.conversation).await;
    step_event(
        shared,
        control,
        index,
        plan.action,
        &text,
        settle(&outcome).0,
    );
    outcome
}

/// A `step` event: one action of the turn, as it starts and ends.
pub fn step_event(
    shared: &Shared,
    control: &Control,
    index: usize,
    action: Action,
    text: &str,
    state: State,
) {
    shared.events.send(
        "step",
        json!({"turn": control.turn, "conversation": control.conversation, "index": index,
               "action": action.as_str(), "text": text, "state": state.as_str(),
               "at": obi_protocol::time::format(obi_protocol::time::now())}),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A supervisor turn begins only where no turn is under way, and never cancels the owner's.
    #[test]
    fn a_supervisor_turn_never_replaces_the_owners() {
        let turns = Turns::default();
        let owner = turns.begin("t1", "c1");
        assert!(turns.begin_if_idle("s1", "c1").is_none());
        assert!(owner.live());
        let elsewhere = turns.begin_if_idle("s2", "c2").unwrap();
        assert!(turns.underway_in("c2"));
        turns.end(&elsewhere);
        turns.end(&owner);
        assert!(turns.begin_if_idle("s3", "c1").is_some());
    }

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

    /// #615: every end a user hears says what was done, else what was looked at, and what's left.
    #[test]
    fn a_turn_the_brain_did_not_answer_still_says_something() {
        let done = vec!["Stopped Vault secrets.".to_owned()];
        let looked: Vec<String> = ["searched oby for “gateway”", "read src/gateway.rs"]
            .map(String::from)
            .into();
        let said = |end: End, done: &[String], looked: &[String]| match finish(&end, done, looked) {
            Talk::Reply { text, .. } => text,
            other => format!("{other:?}"),
        };
        assert_eq!(
            said(End::BudgetSpent, &[], &looked),
            format!("Oby searched oby for “gateway” and read src/gateway.rs. {AS_FAR_AS}")
        );
        assert_eq!(
            said(End::BudgetSpent, &done, &looked),
            format!("Stopped Vault secrets. {AS_FAR_AS}")
        );
        assert_eq!(said(End::BudgetSpent, &[], &[]), AS_FAR_AS);
        assert_eq!(
            said(End::MostSteps, &done, &[]),
            format!("Stopped Vault secrets. {AS_FAR_AS}")
        );
        assert_eq!(
            said(End::BrainFailed, &[], &[]),
            "Oby couldn't think that through: say it again."
        );
        assert_eq!(said(End::BrainFailed, &done, &looked), done[0]);
        assert_eq!(
            said(End::Checked, &[], &looked[..1]),
            "Oby searched oby for “gateway”."
        );
        assert_eq!(finish(&End::Stopped, &[], &[]), Talk::None);
        assert_eq!(finish(&End::Cancelled, &done, &looked), Talk::None);
        let many: Vec<String> = (1..=6).map(|n| format!("read f{n}")).collect();
        assert_eq!(
            listed(&many),
            "read f1, read f2, read f3, read f4 and 2 more lookups"
        );
        assert!(
            continues("Continue.")
                && continues("keep going")
                && !continues("continue the vault job")
        );
    }

    /// #538's acceptance: what an action's step and the turn do comes from its outcome. Reworded
    /// replies (test doubles with other words, some starting as another kind's did) change
    /// nothing: a failed action fails its step and ends the turn, one that happened goes on.
    #[test]
    fn a_step_is_decided_by_its_outcome_never_by_its_words() {
        for text in [
            "Couldn't move it: obid can't yet.",
            "Say which job.",
            "That job isn't running any more.",
            "Started Vault secrets again.",
            "Erledigt.",
            "",
        ] {
            assert_eq!(
                settle(&Outcome::Done(text.into())),
                (State::Done, None),
                "{text}"
            );
            assert_eq!(
                settle(&Outcome::Failed(text.into())),
                (State::Failed, Some(End::CouldNot)),
                "{text}"
            );
            assert_eq!(
                settle(&Outcome::NeedsWhich(text.into())),
                (State::Failed, Some(End::NeedsWhich)),
                "{text}"
            );
        }
    }

    #[test]
    fn an_answer_ends_the_turn_with_what_it_was() {
        let control = Turns::default().begin("t1", "c1");
        let reply = Plan::of(Action::ReplyOnly, "");
        let dispatch = Plan::of(Action::Dispatch, "");
        let started = Talk::Reply {
            text: "Whatever it says.".into(),
            jobs: vec![json!({"id": "ab12cd34"}), json!({"id": "ef56ab78"})],
        };
        assert_eq!(
            answered_end(&dispatch, &started, false, &control),
            End::StartedJobs(vec!["ab12cd34".into(), "ef56ab78".into()])
        );
        let refused = Talk::reply("Whatever it says.");
        assert_eq!(
            answered_end(&dispatch, &refused, false, &control),
            End::CouldNot
        );
        // After research the jobs wait in the inbox for a Start.
        assert_eq!(
            answered_end(&dispatch, &refused, true, &control),
            End::Answered
        );
        assert_eq!(
            answered_end(&reply, &refused, false, &control),
            End::Answered
        );
        assert_eq!(
            answered_end(&reply, &Talk::None, false, &control),
            End::Answered
        );
        let question = Talk::Question {
            said: "x".into(),
            question: super::super::plan::Question {
                text: "Which?".into(),
                options: vec![],
                details: None,
                recommended: None,
                plan: None,
            },
        };
        assert_eq!(
            answered_end(&reply, &question, false, &control),
            End::AskedUser
        );
        let turns = Turns::default();
        let stopped = turns.begin("t2", "c2");
        turns.stop(None);
        assert_eq!(
            answered_end(&dispatch, &Talk::None, false, &stopped),
            End::Stopped
        );
        turns.cancel(None);
        assert_eq!(
            answered_end(&dispatch, &started, false, &stopped),
            End::Cancelled
        );
    }

    /// #539: what the user named is handled when the turn acted on it or the reply mentions it;
    /// what's left is said in Oby's words.
    #[test]
    fn what_was_named_and_left_out_is_said_in_obys_words() {
        let vault = Named::Job {
            id: "ab12cd34".into(),
            title: "Vault secrets".into(),
            numbers: vec![40],
        };
        let named = vec![
            Named::Number(Number::Issue(12)),
            Named::Number(Number::Pr(33)),
            Named::Repo("deskree-inc/tetrix-front-end".into()),
            vault.clone(),
        ];
        let mut handled = Handled::default();
        assert!(!handled.any());
        assert_eq!(unhandled(&named, &handled, "On it."), named);
        handled.numbers.insert(12);
        handled.repos.insert("deskree-inc/tetrix-front-end".into());
        assert_eq!(
            unhandled(&named, &handled, "On it."),
            [Named::Number(Number::Pr(33)), vault.clone()]
        );
        // Mentioned in the reply, whatever the case: handled.
        assert_eq!(
            unhandled(
                &named,
                &handled,
                "PR #33 waits for CI; vault secrets is running."
            ),
            []
        );
        // Part of a word isn't the job.
        assert_eq!(
            unhandled(
                &named,
                &handled,
                "PR #33 waits; the vault secretsmanager is up."
            ),
            std::slice::from_ref(&vault)
        );
        // A job is handled when its issue is, or when the turn stopped everything.
        handled.numbers.insert(40);
        assert_eq!(unhandled(&named, &handled, "#33"), []);
        let mut all = Handled {
            all_jobs: true,
            ..Handled::default()
        };
        assert!(all.any());
        assert_eq!(unhandled(std::slice::from_ref(&vault), &all, ""), []);
        all.all_jobs = false;
        assert_eq!(
            not_started(&[Named::Number(Number::Issue(18))]),
            "I didn't start #18."
        );
        assert_eq!(
            not_started(&named),
            "I didn't start #12, PR #33 or tetrix-front-end. I didn't act on Vault secrets."
        );
        assert_eq!(
            unfinished("fix #12 and #18", &[], &[Named::Number(Number::Issue(18))]),
            "fix #12 and #18\n\nYou haven't handled: #18. Plan it, or reply saying why not."
        );
    }

    /// #539: after the check's step, the jobs started before it join the answer, and what's still
    /// left out is said.
    #[test]
    fn the_answer_after_the_check_keeps_every_job_and_says_what_is_left() {
        let named = vec![
            Named::Number(Number::Issue(12)),
            Named::Number(Number::Issue(18)),
        ];
        let mut handled = Handled::default();
        handled.numbers.insert(12);
        let earlier = vec![json!({"id": "ab12cd34", "issue": 12})];
        let (end, talk) = checked(
            End::Answered,
            Talk::reply("On it. Claude Code is fixing #12."),
            earlier.clone(),
            &named,
            &handled,
        );
        assert_eq!(end, End::Answered);
        assert_eq!(
            talk,
            Talk::Reply {
                text: "On it. Claude Code is fixing #12. I didn't start #18.".into(),
                jobs: earlier.clone()
            }
        );
        handled.numbers.insert(18);
        let (end, talk) = checked(
            End::StartedJobs(vec!["ef56ab78".into()]),
            Talk::Reply {
                text: "On it.".into(),
                jobs: vec![json!({"id": "ef56ab78", "issue": 18})],
            },
            earlier,
            &named,
            &handled,
        );
        assert_eq!(
            end,
            End::StartedJobs(vec!["ab12cd34".into(), "ef56ab78".into()])
        );
        let Talk::Reply { text, jobs } = talk else {
            panic!("a reply");
        };
        assert_eq!(text, "On it.");
        assert_eq!(jobs.len(), 2);
        assert_eq!(
            checked(
                End::Cancelled,
                Talk::None,
                vec![],
                &named,
                &Handled::default()
            ),
            (End::Cancelled, Talk::None)
        );
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
