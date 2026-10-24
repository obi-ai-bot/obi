//! The repositories jobs work in (docs/runner-api.md, "GET /v1/repos"): the configuration's
//! `repos`, and every GitHub repository the owner's gh can push to, listed with gh at start, every
//! hour and after a GitHub sign-in. A job is taken in either kind; the first job in one of GitHub's
//! adds it to the configuration's `repos` (every other entry and setting kept), so from then on
//! it's one of obid's like the rest: cloned for conversations, tidied, followed.

use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use axum::extract::State;
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};

use crate::api::{ApiError, Shared};
use crate::config::Repo;

/// How often gh's list is read again.
const EVERY: Duration = Duration::from_secs(3600);

/// The most of GitHub's repositories the brain is told about, newest push first; a job may still
/// start in any of them.
pub const MOST_TOLD: usize = 100;

/// What `gh api` keeps of each repository it lists: the pushable, unarchived ones'
/// `owner/name` and default branch, one per line.
const JQ: &str =
    ".[] | select(.permissions.push and (.archived | not)) | [.full_name, .default_branch] | @tsv";

/// The repositories as they are now. Cloning shares them.
#[derive(Clone, Default)]
pub struct Repos(Arc<Inner>);

#[derive(Default)]
struct Inner {
    lists: RwLock<Lists>,
    /// One write of the configuration file at a time, never under `lists`' lock.
    writing: std::sync::Mutex<()>,
    /// Wakes the reader early: a GitHub sign-in ended.
    nudge: tokio::sync::Notify,
}

#[derive(Default)]
struct Lists {
    /// The configuration's, with those jobs added since.
    listed: Vec<Repo>,
    /// The configuration file, where a repository a job adds is written; none for a configuration
    /// given as text (tests).
    file: Option<PathBuf>,
    /// GitHub's that gh can push to, as it last listed them, newest push first.
    github: Vec<Repo>,
    /// The gh account `github` is for: none while gh isn't signed in.
    user: Option<String>,
}

/// Two names of one repository: GitHub ignores letter case, and so does the Mac's disk, where both
/// would be one clone.
fn same(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}

impl Repos {
    pub fn new(listed: Vec<Repo>) -> Repos {
        let repos = Repos::default();
        repos.write().listed = listed;
        repos
    }

    fn read(&self) -> std::sync::RwLockReadGuard<'_, Lists> {
        self.0.lists.read().unwrap_or_else(|e| e.into_inner())
    }

    fn write(&self) -> std::sync::RwLockWriteGuard<'_, Lists> {
        self.0.lists.write().unwrap_or_else(|e| e.into_inner())
    }

    /// Where a repository a job adds is written: the file the configuration was read from.
    pub fn open(&self, file: &Path) {
        self.write().file = Some(file.to_path_buf());
    }

    /// The configuration's repositories, with those jobs added since.
    pub fn get(&self) -> Vec<Repo> {
        self.read().listed.clone()
    }

    /// GitHub's repositories gh can push to that aren't listed yet, newest push first.
    pub fn github(&self) -> Vec<Repo> {
        let state = self.read();
        state
            .github
            .iter()
            .filter(|g| !state.listed.iter().any(|r| same(&r.repo, &g.repo)))
            .cloned()
            .collect()
    }

    /// The names the brain is told: every listed one, then up to [`MOST_TOLD`] of GitHub's.
    pub fn names(&self) -> Vec<String> {
        self.get()
            .into_iter()
            .chain(self.github().into_iter().take(MOST_TOLD))
            .map(|r| r.repo)
            .collect()
    }

    /// The repository `name`, letter case aside: a listed one (with its settings), else one of
    /// GitHub's. Its own name is the one to use.
    pub fn find(&self, name: &str) -> Option<Repo> {
        let state = self.read();
        let found = |list: &[Repo]| list.iter().find(|r| same(&r.repo, name)).cloned();
        found(&state.listed).or_else(|| found(&state.github))
    }

    /// Lists `repo` from now on, and adds it to the configuration file's `repos`, the file's other
    /// keys and entries as they are. Listed even when the file can't be written: the error says why.
    pub fn keep(&self, repo: &Repo) -> Result<(), String> {
        let file = {
            let mut state = self.write();
            if state.listed.iter().any(|r| same(&r.repo, &repo.repo)) {
                return Ok(());
            }
            state.listed.push(repo.clone());
            state.file.clone()
        };
        // Outside the lists' lock: find, get and names never wait on the disk.
        let _writing = self.0.writing.lock().unwrap_or_else(|e| e.into_inner());
        match file {
            Some(file) => add_to_file(&file, repo),
            None => Ok(()),
        }
    }

    /// Makes `repo` findable as one of GitHub's, not listed or written yet, for one start on the
    /// owner's tap (crate::github_work::start_adding): the job's first run keeps it as any of
    /// GitHub's is ([`Repos::keep`]), and [`Repos::release`] lets go of it when nothing started.
    pub fn hold(&self, repo: &Repo) {
        let mut state = self.write();
        if !state.github.iter().any(|g| same(&g.repo, &repo.repo)) {
            state.github.push(repo.clone());
        }
    }

    /// Lets go of a repository [`Repos::hold`] made findable, unless it's listed by now.
    pub fn release(&self, name: &str) {
        let mut state = self.write();
        if !state.listed.iter().any(|r| same(&r.repo, name)) {
            state.github.retain(|g| !same(&g.repo, name));
        }
    }

    /// Keeps GitHub's list only while it's `user`'s, the gh account signed in now: with none, or
    /// another, it's dropped at once, so no job starts in (or adds) a repository of an account gh
    /// no longer uses. True when it was dropped.
    pub fn follow(&self, user: Option<&str>) -> bool {
        let mut state = self.write();
        if state.user.as_deref() == user {
            return false;
        }
        if !state.github.is_empty() {
            tracing::info!("GitHub's repositories dropped: gh's login changed");
        }
        state.github.clear();
        state.user = user.map(str::to_owned);
        true
    }

    /// GitHub's list as gh just read it for `user`, unless gh's login changed meanwhile.
    fn read_for(&self, user: &str, github: Vec<Repo>) {
        let mut state = self.write();
        if state.user.as_deref() == Some(user) {
            state.github = github;
        }
    }

    /// Reads gh's list again now, rather than at the next hour.
    pub fn nudge(&self) {
        self.0.nudge.notify_one();
    }
}

impl std::fmt::Debug for Repos {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Repos").field(&self.get()).finish()
    }
}

impl PartialEq for Repos {
    fn eq(&self, other: &Repos) -> bool {
        self.get() == other.get()
    }
}

impl Eq for Repos {}

/// `repo` added to the `repos` of the configuration at `file`, written through a temporary file
/// (0600). ponytail: rewritten as a JSON value, so the file's keys come out sorted; a text edit if
/// that ever matters to someone.
fn add_to_file(file: &Path, repo: &Repo) -> Result<(), String> {
    let unkept =
        |e: &dyn std::fmt::Display| format!("{} isn't in {} yet: {e}", repo.repo, file.display());
    let text = std::fs::read(file).map_err(|e| unkept(&e))?;
    let mut config: Value = serde_json::from_slice(&text).map_err(|e| unkept(&e))?;
    let Some(object) = config.as_object_mut() else {
        return Err(unkept(&"it isn't a JSON object"));
    };
    let Some(repos) = object
        .entry("repos")
        .or_insert_with(|| json!([]))
        .as_array_mut()
    else {
        return Err(unkept(&"its repos isn't a list"));
    };
    if !repos
        .iter()
        .any(|r| r["repo"].as_str().is_some_and(|n| same(n, &repo.repo)))
    {
        repos.push(json!({"repo": repo.repo, "remote": repo.remote,
                          "defaultBranch": repo.default_branch}));
    }
    let mut text = serde_json::to_vec_pretty(&config).map_err(|e| unkept(&e))?;
    text.push(b'\n');
    crate::store::write_private(file, &text).map_err(|e| unkept(&e))
}

/// The repositories gh's `api` printed (`owner/name`, a tab, the default branch, a line each), as
/// obid clones them: over https, through gh's login (crate::publish::fetch_credentials).
fn parse(said: &str) -> Vec<Repo> {
    said.lines()
        .filter_map(|line| {
            let (repo, branch) = line.trim().split_once('\t')?;
            (crate::github::is_repo(repo) && crate::git::is_branch_name(branch)).then(|| Repo {
                repo: repo.to_owned(),
                remote: format!("https://github.com/{repo}.git"),
                default_branch: branch.to_owned(),
                check: None,
                pull_requests: None,
            })
        })
        .collect()
}

/// GitHub's repositories the signed-in gh can push to, newest push first.
async fn list_github(gh: &Path) -> Result<Vec<Repo>, String> {
    let said = crate::github::run_bounded(
        gh,
        &[
            "api",
            "user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member",
            "--paginate",
            "--jq",
            JQ,
        ],
        8 << 20,
        Duration::from_secs(120),
    )
    .await?;
    Ok(parse(&said))
}

/// Reads gh's list at start, then every hour and whenever [`Repos::nudge`]d, until obid stops: gh
/// signed out (or as someone else) drops the list it had ([`Repos::follow`]); a read that fails
/// while the same account is signed in keeps it.
pub fn spawn(shared: Arc<Shared>) {
    let mut stopping = shared.stopping.clone();
    tokio::spawn(async move {
        let repos = shared.config.repos.clone();
        loop {
            let user = match crate::github::gh() {
                Some(gh) => crate::github_login::read_status(&gh)
                    .await
                    .user
                    .map(|u| (gh, u)),
                None => None,
            };
            repos.follow(user.as_ref().map(|(_, u)| u.as_str()));
            if let Some((gh, user)) = user {
                match list_github(&gh).await {
                    Ok(github) => {
                        tracing::info!("gh can push to {} repositories on GitHub", github.len());
                        repos.read_for(&user, github);
                    }
                    Err(e) => tracing::info!("GitHub's repositories weren't listed: {e}"),
                }
            }
            tokio::select! {
                () = tokio::time::sleep(EVERY) => {}
                () = repos.0.nudge.notified() => {}
                _ = stopping.changed() => return,
            }
        }
    });
}

/// `GET /v1/repos`: the repositories a job may start in, listed ones first, then GitHub's that gh
/// can push to, newest push first.
pub async fn list(State(shared): State<Arc<Shared>>) -> Result<Response, ApiError> {
    let repos = &shared.config.repos;
    let entry = |r: Repo, listed: bool| json!({"repo": r.repo, "defaultBranch": r.default_branch, "listed": listed});
    let all: Vec<Value> = repos
        .get()
        .into_iter()
        .map(|r| entry(r, true))
        .chain(repos.github().into_iter().map(|r| entry(r, false)))
        .collect();
    Ok(axum::Json(json!({ "repos": all })).into_response())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo(name: &str) -> Repo {
        Repo {
            repo: name.into(),
            remote: format!("https://github.com/{name}.git"),
            default_branch: "main".into(),
            check: None,
            pull_requests: None,
        }
    }

    #[test]
    fn gh_lines_become_repositories_cloned_over_https() {
        let said = "octo/app\tmain\nocto/lib\tdev\n../evil\tmain\nocto/x\t-oops\nnot a line\n";
        let parsed = parse(said);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].remote, "https://github.com/octo/app.git");
        assert_eq!(parsed[1].default_branch, "dev");
    }

    /// A job's repository from GitHub is found (letter case aside), and once kept it's listed and
    /// in the configuration file, whose other keys and entries stay.
    #[test]
    fn a_kept_github_repository_joins_the_configuration_file() {
        let dir = std::env::temp_dir().join(format!("obid-repos-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("config.json");
        let before = json!({"owner": "o", "repos": [{"repo": "o/old", "remote": "https://x/o/old.git", "check": "make"}]});
        std::fs::write(&file, before.to_string()).unwrap();
        let repos = Repos::new(vec![]);
        repos.open(&file);
        repos.write().github = vec![repo("octo/app")];
        assert_eq!(repos.names(), ["octo/app"]);
        let found = repos.find("Octo/App").expect("GitHub's");
        assert!(repos.find("octo/other").is_none());
        repos.keep(&found).unwrap();
        repos.keep(&found).unwrap();
        assert_eq!(repos.get(), [repo("octo/app")]);
        assert!(repos.github().is_empty());
        let after: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(after["owner"], "o");
        assert_eq!(after["repos"][0], before["repos"][0]);
        assert_eq!(
            after["repos"][1],
            json!({"repo": "octo/app", "remote": "https://github.com/octo/app.git", "defaultBranch": "main"})
        );
        assert_eq!(after["repos"].as_array().unwrap().len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A configured repository and GitHub's name for it differing only in letter case are one: the
    /// configured one, with its check, is what a job gets, and nothing is added twice.
    #[test]
    fn letter_case_never_makes_a_second_repository() {
        let dir = std::env::temp_dir().join(format!("obid-repos-case-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("config.json");
        let configured = Repo {
            check: Some("make test".into()),
            ..repo("acme/App")
        };
        let before = json!({"repos": [{"repo": "acme/App", "remote": "https://github.com/acme/App.git", "check": "make test"}]});
        std::fs::write(&file, before.to_string()).unwrap();
        let repos = Repos::new(vec![configured.clone()]);
        repos.open(&file);
        repos.write().github = vec![repo("acme/app"), repo("acme/lib")];
        assert_eq!(repos.find("acme/app"), Some(configured.clone()));
        assert_eq!(repos.names(), ["acme/App", "acme/lib"]);
        repos.keep(&repo("acme/app")).unwrap();
        assert_eq!(repos.get(), [configured]);
        // One written in the file with other letters isn't written again either.
        let other = Repos::new(vec![]);
        other.open(&file);
        other.keep(&repo("ACME/APP")).unwrap();
        let after: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(after, before);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// GitHub's list is the signed-in gh account's only: signed out, or another account, and it's
    /// gone, so no job starts in one of its repositories; a read for the account that left is
    /// dropped.
    #[test]
    fn githubs_list_goes_with_its_account() {
        let repos = Repos::new(vec![]);
        assert!(repos.follow(Some("octo")));
        repos.read_for("octo", vec![repo("octo/app")]);
        assert!(!repos.follow(Some("octo")));
        assert!(repos.find("octo/app").is_some());
        assert!(repos.follow(None));
        assert!(repos.find("octo/app").is_none());
        repos.read_for("octo", vec![repo("octo/app")]);
        assert!(repos.github().is_empty());
        repos.follow(Some("octo"));
        repos.read_for("octo", vec![repo("octo/app")]);
        assert!(repos.follow(Some("someone-else")));
        assert!(repos.github().is_empty());
    }
}
