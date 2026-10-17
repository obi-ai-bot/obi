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

/// What a published job's `reviewError` says until obid runs Oby's review of it (#525).
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

impl Found {
    /// The agent can rewrite what holds it with a fixup round: a file or a commit's message, not
    /// who the commit says made it, nor a file obid won't name.
    pub fn fixable(&self) -> bool {
        self.file != "commit author" && self.file != scan::HIDDEN_NAME
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
    /// Another publish of the same job is under way: this one sent nothing and changes nothing.
    Busy,
    /// The job may not be published now (nothing to publish, or not what was approved): nothing
    /// ran, and nothing changes.
    Refused(String),
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
            Failure::Busy => "obid is publishing it already.".into(),
            Failure::Refused(why) => why.clone(),
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
    // What the owner can do about a name obid won't repeat: where to look.
    let hidden = if found.iter().any(|f| f.file == scan::HIDDEN_NAME) {
        " obid won't repeat a name that holds a possible secret: it is among the names of the files and folders the branch adds to its base."
    } else {
        ""
    };
    format!(
        "Not published: possible secret in {}{more}.{hidden}",
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
    let all: Vec<&std::ffi::OsStr> = all.iter().map(std::ffi::OsStr::new).collect();
    git::run(clone, &all, SCAN_ENV).await.map_err(|e| e.0)
}

/// What the scan's git reads with: only obid's clone's own configuration, never the system's or
/// the person's (a `log.showRoot = false` there would hide a root commit's files from the scan).
const SCAN_ENV: &[(&str, &str)] = &[
    ("GIT_CONFIG_NOSYSTEM", "1"),
    ("GIT_CONFIG_GLOBAL", "/dev/null"),
    // Nor what obid's own environment would add (`git -c` from a parent, `GIT_CONFIG_KEY_<n>`).
    ("GIT_CONFIG_PARAMETERS", ""),
    ("GIT_CONFIG_COUNT", "0"),
];

/// The `-c` settings that let a push or `ls-remote` to an `https` remote sign in with the owner's
/// `gh` (its own login; git hears the credential on a pipe, never in an argument).
fn credentials(remote: &str, gh: Option<&Path>, unset: &[String]) -> Vec<String> {
    let quote = |text: &str| format!("'{}'", text.replace('\'', r"'\''"));
    let mut args = vec!["-c".to_owned(), "credential.helper=".to_owned()];
    if remote.starts_with("https://")
        && let Some(gh) = gh
    {
        // As `crate::github` runs it: with none of the variables obid keeps from agents and from
        // gh (`GH_TOKEN`, `GITHUB_TOKEN`, …), always those two, and the others obid has.
        let unset: String = unset
            .iter()
            .map(|name| format!(" -u {}", quote(name)))
            .collect();
        args.push("-c".into());
        args.push(format!(
            "credential.helper=!env{unset} {} auth git-credential",
            quote(&gh.to_string_lossy())
        ));
    }
    args
}

/// The variables in obid's environment that never reach gh (`crate::process::is_forbidden`),
/// `GH_TOKEN` and `GITHUB_TOKEN` always among them: names only, never their values.
fn forbidden_names() -> Vec<String> {
    let mut names = vec!["GH_TOKEN".to_owned(), "GITHUB_TOKEN".to_owned()];
    for (name, _) in std::env::vars_os() {
        let name = name.to_string_lossy().into_owned();
        if crate::process::is_forbidden(&name) && !names.contains(&name) {
            names.push(name);
        }
    }
    names
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
    // The base as the remote has it now: work merged since the job started counts as merged, and
    // what the remote doesn't have is all that the scan reads. Pinned to one commit, so another
    // fetch can't move it between the scan and the push. A base that can't be fetched sends
    // nothing.
    let since = {
        let _fetching = target.fetching.lock().await;
        git::git(
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
        .map_err(|e| {
            Failure::Failed(format!(
                "Not published: couldn't fetch {base}: {}",
                git_said(&e, &target.remote)
            ))
        })?;
        git_in(
            clone,
            &[
                "rev-parse",
                "--verify",
                &format!("refs/remotes/origin/{base}^{{commit}}"),
            ],
        )
        .await
        .ok()
        .filter(|c| git::is_sha(c))
        .ok_or_else(|| Failure::Failed(format!("Not published: can't read {base}.")))?
    };
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
    said.extend(scan_commits(clone, &range, &target.scratch).await?);
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
    let opened = {
        // GitHub may still show the commit obid pushed before as the pull request's head.
        let mut heads = vec![head.as_str()];
        heads.extend(job.pushed_head());
        github::open_pull_request(gh, &job.repo, base, &job.branch, &heads, &title, &file).await
    };
    let _ = std::fs::remove_file(&file);
    let (url, sent) = opened.map_err(Failure::Failed)?;
    match sent {
        github::Sent::Opened => hooks.sent(Outgoing::new("pullRequest", &job.repo, &url, None)),
        github::Sent::Edited => hooks.sent(Outgoing::new("pullRequestEdit", &job.repo, &url, None)),
        github::Sent::Nothing => {}
    }
    Ok(url)
}

/// What git said when a command of publishing failed: its last line on stderr, never the command
/// line (which names the remote and the credential helper), with the remote's address taken out.
fn git_said(error: &git::GitError, remote: &str) -> String {
    let said = error
        .0
        .rsplit_once(" failed: ")
        .map_or("no reason given", |(_, said)| said);
    github::said(&said.replace(remote, "the remote"))
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
    let unreadable = |e: String| {
        Failure::Failed(format!(
            "Not published: the secret scan couldn't read the changes ({e})."
        ))
    };
    // The names first: a finding anywhere else in a file whose name is flagged never shows it.
    let pushed = pushed_objects(clone, &range).await.map_err(unreadable)?;
    let mut found: Vec<Found> = scan::in_names(&pushed.names)
        .into_iter()
        .map(|f| Found::of(f, None))
        .collect();
    let names: Vec<String> = pushed.names.iter().map(|n| n.name.clone()).collect();
    let mut hidden: std::collections::HashSet<&str> = std::collections::HashSet::new();
    for (index, rule) in scan::gitleaks_names(&names, scratch)
        .await
        .map_err(|why| could_not_run(&why))?
    {
        if let Some(name) = names.get(index) {
            hidden.insert(name);
        }
        found.push(Found::of(
            Finding {
                name: scan::HIDDEN_NAME.into(),
                line: None,
                rule: format!("{rule} in a name"),
            },
            None,
        ));
    }
    let shown = |path: &str| -> String {
        if path.split('/').any(|part| hidden.contains(part)) {
            scan::HIDDEN_NAME.into()
        } else {
            scan::shown_name(path)
        }
    };
    let mut log_args = vec![
        "log",
        "-p",
        "--root",
        "--diff-merges=remerge",
        "--format=__OBID_COMMIT__%H",
    ];
    log_args.extend_from_slice(DIFF);
    log_args.push(&range);
    let log = git_in(clone, &log_args).await.map_err(unreadable)?;
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
    let at_tip = scan::in_diff(&git_in(clone, &diff_args).await.map_err(unreadable)?);
    for (commit, lines) in &commits {
        let diff = lines.join("\n");
        for finding in scan::in_diff(&diff) {
            let mut finding = Found::of(finding, Some(commit));
            finding.history_only = !at_tip
                .iter()
                .any(|t| t.name == finding.file && t.rule == finding.rule);
            if finding.file != scan::HIDDEN_NAME && shown(&finding.file) == scan::HIDDEN_NAME {
                finding.file = scan::HIDDEN_NAME.into();
            }
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
            found.extend(leaked.into_iter().map(|mut f| {
                f.name = shown(&f.name);
                Found::of(f, Some(commit))
            }));
        }
    }
    for (path, bytes) in &pushed.files {
        found.extend(
            scan::known_secrets_in_file(&String::from_utf8_lossy(bytes), path)
                .into_iter()
                .map(|mut f| {
                    f.name = shown(path);
                    Found::of(f, None)
                }),
        );
    }
    found.extend(pushed.too_big.iter().map(|path| {
        Found::of(
            Finding {
                name: shown(path),
                line: None,
                rule: "too big for the vault scan".into(),
            },
            None,
        )
    }));
    let mut seen = std::collections::HashSet::new();
    found.retain(|f| seen.insert(f.clone()));
    Ok(found)
}

/// The biggest file the scan for the secrets obid holds reads whole; a bigger one is a finding, so
/// it isn't pushed unscanned.
const BIGGEST_BLOB: usize = 32 << 20;

/// What a push sends besides its commits, read from the objects themselves.
struct Pushed {
    /// The own name of every entry a commit adds at a path its parent didn't have (a file's, a
    /// folder's, a submodule's), each once, as git gives them (NUL-separated, never quoted or
    /// split), and whether it's a folder. A name already on the base, at the same path, is the
    /// base's, not the job's.
    names: Vec<scan::Name>,
    /// Every file the push sends, by a path it has, read whole, when obid holds secrets to look
    /// for in it; none otherwise.
    files: Vec<(String, Vec<u8>)>,
    /// The files too big to read whole for those secrets.
    too_big: Vec<String>,
}

/// The objects `range` sends that the base doesn't have (every version, in every commit, merges
/// too): their names, and the files to read whole. Errs when git can't say.
async fn pushed_objects(clone: &Path, range: &str) -> Result<Pushed, String> {
    // "<id> <path>" for every tree and file, "<id>" for a commit. A path is only a label here
    // (one with a newline in it splits the line): the names come from the trees themselves.
    let listed = git_in(clone, &["rev-list", "--objects", range]).await?;
    let mut paths: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for line in listed.lines() {
        let (id, path) = line.split_once(' ').unwrap_or((line, ""));
        if git::is_sha(id) && !paths.contains_key(id) {
            paths.insert(id.to_owned(), path.to_owned());
            order.push(id.to_owned());
        }
    }
    let mut pushed = Pushed {
        names: Vec::new(),
        files: Vec::new(),
        too_big: Vec::new(),
    };
    if order.is_empty() {
        return Ok(pushed);
    }
    let checked = cat_file(
        clone,
        "--batch-check=%(objectname) %(objecttype) %(objectsize)",
        &order,
    )
    .await?;
    let mut blobs = Vec::new();
    for line in String::from_utf8_lossy(&checked).lines() {
        let parts: Vec<&str> = line.split(' ').collect();
        match parts[..] {
            [_, "tree", _] => {}
            [id, "blob", size] => {
                let size: usize = size
                    .parse()
                    .map_err(|_| format!("git cat-file answered {line:?}"))?;
                if size > BIGGEST_BLOB {
                    pushed
                        .too_big
                        .push(paths.get(id).cloned().unwrap_or_default());
                } else {
                    blobs.push(id.to_owned());
                }
            }
            [_, "commit", _] => {}
            _ => return Err(format!("git cat-file answered {line:?}")),
        }
    }
    // Every path a commit adds (`A`, folders too with `-t`), against each parent of a merge
    // (`-m`), and everything a root commit holds (`--root`): its last part is the new name.
    let added = git_bytes(
        clone,
        &[
            "log",
            "--root",
            "-m",
            "-r",
            "-t",
            "--no-renames",
            "--diff-filter=A",
            "--raw",
            "--no-abbrev",
            "-z",
            "--format=",
            range,
        ],
    )
    .await?;
    // Each: ":<old mode> <new mode> <old id> <new id> A", then the path.
    let fields: Vec<&[u8]> = added.split(|b| *b == 0).collect();
    let mut names = std::collections::BTreeSet::new();
    let mut fields = fields.iter();
    while let Some(meta) = fields.next() {
        if meta.is_empty() {
            continue;
        }
        let (Some(b':'), Some(path)) = (meta.first(), fields.next()) else {
            return Err("git log --raw answered something else".into());
        };
        let mode = String::from_utf8_lossy(meta);
        let folder = mode.split(' ').nth(1) == Some("040000");
        let name = path.rsplit(|b| *b == b'/').next().unwrap_or(path);
        names.insert(scan::Name {
            name: String::from_utf8_lossy(name).into_owned(),
            folder,
        });
    }
    pushed.names = names.into_iter().collect();
    if crate::secrets::known().is_empty() {
        pushed.too_big.clear();
        return Ok(pushed);
    }
    if !blobs.is_empty() {
        let read = cat_file(clone, "--batch", &blobs).await?;
        for (id, bytes) in batch_objects(&read)? {
            let path = paths
                .get(&id)
                .ok_or("git cat-file answered an object obid didn't ask for")?;
            pushed.files.push((path.clone(), bytes.to_vec()));
        }
    }
    Ok(pushed)
}

/// `git cat-file <how>` on `ids`, read as they are and with only the clone's own configuration.
async fn cat_file(clone: &Path, how: &str, ids: &[String]) -> Result<Vec<u8>, String> {
    let args = [
        std::ffi::OsStr::new("--no-replace-objects"),
        std::ffi::OsStr::new("cat-file"),
        std::ffi::OsStr::new(how),
    ];
    git::run_bytes(
        clone,
        &args,
        SCAN_ENV,
        Some(format!("{}\n", ids.join("\n")).into_bytes()),
    )
    .await
    .map_err(|e| e.0)
}

/// git in the clone, as the scan reads (only the clone's own configuration), answering its stdout
/// as it is: not trimmed, so a name's own spaces and newlines stay.
async fn git_bytes(clone: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let mut all = vec!["--no-replace-objects", "-c", "core.quotePath=false"];
    all.extend_from_slice(args);
    let all: Vec<&std::ffi::OsStr> = all.iter().map(std::ffi::OsStr::new).collect();
    git::run_bytes(clone, &all, SCAN_ENV, None)
        .await
        .map_err(|e| e.0)
}

/// Every commit the push sends, read as git keeps it (`cat-file`), not as `git log` shows it: its
/// author and committer, and its message's own bytes, each scanned on its own so a finding names
/// the commit to rewrite. A commit with any other header, or a message that isn't UTF-8 text, is
/// refused: nothing goes out.
async fn scan_commits(clone: &Path, range: &str, scratch: &Path) -> Result<Vec<Found>, Failure> {
    let unreadable = |e: String| {
        Failure::Failed(format!(
            "Not published: the secret scan couldn't read the commits ({e})."
        ))
    };
    let listed = git_in(clone, &["rev-list", range])
        .await
        .map_err(unreadable)?;
    let commits: Vec<&str> = listed.lines().filter(|c| git::is_sha(c)).collect();
    if commits.is_empty() {
        return Ok(Vec::new());
    }
    let commits: Vec<String> = commits.into_iter().map(str::to_owned).collect();
    let raw = cat_file(clone, "--batch", &commits)
        .await
        .map_err(unreadable)?;
    let mut found = Vec::new();
    for (commit, object) in batch_objects(&raw).map_err(unreadable)? {
        let (texts, refused) = commit_texts(&commit, object);
        if let Some(why) = refused {
            return Err(Failure::Failed(why));
        }
        match scan::scan(&texts, scratch).await {
            Verdict::Clean => {}
            Verdict::Found(more) => {
                found.extend(more.into_iter().map(|f| Found::of(f, Some(&commit))))
            }
            Verdict::CouldNotRun(why) => return Err(could_not_run(&why)),
        }
    }
    Ok(found)
}

/// `git cat-file --batch`'s answer: each object's id and bytes.
fn batch_objects(mut rest: &[u8]) -> Result<Vec<(String, &[u8])>, String> {
    let mut objects = Vec::new();
    // Each: "<id> <type> <size>\n", the bytes, "\n".
    while let Some(newline) = rest.iter().position(|b| *b == b'\n') {
        let header = String::from_utf8_lossy(&rest[..newline]).into_owned();
        let parts: Vec<&str> = header.split(' ').collect();
        let [id, _, size] = parts[..] else {
            return Err(format!("git cat-file answered {header:?}"));
        };
        let size: usize = size
            .parse()
            .map_err(|_| format!("git cat-file answered {header:?}"))?;
        let start = newline + 1;
        let end = start + size;
        if end >= rest.len() {
            return Err("git cat-file stopped short".into());
        }
        objects.push((id.to_owned(), &rest[start..end]));
        rest = &rest[end + 1..];
    }
    Ok(objects)
}

/// A commit object's texts that go out, `commit author` (its author and committer) and `commit
/// message` (its message's bytes), or why obid won't publish it.
fn commit_texts(commit: &str, object: &[u8]) -> (Vec<(String, String)>, Option<String>) {
    let short = &commit[..12.min(commit.len())];
    let refused = |what: &str| {
        (
            Vec::new(),
            Some(format!(
                "Not published: commit {short} {what}, which obid doesn't publish."
            )),
        )
    };
    let (headers, message) = match object.windows(2).position(|w| w == b"\n\n") {
        Some(at) => (&object[..at], &object[at + 2..]),
        None => (object, &[][..]),
    };
    // Exactly the layout git writes for a plain commit, and nothing else: one `tree`, its
    // `parent`s, one `author`, one `committer`. The ids are hex, so only who made it is text.
    let Ok(headers) = std::str::from_utf8(headers) else {
        return refused("has headers that aren't UTF-8 text");
    };
    let lines: Vec<&str> = headers.split('\n').collect();
    let id = |line: &str, key: &str| {
        line.strip_prefix(key)
            .and_then(|rest| rest.strip_prefix(' '))
            .is_some_and(git::is_sha)
    };
    let parents = lines.iter().skip(1).take_while(|l| id(l, "parent")).count();
    let people = &lines[(1 + parents).min(lines.len())..];
    let laid_out = lines.first().is_some_and(|l| id(l, "tree"))
        && people.len() == 2
        && people[0].starts_with("author ")
        && people[1].starts_with("committer ")
        && !headers.contains(['\0', '\r']);
    if !laid_out {
        return refused("carries headers other than its tree, parents, author and committer");
    }
    let message = match std::str::from_utf8(message) {
        Ok(text) if !text.contains('\0') => text.to_owned(),
        _ => return refused("has a message that isn't UTF-8 text"),
    };
    (
        vec![
            ("commit author".to_owned(), people.join("\n")),
            ("commit message".to_owned(), message),
        ],
        None,
    )
}

/// The commit the job's branch has on the remote, or none when it has no such branch yet.
async fn remote_head(job: &Job, target: &Target) -> Result<Option<String>, Failure> {
    let mut args = credentials(&target.remote, target.gh.as_deref(), &forbidden_names());
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
            git_said(&e, &target.remote)
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
    let mut args = credentials(&target.remote, target.gh.as_deref(), &forbidden_names());
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
                git_said(&e, &target.remote)
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

    /// A commit is read as git keeps it: its author and committer and its message's own bytes go
    /// to the scan; an `encoding` (which would re-encode the message `git log` shows), a signature
    /// or any other header, or a message that isn't UTF-8 text, refuses it.
    #[test]
    fn commits_are_read_as_git_keeps_them() {
        let commit = "c".repeat(40);
        let who = "A <a@example.com> 1791582173 +0000";
        let plain = format!(
            "tree {0}\nparent {0}\nauthor {who}\ncommitter {who}\n\nFix it\n",
            "d".repeat(40)
        );
        let (texts, refused) = commit_texts(&commit, plain.as_bytes());
        assert_eq!(refused, None);
        assert_eq!(
            texts[0],
            (
                "commit author".into(),
                format!("author {who}\ncommitter {who}")
            )
        );
        assert_eq!(texts[1], ("commit message".into(), "Fix it\n".into()));
        let d = "d".repeat(40);
        for object in [
            format!("tree {d}\nauthor {who}\ncommitter {who}\nencoding UTF-16LE\n\nFix it\n"),
            format!("tree {d}\nauthor {who}\ncommitter {who}\ngpgsig -----BEGIN PGP-----\n\nFix\n"),
            format!("tree {d}\nauthor {who}\ncommitter {who}\n continued\n\nFix it\n"),
            // A second tree or parent after the committer, holding anything at all.
            format!("tree {d}\nauthor {who}\ncommitter {who}\ntree ghp_x\n\nFix it\n"),
            format!("tree {d}\nauthor {who}\ncommitter {who}\nparent {d}\n\nFix it\n"),
            format!("tree\tghp_x\nauthor {who}\ncommitter {who}\n\nFix it\n"),
            format!("tree {d}\nparent ghp_x\nauthor {who}\ncommitter {who}\n\nFix it\n"),
            format!("tree {d}\nauthor {who}\n\nFix it\n"),
        ] {
            let (_, refused) = commit_texts(&commit, object.as_bytes());
            let refused = refused.unwrap_or_else(|| panic!("{object:?}"));
            assert!(refused.contains("carries headers other than"), "{object:?}");
            // The line never echoes what the commit holds.
            assert!(
                !refused.contains("ghp") && !refused.contains("UTF-16"),
                "{refused}"
            );
        }
        let mut split = format!("tree {d}\nauthor A").into_bytes();
        split.push(0xff);
        split.extend(format!(" <a@example.com> 1 +0000\ncommitter {who}\n\nFix\n").bytes());
        let (_, refused) = commit_texts(&commit, &split);
        assert!(refused.unwrap().contains("headers that aren't UTF-8 text"));
        let mut utf16 =
            format!("tree {}\nauthor {who}\ncommitter {who}\n\n", "d".repeat(40)).into_bytes();
        utf16.extend("Fix".encode_utf16().flat_map(u16::to_le_bytes));
        let (_, refused) = commit_texts(&commit, &utf16);
        assert!(refused.unwrap().contains("a message that isn't UTF-8 text"));
    }

    #[test]
    fn credentials_come_from_gh_only_for_https() {
        let gh = Path::new("/opt/it's/gh");
        let unset = ["GH_TOKEN".to_owned(), "ANTHROPIC_API_KEY".to_owned()];
        assert_eq!(
            credentials("https://github.com/o/r.git", Some(gh), &unset),
            [
                "-c",
                "credential.helper=",
                "-c",
                r"credential.helper=!env -u 'GH_TOKEN' -u 'ANTHROPIC_API_KEY' '/opt/it'\''s/gh' auth git-credential"
            ]
        );
        assert_eq!(
            credentials("file:///tmp/r.git", Some(gh), &unset),
            ["-c", "credential.helper="]
        );
        let names = forbidden_names();
        assert!(names.starts_with(&["GH_TOKEN".to_owned(), "GITHUB_TOKEN".to_owned()]));
        assert!(names.iter().all(|n| crate::process::is_forbidden(n)));
    }
}
