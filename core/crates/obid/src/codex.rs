//! The Codex adapter: one turn of `codex app-server`, JSON-RPC over stdio (AGENTS.md, "Codex";
//! Engine/Codex.swift is the behaviour it follows). obid sends `initialize` and `initialized`, then
//! `thread/start` (or `thread/resume` with the job's session), then `turn/start` with the round's
//! message; it answers every approval Codex asks for, follows the turn's items as steps, and once
//! `turn/completed` comes for its thread it closes stdin, so the server exits.
//!
//! obid's job sandbox is Codex's sandbox, on Linux and on macOS: Codex's own (bubblewrap, Seatbelt)
//! can't run inside another, so the thread runs `danger-full-access` with `approvalPolicy`
//! `untrusted`, and every command that isn't a known read, and every file change, comes to obid as
//! an approval (as the Swift runner does inside bubblewrap). In Plan mode obid declines file changes.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::watch;

use crate::agent::{self, Answer, Event, Launch, Ruling, Turn};
use crate::conn::{self, Conn, Cut, RpcError};
use crate::process;

/// What a turn needs besides its message.
#[derive(Debug, Clone, Default)]
pub struct Options {
    /// The thread to pick up again (the job's `session`), or `None` for a new one.
    pub resume: Option<String>,
    /// The job's own model, or `None` for Codex's.
    pub model: Option<String>,
    /// The job's own reasoning effort, or `None` for Codex's.
    pub effort: Option<String>,
    /// The job is in Plan mode: Codex reads and plans, and obid declines its file changes.
    pub plan: bool,
}

/// The `command` line `codex app-server` runs as: the binary, then `app-server`.
pub fn argv(bin: PathBuf, mcp: Option<(&str, &str)>) -> Vec<std::ffi::OsString> {
    let mut argv = vec![bin.into_os_string()];
    if let Some((url, _)) = mcp {
        argv.extend([
            "-c".into(),
            format!("mcp_servers.oby.url=\"{url}\"").into(),
            "-c".into(),
            "mcp_servers.oby.bearer_token_env_var=\"OBY_MCP_TOKEN\"".into(),
        ]);
    }
    argv.push("app-server".into());
    argv
}

/// Runs one turn: starts the server, sends `prompt`, answers approvals with `decide`, reports with
/// `on_event`, and ends the server once the turn completes. Ends it and everything it started when
/// `stop` turns or `limit` passes.
pub async fn run_turn(
    launch: Launch,
    prompt: &str,
    options: &Options,
    limit: Duration,
    stop: watch::Receiver<process::Signal>,
    decide: impl Fn(&str, &Value) -> Ruling,
    on_event: impl FnMut(Event),
) -> std::io::Result<Turn> {
    let conn = Conn::spawn(&launch, limit, stop, false).await?;
    let mut run = Run {
        conn,
        decide,
        on_event,
        worktree: launch.cwd.clone(),
        plan: options.plan,
        files: HashMap::new(),
        thread: None,
        turn: None,
        said: None,
        ended: None,
    };
    let mut turn = Turn::default();
    match run.turn(prompt, options).await {
        Ok(()) => {}
        Err(Stop::Cut(Cut::Stopped)) => {
            // Courtesy only: the group ends a moment later whatever Codex does with it.
            if let (Some(thread), Some(id)) = (run.thread.clone(), run.turn.clone()) {
                run.conn
                    .request("turn/interrupt", json!({"threadId": thread, "turnId": id}))
                    .await;
            }
        }
        Err(Stop::Cut(_)) => {}
        Err(Stop::Failed(why)) => {
            run.ended = Some((why, true));
        }
    }
    turn.session = run.thread.clone();
    if let Some((text, failed)) = &run.ended {
        turn.result = Some(agent::result(text, *failed, run.thread.as_deref()));
    }
    // The turn is over: no more input, so the server exits. Read what's left until it does.
    run.conn.close_input();
    if run.ended.is_some() {
        run.conn.drain().await;
    }
    turn.timed_out = run.conn.timed_out;
    turn.stopped = run.conn.stopped;
    turn.exit = run.conn.finish().await;
    Ok(turn)
}

/// Why a turn's steps stopped early.
enum Stop {
    Cut(Cut),
    /// Codex refused a step: the turn fails, saying why.
    Failed(String),
}

impl From<Cut> for Stop {
    fn from(cut: Cut) -> Stop {
        Stop::Cut(cut)
    }
}

struct Run<D, E> {
    conn: Conn,
    decide: D,
    on_event: E,
    worktree: PathBuf,
    plan: bool,
    /// The files each file change writes, by item id: an approval request names only the item.
    files: HashMap<String, Vec<String>>,
    thread: Option<String>,
    /// The turn under way.
    turn: Option<String>,
    /// The agent's last message this turn, from `item/completed`.
    said: Option<String>,
    /// The turn's end: what it said, and whether it failed.
    ended: Option<(String, bool)>,
}

impl<D: Fn(&str, &Value) -> Ruling, E: FnMut(Event)> Run<D, E> {
    async fn turn(&mut self, prompt: &str, options: &Options) -> Result<(), Stop> {
        let version = env!("CARGO_PKG_VERSION");
        self.call(
            "initialize",
            json!({"clientInfo": {"name": "obid", "title": "obid", "version": version}}),
        )
        .await?
        .map_err(|e| Stop::Failed(format!("Codex couldn't start: {}", e.message)))?;
        self.conn.notify("initialized", None).await;

        let cwd = self.worktree.to_string_lossy().into_owned();
        let mut params = thread_params(&cwd);
        let (method, what) = match &options.resume {
            Some(thread) => {
                params["threadId"] = json!(thread);
                ("thread/resume", "pick up its thread")
            }
            None => ("thread/start", "start a thread"),
        };
        let started = self
            .call(method, params)
            .await?
            .map_err(|e| Stop::Failed(format!("Codex couldn't {what}: {}", e.message)))?;
        let thread = started["thread"]["id"]
            .as_str()
            .ok_or_else(|| Stop::Failed("Codex didn't start a thread.".into()))?
            .to_owned();
        self.thread = Some(thread.clone());
        (self.on_event)(Event::Session(thread.clone()));

        let mut params = json!({"threadId": thread, "input": [text(prompt)]});
        if let Some(model) = options.model.as_deref().filter(|m| !m.is_empty()) {
            params["model"] = json!(model);
        }
        if let Some(effort) = options.effort.as_deref().filter(|e| !e.is_empty()) {
            params["effort"] = json!(effort);
        }
        let started = self
            .call("turn/start", params)
            .await?
            .map_err(|e| Stop::Failed(format!("Codex couldn't start the turn: {}", e.message)))?;
        if let Some(id) = started["turn"]["id"].as_str() {
            self.turn = Some(id.to_owned());
        }
        while self.ended.is_none() {
            let message = self.conn.next().await?;
            self.handle(message).await;
        }
        Ok(())
    }

    /// Sends a request and reads until its answer comes, handling everything else on the way.
    async fn call(&mut self, method: &str, params: Value) -> Result<Result<Value, RpcError>, Cut> {
        let id = self.conn.request(method, params).await;
        loop {
            let message = self.conn.next().await?;
            if let Some(answer) = conn::answer_to(&message, id) {
                return Ok(answer);
            }
            self.handle(message).await;
        }
    }

    async fn handle(&mut self, message: Value) {
        if let Some(id) = conn::request_id(&message).cloned() {
            return self.answer(id, &message).await;
        }
        if let Some((item, paths)) = changes(&message) {
            self.files.insert(item, paths);
        }
        let params = &message["params"];
        // Helpers Codex starts run in threads of their own: only this job's thread reports.
        if let (Some(other), Some(thread)) = (params["threadId"].as_str(), &self.thread)
            && other != thread
        {
            return;
        }
        match message["method"].as_str() {
            Some("item/started") => {
                if let Some(step) = step(&params["item"]) {
                    (self.on_event)(Event::Step(step));
                }
            }
            Some("item/completed") if params["item"]["type"] == "agentMessage" => {
                if let Some(said) = params["item"]["text"].as_str().filter(|s| !s.is_empty()) {
                    self.said = Some(said.to_owned());
                }
            }
            Some("turn/completed") => {
                self.ended = Some(finished(&params["turn"], self.said.as_deref()));
            }
            _ => {}
        }
    }

    /// obid's answer to an approval: the fixed denials, then the job's own rule. Anything else
    /// Codex asks (questions, forms, logins) is refused, so it never waits on obid.
    async fn answer(&mut self, id: Value, request: &Value) {
        let params = &request["params"];
        let calls: Vec<(String, Value)> = match request["method"].as_str() {
            Some("item/commandExecution/requestApproval") => match command_of(&params["command"]) {
                Some(command) => vec![("Bash".into(), json!({"command": unwrap_shell(&command)}))],
                None => {
                    return self
                        .decline(&id, params, "obid couldn't see the command.".into())
                        .await;
                }
            },
            Some("item/fileChange/requestApproval") => {
                let mut paths = params["itemId"]
                    .as_str()
                    .and_then(|item| self.files.get(item))
                    .cloned()
                    .unwrap_or_default();
                if paths.is_empty() {
                    return self
                        .decline(
                            &id,
                            params,
                            "obid couldn't see which files this change writes.".into(),
                        )
                        .await;
                }
                if self.plan {
                    return self.decline(&id, params, "This job is in Plan mode: read and plan, and change no file. End with your plan as your summary.".into()).await;
                }
                if let Some(root) = params["grantRoot"].as_str() {
                    paths.push(root.to_owned());
                }
                paths
                    .into_iter()
                    .map(|path| ("Edit".to_owned(), json!({"file_path": path})))
                    .collect()
            }
            _ => return self.conn.refuse(&id).await,
        };
        for (tool, input) in &calls {
            let ruling = (self.decide)(tool, input);
            match self.conn.settle(ruling).await {
                Ok(Answer::Allow) => {}
                Ok(Answer::Deny(why)) => return self.decline(&id, params, why).await,
                // Stopped while the owner was asked: the turn ends.
                Err(_) => return,
            }
        }
        self.conn.reply(&id, json!({"decision": "accept"})).await;
    }

    /// Declines, and since the decision has no room for a reason, tells the turn why.
    async fn decline(&mut self, id: &Value, params: &Value, why: String) {
        self.conn.reply(id, json!({"decision": "decline"})).await;
        (self.on_event)(Event::Denied(why.clone()));
        if let (Some(thread), Some(turn)) = (params["threadId"].as_str(), params["turnId"].as_str())
        {
            self.conn
                .request(
                    "turn/steer",
                    json!({"threadId": thread, "expectedTurnId": turn,
                           "input": [text(&format!("obid declined that: {why}"))]}),
                )
                .await;
        }
    }
}

/// The thread's settings: obid's sandbox is the sandbox, and every approval comes to obid.
fn thread_params(cwd: &str) -> Value {
    json!({"cwd": cwd, "sandbox": "danger-full-access", "approvalPolicy": "untrusted",
           "approvalsReviewer": "user"})
}

/// A text input item.
fn text(text: &str) -> Value {
    json!({"type": "text", "text": text, "text_elements": []})
}

/// A command as Codex sends it: a string, or its words.
fn command_of(value: &Value) -> Option<String> {
    match value {
        Value::String(command) => Some(command.clone()),
        Value::Array(words) => Some(
            words
                .iter()
                .map(|w| {
                    w.as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| w.to_string())
                })
                .collect::<Vec<_>>()
                .join(" "),
        ),
        _ => None,
    }
}

/// The command without the shell Codex wraps it in: `/bin/zsh -lc 'git status'` is `git status`.
pub fn unwrap_shell(command: &str) -> String {
    static WRAPPED: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let wrapped =
        WRAPPED.get_or_init(|| regex::Regex::new(r"(?s)^/\S+ -l?c '(.*)'$").expect("a regex"));
    match wrapped.captures(command) {
        Some(inner) => inner[1].replace("'\\''", "'"),
        None => command.to_owned(),
    }
}

/// The files a change writes: each change's `path`, and where a move goes.
fn files(change: &Value) -> Vec<String> {
    change["changes"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|c| [c["path"].as_str(), c["kind"]["move_path"].as_str()])
        .flatten()
        .map(str::to_owned)
        .collect()
}

/// The files a change writes, as its item started or as its patch was updated.
fn changes(message: &Value) -> Option<(String, Vec<String>)> {
    let params = &message["params"];
    match message["method"].as_str()? {
        "item/started" if params["item"]["type"] == "fileChange" => Some((
            params["item"]["id"].as_str()?.to_owned(),
            files(&params["item"]),
        )),
        "item/fileChange/patchUpdated" => {
            Some((params["itemId"].as_str()?.to_owned(), files(params)))
        }
        _ => None,
    }
}

/// What Codex is doing, in the same words as Claude Code's steps.
pub fn step(item: &Value) -> Option<String> {
    match item["type"].as_str()? {
        "commandExecution" => {
            if let Some([action]) = item["commandActions"].as_array().map(Vec::as_slice) {
                match action["type"].as_str() {
                    Some("read") => {
                        return Some(agent::step(
                            "Read",
                            &json!({"file_path": action["path"].as_str().unwrap_or("")}),
                        ));
                    }
                    Some("search") => {
                        let input = match action["query"].as_str() {
                            Some(query) => json!({"pattern": query}),
                            None => json!({}),
                        };
                        return Some(agent::step("Grep", &input));
                    }
                    Some("listFiles") => return Some(agent::step("Glob", &json!({}))),
                    _ => {}
                }
            }
            let command = command_of(&item["command"]).unwrap_or_default();
            Some(agent::step(
                "Bash",
                &json!({"command": unwrap_shell(&command)}),
            ))
        }
        "fileChange" => {
            let paths = files(item);
            Some(match paths.as_slice() {
                [one] => agent::step("Edit", &json!({"file_path": one})),
                many => format!("Editing {} files", many.len()),
            })
        }
        "mcpToolCall" => Some(agent::step(
            item["tool"].as_str().unwrap_or("a tool"),
            &json!({}),
        )),
        "webSearch" => Some(agent::step("WebSearch", &json!({}))),
        _ => None,
    }
}

/// How a turn ended: what the agent said last (from the turn's items, else its last message), and
/// whether it failed.
pub fn finished(turn: &Value, said: Option<&str>) -> (String, bool) {
    let status = turn["status"].as_str().unwrap_or("");
    let failed = status != "completed";
    let last = turn["items"]
        .as_array()
        .into_iter()
        .flatten()
        .rfind(|item| item["type"] == "agentMessage")
        .and_then(|item| item["text"].as_str())
        .filter(|text| !text.is_empty())
        .or(said.filter(|text| !text.is_empty()));
    if let Some(text) = last {
        return (text.to_owned(), failed);
    }
    if !failed {
        return ("Done.".into(), false);
    }
    if status == "interrupted" {
        return ("Stopped.".into(), true);
    }
    // The API's own error arrives as JSON inside the message.
    let message = turn["error"]["message"].as_str().unwrap_or("");
    let reason = serde_json::from_str::<Value>(message)
        .ok()
        .and_then(|api| api["error"]["message"].as_str().map(str::to_owned))
        .unwrap_or_else(|| message.to_owned());
    if reason.is_empty() {
        ("Codex hit an error.".into(), true)
    } else {
        (format!("Codex hit an error: {reason}"), true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ConnectionTests' last part: Codex finds the broker in its config and reads the job's token
    /// from a variable it names; the token is never an argument (other processes read those).
    #[test]
    fn codex_reaches_the_broker_with_the_token_out_of_its_arguments() {
        let url = "http://127.0.0.1:7777/v1/agent/mcp/job1";
        let token = "job-token-0123456789abcdef";
        let args: Vec<String> = argv(PathBuf::from("/bin/codex"), Some((url, token)))
            .into_iter()
            .map(|a| a.into_string().unwrap())
            .collect();
        assert_eq!(
            args,
            [
                "/bin/codex",
                "-c",
                r#"mcp_servers.oby.url="http://127.0.0.1:7777/v1/agent/mcp/job1""#,
                "-c",
                r#"mcp_servers.oby.bearer_token_env_var="OBY_MCP_TOKEN""#,
                "app-server"
            ]
        );
        assert!(!args.iter().any(|a| a.contains(token)));
        assert_eq!(
            argv(PathBuf::from("/bin/codex"), None),
            ["/bin/codex", "app-server"]
        );
    }

    #[test]
    fn the_shell_codex_wraps_commands_in_comes_off() {
        assert_eq!(unwrap_shell("/bin/zsh -lc 'git status'"), "git status");
        assert_eq!(
            unwrap_shell("/bin/bash -c 'echo '\\''hi'\\'''"),
            "echo 'hi'"
        );
        assert_eq!(unwrap_shell("node --test"), "node --test");
        assert_eq!(
            command_of(&json!(["git", "push", "origin"])).as_deref(),
            Some("git push origin")
        );
    }

    #[test]
    fn items_become_steps() {
        assert_eq!(
            step(&json!({"type": "commandExecution", "command": "/bin/zsh -lc 'node --test'"})),
            Some("Running node --test".into())
        );
        assert_eq!(
            step(&json!({"type": "commandExecution", "command": "cat a",
                         "commandActions": [{"type": "read", "path": "/w/src/greet.js"}]})),
            Some("Reading greet.js".into())
        );
        assert_eq!(
            step(&json!({"type": "fileChange", "changes": [{"path": "/w/a.js"}]})),
            Some("Editing a.js".into())
        );
        assert_eq!(
            step(&json!({"type": "fileChange", "changes": [{"path": "a"}, {"path": "b"}]})),
            Some("Editing 2 files".into())
        );
        assert_eq!(step(&json!({"type": "reasoning"})), None);
    }

    #[test]
    fn a_change_names_its_files_and_where_a_move_goes() {
        let started = json!({"method": "item/started", "params": {"item": {"type": "fileChange", "id": "i1",
            "changes": [{"path": "/w/a"}, {"path": "/w/b", "kind": {"type": "update", "move_path": "/w/c"}}]}}});
        assert_eq!(
            changes(&started),
            Some((
                "i1".into(),
                vec!["/w/a".into(), "/w/b".into(), "/w/c".into()]
            ))
        );
        let updated = json!({"method": "item/fileChange/patchUpdated", "params": {"itemId": "i1", "changes": [{"path": "/w/d"}]}});
        assert_eq!(changes(&updated), Some(("i1".into(), vec!["/w/d".into()])));
    }

    #[test]
    fn turns_end_with_what_the_agent_said() {
        assert_eq!(
            finished(
                &json!({"status": "completed", "items": [{"type": "agentMessage", "text": "Added a."}]}),
                None
            ),
            ("Added a.".into(), false)
        );
        assert_eq!(
            finished(
                &json!({"status": "completed", "items": []}),
                Some("From item/completed.")
            ),
            ("From item/completed.".into(), false)
        );
        assert_eq!(
            finished(&json!({"status": "completed"}), None),
            ("Done.".into(), false)
        );
        assert_eq!(
            finished(&json!({"status": "interrupted"}), None),
            ("Stopped.".into(), true)
        );
        assert_eq!(
            finished(
                &json!({"status": "failed", "error": {"message": "{\"error\": {\"message\": \"You've hit your usage limit.\"}}"}}),
                None
            ),
            (
                "Codex hit an error: You've hit your usage limit.".into(),
                true
            )
        );
    }
}
