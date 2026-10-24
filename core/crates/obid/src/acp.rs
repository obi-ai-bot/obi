//! The Agent Client Protocol adapter: one turn of an ACP agent, newline-delimited JSON-RPC 2.0 over
//! stdio (https://agentclientprotocol.com; Engine/ACP.swift and docs/cursor.md are the behaviour it
//! follows). Cursor (`cursor-agent --sandbox disabled acp`) is the tool obid runs through it.
//!
//! obid sends `initialize` (no `fs`, no `terminal`: the agent reads and runs commands itself, and
//! asks), then `session/load` with the job's session when the agent can load one, else
//! `session/new`, sets the job's model and mode through the session's options, and sends the
//! round's message as `session/prompt`. It answers every request the agent waits on: permissions
//! (`allow_once`, never `allow_always`, which would let later calls past obid), Cursor's plan
//! (`cursor/create_plan`, as Claude Code's `ExitPlanMode`) and question (`cursor/ask_question`,
//! skipped); anything else is refused. The prompt's answer ends the turn, and stdin closes.
//!
//! A permission's answer carries no words, so what obid declined and why goes in the turn's
//! `notes`, which the next prompt starts with.

use std::collections::HashMap;

use serde_json::{Value, json};
use tokio::sync::watch;

use crate::agent::{self, Answer, Event, Launch, Ruling, Turn};
use crate::conn::{self, Conn, Cut, RpcError};
use crate::process;

/// What a turn needs besides its message.
#[derive(Debug, Clone, Default)]
pub struct Options {
    /// How reports name the tool: "Cursor".
    pub tool: String,
    /// The account's name, for "Cursor · Work is signed out".
    pub account: String,
    /// The session to pick up again (the job's `session`), or `None` for a new one.
    pub resume: Option<String>,
    /// The job's own model, or `None` for the tool's.
    pub model: Option<String>,
    /// The job is in Plan mode: the tool's plan mode, else its agent mode.
    pub plan: bool,
    /// The tool's mode ids for Plan and for everything else.
    pub plan_mode: String,
    pub agent_mode: String,
    /// The MCP servers `session/new` (or `session/load`) gives it, when it takes HTTP ones: Oby's
    /// Tetrix server only (crate::tetrix).
    pub mcp: Vec<Value>,
}

/// Runs one turn: starts the agent, sends `prompt`, answers its requests with `decide`, reports with
/// `on_event`, and ends it once the prompt is answered. Ends it and everything it started when
/// `stop` turns or `limit` passes.
pub async fn run_turn(
    launch: Launch,
    prompt: &str,
    options: &Options,
    limit: impl Into<crate::conn::Limit>,
    stop: watch::Receiver<process::Signal>,
    decide: impl Fn(&str, &Value) -> Ruling,
    on_event: impl FnMut(Event),
) -> std::io::Result<Turn> {
    let conn = Conn::spawn(&launch, limit, stop, true).await?;
    let mut run = Run {
        conn,
        decide,
        on_event,
        options: options.clone(),
        cwd: launch.cwd.to_string_lossy().into_owned(),
        session: None,
        found: Found::default(),
        applied: None,
        tools: HashMap::new(),
        current: String::new(),
        before: String::new(),
        thinking: String::new(),
        notes: Vec::new(),
        plan_approved: false,
        tokens: crate::usage::Tokens::default(),
    };
    let mut turn = Turn::default();
    let ended = match run.turn(prompt).await {
        Ok(ended) => Some(ended),
        Err(Stop::Cut(Cut::Stopped)) => {
            if let Some(session) = run.session.clone() {
                run.conn
                    .notify("session/cancel", Some(json!({"sessionId": session})))
                    .await;
            }
            None
        }
        Err(Stop::Cut(_)) => None,
        Err(Stop::Failed(why)) => Some((why, true)),
    };
    turn.session = run.session.clone();
    if let Some((text, failed)) = &ended {
        turn.result = Some(agent::result(text, *failed, run.session.as_deref()));
    }
    turn.notes = std::mem::take(&mut run.notes);
    run.conn.close_input();
    if ended.is_some() {
        run.conn.drain().await;
    }
    turn.timed_out = run.conn.timed_out;
    turn.quiet = run.conn.quiet_out;
    turn.stopped = run.conn.stopped;
    turn.exit = run.conn.finish().await;
    Ok(turn)
}

/// Why a turn's steps stopped early.
enum Stop {
    Cut(Cut),
    /// The turn fails, saying why.
    Failed(String),
}

impl From<Cut> for Stop {
    fn from(cut: Cut) -> Stop {
        Stop::Cut(cut)
    }
}

/// What `session/new` or `session/load` answered, as obid needs it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Found {
    pub id: Option<String>,
    /// Mode ids the tool offers (`modes.availableModes`, or the `mode` config option's values).
    pub modes: Vec<String>,
    pub current_mode: Option<String>,
    /// The config option that sets the mode (category `mode`), when the tool has one.
    pub mode_option: Option<String>,
    /// The config option that sets the model (category `model`), its current value and values.
    pub model_option: Option<String>,
    pub model: Option<String>,
    pub models: Vec<String>,
}

/// Reads a session's answer.
pub fn found(result: &Value) -> Found {
    let mut found = Found {
        id: result["sessionId"].as_str().map(str::to_owned),
        ..Found::default()
    };
    if let Some(modes) = result.get("modes").filter(|m| m.is_object()) {
        found.modes = modes["availableModes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|m| m["id"].as_str().map(str::to_owned))
            .collect();
        found.current_mode = modes["currentModeId"].as_str().map(str::to_owned);
    }
    for option in result["configOptions"].as_array().into_iter().flatten() {
        let Some(id) = option["id"].as_str() else {
            continue;
        };
        // Values come flat, or in groups of their own.
        let values: Vec<String> = option["options"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|entry| match entry["value"].as_str() {
                Some(value) => vec![value.to_owned()],
                None => entry["options"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|o| o["value"].as_str().map(str::to_owned))
                    .collect(),
            })
            .collect();
        let current = option["currentValue"].as_str().map(str::to_owned);
        match option["category"].as_str() {
            Some("mode") => {
                found.mode_option = Some(id.to_owned());
                found.modes = values;
                found.current_mode = current;
            }
            Some("model") => {
                found.model_option = Some(id.to_owned());
                found.models = values;
                found.model = current;
            }
            _ => {}
        }
    }
    found
}

/// The `model` option's value for the model the job names: the value itself, or the first that
/// starts with it and its parameters (`gpt-5.6-luna[context=272k,…]`), its current value first.
/// `None` for `auto` (the tool picks) and for a model the option doesn't offer.
pub fn model_value(model: &str, values: &[String], current: Option<&str>) -> Option<String> {
    if model.is_empty() || model == "auto" {
        return None;
    }
    if values.iter().any(|v| v == model) {
        return Some(model.to_owned());
    }
    let prefix = format!("{model}[");
    let variants: Vec<&String> = values.iter().filter(|v| v.starts_with(&prefix)).collect();
    if let Some(current) = current
        && variants.iter().any(|v| *v == current)
    {
        return Some(current.to_owned());
    }
    variants.first().map(|v| (*v).clone())
}

/// A tool call the agent reported (`tool_call`, then `tool_call_update`s), kept by its id: a
/// permission request names the call, and what it needs (the command, the files) came earlier.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ToolCall {
    pub kind: Option<String>,
    pub title: Option<String>,
    pub command: Option<String>,
    pub url: Option<String>,
    pub pattern: Option<String>,
    pub paths: Vec<String>,
    pub background: bool,
    /// The step last said for it, so an update that changes nothing says nothing.
    said: Option<String>,
}

impl ToolCall {
    /// Takes in the fields of a `tool_call`, a `tool_call_update` or a request's own `toolCall`.
    pub fn merge(&mut self, fields: &Value) {
        if let Some(kind) = fields["kind"].as_str() {
            self.kind = Some(kind.to_owned());
        }
        if let Some(title) = fields["title"].as_str().filter(|t| !t.is_empty()) {
            self.title = Some(title.to_owned());
        }
        let input = &fields["rawInput"];
        match &input["command"] {
            Value::String(command) => self.command = Some(command.clone()),
            Value::Array(words) => {
                self.command = Some(
                    words
                        .iter()
                        .map(|w| {
                            w.as_str()
                                .map(str::to_owned)
                                .unwrap_or_else(|| w.to_string())
                        })
                        .collect::<Vec<_>>()
                        .join(" "),
                )
            }
            _ => {}
        }
        if let Some(url) = input["url"].as_str() {
            self.url = Some(url.to_owned());
        }
        if let Some(pattern) = input["pattern"].as_str().or(input["query"].as_str()) {
            self.pattern = Some(pattern.to_owned());
        }
        if input["run_in_background"] == json!(true) {
            self.background = true;
        }
        let located = fields["locations"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|l| l["path"].as_str());
        let diffs = fields["content"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|b| b["type"] == "diff")
            .filter_map(|b| b["path"].as_str());
        for path in located.chain(diffs) {
            if !self.paths.iter().any(|p| p == path) {
                self.paths.push(path.to_owned());
            }
        }
    }

    /// What it is doing, in the same words as Claude Code's steps.
    pub fn step(&self) -> String {
        let title = self.title.as_deref().filter(|t| !t.is_empty());
        let first = |key: &str| match self.paths.first() {
            Some(path) => json!({ key: path }),
            None => json!({}),
        };
        match self.kind.as_deref() {
            Some("execute") => agent::step(
                "Bash",
                &json!({"command": self.command.as_deref().or(title).unwrap_or("")}),
            ),
            Some("read") => agent::step("Read", &first("file_path")),
            Some("search") => match &self.pattern {
                Some(pattern) => agent::step("Grep", &json!({ "pattern": pattern })),
                None => title.unwrap_or("Searching").to_owned(),
            },
            Some("edit" | "move") => agent::step("Edit", &first("file_path")),
            Some("delete") => match self.paths.first() {
                Some(path) => format!("Deleting {}", path.rsplit('/').next().unwrap_or(path)),
                None => title.unwrap_or("Deleting a file").to_owned(),
            },
            Some("fetch") => agent::step("WebFetch", &json!({})),
            Some("think") => title.unwrap_or("Thinking").to_owned(),
            _ => title.unwrap_or("Using a tool").to_owned(),
        }
    }

    /// The calls obid's policy decides on: `execute` is `Bash`, file changes `Edit` (one per
    /// file), reads and searches `Read`, fetches `WebFetch`, a title shaped as an MCP tool that
    /// tool. Anything else is `None`: obid doesn't know what it does.
    pub fn calls(&self) -> Option<Vec<(String, Value)>> {
        let title = self.title.as_deref().unwrap_or("");
        if let Some(mcp) = mcp_name(title) {
            return Some(vec![(mcp, json!({}))]);
        }
        let per_path = |tool: &str| -> Vec<(String, Value)> {
            self.paths
                .iter()
                .map(|p| (tool.to_owned(), json!({ "file_path": p })))
                .collect()
        };
        match self.kind.as_deref()? {
            // Without its command, the title stands in for obid's fixed rules (a publish is still
            // refused), and Sandbox mode asks (`seen`: false, docs/runner-api.md #586).
            "execute" => Some(vec![(
                "Bash".into(),
                json!({"command": self.command.as_deref().unwrap_or(title),
                       "run_in_background": self.background,
                       "seen": self.command.is_some()}),
            )]),
            "edit" | "delete" | "move" => Some(per_path("Edit")),
            "read" | "search" => {
                let calls = per_path("Read");
                Some(if calls.is_empty() {
                    vec![("Read".into(), json!({}))]
                } else {
                    calls
                })
            }
            "fetch" => Some(vec![("WebFetch".into(), json!({"url": self.url}))]),
            _ => None,
        }
    }
}

impl ToolCall {
    /// The Claude Code tool call it is, for a job's transcript, by its `kind` only: never by its
    /// title, which the agent writes. A kind obid doesn't know is `Tool`.
    fn named(&self) -> (String, Value) {
        let path = json!({"file_path": self.paths.first()});
        match self.kind.as_deref() {
            Some("execute") => ("Bash".into(), json!({"command": self.command})),
            Some("read") => ("Read".into(), path),
            Some("search") => ("Grep".into(), json!({"pattern": self.pattern})),
            Some("edit" | "delete" | "move") => ("Edit".into(), path),
            Some("fetch") => ("WebFetch".into(), json!({"url": self.url})),
            _ => ("Tool".into(), json!({})),
        }
    }
}

/// What an update's text content says (a call's output), when it has any.
fn output_of(content: &Value) -> Option<String> {
    let texts: Vec<&str> = content
        .as_array()?
        .iter()
        .filter(|b| b["type"] == "content")
        .filter_map(|b| b["content"]["text"].as_str())
        .collect();
    (!texts.is_empty()).then(|| texts.join("\n"))
}

/// An update's diffs as unified diffs, by path.
fn patches(content: &Value) -> Vec<(String, String)> {
    content
        .as_array()
        .into_iter()
        .flatten()
        .filter(|b| b["type"] == "diff")
        .map(|b| {
            let path = b["path"].as_str().unwrap_or("").to_owned();
            let patch = crate::detail::replaced(
                &path,
                b["oldText"].as_str().unwrap_or(""),
                b["newText"].as_str().unwrap_or(""),
            );
            (path, patch)
        })
        .collect()
}

/// The lines an update's diffs add and remove, when it has any.
fn diff_lines(content: &Value) -> Option<(u64, u64)> {
    let count = |v: &Value| v.as_str().map_or(0, |s| s.lines().count() as u64);
    content
        .as_array()?
        .iter()
        .filter(|b| b["type"] == "diff")
        .map(|b| (count(&b["newText"]), count(&b["oldText"])))
        .reduce(|(a, r), (a2, r2)| (a + a2, r + r2))
}

/// A to-do list as ACP's `plan` entries or Cursor's todos say it.
fn todos(list: &Value) -> Vec<crate::transcript::Todo> {
    list.as_array()
        .into_iter()
        .flatten()
        .map(|t| crate::transcript::Todo {
            text: t["content"].as_str().unwrap_or("").to_owned(),
            state: crate::transcript::todo_state(t["status"].as_str().unwrap_or("")).into(),
        })
        .collect()
}

/// `mcp__tetrix__get_entity`, `mcp:tetrix:get_entity` or `mcp.tetrix.get_entity` as the first form.
pub fn mcp_name(title: &str) -> Option<String> {
    static MCP: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let mcp = MCP.get_or_init(|| {
        regex::Regex::new(r"^mcp(?:__|[:.])([A-Za-z0-9_-]+?)(?:__|[:.])([A-Za-z0-9_.-]+)$")
            .expect("a regex")
    });
    mcp.captures(title)
        .map(|c| format!("mcp__{}__{}", &c[1], &c[2]))
}

/// The option a permission request offers of `kind` (`allow_once`, `reject_once`…; Cursor's own
/// page spells them with `-`).
fn option(request: &Value, kind: &str) -> Option<String> {
    request["params"]["options"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|o| {
            o["kind"]
                .as_str()
                .or(o["optionId"].as_str())
                .map(|k| k.replace('-', "_"))
                .as_deref()
                == Some(kind)
        })
        .and_then(|o| o["optionId"].as_str().map(str::to_owned))
}

fn selected(option: String) -> Value {
    json!({"outcome": {"outcome": "selected", "optionId": option}})
}

fn cancelled() -> Value {
    json!({"outcome": {"outcome": "cancelled"}})
}

/// What a `session/prompt` answered: the turn's words and whether it failed.
pub fn finished(stop_reason: &str, said: &str) -> (String, bool) {
    let said = said.trim();
    let or = |fallback: &str| {
        if said.is_empty() {
            fallback.to_owned()
        } else {
            said.to_owned()
        }
    };
    match stop_reason {
        "end_turn" => (or("Done."), false),
        "cancelled" => (or("Stopped."), true),
        "max_turn_requests" => (
            or("It ran out of requests for this turn before it finished."),
            true,
        ),
        "refusal" => (or("The model refused to continue."), true),
        "max_tokens" => (or("The model ran out of tokens in this turn."), true),
        other => (or(&format!("The turn ended: {other}.")), true),
    }
}

/// The tool says the login is missing: ACP's "authentication required" (-32000), or words to that
/// effect.
pub fn is_auth(error: &RpcError) -> bool {
    static AUTH: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let auth = AUTH.get_or_init(|| {
        regex::Regex::new(
            r"(?i)\bauth(?:enticat\w*|orization)?\b|signed out|sign in|log ?in|logged out",
        )
        .expect("a regex")
    });
    error.code == -32000 || auth.is_match(&error.message)
}

struct Run<D, E> {
    conn: Conn,
    decide: D,
    on_event: E,
    options: Options,
    cwd: String,
    session: Option<String>,
    found: Found,
    /// The mode the tool is in now.
    applied: Option<String>,
    tools: HashMap<String, ToolCall>,
    /// What the agent said this turn: the message in progress, and the one before the last tool call.
    current: String,
    before: String,
    /// Its thinking in progress: a thought once something else comes.
    thinking: String,
    /// What obid declined, for the next prompt.
    notes: Vec<String>,
    /// The tool's plan was approved while it was in plan mode: it goes ahead in its agent mode.
    plan_approved: bool,
    /// What this turn's prompts used, when the agent reports it (crate::usage::acp_tokens).
    tokens: crate::usage::Tokens,
}

impl<D: Fn(&str, &Value) -> Ruling, E: FnMut(Event)> Run<D, E> {
    /// The thinking so far, as one thought, once something else comes.
    fn thought(&mut self) {
        if !self.thinking.trim().is_empty() {
            let text = std::mem::take(&mut self.thinking);
            (self.on_event)(Event::Thought {
                text,
                seconds: None,
            });
        }
        self.thinking.clear();
    }

    fn signed_out(&self) -> String {
        format!(
            "{} · {} is signed out: sign in with {}'s own login on this account's folder (its configDir).",
            self.options.tool, self.options.account, self.options.tool
        )
    }

    async fn turn(&mut self, prompt: &str) -> Result<(String, bool), Stop> {
        let tool = self.options.tool.clone();
        let version = env!("CARGO_PKG_VERSION");
        let init = self
            .call(
                "initialize",
                json!({"protocolVersion": 1, "clientCapabilities": {},
                       "clientInfo": {"name": "obid", "title": "obid", "version": version}}),
            )
            .await?;
        let init = match init {
            Ok(init) => init,
            Err(e) if is_auth(&e) => return Err(Stop::Failed(self.signed_out())),
            Err(e) => {
                return Err(Stop::Failed(format!(
                    "{tool} couldn't start: {}",
                    e.message
                )));
            }
        };
        let load = init["agentCapabilities"]["loadSession"] == json!(true);
        let cwd = self.cwd.clone();
        // Only the servers obid gives (as its Claude Code runs with --strict-mcp-config), and those
        // only when the tool takes HTTP servers.
        let servers = if init["agentCapabilities"]["mcpCapabilities"]["http"] == json!(true) {
            json!(self.options.mcp)
        } else {
            json!([])
        };
        let (method, params) = match &self.options.resume {
            Some(session) if load => (
                "session/load",
                json!({"sessionId": session, "cwd": cwd, "mcpServers": servers}),
            ),
            _ => ("session/new", json!({"cwd": cwd, "mcpServers": servers})),
        };
        let answer = match self.call(method, params).await? {
            Ok(answer) => answer,
            Err(e) if is_auth(&e) => return Err(Stop::Failed(self.signed_out())),
            Err(e) => {
                return Err(Stop::Failed(format!(
                    "{tool} couldn't start a session: {}",
                    e.message
                )));
            }
        };
        self.found = found(&answer);
        let session = if method == "session/load" {
            self.options.resume.clone()
        } else {
            self.found.id.clone()
        }
        .ok_or_else(|| Stop::Failed(format!("{tool} didn't start a session.")))?;
        self.session = Some(session.clone());
        (self.on_event)(Event::Session(session.clone()));
        self.applied = self.found.current_mode.clone();

        if let Some(model) = self.options.model.clone().filter(|m| !m.is_empty()) {
            let value = self.found.model_option.clone().zip(model_value(
                &model,
                &self.found.models,
                self.found.model.as_deref(),
            ));
            match value {
                Some((option, value)) => {
                    if Some(&value) != self.found.model.as_ref() {
                        let _ = self
                            .call(
                                "session/set_config_option",
                                json!({"sessionId": session, "configId": option, "value": value}),
                            )
                            .await?;
                    }
                }
                // Said, never silent: the tool goes on with its own.
                None if model != "auto" => (self.on_event)(Event::Step(format!(
                    "{tool} doesn't offer {model}: it uses its own model"
                ))),
                None => {}
            }
        }
        let wanted = if self.options.plan {
            self.options.plan_mode.clone()
        } else {
            self.options.agent_mode.clone()
        };
        self.switch_mode(&wanted).await?;

        let mut ended = self.prompt(prompt).await?;
        // The plan was approved: the turn that showed it goes on with the work, as one round.
        if self.plan_approved && ended.1 == "end_turn" {
            self.plan_approved = false;
            let agent_mode = self.options.agent_mode.clone();
            self.switch_mode(&agent_mode).await?;
            ended = self
                .prompt(
                    "Your plan is approved: carry it out now, then finish with a short summary.",
                )
                .await?;
        }
        let (stop_reason, said) = (ended.1, ended.0);
        Ok(finished(&stop_reason, &said))
    }

    /// Puts the tool in `wanted` (as a config option when it has one, else `session/set_mode`),
    /// when it offers that mode and isn't in it. A tool that won't switch goes on as it is.
    async fn switch_mode(&mut self, wanted: &str) -> Result<(), Stop> {
        let Some(session) = self.session.clone() else {
            return Ok(());
        };
        if self.applied.as_deref() == Some(wanted) || !self.found.modes.iter().any(|m| m == wanted)
        {
            return Ok(());
        }
        let answer = match self.found.mode_option.clone() {
            Some(option) => {
                self.call(
                    "session/set_config_option",
                    json!({"sessionId": session, "configId": option, "value": wanted}),
                )
                .await?
            }
            None => {
                self.call(
                    "session/set_mode",
                    json!({"sessionId": session, "modeId": wanted}),
                )
                .await?
            }
        };
        match answer {
            Ok(_) => self.applied = Some(wanted.to_owned()),
            Err(e) => tracing::warn!(
                "{} wouldn't switch to {wanted}: {}",
                self.options.tool,
                e.message
            ),
        }
        Ok(())
    }

    /// One prompt: what the agent said last, and why the prompt ended.
    async fn prompt(&mut self, text: &str) -> Result<(String, String), Stop> {
        let session = self.session.clone().unwrap_or_default();
        self.current.clear();
        self.before.clear();
        let answer = self
            .call(
                "session/prompt",
                json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
            )
            .await?;
        match answer {
            Ok(answer) => {
                self.thought();
                if let Some(tokens) = crate::usage::acp_tokens(&answer) {
                    self.tokens = self.tokens.plus(&tokens);
                    (self.on_event)(Event::Tokens(self.tokens.clone()));
                }
                let said = if self.current.trim().is_empty() {
                    self.before.clone()
                } else {
                    (self.on_event)(Event::Said(self.current.clone()));
                    self.current.clone()
                };
                let reason = answer["stopReason"]
                    .as_str()
                    .unwrap_or("end_turn")
                    .to_owned();
                Ok((said, reason))
            }
            Err(e) if is_auth(&e) => Err(Stop::Failed(self.signed_out())),
            Err(e) => Err(Stop::Failed(format!(
                "{} hit an error: {}",
                self.options.tool, e.message
            ))),
        }
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
            return self.request(id, &message).await;
        }
        let params = &message["params"];
        match message["method"].as_str() {
            Some("session/update") => {
                let update = &params["update"];
                if update["sessionUpdate"] != "agent_thought_chunk" {
                    self.thought();
                }
                match update["sessionUpdate"].as_str() {
                    Some("agent_message_chunk") if update["content"]["type"] == "text" => {
                        let chunk = update["content"]["text"].as_str().unwrap_or("");
                        self.current.push_str(chunk);
                        if !chunk.is_empty() {
                            (self.on_event)(Event::Delta(chunk.to_owned()));
                        }
                    }
                    Some("agent_thought_chunk") if update["content"]["type"] == "text" => {
                        self.thinking
                            .push_str(update["content"]["text"].as_str().unwrap_or(""));
                    }
                    Some(kind @ ("tool_call" | "tool_call_update")) => {
                        // A tool call ends the message before it: that one is what it said last.
                        if kind == "tool_call" && !self.current.is_empty() {
                            self.before = std::mem::take(&mut self.current);
                            (self.on_event)(Event::Said(self.before.clone()));
                        }
                        let Some(id) = update["toolCallId"].as_str() else {
                            return;
                        };
                        let new = !self.tools.contains_key(id);
                        let call = self.tools.entry(id.to_owned()).or_default();
                        call.merge(update);
                        let step = call.step();
                        if call.said.as_ref() != Some(&step) {
                            call.said = Some(step.clone());
                            (self.on_event)(Event::Step(step));
                        }
                        let (name, input) = call.named();
                        if new {
                            (self.on_event)(Event::Tool {
                                id: id.to_owned(),
                                name,
                                input,
                            });
                        }
                        if let Some(status @ ("completed" | "failed")) = update["status"].as_str() {
                            (self.on_event)(Event::ToolDone {
                                id: id.to_owned(),
                                failed: status == "failed",
                                exit: update["rawOutput"]["exitCode"].as_i64(),
                                lines: diff_lines(&update["content"]),
                                output: output_of(&update["content"]),
                                patches: patches(&update["content"]),
                            });
                        }
                    }
                    Some("plan") => {
                        (self.on_event)(Event::Step("Planning the work".into()));
                        (self.on_event)(Event::Plan(todos(&update["entries"])));
                    }
                    _ => {}
                }
            }
            Some("cursor/update_todos") => {
                (self.on_event)(Event::Plan(todos(&params["todos"])));
                let doing = params["todos"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|t| t["status"] == "in_progress")
                    .and_then(|t| t["content"].as_str());
                (self.on_event)(Event::Step(match doing {
                    Some(doing) => format!("Working on: {doing}"),
                    None => "Planning the work".into(),
                }));
            }
            Some("cursor/task") => {
                let what = params["description"]
                    .as_str()
                    .filter(|d| !d.is_empty())
                    .unwrap_or("Starting a helper");
                (self.on_event)(Event::Step(what.to_owned()));
            }
            _ => {}
        }
    }

    /// A request the agent waits on: every one is answered, or the agent hangs.
    async fn request(&mut self, id: Value, request: &Value) {
        let params = &request["params"];
        match request["method"].as_str() {
            Some("session/request_permission") => {
                let fields = &params["toolCall"];
                let mut call = fields["toolCallId"]
                    .as_str()
                    .and_then(|id| self.tools.get(id))
                    .cloned()
                    .unwrap_or_default();
                call.merge(fields);
                let title = call
                    .title
                    .clone()
                    .unwrap_or_else(|| call.kind.clone().unwrap_or_else(|| "a tool call".into()));
                let answer = match call.calls() {
                    None => Answer::Deny(format!(
                        "obid doesn't know what {title} does, so it declined it. Say in your summary what you'd have done with it."
                    )),
                    Some(calls) if calls.is_empty() => {
                        Answer::Deny("obid couldn't see which files this change writes.".into())
                    }
                    Some(calls) => {
                        let mut answer = Answer::Allow;
                        for (tool, input) in &calls {
                            let ruling = (self.decide)(tool, input);
                            match self.conn.settle(ruling).await {
                                Ok(Answer::Allow | Answer::AllowWith(_)) => {}
                                Ok(deny) => {
                                    answer = deny;
                                    break;
                                }
                                // Stopped while the owner was asked: nothing more is answered.
                                Err(_) => return,
                            }
                        }
                        answer
                    }
                };
                let reply = match answer {
                    Answer::Allow | Answer::AllowWith(_) => match option(request, "allow_once") {
                        Some(once) => selected(once),
                        None => {
                            self.notes.push(format!(
                                "obid declined {title}: obid can't allow this once."
                            ));
                            option(request, "reject_once")
                                .map(selected)
                                .unwrap_or_else(cancelled)
                        }
                    },
                    Answer::Deny(why) => {
                        (self.on_event)(Event::Denied(why.clone()));
                        self.notes.push(format!("obid declined {title}: {why}"));
                        option(request, "reject_once")
                            .map(selected)
                            .unwrap_or_else(cancelled)
                    }
                };
                self.conn.reply(&id, reply).await;
            }
            Some("cursor/create_plan") => {
                // The plan, as Claude Code's ExitPlanMode: the job's rule decides.
                let plan = params["plan"].as_str().unwrap_or("");
                let ruling = (self.decide)("ExitPlanMode", &json!({ "plan": plan }));
                let Ok(answer) = self.conn.settle(ruling).await else {
                    return;
                };
                let reply = match answer {
                    Answer::Allow | Answer::AllowWith(_) => {
                        self.plan_approved =
                            self.applied.as_deref() == Some(self.options.plan_mode.as_str());
                        json!({"outcome": {"outcome": "accepted"}})
                    }
                    Answer::Deny(why) => {
                        (self.on_event)(Event::Denied(why.clone()));
                        json!({"outcome": {"outcome": "rejected", "reason": why}})
                    }
                };
                self.conn.reply(&id, reply).await;
            }
            Some("cursor/ask_question") => {
                self.conn
                    .reply(
                        &id,
                        json!({"outcome": {"outcome": "skipped", "reason":
                            "obid can't put a question to the owner here. Decide yourself, or say what you need in your summary."}}),
                    )
                    .await;
            }
            // `fs/*`, `terminal/*` and anything else: refused, so the agent never waits on obid.
            _ => self.conn.refuse(&id).await,
        }
    }
}

/// Cursor (`cursor-agent acp`): its command line, its account's environment and the files obid
/// keeps for it (docs/cursor.md).
pub mod cursor {
    use std::ffi::OsString;
    use std::path::{Path, PathBuf};

    use serde_json::{Value, json};

    /// `cursor-agent --sandbox disabled acp`: Cursor's own sandbox is off (obid's job sandbox is the
    /// sandbox; another can't run inside it), so every command comes to obid. The model is set
    /// through the session's `model` option, never `--model`.
    pub fn argv(bin: PathBuf) -> Vec<OsString> {
        vec![
            bin.into_os_string(),
            "--sandbox".into(),
            "disabled".into(),
            "acp".into(),
        ]
    }

    /// The account's own folders: its login lives under them, and the probe proved two accounts
    /// stay apart only with all three (docs/cursor.md, "Login isolation").
    pub fn environment(home: &Path) -> Vec<(&'static str, OsString)> {
        vec![
            ("CURSOR_CONFIG_DIR", home.as_os_str().to_owned()),
            ("HOME", home.as_os_str().to_owned()),
            ("XDG_CONFIG_HOME", home.join(".config").into_os_string()),
            // Its login in a file under its HOME ([`crate::jobs::cursor_login_file`]), never the
            // macOS Keychain, which a job's box denies: the job gets a copy of that file.
            ("AGENT_CLI_CREDENTIAL_STORE", "file".into()),
        ]
    }

    /// The longest config folder Cursor keeps its sockets in (cursor-agent 2026.05.15: a socket's
    /// name has room for about 84 characters of folder); past it, Cursor uses `/tmp/.cursor`, which
    /// the job sandbox doesn't let it write, and it stops.
    pub const SOCKET_ROOM: usize = 84;

    /// Says in obid's log when a Cursor job's folder (its own login folder, under obid's home) is too
    /// long for Cursor's sockets.
    pub fn warn_if_long(home: &Path) {
        let real = home.canonicalize().unwrap_or_else(|_| home.to_path_buf());
        let length = real.as_os_str().len();
        if length > SOCKET_ROOM {
            tracing::warn!(
                "Cursor's folder {} is {length} characters: past {SOCKET_ROOM}, Cursor puts its sockets in /tmp/.cursor, which the job sandbox doesn't let it write. Give obid a shorter home.",
                real.display()
            );
        }
    }

    /// Before each start: no command or edit is allowed ahead of obid (`allowlist` mode over an empty
    /// allowlist). Cursor's own keys (`authInfo`, `version`, …) stay as they are.
    ///
    /// The folder is a job's own, which the job can write: obid never reads or writes through a
    /// link it left there. The folder is opened once without following a link, and everything
    /// after happens in that very folder (as [`crate::jobs::write_login`]; #645: another job on
    /// the account could swap a link in after a check by name): the file is opened without
    /// following one, and the new one is made with `O_EXCL`, then renamed over the old, which
    /// replaces a link rather than following it.
    pub fn rewrite_config(home: &Path) -> std::io::Result<()> {
        use nix::fcntl::{OFlag, open, openat, renameat};
        use nix::sys::stat::Mode;
        std::fs::create_dir_all(home)?;
        let dir = open(
            home,
            OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_RDONLY | OFlag::O_CLOEXEC,
            Mode::empty(),
        )
        .map_err(std::io::Error::from)?;
        let file = "cli-config.json";
        let read = || -> Option<Vec<u8>> {
            let opened = openat(
                &dir,
                file,
                OFlag::O_NOFOLLOW | OFlag::O_RDONLY | OFlag::O_CLOEXEC | OFlag::O_NONBLOCK,
                Mode::empty(),
            )
            .ok()?;
            let mut opened = std::fs::File::from(opened);
            opened.metadata().ok().filter(|m| m.is_file())?;
            let mut bytes = Vec::new();
            std::io::Read::read_to_end(&mut opened, &mut bytes).ok()?;
            Some(bytes)
        };
        let mut config = read()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .filter(Value::is_object)
            .unwrap_or_else(|| json!({}));
        config["permissions"] = json!({"allow": [], "deny": []});
        config["approvalMode"] = json!("allowlist");
        let text = serde_json::to_vec_pretty(&config).map_err(std::io::Error::other)?;
        // A name of this write's own: two jobs on one account start at once, and one's rename
        // must never take the other's file away.
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let temporary = format!(".cli-config.json.obid-{}-{n}", std::process::id());
        let _ = nix::unistd::unlinkat(
            &dir,
            temporary.as_str(),
            nix::unistd::UnlinkatFlags::NoRemoveDir,
        );
        let new = openat(
            &dir,
            temporary.as_str(),
            OFlag::O_CREAT | OFlag::O_EXCL | OFlag::O_NOFOLLOW | OFlag::O_WRONLY | OFlag::O_CLOEXEC,
            Mode::from_bits_truncate(0o600),
        )
        .map_err(std::io::Error::from)?;
        std::io::Write::write_all(&mut std::fs::File::from(new), &text)?;
        renameat(&dir, temporary.as_str(), &dir, file).map_err(std::io::Error::from)
    }

    /// What the worktree's `.cursor/cli.json` lets through without asking (`permissions.allow`).
    pub fn repository_allowlist(worktree: &Path) -> Vec<String> {
        std::fs::read(worktree.join(".cursor/cli.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .and_then(|config| config["permissions"]["allow"].as_array().cloned())
            .unwrap_or_default()
            .iter()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_calls_name_comes_from_its_kind_never_its_title() {
        let call = |fields: Value| {
            let mut call = ToolCall::default();
            call.merge(&fields);
            call.named().0
        };
        assert_eq!(
            call(json!({"kind": "other", "title": "mcp__tetrix__get_entity"})),
            "Tool"
        );
        assert_eq!(call(json!({"title": "rm -rf / and a secret"})), "Tool");
        assert_eq!(call(json!({"kind": "execute", "title": "Read"})), "Bash");
        assert_eq!(call(json!({"kind": "search", "title": "x"})), "Grep");
    }

    #[test]
    fn a_session_names_its_modes_and_options() {
        let answer = json!({"sessionId": "s1",
            "modes": {"availableModes": [{"id": "agent"}, {"id": "plan"}, {"id": "ask"}], "currentModeId": "agent"},
            "configOptions": [{"id": "model", "category": "model", "currentValue": "default[]",
                               "options": [{"value": "default[]"}, {"group": "GPT", "options": [{"value": "gpt-5.6-luna[context=272k,reasoning=medium]"}]}]}]});
        let found = found(&answer);
        assert_eq!(found.id.as_deref(), Some("s1"));
        assert_eq!(found.modes, ["agent", "plan", "ask"]);
        assert_eq!(found.current_mode.as_deref(), Some("agent"));
        assert_eq!(found.model_option.as_deref(), Some("model"));
        assert_eq!(found.models.len(), 2);
        let mode_option = json!({"configOptions": [{"id": "m", "category": "mode", "currentValue": "agent",
                                                   "options": [{"value": "agent"}, {"value": "plan"}]}]});
        let found = super::found(&mode_option);
        assert_eq!(found.mode_option.as_deref(), Some("m"));
        assert_eq!(found.modes, ["agent", "plan"]);
    }

    #[test]
    fn the_model_value_is_the_variant_with_its_parameters() {
        let values: Vec<String> = ["default[]", "gpt-5.6-luna[a]", "gpt-5.6-luna[b]", "sonnet"]
            .map(str::to_owned)
            .to_vec();
        assert_eq!(
            model_value("sonnet", &values, None).as_deref(),
            Some("sonnet")
        );
        assert_eq!(
            model_value("gpt-5.6-luna", &values, None).as_deref(),
            Some("gpt-5.6-luna[a]")
        );
        assert_eq!(
            model_value("gpt-5.6-luna", &values, Some("gpt-5.6-luna[b]")).as_deref(),
            Some("gpt-5.6-luna[b]")
        );
        assert_eq!(model_value("auto", &values, None), None);
        assert_eq!(model_value("gpt-9", &values, None), None);
    }

    #[test]
    fn tool_calls_map_to_the_policys_tools() {
        let mut call = ToolCall::default();
        call.merge(&json!({"kind": "execute", "title": "git push", "rawInput": {"command": ["git", "push"]}}));
        assert_eq!(
            call.calls(),
            Some(vec![(
                "Bash".into(),
                json!({"command": "git push", "run_in_background": false, "seen": true})
            )])
        );
        assert_eq!(call.step(), "Running git push");
        let mut edit = ToolCall::default();
        edit.merge(&json!({"kind": "edit", "locations": [{"path": "/w/a.js"}],
                           "content": [{"type": "diff", "path": "/w/b.js"}]}));
        assert_eq!(edit.calls().unwrap().len(), 2);
        assert_eq!(edit.step(), "Editing a.js");
        let mut unseen = ToolCall::default();
        unseen.merge(&json!({"kind": "edit"}));
        assert_eq!(unseen.calls(), Some(vec![]));
        let mut mcp = ToolCall::default();
        mcp.merge(&json!({"kind": "other", "title": "mcp:tetrix:get_entity"}));
        assert_eq!(
            mcp.calls(),
            Some(vec![("mcp__tetrix__get_entity".into(), json!({}))])
        );
        let mut other = ToolCall::default();
        other.merge(&json!({"kind": "other", "title": "Something new"}));
        assert_eq!(other.calls(), None);
    }

    #[test]
    fn never_allow_always() {
        let request = json!({"params": {"options": [
            {"optionId": "allow-always", "kind": "allow_always"},
            {"optionId": "allow-once", "kind": "allow_once"},
            {"optionId": "reject-once", "kind": "reject_once"}]}});
        assert_eq!(
            option(&request, "allow_once").as_deref(),
            Some("allow-once")
        );
        assert_eq!(
            option(&request, "reject_once").as_deref(),
            Some("reject-once")
        );
        let spelled = json!({"params": {"options": [{"optionId": "allow-once"}]}});
        assert_eq!(
            option(&spelled, "allow_once").as_deref(),
            Some("allow-once")
        );
    }

    #[test]
    fn stop_reasons_and_auth_errors() {
        assert_eq!(
            finished("end_turn", " Added a. "),
            ("Added a.".into(), false)
        );
        assert_eq!(finished("end_turn", ""), ("Done.".into(), false));
        assert!(finished("refusal", "").1);
        assert!(finished("max_tokens", "").1);
        assert!(finished("weird", "").0.contains("weird"));
        assert!(is_auth(&RpcError {
            code: -32000,
            message: "x".into()
        }));
        assert!(is_auth(&RpcError {
            code: 1,
            message: "Please log in first".into()
        }));
        assert!(!is_auth(&RpcError {
            code: 1,
            message: "The model is busy".into()
        }));
    }

    /// A link a job left in place of Cursor's settings is never read or written through: the
    /// settings start over, and the file the link named is as it was.
    #[test]
    fn cursor_settings_never_follow_a_link() {
        let root = std::env::temp_dir().join(format!("obid-cursor-link-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let home = root.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let elsewhere = root.join("elsewhere.json");
        std::fs::write(&elsewhere, r#"{"secret": "not for the job"}"#).unwrap();
        std::os::unix::fs::symlink(&elsewhere, home.join("cli-config.json")).unwrap();
        cursor::rewrite_config(&home).unwrap();
        let written = std::fs::read_to_string(home.join("cli-config.json")).unwrap();
        assert!(!written.contains("secret"), "{written}");
        assert!(
            !std::fs::symlink_metadata(home.join("cli-config.json"))
                .unwrap()
                .is_symlink()
        );
        assert_eq!(
            std::fs::read_to_string(&elsewhere).unwrap(),
            r#"{"secret": "not for the job"}"#
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A link put in place of the folder itself (#645: another job on the account swaps it in
    /// after obid's check) is never written through: the rewrite fails, the other folder untouched.
    #[test]
    fn cursor_settings_never_follow_a_linked_folder() {
        let root = std::env::temp_dir().join(format!("obid-cursor-dir-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let elsewhere = root.join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        let home = root.join("home");
        std::os::unix::fs::symlink(&elsewhere, &home).unwrap();
        assert!(cursor::rewrite_config(&home).is_err());
        assert_eq!(std::fs::read_dir(&elsewhere).unwrap().count(), 0);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Jobs on one Cursor account start at once: each rewrite of its settings succeeds.
    #[test]
    fn cursor_settings_are_rewritten_by_many_jobs_at_once() {
        let home = std::env::temp_dir().join(format!("obid-cursor-many-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let writers: Vec<_> = (0..8)
            .map(|_| {
                let home = home.clone();
                std::thread::spawn(move || (0..50).try_for_each(|_| cursor::rewrite_config(&home)))
            })
            .collect();
        for writer in writers {
            writer.join().unwrap().unwrap();
        }
        let config: Value =
            serde_json::from_slice(&std::fs::read(home.join("cli-config.json")).unwrap()).unwrap();
        assert_eq!(config["approvalMode"], "allowlist");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn cursor_keeps_its_own_keys_and_asks_about_everything() {
        let home = std::env::temp_dir().join(format!("obid-cursor-config-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(
            home.join("cli-config.json"),
            r#"{"authInfo": {"email": "a@b"}, "version": 1, "permissions": {"allow": ["Shell(*)"]}}"#,
        )
        .unwrap();
        cursor::rewrite_config(&home).unwrap();
        let config: Value =
            serde_json::from_slice(&std::fs::read(home.join("cli-config.json")).unwrap()).unwrap();
        assert_eq!(config["authInfo"]["email"], "a@b");
        assert_eq!(config["version"], 1);
        assert_eq!(config["permissions"], json!({"allow": [], "deny": []}));
        assert_eq!(config["approvalMode"], "allowlist");
        std::fs::create_dir_all(home.join("w/.cursor")).unwrap();
        std::fs::write(
            home.join("w/.cursor/cli.json"),
            r#"{"permissions": {"allow": ["Shell(git status)", 3]}}"#,
        )
        .unwrap();
        assert_eq!(
            cursor::repository_allowlist(&home.join("w")),
            ["Shell(git status)"]
        );
        assert!(cursor::repository_allowlist(&home).is_empty());
        let _ = std::fs::remove_dir_all(&home);
    }
}
