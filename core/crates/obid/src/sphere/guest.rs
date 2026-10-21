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
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use aws_lc_rs::digest;
use serde_json::{Value, json};
use tokio::sync::watch;

use super::Link;
use super::channel::{self, Event, Frame, Kind, Role};
use crate::agent::{self, Event as AgentEvent, Turn};
use crate::process::Signal;

/// The most a job's words may be on the channel (spec protocol.md section 13).
const MAX_WORDS: usize = 20_000;

/// The most a job may run on the other Mac, as its `run_request` asks.
const MAX_MINUTES: u64 = 120;

/// The request headers a relayed model call keeps (spec protocol.md section 13): every other one,
/// any credential among them, is dropped.
pub(super) const HEADERS: [&str; 6] = [
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
pub(super) fn upstream(link: &Link, agent: &str) -> String {
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
    pub start_commit: Option<&'a str>,
    /// On a share of the teammate's API account (#809): its grant. Its model calls are made on
    /// their Mac with their key, so none comes back here.
    pub grant: Option<&'a str>,
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
    // and good for a while (Claude Code refreshes it when it runs here). On a share of a teammate's
    // API account (#809) the calls are made on their Mac with their key: no login is needed here.
    let login = match ask.grant {
        Some(_) => None,
        None => Some(
            Login::read(ask.config_dir)
                .filter(|l| l.lasts(600))
                .ok_or("Your Claude Code login on this Mac has expired, or isn't there: run claude once to sign in, then try again. The job's model calls use it, from this Mac.")?,
        ),
    };
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
    // What the job adds to the repository goes through the secret scan before it leaves.
    let since = ask.start_commit.unwrap_or(&base_sha);
    let diff = git(
        worktree,
        &[
            "diff",
            "--no-color",
            "--no-ext-diff",
            &format!("{since}..HEAD"),
        ],
    )
    .await?;
    // The job's words go too, on the channel (never in the request, so never in the chain): the
    // spec's limit, and the scan.
    if prompt.chars().count() > MAX_WORDS {
        return Err(format!(
            "The job's words are longer than {MAX_WORDS} characters: too long to send to another Mac."
        ));
    }
    let scratch = link.home().join("tmp");
    let _ = std::fs::create_dir_all(&scratch);
    let outgoing = [
        ("the job's changes".into(), diff),
        ("the job's words".into(), prompt.to_owned()),
    ];
    match crate::scan::scan(&outgoing, &scratch).await {
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
    mut login: Option<Login>,
    base_sha: &str,
    dir: &Path,
    signal: &mut watch::Receiver<Signal>,
    on_event: &mut impl FnMut(AgentEvent),
) -> Result<Turn, String> {
    let bundle = dir.join("in.bundle");
    let tag = format!("refs/obi-guest/{}", uuid::Uuid::new_v4().simple());
    git(worktree, &["update-ref", &tag, base_sha]).await?;
    let made = git(
        worktree,
        &["bundle", "create", "-q", &bundle.to_string_lossy(), &tag],
    )
    .await;
    let _ = git(worktree, &["update-ref", "-d", &tag]).await;
    made?;
    let bytes = std::fs::read(&bundle).map_err(|e| e.to_string())?;
    let sha = hex::encode(digest::digest(&digest::SHA256, &bytes).as_ref());
    let mut body = json!({"title": ask.title, "agent": ask.agent, "repo": ask.repo,
                          "base_branch": ask.base_branch, "base_sha": base_sha, "branch": ask.branch,
                          "bundle": {"sha256": sha, "bytes": bytes.len()}, "size": ask.size, "max_minutes": 120});
    if let Some(model) = ask.model {
        body["model"] = json!(model);
    }
    if let Some(grant) = ask.grant {
        body["account"] = json!({"grant": grant});
    }
    // A Mac that says it's busy isn't asked: the job waits until it's free (Sangam's "Wait for
    // Wellington's Mac"), up to a day.
    let waited = tokio::time::Instant::now();
    while link.runner_free(ask.host).await == Some(false) {
        on_event(AgentEvent::Step(format!(
            "Waiting for {}'s Mac to be free",
            ask.host_owner
        )));
        if waited.elapsed() > Duration::from_secs(86_400) {
            return Ok(failed(&format!(
                "{}'s Mac wasn't free for a day. Run it here instead.",
                ask.host_owner
            )));
        }
        tokio::select! {
            () = tokio::time::sleep(Duration::from_secs(30)) => {}
            () = told_to_stop(signal) => return Ok(Turn { stopped: true, ..Turn::default() }),
        }
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
    let http = reqwest::Client::new();
    let mut bundle_sent = false;
    let mut models: HashMap<u32, (Value, Vec<u8>)> = HashMap::new();
    let mut commits: Option<(u32, Vec<u8>, String, u64)> = None;
    let commits_file = dir.join("out.bundle");
    let mut got_commits: Option<String> = None;
    let mut poll = tokio::time::interval(Duration::from_millis(500));
    let mut ended_at: Option<tokio::time::Instant> = None;
    loop {
        tokio::select! {
            event = events.recv() => {
                let Some(event) = event else { break };
                match event {
                    Event::Ready => {
                        channel.send(Frame::json(0, Kind::Data, &json!({"author": author, "request": prompt}))).await;
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
                                    Some("model") => { models.insert(frame.stream, (open, Vec::new())); }
                                    Some("transcript") => {
                                        session.stream = Some(frame.stream);
                                        session.partial.clear();
                                    }
                                    Some("commits") => {
                                        let want = open["bytes"].as_u64().unwrap_or(0);
                                        commits = Some((frame.stream, Vec::new(), open["sha256"].as_str().unwrap_or("").to_owned(), want));
                                    }
                                    _ => {}
                                }
                            }
                            Kind::Data => {
                                if let Some((_, body)) = models.get_mut(&frame.stream) {
                                    if body.len() + frame.payload.len() <= 32 * 1024 * 1024 {
                                        body.extend_from_slice(&frame.payload);
                                    }
                                } else if session.stream == Some(frame.stream) {
                                    session.read(&frame.payload, on_event);
                                } else if let Some((stream, data, _, want)) = commits.as_mut()
                                    && *stream == frame.stream
                                    && (data.len() as u64) + (frame.payload.len() as u64) <= *want
                                {
                                    data.extend_from_slice(&frame.payload);
                                }
                            }
                            Kind::End => {
                                if let Some((open, body)) = models.remove(&frame.stream) {
                                    // On a share, the other Mac makes the calls: none is relayed from here.
                                    let Some(current) = login.as_mut() else {
                                        channel.send(Frame::new(frame.stream, Kind::Reset, b"not relayed on a share".to_vec())).await;
                                        continue;
                                    };
                                    // Not once the exchange is over or the job's minutes are up: the
                                    // other Mac can't keep spending this owner's account.
                                    let over = link.exchange(&cid).is_none_or(|e| e.ended())
                                        || accepted.elapsed() > Duration::from_secs(MAX_MINUTES * 60);
                                    if !current.lasts(300) {
                                        *current = Login::read(ask.config_dir).unwrap_or_else(|| current.clone());
                                    }
                                    let channel = channel.clone();
                                    let http = http.clone();
                                    let (upstream, token) = (upstream.clone(), current.access_token.clone());
                                    tokio::spawn(async move {
                                        if over {
                                            refuse(&channel, frame.stream, 403, "the job's time on that Mac is over").await;
                                        } else {
                                            relay(&channel, &http, &upstream, &token, frame.stream, &open, body).await;
                                        }
                                    });
                                } else if let Some((stream, data, want_sha, _)) = commits.take()
                                    && stream == frame.stream
                                    && sha_of(&data) == want_sha
                                    && std::fs::write(&commits_file, &data).is_ok()
                                {
                                    got_commits = Some(want_sha);
                                    channel.send(Frame::json(0, Kind::Data, &json!({"commits": "received"}))).await;
                                }
                            }
                            Kind::Reset => {
                                models.remove(&frame.stream);
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
        count = apply(worktree, &commits_file, ask.branch, base_sha).await?;
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
            Some("share_used") => format!(
                "your share of {}'s account is used for this month",
                ask.host_owner
            ),
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
        "share_used" => format!(
            "Your share of {host_owner}'s account is used for this month. Run it on your own account instead."
        ),
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

/// Takes the job's commits from the bundle into its worktree: only commits on top of where it
/// started, on the job's own branch.
async fn apply(worktree: &Path, bundle: &Path, branch: &str, base: &str) -> Result<usize, String> {
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
    if git(worktree, &["merge-base", "--is-ancestor", base, &head])
        .await
        .is_err()
    {
        return Err(
            "The commits that came back don't build on the job's code, so obid kept none of them."
                .into(),
        );
    }
    git(worktree, &["reset", "-q", "--hard", &head]).await?;
    let count = git(
        worktree,
        &["rev-list", "--count", &format!("{base}..{head}")],
    )
    .await?;
    Ok(count.parse().unwrap_or(0))
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
) {
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
        return;
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
            return;
        }
    };
    let headers: Vec<Value> = response
        .headers()
        .iter()
        .filter(|(n, _)| {
            !matches!(
                n.as_str(),
                "content-length" | "transfer-encoding" | "connection" | "set-cookie"
            )
        })
        .filter_map(|(n, v)| v.to_str().ok().map(|v| json!([n.as_str(), v])))
        .collect();
    channel.send(Frame::json(stream, Kind::Open, &json!({"type": "model_response", "status": response.status().as_u16(), "headers": headers}))).await;
    let mut response = response;
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) => {
                if !channel.send_data(stream, &chunk).await {
                    return;
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
                return;
            }
        }
    }
    channel
        .send(Frame::new(stream, Kind::End, Vec::new()))
        .await;
}

/// The transcript as it comes: its lines, read into the job's events.
struct Session {
    agent: String,
    stream: Option<u32>,
    partial: Vec<u8>,
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
            lines: 0,
            turn: Turn::default(),
            _worktree: worktree.to_owned(),
        }
    }

    fn read(&mut self, bytes: &[u8], on_event: &mut impl FnMut(AgentEvent)) {
        self.partial.extend_from_slice(bytes);
        while let Some(at) = self.partial.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.partial.drain(..=at).collect();
            self.lines += 1;
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
    fn each_agent_has_its_own_key_in_the_vault() {
        assert_eq!(key_name("claude"), "anthropic-api-key");
        assert_eq!(key_name("codex"), "openai-api-key");
    }
}
