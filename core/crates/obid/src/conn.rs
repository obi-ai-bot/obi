//! One agent process speaking newline-delimited JSON over its stdio, in its own process group: what
//! every adapter runs on (Claude Code's stream-json, Codex's app-server, ACP). obid writes lines to
//! its stdin and reads its stdout split on `\n` only (a JSON string may hold U+2028), sends its
//! stderr to the job's log, and ends it with everything it started. A turn has a time limit and a
//! stop signal: [`Conn::next`] returns [`Cut::TimedOut`] or [`Cut::Stopped`] when one comes first.

use std::process::Stdio;
use std::time::Duration;

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
    buffer: Vec<u8>,
    next_id: u64,
    /// Every message obid writes carries `"jsonrpc": "2.0"` (ACP does; Codex's app-server leaves
    /// it out, and Claude Code's stream-json isn't JSON-RPC).
    jsonrpc: bool,
    pub stopped: bool,
    pub timed_out: bool,
}

impl Conn {
    /// Starts `launch` with its own empty environment plus what it names, in a process group of its
    /// own. `limit` is how long the turn may take from now.
    pub async fn spawn(
        launch: &Launch,
        limit: Duration,
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
            .process_group(0)
            .kill_on_drop(true);
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
        Ok(Conn {
            child,
            pgid,
            stdin,
            lines: BufReader::new(stdout),
            copying,
            stop,
            give_up_at: Box::pin(tokio::time::sleep(limit)),
            buffer: Vec::new(),
            next_id: 0,
            jsonrpc,
            stopped,
            timed_out: false,
        })
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
                        Ok(_) => {}
                    }
                    if let Ok(message) = serde_json::from_slice::<Value>(&self.buffer) {
                        return Ok(message);
                    }
                }
                () = &mut self.give_up_at => {
                    self.timed_out = true;
                }
                changed = self.stop.changed() => {
                    if changed.is_err() || *self.stop.borrow() != process::Signal::Run {
                        self.stopped = true;
                    }
                }
            }
        }
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
        let _ = tokio::time::timeout(Duration::from_secs(10), async {
            while self.next().await.is_ok() {}
        })
        .await;
    }

    /// No more input: an agent that waits for it exits once it's idle.
    pub fn close_input(&mut self) {
        drop(self.stdin.take());
    }

    /// Ends the agent and waits for it: at once when the turn was stopped or ran out of time, else
    /// once it exits by itself (10 seconds at most). Everything left of its group goes too. Returns
    /// how it ended: `exit status 0`, `killed by signal 9`.
    pub async fn finish(mut self) -> String {
        self.close_input();
        if self.timed_out || self.stopped {
            process::end_group(self.pgid, process::STOPPING).await;
        }
        let status = match tokio::time::timeout(Duration::from_secs(10), self.child.wait()).await {
            Ok(status) => status.ok(),
            Err(_) => {
                process::end_group(self.pgid, process::STOPPING).await;
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
