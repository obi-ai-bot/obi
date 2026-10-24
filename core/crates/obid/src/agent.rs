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
    /// Allowed with this input in place of the agent's: the owner's answer to `AskUserQuestion`
    /// (#858), its input with `answers`. An adapter whose tool takes no new input allows it as is.
    AllowWith(Value),
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
    /// (`--include-partial-messages`), Codex's message deltas, ACP's message chunks.
    Delta(String),
    /// A tool call, by its id, its tool's name and its input.
    Tool {
        id: String,
        name: String,
        input: Value,
    },
    /// The answer to the tool call `id` came back; `failed` when it was an error. `exit` is a
    /// command's exit code, `lines` the lines a file change added and removed, `output` what it
    /// printed or answered, `patches` its file changes as unified diffs by path, when the tool says.
    /// Only a job's transcript keeps the output and patches, masked (crate::detail).
    ToolDone {
        id: String,
        failed: bool,
        exit: Option<i64>,
        lines: Option<(u64, u64)>,
        output: Option<String>,
        patches: Vec<(String, String)>,
    },
    /// The agent's words between tool calls, whole (a job's transcript).
    Said(String),
    /// Its thinking, or a summary of its reasoning, when the tool reports it, and how long it
    /// took when the tool says.
    Thought { text: String, seconds: Option<f64> },
    /// It began thinking (`ended` false) or stopped (`ended` true), when the tool says so but
    /// not what it thought: Claude Code's partial messages carry no thinking text, only that a
    /// thinking block started and stopped.
    Thinking { ended: bool },
    /// Its to-do list, whole, each time it changes (Codex's and Cursor's; Claude Code's are tool
    /// calls).
    Plan(Vec<crate::transcript::Todo>),
    /// The account's usage, as the tool just reported it (crate::usage).
    Usage(crate::usage::Usage),
    /// What this turn used so far, in tokens and cost (crate::usage::Tokens): each one replaces
    /// the turn's last.
    Tokens(crate::usage::Tokens),
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
    /// What timed it out was a quiet spell (`conn::Limit::quiet`): no progress for so long.
    pub quiet: bool,
    /// obid ended it for making the same failing call again and again (crate::jobs).
    pub looped: bool,
    /// obid ended it at the job's token budget (crate::jobs).
    pub over_budget: bool,
    /// obid was told to stop it.
    pub stopped: bool,
    /// What the agent should hear at the start of its next prompt: what obid declined this turn
    /// and why, for a tool whose answer to a permission carries no words (ACP).
    pub notes: Vec<String>,
    /// obid ended the turn for something trying again won't mend (a conversation's Codex ran a
    /// command), and why.
    pub fatal: Option<String>,
    /// When the account resets, in seconds since the epoch, if the tool said this turn it's full
    /// (crate::limits).
    pub resets: Option<i64>,
    /// The last words the agent wrote this turn: its `result` carries none when its last message
    /// was a tool call (#764).
    pub last_words: String,
    /// It ended with a background task of its own still running: it ended before the task did
    /// (Claude Code's; crate::jobs).
    pub left_running: bool,
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

    /// What the agent said last: [`Turn::text`], or when that has no words (its last message was
    /// a tool call), the last words it wrote this turn (#764). A conversation shows what it
    /// streamed instead.
    pub fn last_said(&self) -> String {
        let said = self.text();
        if said.trim().is_empty() {
            self.last_words.clone()
        } else {
            said
        }
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

/// Claude Code's answer to a `can_use_tool` prompt about `input`: an allow carries the input it
/// runs with, the agent's own or the one obid gives (an `AskUserQuestion` with its `answers`).
fn permission_response(answer: Answer, input: Value) -> Value {
    match answer {
        Answer::Allow => json!({"behavior": "allow", "updatedInput": input}),
        Answer::AllowWith(updated) => json!({"behavior": "allow", "updatedInput": updated}),
        Answer::Deny(why) => json!({"behavior": "deny", "message": why}),
    }
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
    limit: impl Into<crate::conn::Limit>,
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
/// with the turn: a conversation's next turn skips starting it (docs/fast-replies.md). A `result`
/// while a background task of the agent's still runs isn't the turn's end: it waits for the turn
/// Claude Code starts by itself when the task ends, the task standing for progress meanwhile as a
/// change in the worktree does ([`Conn::holding`]), and the turn's `result` is that one's.
pub async fn turn_on(
    mut conn: Conn,
    prompt: &str,
    decide: impl Fn(&str, &Value) -> Ruling,
    mut on_event: impl FnMut(Event),
    keep: bool,
) -> (Turn, Option<Conn>) {
    conn.send(&user_message(prompt)).await;

    let mut turn = Turn::default();
    let mut api_key_source = None;
    // What each of its background tasks still running does (Bash's `run_in_background`,
    // Monitor), as Claude Code's last `background_tasks_changed` listed them.
    let mut background: Vec<String> = Vec::new();
    // Its turn ended with some of them still running: it waits for them.
    let mut idle = false;
    // The partial message's thinking block, by its index, while it's open.
    let mut thinking: Option<u64> = None;
    loop {
        conn.holding = idle && !background.is_empty();
        let message = match conn.next().await {
            Ok(message) => message,
            Err(_) => break,
        };
        if message["type"] == "rate_limit_event" {
            on_event(Event::Usage(crate::usage::claude(&message)));
        }
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
                if let Answer::Deny(why) = &answer {
                    on_event(Event::Denied(why.clone()));
                }
                let response = permission_response(answer, input);
                conn.send(&json!({"type": "control_response",
                                  "response": {"subtype": "success", "request_id": id, "response": response}}))
                    .await;
            }
            // The whole list each time it changes. Its housekeeping (`ambient`) and the tasks it
            // waits for in the turn itself (`awaited`) wake nothing after it.
            Some("system")
                if message.get("subtype").and_then(Value::as_str)
                    == Some("background_tasks_changed") =>
            {
                background = message["tasks"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|t| t["ambient"] != true && t["awaited"] != true)
                    .map(|t| text_of(t, "description"))
                    .collect();
            }
            Some("system") if message.get("subtype").and_then(Value::as_str) == Some("init") => {
                idle = false;
                if let Some(session) = message.get("session_id").and_then(Value::as_str) {
                    turn.session = Some(session.to_owned());
                    on_event(Event::Session(session.to_owned()));
                }
                api_key_source = message["apiKeySource"].as_str().map(str::to_owned);
            }
            Some("assistant") => {
                // A subagent's (Task's) messages carry the tool call they answer: their words are
                // never the agent's own last ones.
                let own = message.get("parent_tool_use_id").is_none_or(Value::is_null);
                for block in message["message"]["content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    if block.get("type").and_then(Value::as_str) == Some("text") {
                        let text = text_of(block, "text");
                        if own && !text.trim().is_empty() {
                            turn.last_words = text.clone();
                        }
                        on_event(Event::Said(text));
                    }
                    if block.get("type").and_then(Value::as_str) == Some("thinking") {
                        let text = text_of(block, "thinking");
                        if !text.trim().is_empty() {
                            on_event(Event::Thought {
                                text,
                                seconds: None,
                            });
                        }
                    }
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
                    let failed = block.get("is_error").and_then(Value::as_bool) == Some(true);
                    let output = result_text(&block["content"]);
                    // Claude Code's Bash says a command's exit code in its answer: "Exit code 1".
                    let exit = output
                        .lines()
                        .take(3)
                        .find_map(|l| l.split("Exit code ").nth(1))
                        .and_then(|rest| rest.split(|c: char| !c.is_ascii_digit()).next())
                        .and_then(|n| n.parse().ok())
                        .filter(|_| failed);
                    // An edit's answer carries its hunks (never the file it read: originalFile).
                    let result = &message["tool_use_result"];
                    let patches = match (
                        result["filePath"].as_str(),
                        result["structuredPatch"].as_array(),
                    ) {
                        (Some(path), Some(hunks)) if !hunks.is_empty() => {
                            vec![(path.to_owned(), crate::detail::structured(path, hunks))]
                        }
                        _ => vec![],
                    };
                    on_event(Event::ToolDone {
                        id: text_of(block, "tool_use_id"),
                        failed,
                        exit,
                        lines: None,
                        output: Some(output),
                        patches,
                    });
                }
            }
            Some("stream_event") => {
                let event = &message["event"];
                if event["type"] == "content_block_start"
                    && event["content_block"]["type"] == "thinking"
                {
                    thinking = event["index"].as_u64();
                    on_event(Event::Thinking { ended: false });
                } else if event["type"] == "content_block_stop"
                    && thinking.is_some()
                    && event["index"].as_u64() == thinking
                {
                    thinking = None;
                    on_event(Event::Thinking { ended: true });
                } else if event["type"] == "content_block_delta"
                    && event["delta"]["type"] == "text_delta"
                    && let Some(text) = event["delta"]["text"].as_str()
                {
                    on_event(Event::Delta(text.to_owned()));
                }
            }
            Some("rate_limit_event") => {
                if let Some(at) = crate::limits::claude_full_until(&message) {
                    turn.resets = Some(at);
                }
            }
            Some("result") => {
                if let Some(session) = message.get("session_id").and_then(Value::as_str) {
                    turn.session.get_or_insert_with(|| session.to_owned());
                }
                on_event(Event::Tokens(crate::usage::claude_tokens(
                    &message,
                    api_key_source.as_deref(),
                )));
                turn.result = Some(message);
                // Headless Claude Code wakes itself when a background task ends, as it does in a
                // terminal (claude 2.1.302, 2026-10-20): with its input still open, a
                // `task_notification` and then a turn of its own, `init` to `result`. So a turn
                // that ends waiting on one isn't the end: the agent goes on when it's done.
                if let Some(what) = background.last() {
                    idle = true;
                    on_event(Event::Step(if what.is_empty() {
                        "Waiting for a background task".into()
                    } else {
                        format!("Waiting for {what}")
                    }));
                    continue;
                }
                // The turn is over: no more input (unless it's kept), and nothing more to read.
                if !keep {
                    conn.close_input();
                }
                break;
            }
            _ => {}
        }
    }
    turn.left_running = !background.is_empty();
    turn.timed_out = conn.timed_out;
    turn.quiet = conn.quiet_out;
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

/// A `tool_result`'s content as text: a string, or its text blocks one after the other.
fn result_text(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|b| b["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
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
        let done = r#"{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"s1"}"#;
        fake_turn_saying(name, &[done], after).await
    }

    /// As [`fake_turn`], with the fake printing `lines` (JSON, without a `'`) after the prompt.
    async fn fake_turn_saying(
        name: &str,
        lines: &[&str],
        after: &str,
    ) -> (Turn, Duration, PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!("obid-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let bin = root.join("claude");
        std::fs::write(
            &bin,
            format!(
                "#!/bin/sh\nread line\n{}\n{after}\n",
                lines
                    .iter()
                    .map(|l| format!("echo '{l}'"))
                    .collect::<Vec<_>>()
                    .join("\n")
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

    /// A turn whose last message was a tool call has a `result` with no words: its text is the
    /// last words the agent wrote (#764), never a subagent's.
    #[tokio::test]
    async fn a_result_with_no_words_keeps_the_last_ones_written() {
        let (turn, _, root) = fake_turn_saying(
            "last-words",
            &[
                r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed it; the tests pass."}]}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"text","text":" "},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"a"}}]}}"#,
                r#"{"type":"assistant","parent_tool_use_id":"t0","message":{"content":[{"type":"text","text":"A subagent wrote this."}]}}"#,
                r#"{"type":"result","subtype":"success","is_error":false,"result":"","session_id":"s1"}"#,
            ],
            "",
        )
        .await;
        assert!(turn.succeeded());
        assert_eq!(turn.text(), "");
        assert_eq!(turn.last_said(), "Fixed it; the tests pass.");
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

    /// #858: the owner's answer to `AskUserQuestion` reaches Claude Code as the input it runs
    /// with; a plain allow keeps the agent's own, a deny says why.
    #[test]
    fn an_answer_carries_the_input_it_runs_with() {
        let input = json!({"questions": [{"question": "Which?", "options": [{"label": "A"}]}]});
        let answered = json!({"questions": input["questions"], "answers": {"Which?": "A"}});
        assert_eq!(
            permission_response(Answer::AllowWith(answered.clone()), input.clone()),
            json!({"behavior": "allow", "updatedInput": answered})
        );
        assert_eq!(
            permission_response(Answer::Allow, input.clone()),
            json!({"behavior": "allow", "updatedInput": input})
        );
        assert_eq!(
            permission_response(Answer::Deny("no".into()), input),
            json!({"behavior": "deny", "message": "no"})
        );
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
