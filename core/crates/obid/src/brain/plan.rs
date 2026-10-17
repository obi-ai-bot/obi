//! What the brain may decide (Engine/Brain.swift, `Plan`): schema v1 from #31, every action with
//! its fields, the JSON schema the model fills with the choices it has right now, and why obid
//! refuses a plan (`Plan.problems`, the same refusal texts). There is no merge, push, approve or
//! publish action, and obid checks every plan before anything happens for it.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// How long a reply may be: a few short sentences, which the Mac also speaks.
pub const REPLY_LENGTH: usize = 400;
/// The most options a question offers.
pub const MOST_OPTIONS: usize = 3;
/// How many jobs one plan starts, at most.
pub const MOST_DISPATCHES: usize = 10;
/// The range of `maxRunning` (Engine/Jobs.swift, `JobSlots.range`).
pub const MAX_RUNNING: std::ops::RangeInclusive<i64> = 1..=20;

/// The actions, as the schema names them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Dispatch,
    AskUser,
    ReplyOnly,
    StopAgent,
    MoveJob,
    Ignore,
    /// The user answers a job's waiting permission (#134).
    AnswerPermission,
    /// The user changes how much jobs ask.
    SetMode,
    /// The chat reads a job before it answers (#302).
    ReadJob,
    /// The user changes the runner's settings in chat.
    SetSetting,
    /// The chat acts on jobs and the inbox (#300).
    RetryJob,
    DismissJob,
    AnswerInbox,
    StartNow,
    /// Only for the event orchestrator (#351).
    MessageJob,
    FixFailure,
    AskReviewAgain,
    /// Read-only context gathering before the chat answers or proposes work.
    Research,
}

impl Action {
    pub fn as_str(self) -> &'static str {
        match self {
            Action::Dispatch => "dispatch",
            Action::AskUser => "ask_user",
            Action::ReplyOnly => "reply_only",
            Action::StopAgent => "stop_agent",
            Action::MoveJob => "move_job",
            Action::Ignore => "ignore",
            Action::AnswerPermission => "answer_permission",
            Action::SetMode => "set_mode",
            Action::ReadJob => "read_job",
            Action::SetSetting => "set_setting",
            Action::RetryJob => "retry_job",
            Action::DismissJob => "dismiss_job",
            Action::AnswerInbox => "answer_inbox",
            Action::StartNow => "start_now",
            Action::MessageJob => "message_job",
            Action::FixFailure => "fix_failure",
            Action::AskReviewAgain => "ask_review_again",
            Action::Research => "research",
        }
    }

    /// The actions that change something, after which the brain plans the next step
    /// (`Desk.acting`).
    pub fn acts(self) -> bool {
        matches!(
            self,
            Action::StopAgent
                | Action::MoveJob
                | Action::AnswerPermission
                | Action::SetMode
                | Action::SetSetting
                | Action::RetryJob
                | Action::DismissJob
                | Action::AnswerInbox
                | Action::StartNow
                | Action::MessageJob
                | Action::FixFailure
                | Action::AskReviewAgain
        )
    }
}

/// The kinds of work. A kind the model makes up is an investigation, as in Swift.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", from = "String")]
pub enum Kind {
    Review,
    Fix,
    Build,
    Test,
    Investigate,
    Research,
}

impl From<String> for Kind {
    fn from(raw: String) -> Kind {
        match raw.as_str() {
            "review" => Kind::Review,
            "fix" => Kind::Fix,
            "build" => Kind::Build,
            "test" => Kind::Test,
            "research" => Kind::Research,
            _ => Kind::Investigate,
        }
    }
}

impl Kind {
    pub const ALL: [Kind; 6] = [
        Kind::Review,
        Kind::Fix,
        Kind::Build,
        Kind::Test,
        Kind::Investigate,
        Kind::Research,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Review => "review",
            Kind::Fix => "fix",
            Kind::Build => "build",
            Kind::Test => "test",
            Kind::Investigate => "investigate",
            Kind::Research => "research",
        }
    }

    /// Work that commits (`Job.committing`).
    pub fn commits(self) -> bool {
        matches!(self, Kind::Fix | Kind::Build | Kind::Test)
    }
}

/// How hard the work looks: a complex job gets a stronger model offered, never applied on its own.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Complexity {
    #[default]
    Routine,
    Complex,
}

/// A job's permission mode, as a plan names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Mode {
    #[serde(rename = "ask")]
    Ask,
    #[serde(rename = "acceptEdits")]
    AcceptEdits,
    #[serde(rename = "plan")]
    Plan,
    #[serde(rename = "bypass")]
    Bypass,
}

impl Mode {
    pub fn to_permissions(self) -> crate::permissions::Mode {
        match self {
            Mode::Ask => crate::permissions::Mode::Ask,
            Mode::AcceptEdits => crate::permissions::Mode::AcceptEdits,
            Mode::Plan => crate::permissions::Mode::Plan,
            Mode::Bypass => crate::permissions::Mode::Bypass,
        }
    }

    pub fn as_str(self) -> &'static str {
        self.to_permissions().as_str()
    }
}

/// answer_permission's answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Allow,
    Always,
    Deny,
}

impl Decision {
    pub fn as_str(self) -> &'static str {
        match self {
            Decision::Allow => "allow",
            Decision::Always => "always",
            Decision::Deny => "deny",
        }
    }

    pub fn to_permissions(self) -> crate::permissions::Decision {
        match self {
            Decision::Allow => crate::permissions::Decision::Allow,
            Decision::Always => crate::permissions::Decision::Always,
            Decision::Deny => crate::permissions::Decision::Deny,
        }
    }
}

fn auto() -> String {
    "auto".into()
}

fn one() -> i64 {
    1
}

/// One job of a plan.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Dispatch {
    #[serde(default = "auto")]
    pub agent: String,
    #[serde(default = "auto")]
    pub account: String,
    pub repo: String,
    #[serde(default, alias = "baseBranch")]
    pub base_branch: Option<String>,
    #[serde(default)]
    pub pr: Option<i64>,
    /// The issue the work is about. obid reads it for the agent, who has no GitHub login.
    #[serde(default)]
    pub issue: Option<i64>,
    /// An epic: one job per open sub-issue.
    #[serde(default)]
    pub epic: Option<i64>,
    pub kind: Kind,
    /// A short title for the job, 3 to 6 words; none from rules.
    #[serde(default)]
    pub title: Option<String>,
    pub task: String,
    #[serde(default)]
    pub inputs: Vec<String>,
    /// How many rounds the agent may take: 1 unless the user asked to keep going until done.
    #[serde(default = "one")]
    pub rounds: i64,
    /// A one-line command that must succeed for the work to count as done.
    #[serde(default)]
    pub check: Option<String>,
    #[serde(default)]
    pub complexity: Complexity,
    /// What must happen before the job starts (#216). obid can't wait yet (#455): it refuses any.
    #[serde(default, alias = "startWhen")]
    pub start_when: Option<Vec<Value>>,
    /// How the job asks (#134): only when the user said; none for Settings' default.
    #[serde(default)]
    pub mode: Option<Mode>,
    /// Other repositories a research job must read (never writable).
    #[serde(default)]
    pub reads: Option<Vec<String>>,
}

/// A question for the user: at most 3 options, and the user may answer in words of their own.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Question {
    pub text: String,
    #[serde(default)]
    pub options: Vec<String>,
    #[serde(default)]
    pub details: Option<Vec<String>>,
    /// The index of the option the asker recommends, or none.
    #[serde(default)]
    pub recommended: Option<i64>,
    #[serde(default)]
    pub plan: Option<String>,
}

/// Where move_job moves its jobs: a tool, an account by name and a model by id, each "auto"
/// unless the user named it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Move {
    pub agent: String,
    pub account: String,
    pub model: String,
}

/// set_setting's one change.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Setting {
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default, alias = "complexEffort")]
    pub complex_effort: Option<String>,
    #[serde(default, alias = "maxRunning")]
    pub max_running: Option<i64>,
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub lift: Option<bool>,
}

/// The research step's read-only tools.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LookupTool {
    SearchCode,
    ListFiles,
    ReadFile,
    GitLog,
    ViewIssue,
    #[serde(rename = "view_pr")]
    ViewPr,
    #[serde(rename = "fetch_url")]
    FetchUrl,
}

impl LookupTool {
    pub fn as_str(self) -> &'static str {
        match self {
            LookupTool::SearchCode => "search_code",
            LookupTool::ListFiles => "list_files",
            LookupTool::ReadFile => "read_file",
            LookupTool::GitLog => "git_log",
            LookupTool::ViewIssue => "view_issue",
            LookupTool::ViewPr => "view_pr",
            LookupTool::FetchUrl => "fetch_url",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Lookup {
    pub tool: LookupTool,
    #[serde(default)]
    pub repo: Option<String>,
    #[serde(default, rename = "ref")]
    pub reference: Option<String>,
    #[serde(default)]
    pub query: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default, alias = "startLine")]
    pub start_line: Option<i64>,
    #[serde(default, alias = "endLine")]
    pub end_line: Option<i64>,
    #[serde(default)]
    pub number: Option<i64>,
    #[serde(default)]
    pub url: Option<String>,
}

/// One plan: one action and its fields.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    pub action: Action,
    pub reply: String,
    /// One job per independent piece of work, up to 10; empty unless the action is dispatch.
    #[serde(default)]
    pub dispatches: Vec<Dispatch>,
    #[serde(default)]
    pub question: Option<Question>,
    /// The jobs an action names, by id from the briefing. Older plans have no key.
    #[serde(default)]
    pub jobs: Option<Vec<String>>,
    /// Stop everything, for stop_agent: only when the user clearly asked for all of it.
    #[serde(default)]
    pub all: Option<bool>,
    /// Where move_job moves the jobs `jobs` names.
    #[serde(default, rename = "move")]
    pub destination: Option<Move>,
    #[serde(default)]
    pub decision: Option<Decision>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub mode: Option<Mode>,
    #[serde(default)]
    pub setting: Option<Setting>,
    /// answer_inbox's item by id, and its answer: an option by its number from 1, or words.
    #[serde(default)]
    pub item: Option<String>,
    #[serde(default)]
    pub option: Option<i64>,
    #[serde(default)]
    pub answer: Option<String>,
    #[serde(default)]
    pub lookups: Option<Vec<Lookup>>,
    /// Markdown that accompanies a short spoken reply.
    #[serde(default)]
    pub details: Option<String>,
}

impl Plan {
    /// A plan of `action` with nothing else in it.
    pub fn of(action: Action, reply: &str) -> Plan {
        Plan {
            action,
            reply: reply.into(),
            dispatches: vec![],
            question: None,
            jobs: None,
            all: None,
            destination: None,
            decision: None,
            message: None,
            mode: None,
            setting: None,
            item: None,
            option: None,
            answer: None,
            lookups: None,
            details: None,
        }
    }

    pub fn decode(bytes: &[u8]) -> Option<Plan> {
        serde_json::from_slice(bytes).ok()
    }

    pub fn named(&self) -> &[String] {
        self.jobs.as_deref().unwrap_or(&[])
    }
}

/// What the brain may choose from (`BrainContext`): the accounts of each tool, the repositories,
/// the briefing and the quoted file, and the ids each action may name.
#[derive(Debug, Clone, Default)]
pub struct Context {
    /// Each tool's accounts by name, `auto` first, and `auto` for any tool.
    pub accounts: BTreeMap<String, Vec<String>>,
    pub repos: Vec<String>,
    /// Handles for untrusted inputs. None yet.
    pub handles: Vec<String>,
    /// What the brain is told before the user's words.
    pub briefing: Option<String>,
    /// What agents wrote, for the brain to read as a quoted file, never in the prompt.
    pub quoted: Option<String>,
    /// The jobs the brain may stop by id: the briefing's queued and running ones.
    pub jobs: Vec<String>,
    /// The jobs the brain may move or read by id: every job in the briefing.
    pub movable: Vec<String>,
    /// What a job may move to: each tool's models, and its accounts by name.
    pub models: BTreeMap<String, Vec<String>>,
    pub move_accounts: BTreeMap<String, Vec<String>>,
    pub setting_models: BTreeMap<String, Vec<String>>,
    pub setting_efforts: BTreeMap<String, Vec<String>>,
    pub setting_model_efforts: BTreeMap<String, BTreeMap<String, Vec<String>>>,
    pub setting_accounts: Vec<String>,
    /// The jobs whose permission prompt waits for the user, by id.
    pub permissions: Vec<String>,
    /// Pull requests Oby authored (`owner/name#n`) and the jobs that own their review.
    pub review_authors: BTreeMap<String, String>,
    /// Routing hints for choosing the brain's model; they are not the user's instructions.
    pub turn_step: usize,
    pub turn_length: Option<usize>,
    /// The inbox items waiting for the user, by id.
    pub inbox: Vec<String>,
    /// Failure records whose post-mortems permit an automatic fix.
    pub fixable_failures: Vec<String>,
    /// These additional actions are available only while processing a runner event.
    pub orchestrator: bool,
    pub orchestrator_context: Option<String>,
}

fn count(text: &str) -> usize {
    text.chars().count()
}

fn blank(text: &str) -> bool {
    text.trim().is_empty()
}

/// A pull request number is only unique inside its repository.
pub fn review_key(repo: &str, pr: i64) -> String {
    format!("{repo}#{pr}")
}

/// A tool's default model (Engine/Models.swift, `AgentModels.value`).
fn default_model(agent: &str) -> &'static str {
    let models = crate::api::Models::defaults();
    match agent {
        "claude" => models.claude.model,
        "codex" => models.codex.model,
        "cursor" => models.cursor.model,
        _ => "",
    }
}

impl Plan {
    /// Why obid refuses this plan; empty when it's fine. `canary` is the turn's own word, which
    /// no plan may repeat.
    pub fn problems(&self, context: &Context, canary: &str) -> Vec<String> {
        let mut problems: Vec<String> = vec![];
        let action = self.action;
        if !context.orchestrator && matches!(action, Action::MessageJob | Action::FixFailure) {
            problems.push(format!(
                "{} is only available to Oby's event orchestrator",
                action.as_str()
            ));
        }
        if count(&self.reply) > REPLY_LENGTH {
            problems.push(format!("reply is longer than {REPLY_LENGTH} characters"));
        }
        let mut texts: Vec<&str> = vec![
            &self.reply,
            self.question.as_ref().map_or("", |q| q.text.as_str()),
        ];
        texts.extend(self.dispatches.iter().map(|d| d.task.as_str()));
        texts.extend(self.dispatches.iter().filter_map(|d| d.title.as_deref()));
        if let Some(question) = &self.question {
            texts.extend(question.options.iter().map(String::as_str));
        }
        if !canary.is_empty() && texts.iter().any(|t| t.contains(canary)) {
            problems.push("the plan repeats the canary".into());
        }

        match action {
            Action::Dispatch => {
                if self.dispatches.is_empty() {
                    problems.push("dispatch needs at least one job in dispatches".into());
                }
                if self.dispatches.len() > MOST_DISPATCHES {
                    problems.push("dispatches holds at most 10 jobs".into());
                }
                if self.question.is_some() {
                    problems.push("dispatch has no question".into());
                }
                for dispatch in &self.dispatches {
                    for problem in dispatch_problems(dispatch, context) {
                        if !problems.contains(&problem) {
                            problems.push(problem);
                        }
                    }
                }
            }
            Action::AskUser => {
                if self.question.is_none() {
                    problems.push("ask_user needs its question object".into());
                }
                if !self.dispatches.is_empty() {
                    problems.push("ask_user has no dispatches".into());
                }
                if let Some(question) = &self.question {
                    if question.options.len() > MOST_OPTIONS {
                        problems.push(format!("question has at most {MOST_OPTIONS} options"));
                    }
                    if let Some(recommended) = question.recommended
                        && !(0..question.options.len() as i64).contains(&recommended)
                    {
                        problems
                            .push("recommended is the index of one of the options, or null".into());
                    }
                }
            }
            Action::Research => {
                let lookups = self.lookups.as_deref().unwrap_or(&[]);
                if !(1..=4).contains(&lookups.len()) {
                    problems.push("research needs 1 to 4 lookups".into());
                }
                if !self.dispatches.is_empty() {
                    problems.push("research has no dispatches".into());
                }
                if self.question.is_some() {
                    problems.push("research has no question".into());
                }
                if !self.named().is_empty() {
                    problems.push("research has no jobs".into());
                }
                for lookup in lookups {
                    problems.extend(lookup_problems(lookup, context));
                }
            }
            _ => {
                if !self.dispatches.is_empty() || self.question.is_some() {
                    problems.push(format!(
                        "{} has no dispatches or question object",
                        action.as_str()
                    ));
                }
            }
        }
        if action != Action::Research && !self.lookups.as_deref().unwrap_or(&[]).is_empty() {
            problems.push("only research has lookups".into());
        }
        if let Some(details) = &self.details {
            if count(details) > 4000 {
                problems.push("details is longer than 4,000 characters".into());
            }
            if action != Action::ReplyOnly && action != Action::AskUser {
                problems.push("details is only for reply_only and ask_user".into());
            }
        }
        // Only some actions name jobs, and only ones the briefing listed. Stopping everything is
        // said in so many words, never by naming none.
        let named = self.named();
        match action {
            Action::StopAgent => {
                for id in named.iter().filter(|id| !context.jobs.contains(id)) {
                    problems.push(format!("{id} isn't a job Oby can stop"));
                }
                if named.is_empty() && self.all != Some(true) {
                    problems.push(
                        "stop_agent names the jobs to stop, or all is true for everything".into(),
                    );
                }
                if !named.is_empty() && self.all == Some(true) {
                    problems.push("stop_agent names jobs or stops all, not both".into());
                }
            }
            Action::MoveJob => {
                if named.is_empty() || named.len() > 10 {
                    problems.push("move_job names 1 to 10 jobs".into());
                }
                for id in named.iter().filter(|id| !context.movable.contains(id)) {
                    problems.push(format!("{id} isn't a job Oby can move"));
                }
                match &self.destination {
                    Some(destination) => problems.extend(move_problems(destination, context)),
                    None => problems.push("move_job needs its move object".into()),
                }
            }
            Action::AnswerPermission => {
                if named.len() != 1 {
                    problems.push("answer_permission names one job".into());
                }
                for id in named.iter().filter(|id| !context.permissions.contains(id)) {
                    problems.push(format!("{id} isn't waiting for the user's OK"));
                }
                if self.decision.is_none() {
                    problems.push("answer_permission needs its decision".into());
                }
            }
            Action::SetMode => {
                if named.is_empty() {
                    problems.push("set_mode names the jobs".into());
                }
                for id in named.iter().filter(|id| !context.jobs.contains(id)) {
                    problems.push(format!("{id} isn't a running job"));
                }
                if self.mode.is_none() {
                    problems.push("set_mode needs its mode".into());
                }
            }
            Action::ReadJob => {
                if named.len() != 1 {
                    problems.push("read_job names one job".into());
                }
                for id in named.iter().filter(|id| !context.movable.contains(id)) {
                    problems.push(format!("{id} isn't a job Oby can read"));
                }
            }
            Action::SetSetting => match &self.setting {
                Some(setting) => problems.extend(setting_problems(setting, context)),
                None => problems.push("set_setting needs its setting object".into()),
            },
            Action::MessageJob => {
                if named.len() != 1 {
                    problems.push("message_job names one job".into());
                }
                for id in named.iter().filter(|id| !context.movable.contains(id)) {
                    problems.push(format!("{id} isn't a job Oby can message"));
                }
                if self.message.as_deref().is_none_or(blank) {
                    problems.push("message_job needs what Oby found and what to change".into());
                }
            }
            Action::AskReviewAgain => {
                if named.len() != 1 {
                    problems.push("ask_review_again names one job".into());
                }
                for id in named.iter().filter(|id| !context.movable.contains(id)) {
                    problems.push(format!("{id} isn't a job Oby can review again"));
                }
                if !context.orchestrator
                    && let Some(id) = named.first()
                    && !context.review_authors.values().any(|v| v == id)
                {
                    problems.push(format!("{id} isn't an Oby-authored pull request"));
                }
            }
            Action::FixFailure => {
                if !named.is_empty() {
                    problems.push("fix_failure names its failure in item, not jobs".into());
                }
                if !context
                    .fixable_failures
                    .contains(self.item.as_ref().unwrap_or(&String::new()))
                {
                    problems.push("fix_failure names a studied, fixable failure".into());
                }
            }
            Action::RetryJob | Action::DismissJob | Action::StartNow => {}
            _ => {
                if !named.is_empty() {
                    problems.push(
                        "only stop_agent, move_job, answer_permission and set_mode name jobs"
                            .into(),
                    );
                }
            }
        }
        problems.extend(self.job_action_problems(context));
        if action != Action::StopAgent && self.all == Some(true) {
            problems.push("only stop_agent stops all".into());
        }
        if action != Action::MoveJob && self.destination.is_some() {
            problems.push("only move_job has a move object".into());
        }
        if self.decision.is_some() && action != Action::AnswerPermission {
            problems.push("only answer_permission has a decision or a message".into());
        }
        if !self.message.as_deref().unwrap_or("").is_empty()
            && action != Action::AnswerPermission
            && action != Action::MessageJob
        {
            problems.push("only answer_permission has a decision or a message".into());
        }
        if action != Action::SetMode && self.mode.is_some() {
            problems.push("only set_mode has a mode".into());
        }
        if action != Action::SetSetting && self.setting.is_some() {
            problems.push("only set_setting has a setting object".into());
        }
        if count(self.message.as_deref().unwrap_or("")) > 2000 {
            problems.push("message is longer than 2,000 characters".into());
        }
        problems
    }

    /// Why obid refuses the job actions' fields (Engine/JobActions.swift).
    fn job_action_problems(&self, context: &Context) -> Vec<String> {
        let mut problems: Vec<String> = vec![];
        let named = self.named();
        let action = self.action;
        match action {
            Action::RetryJob
            | Action::DismissJob
            | Action::StartNow
            | Action::MessageJob
            | Action::AskReviewAgain => {
                if named.is_empty() || named.len() > 10 {
                    problems.push(format!("{} names 1 to 10 jobs", action.as_str()));
                }
                for id in named.iter().filter(|id| !context.movable.contains(id)) {
                    problems.push(format!("{id} isn't a job in the briefing"));
                }
                if action == Action::MessageJob {
                    if named.len() != 1 {
                        problems.push("message_job names one job".into());
                    }
                    if self.message.as_deref().is_none_or(blank) {
                        problems.push("message_job needs a message".into());
                    }
                    if count(self.message.as_deref().unwrap_or("")) > 2000 {
                        problems.push("message_job is longer than 2,000 characters".into());
                    }
                }
            }
            Action::AnswerInbox => {
                if !named.is_empty() {
                    problems.push("answer_inbox names an inbox item, not jobs".into());
                }
                if !context
                    .inbox
                    .contains(self.item.as_ref().unwrap_or(&String::new()))
                {
                    problems.push("answer_inbox names an item waiting in the inbox".into());
                }
                let words = self.answer.as_deref().unwrap_or("").trim();
                if self.option.is_none() && words.is_empty() {
                    problems.push("answer_inbox gives an option or the user's words".into());
                }
                if self.option.is_some() && !words.is_empty() {
                    problems
                        .push("answer_inbox gives an option or the user's words, not both".into());
                }
                if let Some(option) = self.option
                    && option < 1
                {
                    problems.push("option counts from 1".into());
                }
            }
            _ => {}
        }
        if action != Action::AnswerInbox
            && action != Action::FixFailure
            && (self.item.is_some() || self.option.is_some() || self.answer.is_some())
        {
            problems.push("only answer_inbox has an item, an option or an answer".into());
        }
        if action != Action::MessageJob
            && action != Action::AnswerPermission
            && self.message.as_deref().is_some_and(|m| !m.is_empty())
        {
            problems.push("only message_job or answer_permission has a message".into());
        }
        if count(self.answer.as_deref().unwrap_or("")) > 2000 {
            problems.push("answer is longer than 2,000 characters".into());
        }
        problems
    }

    /// What makes two actions the same: what they do, to which jobs, how (`Desk.signature`).
    pub fn signature(&self) -> String {
        let mut jobs = self.named().to_vec();
        jobs.sort();
        let setting = self.setting.as_ref().map_or(String::new(), |s| {
            format!(
                "{}/{}/{}/{}/{}/{}",
                s.agent.as_deref().unwrap_or(""),
                s.model.as_deref().unwrap_or(""),
                s.effort.as_deref().unwrap_or(""),
                s.max_running.map(|m| m.to_string()).unwrap_or_default(),
                s.account.as_deref().unwrap_or(""),
                s.lift.map(|l| l.to_string()).unwrap_or_default()
            )
        });
        let act = [
            self.item.clone().unwrap_or_default(),
            self.option.map(|o| o.to_string()).unwrap_or_default(),
            self.answer.clone().unwrap_or_default(),
            if self.action == Action::MessageJob {
                self.message.clone().unwrap_or_default()
            } else {
                String::new()
            },
        ]
        .join("/");
        [
            self.action.as_str().to_owned(),
            jobs.join(","),
            if self.all == Some(true) {
                "all".into()
            } else {
                String::new()
            },
            self.destination.as_ref().map_or(String::new(), |m| {
                format!("{}/{}/{}", m.agent, m.account, m.model)
            }),
            self.mode.map(|m| m.as_str().to_owned()).unwrap_or_default(),
            self.decision
                .map(|d| d.as_str().to_owned())
                .unwrap_or_default(),
            setting,
            act,
        ]
        .join("|")
    }
}

fn setting_problems(setting: &Setting, context: &Context) -> Vec<String> {
    let mut problems = vec![];
    let model_change = setting.agent.is_some()
        || setting.model.is_some()
        || setting.effort.is_some()
        || setting.complex_effort.is_some();
    let max_change = setting.max_running.is_some();
    let reserve_change = setting.account.is_some() || setting.lift.is_some();
    if [model_change, max_change, reserve_change]
        .iter()
        .filter(|c| **c)
        .count()
        != 1
    {
        return vec!["set_setting changes one model, maxRunning, or account reserve".into()];
    }
    if model_change {
        let Some(agent) = setting
            .agent
            .as_deref()
            .filter(|a| ["claude", "codex", "cursor"].contains(a))
        else {
            return vec!["setting needs a tool".into()];
        };
        // Cursor has a model and nothing else: no effort to set.
        if agent == "cursor" && (setting.effort.is_some() || setting.complex_effort.is_some()) {
            return vec![
                "Cursor has no effort: effort and complex_effort must be null for it".into(),
            ];
        }
        let none = vec![];
        let models = context.setting_models.get(agent).unwrap_or(&none);
        let efforts = context.setting_efforts.get(agent).unwrap_or(&none);
        if let Some(model) = &setting.model
            && !models.contains(model)
        {
            problems.push(format!("unknown model; choices: {}", models.join(", ")));
        }
        if let Some(effort) = &setting.effort
            && !efforts.contains(effort)
        {
            problems.push(format!("unknown effort; choices: {}", efforts.join(", ")));
        }
        if let Some(effort) = &setting.complex_effort
            && !efforts.contains(effort)
        {
            problems.push(format!(
                "unknown complex effort; choices: {}",
                efforts.join(", ")
            ));
        }
        let model = setting
            .model
            .clone()
            .unwrap_or_else(|| default_model(agent).to_owned());
        let choices = context
            .setting_model_efforts
            .get(agent)
            .and_then(|m| m.get(&model));
        if let (Some(effort), Some(choices)) = (&setting.effort, choices)
            && !choices.contains(effort)
        {
            problems.push(format!(
                "unknown effort for {model}; choices: {}",
                choices.join(", ")
            ));
        }
        if let (Some(effort), Some(choices)) = (&setting.complex_effort, choices)
            && !choices.contains(effort)
        {
            problems.push(format!(
                "unknown complex effort for {model}; choices: {}",
                choices.join(", ")
            ));
        }
        if setting.model.is_none() && setting.effort.is_none() && setting.complex_effort.is_none() {
            problems.push("setting needs a model or effort".into());
        }
    } else if let Some(max) = setting.max_running {
        if !MAX_RUNNING.contains(&max) {
            problems.push(format!(
                "maxRunning goes from {} to {}",
                MAX_RUNNING.start(),
                MAX_RUNNING.end()
            ));
        }
    } else if reserve_change {
        let Some(account) = &setting.account else {
            problems.push("reserve setting needs an account".into());
            return problems;
        };
        if !context.setting_accounts.contains(account) {
            problems.push("unknown account".into());
        }
        if setting.lift.is_none() {
            problems.push("reserve setting needs lift".into());
        }
    }
    problems
}

fn is_hex_ref(text: &str) -> bool {
    (7..=40).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Whether `url` is HTTPS with a host and no user or password: malformed and non-HTTPS URLs are
/// refused here; private addresses are refused when the lookup runs, so they show as evidence.
fn is_https(url: &str) -> bool {
    let Some((scheme, rest)) = url.split_once("://") else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case("https") {
        return false;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority
        .rsplit_once(':')
        .map_or(authority, |(host, _)| host);
    !authority.contains('@') && !host.is_empty() && !url.chars().any(char::is_whitespace)
}

fn lookup_problems(lookup: &Lookup, context: &Context) -> Vec<String> {
    let mut problems = vec![];
    let path_valid = lookup.path.as_deref().is_none_or(|path| {
        !path.is_empty()
            && count(path) <= 300
            && !path.starts_with('/')
            && !path.starts_with('-')
            && !path.split('/').any(|piece| piece == "..")
    });
    if !path_valid {
        problems.push("path must be relative, at most 300 characters, and contain no .. segment or leading slash or hyphen".into());
    }
    if let Some(reference) = &lookup.reference
        && !(is_branch_name(reference) || is_hex_ref(reference))
    {
        problems.push("ref must be a branch name or 7 to 40 hexadecimal characters".into());
    }
    let tool = lookup.tool.as_str();
    let lines = lookup.start_line.is_some() || lookup.end_line.is_some();
    match lookup.tool {
        LookupTool::SearchCode => {
            if lookup.repo.is_none() {
                problems.push("search_code needs repo".into());
            }
            match &lookup.query {
                Some(query) => {
                    if !(1..=200).contains(&count(query)) || query.contains(['\n', '\r']) {
                        problems.push(
                            "search_code query must be 1 to 200 characters on one line".into(),
                        );
                    }
                }
                None => problems.push("search_code needs query".into()),
            }
            if lookup.number.is_some() || lookup.url.is_some() || lines {
                problems.push("search_code has only repo, ref, query and path".into());
            }
        }
        LookupTool::ListFiles => {
            if lookup.repo.is_none() {
                problems.push("list_files needs repo".into());
            }
            if lookup.query.is_some() || lookup.number.is_some() || lookup.url.is_some() || lines {
                problems.push("list_files has only repo, ref and path".into());
            }
        }
        LookupTool::ReadFile => {
            if lookup.repo.is_none() {
                problems.push("read_file needs repo".into());
            }
            if lookup.path.is_none() {
                problems.push("read_file needs path".into());
            }
            if lookup.start_line.is_some_and(|s| s < 1) {
                problems.push("startLine must be positive".into());
            }
            if lookup.end_line.is_some_and(|e| e < 1) {
                problems.push("endLine must be positive".into());
            }
            if let (Some(start), Some(end)) = (lookup.start_line, lookup.end_line)
                && end < start
            {
                problems.push("endLine must be at least startLine".into());
            }
            let start = lookup.start_line.unwrap_or(1);
            if let Some(end) = lookup.end_line
                && end >= start
                && end - start >= 400
            {
                problems.push("read_file range is at most 400 lines".into());
            }
            if lookup.query.is_some() || lookup.number.is_some() || lookup.url.is_some() {
                problems.push("read_file has only repo, ref, path and line range".into());
            }
        }
        LookupTool::GitLog => {
            if lookup.repo.is_none() {
                problems.push("git_log needs repo".into());
            }
            if lookup.query.is_some() || lookup.number.is_some() || lookup.url.is_some() || lines {
                problems.push("git_log has only repo, ref and path".into());
            }
        }
        LookupTool::ViewIssue | LookupTool::ViewPr => {
            if lookup.repo.is_none() {
                problems.push(format!("{tool} needs repo"));
            }
            if lookup.number.is_none_or(|n| n <= 0) {
                problems.push(format!("{tool} needs a positive number"));
            }
            if lookup.query.is_some()
                || lookup.path.is_some()
                || lines
                || lookup.url.is_some()
                || lookup.reference.is_some()
            {
                problems.push(format!("{tool} has only repo and number"));
            }
        }
        LookupTool::FetchUrl => {
            match &lookup.url {
                Some(url) => {
                    if !is_https(url) {
                        problems.push("fetch_url needs a public HTTPS URL".into());
                    }
                }
                None => problems.push("fetch_url needs url".into()),
            }
            if lookup.repo.is_some()
                || lookup.reference.is_some()
                || lookup.query.is_some()
                || lookup.path.is_some()
                || lines
                || lookup.number.is_some()
            {
                problems.push("fetch_url has only url".into());
            }
        }
    }
    if let Some(repo) = &lookup.repo
        && !context.repos.contains(repo)
    {
        problems.push(format!("{repo} isn't a known repository"));
    }
    problems
}

/// What's wrong with where move_job moves its jobs: the tool, account and model must exist and
/// go together. Whether the account has room is checked when it moves.
fn move_problems(destination: &Move, context: &Context) -> Vec<String> {
    let mut problems = vec![];
    if destination.agent == "auto" && destination.account == "auto" && destination.model == "auto" {
        problems.push("move names a tool, an account or a model".into());
    }
    if destination.agent != "auto" && !context.models.contains_key(&destination.agent) {
        problems.push(format!("{} can't run jobs", destination.agent));
    }
    if destination.account != "auto" {
        let owners: Vec<&String> = context
            .move_accounts
            .iter()
            .filter(|(_, names)| names.contains(&destination.account))
            .map(|(agent, _)| agent)
            .collect();
        if owners.is_empty() {
            problems.push(format!("{} isn't an account", destination.account));
        } else if destination.agent != "auto" && !owners.contains(&&destination.agent) {
            problems.push(format!(
                "{} isn't an account of {}",
                destination.account, destination.agent
            ));
        }
    }
    if destination.model != "auto" {
        let owners: Vec<&String> = context
            .models
            .iter()
            .filter(|(_, models)| models.contains(&destination.model))
            .map(|(agent, _)| agent)
            .collect();
        if owners.is_empty() {
            problems.push(format!("{} isn't a model", destination.model));
        } else if destination.agent != "auto" && !owners.contains(&&destination.agent) {
            problems.push(format!(
                "{} isn't a model of {}",
                destination.model, destination.agent
            ));
        }
    }
    problems
}

/// What's wrong with one job of a plan.
fn dispatch_problems(dispatch: &Dispatch, context: &Context) -> Vec<String> {
    let mut problems = vec![];
    match context.accounts.get(&dispatch.agent) {
        Some(accounts) => {
            if !accounts.contains(&dispatch.account) {
                problems.push(format!(
                    "{} isn't an account of {}",
                    dispatch.account, dispatch.agent
                ));
            }
        }
        None => problems.push(format!("{} isn't connected", dispatch.agent)),
    }
    if !context.repos.contains(&dispatch.repo) {
        problems.push(format!("{} isn't a known repository", dispatch.repo));
    }
    if blank(&dispatch.task) {
        problems.push("task is empty".into());
    }
    if count(&dispatch.task) > 2000 {
        problems.push("task is longer than 2,000 characters".into());
    }
    if let Some(title) = &dispatch.title
        && !is_title(title)
    {
        problems.push("title must be one line of 1 to 60 characters".into());
    }
    if dispatch.pr.is_some_and(|pr| pr <= 0) {
        problems.push("pr must be a positive number".into());
    }
    if dispatch.kind == Kind::Review
        && let Some(pr) = dispatch.pr
        && let Some(author) = context.review_authors.get(&review_key(&dispatch.repo, pr))
    {
        problems.push(format!(
            "PR #{pr} has Oby author job {author}; use ask_review_again"
        ));
    }
    if dispatch.issue.is_some_and(|issue| issue <= 0) {
        problems.push("issue must be a positive number".into());
    }
    // Both is an issue's work started from a pull request's head (#219): work that commits.
    if dispatch.pr.is_some() && dispatch.issue.is_some() && !dispatch.kind.commits() {
        problems.push("a job is about a pr or an issue, not both, unless it's a fix, build or test of the issue that starts from the pr".into());
    }
    if let Some(epic) = dispatch.epic {
        if epic <= 0 {
            problems.push("epic must be a positive number".into());
        }
        if dispatch.pr.is_some() || dispatch.issue.is_some() {
            problems.push("an epic job has no pr or issue: Oby finds its sub-issues".into());
        }
    }
    if !(1..=10).contains(&dispatch.rounds) {
        problems.push("rounds must be 1 to 10".into());
    }
    if let Some(check) = &dispatch.check
        && !is_check(check)
    {
        problems.push("check must be one line of 1 to 200 characters".into());
    }
    if let Some(base) = &dispatch.base_branch
        && !is_branch_name(base)
    {
        problems.push("base_branch isn't a branch name".into());
    }
    if dispatch.kind == Kind::Research {
        if let Some(reads) = &dispatch.reads {
            if reads.len() > 5 {
                problems.push("reads holds at most 5 repositories".into());
            }
            if reads.iter().collect::<BTreeSet<_>>().len() != reads.len() {
                problems.push("reads has duplicate repositories".into());
            }
            if reads.contains(&dispatch.repo) {
                problems.push("reads lists the job's repository".into());
            }
            if let Some(unknown) = reads.iter().find(|r| !context.repos.contains(r)) {
                problems.push(format!("{unknown} isn't a known repository"));
            }
        }
    } else if dispatch.reads.as_ref().is_some_and(|r| !r.is_empty()) {
        problems.push("reads is only available for research jobs".into());
    }
    if let Some(unknown) = dispatch
        .inputs
        .iter()
        .find(|i| !context.handles.contains(i))
    {
        problems.push(format!("input {unknown} doesn't exist"));
    }
    // What obid's jobs can't carry yet is refused, never dropped (#546).
    if dispatch.epic.is_some() {
        problems.push(
            "epic is null: obid can't make one job per sub-issue yet; name the issues instead"
                .into(),
        );
    }
    if dispatch.reads.as_ref().is_some_and(|r| !r.is_empty()) {
        problems
            .push("reads is null: obid's research jobs can't read other repositories yet".into());
    }
    // obid can't hold a job until something happens yet (#455).
    if dispatch.start_when.as_ref().is_some_and(|c| !c.is_empty()) {
        problems.push("start_when is empty: obid can't wait to start a job yet".into());
    }
    problems
}

/// A branch name git accepts and Oby is happy to create: no option-looking or odd names.
pub fn is_branch_name(name: &str) -> bool {
    name.len() <= 100
        && !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._/-".contains(&b))
        && !name.starts_with(['-', '/', '.'])
        && !name.ends_with('/')
        && !name.ends_with('.')
        && !name.ends_with(".lock")
        && !name.contains("..")
        && !name.contains("//")
        && !name.contains("/.")
}

/// A command Oby will run to check the work: one line, short enough to read on the card.
pub fn is_check(command: &str) -> bool {
    let trimmed = command.trim_matches([' ', '\t']);
    !trimmed.is_empty() && count(trimmed) <= 200 && !trimmed.contains(['\n', '\r'])
}

/// A job's title: one line, short enough for a row on the iPhone and the notch.
pub fn is_title(title: &str) -> bool {
    let trimmed = title.trim_matches([' ', '\t']);
    !trimmed.is_empty() && count(trimmed) <= 60 && !trimmed.contains(['\n', '\r'])
}

fn nullable(object: Value) -> Value {
    json!({"anyOf": [{"type": "null"}, object]})
}

/// The JSON schema the model has to fill. It's the same from turn to turn (#534): the schema is
/// the first thing the model's server reads, so a job or an inbox item in it would undo the cache
/// on every call. Ids, accounts, models and repositories are strings, checked by
/// [`Plan::problems`], whose refusal goes back to the model; only the event orchestrator, a
/// caller of its own, has other actions.
pub fn schema(context: &Context) -> Value {
    let modes = json!(["ask", "acceptEdits", "plan", "bypass"]);
    let tools = json!(["auto", "claude", "codex", "cursor"]);
    let string = json!({"type": "string"});
    let dispatch = json!({
        "type": "object", "additionalProperties": false,
        "required": ["agent", "account", "repo", "base_branch", "pr", "issue", "epic", "kind", "title", "task", "inputs", "rounds", "check", "complexity", "start_when", "mode", "reads"],
        "properties": {
            "agent": {"enum": tools},
            "account": string,
            "repo": string,
            "base_branch": {"type": ["string", "null"]},
            "pr": {"type": ["integer", "null"]},
            "issue": {"type": ["integer", "null"]},
            // obid can't make one job per sub-issue, or let a job read other repositories, yet.
            "epic": {"type": "null"},
            "complexity": {"enum": ["routine", "complex"]},
            "rounds": {"type": "integer", "minimum": 1, "maximum": 10},
            "check": {"type": ["string", "null"], "maxLength": 200},
            "kind": {"enum": Kind::ALL.iter().map(|k| k.as_str()).collect::<Vec<_>>()},
            "title": {"type": "string", "maxLength": 60},
            "task": {"type": "string", "maxLength": 2000},
            "inputs": {"type": "array", "items": string},
            // obid can't hold a job until something happens yet (#455).
            "start_when": {"type": "array", "maxItems": 0},
            "mode": nullable(json!({"enum": modes})),
            "reads": {"type": "null"},
        },
    });
    let question = json!({
        "type": "object", "additionalProperties": false, "required": ["text", "options", "recommended"],
        "properties": {"text": {"type": "string"},
                       "options": {"type": "array", "items": {"type": "string"}, "maxItems": MOST_OPTIONS},
                       "recommended": {"type": ["integer", "null"], "minimum": 0, "maximum": MOST_OPTIONS - 1}},
    });
    let setting = json!({
        "type": "object", "additionalProperties": false,
        "required": ["agent", "model", "effort", "complex_effort", "max_running", "account", "lift"],
        "properties": {
            "agent": nullable(json!({"enum": ["claude", "codex", "cursor"]})),
            "model": {"type": ["string", "null"]},
            "effort": {"type": ["string", "null"]},
            "complex_effort": {"type": ["string", "null"]},
            "max_running": {"type": ["integer", "null"], "minimum": 1, "maximum": 20},
            "account": {"type": ["string", "null"]},
            "lift": {"type": ["boolean", "null"]},
        },
    });
    let lookup = json!({
        "type": "object", "additionalProperties": false,
        "required": ["tool", "repo", "ref", "query", "path", "start_line", "end_line", "number", "url"],
        "properties": {
            "tool": {"enum": ["search_code", "list_files", "read_file", "git_log", "view_issue", "view_pr", "fetch_url"]},
            "repo": {"type": ["string", "null"]}, "ref": {"type": ["string", "null"]},
            "query": {"type": ["string", "null"], "maxLength": 200}, "path": {"type": ["string", "null"], "maxLength": 300},
            "start_line": {"type": ["integer", "null"], "minimum": 1}, "end_line": {"type": ["integer", "null"], "minimum": 1},
            "number": {"type": ["integer", "null"], "minimum": 1}, "url": {"type": ["string", "null"]},
        },
    });
    let destination = json!({
        "type": "object", "additionalProperties": false, "required": ["agent", "account", "model"],
        "properties": {"agent": {"enum": tools}, "account": string, "model": string},
    });
    let mut actions: Vec<&str> = vec![
        "dispatch",
        "ask_user",
        "reply_only",
        "stop_agent",
        "move_job",
        "ignore",
        "answer_permission",
        "set_mode",
        "read_job",
        "set_setting",
        "retry_job",
        "dismiss_job",
        "answer_inbox",
        "start_now",
    ];
    if !context.orchestrator {
        actions.push("research");
    } else {
        actions.extend(["message_job", "fix_failure"]);
    }
    // Offered whether or not the briefing has an Oby-authored pull request: problems refuses it
    // for a job that has none.
    actions.push("ask_review_again");
    json!({
        "type": "object", "additionalProperties": false,
        "required": ["action", "reply", "dispatches", "question", "jobs", "all", "move", "decision", "message", "mode", "setting", "item", "option", "answer", "lookups", "details"],
        "properties": {
            "action": {"enum": actions},
            "reply": {"type": "string", "maxLength": REPLY_LENGTH},
            "dispatches": {"type": "array", "items": dispatch, "maxItems": MOST_DISPATCHES},
            "question": nullable(question),
            "jobs": {"type": "array", "items": string, "maxItems": 10},
            "all": {"type": "boolean"},
            "move": nullable(destination),
            "decision": nullable(json!({"enum": ["allow", "always", "deny"]})),
            "message": {"type": ["string", "null"], "maxLength": 2000},
            "mode": nullable(json!({"enum": modes})),
            "setting": nullable(setting),
            "item": {"type": ["string", "null"]},
            "option": {"type": ["integer", "null"], "minimum": 1, "maximum": 20},
            "answer": {"type": ["string", "null"], "maxLength": 2000},
            "lookups": {"type": "array", "items": lookup, "maxItems": 4},
            "details": {"type": ["string", "null"], "maxLength": 4000},
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reply(text: &str) -> Plan {
        Plan::decode(
            format!(r#"{{"action":"reply_only","reply":"{text}","question":null,"dispatches":[],"jobs":[]}}"#)
                .as_bytes(),
        )
        .unwrap()
    }

    /// A stop of the jobs named, or of everything when none are.
    fn stop(ids: &[&str]) -> Plan {
        Plan::decode(
            json!({"action": "stop_agent", "reply": "", "question": null, "dispatches": [],
                   "jobs": ids, "all": ids.is_empty()})
            .to_string()
            .as_bytes(),
        )
        .unwrap()
    }

    fn context() -> Context {
        Context {
            accounts: BTreeMap::from([("claude".into(), vec!["default".into()])]),
            repos: vec!["deskree-inc/oby".into()],
            briefing: Some("# What Oby knows".into()),
            jobs: vec!["ab12cd34".into()],
            ..Context::default()
        }
    }

    /// ConversationTests.plansNamingJobsAreChecked
    #[test]
    fn plans_naming_jobs_are_checked() {
        let context = context();
        assert!(stop(&["ab12cd34"]).problems(&context, "zq9").is_empty());
        assert_eq!(
            stop(&["zz"]).problems(&context, "zq9"),
            ["zz isn't a job Oby can stop"]
        );
        let mut dispatch = reply("ok");
        dispatch.jobs = Some(vec!["ab12cd34".into()]);
        assert_eq!(
            dispatch.problems(&context, "zq9"),
            ["only stop_agent, move_job, answer_permission and set_mode name jobs"]
        );
        // Stopping everything is said in so many words, never by naming no job.
        assert!(stop(&[]).problems(&context, "zq9").is_empty());
        let mut bare = stop(&[]);
        bare.all = Some(false);
        assert_eq!(
            bare.problems(&context, "zq9"),
            ["stop_agent names the jobs to stop, or all is true for everything"]
        );
        let mut both = stop(&["ab12cd34"]);
        both.all = Some(true);
        assert_eq!(
            both.problems(&context, "zq9"),
            ["stop_agent names jobs or stops all, not both"]
        );
        dispatch.jobs = None;
        dispatch.all = Some(true);
        assert_eq!(
            dispatch.problems(&context, "zq9"),
            ["only stop_agent stops all"]
        );
        // Older plans have no jobs key; the schema offers only the briefing's running jobs.
        assert_eq!(
            Plan::decode(br#"{"action":"ignore","reply":"","question":null,"dispatches":[]}"#)
                .unwrap()
                .jobs,
            None
        );
        // The schema names no job (#534): problems checks them, so it's the same with or without.
        let schema = schema(&context);
        assert_eq!(
            schema["properties"]["jobs"]["items"],
            json!({"type": "string"})
        );
        let required = schema["required"].as_array().unwrap();
        assert!(required.contains(&json!("jobs")) && required.contains(&json!("all")));
        assert_eq!(super::schema(&Context::default()), schema);
        let long = Plan::of(Action::ReplyOnly, &"x".repeat(REPLY_LENGTH + 1));
        assert_eq!(
            long.problems(&context, "zq9"),
            ["reply is longer than 400 characters"]
        );
    }

    /// The canary of the turn never comes back in a plan.
    #[test]
    fn a_plan_repeating_the_canary_is_refused() {
        assert_eq!(
            reply("canary zq9").problems(&context(), "zq9"),
            ["the plan repeats the canary"]
        );
    }

    /// ConversationTests.reviewingAnObyAuthoredPullRequestAgainNamesItsAuthorJob
    #[test]
    fn reviewing_an_oby_authored_pull_request_again_names_its_author_job() {
        let context = Context {
            accounts: BTreeMap::from([("claude".into(), vec!["default".into()])]),
            repos: vec!["deskree-inc/oby".into(), "deskree-inc/another".into()],
            movable: vec!["author".into()],
            review_authors: BTreeMap::from([("deskree-inc/oby#80".into(), "author".into())]),
            ..Context::default()
        };
        let mut again = Plan::of(Action::AskReviewAgain, "");
        again.jobs = Some(vec!["author".into()]);
        assert!(again.problems(&context, "zq9").is_empty());
        let dispatch: Dispatch = serde_json::from_value(json!({
            "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "base_branch": null,
            "pr": 80, "issue": null, "epic": null, "kind": "review", "title": null, "task": "Review PR #80",
            "inputs": [], "rounds": 1, "check": null, "complexity": "routine", "start_when": null, "mode": null}))
        .unwrap();
        let mut standalone = Plan::of(Action::Dispatch, "");
        standalone.dispatches = vec![dispatch.clone()];
        assert_eq!(
            standalone.problems(&context, "zq9"),
            ["PR #80 has Oby author job author; use ask_review_again"]
        );
        let mut other = dispatch;
        other.repo = "deskree-inc/another".into();
        standalone.dispatches = vec![other];
        assert!(standalone.problems(&context, "zq9").is_empty());
    }

    /// BrainTests.cursorInDispatchEnum: the schema offers Cursor as a tool wherever one is named;
    /// every tool, connected or not (#534), and problems refuses one that isn't connected.
    #[test]
    fn cursor_in_dispatch_enum() {
        let context = Context {
            accounts: BTreeMap::from([
                ("auto".into(), vec!["auto".into(), "Work".into()]),
                ("cursor".into(), vec!["auto".into(), "Work".into()]),
            ]),
            repos: vec!["deskree-inc/oby".into()],
            ..Context::default()
        };
        let schema = schema(&context);
        let dispatch = &schema["properties"]["dispatches"]["items"]["properties"]["agent"]["enum"];
        assert_eq!(dispatch, &json!(["auto", "claude", "codex", "cursor"]));
        let setting =
            &schema["properties"]["setting"]["anyOf"][1]["properties"]["agent"]["anyOf"][1]["enum"];
        assert_eq!(setting, &json!(["claude", "codex", "cursor"]));
    }

    /// The other actions' fields, with Swift's refusal texts.
    #[test]
    fn job_actions_settings_and_lookups_are_checked() {
        let mut context = context();
        context.movable = vec!["ab12cd34".into(), "d0ne0000".into()];
        context.inbox = vec!["item-1".into()];
        context.permissions = vec!["ab12cd34".into()];
        let mut retry = Plan::of(Action::RetryJob, "");
        assert_eq!(
            retry.problems(&context, "zq9"),
            ["retry_job names 1 to 10 jobs"]
        );
        retry.jobs = Some(vec!["nope".into()]);
        assert_eq!(
            retry.problems(&context, "zq9"),
            ["nope isn't a job in the briefing"]
        );
        let mut answer = Plan::of(Action::AnswerInbox, "");
        answer.item = Some("item-1".into());
        assert_eq!(
            answer.problems(&context, "zq9"),
            ["answer_inbox gives an option or the user's words"]
        );
        answer.option = Some(0);
        answer.answer = Some("yes".into());
        assert_eq!(
            answer.problems(&context, "zq9"),
            [
                "answer_inbox gives an option or the user's words, not both",
                "option counts from 1"
            ]
        );
        let mut permission = Plan::of(Action::AnswerPermission, "");
        permission.jobs = Some(vec!["d0ne0000".into()]);
        assert_eq!(
            permission.problems(&context, "zq9"),
            [
                "d0ne0000 isn't waiting for the user's OK",
                "answer_permission needs its decision"
            ]
        );
        let mut setting = Plan::of(Action::SetSetting, "");
        setting.setting = Some(Setting {
            max_running: Some(30),
            ..Setting::default()
        });
        assert_eq!(
            setting.problems(&context, "zq9"),
            ["maxRunning goes from 1 to 20"]
        );
        setting.setting = Some(Setting {
            max_running: Some(3),
            model: Some("x".into()),
            ..Setting::default()
        });
        assert_eq!(
            setting.problems(&context, "zq9"),
            ["set_setting changes one model, maxRunning, or account reserve"]
        );
        let mut research = Plan::of(Action::Research, "");
        research.lookups = Some(vec![Lookup {
            tool: LookupTool::ReadFile,
            repo: Some("deskree-inc/oby".into()),
            reference: None,
            query: None,
            path: Some("../etc/passwd".into()),
            start_line: Some(1),
            end_line: Some(500),
            number: None,
            url: None,
        }]);
        assert_eq!(
            research.problems(&context, "zq9"),
            [
                "path must be relative, at most 300 characters, and contain no .. segment or leading slash or hyphen",
                "read_file range is at most 400 lines"
            ]
        );
        let mut fetch = Plan::of(Action::Research, "");
        fetch.lookups = Some(vec![Lookup {
            tool: LookupTool::FetchUrl,
            repo: None,
            reference: None,
            query: None,
            path: None,
            start_line: None,
            end_line: None,
            number: None,
            url: Some("http://user@example.com".into()),
        }]);
        assert_eq!(
            fetch.problems(&context, "zq9"),
            ["fetch_url needs a public HTTPS URL"]
        );
        assert!(is_https("https://docs.rs/serde?x=1"));
        assert!(!is_https("https://user:pw@example.com/"));
    }

    /// What obid's jobs can't carry is refused, never dropped (review on #551).
    #[test]
    fn epics_and_reads_are_refused_not_dropped() {
        let context = context();
        let mut plan = Plan::of(Action::Dispatch, "");
        plan.dispatches = vec![
            serde_json::from_value(json!({
            "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "epic": 30,
            "kind": "build", "task": "Work on epic #30"}))
            .unwrap(),
        ];
        assert_eq!(
            plan.problems(&context, "zq9"),
            ["epic is null: obid can't make one job per sub-issue yet; name the issues instead"]
        );
        plan.dispatches = vec![serde_json::from_value(json!({
            "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "reads": ["deskree-inc/oby"],
            "kind": "research", "task": "Compare"}))
        .unwrap()];
        assert!(plan.problems(&context, "zq9").contains(
            &"reads is null: obid's research jobs can't read other repositories yet".to_owned()
        ));
        let dispatch = &schema(&context)["properties"]["dispatches"]["items"]["properties"];
        assert_eq!(dispatch["epic"], json!({"type": "null"}));
        assert_eq!(dispatch["reads"], json!({"type": "null"}));
    }

    /// JobActionTests.swiftChecksWhatTheBrainNames
    #[test]
    fn obid_checks_what_the_brain_names() {
        let context = Context {
            movable: vec!["fa11ed00".into()],
            inbox: vec!["fa11ed00-failed-1".into()],
            ..Context::default()
        };
        let on = |action: &str, ids: &[&str]| {
            Plan::decode(
                json!({"action": action, "reply": "", "question": null, "dispatches": [], "jobs": ids})
                    .to_string()
                    .as_bytes(),
            )
            .unwrap()
        };
        let answer = |item: &str, option: Option<i64>, words: Option<&str>| {
            Plan::decode(
                json!({"action": "answer_inbox", "reply": "", "question": null, "dispatches": [], "jobs": [],
                       "item": item, "option": option, "answer": words})
                .to_string()
                .as_bytes(),
            )
            .unwrap()
        };
        for action in ["retry_job", "dismiss_job", "start_now"] {
            assert!(
                on(action, &["fa11ed00"])
                    .problems(&context, "c4n4ry")
                    .is_empty()
            );
        }
        assert_eq!(
            on("retry_job", &["nobody"]).problems(&context, "c4n4ry"),
            ["nobody isn't a job in the briefing"]
        );
        assert_eq!(
            on("start_now", &[]).problems(&context, "c4n4ry"),
            ["start_now names 1 to 10 jobs"]
        );
        assert!(
            answer("fa11ed00-failed-1", Some(1), None)
                .problems(&context, "c4n4ry")
                .is_empty()
        );
        assert!(
            answer("fa11ed00-failed-1", None, Some("try again"))
                .problems(&context, "c4n4ry")
                .is_empty()
        );
        assert_eq!(
            answer("nothing-1", Some(1), None).problems(&context, "c4n4ry"),
            ["answer_inbox names an item waiting in the inbox"]
        );
        assert_eq!(
            answer("fa11ed00-failed-1", None, None).problems(&context, "c4n4ry"),
            ["answer_inbox gives an option or the user's words"]
        );
        assert_eq!(
            answer("fa11ed00-failed-1", Some(1), Some("x")).problems(&context, "c4n4ry"),
            ["answer_inbox gives an option or the user's words, not both"]
        );
        // The fields belong to answer_inbox alone.
        let mut stray = on("retry_job", &["fa11ed00"]);
        stray.item = Some("fa11ed00-failed-1".into());
        assert_eq!(
            stray.problems(&context, "c4n4ry"),
            ["only answer_inbox has an item, an option or an answer"]
        );
        // The schema offers the actions; the items are the briefing's, checked above (#534).
        let schema = schema(&context).to_string();
        for part in [
            "\"retry_job\"",
            "\"dismiss_job\"",
            "\"answer_inbox\"",
            "\"start_now\"",
        ] {
            assert!(schema.contains(part), "{part}");
        }
        assert!(!schema.contains("fa11ed00-failed-1"));
        let prompt = crate::brain::planner::system(false);
        for action in ["retry_job", "dismiss_job", "answer_inbox", "start_now"] {
            assert!(prompt.contains(action), "{action}");
        }
    }

    /// ReadJobTests.readJobPlansAreChecked
    #[test]
    fn read_job_plans_are_checked() {
        let context = Context {
            accounts: BTreeMap::from([("claude".into(), vec!["default".into()])]),
            repos: vec!["deskree-inc/oby".into()],
            movable: vec!["aaaa1111".into(), "bbbb2222".into()],
            ..Context::default()
        };
        let mut read = Plan::of(Action::ReadJob, "");
        read.jobs = Some(vec!["aaaa1111".into()]);
        assert!(read.problems(&context, "zq9").is_empty());
        read.jobs = Some(vec!["zz".into()]);
        assert_eq!(
            read.problems(&context, "zq9"),
            ["zz isn't a job Oby can read"]
        );
        read.jobs = Some(vec!["aaaa1111".into(), "bbbb2222".into()]);
        assert_eq!(read.problems(&context, "zq9"), ["read_job names one job"]);
        assert!(schema(&context).to_string().contains("read_job"));
        // It changes nothing, so the loop doesn't count it as an action that did something.
        assert!(!Action::ReadJob.acts() && !Action::Research.acts());
    }

    /// FinishFromPRTests.finishingAnIssueFromAPullRequestIsAValidFixBuildOrTest and
    /// theBrainIsToldToDispatchFromThePullRequestsHead.
    #[test]
    fn finishing_an_issue_from_a_pull_request_is_a_valid_fix_build_or_test() {
        let context = context();
        let finish = |kind: &str| {
            let mut plan = Plan::of(Action::Dispatch, "");
            plan.dispatches = vec![
                serde_json::from_value(json!({
                "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "pr": 124,
                "issue": 19, "kind": kind, "task": "Finish #19 from PR #124"}))
                .unwrap(),
            ];
            plan.problems(&context, "zq9")
        };
        for kind in ["fix", "build", "test"] {
            assert!(finish(kind).is_empty(), "{kind}");
        }
        assert_eq!(
            finish("review"),
            [
                "a job is about a pr or an issue, not both, unless it's a fix, build or test of the issue that starts from the pr"
            ]
        );
        assert!(!finish("investigate").is_empty());
        let system = crate::brain::planner::system(false);
        assert!(system.contains("finish #19 from PR #124") && !system.contains("(never both)"));
    }

    #[test]
    fn unknown_kinds_are_investigations_and_branch_names_are_checked() {
        let dispatch: Dispatch =
            serde_json::from_value(json!({"repo": "r", "kind": "audit", "task": "t"})).unwrap();
        assert_eq!(dispatch.kind, Kind::Investigate);
        for good in ["dev", "oby/fix-12", "release-1.2"] {
            assert!(is_branch_name(good), "{good}");
        }
        for bad in [
            "-x", "/x", ".x", "x/", "x.", "x.lock", "a..b", "a//b", "a/.b", "a b",
        ] {
            assert!(!is_branch_name(bad), "{bad}");
        }
    }
}
