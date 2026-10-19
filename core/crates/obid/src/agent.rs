//! What every agent adapter shares (what to run, obid's answer to a permission, what the agent did,
//! how a turn ended), and the Claude Code adapter: one turn of `claude -p --input-format
//! stream-json --output-format stream-json --verbose --permission-prompt-tool stdio`, in the job
//! sandbox (AGENTS.md, "Claude Code headless"). obid writes the user's message as one JSON line,
//! answers every permission prompt (`control_request` `can_use_tool`) itself, follows the agent's
//! steps, and closes stdin after the turn's `result` line, so the agent exits. Codex's app-server
//! adapter is `codex`, the Agent Client Protocol's (Cursor) `acp`.

use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::watch;

use crate::conn::Conn;
use crate::process;

/// The coding tools obid runs jobs on, each through its own adapter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tool {
    /// Claude Code, stream-json (this module).
    Claude,
    /// Codex, `codex app-server` (`crate::codex`).
    Codex,
    /// Cursor, `cursor-agent acp` (`crate::acp`).
    Cursor,
}

impl Tool {
    /// In the order routing tries them when a job names no tool.
    pub const ALL: [Tool; 3] = [Tool::Claude, Tool::Codex, Tool::Cursor];

    /// The id jobs, accounts and the configuration name it by: `claude`, `codex`, `cursor`.
    pub fn id(self) -> &'static str {
        match self {
            Tool::Claude => "claude",
            Tool::Codex => "codex",
            Tool::Cursor => "cursor",
        }
    }

    /// How reports say it.
    pub fn name(self) -> &'static str {
        match self {
            Tool::Claude => "Claude Code",
            Tool::Codex => "Codex",
            Tool::Cursor => "Cursor",
        }
    }

    pub fn from_id(id: &str) -> Option<Tool> {
        Tool::ALL.into_iter().find(|tool| tool.id() == id)
    }
}

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

/// obid's ruling on a permission prompt: an answer now, or one the owner gives later (the job's
/// mode asks them: `crate::permissions`), which the adapter waits for ([`Conn::settle`]).
#[derive(Debug)]
pub enum Ruling {
    Now(Answer),
    Ask(tokio::sync::oneshot::Receiver<Answer>),
}

impl From<Answer> for Ruling {
    fn from(answer: Answer) -> Ruling {
        Ruling::Now(answer)
    }
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
    /// Words as the agent writes them: Claude Code's partial messages
    /// (`--include-partial-messages`), which only a conversation's session asks for.
    Delta(String),
    /// A tool call, by its id, its tool's name and its input.
    Tool {
        id: String,
        name: String,
        input: Value,
    },
    /// The answer to the tool call `id` came back; `failed` when it was an error.
    ToolDone { id: String, failed: bool },
}

/// How a turn ended, for every adapter.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Turn {
    /// The turn's result, when it ended with one, in the shape of Claude Code's `result` line:
    /// `is_error`, `subtype`, `result` (the agent's last words), and `structured_output` when the
    /// agent gave one. Codex's and ACP's adapters make it from their own end of turn.
    pub result: Option<Value>,
    pub session: Option<String>,
    /// How the process ended: `exit status 0`, `killed by signal 9`.
    pub exit: String,
    /// The turn ran past its time and obid ended it.
    pub timed_out: bool,
    /// obid was told to stop it.
    pub stopped: bool,
    /// What the agent should hear at the start of its next prompt: what obid declined this turn
    /// and why, for a tool whose answer to a permission carries no words (ACP).
    pub notes: Vec<String>,
    /// obid ended the turn for something trying again won't mend (a conversation's Codex ran a
    /// command), and why.
    pub fatal: Option<String>,
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

/// A turn's result in the shape of Claude Code's `result` line: what the agent said last, and
/// whether the turn failed.
pub fn result(text: &str, failed: bool, session: Option<&str>) -> Value {
    json!({"type": "result", "subtype": if failed { "error_during_execution" } else { "success" },
           "is_error": failed, "result": text, "session_id": session})
}

/// The user message line for `text`.
pub fn user_message(text: &str) -> Value {
    json!({"type": "user", "message": {"role": "user", "content": text}})
}

/// How long the agent may take to close its output and exit by itself once its turn's `result`
/// came: Claude Code took 0.8 to 3.1 seconds, finishing the session file the next turn's
/// `--resume` reads. Then it's ended, as a stop ends it.
pub const AFTER_RESULT: Duration = Duration::from_secs(3);

/// Runs one turn: starts the agent, sends `prompt`, answers prompts with `decide`, reports with
/// `on_event`, closes stdin after the `result` line and lets the agent exit (`AFTER_RESULT`). Ends the
/// agent and everything it started when `stop` turns true or `limit` passes.
pub async fn run_turn(
    launch: Launch,
    prompt: &str,
    limit: Duration,
    stop: watch::Receiver<process::Signal>,
    decide: impl Fn(&str, &Value) -> Ruling,
    on_event: impl FnMut(Event),
) -> std::io::Result<Turn> {
    let conn = Conn::spawn(&launch, limit, stop, false).await?;
    Ok(turn_on(conn, prompt, decide, on_event, false).await.0)
}

/// [`run_turn`] on a Claude Code already running (`conn`). With `keep`, a turn that ends with its
/// `result` leaves the agent running, waiting on its stdin for the next message (stream-json
/// input takes one turn after another; `--max-turns` counts each on its own), and it comes back
/// with the turn: a conversation's next turn skips starting it (docs/fast-replies.md).
pub async fn turn_on(
    mut conn: Conn,
    prompt: &str,
    decide: impl Fn(&str, &Value) -> Ruling,
    mut on_event: impl FnMut(Event),
    keep: bool,
) -> (Turn, Option<Conn>) {
    conn.send(&user_message(prompt)).await;

    let mut turn = Turn::default();
    loop {
        let message = match conn.next().await {
            Ok(message) => message,
            Err(_) => break,
        };
        match message.get("type").and_then(Value::as_str) {
            Some("control_request") => {
                let request = &message["request"];
                let id = message.get("request_id").cloned().unwrap_or(Value::Null);
                if request.get("subtype").and_then(Value::as_str) != Some("can_use_tool") {
                    continue;
                }
                let tool = request
                    .get("tool_name")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let input = request.get("input").cloned().unwrap_or_else(|| json!({}));
                // The owner's answer may take a while: the turn's clock stands still meanwhile.
                let Ok(answer) = conn.settle(decide(tool, &input)).await else {
                    break;
                };
                let response = match answer {
                    Answer::Allow => json!({"behavior": "allow", "updatedInput": input}),
                    Answer::Deny(why) => {
                        on_event(Event::Denied(why.clone()));
                        json!({"behavior": "deny", "message": why})
                    }
                };
                conn.send(&json!({"type": "control_response",
                                  "response": {"subtype": "success", "request_id": id, "response": response}}))
                    .await;
            }
            Some("system") if message.get("subtype").and_then(Value::as_str) == Some("init") => {
                if let Some(session) = message.get("session_id").and_then(Value::as_str) {
                    turn.session = Some(session.to_owned());
                    on_event(Event::Session(session.to_owned()));
                }
            }
            Some("assistant") => {
                for block in message["message"]["content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    if block.get("type").and_then(Value::as_str) == Some("tool_use") {
                        let name = block.get("name").and_then(Value::as_str).unwrap_or("");
                        let input = block.get("input").cloned().unwrap_or(Value::Null);
                        on_event(Event::Step(step(name, &input)));
                        on_event(Event::Tool {
                            id: text_of(block, "id"),
                            name: name.to_owned(),
                            input,
                        });
                    }
                }
            }
            // A tool's answer, in the user message that hands it back to the model.
            Some("user") => {
                for block in message["message"]["content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
                {
                    on_event(Event::ToolDone {
                        id: text_of(block, "tool_use_id"),
                        failed: block.get("is_error").and_then(Value::as_bool) == Some(true),
                    });
                }
            }
            Some("stream_event") => {
                let event = &message["event"];
                if event["type"] == "content_block_delta"
                    && event["delta"]["type"] == "text_delta"
                    && let Some(text) = event["delta"]["text"].as_str()
                {
                    on_event(Event::Delta(text.to_owned()));
                }
            }
            Some("result") => {
                if let Some(session) = message.get("session_id").and_then(Value::as_str) {
                    turn.session.get_or_insert_with(|| session.to_owned());
                }
                turn.result = Some(message);
                // The turn is over: no more input (unless it's kept), and nothing more to read.
                if !keep {
                    conn.close_input();
                }
                break;
            }
            _ => {}
        }
    }
    turn.timed_out = conn.timed_out;
    turn.stopped = conn.stopped;
    if keep && turn.result.is_some() && !turn.timed_out && !turn.stopped {
        turn.exit = "still running".into();
        return (turn, Some(conn));
    }
    conn.close_input();
    // After its result the agent closes its output and exits by itself, within AFTER_RESULT.
    turn.exit = if turn.result.is_some() {
        let until = std::time::Instant::now() + AFTER_RESULT;
        conn.drain_within(AFTER_RESULT).await;
        conn.finish_within(until.saturating_duration_since(std::time::Instant::now()))
            .await
    } else {
        conn.finish().await
    };
    (turn, None)
}

fn text_of(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned()
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

    /// Runs one turn of a fake Claude Code that reads the prompt, prints its result, then runs
    /// `after`: the turn, how long it took, and the fake's folder.
    async fn fake_turn(name: &str, after: &str) -> (Turn, Duration, PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!("obid-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let bin = root.join("claude");
        std::fs::write(
            &bin,
            format!(
                "#!/bin/sh\nread line\necho '{{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"Done.\",\"session_id\":\"s1\"}}'\n{after}\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        let launch = Launch {
            argv: vec![bin.into_os_string()],
            env: vec![("PATH".into(), "/usr/bin:/bin".into())],
            cwd: root.clone(),
            stderr: root.join("agent.log"),
        };
        let (_stop, stop) = watch::channel(process::Signal::Run);
        let began = std::time::Instant::now();
        let turn = run_turn(
            launch,
            "Do it.",
            Duration::from_secs(60),
            stop,
            |_, _| Ruling::Now(Answer::Allow),
            |_| {},
        )
        .await
        .unwrap();
        (turn, began.elapsed(), root)
    }

    /// After its result Claude Code finishes its session file, which the next turn's `--resume`
    /// reads: obid lets it exit by itself (it took 0.8 to 3.1 seconds), never cutting it at once.
    #[tokio::test]
    async fn the_agent_finishes_its_session_before_the_turn_ends() {
        let (turn, took, root) = fake_turn("session-end", "sleep 1\necho end > session-end").await;
        assert!(turn.succeeded());
        assert_eq!(turn.text(), "Done.");
        assert!(root.join("session-end").exists(), "cut after {took:?}");
        assert!(took < AFTER_RESULT, "{took:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// One that never exits after its result ends a few seconds later, not at the round's limit.
    #[tokio::test]
    async fn an_agent_that_never_exits_ends_soon_after_its_result() {
        let (turn, took, root) = fake_turn("never-exits", "exec sleep 30").await;
        assert!(turn.succeeded());
        assert!(took < AFTER_RESULT + Duration::from_secs(2), "{took:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

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
