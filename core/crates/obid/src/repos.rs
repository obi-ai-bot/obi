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
            .filter(|g| !state.listed.iter().any(|r| r.repo == g.repo))
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

    /// The repository `name`: a listed one, else one of GitHub's (named as GitHub does, letter
    /// case aside, as GitHub takes it).
    pub fn find(&self, name: &str) -> Option<Repo> {
        let state = self.read();
        state
            .listed
            .iter()
            .find(|r| r.repo == name)
            .cloned()
            .or_else(|| {
                state
                    .github
                    .iter()
                    .find(|r| r.repo.eq_ignore_ascii_case(name))
                    .cloned()
            })
    }

    /// Lists `repo` from now on, and adds it to the configuration file's `repos`, the file's other
    /// keys and entries as they are. Listed even when the file can't be written: the error says why.
    pub fn keep(&self, repo: &Repo) -> Result<(), String> {
        let mut state = self.write();
        if state.listed.iter().any(|r| r.repo == repo.repo) {
            return Ok(());
        }
        state.listed.push(repo.clone());
        match &state.file {
            Some(file) => add_to_file(file, repo),
            None => Ok(()),
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
    if !repos.iter().any(|r| r["repo"] == repo.repo.as_str()) {
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

/// Reads gh's list at start, then every hour and whenever [`Repos::nudge`]d, until obid stops. A
/// read that fails (no gh, signed out) keeps the list it had.
pub fn spawn(shared: Arc<Shared>) {
    let mut stopping = shared.stopping.clone();
    tokio::spawn(async move {
        let repos = shared.config.repos.clone();
        loop {
            if let Some(gh) = crate::github::gh() {
                match list_github(&gh).await {
                    Ok(github) => {
                        tracing::info!("gh can push to {} repositories on GitHub", github.len());
                        repos.write().github = github;
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
}
