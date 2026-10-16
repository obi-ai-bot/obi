//! Publishing the owner's work (docs/runner-api.md, "Job" and `GET`/`POST /v1/jobs/{id}/publish`),
//! ported from Engine/Publish.swift: the publish gate, then one pinned commit pushed to the job's
//! own `oby/` branch, then its pull request, ready for review. **obid never merges**, for anyone
//! (docs/ARCHITECTURE.md, "Trust boundaries").
//!
//! Nothing leaves before the gate passed over everything that goes out: every line every commit
//! adds (merges as what their author changed), the files those commits send read whole for the
//! secrets obid holds, every commit's message, the branch's name, and the pull request's title and
//! description, in plain text and in their encoded copies (`crate::scan`). If the scan can't run,
//! nothing goes out.
//!
//! Every git command runs in obid's own clone (`home/clones/<owner>/<name>`), never in the job's
//! worktree: the agent could write the worktree's git files, never the clone's. The push goes to
//! the repository's `remote` by its address (the clone's own push URL is invalid, so nothing an
//! agent runs can push), signed in by the owner's `gh` as a credential helper for `https`; the pull
//! request is opened with the owner's `gh` (`crate::github`). No token is ever in obid's
//! arguments or environment.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};

use crate::job::Job;
use crate::scan::{self, Finding, Verdict};
use crate::{git, github};

/// What publishing is doing now (`publishStep`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Step {
    Scan,
    Push,
    PullRequest,
}

impl Step {
    pub fn as_str(self) -> &'static str {
        match self {
            Step::Scan => "scan",
            Step::Push => "push",
            Step::PullRequest => "pullRequest",
        }
    }

    /// The Publish stage's detail while it's on this step (Engine/Publish.swift, `PublishStep`).
    pub fn detail(self) -> &'static str {
        match self {
            Step::Scan => "Secret scan",
            Step::Push => "Secret scan clean · pushing commits",
            Step::PullRequest => "Commits pushed · opening pull request",
        }
    }
}

/// Something obid sent out for a job (`outgoing`): ids only, never what was sent.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Outgoing {
    /// `push`, `pullRequest` or `pullRequestEdit`.
    pub action: String,
    pub repo: String,
    /// The commit pushed, or the pull request's URL.
    pub id: String,
    /// Where a push went; none for the rest.
    pub branch: Option<String>,
    /// Seconds since the epoch.
    pub date: i64,
}

impl Outgoing {
    pub fn new(action: &str, repo: &str, id: &str, branch: Option<&str>) -> Outgoing {
        Outgoing {
            action: action.into(),
            repo: repo.into(),
            id: id.into(),
            branch: branch.map(str::to_owned),
            date: obi_protocol::time::now(),
        }
    }

    /// As the runner API shows it: `branch` only on pushes.
    pub fn to_json(&self) -> Value {
        let mut value = json!({
            "action": self.action,
            "repo": self.repo,
            "id": self.id,
            "date": obi_protocol::time::format(self.date),
        });
        if let Some(branch) = &self.branch {
            value["branch"] = json!(branch);
        }
        value
    }
}

/// What a published job's `reviewError` says until obid runs Oby's review of it (#451).
pub const NOT_REVIEWED: &str =
    "obid doesn't run Oby's review yet: a person reviews the pull request on GitHub.";

/// Something the scan found in what would go out: where, which rule, and the commit whose patch or
/// message holds it. Never the secret itself.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Found {
    pub file: String,
    pub line: Option<usize>,
    pub rule: String,
    /// The commit whose patch (or message) introduced it; none for the pull request's texts.
    pub commit: Option<String>,
    /// Gone from the branch's tip but still in an earlier commit.
    pub history_only: bool,
}

impl Found {
    fn of(finding: Finding, commit: Option<&str>) -> Found {
        Found {
            file: finding.name,
            line: finding.line,
            rule: finding.rule,
            commit: commit.map(str::to_owned),
            history_only: false,
        }
    }
}

impl std::fmt::Display for Found {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.line {
            Some(line) => write!(f, "{}:{line} ({})", self.file, self.rule),
            None => write!(f, "{} ({})", self.file, self.rule),
        }
    }
}

/// Why nothing (more) went out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    /// The secret scan found something: nothing goes out.
    Blocked(Vec<Found>),
    /// Every commit is on the base already, compared by patch.
    AlreadyOnBase(String),
    /// The job was stopped while it published: nothing more goes out.
    Stopped,
    /// Anything else, as one line a person can read.
    Failed(String),
}

impl Failure {
    /// One line for the job and the apps: where the scan found something, never the secret.
    pub fn line(&self) -> String {
        match self {
            Failure::Blocked(found) => blocked(found),
            Failure::AlreadyOnBase(base) => {
                format!("Not published: its commits are already on {base}.")
            }
            Failure::Stopped => "Not published: the job was stopped.".into(),
            Failure::Failed(why) => why.clone(),
        }
    }
}

/// "Not published: possible secret in a.txt:3 (AWS access key), … and 2 more."
pub fn blocked(found: &[Found]) -> String {
    let more = if found.len() > 3 {
        format!(" and {} more", found.len() - 3)
    } else {
        String::new()
    };
    let places: Vec<String> = found.iter().take(3).map(Found::to_string).collect();
    format!(
        "Not published: possible secret in {}{more}.",
        places.join(", ")
    )
}

/// The one sentence a publish carries out: what the app shows, and what a device signs.
pub fn action(job: &Job, base: &str) -> String {
    if job.published.is_none() {
        format!(
            "Push {} to {} and open a pull request into {base}.",
            job.branch, job.repo
        )
    } else {
        format!(
            "Push the new commits on {} to {}, for its pull request into {base}.",
            job.branch, job.repo
        )
    }
}

/// Why obid won't publish this job, or none to go ahead: never a review, only its own `oby/`
/// branches, never onto `main`, `master` or the repository's default branch.
pub fn refusal(job: &Job, base: &str, default_branch: &str) -> Option<String> {
    if job.kind == "review" {
        return Some("A review made commits; nothing was published.".into());
    }
    if job.kind == "research" {
        return Some("Research jobs don't publish.".into());
    }
    let branch = job.branch.as_str();
    if !branch.starts_with("oby/") || !git::is_branch_name(branch) {
        return Some(format!(
            "obid only publishes its own oby/ branches, not {branch}."
        ));
    }
    if !git::is_branch_name(base) {
        return Some(format!("{base} isn't a branch name."));
    }
    if branch == base {
        return Some(format!("{branch} can't be its own base."));
    }
    if ["main", "master", default_branch].contains(&branch) {
        return Some(format!("obid never pushes to {branch}."));
    }
    if !github::is_repo(&job.repo) {
        return Some(format!("{} isn't a GitHub repository.", job.repo));
    }
    None
}

/// A remote whose address carries a login (`https://user:token@…`): obid never pushes with it,
/// since the address would be in git's arguments. An `ssh` user name is no secret.
pub fn has_login(remote: &str) -> bool {
    let Some((scheme, rest)) = remote.split_once("://") else {
        return false;
    };
    if scheme.eq_ignore_ascii_case("ssh") {
        return false;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    authority.contains('@')
}

/// The pull request's title in Conventional Commits form, ending with `(#issue)` when there is
/// one: the first commit subject already in that form, else the job's kind and the agent's first
/// line. At most 100 characters.
pub fn title(job: &Job, subjects: &[String]) -> String {
    let conventional =
        regex::Regex::new(r"^[a-z]+(\([^()]+\))?!?: \S.*$").expect("the title pattern compiles");
    let mut title = subjects
        .iter()
        .map(|s| s.trim())
        .find(|s| conventional.is_match(s))
        .map(str::to_owned);
    if title.is_none() {
        let kind = match job.kind.as_str() {
            "build" => "feat",
            "fix" => "fix",
            "test" => "test",
            _ => "chore",
        };
        let said = job
            .summaries
            .as_ref()
            .and_then(|s| s.last())
            .unwrap_or(&job.summary)
            .split('\n')
            .next()
            .unwrap_or("")
            .trim_matches(|c: char| c == ' ' || c == '\t' || c == '.')
            .to_owned();
        // "Fixed the thing" reads "fixed the thing" after the colon; "iOS" and "API" stay.
        let mut chars = said.chars();
        let line = match (chars.next(), chars.next()) {
            (Some(first), second)
                if first.is_uppercase() && !second.is_some_and(char::is_uppercase) =>
            {
                format!("{}{}", first.to_lowercase(), &said[first.len_utf8()..])
            }
            _ => said.clone(),
        };
        title = Some(format!(
            "{kind}: {}",
            if line.is_empty() {
                job.short_title()
            } else {
                line
            }
        ));
    }
    let text = title.unwrap_or_else(|| job.short_title());
    // The issue goes last, once: a subject may carry one already.
    let text = regex::Regex::new(r"\s*\(#\d+\)$")
        .expect("the issue pattern compiles")
        .replace(&text, "")
        .into_owned();
    let issue = job.issue.map(|n| format!(" (#{n})")).unwrap_or_default();
    let issue_len = issue.chars().count();
    let text = if text.chars().count() + issue_len > 100 {
        format!(
            "{}…",
            text.chars()
                .take(99usize.saturating_sub(issue_len))
                .collect::<String>()
        )
    } else {
        text
    };
    format!("{text}{issue}")
}

/// Whether a pull request closes its issue: not one whose body has a checklist (a feature or an
/// epic, which closes once its tests pass, never because one slice merged).
pub fn closes(issue: &str) -> bool {
    !issue.split('\n').any(|line| {
        let text = line.trim();
        text.starts_with("- [ ] ") || text.starts_with("- [x] ") || text.starts_with("- [X] ")
    })
}

/// The longest run of backticks in `text`.
fn longest_backticks(text: &str) -> usize {
    text.split(|c| c != '`').map(str::len).max().unwrap_or(0)
}

/// Text as inline code, whatever backticks it holds.
fn code(text: &str) -> String {
    let ticks = "`".repeat(longest_backticks(text) + 1);
    format!("{ticks} {text} {ticks}")
}

/// The pull request's description: every round's summary, what the owner asked for, the check and
/// the scan, `Closes #N` (`Part of #N` when it doesn't close it), and that obid opened it and never
/// merges. The agent's summaries are untrusted (it may have read someone else's words), so they go
/// in as code blocks: no mention, link or closing keyword in them takes effect.
pub fn body(job: &Job, closes: bool) -> String {
    let summaries: Vec<&String> = match &job.summaries {
        Some(list) if !list.is_empty() => list.iter().collect(),
        _ => vec![&job.summary],
    };
    let rounds: Vec<String> = summaries
        .iter()
        .enumerate()
        .map(|(i, summary)| {
            let fence = "`".repeat(3.max(longest_backticks(summary) + 1));
            let label = if summaries.len() == 1 {
                "The agent's summary:".to_owned()
            } else {
                format!("Round {}, the agent's summary:", i + 1)
            };
            format!("{label}\n\n{fence}\n{summary}\n{fence}")
        })
        .collect();
    let request = job
        .request
        .split('\n')
        .map(|l| format!("> {l}"))
        .collect::<Vec<_>>()
        .join("\n");
    let check = match &job.check {
        Some(check) => format!("- Check: {} passed.", code(check)),
        None => "- Check: none, the job had no check.".into(),
    };
    let issue = job
        .issue
        .map(|n| format!("\n\n{} #{n}", if closes { "Closes" } else { "Part of" }))
        .unwrap_or_default();
    format!(
        "{}\n\nWhat the user asked for:\n\n{request}\n\n{check}\n- Secret scan: clean.{issue}\n\nby Oby: Oby opened this pull request after the check passed and the secret scan was clean. Oby never merges it: a person does.",
        rounds.join("\n\n")
    )
}

/// What the agent hears when publishing found a possible secret in its changes: rewrite the
/// commits that hold it with fixup commits, autosquashed onto `origin/<base>`.
pub fn fix_prompt(found: &[Found], base: &str) -> String {
    let places: Vec<String> = found
        .iter()
        .map(|f| match &f.commit {
            Some(commit) => format!("- {f} — commit {commit}"),
            None => format!("- {f}"),
        })
        .collect();
    let in_files = found.iter().any(|f| f.file != "commit message");
    let in_messages = found.iter().any(|f| f.file == "commit message");
    let mut contexts = Vec::new();
    if in_files {
        contexts.push(if found.iter().any(|f| f.history_only) {
            "The flagged file value is already gone from the branch tip, but it is still present in the commit history."
        } else {
            "The flagged file value was introduced by the listed commit and must be removed from that commit's patch."
        });
    }
    if in_messages {
        contexts.push("The flagged commit-message value is in the listed commit's message and must be removed by rewriting that message.");
    }
    let file_fix = if in_files {
        "For findings in file diffs, make your change with `git commit --fixup=<commit>` for the commit that introduced each finding. "
    } else {
        ""
    };
    let message_fix = if in_messages {
        "For a commit-message finding, rewrite that commit's message with `git commit --fixup=reword:<commit>`. "
    } else {
        ""
    };
    format!(
        "obid's secret scan blocked publishing at these locations:\n\n{}\n\n{} Rewrite the listed commit(s) so no commit on this branch contains the value. {file_fix}{message_fix}Then run `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash origin/{base}`. Never merge the base into this branch. After rebasing, check `git log -p origin/{base}..HEAD` no longer shows the finding. Do not include any real secret value in the code, commit message, or summary. Run the checks in the foreground and finish with a short summary.",
        places.join("\n"),
        contexts.join(" ")
    )
}

/// What publishing tells the job as it goes, and asks before each thing it sends.
pub trait Hooks: Send + Sync {
    /// The step it's on, for the job's pipeline.
    fn progress(&self, step: Step);
    /// False when nothing more may go out (the job was stopped): asked right before the push and
    /// right before the pull request.
    fn proceed(&self) -> bool;
    /// Something just went out, for `outgoing` and the log.
    fn sent(&self, outgoing: Outgoing);
}

/// Where a job publishes from and to.
pub struct Target {
    /// obid's clone of the repository: where every git command runs.
    pub clone: PathBuf,
    /// The repository's `remote`, where the push goes.
    pub remote: String,
    pub default_branch: String,
    /// A private folder for the scan and the pull request's description, removed afterwards.
    pub scratch: PathBuf,
    /// The owner's GitHub CLI, or none when it isn't installed.
    pub gh: Option<PathBuf>,
    /// Held while the base is fetched into the clone: one fetch at a time per clone.
    pub fetching: Arc<tokio::sync::Mutex<()>>,
}

/// The options every diff the scan reads takes: no attribute or driver can hide what the push
/// sends, files named as they are.
const DIFF: &[&str] = &[
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--text",
    "--diff-filter=d",
    "--src-prefix=a/",
    "--dst-prefix=b/",
];

/// git in the clone, reading objects as they are (no replacements) and names as they are.
async fn git_in(clone: &Path, args: &[&str]) -> Result<String, String> {
    let mut all = vec!["--no-replace-objects", "-c", "core.quotePath=false"];
    all.extend_from_slice(args);
    git::git(clone, &all).await.map_err(|e| e.0)
}

/// The `-c` settings that let a push or `ls-remote` to an `https` remote sign in with the owner's
/// `gh` (its own login; git hears the credential on a pipe, never in an argument).
fn credentials(remote: &str, gh: Option<&Path>) -> Vec<String> {
    let mut args = vec!["-c".to_owned(), "credential.helper=".to_owned()];
    if remote.starts_with("https://")
        && let Some(gh) = gh
    {
        let quoted = gh.to_string_lossy().replace('\'', r"'\''");
        args.push("-c".into());
        args.push(format!("credential.helper=!'{quoted}' auth git-credential"));
    }
    args
}

/// Publishes `job` from `target`: the gate, then the push of one pinned commit, then the pull
/// request into `base`. Answers the pull request's URL.
pub async fn publish(
    job: &Job,
    base: &str,
    target: &Target,
    hooks: &dyn Hooks,
) -> Result<String, Failure> {
    hooks.progress(Step::Scan);
    if let Some(why) = refusal(job, base, &target.default_branch) {
        return Err(Failure::Failed(why));
    }
    if has_login(&target.remote) {
        return Err(Failure::Failed(
            "Not published: the repository's remote has a login in its address, and obid signs in only with gh's own login.".into(),
        ));
    }
    let clone = target.clone.as_path();
    // One commit from here on, so nothing added after the scan gets pushed.
    let head = git_in(
        clone,
        &[
            "rev-parse",
            "--verify",
            &format!("refs/heads/{}^{{commit}}", job.branch),
        ],
    )
    .await
    .ok()
    .filter(|h| git::is_sha(h))
    .ok_or_else(|| {
        Failure::Failed(format!(
            "Not published: can't read {} in obid's clone.",
            job.branch
        ))
    })?;
    let ancestry = git_in(clone, &["rev-list", "--parents", "-n", "1", &head])
        .await
        .map_err(|_| {
            Failure::Failed(format!(
                "Not published: can't read the history of {}.",
                job.branch
            ))
        })?;
    if ancestry.split_whitespace().count() == 1 {
        return Err(Failure::Failed(format!(
            "Not published: the head commit on {} has no parent.",
            job.branch
        )));
    }
    // The base as the remote has it now: work merged since the job started counts as merged.
    {
        let _fetching = target.fetching.lock().await;
        if let Err(e) = git::git(
            clone,
            &[
                "fetch",
                "--quiet",
                "--no-tags",
                "--no-write-fetch-head",
                "origin",
                &format!("+refs/heads/{base}:refs/remotes/origin/{base}"),
            ],
        )
        .await
        {
            tracing::info!(
                "job {}: couldn't fetch {base} before publishing: {e}",
                job.id
            );
        }
    }
    let since = format!("refs/remotes/origin/{base}");
    let range = format!("{since}..{head}");
    if git_in(clone, &["rev-list", "--count", &range]).await.ok() == Some("0".into()) {
        return Err(Failure::Failed(format!(
            "Nothing to publish: {} has no commits that aren't on {base}.",
            job.branch
        )));
    }
    match unmerged(clone, &since, &head).await {
        None => {
            return Err(Failure::Failed(format!(
                "Not published: can't compare {} with {base}.",
                job.branch
            )));
        }
        Some(0) => return Err(Failure::AlreadyOnBase(base.to_owned())),
        Some(_) => {}
    }
    let found = scan_changes(clone, &since, &head, &target.scratch).await?;
    if !found.is_empty() {
        return Err(Failure::Blocked(found));
    }
    // Everything else that goes out: every commit's message, and the pull request's title and
    // description.
    let subjects = git_in(
        clone,
        &["log", "--reverse", "--no-merges", "--format=%s", &range],
    )
    .await
    .map_err(|e| {
        Failure::Failed(format!(
            "Not published: the secret scan couldn't read the commit messages ({e})."
        ))
    })?;
    let subjects: Vec<String> = subjects.lines().map(str::to_owned).collect();
    let title = title(job, &subjects);
    // Read once: the scan checks the very description the pull request gets.
    let closes = match (job.issue, &target.gh) {
        (Some(number), Some(gh)) => github::issue_body(gh, &job.repo, number)
            .await
            .is_some_and(|issue| closes(&issue)),
        _ => false,
    };
    let description = body(job, closes);
    let texts = vec![
        ("branch name".to_owned(), job.branch.clone()),
        ("pull request title".to_owned(), title.clone()),
        ("pull request description".to_owned(), description.clone()),
    ];
    let mut said: Vec<Found> = match scan::scan(&texts, &target.scratch).await {
        Verdict::Clean => Vec::new(),
        Verdict::Found(found) => found.into_iter().map(|f| Found::of(f, None)).collect(),
        Verdict::CouldNotRun(why) => return Err(could_not_run(&why)),
    };
    said.extend(scan_messages(clone, &range, &target.scratch).await?);
    if !said.is_empty() {
        return Err(Failure::Blocked(said));
    }
    if !hooks.proceed() {
        return Err(Failure::Stopped);
    }
    hooks.progress(Step::Push);
    // A rebased branch replaces what's on the remote, and only what obid pushed there itself.
    let lease = lease(&head, job, target).await?;
    if !hooks.proceed() {
        return Err(Failure::Stopped);
    }
    push(&head, job, target, lease.as_deref()).await?;
    hooks.sent(Outgoing::new(
        "push",
        &job.repo,
        &head,
        Some(job.branch.as_str()),
    ));
    if !hooks.proceed() {
        return Err(Failure::Stopped);
    }
    hooks.progress(Step::PullRequest);
    let gh = target.gh.as_deref().ok_or_else(|| {
        Failure::Failed("Couldn't open the pull request: GitHub's CLI (gh) isn't installed.".into())
    })?;
    let file = target.scratch.join("pull-request.md");
    let _ = std::fs::remove_file(&file);
    crate::store::write_private(&file, description.as_bytes()).map_err(|e| {
        Failure::Failed(format!(
            "Couldn't open the pull request: obid couldn't write its description ({e})."
        ))
    })?;
    let opened = github::open_pull_request(gh, &job.repo, base, &job.branch, &title, &file).await;
    let _ = std::fs::remove_file(&file);
    let (url, sent) = opened.map_err(Failure::Failed)?;
    match sent {
        github::Sent::Opened => hooks.sent(Outgoing::new("pullRequest", &job.repo, &url, None)),
        github::Sent::Edited => hooks.sent(Outgoing::new("pullRequestEdit", &job.repo, &url, None)),
        github::Sent::Nothing => {}
    }
    Ok(url)
}

fn could_not_run(why: &str) -> Failure {
    Failure::Failed(format!(
        "Not published: the secret scan couldn't run ({why})."
    ))
}

/// How many commits up to `head` aren't on `since`, compared by patch, so a cherry-pick, a rebase
/// or a squash merge counts as on it. None when git can't say.
async fn unmerged(clone: &Path, since: &str, head: &str) -> Option<usize> {
    // One line per commit: "-" when a commit with the same patch is on the base, "+" when not.
    let cherry = git_in(clone, &["cherry", since, head]).await.ok()?;
    let left = cherry.lines().filter(|l| l.starts_with('+')).count();
    if left == 0 {
        return Some(0);
    }
    // A squash merge lands them all as one commit: then merging them into the base changes
    // nothing. A conflict (merge-tree fails) means they aren't all there.
    let Ok(merged) = git_in(clone, &["merge-tree", "--write-tree", since, head]).await else {
        return Some(left);
    };
    let Ok(tree) = git_in(clone, &["rev-parse", &format!("{since}^{{tree}}")]).await else {
        return Some(left);
    };
    Some(if merged.lines().next() == Some(tree.as_str()) {
        0
    } else {
        left
    })
}

/// The scan of what the push sends: each commit's patch (a merge as what its author changed from
/// git's own merge of its parents), gitleaks on the lines each adds, and every file those commits
/// send, read whole, for the secrets obid holds. Each finding names the commit whose patch
/// introduced it, and whether the branch's tip still has it.
async fn scan_changes(
    clone: &Path,
    since: &str,
    head: &str,
    scratch: &Path,
) -> Result<Vec<Found>, Failure> {
    let range = format!("{since}..{head}");
    let mut log_args = vec![
        "log",
        "-p",
        "--diff-merges=remerge",
        "--format=__OBID_COMMIT__%H",
    ];
    log_args.extend_from_slice(DIFF);
    log_args.push(&range);
    let log = git_in(clone, &log_args).await.map_err(|e| {
        Failure::Failed(format!(
            "Not published: the secret scan couldn't read the changes ({e})."
        ))
    })?;
    let mut commits: Vec<(String, Vec<&str>)> = Vec::new();
    for line in log.split('\n') {
        match line.strip_prefix("__OBID_COMMIT__") {
            Some(commit) if git::is_sha(commit) => commits.push((commit.to_owned(), Vec::new())),
            _ => {
                if let Some((_, lines)) = commits.last_mut() {
                    lines.push(line);
                }
            }
        }
    }
    let tip_range = format!("{since}...{head}");
    let mut diff_args = vec!["diff"];
    diff_args.extend_from_slice(DIFF);
    diff_args.push(&tip_range);
    let at_tip = scan::in_diff(&git_in(clone, &diff_args).await.map_err(|e| {
        Failure::Failed(format!(
            "Not published: the secret scan couldn't read the changes ({e})."
        ))
    })?);
    let mut found = Vec::new();
    for (commit, lines) in &commits {
        let diff = lines.join("\n");
        for finding in scan::in_diff(&diff) {
            let mut finding = Found::of(finding, Some(commit));
            finding.history_only = !at_tip
                .iter()
                .any(|t| t.name == finding.file && t.rule == finding.rule);
            found.push(finding);
        }
        let added: Vec<(String, usize, String)> = scan::parse_diff(&diff)
            .1
            .into_iter()
            .map(|a| (a.file, a.number, a.text))
            .collect();
        if !added.is_empty() {
            let leaked = scan::gitleaks_lines(&added, scratch)
                .await
                .map_err(|why| could_not_run(&why))?;
            let secrets = crate::secrets::known();
            found.extend(leaked.into_iter().map(|mut f| {
                f.name = secrets.redact(&f.name);
                Found::of(f, Some(commit))
            }));
        }
    }
    found.extend(
        known_secrets_in_files(clone, &range)
            .await
            .map_err(|e| {
                Failure::Failed(format!(
                    "Not published: the secret scan couldn't read the commits' files ({e})."
                ))
            })?
            .into_iter()
            .map(|f| Found::of(f, None)),
    );
    let mut seen = std::collections::HashSet::new();
    found.retain(|f| seen.insert(f.clone()));
    Ok(found)
}

/// The biggest file the scan for the secrets obid holds reads whole; a bigger one is a finding, so
/// it isn't pushed unscanned.
const BIGGEST_BLOB: usize = 32 << 20;

/// The secrets obid holds in every file the push sends that the base doesn't have, each read
/// whole (every version, in every commit, merges too). Errs when git can't say.
async fn known_secrets_in_files(clone: &Path, range: &str) -> Result<Vec<Finding>, String> {
    if crate::secrets::known().is_empty() {
        return Ok(Vec::new());
    }
    // "<sha> <path>" for every tree and file; a commit has no path.
    let listed = git_in(clone, &["rev-list", "--objects", range]).await?;
    let mut paths: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for line in listed.lines() {
        let Some((sha, path)) = line.split_once(' ') else {
            continue;
        };
        if !path.is_empty() && !paths.contains_key(sha) {
            paths.insert(sha.to_owned(), path.to_owned());
            order.push(sha.to_owned());
        }
    }
    if order.is_empty() {
        return Ok(Vec::new());
    }
    let batch = |format: &'static str| -> Vec<&'static std::ffi::OsStr> {
        vec![
            std::ffi::OsStr::new("--no-replace-objects"),
            std::ffi::OsStr::new("cat-file"),
            std::ffi::OsStr::new(format),
        ]
    };
    let input = format!("{}\n", order.join("\n")).into_bytes();
    let checked = git::run_bytes(
        clone,
        &batch("--batch-check=%(objectname) %(objecttype) %(objectsize)"),
        &[],
        Some(input),
    )
    .await
    .map_err(|e| e.0)?;
    let mut found = Vec::new();
    let mut blobs = Vec::new();
    for line in String::from_utf8_lossy(&checked).lines() {
        let parts: Vec<&str> = line.split(' ').collect();
        let [sha, "blob", size] = parts[..] else {
            continue;
        };
        let (Ok(size), Some(path)) = (size.parse::<usize>(), paths.get(sha)) else {
            continue;
        };
        if size > BIGGEST_BLOB {
            found.push(Finding {
                name: crate::secrets::known().redact(path),
                line: None,
                rule: "too big for the vault scan".into(),
            });
        } else {
            blobs.push(sha.to_owned());
        }
    }
    if blobs.is_empty() {
        return Ok(found);
    }
    let read = git::run_bytes(
        clone,
        &batch("--batch"),
        &[],
        Some(format!("{}\n", blobs.join("\n")).into_bytes()),
    )
    .await
    .map_err(|e| e.0)?;
    // Each: "<sha> blob <size>\n", the bytes, "\n".
    let mut rest = &read[..];
    while let Some(newline) = rest.iter().position(|b| *b == b'\n') {
        let header = String::from_utf8_lossy(&rest[..newline]).into_owned();
        let parts: Vec<&str> = header.split(' ').collect();
        let [sha, _, size] = parts[..] else {
            return Err("git cat-file answered something else".into());
        };
        let (Ok(size), Some(path)) = (size.parse::<usize>(), paths.get(sha)) else {
            return Err("git cat-file answered something else".into());
        };
        let start = newline + 1;
        let end = start + size;
        if end >= rest.len() {
            return Err("git cat-file stopped short".into());
        }
        found.extend(scan::known_secrets_in_file(
            &String::from_utf8_lossy(&rest[start..end]),
            path,
        ));
        rest = &rest[end + 1..];
    }
    Ok(found)
}

/// Each commit's message, scanned on its own so a finding names the commit whose message must be
/// rewritten. NUL framing is safe: a commit message can't hold NUL.
async fn scan_messages(clone: &Path, range: &str, scratch: &Path) -> Result<Vec<Found>, Failure> {
    let raw = git_in(clone, &["log", "-z", "--format=%H%x00%B", range])
        .await
        .map_err(|e| {
            Failure::Failed(format!(
                "Not published: the secret scan couldn't read the commit messages ({e})."
            ))
        })?;
    let fields: Vec<&str> = raw.split('\0').collect();
    let mut found = Vec::new();
    for pair in fields.chunks(2) {
        let [commit, message] = pair else { continue };
        let commit = commit.trim();
        if !git::is_sha(commit) {
            continue;
        }
        let texts = vec![("commit message".to_owned(), message.to_string())];
        match scan::scan(&texts, scratch).await {
            Verdict::Clean => {}
            Verdict::Found(more) => {
                found.extend(more.into_iter().map(|f| Found::of(f, Some(commit))))
            }
            Verdict::CouldNotRun(why) => return Err(could_not_run(&why)),
        }
    }
    Ok(found)
}

/// The commit the job's branch has on the remote, or none when it has no such branch yet.
async fn remote_head(job: &Job, target: &Target) -> Result<Option<String>, Failure> {
    let mut args = credentials(&target.remote, target.gh.as_deref());
    args.extend([
        "ls-remote".into(),
        "--heads".into(),
        "--".into(),
        target.remote.clone(),
        format!("refs/heads/{}", job.branch),
    ]);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let listed = git::git(&target.clone, &args).await.map_err(|e| {
        Failure::Failed(format!(
            "Couldn't read {} on the remote: {}",
            job.branch,
            github::said(&e.0)
        ))
    })?;
    let wanted = format!("refs/heads/{}", job.branch);
    Ok(listed.lines().find_map(|line| {
        let (commit, name) = line.split_once('\t')?;
        (name == wanted && git::is_sha(commit)).then(|| commit.to_owned())
    }))
}

/// What pushing `head` replaces on the job's branch: none when it only adds to what's there (no
/// branch yet, the same commit, or one `head` builds on), else the commit there, which a rebase
/// leaves behind. Only the commit obid pushed there last may be replaced: anything else someone
/// else pushed, and obid refuses rather than overwrite it.
async fn lease(head: &str, job: &Job, target: &Target) -> Result<Option<String>, Failure> {
    let Some(there) = remote_head(job, target).await? else {
        return Ok(None);
    };
    if there == head {
        return Ok(None);
    }
    // Fails too when the clone doesn't have that commit: then it isn't one obid pushed from here.
    if git_in(
        &target.clone,
        &["merge-base", "--is-ancestor", &there, head],
    )
    .await
    .is_ok()
    {
        return Ok(None);
    }
    if job.pushed_head() != Some(there.as_str()) {
        return Err(Failure::Failed(format!(
            "Not published: {} on GitHub is at {}, not the commit Oby pushed, so the rebase would overwrite someone else's work.",
            job.branch,
            &there[..12]
        )));
    }
    Ok(Some(there))
}

/// Pushes one commit to the job's own branch: no tags, submodules or signing. With `lease`, the
/// commit a rebase replaces, it pushes with `--force-with-lease` on that commit, so it fails when
/// the branch moved since; never to a branch obid didn't make.
async fn push(head: &str, job: &Job, target: &Target, lease: Option<&str>) -> Result<(), Failure> {
    if lease.is_some() && (!job.branch.starts_with("oby/") || !git::is_branch_name(&job.branch)) {
        return Err(Failure::Failed(format!(
            "obid never force-pushes {}: only the oby/ branches it made.",
            job.branch
        )));
    }
    let mut args = credentials(&target.remote, target.gh.as_deref());
    args.extend([
        "push".into(),
        "--no-follow-tags".into(),
        "--no-signed".into(),
        "--recurse-submodules=no".into(),
        "--no-verify".into(),
    ]);
    if let Some(there) = lease {
        args.push(format!(
            "--force-with-lease=refs/heads/{}:{there}",
            job.branch
        ));
    }
    args.extend([
        "--".into(),
        target.remote.clone(),
        format!("{head}:refs/heads/{}", job.branch),
    ]);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    git::git(&target.clone, &args).await.map_err(|e| {
        if lease.is_some() && e.0.contains("stale info") {
            Failure::Failed(format!(
                "Not published: {} moved on GitHub while Oby pushed the rebase, so it would overwrite someone else's work.",
                job.branch
            ))
        } else {
            Failure::Failed(format!(
                "Couldn't push {}: {}",
                job.branch,
                github::said(&e.0)
            ))
        }
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job() -> Job {
        let mut job = Job::new(
            "ab12cd34".into(),
            "deskree-inc/oby".into(),
            "fix".into(),
            "Fix the thing".into(),
            "claude".into(),
            "default".into(),
        );
        job.branch = "oby/fix-75".into();
        job.base = Some("dev".into());
        job
    }

    #[test]
    fn the_sentence_a_device_signs() {
        let mut job = job();
        assert_eq!(
            action(&job, "dev"),
            "Push oby/fix-75 to deskree-inc/oby and open a pull request into dev."
        );
        job.published = Some("https://github.com/deskree-inc/oby/pull/42".into());
        assert_eq!(
            action(&job, "dev"),
            "Push the new commits on oby/fix-75 to deskree-inc/oby, for its pull request into dev."
        );
    }

    #[test]
    fn only_its_own_branches_and_never_main() {
        let mut job = job();
        assert_eq!(refusal(&job, "dev", "main"), None);
        job.branch = "feature/x".into();
        assert!(refusal(&job, "dev", "main").unwrap().contains("oby/"));
        job.branch = "oby/fix-75".into();
        assert!(
            refusal(&job, "oby/fix-75", "main")
                .unwrap()
                .contains("its own base")
        );
        assert!(
            refusal(&job, "dev", "oby/fix-75")
                .unwrap()
                .contains("never pushes")
        );
        job.repo = "../etc".into();
        assert!(refusal(&job, "dev", "main").is_some());
        let mut review = self::job();
        review.kind = "review".into();
        assert_eq!(
            refusal(&review, "dev", "main").unwrap(),
            "A review made commits; nothing was published."
        );
    }

    #[test]
    fn a_login_in_the_remotes_address_is_refused() {
        assert!(has_login("https://user:secret@github.com/o/r.git"));
        assert!(has_login("https://x@github.com/o/r.git"));
        assert!(!has_login("https://github.com/o/r.git"));
        assert!(!has_login("https://github.com/o/r@x.git"));
        assert!(!has_login("ssh://git@github.com/o/r.git"));
        assert!(!has_login("git@github.com:o/r.git"));
        assert!(!has_login("file:///tmp/remote.git"));
    }

    #[test]
    fn titles_are_conventional_and_end_with_the_issue() {
        let mut job = job();
        job.summary = "Fixed the thing.\nMore.".into();
        assert_eq!(title(&job, &[]), "fix: fixed the thing");
        assert_eq!(
            title(&job, &["wip".into(), "fix(api): stop the leak (#3)".into()]),
            "fix(api): stop the leak"
        );
        job.issue = Some(75);
        assert_eq!(
            title(&job, &["fix(api): stop the leak (#3)".into()]),
            "fix(api): stop the leak (#75)"
        );
        job.summary = "API is faster".into();
        assert_eq!(title(&job, &[]), "fix: API is faster (#75)");
        job.summary = "x".repeat(200);
        let long = title(&job, &[]);
        assert_eq!(long.chars().count(), 100);
        assert!(long.ends_with("… (#75)"));
    }

    #[test]
    fn descriptions_quote_the_agent_and_never_promise_a_merge() {
        let mut job = job();
        job.summaries = Some(vec!["One ``` fence".into(), "Two @someone".into()]);
        job.request = "Fix it\nplease".into();
        job.check = Some("swift test".into());
        job.issue = Some(75);
        let text = body(&job, true);
        assert!(text.starts_with("Round 1, the agent's summary:\n\n````\nOne ``` fence\n````"));
        assert!(text.contains("Round 2, the agent's summary:\n\n```\nTwo @someone\n```"));
        assert!(text.contains("> Fix it\n> please"));
        assert!(text.contains("- Check: ` swift test ` passed."));
        assert!(text.contains("Closes #75"));
        assert!(text.contains("never merges"));
        assert!(body(&job, false).contains("Part of #75"));
        assert!(closes("A bug.\n"));
        assert!(!closes("Tests:\n  - [ ] it works\n"));
    }

    #[test]
    fn a_blocked_publish_names_places_never_secrets() {
        let found: Vec<Found> = (1..=5)
            .map(|line| Found {
                file: "a.txt".into(),
                line: Some(line),
                rule: "AWS access key".into(),
                commit: Some("c".repeat(40)),
                history_only: false,
            })
            .collect();
        assert_eq!(
            blocked(&found),
            "Not published: possible secret in a.txt:1 (AWS access key), a.txt:2 (AWS access key), a.txt:3 (AWS access key) and 2 more."
        );
        let prompt = fix_prompt(&found[..1], "dev");
        assert!(prompt.contains("--fixup=<commit>"));
        assert!(prompt.contains(&format!("commit {}", "c".repeat(40))));
        assert!(prompt.contains("git rebase -i --autosquash origin/dev"));
    }

    #[test]
    fn credentials_come_from_gh_only_for_https() {
        let gh = Path::new("/opt/it's/gh");
        assert_eq!(
            credentials("https://github.com/o/r.git", Some(gh)),
            [
                "-c",
                "credential.helper=",
                "-c",
                r"credential.helper=!'/opt/it'\''s/gh' auth git-credential"
            ]
        );
        assert_eq!(
            credentials("file:///tmp/r.git", Some(gh)),
            ["-c", "credential.helper="]
        );
    }
}
