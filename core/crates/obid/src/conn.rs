//! One agent process speaking newline-delimited JSON over its stdio, in its own process group: what
//! every adapter runs on (Claude Code's stream-json, Codex's app-server, ACP). obid writes lines to
//! its stdin and reads its stdout split on `\n` only (a JSON string may hold U+2028), sends its
//! stderr to the job's log, and ends it with everything it started. A turn has a time limit (a
//! [`Limit`]: at most so long, and, for a job's turn, no longer than so long without progress) and
//! a stop signal: [`Conn::next`] returns [`Cut::TimedOut`] or [`Cut::Stopped`] when one comes first.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime};

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout};
use tokio::sync::watch;

use crate::agent::Launch;
use crate::process;

/// Why a turn's messages ended before the turn did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cut {
    /// The agent closed its output: it exited, or is exiting.
    Closed,
    /// The turn ran past its time.
    TimedOut,
    /// obid was told to stop it.
    Stopped,
}

/// How many quiet windows in a row a change in the worktree, or a background task still running
/// (`Conn::holding`), alone stands for progress: a quiet build is, a loop touching a file or a
/// server that never ends isn't.
pub const FILE_WINDOWS: u32 = 4;

/// Something outside the agent the turn waits on (an Apple check on a Mac): while it says so, the
/// turn isn't quiet, as while it waits for the owner.
pub type Waiting = std::sync::Arc<dyn Fn() -> bool + Send + Sync>;

/// How long a turn may take: `most` at all, and, with `quiet`, no longer than that without a line
/// from the agent, a wait (`waiting`) or, for [`FILE_WINDOWS`] windows at most, a change in `watch`
/// (a job's worktree): a job runs as long as it makes progress (docs/runner-api.md, `limit`). A
/// plain `Duration` is a fixed limit.
#[derive(Clone)]
pub struct Limit {
    pub most: Duration,
    pub quiet: Option<Duration>,
    pub watch: Option<PathBuf>,
    pub waiting: Option<Waiting>,
}

impl From<Duration> for Limit {
    fn from(most: Duration) -> Limit {
        Limit {
            most,
            quiet: None,
            watch: None,
            waiting: None,
        }
    }
}

/// Something in `dir` (files, folders, its git folder too) changed after `since`, and not after
/// now (a file dated ahead is no progress): what the agent did without a word, like a quiet build
/// writing its output. Links aren't followed.
// ponytail: a full walk, once per quiet window and stopping at the first change; a file watcher if
// worktrees get too big for that.
pub fn changed_since(dir: &Path, since: SystemTime) -> bool {
    let now = SystemTime::now();
    let mut folders = vec![dir.to_path_buf()];
    while let Some(folder) = folders.pop() {
        let Ok(entries) = std::fs::read_dir(&folder) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            if meta.modified().is_ok_and(|m| m > since && m <= now) {
                return true;
            }
            if meta.is_dir() && !meta.file_type().is_symlink() {
                folders.push(entry.path());
            }
        }
    }
    false
}

/// A JSON-RPC error the agent answered with.
#[derive(Debug, Clone, PartialEq)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

/// A running agent and its stdio.
pub struct Conn {
    child: Child,
    pgid: u32,
    stdin: Option<ChildStdin>,
    lines: BufReader<ChildStdout>,
    copying: Option<tokio::task::JoinHandle<()>>,
    stop: watch::Receiver<process::Signal>,
    give_up_at: std::pin::Pin<Box<tokio::time::Sleep>>,
    /// When the turn is quiet for too long (`Limit::quiet`), and what else counts as progress.
    quiet: Option<Duration>,
    quiet_at: std::pin::Pin<Box<tokio::time::Sleep>>,
    watch: Option<PathBuf>,
    waiting: Option<Waiting>,
    /// The last sign of progress, and the quiet windows since the agent's last line that only a
    /// change in `watch` filled.
    heard_at: SystemTime,
    file_windows: u32,
    buffer: Vec<u8>,
    next_id: u64,
    /// Every message obid writes carries `"jsonrpc": "2.0"` (ACP does; Codex's app-server leaves
    /// it out, and Claude Code's stream-json isn't JSON-RPC).
    jsonrpc: bool,
    pub stopped: bool,
    pub timed_out: bool,
    /// It timed out for being quiet (`Limit::quiet`), not at its most.
    pub quiet_out: bool,
    /// The agent ended its turn and waits for a background task of its own that is still running
    /// (crate::agent): the task stands for progress as a change in `watch` does, for
    /// [`FILE_WINDOWS`] windows at most without a line (a server or a `--watch` never ends).
    pub holding: bool,
}

impl Conn {
    /// Starts `launch` with its own empty environment plus what it names, in a process group of its
    /// own. `limit` is how long the turn may take from now.
    pub async fn spawn(
        launch: &Launch,
        limit: impl Into<Limit>,
        stop: watch::Receiver<process::Signal>,
        jsonrpc: bool,
    ) -> std::io::Result<Conn> {
        // The agent's stderr goes to obid, which writes it to the log: a file of obid's home would
        // be one the sandbox hides from the agent, and some tools refuse to start with such a stderr.
        let mut log = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&launch.stderr)
            .await?;
        let (program, args) = launch
            .argv
            .split_first()
            .ok_or_else(|| std::io::Error::other("nothing to run"))?;
        let mut command = tokio::process::Command::new(program);
        command
            .args(args)
            .env_clear()
            .envs(launch.env.iter().map(|(k, v)| (k, v)))
            .current_dir(&launch.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        // No process group set here: the command line is the job sandbox's (`Sandbox::wrap`), whose
        // first program starts a session of its own, and so a process group whose id is the child's.
        let mut child = command.spawn()?;
        let pgid = child.id().unwrap_or(0);
        let stdin = child.stdin.take();
        let copying = child.stderr.take().map(|mut stderr| {
            tokio::spawn(async move {
                let _ = tokio::io::copy(&mut stderr, &mut log).await;
            })
        });
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| std::io::Error::other("no stdout"))?;
        let stopped = *stop.borrow() != process::Signal::Run;
        let limit = limit.into();
        Ok(Conn {
            child,
            pgid,
            stdin,
            lines: BufReader::new(stdout),
            copying,
            stop,
            give_up_at: Box::pin(tokio::time::sleep(limit.most)),
            quiet: limit.quiet,
            quiet_at: Box::pin(tokio::time::sleep(limit.quiet.unwrap_or(limit.most))),
            watch: limit.watch,
            waiting: limit.waiting,
            heard_at: SystemTime::now(),
            file_windows: 0,
            buffer: Vec::new(),
            next_id: 0,
            jsonrpc,
            stopped,
            timed_out: false,
            quiet_out: false,
            holding: false,
        })
    }

    /// The agent's process id.
    pub fn pid(&self) -> u32 {
        self.pgid
    }

    /// A running agent's next turn: `limit` from now, and `stop` its stop signal.
    pub fn renew(&mut self, limit: impl Into<Limit>, stop: watch::Receiver<process::Signal>) {
        let limit = limit.into();
        self.give_up_at
            .as_mut()
            .reset(tokio::time::Instant::now() + limit.most);
        self.quiet = limit.quiet;
        self.watch = limit.watch;
        self.waiting = limit.waiting;
        self.heard();
        self.stopped = *stop.borrow() != process::Signal::Run;
        self.stop = stop;
        self.timed_out = false;
        self.quiet_out = false;
        self.holding = false;
    }

    /// A sign of progress from the agent (or a wait): the quiet window starts again.
    fn heard(&mut self) {
        self.file_windows = 0;
        self.rearm();
    }

    /// The quiet window starts again.
    fn rearm(&mut self) {
        self.heard_at = SystemTime::now();
        if let Some(quiet) = self.quiet {
            self.quiet_at
                .as_mut()
                .reset(tokio::time::Instant::now() + quiet);
        }
    }

    /// Nothing waits to be read and the agent hasn't closed its output, which is how a running
    /// agent stays between turns: looked at without waiting. A line it wrote while idle would be
    /// taken for the next turn's.
    pub async fn quiet(&mut self) -> bool {
        self.lines.buffer().is_empty()
            && tokio::time::timeout(Duration::ZERO, self.lines.fill_buf())
                .await
                .is_err()
    }

    /// The next JSON message, or why none comes. Lines that aren't JSON are skipped.
    pub async fn next(&mut self) -> Result<Value, Cut> {
        loop {
            if self.stopped {
                return Err(Cut::Stopped);
            }
            if self.timed_out {
                return Err(Cut::TimedOut);
            }
            self.buffer.clear();
            tokio::select! {
                read = self.lines.read_until(b'\n', &mut self.buffer) => {
                    match read {
                        Ok(0) | Err(_) => return Err(Cut::Closed),
                        Ok(_) => self.heard(),
                    }
                    if let Ok(message) = serde_json::from_slice::<Value>(&self.buffer) {
                        return Ok(message);
                    }
                }
                () = &mut self.give_up_at => {
                    self.timed_out = true;
                }
                () = &mut self.quiet_at, if self.quiet.is_some() => {
                    let since = self.heard_at;
                    let changed = match self.watch.clone() {
                        Some(dir) if self.file_windows < FILE_WINDOWS => {
                            tokio::task::spawn_blocking(move || changed_since(&dir, since))
                                .await
                                .unwrap_or(false)
                        }
                        _ => false,
                    };
                    if self.waiting.as_ref().is_some_and(|waiting| waiting()) {
                        self.heard();
                    } else if changed || (self.holding && self.file_windows < FILE_WINDOWS) {
                        self.file_windows += 1;
                        self.rearm();
                    } else {
                        self.timed_out = true;
                        self.quiet_out = true;
                    }
                }
                changed = self.stop.changed() => {
                    if changed.is_err() || *self.stop.borrow() != process::Signal::Run {
                        self.stopped = true;
                    }
                }
            }
        }
    }

    /// The answer `ruling` comes to: now, or once the owner gives it. While obid waits for them the
    /// turn's clock stands still (its time limit moves on by the wait), and a stop ends the wait.
    /// A question nobody will answer any more (obid dropped it) is a no.
    pub async fn settle(
        &mut self,
        ruling: crate::agent::Ruling,
    ) -> Result<crate::agent::Answer, Cut> {
        use crate::agent::{Answer, Ruling};
        let mut asked = match ruling {
            Ruling::Now(answer) => return Ok(answer),
            Ruling::Ask(asked) => asked,
        };
        let deadline = self.give_up_at.deadline();
        let since = tokio::time::Instant::now();
        let answer = loop {
            if self.stopped {
                return Err(Cut::Stopped);
            }
            tokio::select! {
                answer = &mut asked => {
                    break answer.unwrap_or_else(|_| Answer::Deny(
                        "Nobody answered that: obid let the question go.".into(),
                    ));
                }
                changed = self.stop.changed() => {
                    if changed.is_err() || *self.stop.borrow() != process::Signal::Run {
                        self.stopped = true;
                    }
                }
            }
        };
        self.give_up_at.as_mut().reset(deadline + since.elapsed());
        // Waiting for the owner isn't being quiet.
        self.heard();
        Ok(answer)
    }

    /// Writes one message as a line. An agent that stopped reading says so through its exit.
    pub async fn send(&mut self, message: &Value) {
        let mut message = message.clone();
        if self.jsonrpc
            && let Some(object) = message.as_object_mut()
        {
            object.insert("jsonrpc".into(), json!("2.0"));
        }
        let Ok(mut bytes) = serde_json::to_vec(&message) else {
            return;
        };
        bytes.push(b'\n');
        if let Some(input) = self.stdin.as_mut() {
            let _ = input.write_all(&bytes).await;
            let _ = input.flush().await;
        }
    }

    /// Sends a request and returns its id; the answer comes back through [`Conn::next`].
    pub async fn request(&mut self, method: &str, params: Value) -> u64 {
        self.next_id += 1;
        let id = self.next_id;
        self.send(&json!({"id": id, "method": method, "params": params}))
            .await;
        id
    }

    /// A notification: nothing answers it.
    pub async fn notify(&mut self, method: &str, params: Option<Value>) {
        let message = match params {
            Some(params) => json!({"method": method, "params": params}),
            None => json!({"method": method}),
        };
        self.send(&message).await;
    }

    /// Answers the agent's own request `id`.
    pub async fn reply(&mut self, id: &Value, result: Value) {
        self.send(&json!({"id": id, "result": result})).await;
    }

    /// Refuses the agent's own request `id`, so it never waits on obid.
    pub async fn refuse(&mut self, id: &Value) {
        self.send(&json!({"id": id, "error": {"code": -32601, "message": "obid doesn't answer this request."}}))
            .await;
    }

    /// Reads what the agent still says until it closes its output, for 10 seconds at most: after
    /// its turn, with stdin closed, it is exiting.
    pub async fn drain(&mut self) {
        self.drain_within(Duration::from_secs(10)).await;
    }

    /// [`Conn::drain`], for `limit` at most.
    pub async fn drain_within(&mut self, limit: Duration) {
        let _ = tokio::time::timeout(limit, async { while self.next().await.is_ok() {} }).await;
    }

    /// No more input: an agent that waits for it exits once it's idle.
    pub fn close_input(&mut self) {
        drop(self.stdin.take());
    }

    /// Ends the agent and waits for it: at once when the turn was stopped or ran out of time, else
    /// once it exits by itself (10 seconds at most). Everything left of its group goes too. Returns
    /// how it ended: `exit status 0`, `killed by signal 9`.
    pub async fn finish(self) -> String {
        self.finish_within(Duration::from_secs(10)).await
    }

    /// [`Conn::finish`], with `wait` for the agent to exit by itself.
    pub async fn finish_within(mut self, wait: Duration) -> String {
        self.close_input();
        if self.timed_out || self.stopped {
            process::end_group(self.pgid, process::STOPPING).await;
        }
        let status = match tokio::time::timeout(wait, self.child.wait()).await {
            Ok(status) => status.ok(),
            Err(_) => {
                process::end_group(self.pgid, process::STOPPING).await;
                let _ = self.child.start_kill();
                self.child.wait().await.ok()
            }
        };
        process::signal_group(self.pgid, nix::sys::signal::Signal::SIGKILL);
        if let Some(copying) = self.copying.take() {
            let _ = tokio::time::timeout(Duration::from_secs(5), copying).await;
        }
        status
            .map(process::describe)
            .unwrap_or_else(|| "ended".into())
    }
}

/// The answer to request `id` in `message`, when it is one: its result, or the error it carries.
pub fn answer_to(message: &Value, id: u64) -> Option<Result<Value, RpcError>> {
    if message.get("method").is_some() || message.get("id").and_then(Value::as_u64) != Some(id) {
        return None;
    }
    Some(match message.get("error") {
        Some(error) if !error.is_null() => Err(RpcError {
            code: error.get("code").and_then(Value::as_i64).unwrap_or(0),
            message: error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("refused")
                .to_owned(),
        }),
        _ => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
    })
}

/// The agent's own request (it carries a method and an id): its id.
pub fn request_id(message: &Value) -> Option<&Value> {
    message.get("method")?;
    message.get("id").filter(|id| !id.is_null())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A file written in the folder, however deep, is progress; nothing written isn't.
    #[test]
    fn a_change_in_the_worktree_is_progress() {
        let dir = std::env::temp_dir().join(format!("obid-changed-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("target/debug")).unwrap();
        let since = SystemTime::now();
        assert!(!changed_since(&dir, since + Duration::from_secs(1)));
        std::thread::sleep(Duration::from_millis(20));
        let since = SystemTime::now();
        std::thread::sleep(Duration::from_millis(20));
        assert!(!changed_since(&dir, since));
        std::fs::write(dir.join("target/debug/out.o"), "x").unwrap();
        assert!(changed_since(&dir, since));
        // A file dated ahead (a `touch -d` loop) is no progress.
        let since = SystemTime::now() + Duration::from_secs(1);
        let ahead = std::fs::File::create(dir.join("ahead")).unwrap();
        ahead
            .set_modified(SystemTime::now() + Duration::from_secs(3600))
            .unwrap();
        assert!(!changed_since(&dir, since));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn answers_and_requests() {
        assert_eq!(
            answer_to(&json!({"id": 3, "result": {"a": 1}}), 3),
            Some(Ok(json!({"a": 1})))
        );
        assert_eq!(answer_to(&json!({"id": 4, "result": {}}), 3), None);
        assert_eq!(
            answer_to(&json!({"id": 3, "method": "x", "params": {}}), 3),
            None
        );
        assert_eq!(
            answer_to(
                &json!({"id": 3, "error": {"code": -32000, "message": "Authentication required"}}),
                3
            ),
            Some(Err(RpcError {
                code: -32000,
                message: "Authentication required".into()
            }))
        );
        assert_eq!(
            request_id(&json!({"id": "a", "method": "session/request_permission"})),
            Some(&json!("a"))
        );
        assert_eq!(request_id(&json!({"method": "session/update"})), None);
        assert_eq!(request_id(&json!({"id": 1, "result": {}})), None);
    }
}
