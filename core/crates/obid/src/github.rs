//! obid's own calls to GitHub, through the owner's GitHub CLI (`gh`, found on the login shell's
//! `PATH`): opening the pull request of a published job or bringing its description up to date,
//! reading an issue's shape, and following a published pull request (docs/runner-api.md, "Job
//! pipeline and pull request following"). obid has no GitHub app, so every call goes as the owner
//! (`GET /v1/status` says `"github": "owner"`).
//!
//! `gh` signs in with its own login: obid never reads, holds or passes a token. Its environment is
//! obid's without `GH_TOKEN`, `GITHUB_TOKEN` or the agents' variables, with prompts, colour and
//! update checks off; nothing it is given is a secret (titles and
//! descriptions went through the secret scan first). What `gh` prints is never logged whole and
//! never reaches an agent: an error keeps its last line, with the secrets obid holds taken out.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

/// How long one `gh` call may take.
const GH_TIMEOUT: Duration = Duration::from_secs(120);

/// The GitHub CLI obid uses, or none when it isn't installed.
pub fn gh() -> Option<PathBuf> {
    crate::process::resolve_bin("gh")
}

/// The pull request as obid last read it from GitHub (`pullRequest` on a job): only typed status,
/// never anything a person wrote.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequest {
    /// `OPEN`, `CLOSED` or `MERGED`.
    pub state: String,
    /// `REVIEW_REQUIRED`, `CHANGES_REQUESTED`, `APPROVED`, or none (no decision yet).
    pub review_decision: Option<String>,
    pub base: String,
    /// Seconds since the epoch; only once merged.
    pub merged_at: Option<i64>,
    pub checked_at: i64,
    /// The pull request's head commit as GitHub has it.
    pub head: Option<String>,
}

impl PullRequest {
    /// As the runner API shows it: `mergedAt` and `head` only when known.
    pub fn to_json(&self) -> Value {
        let mut value = json!({
            "state": self.state,
            "reviewDecision": self.review_decision,
            "base": self.base,
            "checkedAt": obi_protocol::time::format(self.checked_at),
        });
        if let Some(merged) = self.merged_at {
            value["mergedAt"] = json!(obi_protocol::time::format(merged));
        }
        if let Some(head) = &self.head {
            value["head"] = json!(head);
        }
        value
    }

    pub fn is_open(&self) -> bool {
        self.state == "OPEN"
    }
}

/// `owner/name`, as GitHub names a repository: nothing a URL or a path could be made of.
pub fn is_repo(repo: &str) -> bool {
    let Some((owner, name)) = repo.split_once('/') else {
        return false;
    };
    !owner.is_empty()
        && !name.is_empty()
        && !repo.contains("..")
        && owner
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// The number of a pull request URL in `repo`: exactly `https://github.com/<repo>/pull/<n>`, or
/// none. Only a pull request of the job's own repository is ever read or followed.
pub fn pull_request_number(url: &str, repo: &str) -> Option<u64> {
    if !is_repo(repo) {
        return None;
    }
    let rest = url.strip_prefix("https://github.com/")?;
    let number = rest.strip_prefix(repo)?.strip_prefix("/pull/")?;
    if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit()) || number.len() > 10 {
        return None;
    }
    number.parse::<u64>().ok().filter(|n| *n > 0)
}

/// Runs `gh` with `args`: its stdout, trimmed, or the last line it said on stderr.
pub(crate) async fn run(gh: &Path, args: &[&str]) -> Result<String, String> {
    output(gh, args).await.map_err(|(_, said)| said)
}

/// [`run`], keeping what `gh` printed on stdout when it fails too (trimmed; empty when it never
/// ran): `gh api graphql` exits non-zero on an answer with `errors` even when it has `data`.
pub(crate) async fn output(gh: &Path, args: &[&str]) -> Result<String, (String, String)> {
    let mut command = tokio::process::Command::new(gh);
    // gh signs in with its own login only: a token that found its way into obid's environment
    // (`GH_TOKEN`, `GITHUB_TOKEN`, the agents' variables) never reaches it.
    for (name, _) in std::env::vars_os() {
        if crate::process::is_forbidden(&name.to_string_lossy()) {
            command.env_remove(name);
        }
    }
    command
        .args(args)
        .env("PATH", crate::process::tools_path())
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_SPINNER_DISABLED", "1")
        .env("NO_COLOR", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let child = command
        .spawn()
        .map_err(|e| (String::new(), format!("gh couldn't start: {e}")))?;
    let output = tokio::time::timeout(GH_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| {
            (
                String::new(),
                format!("gh took more than {} seconds", GH_TIMEOUT.as_secs()),
            )
        })?
        .map_err(|e| (String::new(), format!("gh: {e}")))?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if output.status.success() {
        return Ok(stdout);
    }
    Err((stdout, said(&String::from_utf8_lossy(&output.stderr))))
}

/// The last thing a tool said on stderr, skipping git's hints, with the secrets obid holds taken
/// out and at most 300 characters.
pub fn said(stderr: &str) -> String {
    let line = stderr
        .lines()
        .rfind(|l| !l.trim().is_empty() && !l.starts_with("hint:"))
        .unwrap_or("no reason given")
        .trim();
    let line = crate::secrets::known().redact(line);
    if line.chars().count() > 300 {
        format!("{}…", line.chars().take(299).collect::<String>())
    } else {
        line
    }
}

/// What publishing sent for the pull request: opened, or its description brought up to date.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sent {
    Opened,
    Edited,
    /// The pull request was open already and its description didn't update.
    Nothing,
}

/// The open pull request obid published `branch` to: from this repository itself (never a fork's
/// branch of the same name, which `gh pr list --head` would match too), into `base`, and with one of `heads` as
/// its head: the commit obid just pushed, or the one it pushed before (GitHub may not have moved
/// it yet). `gh pr list --json` answers a list of them.
pub fn own_pull_request(listed: &str, repo: &str, base: &str, heads: &[&str]) -> Option<String> {
    if listed.trim().is_empty() {
        return None;
    }
    let list: Vec<Value> = serde_json::from_str(listed).ok()?;
    list.iter()
        .filter(|pr| {
            pr["isCrossRepository"] == Value::Bool(false)
                && pr["baseRefName"] == base
                && pr["headRefOid"]
                    .as_str()
                    .is_some_and(|h| git_sha(h) && heads.contains(&h))
        })
        .filter_map(|pr| pr["url"].as_str())
        .find(|url| pull_request_number(url, repo).is_some())
        .map(str::to_owned)
}

/// Opens the pull request for `branch` into `base`, ready for review (never a draft), or finds the
/// one obid already opened for it (`own_pull_request`: same repository, one of `heads` its head) and
/// brings its description up to date from `body_file`. Answers its URL, which must be a pull
/// request of `repo`, and what went out.
pub async fn open_pull_request(
    gh: &Path,
    repo: &str,
    base: &str,
    branch: &str,
    heads: &[&str],
    title: &str,
    body_file: &Path,
) -> Result<(String, Sent), String> {
    let body = body_file.to_string_lossy();
    let listed = run(
        gh,
        &[
            "pr",
            "list",
            "-R",
            repo,
            "--head",
            branch,
            "--state",
            "open",
            "--json",
            "url,isCrossRepository,headRefOid,baseRefName",
            "--limit",
            "100",
        ],
    )
    .await
    .map_err(|e| format!("Couldn't look for the open pull request: {e}"))?;
    if let Some(open) = own_pull_request(&listed, repo, base, heads) {
        // The commits are on it already; a description that didn't update isn't worth failing for.
        let edited = run(gh, &["pr", "edit", &open, "-R", repo, "--body-file", &body])
            .await
            .is_ok();
        return Ok((open, if edited { Sent::Edited } else { Sent::Nothing }));
    }
    let title = format!("--title={title}");
    let created = run(
        gh,
        &[
            "pr",
            "create",
            "-R",
            repo,
            "--base",
            base,
            "--head",
            branch,
            &title,
            "--body-file",
            &body,
        ],
    )
    .await
    .map_err(|e| format!("Couldn't open the pull request: {e}"))?;
    let url = created.lines().last().unwrap_or("").trim().to_owned();
    if pull_request_number(&url, repo).is_none() {
        return Err("gh opened no pull request of this repository.".into());
    }
    Ok((url, Sent::Opened))
}

/// The body of issue `number` in `repo`, or none when `gh` can't read it. Only its shape is used
/// (whether it has a checklist), never sent anywhere.
pub async fn issue_body(gh: &Path, repo: &str, number: u64) -> Option<String> {
    let number = number.to_string();
    run(
        gh,
        &[
            "issue", "view", &number, "-R", repo, "--json", "body", "-q", ".body",
        ],
    )
    .await
    .ok()
}

/// What GitHub says now about the pull request `number` of `repo`, read at `now`. The error is a
/// fixed line: what `gh` printed could hold a credential or someone's words.
pub async fn view(gh: &Path, repo: &str, number: u64, now: i64) -> Result<PullRequest, String> {
    const FAILED: &str = "Couldn't refresh the pull request. Will try again shortly.";
    let number = number.to_string();
    let output = run(
        gh,
        &[
            "pr",
            "view",
            &number,
            "--repo",
            repo,
            "--json",
            "state,reviewDecision,mergedAt,baseRefName,headRefOid",
        ],
    )
    .await
    .map_err(|_| FAILED.to_owned())?;
    decode(&output, now).ok_or_else(|| FAILED.to_owned())
}

/// `gh pr view --json state,reviewDecision,mergedAt,baseRefName,headRefOid`, checked: a known
/// state, a base, and a merge date exactly when merged.
pub fn decode(text: &str, now: i64) -> Option<PullRequest> {
    let value: Value = serde_json::from_str(text).ok()?;
    let state = value["state"].as_str()?;
    if !["OPEN", "CLOSED", "MERGED"].contains(&state) {
        return None;
    }
    let base = value["baseRefName"].as_str().filter(|b| !b.is_empty())?;
    let merged_at = match value["mergedAt"].as_str().filter(|m| !m.is_empty()) {
        Some(date) => Some(obi_protocol::time::parse(date)?),
        None => None,
    };
    if (state == "MERGED") != merged_at.is_some() {
        return None;
    }
    let review_decision = value["reviewDecision"]
        .as_str()
        .filter(|d| ["REVIEW_REQUIRED", "CHANGES_REQUESTED", "APPROVED"].contains(d))
        .map(str::to_owned);
    let head = value["headRefOid"]
        .as_str()
        .filter(|h| crate::git::is_sha(h))
        .map(str::to_owned);
    Some(PullRequest {
        state: state.to_owned(),
        review_decision,
        base: base.to_owned(),
        merged_at,
        checked_at: now,
        head,
    })
}

fn git_sha(text: &str) -> bool {
    crate::git::is_sha(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_pull_requests_of_the_jobs_repository() {
        let repo = "deskree-inc/oby";
        assert_eq!(
            pull_request_number("https://github.com/deskree-inc/oby/pull/42", repo),
            Some(42)
        );
        for url in [
            "https://github.com/deskree-inc/oby/pull/0",
            "https://github.com/deskree-inc/oby/pull/",
            "https://github.com/deskree-inc/oby/pull/42/files",
            "https://github.com/deskree-inc/oby/pull/42?x=1",
            "https://github.com/deskree-inc/oby2/pull/42",
            "https://github.com/other/oby/pull/42",
            "http://github.com/deskree-inc/oby/pull/42",
            "https://github.com.evil/deskree-inc/oby/pull/42",
            "https://user@github.com/deskree-inc/oby/pull/42",
            "https://github.com/deskree-inc/oby/issues/42",
        ] {
            assert_eq!(pull_request_number(url, repo), None, "{url}");
        }
        assert_eq!(
            pull_request_number("https://github.com/../x/pull/1", "../x"),
            None
        );
    }

    /// Only a pull request from this repository's own branch, at a commit obid pushed: never a
    /// fork's pull request from a branch of the same name.
    #[test]
    fn only_its_own_open_pull_request_is_adopted() {
        let repo = "deskree-inc/oby";
        let head = "a".repeat(40);
        let before = "b".repeat(40);
        let pr = |url: &str, cross: bool, oid: &str| json!({"url": url, "isCrossRepository": cross, "headRefOid": oid, "baseRefName": "dev"});
        let ours = "https://github.com/deskree-inc/oby/pull/42";
        let list = |items: Vec<Value>| Value::Array(items).to_string();
        assert_eq!(
            own_pull_request(&list(vec![pr(ours, false, &head)]), repo, "dev", &[&head]),
            Some(ours.into())
        );
        assert_eq!(
            own_pull_request(
                &list(vec![pr(ours, false, &before)]),
                repo,
                "dev",
                &[&head, &before]
            ),
            Some(ours.into())
        );
        for listed in [
            list(vec![pr(ours, true, &head)]),
            list(vec![pr(ours, false, &"c".repeat(40))]),
            list(vec![pr(
                "https://github.com/other/oby/pull/42",
                false,
                &head,
            )]),
            list(vec![json!({"url": ours})]),
            // Someone's pull request of the same branch at obid's commit, into another base.
            list(vec![
                json!({"url": ours, "isCrossRepository": false, "headRefOid": head, "baseRefName": "main"}),
            ]),
            String::new(),
            "not json".into(),
        ] {
            assert_eq!(
                own_pull_request(&listed, repo, "dev", &[&head]),
                None,
                "{listed}"
            );
        }
    }

    #[test]
    fn repositories() {
        assert!(is_repo("obi-e2e/fixture-app"));
        assert!(is_repo("deskree-inc/oby.v2_x"));
        for bad in [
            "", "a", "a/", "/b", "a/b/c", "a/..", "a b/c", "a/b?c", "a/b#c",
        ] {
            assert!(!is_repo(bad), "{bad}");
        }
    }

    #[test]
    fn what_gh_says_about_a_pull_request() {
        let now = 1_791_582_173;
        let open = decode(
            r#"{"state":"OPEN","reviewDecision":"","mergedAt":null,"baseRefName":"dev","headRefOid":"0123456789abcdef0123456789abcdef01234567"}"#,
            now,
        )
        .unwrap();
        assert_eq!(open.state, "OPEN");
        assert_eq!(open.review_decision, None);
        assert_eq!(open.base, "dev");
        assert_eq!(
            open.to_json(),
            json!({"state": "OPEN", "reviewDecision": null, "base": "dev",
                   "checkedAt": "2026-10-09T21:42:53Z", "head": "0123456789abcdef0123456789abcdef01234567"})
        );
        let merged = decode(
            r#"{"state":"MERGED","reviewDecision":"APPROVED","mergedAt":"2026-10-09T22:00:00Z","baseRefName":"dev","headRefOid":""}"#,
            now,
        )
        .unwrap();
        assert_eq!(merged.review_decision.as_deref(), Some("APPROVED"));
        assert_eq!(merged.to_json()["mergedAt"], "2026-10-09T22:00:00Z");
        assert!(merged.to_json().get("head").is_none());
        for bad in [
            r#"{"state":"MERGED","mergedAt":null,"baseRefName":"dev"}"#,
            r#"{"state":"OPEN","mergedAt":"2026-10-09T22:00:00Z","baseRefName":"dev"}"#,
            r#"{"state":"OPEN","baseRefName":""}"#,
            r#"{"state":"DRAFT","baseRefName":"dev"}"#,
            "not json",
        ] {
            assert_eq!(decode(bad, now), None, "{bad}");
        }
    }

    #[test]
    fn what_a_tool_said_keeps_its_last_line() {
        assert_eq!(
            said("hint: one\nerror: it broke\nhint: try again\n"),
            "error: it broke"
        );
        assert_eq!(said(""), "no reason given");
        assert_eq!(said(&"x".repeat(400)).chars().count(), 300);
    }
}
