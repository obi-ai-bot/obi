//! Running one of this owner's jobs on a teammate's Mac (#797, #807): the guest's side of a
//! `run_request`. The job is an ordinary job here (its worktree, its check, its secret scan, its
//! pull request); only its agent's turn runs over there, in a VM, and this obid stays in the loop:
//!
//! - the code goes as a git bundle on the job channel, after the secret scan of what the job adds;
//! - every model call the agent makes comes back here, and obid sends it to the model's API from
//!   this Mac with this owner's own Claude Code login, the job's account's (the owner's decision of
//!   2026-10-21): the VM has a placeholder, and the login never leaves this Mac. Only the agent's
//!   model paths and an allowlist of headers pass; whatever credential the other Mac sends is
//!   dropped; and nothing is relayed once the exchange ends or the job's minutes are up;
//! - the transcript comes back as it goes, and the commits at the end, into the job's worktree.
//!
//! What comes back from the other Mac is data: the transcript is shown, the commits go through the
//! job's own check and secret scan before anything is published, under this owner.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use aws_lc_rs::digest;
use serde_json::{Value, json};
use tokio::sync::{Semaphore, watch};

use super::Link;
use super::channel::{self, Event, Frame, Kind, Role};
use crate::agent::{self, Event as AgentEvent, Turn};
use crate::process::Signal;

/// The most a job may run on other Macs, all its rounds together, as its `run_request` asks.
const MAX_MINUTES: u64 = 120;

/// What each job spent on other Macs so far, all its rounds together, by repository and branch:
/// tokens and seconds. The budget and the time limit are the job's, not a round's.
// ponytail: in memory; an obid restart starts a job's count again. Kept in the job when that matters.
static SPENT: std::sync::LazyLock<std::sync::Mutex<HashMap<String, (u64, u64)>>> =
    std::sync::LazyLock::new(Default::default);

/// Adds a round's tokens and seconds to its job's count as the round ends, however it ends.
struct Spending {
    job: String,
    tokens: Arc<AtomicU64>,
    since: Option<tokio::time::Instant>,
    seconds_before: u64,
}

impl Drop for Spending {
    fn drop(&mut self) {
        let seconds = self.seconds_before + self.since.map_or(0, |s| s.elapsed().as_secs());
        SPENT.lock().unwrap().insert(
            self.job.clone(),
            (self.tokens.load(Ordering::Relaxed), seconds),
        );
    }
}
/// The most model calls the other Mac may have relayed at once.
const CALLS_AT_ONCE: usize = 4;
/// The most tokens a job on the other Mac may spend of this owner's account, as the answers say
/// (cache reads count a tenth); past it, no call is relayed.
// ponytail: one budget for every job; per job size, or the owner's own, if real jobs reach it.
const MAX_TOKENS: u64 = 10_000_000;
/// The most model calls the other Mac may have open (still sending their request) at once.
const MAX_OPEN: usize = 8;
const MAX_MODEL_BODY: usize = 32 * 1024 * 1024;
const MAX_COMMITS: u64 = 1024 * 1024 * 1024;
/// The longest transcript line kept; a longer one is skipped.
const MAX_LINE: usize = 4 * 1024 * 1024;

/// The request headers a relayed model call keeps (spec protocol.md section 13): every other one,
/// any credential among them, is dropped.
const HEADERS: [&str; 6] = [
    "content-type",
    "accept",
    "anthropic-version",
    "anthropic-beta",
    "openai-beta",
    "user-agent",
];

/// The guest's own Claude Code login as a model call takes it: only the access token and when it
/// ends (crate::jobs: never a refresh token), read where Claude Code keeps it (the Keychain, or the
/// account's `.credentials.json`), its token already among the secrets obid takes out of logs.
#[derive(Clone)]
pub struct Login {
    pub access_token: String,
    /// Milliseconds since 1970, when it says.
    pub expires_ms: Option<u64>,
}

impl Login {
    /// The job's account's login, from its folder, or Claude Code's own default one.
    pub fn read(config_dir: Option<&Path>) -> Option<Login> {
        let bytes = match config_dir {
            Some(dir) => crate::jobs::account_login(dir),
            None => crate::jobs::keychain_login(None).or_else(|| {
                crate::jobs::login_home()
                    .and_then(|home| crate::jobs::folder_login(&home.join(".claude")))
            }),
        }?;
        let login: Value = serde_json::from_slice(&bytes).ok()?;
        let oauth = &login["claudeAiOauth"];
        Some(Login {
            access_token: oauth["accessToken"].as_str()?.to_owned(),
            expires_ms: oauth["expiresAt"].as_u64(),
        })
    }

    /// Whether it still works `seconds` from now.
    pub fn lasts(&self, seconds: u64) -> bool {
        self.expires_ms
            .is_none_or(|t| t > (obi_protocol::time::now().max(0) as u64 + seconds) * 1000)
    }
}

/// The vault secret each agent's company API key is kept under.
pub fn key_name(agent: &str) -> &'static str {
    if agent == "codex" {
        "openai-api-key"
    } else {
        "anthropic-api-key"
    }
}

/// Where each agent's model API is.
fn upstream(link: &Link, agent: &str) -> String {
    link.model_api_base().unwrap_or_else(|| {
        if agent == "codex" {
            "https://api.openai.com".into()
        } else {
            "https://api.anthropic.com".into()
        }
    })
}

/// What the request carries, and the answer to it.
pub struct Ask<'a> {
    pub host: &'a str,
    pub host_owner: &'a str,
    pub agent: &'a str,
    pub model: Option<&'a str>,
    pub repo: &'a str,
    pub base_branch: &'a str,
    pub branch: &'a str,
    pub title: &'a str,
    pub size: &'a str,
    /// The job's account's folder (`CLAUDE_CONFIG_DIR`), or none for Claude Code's own login.
    pub config_dir: Option<&'a Path>,
}

async fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    crate::git::git(dir, args).await.map_err(|e| e.to_string())
}

/// Runs the job's turn on the other Mac and answers how it went, in the shape a local turn has.
pub async fn run_turn(
    link: &Arc<Link>,
    ask: Ask<'_>,
    worktree: &Path,
    prompt: &str,
    mut signal: watch::Receiver<Signal>,
    mut on_event: impl FnMut(AgentEvent),
) -> Result<Turn, String> {
    if ask.agent != "claude" {
        return Err("Only Claude Code jobs run on another Mac so far: run this one here.".into());
    }
    // The job's model calls use this owner's own Claude Code login, from this Mac: it must be there,
    // and good for a while (Claude Code refreshes it when it runs here).
    let login = Login::read(ask.config_dir)
        .filter(|l| l.lasts(600))
        .ok_or("Your Claude Code login on this Mac has expired, or isn't there: run claude once to sign in, then try again. The job's model calls use it, from this Mac.")?;
    on_event(AgentEvent::Step(format!(
        "Packing the code for {}'s Mac",
        ask.host_owner
    )));
    // What's done so far is committed first: the other Mac gets the job's code as commits.
    if !git(worktree, &["status", "--porcelain"]).await?.is_empty() {
        git(worktree, &["add", "-A"]).await?;
        git(
            worktree,
            &[
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-q",
                "-m",
                "Work so far",
            ],
        )
        .await?;
    }
    let base_sha = git(worktree, &["rev-parse", "HEAD"]).await?;
    // Everything that leaves goes through the secret scan first: the whole tree the snapshot
    // carries, as one diff from the empty tree, not only what the job added.
    let empty = crate::git::run_bytes(
        worktree,
        &[
            "hash-object".as_ref(),
            "-t".as_ref(),
            "tree".as_ref(),
            "--stdin".as_ref(),
        ],
        &[],
        Some(Vec::new()),
    )
    .await
    .map_err(|e| e.to_string())?;
    let empty = String::from_utf8_lossy(&empty).trim().to_owned();
    let tree = git(
        worktree,
        &["diff", "--no-color", "--no-ext-diff", &empty, "HEAD"],
    )
    .await?;
    let scratch = link.home().join("tmp");
    let _ = std::fs::create_dir_all(&scratch);
    match crate::scan::scan(&[("the job's code".into(), tree)], &scratch).await {
        crate::scan::Verdict::Clean => {}
        crate::scan::Verdict::Found(found) => {
            return Err(format!(
                "The secret scan found a possible secret in {}: nothing was sent to {}'s Mac.",
                found.first().map(ToString::to_string).unwrap_or_default(),
                ask.host_owner
            ));
        }
        crate::scan::Verdict::CouldNotRun(why) => {
            return Err(format!(
                "The secret scan couldn't run ({why}): nothing was sent."
            ));
        }
    }
    let dir = link
        .home()
        .join("tmp")
        .join(format!("guest-{}", uuid::Uuid::new_v4().simple()));
    crate::store::make_private_dir(&dir).map_err(|e| e.to_string())?;
    let outcome = run_in(
        link,
        &ask,
        worktree,
        prompt,
        login,
        &base_sha,
        &dir,
        &mut signal,
        &mut on_event,
    )
    .await;
    let _ = std::fs::remove_dir_all(&dir);
    outcome
}

#[allow(clippy::too_many_arguments)]
async fn run_in(
    link: &Arc<Link>,
    ask: &Ask<'_>,
    worktree: &Path,
    prompt: &str,
    mut login: Login,
    base_sha: &str,
    dir: &Path,
    signal: &mut watch::Receiver<Signal>,
    on_event: &mut impl FnMut(AgentEvent),
) -> Result<Turn, String> {
    let bundle = dir.join("in.bundle");
    let job = format!("{}#{}", ask.repo, ask.branch);
    let (tokens_before, seconds_before) =
        SPENT.lock().unwrap().get(&job).copied().unwrap_or((0, 0));
    if tokens_before >= MAX_TOKENS || seconds_before >= MAX_MINUTES * 60 {
        return Ok(failed(
            "This job used all the time and tokens it may on other Macs: run it here.",
        ));
    }
    let left = MAX_MINUTES * 60 - seconds_before;
    let mut spending = Spending {
        job,
        tokens: Arc::new(AtomicU64::new(tokens_before)),
        since: None,
        seconds_before,
    };
    // Only the job's code goes, never the repository's history: one commit of its tree (the tree
    // scanned) with no parent. What comes back is replayed onto base_sha.
    let snapshot = crate::git::run(
        worktree,
        &[
            "commit-tree".as_ref(),
            format!("{base_sha}^{{tree}}").as_ref(),
            "-m".as_ref(),
            "The job's code".as_ref(),
        ],
        &[
            ("GIT_AUTHOR_NAME", "Oby"),
            ("GIT_AUTHOR_EMAIL", "oby@users.noreply.github.com"),
            ("GIT_COMMITTER_NAME", "Oby"),
            ("GIT_COMMITTER_EMAIL", "oby@users.noreply.github.com"),
        ],
    )
    .await
    .map_err(|e| e.to_string())?;
    let tag = format!("refs/obi-guest/{}", uuid::Uuid::new_v4().simple());
    git(worktree, &["update-ref", &tag, &snapshot]).await?;
    let made = git(
        worktree,
        &["bundle", "create", "-q", &bundle.to_string_lossy(), &tag],
    )
    .await;
    let _ = git(worktree, &["update-ref", "-d", &tag]).await;
    made?;
    let bytes = std::fs::read(&bundle).map_err(|e| e.to_string())?;
    let sha = hex::encode(digest::digest(&digest::SHA256, &bytes).as_ref());
    let mut body = json!({"title": ask.title, "request": prompt, "agent": ask.agent, "repo": ask.repo,
                          "base_branch": ask.base_branch, "base_sha": snapshot, "branch": ask.branch,
                          "bundle": {"sha256": sha, "bytes": bytes.len()}, "size": ask.size, "max_minutes": left.div_ceil(60)});
    if let Some(model) = ask.model {
        body["model"] = json!(model);
    }
    let exchange = link
        .send_request(ask.host, "run_request", body, 86_400)
        .await
        .map_err(|e| e.message)?;
    let cid = exchange.correlation_id.clone();
    on_event(AgentEvent::Step(format!(
        "Waiting for {}'s Mac",
        ask.host_owner
    )));
    // The answer: accepted, or declined with a reason.
    loop {
        let Some(ex) = link.exchange(&cid) else {
            return Err("the request is gone".into());
        };
        match ex.state.as_str() {
            "accepted" => break,
            "declined" | "expired" => return Ok(declined(&ex, ask.host_owner)),
            _ => {}
        }
        tokio::select! {
            () = tokio::time::sleep(Duration::from_millis(500)) => {}
            () = told_to_stop(signal) => {
                link.send_cancel(&cid);
                return Ok(Turn { stopped: true, ..Turn::default() });
            }
        }
    }
    let accepted = tokio::time::Instant::now();
    spending.since = Some(accepted);
    on_event(AgentEvent::Step(format!(
        "Running on {}'s Mac",
        ask.host_owner
    )));
    let params = link
        .channel_params(&cid, ask.host, Role::Guest)
        .ok_or("obid isn't in a Sphere")?;
    let (channel, mut events) = channel::open(params, link.clone());
    let mut session = Session::new(ask.agent, worktree);
    let author = author_of(link, worktree).await;
    let upstream = upstream(link, ask.agent);
    // A redirect would take the owner's login somewhere else.
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;
    let calls = Arc::new(Semaphore::new(CALLS_AT_ONCE));
    let spent = spending.tokens.clone();
    let mut bundle_sent = false;
    // An open model call: what it asks, its body so far, and whether that went past the limit.
    let mut models: HashMap<u32, (Value, Vec<u8>, bool)> = HashMap::new();
    // The commits as they come: their stream, the file, its hash, bytes so far, the sha and size named.
    let mut commits: Option<(u32, std::fs::File, digest::Context, u64, String, u64)> = None;
    let commits_file = dir.join("out.bundle");
    let commits_part = dir.join("out.bundle.part");
    let mut got_commits: Option<String> = None;
    let mut poll = tokio::time::interval(Duration::from_millis(500));
    let mut ended_at: Option<tokio::time::Instant> = None;
    loop {
        tokio::select! {
            event = events.recv() => {
                let Some(event) = event else { break };
                match event {
                    Event::Ready => {
                        channel.send(Frame::json(0, Kind::Data, &json!({"author": author}))).await;
                        channel.send(Frame::json(0, Kind::Data, &json!({"transcript_from": session.lines}))).await;
                        if !bundle_sent {
                            let stream = 2;
                            channel.send(Frame::json(stream, Kind::Open, &json!({"type": "bundle", "sha256": sha_of(&bytes), "bytes": bytes.len()}))).await;
                            channel.send_data(stream, &bytes).await;
                            channel.send(Frame::new(stream, Kind::End, Vec::new())).await;
                        }
                    }
                    Event::Lost(_) => {
                        models.clear();
                        commits = None;
                        session.stream = None;
                    }
                    Event::Closed(_) => break,
                    Event::Frame(frame) => {
                        if frame.stream == 0 {
                            if frame.value().is_some_and(|v| v["bundle"] == "received") {
                                bundle_sent = true;
                            }
                            continue;
                        }
                        match frame.kind {
                            Kind::Open => {
                                let Some(open) = frame.value() else { continue };
                                match open["type"].as_str() {
                                    Some("model") if models.len() >= MAX_OPEN => {
                                        let channel = channel.clone();
                                        tokio::spawn(async move {
                                            refuse(&channel, frame.stream, 429, "too many model calls at once").await;
                                        });
                                    }
                                    Some("model") => { models.insert(frame.stream, (open, Vec::new(), false)); }
                                    Some("transcript") => {
                                        session.stream = Some(frame.stream);
                                        session.partial.clear();
                                        session.skipping = false;
                                    }
                                    Some("commits") => {
                                        let want = open["bytes"].as_u64().unwrap_or(0);
                                        commits = None;
                                        if want <= MAX_COMMITS && let Ok(file) = std::fs::File::create(&commits_part) {
                                            commits = Some((frame.stream, file, digest::Context::new(&digest::SHA256), 0,
                                                            open["sha256"].as_str().unwrap_or("").to_owned(), want));
                                        }
                                    }
                                    _ => {}
                                }
                            }
                            Kind::Data => {
                                if let Some((_, body, over)) = models.get_mut(&frame.stream) {
                                    if body.len() + frame.payload.len() <= MAX_MODEL_BODY {
                                        body.extend_from_slice(&frame.payload);
                                    } else {
                                        *over = true;
                                        body.clear();
                                    }
                                } else if session.stream == Some(frame.stream) {
                                    session.read(&frame.payload, on_event);
                                } else if let Some((stream, file, hash, got, _, want)) = commits.as_mut()
                                    && *stream == frame.stream
                                {
                                    *got += frame.payload.len() as u64;
                                    hash.update(&frame.payload);
                                    if *got > *want || file.write_all(&frame.payload).is_err() {
                                        commits = None;
                                    }
                                }
                            }
                            Kind::End => {
                                if let Some((open, body, too_big)) = models.remove(&frame.stream) {
                                    // Not once the exchange is over or the job's minutes are up: the
                                    // other Mac can't keep spending this owner's account.
                                    let over = link.exchange(&cid).is_none_or(|e| e.ended())
                                        || accepted.elapsed() > Duration::from_secs(left);
                                    let spent_all = spent.load(Ordering::Relaxed) >= MAX_TOKENS;
                                    let permit = calls.clone().try_acquire_owned().ok();
                                    if !login.lasts(300) {
                                        login = Login::read(ask.config_dir).unwrap_or(login);
                                    }
                                    let channel = channel.clone();
                                    let (http, spent) = (http.clone(), spent.clone());
                                    let (upstream, token) = (upstream.clone(), login.access_token.clone());
                                    tokio::spawn(async move {
                                        if over {
                                            refuse(&channel, frame.stream, 403, "the job's time on that Mac is over").await;
                                        } else if spent_all {
                                            refuse(&channel, frame.stream, 403, "the job used all the tokens it may").await;
                                        } else if too_big {
                                            refuse(&channel, frame.stream, 413, "the call is too big to relay").await;
                                        } else if permit.is_none() {
                                            refuse(&channel, frame.stream, 429, "too many model calls at once").await;
                                        } else {
                                            let used = relay(&channel, &http, &upstream, &token, frame.stream, &open, body).await;
                                            spent.fetch_add(used, Ordering::Relaxed);
                                        }
                                        drop(permit);
                                    });
                                } else if let Some((stream, file, hash, got, want_sha, want)) = commits.take()
                                    && stream == frame.stream
                                    && got == want
                                    && hex::encode(hash.finish().as_ref()) == want_sha
                                    && file.sync_all().is_ok()
                                    && std::fs::rename(&commits_part, &commits_file).is_ok()
                                {
                                    got_commits = Some(want_sha);
                                    channel.send(Frame::json(0, Kind::Data, &json!({"commits": "received"}))).await;
                                }
                            }
                            Kind::Reset => {
                                models.remove(&frame.stream);
                                if commits.as_ref().is_some_and(|c| c.0 == frame.stream) {
                                    commits = None;
                                }
                            }
                        }
                    }
                }
            }
            _ = poll.tick() => {
                let ended = link.exchange(&cid).is_none_or(|e| e.ended());
                if ended {
                    // The reply that ends it comes after the commits: a little longer for the channel.
                    let until = *ended_at.get_or_insert_with(|| tokio::time::Instant::now() + Duration::from_secs(10));
                    if tokio::time::Instant::now() > until {
                        break;
                    }
                }
            }
            () = told_to_stop(signal) => {
                link.send_cancel(&cid);
                channel.close().await;
                return Ok(Turn { stopped: true, ..Turn::default() });
            }
        }
    }
    channel.close().await;
    let ex = link.exchange(&cid).ok_or("the request is gone")?;
    let reply = ex.messages.iter().rev().map(|m| &m.envelope).find(|e| {
        matches!(
            e["type"].as_str(),
            Some("result" | "run_return" | "decline")
        )
    });
    let Some(reply) = reply.cloned() else {
        return Ok(failed(&format!(
            "{}'s Mac stopped answering before the job finished.",
            ask.host_owner
        )));
    };
    if reply["type"] == "decline" {
        return Ok(declined(&ex, ask.host_owner));
    }
    // The commits, when the reply names the ones that came.
    let named = reply["body"]["commits"]["sha256"]
        .as_str()
        .map(str::to_owned);
    let mut count = 0;
    if let (Some(named), Some(got)) = (&named, &got_commits)
        && named == got
    {
        count = apply(worktree, &commits_file, ask.branch, base_sha, &snapshot).await?;
    } else if named.is_some() {
        return Ok(failed(&format!(
            "The commits from {}'s Mac didn't arrive whole, so obid kept none of them.",
            ask.host_owner
        )));
    }
    let mut turn = session.turn;
    if reply["type"] == "run_return" {
        let minutes = reply["body"]["minutes"].as_u64().unwrap_or(0);
        let why = match reply["body"]["reason"].as_str() {
            Some("owner_back") => format!("{} is back at that Mac", ask.host_owner),
            Some("time_limit") => "it reached its time limit there".to_owned(),
            Some("sharing_off") => format!("{} turned sharing off", ask.host_owner),
            Some("shutdown") => "that Mac shut down".to_owned(),
            _ => format!("{} stopped it", ask.host_owner),
        };
        let text = format!(
            "Came back from {}'s Mac: {why}. It ran {minutes} minute{} there and came back with its notes and {count} commit{}. Try again to send it back there, or run it here.",
            ask.host_owner,
            if minutes == 1 { "" } else { "s" },
            if count == 1 { "" } else { "s" }
        );
        turn.result = Some(agent::result(&text, true, None));
        turn.last_words = text;
        return Ok(turn);
    }
    if turn.result.is_none() {
        let ok = reply["body"]["outcome"] == "done";
        let text = if ok {
            format!("Done on {}'s Mac.", ask.host_owner)
        } else {
            format!("The job failed on {}'s Mac.", ask.host_owner)
        };
        turn.result = Some(agent::result(&text, !ok, None));
    }
    turn.exit = "exited on another Mac".into();
    Ok(turn)
}

/// Waits until the job is told to stop (its guard dropped before the wait ends, so the future
/// stays `Send`).
async fn told_to_stop(signal: &mut watch::Receiver<Signal>) {
    let _ = signal.wait_for(|s| *s != Signal::Run).await;
}

fn sha_of(bytes: &[u8]) -> String {
    hex::encode(digest::digest(&digest::SHA256, bytes).as_ref())
}

fn failed(text: &str) -> Turn {
    Turn {
        result: Some(agent::result(text, true, None)),
        last_words: text.into(),
        ..Turn::default()
    }
}

fn declined(ex: &super::exchange::Exchange, host_owner: &str) -> Turn {
    let reason = ex
        .messages
        .iter()
        .rev()
        .find(|m| m.envelope["type"] == "decline")
        .and_then(|m| m.envelope["body"]["reason"].as_str())
        .unwrap_or("expired");
    let text = match reason {
        "not_free" => {
            format!("{host_owner}'s Mac isn't free now. Try again later, or run it here.")
        }
        "busy" => {
            format!("{host_owner}'s Mac is busy with another job. Try again later, or run it here.")
        }
        "owner_declined" => {
            format!("{host_owner} said no to running it on their Mac. Run it here instead.")
        }
        "policy" => format!("{host_owner}'s Mac doesn't take your jobs. Run it here instead."),
        "expired" => {
            format!("{host_owner}'s Mac didn't answer in time. Try again, or run it here.")
        }
        _ => format!("{host_owner}'s Mac couldn't take it. Run it here instead."),
    };
    failed(&text)
}

/// The owner's name and email as git has them here: the commits made there are theirs.
async fn author_of(link: &Link, worktree: &Path) -> Value {
    let name = git(worktree, &["config", "user.name"])
        .await
        .unwrap_or_default();
    let email = git(worktree, &["config", "user.email"])
        .await
        .unwrap_or_default();
    let name = if name.is_empty() {
        link.owner().to_owned()
    } else {
        name
    };
    let email = if email.is_empty() {
        "oby@users.noreply.github.com".into()
    } else {
        email
    };
    json!({"name": name, "email": email})
}

/// Takes the job's commits from the bundle into its worktree: only commits on top of the snapshot
/// it went with, on the job's own branch, replayed onto `base` (along the first parent).
async fn apply(
    worktree: &Path,
    bundle: &Path,
    branch: &str,
    base: &str,
    snapshot: &str,
) -> Result<usize, String> {
    let file = bundle.to_string_lossy().into_owned();
    git(worktree, &["bundle", "verify", "-q", &file])
        .await
        .map_err(|e| format!("the commits' bundle isn't whole: {e}"))?;
    git(
        worktree,
        &[
            "fetch",
            "-q",
            "--no-tags",
            &file,
            &format!("refs/heads/{branch}"),
        ],
    )
    .await?;
    let head = git(worktree, &["rev-parse", "FETCH_HEAD"]).await?;
    if git(worktree, &["merge-base", "--is-ancestor", snapshot, &head])
        .await
        .is_err()
    {
        return Err(
            "The commits that came back don't build on the job's code, so obid kept none of them."
                .into(),
        );
    }
    let list = git(
        worktree,
        &[
            "rev-list",
            "--reverse",
            "--first-parent",
            &format!("{snapshot}..{head}"),
        ],
    )
    .await?;
    let mut parent = base.to_owned();
    let mut count = 0;
    for commit in list.lines() {
        let who = git(
            worktree,
            &[
                "log",
                "-1",
                "--date=raw",
                "--format=%an%x00%ae%x00%ad%x00%cn%x00%ce%x00%cd",
                commit,
            ],
        )
        .await?;
        let who: Vec<&str> = who.split('\0').collect();
        let [an, ae, ad, cn, ce, cd] = who[..] else {
            return Err("a commit that came back has no author".into());
        };
        let message = git(worktree, &["log", "-1", "--format=%B", commit]).await?;
        parent = crate::git::run(
            worktree,
            &[
                "commit-tree".as_ref(),
                format!("{commit}^{{tree}}").as_ref(),
                "-p".as_ref(),
                parent.as_ref(),
                "-m".as_ref(),
                message.as_ref(),
            ],
            &[
                ("GIT_AUTHOR_NAME", an),
                ("GIT_AUTHOR_EMAIL", ae),
                ("GIT_AUTHOR_DATE", ad),
                ("GIT_COMMITTER_NAME", cn),
                ("GIT_COMMITTER_EMAIL", ce),
                ("GIT_COMMITTER_DATE", cd),
            ],
        )
        .await
        .map_err(|e| e.to_string())?;
        count += 1;
    }
    git(worktree, &["reset", "-q", "--hard", &parent]).await?;
    Ok(count)
}

/// A model call answered here with an error, never sent on.
async fn refuse(channel: &channel::Channel, stream: u32, status: u16, why: &str) {
    channel
        .send(Frame::json(
            stream,
            Kind::Open,
            &json!({"type": "model_response", "status": status, "headers": [["content-type", "text/plain"]]}),
        ))
        .await;
    channel.send_data(stream, why.as_bytes()).await;
    channel
        .send(Frame::new(stream, Kind::End, Vec::new()))
        .await;
}

/// The `anthropic-beta` a call on a Claude Code login needs.
const OAUTH_BETA: &str = "oauth-2025-04-20";

/// One model call: allowed paths and headers only, sent from this Mac with this owner's own
/// Claude Code login, its answer streamed back on the same stream.
async fn relay(
    channel: &channel::Channel,
    http: &reqwest::Client,
    upstream: &str,
    token: &str,
    stream: u32,
    open: &Value,
    body: Vec<u8>,
) -> u64 {
    let asked = body.len();
    let method = open["method"].as_str().unwrap_or("");
    let path = open["path"].as_str().unwrap_or("");
    let refuse = |status: u16, why: &str| {
        Frame::json(
            stream,
            Kind::Open,
            &json!({"type": "model_response", "status": status, "headers": [["content-type", "text/plain"]], "why": why}),
        )
    };
    if !super::hosting::model_path_allowed(method, path) {
        tracing::warn!("sphere: refused a model call to {method} a path outside the allow-list");
        channel.send(refuse(403, "not relayed")).await;
        channel
            .send(Frame::new(stream, Kind::End, Vec::new()))
            .await;
        return 0;
    }
    let mut request = match method {
        "GET" => http.get(format!("{upstream}{path}")),
        _ => http.post(format!("{upstream}{path}")).body(body),
    };
    let mut betas: Vec<String> = Vec::new();
    for pair in open["headers"].as_array().into_iter().flatten() {
        let (Some(name), Some(value)) = (pair[0].as_str(), pair[1].as_str()) else {
            continue;
        };
        let name = name.to_ascii_lowercase();
        if name == "anthropic-beta" {
            betas.extend(
                value
                    .split(',')
                    .map(|b| b.trim().to_owned())
                    .filter(|b| !b.is_empty()),
            );
        } else if HEADERS.contains(&name.as_str()) {
            request = request.header(name, value);
        }
    }
    if !betas.iter().any(|b| b == OAUTH_BETA) {
        betas.push(OAUTH_BETA.into());
    }
    request = request
        .header("anthropic-beta", betas.join(","))
        .bearer_auth(token);
    let response = match request.send().await {
        Ok(response) => response,
        Err(_) => {
            channel
                .send(refuse(502, "the model's API couldn't be reached"))
                .await;
            channel
                .send(Frame::new(stream, Kind::End, Vec::new()))
                .await;
            return 0;
        }
    };
    let headers: Vec<Value> = response
        .headers()
        .iter()
        .filter(|(n, _)| {
            !matches!(
                n.as_str(),
                "content-length"
                    | "transfer-encoding"
                    | "connection"
                    | "set-cookie"
                    | "anthropic-organization-id"
            )
        })
        .filter_map(|(n, v)| v.to_str().ok().map(|v| json!([n.as_str(), v])))
        .collect();
    channel.send(Frame::json(stream, Kind::Open, &json!({"type": "model_response", "status": response.status().as_u16(), "headers": headers}))).await;
    let mut response = response;
    let mut tokens = Tokens::default();
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) => {
                tokens.feed(&chunk);
                if !channel.send_data(stream, &chunk).await {
                    return tokens.total(asked);
                }
            }
            Ok(None) => break,
            Err(_) => {
                channel
                    .send(Frame::new(
                        stream,
                        Kind::Reset,
                        b"the model's answer broke off".to_vec(),
                    ))
                    .await;
                return tokens.total(asked);
            }
        }
    }
    channel
        .send(Frame::new(stream, Kind::End, Vec::new()))
        .await;
    tokens.total(asked)
}

/// The tokens a relayed answer says it used: the most each count reached in its stream's events
/// (`data: {…}` lines; a stream's counts are cumulative) or in its body.
#[derive(Default)]
struct Tokens {
    partial: Vec<u8>,
    input: u64,
    output: u64,
    cache_write: u64,
    cache_read: u64,
    reported: bool,
}

impl Tokens {
    fn feed(&mut self, chunk: &[u8]) {
        self.partial.extend_from_slice(chunk);
        while let Some(at) = self.partial.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.partial.drain(..=at).collect();
            self.line(&line);
        }
        if self.partial.len() > MAX_LINE {
            self.partial.clear();
        }
    }

    fn line(&mut self, line: &[u8]) {
        let line = line.strip_prefix(b"data:").unwrap_or(line);
        let Ok(event) = serde_json::from_slice::<Value>(line.trim_ascii()) else {
            return;
        };
        for usage in [
            &event["usage"],
            &event["message"]["usage"],
            &event["response"]["usage"],
        ] {
            if !usage.is_object() {
                continue;
            }
            let n = |k: &str| usage[k].as_u64().unwrap_or(0);
            self.reported = true;
            self.input = self.input.max(n("input_tokens") + n("prompt_tokens"));
            self.output = self.output.max(n("output_tokens") + n("completion_tokens"));
            self.cache_write = self.cache_write.max(n("cache_creation_input_tokens"));
            self.cache_read = self.cache_read.max(n("cache_read_input_tokens"));
        }
    }

    /// What the call counts against the job's budget; an answer that never said, a conservative
    /// guess from what it asked (`asked` bytes, about 3 to a token, and a long answer).
    fn total(mut self, asked: usize) -> u64 {
        let rest = std::mem::take(&mut self.partial);
        self.line(&rest);
        if !self.reported {
            return asked as u64 / 3 + 32_000;
        }
        self.input + self.output + self.cache_write + self.cache_read / 10
    }
}

/// The transcript as it comes: its lines, read into the job's events.
struct Session {
    agent: String,
    stream: Option<u32>,
    partial: Vec<u8>,
    /// Inside a line longer than MAX_LINE, which is skipped (and still counted).
    skipping: bool,
    lines: usize,
    turn: Turn,
    _worktree: PathBuf,
}

impl Session {
    fn new(agent: &str, worktree: &Path) -> Session {
        Session {
            agent: agent.into(),
            stream: None,
            partial: Vec::new(),
            skipping: false,
            lines: 0,
            turn: Turn::default(),
            _worktree: worktree.to_owned(),
        }
    }

    fn read(&mut self, bytes: &[u8], on_event: &mut impl FnMut(AgentEvent)) {
        for piece in bytes.split_inclusive(|b| *b == b'\n') {
            if !self.skipping {
                self.partial.extend_from_slice(piece);
            }
            if piece.last() != Some(&b'\n') {
                if self.partial.len() > MAX_LINE {
                    self.partial.clear();
                    self.skipping = true;
                }
                continue;
            }
            self.lines += 1;
            let line = std::mem::take(&mut self.partial);
            if std::mem::take(&mut self.skipping) {
                continue;
            }
            let Ok(message) = serde_json::from_slice::<Value>(&line) else {
                continue;
            };
            if self.agent == "codex" {
                codex_line(&message, &mut self.turn, on_event);
            } else {
                claude_line(&message, &mut self.turn, on_event);
            }
        }
    }
}

/// A Claude Code `stream-json` line from the other Mac, as the job's events.
fn claude_line(message: &Value, turn: &mut Turn, on_event: &mut impl FnMut(AgentEvent)) {
    let text = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
    match message["type"].as_str() {
        Some("assistant") => {
            let own = message.get("parent_tool_use_id").is_none_or(Value::is_null);
            for block in message["message"]["content"]
                .as_array()
                .into_iter()
                .flatten()
            {
                match block["type"].as_str() {
                    Some("text") => {
                        let said = text(block, "text");
                        if own && !said.trim().is_empty() {
                            turn.last_words = said.clone();
                        }
                        on_event(AgentEvent::Said(said));
                    }
                    Some("tool_use") => {
                        let name = text(block, "name");
                        let input = block.get("input").cloned().unwrap_or(Value::Null);
                        on_event(AgentEvent::Step(agent::step(&name, &input)));
                        on_event(AgentEvent::Tool {
                            id: text(block, "id"),
                            name,
                            input,
                        });
                    }
                    _ => {}
                }
            }
        }
        Some("user") => {
            for block in message["message"]["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|b| b["type"] == "tool_result")
            {
                let output = match &block["content"] {
                    Value::String(s) => s.clone(),
                    Value::Array(parts) => parts
                        .iter()
                        .filter_map(|p| p["text"].as_str())
                        .collect::<Vec<_>>()
                        .join("\n"),
                    _ => String::new(),
                };
                on_event(AgentEvent::ToolDone {
                    id: text(block, "tool_use_id"),
                    failed: block["is_error"] == true,
                    exit: None,
                    lines: None,
                    output: Some(output),
                    patches: Vec::new(),
                });
            }
        }
        Some("result") => {
            on_event(AgentEvent::Tokens(crate::usage::claude_tokens(
                message,
                Some("ANTHROPIC_API_KEY"),
            )));
            turn.result = Some(message.clone());
        }
        _ => {}
    }
}

/// A `codex exec --json` line from the other Mac, as the job's events.
fn codex_line(message: &Value, turn: &mut Turn, on_event: &mut impl FnMut(AgentEvent)) {
    let item = &message["item"];
    match (message["type"].as_str(), item["type"].as_str()) {
        (Some("item.completed"), Some("agent_message")) => {
            let said = item["text"].as_str().unwrap_or("").to_owned();
            if !said.trim().is_empty() {
                turn.last_words = said.clone();
            }
            on_event(AgentEvent::Said(said));
        }
        (Some("item.started"), Some("command_execution")) => {
            let command = item["command"].as_str().unwrap_or("").to_owned();
            let input = json!({"command": command});
            on_event(AgentEvent::Step(agent::step("Bash", &input)));
            on_event(AgentEvent::Tool {
                id: item["id"].as_str().unwrap_or("").into(),
                name: "Bash".into(),
                input,
            });
        }
        (Some("item.completed"), Some("command_execution")) => {
            let exit = item["exit_code"].as_i64();
            on_event(AgentEvent::ToolDone {
                id: item["id"].as_str().unwrap_or("").into(),
                failed: exit.is_some_and(|e| e != 0),
                exit,
                lines: None,
                output: item["aggregated_output"].as_str().map(str::to_owned),
                patches: Vec::new(),
            });
        }
        (Some("turn.completed"), _) => {
            turn.result = Some(agent::result(&turn.last_words, false, None));
        }
        (Some("turn.failed"), _) => {
            let why = message["error"]["message"]
                .as_str()
                .unwrap_or("Codex failed on the other Mac.");
            turn.result = Some(agent::result(why, true, None));
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_claude_transcript_from_the_other_mac_becomes_the_jobs_events() {
        let mut turn = Turn::default();
        let mut events = Vec::new();
        let mut on = |e| events.push(e);
        let lines = [
            json!({"type": "system", "subtype": "init", "session_id": "elsewhere"}),
            json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "sed -i s/a/b/ x"}}]}}),
            json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}),
            json!({"type": "assistant", "message": {"content": [{"type": "text", "text": "Done: add() adds now."}]}}),
            json!({"type": "result", "subtype": "success", "is_error": false, "result": "Done: add() adds now.", "usage": {"input_tokens": 10, "output_tokens": 5}}),
        ];
        for line in &lines {
            claude_line(line, &mut turn, &mut on);
        }
        assert!(turn.succeeded());
        assert_eq!(turn.last_words, "Done: add() adds now.");
        // The other Mac's session can't be resumed here: none is kept.
        assert_eq!(turn.session, None);
        assert!(
            events
                .iter()
                .any(|e| matches!(e, AgentEvent::Tool { name, .. } if name == "Bash"))
        );
        assert!(
            events
                .iter()
                .any(|e| matches!(e, AgentEvent::ToolDone { id, .. } if id == "t1"))
        );
    }

    #[test]
    fn a_line_split_across_frames_is_read_once_whole() {
        let mut session = Session::new("claude", Path::new("/tmp"));
        let mut events = Vec::new();
        let line = format!(
            "{}\n",
            json!({"type": "assistant", "message": {"content": [{"type": "text", "text": "hi"}]}})
        );
        let (a, b) = line.as_bytes().split_at(10);
        session.read(a, &mut |e| events.push(e));
        assert!(events.is_empty());
        session.read(b, &mut |e| events.push(e));
        assert_eq!(session.lines, 1);
        assert_eq!(events, vec![AgentEvent::Said("hi".into())]);
    }

    #[test]
    fn a_transcript_line_past_the_limit_is_skipped_and_still_counted() {
        let mut session = Session::new("claude", Path::new("/tmp"));
        let mut events = Vec::new();
        session.read(&vec![b'x'; MAX_LINE + 10], &mut |e| events.push(e));
        assert!(session.partial.is_empty());
        let next = format!(
            "yyy\n{}\n",
            json!({"type": "assistant", "message": {"content": [{"type": "text", "text": "hi"}]}})
        );
        session.read(next.as_bytes(), &mut |e| events.push(e));
        assert_eq!(session.lines, 2);
        assert_eq!(events, vec![AgentEvent::Said("hi".into())]);
    }

    #[test]
    fn a_relayed_answers_tokens_come_from_its_stream_or_its_body() {
        let mut stream = Tokens::default();
        stream.feed(
            b"event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":",
        );
        stream.feed(
            b"{\"input_tokens\":100,\"cache_read_input_tokens\":1000,\"output_tokens\":1}}}\n\n",
        );
        stream.feed(b"data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":50}}\n\n");
        assert_eq!(stream.total(0), 100 + 50 + 100);
        let mut body = Tokens::default();
        body.feed(br#"{"usage": {"input_tokens": 7, "output_tokens": 3}}"#);
        assert_eq!(body.total(0), 10);
        // An answer that never says: what it asked, and a long answer.
        assert_eq!(Tokens::default().total(3_000), 1_000 + 32_000);
    }

    #[test]
    fn each_agent_has_its_own_key_in_the_vault() {
        assert_eq!(key_name("claude"), "anthropic-api-key");
        assert_eq!(key_name("codex"), "openai-api-key");
    }
}
