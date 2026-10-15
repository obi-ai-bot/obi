//! The Claude Code adapter: one turn of `claude -p --input-format stream-json --output-format
//! stream-json --verbose --permission-prompt-tool stdio`, in the job sandbox (AGENTS.md, "Claude
//! Code headless"). obid writes the user's message as one JSON line, answers every permission
//! prompt (`control_request` `can_use_tool`) itself, follows the agent's steps, and closes stdin
//! after the turn's `result` line, so the agent exits. Output is split on `\n` only: a JSON string
//! may hold U+2028.

use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::watch;

use crate::process;

/// What to run: the command line (already wrapped in the sandbox), its environment and working
/// directory, and where its stderr goes.
pub struct Launch {
    pub argv: Vec<OsString>,
    pub env: Vec<(OsString, OsString)>,
    pub cwd: PathBuf,
    pub stderr: PathBuf,
}

/// What obid answers a permission prompt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Answer {
    Allow,
    Deny(String),
}

/// What the agent did that the job shows as it goes.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// Its session id, from the `init` line.
    Session(String),
    /// What it is doing now, like `Reading greet.js`.
    Step(String),
    /// A permission obid refused, and why.
    Denied(String),
}

/// How a turn ended.
#[derive(Debug, Clone, PartialEq)]
pub struct Turn {
    /// The `result` line, when one came.
    pub result: Option<Value>,
    pub session: Option<String>,
    /// How the process ended: `exit status 0`, `killed by signal 9`.
    pub exit: String,
    /// The turn ran past its time and obid ended it.
    pub timed_out: bool,
    /// obid was told to stop it.
    pub stopped: bool,
}

impl Turn {
    /// The `result` line said the turn succeeded.
    pub fn succeeded(&self) -> bool {
        self.result.as_ref().is_some_and(|r| {
            r.get("is_error")
                .and_then(Value::as_bool)
                .map(|e| !e)
                .unwrap_or(r.get("subtype") == Some(&json!("success")))
        })
    }

    /// The agent's final text.
    pub fn text(&self) -> String {
        self.result
            .as_ref()
            .and_then(|r| r.get("result"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned()
    }
}

/// The user message line for `text`.
pub fn user_message(text: &str) -> Value {
    json!({"type": "user", "message": {"role": "user", "content": text}})
}

/// Runs one turn: starts the agent, sends `prompt`, answers prompts with `decide`, reports with
/// `on_event`, closes stdin after the `result` line and waits for the agent to exit. Ends the
/// agent and everything it started when `stop` turns true or `limit` passes.
pub async fn run_turn(
    launch: Launch,
    prompt: &str,
    limit: Duration,
    mut stop: watch::Receiver<process::Signal>,
    decide: impl Fn(&str, &Value) -> Answer,
    mut on_event: impl FnMut(Event),
) -> std::io::Result<Turn> {
    // The agent's stderr goes to obid, which writes it to the log: a file of obid's home would be
    // one the sandbox hides from the agent, and some tools refuse to start with such a stderr.
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
    let mut stdin = child.stdin.take();
    let copying = child.stderr.take().map(|mut stderr| {
        tokio::spawn(async move {
            let _ = tokio::io::copy(&mut stderr, &mut log).await;
        })
    });
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| std::io::Error::other("no stdout"))?;
    let mut lines = BufReader::new(stdout);

    let mut first = serde_json::to_vec(&user_message(prompt)).map_err(std::io::Error::other)?;
    first.push(b'\n');
    if let Some(input) = stdin.as_mut() {
        // An agent that exits before reading says so through its exit, below.
        let _ = input.write_all(&first).await;
        let _ = input.flush().await;
    }

    let mut turn = Turn {
        result: None,
        session: None,
        exit: String::new(),
        timed_out: false,
        stopped: false,
    };
    if *stop.borrow() != process::Signal::Run {
        turn.stopped = true;
    }
    let deadline = tokio::time::sleep(limit);
    tokio::pin!(deadline);
    let mut buffer = Vec::new();
    while !turn.stopped {
        buffer.clear();
        tokio::select! {
            read = lines.read_until(b'\n', &mut buffer) => {
                match read {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let Ok(message) = serde_json::from_slice::<Value>(&buffer) else { continue };
                match message.get("type").and_then(Value::as_str) {
                    Some("control_request") => {
                        let request = &message["request"];
                        let id = message.get("request_id").cloned().unwrap_or(Value::Null);
                        if request.get("subtype").and_then(Value::as_str) != Some("can_use_tool") {
                            continue;
                        }
                        let tool = request.get("tool_name").and_then(Value::as_str).unwrap_or("");
                        let input = request.get("input").cloned().unwrap_or_else(|| json!({}));
                        let response = match decide(tool, &input) {
                            Answer::Allow => json!({"behavior": "allow", "updatedInput": input}),
                            Answer::Deny(why) => {
                                on_event(Event::Denied(why.clone()));
                                json!({"behavior": "deny", "message": why})
                            }
                        };
                        let line = json!({"type": "control_response",
                                          "response": {"subtype": "success", "request_id": id, "response": response}});
                        if let Some(input) = stdin.as_mut() {
                            let mut bytes = serde_json::to_vec(&line).map_err(std::io::Error::other)?;
                            bytes.push(b'\n');
                            let _ = input.write_all(&bytes).await;
                            let _ = input.flush().await;
                        }
                    }
                    Some("system") if message.get("subtype").and_then(Value::as_str) == Some("init") => {
                        if let Some(session) = message.get("session_id").and_then(Value::as_str) {
                            turn.session = Some(session.to_owned());
                            on_event(Event::Session(session.to_owned()));
                        }
                    }
                    Some("assistant") => {
                        for block in message["message"]["content"].as_array().into_iter().flatten() {
                            if block.get("type").and_then(Value::as_str) == Some("tool_use") {
                                let name = block.get("name").and_then(Value::as_str).unwrap_or("");
                                on_event(Event::Step(step(name, block.get("input").unwrap_or(&Value::Null))));
                            }
                        }
                    }
                    Some("result") => {
                        if let Some(session) = message.get("session_id").and_then(Value::as_str) {
                            turn.session.get_or_insert_with(|| session.to_owned());
                        }
                        turn.result = Some(message);
                        // The turn is over: no more input, so the agent exits once it's idle.
                        drop(stdin.take());
                    }
                    _ => {}
                }
            }
            () = &mut deadline => {
                turn.timed_out = true;
                break;
            }
            changed = stop.changed() => {
                if changed.is_err() || *stop.borrow() != process::Signal::Run {
                    turn.stopped = true;
                    break;
                }
            }
        }
    }
    drop(stdin.take());
    if turn.timed_out || turn.stopped {
        process::end_group(pgid, process::STOPPING).await;
    }
    // The output ended: the agent is exiting. Give it a moment, then end what's left of its group.
    let status = match tokio::time::timeout(Duration::from_secs(10), child.wait()).await {
        Ok(status) => status.ok(),
        Err(_) => {
            process::end_group(pgid, process::STOPPING).await;
            child.wait().await.ok()
        }
    };
    process::signal_group(pgid, nix::sys::signal::Signal::SIGKILL);
    if let Some(copying) = copying {
        let _ = tokio::time::timeout(Duration::from_secs(5), copying).await;
    }
    turn.exit = status
        .map(process::describe)
        .unwrap_or_else(|| "ended".into());
    Ok(turn)
}

/// What a tool call says the agent is doing (Engine/Jobs.swift, `StreamJSON.step`).
pub fn step(tool: &str, input: &Value) -> String {
    let text = |key: &str| input.get(key).and_then(Value::as_str);
    let file = text("file_path").map(|p| p.rsplit('/').next().unwrap_or(p).to_owned());
    match tool {
        "Bash" => {
            let command = text("command")
                .unwrap_or("")
                .split('\n')
                .next()
                .unwrap_or("");
            if command.chars().count() <= 48 {
                format!("Running {command}")
            } else {
                text("description").map(str::to_owned).unwrap_or_else(|| {
                    format!("Running {}…", command.chars().take(47).collect::<String>())
                })
            }
        }
        "Read" => format!("Reading {}", file.as_deref().unwrap_or("a file")),
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => {
            format!("Editing {}", file.as_deref().unwrap_or("a file"))
        }
        "Grep" => format!("Searching for {}", text("pattern").unwrap_or("text")),
        "Glob" => format!("Looking for {}", text("pattern").unwrap_or("files")),
        "WebFetch" | "WebSearch" => "Reading the web".into(),
        "TodoWrite" => "Planning the work".into(),
        "Task" | "Agent" => text("description")
            .unwrap_or("Starting a helper")
            .to_owned(),
        _ => format!("Using {tool}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steps() {
        assert_eq!(
            step("Read", &json!({"file_path": "/w/src/greet.js"})),
            "Reading greet.js"
        );
        assert_eq!(
            step("Bash", &json!({"command": "node --test"})),
            "Running node --test"
        );
        assert_eq!(
            step("Glob", &json!({"pattern": "**/*.js"})),
            "Looking for **/*.js"
        );
        assert_eq!(step("Mystery", &json!({})), "Using Mystery");
    }
}
