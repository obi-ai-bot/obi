//! Jobs: made, queued, run side by side (at most `maxRunning` at once), stopped, waited on and
//! kept across restarts. Each runs in its own worktree, `home/worktrees/<job id>`, with its agent
//! and the repository's check in the job sandbox (`sandbox`).
//!
//! Two kinds of job run here. The owner's own work (`POST /v1/jobs`): a branch from the base, rounds
//! of the agent and the check, commits counted. And a review another Obi asked for
//! ([`Jobs::start_obi_review`]): a fresh worktree detached at the request's commit, the request
//! quoted as data, the agent reading only, the check in the sandbox, a typed result body.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use obi_protocol::types::ReviewRequest;
use serde_json::{Value, json};
use tokio::sync::{Notify, watch};

use crate::agent::{self, Event as AgentEvent, Launch, Tool};
use crate::config::{Config, Repo};
use crate::events::Events;
use crate::job::{Job, ObiRef, Phase, Status, Waiting};
use crate::process::{self, Signal};
use crate::sandbox::{self, Sandbox, Spec};
use crate::store::{self, Store};
use crate::{acp, codex, git, policy, review};

/// How long one round's turn may take (docs/runner-api.md, "limit").
pub const ROUND_LIMIT: Duration = Duration::from_secs(45 * 60);
/// How long one run of the check may take.
pub const CHECK_LIMIT: Duration = Duration::from_secs(20 * 60);
/// What a check run that took too long ends with.
pub const CHECK_TOO_LONG: &str = "obid stopped it after 20 minutes, the most a test run may take.";
/// How much of a check's output obid keeps: its end.
const CHECK_OUTPUT_MAX: usize = 64 * 1024;
/// Claude Code's own turn limit for a round.
const MAX_TURNS: &str = "200";
/// The kinds whose work is commits: one that ends with none committed failed.
const COMMITTING: [&str; 3] = ["build", "fix", "test"];

/// A job the owner describes whole (`POST /v1/jobs`), checked.
#[derive(Debug, Clone, Default)]
pub struct NewJob {
    pub repo: String,
    pub kind: String,
    pub task: String,
    pub title: Option<String>,
    pub request: Option<String>,
    pub pr: Option<u64>,
    pub issue: Option<u64>,
    pub account: Option<String>,
    pub agent: Option<String>,
    pub branch: Option<String>,
    pub base: Option<String>,
    pub rounds: Option<u32>,
    pub check: Option<String>,
    pub model: Option<String>,
    pub files: Option<Vec<String>>,
    pub mode: Option<String>,
}

/// A review another Obi asked for, once the owner or a remembered decision accepted it.
#[derive(Debug, Clone)]
pub struct ObiReview {
    pub correlation_id: String,
    pub request_id: String,
    pub from: String,
    pub from_owner: String,
    /// The `review_request` body exactly as received, already checked against the spec.
    pub body: Value,
}

/// What obid does when an Obi-to-Obi review job ends, before the job says it has: the exchange's
/// publish gate and reply (`sphere::Link::review_ended`). Given the job and whether it ended done.
pub type ReviewHook = Arc<
    dyn Fn(Job, bool) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>
        + Send
        + Sync,
>;

/// Why a job couldn't be made: a person can read it (`422`).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct Refused(pub String);

struct State {
    jobs: HashMap<String, Job>,
    /// The jobs a worker runs now, and how to tell it to stop.
    workers: HashMap<String, watch::Sender<Signal>>,
}

/// Every job obid has, and the workers running them.
pub struct Jobs {
    config: Config,
    store: Store,
    events: Events,
    sandbox: Result<Sandbox, String>,
    state: Mutex<State>,
    changed: Notify,
    max_running: usize,
    shutting_down: std::sync::atomic::AtomicBool,
    identity: (String, String),
    /// One preparation at a time per repository (Engine/Desk.swift, `setups`): its clone is
    /// fetched and its worktrees added one after the other, never at once.
    preparing: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    /// Told when an Obi-to-Obi review ends.
    review_hook: std::sync::OnceLock<ReviewHook>,
}

impl Jobs {
    /// Opens the jobs kept in `home/jobs`. Those that were queued or running when obid stopped
    /// carry on once [`Jobs::resume`] runs, as after any restart.
    pub fn open(
        config: Config,
        events: Events,
        sandbox: Result<Sandbox, String>,
    ) -> std::io::Result<Arc<Jobs>> {
        let store = Store::open(&config.home)?;
        let mut jobs = HashMap::new();
        for mut job in store.load_all() {
            if job.status == Status::Running {
                job.status = Status::Queued;
                job.step = "obid restarted while this ran: starting it again".into();
                job.phase = Some(Phase::Prepare);
                let _ = store.save(&job);
            }
            jobs.insert(job.id.clone(), job);
        }
        let identity = commit_identity(&config.owner);
        Ok(Arc::new(Jobs {
            config,
            store,
            events,
            sandbox,
            state: Mutex::new(State {
                jobs,
                workers: HashMap::new(),
            }),
            changed: Notify::new(),
            max_running: crate::api::MAX_RUNNING as usize,
            shutting_down: std::sync::atomic::AtomicBool::new(false),
            identity,
            preparing: Mutex::new(HashMap::new()),
            review_hook: std::sync::OnceLock::new(),
        }))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Who is told when an Obi-to-Obi review job ends (once; a second call changes nothing).
    pub fn on_review_end(&self, hook: ReviewHook) {
        let _ = self.review_hook.set(hook);
    }

    /// Tells the hook the review job `id` ended (`done` or not), and waits for it.
    async fn review_ended(&self, id: &str, done: bool) {
        let (Some(hook), Some(job)) = (self.review_hook.get(), self.get(id)) else {
            return;
        };
        if job.obi.is_some() {
            hook(job, done).await;
        }
    }

    /// Starts the queued jobs there are slots for.
    pub fn resume(self: &Arc<Self>) {
        self.schedule();
    }

    /// One job.
    pub fn get(&self, id: &str) -> Option<Job> {
        self.lock().jobs.get(id).cloned()
    }

    /// The latest `limit` jobs, newest first.
    pub fn list(&self, limit: usize) -> Vec<Job> {
        let mut jobs: Vec<Job> = self.lock().jobs.values().cloned().collect();
        jobs.sort_by(|a, b| b.created.cmp(&a.created).then_with(|| b.id.cmp(&a.id)));
        jobs.truncate(limit);
        jobs
    }

    /// How many slots are taken: jobs a worker runs.
    pub fn running(&self) -> usize {
        self.lock().workers.len()
    }

    /// How many of them run on the account `id`.
    pub fn running_on(&self, account: &str) -> usize {
        let state = self.lock();
        state
            .workers
            .keys()
            .filter(|id| state.jobs.get(*id).is_some_and(|j| j.account == account))
            .count()
    }

    /// Changes the job `id` with `change`, keeps it and tells the apps. `None` for a job obid
    /// doesn't have.
    fn update(&self, id: &str, change: impl FnOnce(&mut Job)) -> Option<Job> {
        let job = {
            let mut state = self.lock();
            let job = state.jobs.get_mut(id)?;
            change(job);
            job.clone()
        };
        if let Err(e) = self.store.save(&job) {
            tracing::error!("can't keep job {id}: {e}");
        }
        self.events.send("job", job.to_json());
        self.changed.notify_waiters();
        Some(job)
    }

    fn insert(&self, job: Job) -> Job {
        if let Err(e) = self.store.save(&job) {
            tracing::error!("can't keep job {}: {e}", job.id);
        }
        self.lock().jobs.insert(job.id.clone(), job.clone());
        self.events.send("job", job.to_json());
        self.changed.notify_waiters();
        job
    }

    fn new_id(&self) -> String {
        loop {
            let mut bytes = [0u8; 4];
            getrandom::fill(&mut bytes).expect("the system's random source works");
            let id = hex::encode(bytes);
            if !self.lock().jobs.contains_key(&id) {
                return id;
            }
        }
    }

    /// The configuration of `tool`'s adapter, when obid has one.
    fn agent_config(&self, tool: Tool) -> Option<&crate::config::Agent> {
        match tool {
            Tool::Claude => self.config.agents.claude.as_ref(),
            Tool::Codex => self.config.agents.codex.as_ref(),
            Tool::Cursor => self.config.agents.cursor.as_ref(),
        }
    }

    /// `tool`'s accounts: the configured ones, or its own default login (Claude Code's and
    /// Codex's; a Cursor account always has a folder of its own).
    fn accounts(&self, tool: Tool) -> Vec<crate::config::Account> {
        let Some(agent) = self.agent_config(tool) else {
            return Vec::new();
        };
        match tool {
            Tool::Claude => claude_accounts(agent),
            Tool::Codex if agent.accounts.is_empty() => vec![crate::config::Account {
                id: "codex".into(),
                name: "Codex".into(),
                config_dir: None,
            }],
            _ => agent.accounts.clone(),
        }
    }

    /// The tool and account a job runs on: the tool named (`claude`, `codex`, `cursor`; `auto` or
    /// none for any), and the account named (by id or name), or the first account of the first
    /// tool obid has (Claude Code, then Codex, then Cursor).
    fn pick(
        &self,
        agent: Option<&str>,
        named: Option<&str>,
    ) -> Result<(Tool, crate::config::Account), Refused> {
        let tools: Vec<Tool> = match agent
            .map(str::trim)
            .filter(|a| !a.is_empty() && !a.eq_ignore_ascii_case("auto"))
        {
            None => Tool::ALL
                .into_iter()
                .filter(|t| self.agent_config(*t).is_some())
                .collect(),
            Some(id) => {
                let tool = Tool::from_id(id).ok_or_else(|| {
                    Refused(format!("agent is claude, codex or cursor, not {id}."))
                })?;
                if self.agent_config(tool).is_none() {
                    return Err(Refused(format!(
                        "obid has no {} set up: its configuration names no agents.{id}.",
                        tool.name()
                    )));
                }
                vec![tool]
            }
        };
        if tools.is_empty() {
            return Err(Refused(
                "obid has no agent set up: its configuration names no agents.claude, agents.codex or agents.cursor.".into(),
            ));
        }
        let named = named
            .map(str::trim)
            .filter(|n| !n.is_empty() && !n.eq_ignore_ascii_case("auto"));
        for tool in &tools {
            let accounts = self.accounts(*tool);
            let found = match named {
                None => accounts.into_iter().next(),
                Some(named) => accounts
                    .into_iter()
                    .find(|a| a.id == named || a.name == named),
            };
            if let Some(account) = found {
                return Ok((*tool, account));
            }
        }
        Err(Refused(match (named, tools.as_slice()) {
            (Some(named), _) => format!("There's no account {named}."),
            (None, [tool]) => format!(
                "obid has no {} account: agents.{}.accounts names none.",
                tool.name(),
                tool.id()
            ),
            (None, _) => "obid has no account to run the job on.".into(),
        }))
    }

    /// The tool and account a job was made for.
    fn job_account(&self, job: &Job) -> Result<(Tool, crate::config::Account), String> {
        let tool = Tool::from_id(&job.agent)
            .ok_or_else(|| format!("obid has no adapter for {}.", job.agent))?;
        self.pick(Some(tool.id()), Some(&job.account))
            .map_err(|e| e.0)
    }

    fn repo(&self, repo: &str) -> Option<&Repo> {
        self.config.repos.iter().find(|r| r.repo == repo)
    }

    /// Makes a job the owner described whole, queued.
    pub fn create(self: &Arc<Self>, new: NewJob) -> Result<Job, Refused> {
        let repo = self
            .repo(&new.repo)
            .ok_or_else(|| Refused(format!("{} isn't a repository obid knows.", new.repo)))?
            .clone();
        if !crate::job::KINDS.contains(&new.kind.as_str()) {
            return Err(Refused(format!(
                "kind is one of {}.",
                crate::job::KINDS.join(", ")
            )));
        }
        let task_length = new.task.trim().chars().count();
        if task_length == 0 || new.task.chars().count() > 2000 {
            return Err(Refused("task is 1 to 2,000 characters.".into()));
        }
        if let Some(title) = &new.title
            && (title.trim().is_empty() || title.chars().count() > 60 || title.contains('\n'))
        {
            return Err(Refused("title is one line of 1 to 60 characters.".into()));
        }
        let (tool, account) = self.pick(new.agent.as_deref(), new.account.as_deref())?;
        if let Some(rounds) = new.rounds
            && !(1..=10).contains(&rounds)
        {
            return Err(Refused("rounds is 1 to 10.".into()));
        }
        if let Some(check) = &new.check
            && (check.contains('\n') || check.chars().count() > 200 || check.trim().is_empty())
        {
            return Err(Refused("check is one line of up to 200 characters.".into()));
        }
        if let Some(mode) = &new.mode
            && !crate::job::MODES.contains(&mode.as_str())
        {
            return Err(Refused("mode is ask, acceptEdits, plan or bypass.".into()));
        }
        let files = new.files.as_deref().map(claimed_files).transpose()?;
        if let Some(base) = &new.base
            && !git::is_branch_name(base)
        {
            return Err(Refused("That isn't a base branch obid can use.".into()));
        }
        if let Some(model) = &new.model
            && (model.trim().is_empty()
                || !model
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_')))
        {
            return Err(Refused(format!(
                "{model} isn't a model of {}.",
                tool.name()
            )));
        }
        let id = self.new_id();
        let mut job = Job::new(
            id.clone(),
            new.repo.clone(),
            new.kind.clone(),
            new.task.clone(),
            tool.id().into(),
            account.id.clone(),
        );
        job.request = new
            .request
            .clone()
            .filter(|r| !r.trim().is_empty())
            .unwrap_or_else(|| new.task.clone());
        job.title = new.title.map(|t| t.trim().to_owned());
        job.pr = new.pr;
        job.issue = new.issue;
        job.rounds = new.rounds;
        job.round = Some(1);
        job.check = new
            .check
            .or(repo.check.clone())
            .filter(|c| !c.trim().is_empty());
        job.model = new.model.map(|m| m.trim().to_owned());
        job.files = files;
        job.mode = Some(new.mode.unwrap_or_else(|| "bypass".into()));
        job.base = Some(new.base.unwrap_or_else(|| repo.default_branch.clone()));
        job.branch = match new
            .branch
            .map(|b| b.trim().to_owned())
            .filter(|b| !b.is_empty())
        {
            Some(branch) if git::is_branch_name(&branch) => branch,
            Some(_) => return Err(Refused("That isn't a branch name obid can create.".into())),
            None => match new.pr.or(new.issue) {
                Some(number) => format!("oby/{}-{number}", new.kind),
                None => format!("oby/{}-{id}", new.kind),
            },
        };
        job.phase = Some(Phase::Prepare);
        job.step = format!("Getting {} ready", job.repo_name());
        let job = self.insert(job);
        self.schedule();
        Ok(job)
    }

    /// Starts the review another Obi asked for (runner-api.md, "obid only: Obi-to-Obi review jobs",
    /// step 1): a `review` job on an account routing picks, titled from typed fields only.
    pub fn start_obi_review(self: &Arc<Self>, request: ObiReview) -> Result<Job, Refused> {
        let body: ReviewRequest = serde_json::from_value(request.body.clone())
            .map_err(|e| Refused(format!("The request isn't a review_request: {e}")))?;
        if self.repo(&body.repo).is_none() {
            return Err(Refused(format!(
                "{} isn't a repository obid knows.",
                body.repo
            )));
        }
        // Claude Code's: the review's answer is its structured output (`--json-schema`).
        let (_, account) = self.pick(Some(Tool::Claude.id()), None)?;
        let id = self.new_id();
        let repo_name = body
            .repo
            .rsplit('/')
            .next()
            .unwrap_or(&body.repo)
            .to_owned();
        let task = format!(
            "Review {} for {}: {} at {} into {}.",
            body.repo,
            request.from_owner,
            body.head_branch,
            &body.head_sha[..7.min(body.head_sha.len())],
            body.base_branch
        );
        let mut job = Job::new(
            id,
            body.repo.clone(),
            "review".into(),
            task,
            "claude".into(),
            account.id,
        );
        job.title = Some(format!("Review for {}: {repo_name}", request.from_owner));
        job.branch = body.head_branch.clone();
        job.base = Some(body.base_branch.clone());
        job.pr = body.pr;
        job.check = self.repo(&body.repo).and_then(|r| r.check.clone());
        job.mode = Some("bypass".into());
        job.round = Some(1);
        job.obi = Some(ObiRef {
            correlation_id: request.correlation_id.clone(),
            from: request.from.clone(),
            from_owner: request.from_owner.clone(),
            request_id: request.request_id.clone(),
        });
        job.obi_request = Some(json!({
            "from": request.from, "from_owner": request.from_owner, "type": "review_request", "body": request.body
        }));
        job.phase = Some(Phase::Prepare);
        job.step = format!("Getting {repo_name} ready");
        let job = self.insert(job);
        self.schedule();
        Ok(job)
    }

    /// Starts the queued jobs, oldest first, while slots are free; the others say they wait.
    fn schedule(self: &Arc<Self>) {
        if self
            .shutting_down
            .load(std::sync::atomic::Ordering::Relaxed)
        {
            return;
        }
        let mut start = Vec::new();
        let mut waiting = Vec::new();
        {
            let mut state = self.lock();
            let mut queued: Vec<(i64, String)> = state
                .jobs
                .values()
                .filter(|j| j.status == Status::Queued && !state.workers.contains_key(&j.id))
                .map(|j| (j.created, j.id.clone()))
                .collect();
            queued.sort();
            for (_, id) in queued {
                if state.workers.len() < self.max_running {
                    let (sender, receiver) = watch::channel(Signal::Run);
                    state.workers.insert(id.clone(), sender);
                    start.push((id, receiver));
                } else {
                    waiting.push(id);
                }
            }
        }
        let running = self.running();
        for id in waiting {
            let max = self.max_running;
            self.update(&id, |job| {
                let wait = Waiting {
                    kind: "cap".into(),
                    text: "a slot opens".into(),
                };
                if job.waiting.as_ref() != Some(&wait) {
                    job.waiting = Some(wait);
                    job.step = format!("Waiting for a free slot: {running} of {max} jobs running");
                }
            });
        }
        for (id, signal) in start {
            let jobs = self.clone();
            tokio::spawn(async move {
                jobs.work(&id, signal).await;
                jobs.lock().workers.remove(&id);
                jobs.changed.notify_waiters();
                jobs.schedule();
            });
        }
    }

    /// Stops a queued or running job: its agent and check end within 2 seconds, with everything they
    /// started. A job that already ended comes back as it is. `None` for one obid doesn't have.
    pub fn stop(&self, id: &str) -> Option<Job> {
        let job = self.get(id)?;
        if !job.status.is_active() {
            return Some(job);
        }
        let worked = match self.lock().workers.get(id) {
            Some(worker) => {
                let _ = worker.send(Signal::Stop);
                true
            }
            None => false,
        };
        let stopped = self.update(id, |job| {
            job.status = Status::Stopped;
            job.step = String::new();
            job.waiting = None;
            job.finished = Some(obi_protocol::time::now());
        });
        // A review that never started: its exchange still gets its answer. One that ran is
        // answered by its worker as it ends.
        if !worked
            && let (Some(job), Some(hook)) = (stopped.clone(), self.review_hook.get())
            && job.obi.is_some()
        {
            tokio::spawn(hook(job, false));
        }
        stopped
    }

    /// Stops every queued and running job: answers the ones it stopped.
    pub fn stop_all(&self) -> Vec<Job> {
        let ids: Vec<String> = self
            .lock()
            .jobs
            .values()
            .filter(|j| j.status.is_active())
            .map(|j| j.id.clone())
            .collect();
        ids.iter().filter_map(|id| self.stop(id)).collect()
    }

    /// Lets go of a job that needs the owner. `Err` when it doesn't need them.
    pub fn dismiss(&self, id: &str) -> Option<Result<Job, Refused>> {
        let job = self.get(id)?;
        if job.dismissed.is_some() {
            return Some(Ok(job));
        }
        if !job.needs_you() {
            return Some(Err(Refused(
                "This job doesn't need you: there's nothing to dismiss.".into(),
            )));
        }
        self.update(id, |job| job.dismissed = Some(obi_protocol::time::now()))
            .map(Ok)
    }

    /// The job once it has ended (done, failed, stopped or interrupted), or `None` for one obid
    /// doesn't have.
    pub async fn wait(&self, id: &str) -> Option<Job> {
        loop {
            let notified = self.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            let job = self.get(id)?;
            let worker = self.lock().workers.contains_key(id);
            if !job.status.is_active() && !worker {
                return Some(job);
            }
            notified.await;
        }
    }

    /// obid is stopping: every worker ends its agent and check now and leaves its job as it is,
    /// queued or running, so the next start carries it on. Returns once they have, or after
    /// `within`.
    pub async fn shutdown(&self, within: Duration) {
        self.shutting_down
            .store(true, std::sync::atomic::Ordering::Relaxed);
        for worker in self.lock().workers.values() {
            let _ = worker.send(Signal::Shutdown);
        }
        let _ = tokio::time::timeout(within, async {
            loop {
                let notified = self.changed.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                if self.lock().workers.is_empty() {
                    return;
                }
                notified.await;
            }
        })
        .await;
    }

    /// The lock that orders the preparations of `repo`.
    fn preparing(&self, repo: &str) -> Arc<tokio::sync::Mutex<()>> {
        self.preparing
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(repo.to_owned())
            .or_default()
            .clone()
    }

    fn worktree_path(&self, id: &str) -> PathBuf {
        crate::api::worktrees(&self.config.home).join(id)
    }

    fn temp_path(&self, id: &str) -> PathBuf {
        self.config.home.join("tmp").join(id)
    }

    /// The tool's own login as a job sees it, when its account has no `configDir`: a folder of the
    /// job's own (`home/logins/<job id>`), never the person's real one.
    fn login_path(&self, id: &str) -> PathBuf {
        self.config.home.join("logins").join(id)
    }

    /// Takes what an owner's job committed into its clone and moves its branch there: the
    /// worktree's HEAD commit, which it answers.
    ///
    /// In the sandbox the job's HEAD is detached and its new objects are in its own object folder
    /// (Spec::git_env); the clone's refs and objects were never writable. The objects the clone
    /// doesn't have are packed inside the job's sandbox again (so git reads nothing the job
    /// couldn't, whatever links or alternates it left in its object folder), indexed into the
    /// clone outside it ([`git::take_pack`] checks every object), and then the branch moves.
    async fn keep_commits(&self, id: &str) -> Result<String, String> {
        let job = self.get(id).ok_or("the job is gone")?;
        let worktree = self.worktree_path(id);
        if !worktree.join(".git").exists() {
            return Err("the job has no worktree".into());
        }
        let (admin, common) = git::worktree_dirs(&worktree)
            .await
            .map_err(|e| e.to_string())?;
        let clone = common
            .parent()
            .ok_or("the clone's git directory has no folder")?
            .to_path_buf();
        let head = git::git(&worktree, &["rev-parse", "--verify", "--quiet", "HEAD"])
            .await
            .map_err(|e| e.to_string())?;
        if !git::is_sha(&head) {
            return Err(format!("the worktree's HEAD isn't a commit: {head}"));
        }
        if !git::has_commit(&clone, &head).await {
            let sandbox = self.sandbox.as_ref().map_err(String::clone)?;
            let temp = self.temp_path(id);
            prepare_folder(&temp).map_err(|e| e.to_string())?;
            let mut spec = self.spec(&worktree, &admin, &common, &temp, true, Tool::Claude);
            spec.network = false;
            spec.read_only.clear();
            let git_args = |args: &[&str]| -> Vec<OsString> {
                let mut argv: Vec<OsString> = vec![
                    "git".into(),
                    "-c".into(),
                    "core.hooksPath=/dev/null".into(),
                    "-c".into(),
                    "core.fsmonitor=false".into(),
                ];
                argv.extend(args.iter().map(OsString::from));
                sandbox.wrap(&spec, &argv)
            };
            let env = process::sandbox_env(&process::tools_path(), &temp, &spec.git_env());
            let objects = sandboxed_output(
                &git_args(&[
                    "rev-list",
                    "--objects",
                    &head,
                    "--not",
                    "--branches",
                    "--remotes",
                    "--tags",
                ]),
                &env,
                &worktree,
                None,
            )
            .await?;
            let pack = sandboxed_output(
                &git_args(&["pack-objects", "--stdout", "--quiet"]),
                &env,
                &worktree,
                Some(objects),
            )
            .await?;
            git::take_pack(&clone, pack)
                .await
                .map_err(|e| e.to_string())?;
        }
        git::move_branch(&clone, &job.branch, &head)
            .await
            .map_err(|e| e.to_string())?;
        Ok(head)
    }

    fn log_path(&self, id: &str, name: &str) -> PathBuf {
        self.config.home.join("logs").join(id).join(name)
    }

    /// Runs a job to its end, unless it is stopped or obid shuts down.
    async fn work(self: &Arc<Self>, id: &str, signal: watch::Receiver<Signal>) {
        let Some(job) = self.get(id) else { return };
        if job.status != Status::Queued {
            return;
        }
        // Queued while its worktree gets ready, as the Swift runner has it: running once its agent
        // starts.
        self.update(id, |job| {
            job.waiting = None;
            job.step = format!("Getting {} ready", job.repo_name());
        });
        let temp = self.temp_path(id);
        let outcome = match prepare_folder(&temp).and_then(|()| {
            prepare_folder(self.log_path(id, "x").parent().expect("a log has a folder"))
        }) {
            Err(e) => Err(format!("obid couldn't make the job's folders: {e}")),
            Ok(()) if job.obi.is_some() => self.run_obi_review(id, &signal).await,
            Ok(()) => {
                let outcome = self.run_owner_job(id, &signal).await;
                // Whatever ended it (a limit, a stop, a failure), what it committed is on its
                // branch.
                if let Err(e) = self.keep_commits(id).await {
                    tracing::info!("job {id}: its commits stay in its worktree: {e}");
                }
                outcome
            }
        };
        let _ = std::fs::remove_dir_all(&temp);
        forget_login_secrets(&self.login_path(id));
        let stopped = *signal.borrow() != Signal::Run;
        match outcome {
            // The owner stopped it: its exchange gets a failed result. A shutdown leaves it be.
            _ if stopped => {
                if *signal.borrow() == Signal::Stop {
                    self.review_ended(id, false).await;
                }
            }
            Ok(()) => {}
            Err(why) => {
                let review = self.get(id).and_then(|j| {
                    let body: ReviewRequest =
                        serde_json::from_value(j.obi_request?.get("body")?.clone()).ok()?;
                    Some(review::failed_result(&body))
                });
                if job.obi.is_some() {
                    self.update(id, |job| job.review_result = review.clone());
                    self.review_ended(id, false).await;
                }
                self.update(id, |job| {
                    job.status = Status::Failed;
                    job.step = String::new();
                    job.summary = why;
                    job.finished = Some(obi_protocol::time::now());
                    if job.obi.is_some() {
                        job.review_result = review;
                    }
                });
            }
        }
    }

    /// Everything a sandboxed process of this job may and may not touch.
    fn spec(
        &self,
        worktree: &Path,
        admin: &Path,
        common: &Path,
        temp: &Path,
        commits: bool,
        tool: Tool,
    ) -> Spec {
        let mut hidden = vec![self.config.home.clone()];
        hidden.extend(person_homes());
        let mut read_only = sandbox::tool_roots(
            &process::tools_path(),
            &hidden,
            std::slice::from_ref(&self.config.home),
        );
        if let Some(bin) = self.agent_bin(tool) {
            read_only.extend(sandbox::install_root(
                &bin,
                &hidden,
                std::slice::from_ref(&self.config.home),
            ));
            read_only.push(bin);
        }
        Spec {
            worktree: worktree.to_path_buf(),
            git_admin: Some(admin.to_path_buf()),
            git_common: Some(common.to_path_buf()),
            commits,
            temp: temp.to_path_buf(),
            accounts: Vec::new(),
            read_only,
            hidden,
            // An agent keeps the network any agent has (its model's API); the check gets none.
            network: true,
        }
    }

    fn agent_bin(&self, tool: Tool) -> Option<PathBuf> {
        self.agent_config(tool)
            .and_then(|agent| process::resolve_bin(&agent.bin))
    }

    /// The agent's command line and environment for one turn of `tool` on `account`. `flags`
    /// follow Claude Code's binary; Codex and Cursor take their adapters' own.
    fn launch(
        &self,
        job: &Job,
        spec: &Spec,
        tool: Tool,
        flags: Vec<OsString>,
        account: &crate::config::Account,
    ) -> Result<Launch, String> {
        let sandbox = self
            .sandbox
            .as_ref()
            .map_err(|why| format!("obid can't run this job's agent: {why}"))?;
        let bin = self.agent_bin(tool).ok_or_else(|| {
            let named = self
                .agent_config(tool)
                .map(|c| c.bin.clone())
                .unwrap_or_default();
            format!("obid can't find {}'s binary ({named}).", tool.name())
        })?;
        let mut spec = spec.clone();
        let mut extra: Vec<(&str, OsString)> = spec.git_env();
        match (&account.config_dir, tool) {
            (Some(dir), _) => {
                std::fs::create_dir_all(dir).map_err(|e| {
                    format!(
                        "obid can't make the account's folder {}: {e}",
                        dir.display()
                    )
                })?;
                spec.accounts.push(dir.clone());
                match tool {
                    Tool::Claude => extra.push(("CLAUDE_CONFIG_DIR", dir.clone().into_os_string())),
                    Tool::Codex => extra.push(("CODEX_HOME", dir.clone().into_os_string())),
                    Tool::Cursor => {
                        acp::cursor::warn_if_long(dir);
                        acp::cursor::rewrite_config(dir).map_err(|e| {
                            format!(
                                "obid can't write Cursor's settings in {}: {e}",
                                dir.display()
                            )
                        })?;
                        extra.extend(acp::cursor::environment(dir));
                    }
                }
            }
            (None, Tool::Cursor) => {
                return Err(format!(
                    "Cursor · {} has no folder of its own (configDir), so Cursor didn't start.",
                    account.name
                ));
            }
            (None, _) => {
                // The tool's own login, without the person's real folders: obid copies the login
                // (and only that) into a folder of the job's own, which the agent sees as its
                // ~/.claude and ~/.claude.json (or ~/.codex) through its temporary HOME. What the
                // agent writes there (settings, hooks, MCP servers, a refreshed token) stays there:
                // the person's own ~/.claude, ~/.claude.json and ~/.codex are never writable, so
                // nothing a job runs can plant something the tool runs later outside the sandbox.
                let login = self.login_path(&job.id);
                let names = copy_login(login_home().as_deref(), &login, tool).map_err(|e| {
                    format!("obid can't copy {}'s login for this job: {e}", tool.name())
                })?;
                for name in names {
                    let link = spec.temp.join(name);
                    let _ = std::fs::remove_file(&link);
                    #[cfg(unix)]
                    std::os::unix::fs::symlink(login.join(name), &link)
                        .map_err(|e| format!("obid can't show the job its login: {e}"))?;
                }
                spec.accounts.push(login);
            }
        }
        if COMMITTING.contains(&job.kind.as_str()) || job.obi.is_none() {
            let (name, email) = &self.identity;
            for key in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"] {
                extra.push((key, name.into()));
            }
            for key in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"] {
                extra.push((key, email.into()));
            }
        }
        let argv = match tool {
            Tool::Claude => {
                let mut argv: Vec<OsString> = vec![bin.into_os_string()];
                argv.extend(flags);
                argv
            }
            Tool::Codex => codex::argv(bin),
            Tool::Cursor => acp::cursor::argv(bin),
        };
        Ok(Launch {
            argv: sandbox.wrap(&spec, &argv),
            env: process::sandbox_env(&process::tools_path(), &spec.temp, &extra),
            cwd: spec.worktree.clone(),
            stderr: self.log_path(&job.id, "agent.log"),
        })
    }

    /// Runs one turn of the job's tool and follows it on the job: its session and steps.
    async fn turn(
        &self,
        id: &str,
        tool: Tool,
        launch: Launch,
        prompt: &str,
        signal: &watch::Receiver<Signal>,
        obi_review: bool,
    ) -> Result<agent::Turn, String> {
        let worktree = launch.cwd.clone();
        let job = self.get(id).ok_or("the job is gone")?;
        let jobs = self;
        let decide = |name: &str, input: &Value| policy::decide(name, input, &worktree, obi_review);
        let on_event = |event| match event {
            AgentEvent::Session(session) => {
                jobs.update(id, |job| job.session = Some(session));
            }
            AgentEvent::Step(step) | AgentEvent::Denied(step) => {
                jobs.update(id, |job| job.step = step);
            }
        };
        let plan = job.mode.as_deref() == Some("plan");
        let ran = match tool {
            Tool::Claude => {
                agent::run_turn(
                    launch,
                    prompt,
                    ROUND_LIMIT,
                    signal.clone(),
                    decide,
                    on_event,
                )
                .await
            }
            Tool::Codex => {
                let options = codex::Options {
                    resume: job.session.clone(),
                    model: job.model.clone(),
                    plan,
                };
                codex::run_turn(
                    launch,
                    prompt,
                    &options,
                    ROUND_LIMIT,
                    signal.clone(),
                    decide,
                    on_event,
                )
                .await
            }
            Tool::Cursor => {
                let account = self
                    .job_account(&job)
                    .map(|(_, a)| a.name)
                    .unwrap_or_default();
                let options = acp::Options {
                    tool: tool.name().into(),
                    account,
                    resume: job.session.clone(),
                    model: job.model.clone(),
                    plan,
                    plan_mode: "plan".into(),
                    agent_mode: "agent".into(),
                };
                acp::run_turn(
                    launch,
                    prompt,
                    &options,
                    ROUND_LIMIT,
                    signal.clone(),
                    decide,
                    on_event,
                )
                .await
            }
        };
        ran.map_err(|e| format!("obid couldn't start {}: {e}", tool.name()))
    }

    /// Runs the repository's check in the job sandbox, with no network at all.
    async fn check(
        &self,
        id: &str,
        command: &str,
        spec: &Spec,
        signal: &watch::Receiver<Signal>,
    ) -> Result<CheckRun, String> {
        let sandbox = self
            .sandbox
            .as_ref()
            .map_err(|why| format!("obid can't run the check: {why}"))?;
        let mut spec = spec.clone();
        spec.network = false;
        spec.accounts.clear();
        let argv: Vec<OsString> = vec!["/bin/sh".into(), "-c".into(), command.into()];
        let argv = sandbox.wrap(&spec, &argv);
        let env = process::sandbox_env(&process::tools_path(), &spec.temp, &spec.git_env());
        let run = run_check(&argv, &env, &spec.worktree, CHECK_LIMIT, signal.clone())
            .await
            .map_err(|e| format!("obid couldn't run the check: {e}"))?;
        let _ = std::fs::write(self.log_path(id, "check.log"), &run.output);
        Ok(run)
    }

    /// A review another Obi asked for, steps 2 to 7 (runner-api.md, "obid only: Obi-to-Obi review
    /// jobs"). The publish gate and the reply are the exchange's, once the job has its result.
    async fn run_obi_review(
        self: &Arc<Self>,
        id: &str,
        signal: &watch::Receiver<Signal>,
    ) -> Result<(), String> {
        let job = self.get(id).ok_or("the job is gone")?;
        let quoted = job.obi_request.clone().ok_or("the job has no request")?;
        let request: ReviewRequest = serde_json::from_value(quoted["body"].clone())
            .map_err(|e| format!("the request isn't a review_request: {e}"))?;
        if let Err(why) = &self.sandbox {
            return Err(format!(
                "obid can't make the job sandbox on this machine, so it ran nothing: {why}"
            ));
        }
        let repo = self
            .repo(&request.repo)
            .ok_or_else(|| format!("{} isn't a repository obid knows.", request.repo))?
            .clone();
        if !git::is_branch_name(&request.head_branch)
            || !git::is_branch_name(&request.base_branch)
            || !git::is_sha(&request.head_sha)
        {
            return Err("The request's branches or commit aren't ones obid can fetch.".into());
        }

        // 2. The head (and the base, to compare with), into obid's clone; a fresh worktree at head_sha.
        self.update(id, |job| {
            job.step = format!("Fetching {}", request.head_branch)
        });
        let preparing = self.preparing(&repo.repo);
        let prepared = preparing.lock().await;
        let head_ref = format!(
            "+refs/heads/{0}:refs/remotes/origin/{0}",
            request.head_branch
        );
        let clone = git::ensure_clone(&self.config.home, &repo.repo, &repo.remote, &[head_ref])
            .await
            .map_err(|e| {
                format!(
                    "Couldn't fetch {} from {}: {e}",
                    request.head_branch, repo.repo
                )
            })?;
        let base_ref = format!(
            "+refs/heads/{0}:refs/remotes/origin/{0}",
            request.base_branch
        );
        if let Err(e) = git::git(
            &clone,
            &[
                "fetch",
                "--quiet",
                "--no-tags",
                "--no-write-fetch-head",
                "origin",
                &base_ref,
            ],
        )
        .await
        {
            tracing::info!(
                "job {id}: the base {} didn't fetch: {e}",
                request.base_branch
            );
        }
        if !git::has_commit(&clone, &request.head_sha).await {
            let _ = git::git(
                &clone,
                &[
                    "fetch",
                    "--quiet",
                    "--no-tags",
                    "--no-write-fetch-head",
                    "origin",
                    &request.head_sha,
                ],
            )
            .await;
        }
        if !git::has_commit(&clone, &request.head_sha).await {
            return Err(format!(
                "Couldn't fetch {} from {}: the remote doesn't have it.",
                request.head_sha, repo.repo
            ));
        }
        let worktree = self.worktree_path(id);
        if worktree.exists() {
            // A restart: start again from a fresh one.
            let _ = git::run(
                &clone,
                &[
                    "worktree".as_ref(),
                    "remove".as_ref(),
                    "--force".as_ref(),
                    worktree.as_os_str(),
                ],
                &[],
            )
            .await;
            let _ = std::fs::remove_dir_all(&worktree);
            let _ = git::git(&clone, &["worktree", "prune"]).await;
        }
        std::fs::create_dir_all(worktree.parent().expect("worktrees have a folder"))
            .map_err(|e| format!("obid can't make its worktrees folder: {e}"))?;
        git::run(
            &clone,
            &[
                "worktree".as_ref(),
                "add".as_ref(),
                "--quiet".as_ref(),
                "--detach".as_ref(),
                worktree.as_os_str(),
                request.head_sha.as_ref(),
            ],
            &[],
        )
        .await
        .map_err(|e| format!("obid couldn't make the job's worktree: {e}"))?;
        drop(prepared);
        let worktree_text = worktree.to_string_lossy().into_owned();
        self.update(id, |job| {
            job.worktree = Some(worktree_text);
            job.start_commit = Some(request.head_sha.clone());
        });

        // 3. The request, as data, in the worktree.
        let inputs = worktree.join(".obi").join("inputs");
        std::fs::create_dir_all(&inputs)
            .map_err(|e| format!("obid can't make .obi/inputs: {e}"))?;
        let text = serde_json::to_vec_pretty(&quoted).map_err(|e| e.to_string())?;
        std::fs::write(worktree.join(review::REQUEST_FILE), text)
            .map_err(|e| format!("obid can't write the request: {e}"))?;

        // 4. The agent, with a fixed prompt, in the sandbox.
        let (admin, common) = git::worktree_dirs(&worktree)
            .await
            .map_err(|e| e.to_string())?;
        let temp = self.temp_path(id);
        let (tool, account) = self.job_account(&job)?;
        let spec = self.spec(&worktree, &admin, &common, &temp, false, tool);
        let flags: Vec<OsString> = [
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--permission-prompt-tool",
            "stdio",
            "--permission-mode",
            "default",
            "--setting-sources",
            "",
            "--json-schema",
            review::OUTPUT_SCHEMA,
        ]
        .iter()
        .map(OsString::from)
        .collect();
        let launch = self.launch(&job, &spec, tool, flags, &account)?;
        if *signal.borrow() != Signal::Run {
            return Ok(());
        }
        self.update(id, |job| {
            if job.status == Status::Queued {
                job.status = Status::Running;
            }
            job.started.get_or_insert_with(obi_protocol::time::now);
            job.phase = Some(Phase::Work);
            job.step = "Reviewing".into();
        });
        let turn = self
            .turn(id, tool, launch, &review::prompt(&request), signal, true)
            .await?;
        if *signal.borrow() != Signal::Run {
            return Ok(());
        }
        if turn.timed_out {
            return Err("The review ran past 45 minutes, the most a round may take.".into());
        }
        if !turn.succeeded() {
            let said = turn.text();
            let first = said.lines().next().unwrap_or("").trim();
            return Err(if first.is_empty() {
                format!(
                    "Claude Code stopped without finishing the review ({}).",
                    turn.exit
                )
            } else {
                format!("Claude Code couldn't finish the review: {first}")
            });
        }
        let head = git::git(&worktree, &["rev-parse", "HEAD"])
            .await
            .map_err(|e| e.to_string())?;
        if head != request.head_sha {
            return Err("The review made a commit: a review only reads.".into());
        }

        // 5. Its review.
        let output = review::parse_output(
            turn.result
                .as_ref()
                .expect("a turn that succeeded has its result"),
        )?;

        // 6. The check, in the same sandbox, with no network.
        let tests_pass = match &job.check {
            Some(command) => {
                self.update(id, |job| {
                    job.phase = Some(Phase::Check);
                    job.step = format!("Running {command}");
                });
                let run = self.check(id, command, &spec, signal).await?;
                if *signal.borrow() != Signal::Run {
                    return Ok(());
                }
                run.passed
            }
            None => false,
        };

        // 7. The result; 8. the publish gate and the reply, the exchange's, before the job ends.
        let body = review::result(&request, &output, tests_pass);
        let findings = body["findings"].as_array().map_or(0, Vec::len);
        let outcome = body["outcome"].as_str().unwrap_or("").replace('_', " ");
        self.update(id, |job| {
            job.review_result = Some(body.clone());
            job.step = "Scanning the result for secrets and sending it".into();
        });
        self.review_ended(id, true).await;
        self.update(id, |job| {
            job.status = Status::Done;
            job.step = String::new();
            job.commits = Some(0);
            job.summary = format!(
                "Review for {}: {outcome}, {findings} finding(s), {}.",
                job.obi
                    .as_ref()
                    .map(|o| o.from_owner.as_str())
                    .unwrap_or("another Obi"),
                match (&job.check, tests_pass) {
                    (None, _) => "no check to run",
                    (Some(_), true) => "tests pass",
                    (Some(_), false) => "tests fail",
                }
            );
            job.review_result = Some(body);
            job.finished = Some(obi_protocol::time::now());
        });
        Ok(())
    }

    /// The owner's own work: a branch, rounds of the agent and the check, its commits counted.
    async fn run_owner_job(
        self: &Arc<Self>,
        id: &str,
        signal: &watch::Receiver<Signal>,
    ) -> Result<(), String> {
        let job = self.get(id).ok_or("the job is gone")?;
        if let Err(why) = &self.sandbox {
            return Err(format!(
                "obid can't make the job sandbox on this machine, so it ran nothing: {why}"
            ));
        }
        let repo = self
            .repo(&job.repo)
            .ok_or_else(|| format!("{} isn't a repository obid knows.", job.repo))?
            .clone();
        let base = job
            .base
            .clone()
            .unwrap_or_else(|| repo.default_branch.clone());
        let worktree = self.worktree_path(id);

        let preparing = self.preparing(&repo.repo);
        let prepared = preparing.lock().await;
        if !worktree.join(".git").exists() {
            let mut refspecs = vec![format!("+refs/heads/{base}:refs/remotes/origin/{base}")];
            if let Some(pr) = job.pr {
                refspecs.push(format!("+refs/pull/{pr}/head:refs/remotes/origin/pr/{pr}"));
            }
            let clone = git::ensure_clone(&self.config.home, &repo.repo, &repo.remote, &refspecs)
                .await
                .map_err(|e| format!("Couldn't get {} ready: {e}", repo.repo))?;
            let start = match job.pr {
                Some(pr) => format!("refs/remotes/origin/pr/{pr}"),
                None => format!("refs/remotes/origin/{base}"),
            };
            let start_commit = git::git(
                &clone,
                &["rev-parse", "--verify", &format!("{start}^{{commit}}")],
            )
            .await
            .map_err(|e| format!("Couldn't find {start} in {}: {e}", repo.repo))?;
            std::fs::create_dir_all(worktree.parent().expect("worktrees have a folder"))
                .map_err(|e| format!("obid can't make its worktrees folder: {e}"))?;
            let exists = git::git(
                &clone,
                &[
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    &format!("refs/heads/{}", job.branch),
                ],
            )
            .await
            .is_ok();
            if !exists {
                git::git(
                    &clone,
                    &["branch", "--no-track", "--", &job.branch, &start_commit],
                )
                .await
                .map_err(|e| format!("obid couldn't make the job's branch: {e}"))?;
            }
            // Detached at the branch: the sandbox never writes the clone's refs, so obid moves the
            // branch to the job's commits itself (git::keep_commits).
            let branch_ref = format!("refs/heads/{}", job.branch);
            let args: Vec<&std::ffi::OsStr> = vec![
                "worktree".as_ref(),
                "add".as_ref(),
                "--quiet".as_ref(),
                "--detach".as_ref(),
                worktree.as_os_str(),
                branch_ref.as_ref(),
            ];
            git::run(&clone, &args, &[])
                .await
                .map_err(|e| format!("obid couldn't make the job's worktree: {e}"))?;
            let worktree_text = worktree.to_string_lossy().into_owned();
            self.update(id, |job| {
                job.worktree = Some(worktree_text);
                job.start_commit.get_or_insert(start_commit);
                job.base = Some(base.clone());
            });
        }
        drop(prepared);
        let job = self.get(id).ok_or("the job is gone")?;
        let start_commit = job.start_commit.clone().unwrap_or_default();
        let (admin, common) = git::worktree_dirs(&worktree)
            .await
            .map_err(|e| e.to_string())?;
        let temp = self.temp_path(id);
        let (tool, account) = self.job_account(&job)?;
        let spec = self.spec(&worktree, &admin, &common, &temp, true, tool);
        // HEAD detached at the branch (a worktree from before may be on it), and the folder the
        // job's new objects go to (Spec::git_env).
        if let Ok(head) = git::git(&worktree, &["rev-parse", "--verify", "--quiet", "HEAD"]).await
            && git::git(&worktree, &["symbolic-ref", "--quiet", "HEAD"])
                .await
                .is_ok()
        {
            git::git(&worktree, &["update-ref", "--no-deref", "HEAD", &head])
                .await
                .map_err(|e| format!("obid couldn't detach the job's HEAD: {e}"))?;
        }
        if let Some(own) = spec.own_objects() {
            std::fs::create_dir_all(own.join("info"))
                .map_err(|e| format!("obid can't make the job's object folder: {e}"))?;
        }
        if tool == Tool::Cursor {
            let allowed = acp::cursor::repository_allowlist(&worktree);
            if !allowed.is_empty() {
                return Err(format!(
                    "Cursor didn't start: this repository's .cursor/cli.json lets it run {} without asking obid, and obid can't ask you about that yet.",
                    allowed.join(", ")
                ));
            }
        }

        let mut message = owner_prompt(&job);
        if job.session.is_some() {
            message = format!(
                "obid restarted while you were working: carry on with this round.\n\n{message}"
            );
        }
        loop {
            let job = self.get(id).ok_or("the job is gone")?;
            let round = job.current_round();
            let mut flags: Vec<OsString> = [
                "-p",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--verbose",
                "--permission-prompt-tool",
                "stdio",
                "--permission-mode",
                if job.mode.as_deref() == Some("plan") {
                    "plan"
                } else {
                    "default"
                },
                "--setting-sources",
                "",
                "--strict-mcp-config",
                "--max-turns",
                MAX_TURNS,
            ]
            .iter()
            .map(OsString::from)
            .collect();
            if let Some(model) = &job.model {
                flags.extend(["--model".into(), model.into()]);
            }
            if let Some(session) = &job.session {
                flags.extend(["--resume".into(), session.into()]);
            }
            let launch = self.launch(&job, &spec, tool, flags, &account)?;
            if *signal.borrow() != Signal::Run {
                return Ok(());
            }
            self.update(id, |job| {
                if job.status == Status::Queued {
                    job.status = Status::Running;
                }
                job.started.get_or_insert_with(obi_protocol::time::now);
                job.phase = Some(Phase::Work);
                job.step = format!("Starting {}", tool.name());
            });
            let turn = self.turn(id, tool, launch, &message, signal, false).await?;
            if *signal.borrow() != Signal::Run {
                return Ok(());
            }
            if turn.timed_out {
                self.update(id, |job| {
                    job.limit = Some("the round ran past 45 minutes".into())
                });
                return Err("Stopped at a limit: the round ran past 45 minutes. The branch is kept and nothing was pushed; one more round is possible.".into());
            }
            let said = turn.text();
            if !turn.succeeded() {
                let first = said.lines().next().unwrap_or("").trim().to_owned();
                return Err(if first.is_empty() {
                    format!("{} stopped without finishing ({}).", tool.name(), turn.exit)
                } else {
                    first
                });
            }
            self.update(id, |job| {
                job.summary = said.clone();
                job.summaries
                    .get_or_insert_with(Vec::new)
                    .push(said.clone());
            });
            let job = self.get(id).ok_or("the job is gone")?;
            let more_rounds = round < job.max_rounds();
            if let Some(command) = &job.check {
                self.update(id, |job| {
                    job.phase = Some(Phase::Check);
                    job.step = format!("Running {command}");
                });
                let run = self.check(id, command, &spec, signal).await?;
                if *signal.borrow() != Signal::Run {
                    return Ok(());
                }
                if run.passed {
                    break;
                }
                if !more_rounds {
                    let limit = format!("`{command}` still fails after {round} round(s)");
                    self.update(id, |job| job.limit = Some(limit.clone()));
                    return Err(format!(
                        "Stopped at a limit: {limit}. The branch is kept and nothing was pushed; one more round is possible."
                    ));
                }
                message = format!(
                    "`{command}` failed after your last round. Its output, from the end:\n\n```\n{}\n```\n\nFix what it shows, run it again in the foreground, commit, and finish with a short summary.",
                    tail(&run.output, 8_000)
                );
            } else if job.max_rounds() > 1 {
                let last = said
                    .lines()
                    .rev()
                    .find(|l| !l.trim().is_empty())
                    .unwrap_or("")
                    .trim();
                if last == "GOAL MET" || !more_rounds {
                    break;
                }
                message = "Your last line didn't say `GOAL MET`: carry on with what's left, then end with `GOAL MET` or `GOAL NOT MET: <what's left>`.".into();
            } else {
                break;
            }
            // What obid declined last round, for a tool whose answers carry no words (ACP).
            if !turn.notes.is_empty() {
                message = format!("{}\n\n{message}", turn.notes.join("\n"));
            }
            self.update(id, |job| job.round = Some(round + 1));
        }

        let head = self.keep_commits(id).await?;
        let commits = if start_commit.is_empty() || head == start_commit {
            0
        } else {
            git::git(
                &worktree,
                &["rev-list", "--count", &format!("{start_commit}..HEAD")],
            )
            .await
            .ok()
            .and_then(|n| n.parse::<u64>().ok())
            .unwrap_or(0)
        };
        let job = self.get(id).ok_or("the job is gone")?;
        let first_line = job.summary.lines().next().unwrap_or("").trim().to_owned();
        if COMMITTING.contains(&job.kind.as_str()) && commits == 0 {
            return Err(format!("Nothing committed: {first_line}"));
        }
        self.update(id, |job| {
            job.status = Status::Done;
            job.step = String::new();
            job.commits = Some(commits);
            if commits > 0 {
                job.publish_error = Some(format!(
                    "obid doesn't publish yet: the branch {} keeps the {commits} commit(s).",
                    job.branch
                ));
            }
            job.finished = Some(obi_protocol::time::now());
        });
        Ok(())
    }
}

/// The accounts Claude Code has: the configured ones, or the tool's own default login.
pub fn claude_accounts(claude: &crate::config::Agent) -> Vec<crate::config::Account> {
    if claude.accounts.is_empty() {
        vec![crate::config::Account {
            id: "default".into(),
            name: "Default".into(),
            config_dir: None,
        }]
    } else {
        claude.accounts.clone()
    }
}

/// What a sandboxed command (`argv`, wrapped already) prints, with `input` on its stdin; why not,
/// when it fails.
async fn sandboxed_output(
    argv: &[OsString],
    env: &[(OsString, OsString)],
    dir: &Path,
    input: Option<Vec<u8>>,
) -> Result<Vec<u8>, String> {
    use tokio::io::AsyncWriteExt;
    let mut child = tokio::process::Command::new(&argv[0])
        .args(&argv[1..])
        .env_clear()
        .envs(env.iter().map(|(k, v)| (k, v)))
        .current_dir(dir)
        .stdin(if input.is_some() {
            std::process::Stdio::piped()
        } else {
            std::process::Stdio::null()
        })
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("obid couldn't start git in the job's sandbox: {e}"))?;
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
        tokio::spawn(async move {
            let _ = stdin.write_all(&input).await;
        });
    }
    let output = tokio::time::timeout(Duration::from_secs(600), child.wait_with_output())
        .await
        .map_err(|_| "git in the job's sandbox took more than 600 seconds".to_owned())?
        .map_err(|e| format!("git in the job's sandbox failed: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let line = stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("");
        return Err(format!("git in the job's sandbox failed: {}", line.trim()));
    }
    Ok(output.stdout)
}

/// Where the tool's own login is: the `HOME` obid was started with, as the tool itself would look
/// when the person runs it, else the password database's.
fn login_home() -> Option<PathBuf> {
    let homes = person_homes();
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|home| homes.contains(home))
        .or_else(|| homes.into_iter().next())
}

/// The tool's own login, copied from `home` into the job's `login` folder, for an account with no
/// `configDir`: Claude Code's `~/.claude/.credentials.json` and `~/.claude.json`, Codex's
/// `~/.codex/auth.json` and `config.toml`. Nothing else of those folders (no settings, hooks,
/// commands or sessions of the person's). The credentials are copied again before every start (the
/// person may have signed in again) and removed when the job's run ends
/// ([`forget_login_secrets`]); the rest is copied once, then the job's own. Answers the names to
/// show in the job's `HOME`. (On macOS Claude Code keeps its credentials in the keychain, not in a
/// file: there is then no file to copy.)
fn copy_login(home: Option<&Path>, login: &Path, tool: Tool) -> std::io::Result<Vec<&'static str>> {
    let (shown, secret, once): (&[&'static str], &[&str], &[&str]) = match tool {
        Tool::Codex => (&[".codex"], &[".codex/auth.json"], &[".codex/config.toml"]),
        _ => (
            &[".claude", ".claude.json"],
            &[".claude/.credentials.json"],
            &[".claude.json"],
        ),
    };
    store::make_private_dir(login)?;
    // The job may have changed its login folder: obid writes only into a real folder there,
    // never through a link the job left in its place.
    let folder = login.join(shown[0]);
    if std::fs::symlink_metadata(&folder).is_ok_and(|m| !m.is_dir()) {
        std::fs::remove_file(&folder)?;
    }
    store::make_private_dir(&folder)?;
    let Some(home) = home else {
        return Ok(shown.to_vec());
    };
    let copy = |name: &str| -> std::io::Result<()> {
        let from = home.join(name);
        let to = login.join(name);
        // A regular file only: a link or a folder in its place is not a login.
        match std::fs::symlink_metadata(&from) {
            Ok(meta) if meta.is_file() => {}
            _ => return Ok(()),
        }
        let bytes = std::fs::read(&from)?;
        let _ = std::fs::remove_file(&to);
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        std::io::Write::write_all(&mut options.open(&to)?, &bytes)
    };
    for name in secret {
        copy(name)?;
    }
    for name in once {
        if std::fs::symlink_metadata(login.join(name)).is_err() {
            copy(name)?;
        }
    }
    Ok(shown.to_vec())
}

/// Removes the copied credentials from a job's login folder once its run ended: they are copied
/// again before its next start.
fn forget_login_secrets(login: &Path) {
    for (folder, name) in [(".claude", ".credentials.json"), (".codex", "auth.json")] {
        let folder = login.join(folder);
        // Only in a real folder: never through a link the job left in its place.
        if std::fs::symlink_metadata(&folder).is_ok_and(|m| m.is_dir()) {
            let _ = std::fs::remove_file(folder.join(name));
        } else {
            let _ = std::fs::remove_file(&folder);
        }
    }
}

/// The person's home folders: obid's `HOME`, and the one the password database names (they
/// differ when obid was given a `HOME` of its own).
pub fn person_homes() -> Vec<PathBuf> {
    let mut homes = Vec::new();
    if let Ok(Some(user)) = nix::unistd::User::from_uid(nix::unistd::getuid())
        && user.dir.is_absolute()
        && user.dir != Path::new("/")
    {
        homes.push(user.dir);
    }
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from)
        && home.is_absolute()
        && home != Path::new("/")
        && !homes.contains(&home)
    {
        homes.push(home);
    }
    homes
}

/// Who commits made in a job are by: the person's git identity as obid's own git sees it, else
/// the owner.
fn commit_identity(owner: &str) -> (String, String) {
    let read = |key: &str| {
        std::process::Command::new("git")
            .args(["config", "--get", key])
            .stdin(std::process::Stdio::null())
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
            .filter(|v| !v.is_empty())
    };
    (
        read("user.name").unwrap_or_else(|| owner.to_owned()),
        read("user.email").unwrap_or_else(|| format!("{owner}@users.noreply.obi.invalid")),
    )
}

/// A folder of the job's own, 0700.
fn prepare_folder(path: &Path) -> std::io::Result<()> {
    store::make_private_dir(path)
}

/// A path inside the repository: relative, no `..`, no NUL.
fn inside_repository(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\0')
        && path.split('/').all(|part| part != "..")
}

/// The `files` a client claims at dispatch, as Engine/Desk.swift's `validated` takes them: each
/// one cleaned (spaces, a sentence's trailing `.:!?*_`, Markdown's leading `*_`, `./` and doubled
/// slashes gone), the empty ones dropped, each kept once in order; at most 30, every one a path
/// inside the repository (Engine/Lead.swift, `isPath`), or the whole list is refused naming the
/// first that isn't.
pub fn claimed_files(files: &[String]) -> Result<Vec<String>, Refused> {
    let mut paths: Vec<String> = Vec::new();
    for file in files {
        let path = cleaned_path(file);
        if !path.is_empty() && !paths.contains(&path) {
            paths.push(path);
        }
    }
    if paths.len() > 30 {
        return Err(Refused(format!(
            "files holds at most 30 paths, not {}.",
            paths.len()
        )));
    }
    if let Some(bad) = paths.iter().find(|p| !is_claimable_path(p)) {
        return Err(Refused(format!(
            "{bad:?} isn't a path inside the repository."
        )));
    }
    Ok(paths)
}

fn cleaned_path(token: &str) -> String {
    let mut text = token.trim_matches(|c: char| c == ' ' || c == '\t');
    text = text.trim_end_matches(|c: char| ".:!?*_".contains(c));
    text = text.trim_start_matches(['*', '_']);
    let mut text = text.trim_matches(|c: char| c == ' ' || c == '\t');
    while let Some(rest) = text.strip_prefix("./") {
        text = rest;
    }
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if c == '/' && out.ends_with('/') {
            continue;
        }
        out.push(c);
    }
    out
}

/// Engine/Lead.swift's `isPath`: one line of up to 200 characters, relative (not `/` or `~`),
/// never `..`, no NUL.
fn is_claimable_path(path: &str) -> bool {
    let text = path.trim_matches(|c: char| c == ' ' || c == '\t');
    !text.is_empty()
        && text.chars().count() <= 200
        && !text.contains([
            '\n', '\r', '\u{2028}', '\u{2029}', '\u{85}', '\u{b}', '\u{c}',
        ])
        && !text.starts_with('/')
        && !text.starts_with('~')
        && inside_repository(text)
}

/// The end of `text`, at most `max` bytes, cut at a character.
fn tail(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut start = text.len() - max;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}

/// The first prompt of the owner's job (Engine/Jobs.swift, `Prompts.agent`, for what obid does).
fn owner_prompt(job: &Job) -> String {
    let base = job
        .base
        .clone()
        .unwrap_or_else(|| "the default branch".into());
    let mut lines = vec![match job.pr {
        Some(pr) => format!(
            "{} pull request #{pr} in {}. Its code is checked out here at the head of the branch {} (HEAD detached: commit as it is, obid moves the branch to your commits); compare it with origin/{base} (git diff origin/{base}...HEAD).",
            if job.kind == "review" {
                "Review"
            } else {
                "Work on"
            },
            job.repo,
            job.branch
        ),
        None => format!(
            "You're working in {}, in a git worktree of its own at the head of the branch {}, started from origin/{base}. Its HEAD is detached: commit as it is and don't switch branches; obid moves the branch to your commits after each turn.",
            job.repo, job.branch
        ),
    }];
    if let Some(issue) = job.issue {
        lines.push(format!("The work is about issue #{issue}."));
    }
    lines.push(format!("What the user asked for: {}", job.task));
    lines.push("Commit your changes here when they're ready. Don't push, open pull requests or post anything to GitHub: obid publishes the work itself.".into());
    if COMMITTING.contains(&job.kind.as_str()) {
        lines.push(format!("If you can't commit, say why in your summary's first line: a {} job that ends with no commits counts as nothing committed.", job.kind));
    }
    if let Some(check) = &job.check {
        lines.push(format!("The work counts as done only when `{check}` succeeds in this directory; obid runs it after you finish. Run it yourself first."));
    } else if job.max_rounds() > 1 {
        lines.push("End your summary with a last line that is exactly `GOAL MET` when the user's goal is fully met, or `GOAL NOT MET: <what's left>` when it isn't.".into());
    }
    lines.push("Run checks in the foreground, and never end a turn waiting on a background command: obid takes the end of your turn as the end of your work.".into());
    lines.push(
        "Finish with a short summary. Its first line is one sentence the user will see.".into(),
    );
    lines.join("\n\n")
}

/// How a run of the check went.
#[derive(Debug, Clone)]
pub struct CheckRun {
    pub passed: bool,
    /// Its output, stdout and stderr together, from the end.
    pub output: String,
}

/// Runs a check's command line: its output together, at most [`CHECK_LIMIT`] long, ended with
/// everything it started when it runs too long or the job stops.
pub async fn run_check(
    argv: &[OsString],
    env: &[(OsString, OsString)],
    cwd: &Path,
    limit: Duration,
    mut signal: watch::Receiver<Signal>,
) -> std::io::Result<CheckRun> {
    let (reader, writer) = std::io::pipe()?;
    let (program, args) = argv
        .split_first()
        .ok_or_else(|| std::io::Error::other("nothing to run"))?;
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .env_clear()
        .envs(env.iter().map(|(k, v)| (k, v)))
        .current_dir(cwd)
        .stdin(std::process::Stdio::null())
        .stdout(writer.try_clone()?)
        .stderr(writer)
        .process_group(0)
        .kill_on_drop(true);
    let mut child = command.spawn()?;
    // The writing ends live in the child now: the reader ends when it (and what it started) does.
    drop(command);
    let pgid = child.id().unwrap_or(0);
    let reading = tokio::task::spawn_blocking(move || {
        let mut reader = reader;
        let mut kept: Vec<u8> = Vec::new();
        let mut buffer = [0u8; 8192];
        loop {
            match std::io::Read::read(&mut reader, &mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    kept.extend_from_slice(&buffer[..n]);
                    if kept.len() > 2 * CHECK_OUTPUT_MAX {
                        kept.drain(..kept.len() - CHECK_OUTPUT_MAX);
                    }
                }
            }
        }
        kept
    });
    let mut timed_out = false;
    let status = tokio::select! {
        status = child.wait() => status.ok(),
        () = tokio::time::sleep(limit) => {
            timed_out = true;
            process::end_group(pgid, process::STOPPING).await;
            child.wait().await.ok()
        }
        _ = async { while signal.changed().await.is_ok() && *signal.borrow() == Signal::Run {} } => {
            process::end_group(pgid, process::STOPPING).await;
            child.wait().await.ok()
        }
    };
    // Whatever it left running would hold the output open.
    process::signal_group(pgid, nix::sys::signal::Signal::SIGKILL);
    let kept = tokio::time::timeout(Duration::from_secs(5), reading)
        .await
        .ok()
        .and_then(Result::ok)
        .unwrap_or_default();
    let mut output = String::from_utf8_lossy(&kept).into_owned();
    if output.len() > CHECK_OUTPUT_MAX {
        output = tail(&output, CHECK_OUTPUT_MAX).to_owned();
    }
    if timed_out {
        if !output.ends_with('\n') && !output.is_empty() {
            output.push('\n');
        }
        output.push_str(CHECK_TOO_LONG);
    }
    Ok(CheckRun {
        passed: !timed_out && status.is_some_and(|s| s.success()),
        output,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_inside_the_repository() {
        assert!(inside_repository("src/a.js"));
        assert!(inside_repository("Engine/"));
        assert!(!inside_repository("/etc/passwd"));
        assert!(!inside_repository("a/../../b"));
        assert!(!inside_repository(""));
    }

    #[test]
    fn tails_cut_at_characters() {
        assert_eq!(tail("abc", 5), "abc");
        assert_eq!(tail("aébc", 3), "bc");
    }

    #[test]
    fn the_owner_prompt_says_what_obid_does() {
        let mut job = Job::new(
            "j".into(),
            "o/r".into(),
            "fix".into(),
            "Fix it".into(),
            "claude".into(),
            "default".into(),
        );
        job.branch = "oby/fix-j".into();
        job.base = Some("main".into());
        job.check = Some("node --test".into());
        let prompt = owner_prompt(&job);
        assert!(prompt.contains("What the user asked for: Fix it"));
        assert!(prompt.contains("`node --test` succeeds"));
        assert!(prompt.contains("counts as nothing committed"));
    }
}
