//! The owner's GitHub login, from the Mac: whether `gh` is signed in, and gh's own sign-in
//! (the owner's decision of 2026-10-18: Oby.app carries gh, and nobody types `gh auth login`).
//!
//! obid never reads, holds or passes the token: gh signs in through GitHub's device page and keeps
//! the login in its own Keychain item, as `gh auth login` always does. What obid takes from gh is
//! the account's name and whether it's signed in (`gh auth status --json hosts`, never
//! `--show-token`), and, while signing in, the one-time code and the page gh prints. None of this
//! is on the gateway's allowlist: a paired phone never signs the Mac in to someone's GitHub.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};

use crate::api::{ApiError, Shared};

/// How long a sign-in waits for the person: GitHub's device codes last 15 minutes.
const SIGN_IN_LASTS: Duration = Duration::from_secs(15 * 60);
/// How long gh has to print its code and page.
const CODE_WITHIN: Duration = Duration::from_secs(30);
/// How long a status read is kept: `gh auth status` asks GitHub.
const STATUS_KEPT: Duration = Duration::from_secs(30);
/// The only page a code is typed on.
const DEVICE_PAGE: &str = "https://github.com/login/device";

/// The GitHub login as obid last read it, and the sign-in under way.
#[derive(Default)]
pub struct GitHubLogin {
    status: Mutex<Option<(Instant, Status)>>,
    sign_in: tokio::sync::Mutex<Option<Arc<SignIn>>>,
}

/// Whether gh is signed in to github.com, and as whom.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub signed_in: bool,
    pub user: Option<String>,
}

/// gh's sign-in under way: its code and page, until it ends.
pub struct SignIn {
    user_code: String,
    expires: i64,
    group: Option<u32>,
    ended: tokio::sync::watch::Receiver<bool>,
    cancel: tokio::sync::Notify,
}

impl SignIn {
    fn to_json(&self) -> Value {
        json!({"url": DEVICE_PAGE, "userCode": self.user_code,
               "expiresAt": obi_protocol::time::format(self.expires)})
    }
}

impl GitHubLogin {
    /// Kills a sign-in's whole process group (obid is stopping).
    pub fn kill(&self) {
        if let Ok(guard) = self.sign_in.try_lock()
            && let Some(group) = guard.as_ref().and_then(|s| s.group)
        {
            crate::process::signal_group(group, nix::sys::signal::Signal::SIGKILL);
        }
    }

    fn forget_status(&self) {
        *self.status.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    async fn status(&self, gh: Option<&Path>) -> Status {
        if let Some((at, status)) = &*self.status.lock().unwrap_or_else(|e| e.into_inner())
            && at.elapsed() < STATUS_KEPT
        {
            return status.clone();
        }
        let status = match gh {
            Some(gh) => read_status(gh).await,
            None => Status {
                signed_in: false,
                user: None,
            },
        };
        *self.status.lock().unwrap_or_else(|e| e.into_inner()) =
            Some((Instant::now(), status.clone()));
        status
    }
}

/// `gh auth status` for github.com, as `{signed_in, user}`; signed out when gh says nothing usable.
async fn read_status(gh: &Path) -> Status {
    let said = crate::github::run(
        gh,
        &[
            "auth",
            "status",
            "--hostname",
            "github.com",
            "--active",
            "--json",
            "hosts",
        ],
    )
    .await
    .unwrap_or_default();
    decode_status(&said)
}

/// The active github.com account in `gh auth status --json hosts`, when its state is `success`.
pub fn decode_status(said: &str) -> Status {
    let account = serde_json::from_str::<Value>(said).ok().and_then(|v| {
        v["hosts"]["github.com"]
            .as_array()?
            .iter()
            .find(|a| a["active"] == true && a["state"] == "success")
            .cloned()
    });
    let user = account
        .as_ref()
        .and_then(|a| a["login"].as_str())
        .filter(|l| {
            !l.is_empty()
                && l.len() <= 39
                && l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
        .map(str::to_owned);
    Status {
        signed_in: user.is_some(),
        user,
    }
}

/// `GET /v1/github`: whether obid has a gh, whether it's signed in and as whom, and the sign-in
/// under way.
pub async fn get(State(shared): State<Arc<Shared>>) -> Result<Response, ApiError> {
    let gh = crate::github::gh();
    let status = shared.github.status(gh.as_deref()).await;
    let sign_in = shared
        .github
        .sign_in
        .lock()
        .await
        .as_ref()
        .filter(|s| !*s.ended.borrow())
        .map(|s| s.to_json());
    Ok(
        axum::Json(json!({"gh": gh.is_some(), "signedIn": status.signed_in,
                         "user": status.user, "signIn": sign_in}))
        .into_response(),
    )
}

/// `POST /v1/github/sign-in`: gh's own sign-in, or the one under way: `{url, userCode, expiresAt}`.
/// The app opens `url`; the person types `userCode` there (gh also puts it on the clipboard).
pub async fn sign_in(State(shared): State<Arc<Shared>>) -> Result<Response, ApiError> {
    let mut current = shared.github.sign_in.lock().await;
    if let Some(running) = current.as_ref()
        && !*running.ended.borrow()
    {
        return Ok(axum::Json(running.to_json()).into_response());
    }
    let gh = crate::github::gh()
        .filter(|gh| gh.is_absolute())
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "obid has no GitHub CLI (gh) to sign in with.",
            )
        })?;
    let started = start(&shared, &gh)
        .await
        .map_err(|why| ApiError::new(StatusCode::BAD_GATEWAY, why))?;
    let answer = started.to_json();
    *current = Some(started);
    Ok(axum::Json(answer).into_response())
}

/// `DELETE /v1/github/sign-in`: ends the sign-in under way, if any.
pub async fn end_sign_in(State(shared): State<Arc<Shared>>) -> Result<Response, ApiError> {
    if let Some(running) = shared.github.sign_in.lock().await.as_ref() {
        running.cancel.notify_one();
        let mut ended = running.ended.clone();
        let _ = tokio::time::timeout(Duration::from_secs(5), ended.wait_for(|e| *e)).await;
    }
    Ok(StatusCode::NO_CONTENT.into_response())
}

/// Starts `gh auth login` and waits for its code.
async fn start(shared: &Arc<Shared>, gh: &Path) -> Result<Arc<SignIn>, String> {
    let scratch = scratch_folder(&shared.config.home)?;
    let mut child = match command(gh, &scratch).and_then(|mut c| {
        c.spawn()
            .map_err(|e| format!("obid couldn't start gh's sign-in: {e}"))
    }) {
        Ok(child) => child,
        Err(why) => {
            let _ = std::fs::remove_dir_all(&scratch);
            return Err(why);
        }
    };
    let group = child.id();
    let kill = move || {
        if let Some(group) = group {
            crate::process::signal_group(group, nix::sys::signal::Signal::SIGKILL);
        }
    };
    let (lines, mut said) = tokio::sync::mpsc::unbounded_channel::<String>();
    for out in [
        child
            .stdout
            .take()
            .map(|o| Box::new(o) as Box<dyn tokio::io::AsyncRead + Unpin + Send>),
        child
            .stderr
            .take()
            .map(|e| Box::new(e) as Box<dyn tokio::io::AsyncRead + Unpin + Send>),
    ]
    .into_iter()
    .flatten()
    {
        tokio::spawn(crate::accounts::read_lines(out, lines.clone()));
    }
    drop(lines);
    let wanted = async {
        while let Some(line) = said.recv().await {
            if let Some(code) = user_code(&crate::accounts::plain(&line)) {
                return Some(code);
            }
        }
        None
    };
    let Ok(Some(user_code)) = tokio::time::timeout(CODE_WITHIN, wanted).await else {
        kill();
        let _ = child.wait().await;
        let _ = std::fs::remove_dir_all(&scratch);
        return Err("gh's sign-in didn't give a code to type.".into());
    };
    // The rest of what it prints is read and dropped.
    tokio::spawn(async move { while said.recv().await.is_some() {} });
    let (ended_tx, ended) = tokio::sync::watch::channel(false);
    let sign_in = Arc::new(SignIn {
        user_code,
        expires: obi_protocol::time::now() + SIGN_IN_LASTS.as_secs() as i64,
        group,
        ended,
        cancel: tokio::sync::Notify::new(),
    });
    tracing::info!("GitHub sign-in started");
    let (shared, watched) = (shared.clone(), sign_in.clone());
    tokio::spawn(async move {
        let exited = tokio::select! {
            status = child.wait() => status.ok(),
            () = tokio::time::sleep(SIGN_IN_LASTS) => None,
            () = watched.cancel.notified() => None,
        };
        kill();
        if exited.is_none() {
            let _ = child.wait().await;
        }
        let _ = std::fs::remove_dir_all(&scratch);
        shared.github.forget_status();
        let signed = exited.is_some_and(|s| s.success());
        tracing::info!(
            "GitHub sign-in ended {}",
            if signed {
                "signed in"
            } else {
                "without signing in"
            }
        );
        let _ = ended_tx.send(true);
    });
    Ok(sign_in)
}

/// A folder of obid's own for the sign-in (its `TMPDIR`, working folder, and the git settings gh
/// may write), removed when it ends.
fn scratch_folder(home: &Path) -> Result<PathBuf, String> {
    let scratch = home
        .join("tmp")
        .join(format!("github-sign-in-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    crate::store::make_private_dir(&home.join("tmp"))
        .and_then(|()| crate::store::make_private_dir(&scratch))
        .map_err(|e| format!("obid can't make a folder for the sign-in: {e}"))?;
    Ok(scratch)
}

/// `gh auth login` for github.com through GitHub's device page, with https for git: obid's
/// environment without tokens or the agents' variables, the person's `HOME` (gh keeps its settings
/// and Keychain item where it always does), nothing opened on this machine (the app opens the
/// page), and git's global settings pointed at a file of the sign-in's own, so gh never changes
/// the person's own (`gh auth setup-git` isn't needed: obid gives git gh's login itself). In a
/// process group of its own.
fn command(gh: &Path, scratch: &Path) -> Result<tokio::process::Command, String> {
    let home =
        crate::jobs::login_home().ok_or("obid can't find the person's home for gh's sign-in.")?;
    let mut command = tokio::process::Command::new(gh);
    command
        .args([
            "auth",
            "login",
            "--hostname",
            "github.com",
            "--git-protocol",
            "https",
            "--web",
            "--skip-ssh-key",
        ])
        .env_clear()
        .envs(crate::process::kept(|name| std::env::var_os(name)))
        .env("HOME", home)
        .env("PATH", crate::process::tools_path())
        .env("TMPDIR", scratch)
        .env("GH_BROWSER", "true")
        .env("BROWSER", "true")
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("NO_COLOR", "1")
        .env("GIT_CONFIG_GLOBAL", scratch.join("gitconfig"))
        .current_dir(scratch)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .process_group(0);
    Ok(command)
}

/// gh's one-time code in a line it prints (`! One-time code (BA49-7C89) copied to clipboard`, or
/// `! First copy your one-time code: BA49-7C89`): two groups of four letters or digits.
fn user_code(line: &str) -> Option<String> {
    static CODE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    if !line.to_ascii_lowercase().contains("one-time code") {
        return None;
    }
    CODE.get_or_init(|| {
        regex::Regex::new(r"\b([A-Z0-9]{4}-[A-Z0-9]{4})\b").expect("a valid pattern")
    })
    .captures(line)
    .map(|c| c[1].to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_code_is_taken_from_either_line_gh_prints() {
        assert_eq!(
            user_code("! One-time code (BA49-7C89) copied to clipboard").as_deref(),
            Some("BA49-7C89")
        );
        assert_eq!(
            user_code("! First copy your one-time code: 0F1A-22BC").as_deref(),
            Some("0F1A-22BC")
        );
        assert_eq!(
            user_code(
                "Open this URL to continue in your web browser: https://github.com/login/device"
            ),
            None
        );
        assert_eq!(user_code("ABCD-1234 is not said to be a code"), None);
    }

    #[test]
    fn the_status_is_the_active_github_account_signed_in() {
        let signed = r#"{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"well-prado","tokenSource":"keyring","gitProtocol":"https"}]}}"#;
        assert_eq!(
            decode_status(signed),
            Status {
                signed_in: true,
                user: Some("well-prado".into())
            }
        );
        let signed_out = Status {
            signed_in: false,
            user: None,
        };
        assert_eq!(decode_status(r#"{"hosts":{}}"#), signed_out);
        assert_eq!(decode_status(""), signed_out);
        let failing = r#"{"hosts":{"github.com":[{"state":"error","active":true,"login":"x"}]}}"#;
        assert_eq!(decode_status(failing), signed_out);
        let odd = r#"{"hosts":{"github.com":[{"state":"success","active":true,"login":"a b"}]}}"#;
        assert_eq!(decode_status(odd), signed_out);
    }
}
