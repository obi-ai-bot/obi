//! Connected apps and their MCP broker (Runner/Connections.swift, Runner/Broker.swift and
//! Engine/Connected.swift). Connection files contain names and URLs only; the separate vault
//! holds the values, and the agent reaches this process with a per-job token.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};

use axum::extract::{Path as UrlPath, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::{ApiError, Shared};

/// The permission rule that lets a job's agent call the broker's tools (`mcp__oby__<connection>_<tool>`),
/// in the job's rules only when it was given the broker.
pub const BROKER_RULE: &str = "mcp__oby__*";
/// The calls a job's report keeps: the latest ones (the use log has them all).
pub const KEPT_USES: usize = 500;
/// How large the use log grows before it starts again, the one before kept as `uses.1.jsonl`.
const USES_LOG_MAX: u64 = 4 << 20;
const ACTING: &str = "Acting as you needs your OK, which arrives with permission modes.";
const LONGEST: usize = 256 * 1024;
const MCP_VERSIONS: &[&str] = &["2025-06-18", "2025-03-26", "2024-11-05"];
const MCP_SESSION_EXPIRED: &str = "The connected server forgot this MCP session.";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Connection {
    pub name: String,
    #[serde(default)]
    pub mcp: Option<String>,
    #[serde(default)]
    pub api: Option<String>,
    pub secret: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    pub created: String,
}

impl Connection {
    pub fn host(&self) -> String {
        self.mcp
            .as_deref()
            .or(self.api.as_deref())
            .and_then(|s| reqwest::Url::parse(s).ok())
            .and_then(|u| u.host_str().map(str::to_owned))
            .unwrap_or_default()
    }

    pub fn url(&self) -> reqwest::Url {
        reqwest::Url::parse(
            self.mcp
                .as_deref()
                .or(self.api.as_deref())
                .unwrap_or_default(),
        )
        .expect("validated connection URL")
    }

    pub fn problem(&self) -> Option<String> {
        if self.name.is_empty()
            || self.name.len() > 32
            || !self.name.as_bytes()[0].is_ascii_lowercase()
                && !self.name.as_bytes()[0].is_ascii_digit()
            || !self
                .name
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        {
            return Some(
                "A connection's name is up to 32 lower-case letters, digits or dashes.".into(),
            );
        }
        if self.mcp.is_some() == self.api.is_some() {
            return Some("A connection has either mcp (a remote MCP server's URL) or api (an API's base URL).".into());
        }
        let Some(text) = self.mcp.as_deref().or(self.api.as_deref()) else {
            return Some("A connection needs a URL.".into());
        };
        let Ok(url) = reqwest::Url::parse(text) else {
            return Some(format!(
                "{text} isn't a URL a connection can use: https://host/path, with no login, query or fragment in it."
            ));
        };
        // The phone signs this text, and the secret goes where the parsed URL points: they must
        // be the same. WHATWG parsing reads `\` as `/`, drops tabs and newlines, lower-cases the
        // host and spells a non-ASCII one as xn--, so a URL that isn't already in that form
        // could show the owner one host and send the login to another.
        if url.as_str() != text {
            return Some(format!(
                "{text:?} isn't written the way it's read. Write it as {url}: that is where the secret would go."
            ));
        }
        let loopback = matches!(
            url.host_str().unwrap_or("").to_ascii_lowercase().as_str(),
            "127.0.0.1" | "localhost" | "::1" | "[::1]"
        );
        if !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Some(format!(
                "{text} isn't a URL a connection can use: https://host/path, with no login, query or fragment in it."
            ));
        }
        if !(url.scheme() == "https" || url.scheme() == "http" && loopback) {
            return Some("A connection's URL is HTTPS (HTTP only on 127.0.0.1): the secret never travels in the clear.".into());
        }
        if !valid_secret_name(&self.secret) {
            return Some(
                "A secret's name is up to 64 letters, digits, dots, dashes or underscores.".into(),
            );
        }
        if let Some(name) = &self.header {
            let reserved = [
                "host",
                "content-length",
                "content-type",
                "transfer-encoding",
                "connection",
                "accept",
                "cookie",
                "mcp-session-id",
                "mcp-protocol-version",
            ];
            if name.is_empty()
                || name.len() > 64
                || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                || reserved.contains(&name.to_ascii_lowercase().as_str())
            {
                return Some(format!(
                    "{name} can't carry the secret: name a header like Authorization or X-Api-Key."
                ));
            }
        }
        None
    }

    pub fn action(&self) -> String {
        let target = self
            .mcp
            .as_ref()
            .map(|u| format!("the MCP server {u}"))
            .unwrap_or_else(|| format!("the API {}", self.api.as_deref().unwrap_or_default()));
        let header = self
            .header
            .as_deref()
            .filter(|h| !h.eq_ignore_ascii_case("authorization"));
        format!(
            "Connect {}: agents' read-only calls to {target} carry the vault secret {}{}",
            self.name,
            self.secret,
            header
                .map(|h| format!(" in the header {h}."))
                .unwrap_or_else(|| " as Authorization: Bearer.".into())
        )
    }

    pub fn removal(name: &str) -> String {
        format!("Disconnect {name}.")
    }
}

fn valid_secret_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.as_bytes()[0].is_ascii_alphanumeric()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionUse {
    pub job: String,
    pub connection: String,
    pub tool: String,
    pub access: String,
    pub allowed: bool,
    pub secret: String,
    pub host: String,
    pub date: String,
}

impl ConnectionUse {
    pub fn line(&self) -> String {
        format!(
            "{} {} {} ({})",
            if self.access == "read" {
                "Read"
            } else {
                "Write"
            },
            self.connection,
            self.tool,
            if self.allowed { "allowed" } else { "refused" }
        )
    }
}

pub struct Connections {
    file: PathBuf,
    uses_file: PathBuf,
    /// [`USES_LOG_MAX`]; smaller in tests.
    uses_max: u64,
    /// How a vault secret is read: `crate::vault::value`, a fake in tests.
    vault: fn(&str) -> Result<Option<String>, String>,
    all: Mutex<Vec<Connection>>,
    last_used: Mutex<HashMap<String, String>>,
    tokens: Mutex<HashMap<String, String>>,
    snapshots: Mutex<HashMap<String, Vec<Connection>>>,
    upstreams: tokio::sync::Mutex<HashMap<String, Upstream>>,
    jobs: Weak<crate::jobs::Jobs>,
    client: reqwest::Client,
    api_url: String,
    next_id: std::sync::atomic::AtomicU64,
}

#[derive(Default)]
struct Upstream {
    session: Option<String>,
    version: Option<String>,
    tools: HashMap<String, Value>,
}

impl Connections {
    pub fn open(home: &Path, jobs: &Arc<crate::jobs::Jobs>, api_url: String) -> Arc<Connections> {
        let file = home.join("connections.json");
        let all = load(&file);
        let uses_file = home.join("vault/uses.jsonl");
        let mut last_used = HashMap::new();
        for text in [&previous_log(&uses_file), &uses_file]
            .into_iter()
            .filter_map(|f| std::fs::read_to_string(f).ok())
        {
            for line in text.lines() {
                if let Ok(value) = serde_json::from_str::<ConnectionUse>(line) {
                    last_used
                        .entry(value.connection)
                        .and_modify(|d: &mut String| {
                            if value.date > *d {
                                *d = value.date.clone();
                            }
                        })
                        .or_insert(value.date);
                }
            }
        }
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(60))
            .build()
            .expect("reqwest client");
        Arc::new(Connections {
            file,
            uses_file,
            uses_max: USES_LOG_MAX,
            vault: crate::vault::value,
            all: Mutex::new(all),
            last_used: Mutex::new(last_used),
            tokens: Mutex::new(HashMap::new()),
            snapshots: Mutex::new(HashMap::new()),
            upstreams: tokio::sync::Mutex::new(HashMap::new()),
            jobs: Arc::downgrade(jobs),
            client,
            api_url,
            next_id: std::sync::atomic::AtomicU64::new(1),
        })
    }

    /// The vault secret `name`, through obid's vault (`crate::vault::value`): it fails whenever
    /// the vault can't be read, and its value is already in `crate::secrets::known()` as
    /// `vault <name>`, so nothing is learned here (a secret named like one of obid's own,
    /// `api-token`, would replace it).
    fn vault_value(&self, name: &str) -> Result<Option<String>, String> {
        (self.vault)(name)
    }

    fn list_json(&self) -> Result<Value, ApiError> {
        let all = self.all.lock().unwrap_or_else(|e| e.into_inner());
        let used = self.last_used.lock().unwrap_or_else(|e| e.into_inner());
        let mut list = Vec::new();
        for connection in all.iter() {
            let saved = self
                .vault_value(&connection.secret)
                .map_err(|e| ApiError::new(StatusCode::SERVICE_UNAVAILABLE, e))?
                .is_some();
            list.push(connection_json(
                connection,
                saved,
                used.get(&connection.name),
            ));
        }
        Ok(Value::Array(list))
    }

    fn save(&self, connection: Connection) -> Result<(), String> {
        if let Some(problem) = connection.problem() {
            return Err(problem);
        }
        if self.vault_value(&connection.secret)?.is_none() {
            return Err(format!(
                "The vault has no secret named {}.",
                connection.secret
            ));
        }
        let mut all = self.all.lock().unwrap_or_else(|e| e.into_inner());
        let mut next: Vec<_> = all
            .iter()
            .filter(|c| c.name != connection.name)
            .cloned()
            .collect();
        next.push(connection);
        next.sort_by(|a, b| a.name.cmp(&b.name));
        write_private(
            &self.file,
            &serde_json::to_vec_pretty(&next).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        *all = next;
        Ok(())
    }

    fn remove(&self, name: &str) -> Result<bool, String> {
        let mut all = self.all.lock().unwrap_or_else(|e| e.into_inner());
        if !all.iter().any(|c| c.name == name) {
            return Ok(false);
        }
        let next: Vec<_> = all.iter().filter(|c| c.name != name).cloned().collect();
        write_private(
            &self.file,
            &serde_json::to_vec_pretty(&next).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        *all = next;
        Ok(true)
    }

    fn contains(&self, name: &str) -> bool {
        self.all
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .any(|connection| connection.name == name)
    }

    pub fn open_job(&self, id: &str) -> Option<(String, String)> {
        let current = self.all.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let kept = self
            .snapshots
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(id)
            .cloned();
        // The snapshot the job started with: in memory while it works, and kept on the job, so
        // a later round, a message or a restart doesn't take a new one.
        let snapshot = kept.unwrap_or_else(|| {
            let started = match self.jobs.upgrade() {
                Some(jobs) => jobs.connections_of(id, current.clone()),
                None => current.clone(),
            };
            self.snapshots
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .entry(id.to_owned())
                .or_insert(started)
                .clone()
        });
        if !snapshot
            .iter()
            .any(|s| current.contains(s) && self.vault_value(&s.secret).ok().flatten().is_some())
        {
            return None;
        }
        let mut tokens = self.tokens.lock().unwrap_or_else(|e| e.into_inner());
        let token = tokens
            .iter()
            .find_map(|(token, job)| (job == id).then(|| token.clone()))
            .unwrap_or_else(|| {
                let token = format!(
                    "{}{}",
                    uuid::Uuid::new_v4().simple(),
                    uuid::Uuid::new_v4().simple()
                );
                tokens.insert(token.clone(), id.to_owned());
                token
            });
        Some((format!("{}/v1/agent/mcp/{id}", self.api_url), token))
    }

    pub async fn close_job(&self, id: &str) {
        self.tokens
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|_, job| job != id);
        self.snapshots
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(id);
        let prefix = format!("{id}/");
        self.upstreams
            .lock()
            .await
            .retain(|key, _| !key.starts_with(&prefix));
    }

    pub fn allows(&self, id: &str, token: &str) -> bool {
        self.jobs
            .upgrade()
            .and_then(|j| j.get(id))
            .is_some_and(|j| j.status.is_active())
            && self
                .tokens
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(token)
                .is_some_and(|job| job == id)
    }

    fn usable(&self, id: &str) -> Vec<Connection> {
        let snapshot = self
            .snapshots
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(id)
            .cloned()
            .unwrap_or_default();
        let current = self.all.lock().unwrap_or_else(|e| e.into_inner());
        snapshot
            .into_iter()
            .filter(|c| current.contains(c))
            .collect()
    }

    fn record(&self, use_record: ConnectionUse) {
        if let Some(jobs) = self.jobs.upgrade() {
            jobs.connection_used(&use_record.job, use_record.clone());
        }
        self.last_used
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(use_record.connection.clone(), use_record.date.clone());
        if let Ok(mut line) = serde_json::to_vec(&use_record) {
            line.push(b'\n');
            // Full: it starts again, the one before kept (a rename keeps its 0600 and owner).
            if std::fs::symlink_metadata(&self.uses_file)
                .is_ok_and(|m| m.is_file() && m.len() + line.len() as u64 > self.uses_max)
            {
                let _ = std::fs::rename(&self.uses_file, previous_log(&self.uses_file));
            }
            let _ = append_private(&self.uses_file, &line);
        }
    }

    async fn handle(&self, id: &str, body: Value) -> Option<Value> {
        let method = body.get("method")?.as_str()?;
        let rpc_id = body.get("id").cloned().filter(|id| !id.is_null())?;
        let params = body
            .get("params")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let result = match method {
            "initialize" => {
                let asked = params
                    .get("protocolVersion")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                json!({"protocolVersion": if MCP_VERSIONS.contains(&asked) { asked } else { MCP_VERSIONS[0] }, "capabilities":{"tools":{"listChanged":false}}, "serverInfo":{"name":"oby","version":crate::api::API_VERSION}, "instructions":"Your user's connected apps, through Oby: Oby holds each login and you get results only. Tools are named <connection>_<tool>. Read-only tools work; tools that act as the user are refused for now."})
            }
            "ping" => json!({}),
            "tools/list" => json!({"tools": self.tools(id).await}),
            "tools/call" => {
                self.call(
                    id,
                    params.get("name").and_then(Value::as_str).unwrap_or(""),
                    params
                        .get("arguments")
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                )
                .await
            }
            _ => {
                return Some(
                    json!({"jsonrpc":"2.0","id":rpc_id,"error":{"code":-32601,"message":format!("Oby's broker doesn't answer {method}.")}}),
                );
            }
        };
        Some(json!({"jsonrpc":"2.0","id":rpc_id,"result":self.clean(result)}))
    }

    async fn tools(&self, id: &str) -> Vec<Value> {
        let mut out = Vec::new();
        for c in self.usable(id) {
            if c.api.is_some() {
                out.extend(api_tools(&c));
                continue;
            }
            if let Ok(tools) = self.upstream_tools(id, &c, false).await {
                let mut tools: Vec<_> = tools.into_iter().collect();
                tools.sort_by(|a, b| a.0.cmp(&b.0));
                for (name, mut tool) in tools {
                    let write = access(&name, &tool) == "write";
                    if let Some(obj) = tool.as_object_mut() {
                        obj.insert("name".into(), json!(format!("{}_{}", c.name, name)));
                        obj.insert(
                            "description".into(),
                            json!(format!(
                                "{} (through Oby): {}{}",
                                c.name,
                                obj.get("description")
                                    .and_then(Value::as_str)
                                    .unwrap_or(&name),
                                if write {
                                    " Acts as the user, so Oby refuses it for now."
                                } else {
                                    ""
                                }
                            )),
                        );
                    }
                    out.push(tool);
                }
            }
        }
        out
    }

    async fn upstream_tools(
        &self,
        job: &str,
        c: &Connection,
        again: bool,
    ) -> Result<HashMap<String, Value>, String> {
        let key = format!("{job}/{}", c.name);
        let state = self.upstreams.lock().await;
        let initialized = state.get(&key).is_some_and(|u| u.version.is_some());
        let cached = state.get(&key).map(|u| u.tools.clone());
        drop(state);
        if initialized && !again {
            return Ok(cached.unwrap_or_default());
        }
        if !initialized {
            self.initialize_upstream(job, c).await?;
        }
        let mut tools = HashMap::new();
        let mut cursor: Option<String> = None;
        loop {
            let mut params = json!({});
            if let Some(value) = &cursor {
                params["cursor"] = json!(value);
            }
            let listed = self.upstream_rpc(job, c, "tools/list", params).await?;
            for tool in listed
                .get("tools")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let Some(name) = tool.get("name").and_then(Value::as_str).filter(|n| {
                    !n.is_empty()
                        && n.len() <= 64
                        && n.bytes()
                            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
                }) else {
                    continue;
                };
                tools.insert(name.to_owned(), tool.clone());
                if tools.len() >= 1000 {
                    break;
                }
            }
            if tools.len() >= 1000 {
                break;
            }
            cursor = listed
                .get("nextCursor")
                .and_then(Value::as_str)
                .map(str::to_owned);
            if cursor.is_none() {
                break;
            }
        }
        self.upstreams.lock().await.entry(key).or_default().tools = tools.clone();
        Ok(tools)
    }

    async fn initialize_upstream(&self, job: &str, c: &Connection) -> Result<(), String> {
        let key = format!("{job}/{}", c.name);
        self.upstreams.lock().await.remove(&key);
        let init = self
            .send_mcp(
                job,
                c,
                "initialize",
                Some(json!({"jsonrpc":"2.0","id":self.next_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed),"method":"initialize","params":{"protocolVersion":MCP_VERSIONS[0],"capabilities":{},"clientInfo":{"name":"oby","version":crate::api::API_VERSION}}})),
            )
            .await?
            .ok_or_else(|| format!("{} didn't answer.", c.name))?;
        let version = init
            .get("protocolVersion")
            .and_then(Value::as_str)
            .unwrap_or(MCP_VERSIONS[0])
            .to_owned();
        self.upstreams.lock().await.entry(key).or_default().version = Some(version);
        self.send_mcp(
            job,
            c,
            "notifications/initialized",
            Some(json!({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})),
        )
        .await?;
        Ok(())
    }

    async fn upstream_rpc(
        &self,
        job: &str,
        c: &Connection,
        method: &str,
        params: Value,
    ) -> Result<Value, String> {
        let id = self
            .next_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let body = if method.starts_with("notifications/") {
            json!({"jsonrpc":"2.0","method":method,"params":params})
        } else {
            json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})
        };
        match self.send_mcp(job, c, method, Some(body.clone())).await {
            Err(error) if error == MCP_SESSION_EXPIRED => {
                self.initialize_upstream(job, c).await?;
                self.send_mcp(job, c, method, Some(body))
                    .await
                    .map_err(|error| {
                        if error == MCP_SESSION_EXPIRED {
                            format!("{} didn't answer after starting a new session.", c.name)
                        } else {
                            error
                        }
                    })?
                    .ok_or_else(|| format!("{} didn't answer.", c.name))
            }
            Ok(Some(answer)) => Ok(answer),
            Ok(None) => Err(format!("{} didn't answer.", c.name)),
            Err(error) => Err(error),
        }
    }

    async fn send_mcp(
        &self,
        job: &str,
        c: &Connection,
        method: &str,
        body: Option<Value>,
    ) -> Result<Option<Value>, String> {
        let expected_id = body.as_ref().and_then(|value| value.get("id")).cloned();
        let mut req = self.authorized(c, self.client.post(c.url())).await?;
        req = req
            .header(header::CONTENT_TYPE, "application/json")
            .header(header::ACCEPT, "application/json, text/event-stream");
        let key = format!("{job}/{}", c.name);
        let upstreams = self.upstreams.lock().await;
        let has_session = upstreams
            .get(&key)
            .is_some_and(|upstream| upstream.session.is_some());
        if let Some(up) = upstreams.get(&key) {
            if let Some(session) = &up.session {
                req = req.header("Mcp-Session-Id", session);
            }
            if method != "initialize"
                && let Some(version) = &up.version
            {
                req = req.header("MCP-Protocol-Version", version);
            }
        }
        drop(upstreams);
        if let Some(body) = body {
            req = req.json(&body);
        }
        let response = req.send().await.map_err(|e| e.to_string())?;
        let status = response.status();
        if status == StatusCode::NOT_FOUND && has_session && method != "initialize" {
            return Err(MCP_SESSION_EXPIRED.into());
        }
        if status.is_redirection() {
            return Err(format!(
                "{} sent Oby elsewhere (HTTP {}); the login stays with {}, so Oby doesn't follow.",
                c.host(),
                status.as_u16(),
                c.host()
            ));
        }
        if !status.is_success() {
            return Err(format!("{} answered HTTP {}.", c.host(), status.as_u16()));
        }
        let session = response
            .headers()
            .get("Mcp-Session-Id")
            .and_then(|x| x.to_str().ok())
            .map(str::to_owned);
        let is_sse = response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|x| x.to_str().ok())
            .is_some_and(|x| x.contains("text/event-stream"));
        let bytes = response.bytes().await.map_err(|e| e.to_string())?;
        if bytes.len() > LONGEST {
            return Err("The connected server's answer was too large.".into());
        }
        if let Some(session) = session {
            self.upstreams
                .lock()
                .await
                .entry(key.clone())
                .or_default()
                .session = Some(session);
        }
        if method.starts_with("notifications/") {
            return Ok(None);
        }
        let Some(expected_id) = expected_id else {
            return Err(format!("{} didn't answer.", c.name));
        };
        let answers: Vec<Vec<u8>> = if is_sse {
            String::from_utf8_lossy(&bytes)
                .replace("\r\n", "\n")
                .split("\n\n")
                .filter_map(|part| {
                    let data = part
                        .lines()
                        .filter_map(|l| l.strip_prefix("data:").map(str::trim_start))
                        .collect::<Vec<_>>()
                        .join("\n");
                    (!data.is_empty()).then(|| data.into_bytes())
                })
                .collect()
        } else {
            vec![bytes.to_vec()]
        };
        for answer in answers {
            let Ok(value) = serde_json::from_slice::<Value>(&answer) else {
                continue;
            };
            if value.get("id") == Some(&expected_id) {
                if let Some(error) = value.get("error") {
                    return Err(format!(
                        "{} said: {}.",
                        c.name,
                        error
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("an error")
                    ));
                }
                return Ok(value.get("result").cloned().or(Some(json!({}))));
            }
        }
        Err(format!("{} didn't answer.", c.name))
    }

    async fn authorized(
        &self,
        c: &Connection,
        req: reqwest::RequestBuilder,
    ) -> Result<reqwest::RequestBuilder, String> {
        let value = self
            .vault_value(&c.secret)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("The vault has no secret named {}.", c.secret))?;
        if value.contains(['\n', '\r']) {
            return Err(format!(
                "The vault secret {} spans lines, so it can't go in a header.",
                c.secret
            ));
        }
        let req = if c
            .header
            .as_deref()
            .is_some_and(|h| !h.eq_ignore_ascii_case("authorization"))
        {
            req.header(c.header.as_deref().unwrap(), value)
        } else {
            req.bearer_auth(value)
        };
        Ok(req)
    }

    async fn call(&self, id: &str, name: &str, args: Value) -> Value {
        let Some(c) = self
            .usable(id)
            .into_iter()
            .filter(|c| name.starts_with(&format!("{}_", c.name)))
            .max_by_key(|c| c.name.len())
        else {
            return failure(format!(
                "There's no connected app with a tool named {name}."
            ));
        };
        let tool = name[c.name.len() + 1..].to_owned();
        let access = if c.api.is_some() {
            if tool == "get" {
                "read"
            } else if tool == "send" {
                "write"
            } else {
                return failure(format!("{} has no tool {tool}.", c.name));
            }
        } else {
            let Ok(mut tools) = self.upstream_tools(id, &c, false).await else {
                return failure(format!("Oby couldn't reach {}.", c.name));
            };
            if !tools.contains_key(&tool) {
                let Ok(updated) = self.upstream_tools(id, &c, true).await else {
                    return failure(format!("Oby couldn't reach {}.", c.name));
                };
                tools = updated;
            }
            let Some(found) = tools.get(&tool) else {
                return failure(format!("{} has no tool {tool}.", c.name));
            };
            access(&tool, found)
        };
        let use_record = ConnectionUse {
            job: id.to_owned(),
            connection: c.name.clone(),
            tool: tool.clone(),
            access: access.into(),
            allowed: access == "read",
            secret: c.secret.clone(),
            host: c.host(),
            date: obi_protocol::time::format(obi_protocol::time::now()),
        };
        self.record(use_record);
        if access != "read" {
            return failure(ACTING);
        }
        if c.api.is_some() {
            self.api_get(&c, &args).await
        } else {
            self.upstream_rpc(
                id,
                &c,
                "tools/call",
                json!({"name":tool,"arguments":args}),
            )
            .await
        }
        .unwrap_or_else(|e| {
            json!({"content":[{"type":"text","text":format!("Oby couldn't reach {}: {e}",c.name)}],"isError":true})
        })
    }

    async fn api_get(&self, c: &Connection, args: &Value) -> Result<Value, String> {
        let path = args.get("path").and_then(Value::as_str).unwrap_or("");
        let query = args.get("query").and_then(Value::as_object);
        let Some(url) = api_url(c, path, query) else {
            return Ok(failure(format!(
                "The path starts with / and stays on {}, like /v1/me.",
                c.host()
            )));
        };
        let response = self
            .authorized(c, self.client.get(url))
            .await?
            .send()
            .await
            .map_err(|e| e.to_string())?;
        let status = response.status();
        if status.is_redirection() {
            return Ok(failure(format!(
                "{} sent Oby elsewhere (HTTP {}); the login stays with {}, so Oby doesn't follow.",
                c.host(),
                status.as_u16(),
                c.host()
            )));
        }
        let bytes = response.bytes().await.map_err(|e| e.to_string())?;
        let cut = bytes.len() > LONGEST;
        let text = String::from_utf8_lossy(&bytes[..bytes.len().min(LONGEST)]);
        Ok(
            json!({"content":[{"type":"text","text":format!("HTTP {}\n\n{}{}",status.as_u16(),text,if cut { format!("\n\n(cut at {LONGEST} bytes)") } else { String::new() })}],"isError":status.is_client_error()||status.is_server_error()}),
        )
    }

    fn clean(&self, value: Value) -> Value {
        fn scrub(value: Value, secrets: &crate::secrets::Secrets) -> Value {
            match value {
                Value::String(s) => Value::String(secrets.redact(&s)),
                Value::Array(xs) => {
                    Value::Array(xs.into_iter().map(|x| scrub(x, secrets)).collect())
                }
                Value::Object(xs) => Value::Object(
                    xs.into_iter()
                        .map(|(k, v)| (secrets.redact(&k), scrub(v, secrets)))
                        .collect(),
                ),
                x => x,
            }
        }
        scrub(value, &crate::secrets::known())
    }
}

/// Where the use log before this one is kept: `uses.1.jsonl` next to `uses.jsonl`.
fn previous_log(file: &Path) -> PathBuf {
    file.with_extension("1.jsonl")
}

/// `use_record` added to a job's report, which keeps the latest [`KEPT_USES`].
pub fn keep_use(uses: &mut Vec<ConnectionUse>, use_record: ConnectionUse) {
    uses.push(use_record);
    if uses.len() > KEPT_USES {
        uses.drain(..uses.len() - KEPT_USES);
    }
}

/// The connections in `file`, each one `problem` lets through (so `Connection::url` never fails
/// on one); the others are left out.
fn load(file: &Path) -> Vec<Connection> {
    let all = std::fs::read(file)
        .ok()
        .and_then(|b| serde_json::from_slice::<Vec<Connection>>(&b).ok())
        .unwrap_or_default();
    // Logged by name only: a hand-edited URL could hold a login.
    all.into_iter()
        .filter(|c| {
            let fine = c.problem().is_none();
            if !fine {
                tracing::error!(
                    "left connection {:?} out of {}: it wouldn't save",
                    c.name,
                    file.display()
                );
            }
            fine
        })
        .collect()
}

fn connection_json(connection: &Connection, saved: bool, last_used: Option<&String>) -> Value {
    json!({"name": connection.name, "mcp": connection.mcp, "api": connection.api, "secret": connection.secret,
        "header": connection.header.as_deref().unwrap_or("Authorization"), "created": connection.created,
        "secretSaved": saved, "lastUsed": last_used})
}

/// Read or write: read only when the tool says it's read-only (MCP's `readOnlyHint`) and its
/// name has no word that acts (a server's hint is only a hint). Words split as Broker.swift's
/// `access` splits them: at a lower-case letter or digit followed by a capital, and at anything
/// that isn't a letter.
fn access(name: &str, tool: &Value) -> &'static str {
    let mut words = String::with_capacity(name.len() + 8);
    let mut previous: Option<char> = None;
    for c in name.chars() {
        if c.is_ascii_uppercase()
            && previous.is_some_and(|p| p.is_ascii_lowercase() || p.is_ascii_digit())
        {
            words.push('_');
        }
        words.push(c.to_ascii_lowercase());
        previous = Some(c);
    }
    let acting = [
        "send", "post", "create", "delete", "remove", "pay", "update", "write", "edit", "reply",
        "publish", "upload", "transfer", "invite", "archive", "merge", "comment", "put", "patch",
        "set", "add", "move",
    ];
    let suspicious = words
        .split(|c: char| !c.is_ascii_alphabetic())
        .any(|w| acting.contains(&w));
    if tool
        .get("annotations")
        .and_then(|a| a.get("readOnlyHint"))
        .and_then(Value::as_bool)
        == Some(true)
        && tool
            .get("annotations")
            .and_then(|a| a.get("destructiveHint"))
            .and_then(Value::as_bool)
            != Some(true)
        && !suspicious
    {
        "read"
    } else {
        "write"
    }
}

fn api_tools(c: &Connection) -> Vec<Value> {
    let base = c.api.as_deref().unwrap_or_default();
    vec![
        json!({"name":format!("{}_get",c.name),"description":format!("{} (through Oby): GET a path of {base} with the user's login. Answers with the status and the body.",c.name),"inputSchema":{"type":"object","properties":{"path":{"type":"string","description":format!("The path under {base}, starting with /, like /v1/me.")},"query":{"type":"object","additionalProperties":{"type":"string"},"description":"Query parameters."}},"required":["path"]},"annotations":{"readOnlyHint":true}}),
        json!({"name":format!("{}_send",c.name),"description":format!("{} (through Oby): POST, PUT, PATCH or DELETE as the user. Acts as the user, so Oby refuses it for now.",c.name),"inputSchema":{"type":"object","properties":{"method":{"type":"string","enum":["POST","PUT","PATCH","DELETE"]},"path":{"type":"string"}},"required":["method","path"]},"annotations":{"readOnlyHint":false}}),
    ]
}

/// The URL an API connection's `get` asks: `path` under its base URL, with `query` (string
/// values only, sorted). None when the path isn't one (`valid_api_path`), or when the URL it makes
/// would leave the connection's scheme, host or port (Broker.swift's `url`).
fn api_url(
    c: &Connection,
    path: &str,
    query: Option<&serde_json::Map<String, Value>>,
) -> Option<reqwest::Url> {
    if !valid_api_path(path) {
        return None;
    }
    let base = c.url();
    let mut url = base.clone();
    let base_path = base.path().trim_end_matches('/');
    url.set_path(&format!("{base_path}{path}"));
    let mut query: Vec<_> = query
        .into_iter()
        .flatten()
        .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned())))
        .collect();
    query.sort();
    if !query.is_empty() {
        url.query_pairs_mut().extend_pairs(query);
    }
    (url.scheme() == base.scheme()
        && url.host_str() == base.host_str()
        && url.port_or_known_default() == base.port_or_known_default())
    .then_some(url)
}

fn valid_api_path(path: &str) -> bool {
    path.starts_with('/')
        && !path.starts_with("//")
        && path
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"/-._~!$&'()*+,;=:@%".contains(&b))
        && {
            let b = path.as_bytes();
            let mut i = 0;
            while i < b.len() {
                if b[i] == b'%' {
                    if i + 2 >= b.len()
                        || !b[i + 1].is_ascii_hexdigit()
                        || !b[i + 2].is_ascii_hexdigit()
                    {
                        return false;
                    }
                    i += 3
                } else {
                    i += 1
                }
            }
            true
        }
}
fn failure(text: impl Into<String>) -> Value {
    json!({"content":[{"type":"text","text":text.into()}],"isError":true})
}

fn write_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let parent = path.parent().unwrap();
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)?;
    let tmp = parent.join(format!(".connections-{}.tmp", uuid::Uuid::new_v4()));
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)?;
    use std::io::Write;
    f.write_all(data)?;
    f.sync_all()?;
    std::fs::rename(tmp, path)
}
fn append_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
    let parent = path.parent().unwrap();
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)?;
    let uid = nix::unistd::geteuid().as_raw();
    let directory = std::fs::symlink_metadata(parent)?;
    if !directory.is_dir()
        || directory.file_type().is_symlink()
        || directory.mode() & 0o077 != 0
        || directory.uid() != uid
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "the vault folder isn't private",
        ));
    }
    let mut f = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = f.metadata()?;
    if !metadata.is_file() || metadata.mode() & 0o077 != 0 || metadata.uid() != uid {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "the vault use log isn't private",
        ));
    }
    use std::io::Write;
    f.write_all(data)?;
    f.sync_data()
}

pub fn router() -> Router<Arc<Shared>> {
    Router::new()
        .route("/v1/connections", get(list).post(add))
        .route("/v1/connections/{name}", axum::routing::delete(remove))
        .route("/v1/agent/mcp/{job}", post(agent_mcp))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Add {
    name: String,
    mcp: Option<String>,
    api: Option<String>,
    secret: String,
    header: Option<String>,
    approval: Option<Value>,
    value: Option<String>,
}
async fn list(State(shared): State<Arc<Shared>>) -> Result<Json<Value>, ApiError> {
    Ok(Json(shared.connections.list_json()?))
}
async fn add(State(shared): State<Arc<Shared>>, Json(body): Json<Add>) -> Response {
    if body.value.is_some() {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!(
                "The API never takes a secret value. Add it to the vault first: `obid vault --config <path> add {}`, the value on stdin.",
                body.secret
            ),
        )
        .into_response();
    }
    let connection = Connection {
        name: body.name,
        mcp: body.mcp,
        api: body.api,
        secret: body.secret,
        header: body.header,
        created: obi_protocol::time::format(obi_protocol::time::now()),
    };
    if let Some(problem) = connection.problem() {
        return ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, problem).into_response();
    }
    let action = connection.action();
    let connection_name = connection.name.clone();
    if body
        .approval
        .as_ref()
        .is_none_or(|a| !shared.devices.approves_connection(a, &action))
    {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({"error":"Connect this app on your phone first.","action":action})),
        )
            .into_response();
    }
    match shared.connections.save(connection) {
        Ok(()) => match shared.connections.list_json() {
            Ok(list) => {
                let saved = list.as_array().and_then(|items| {
                    items
                        .iter()
                        .find(|item| item["name"] == connection_name)
                        .cloned()
                });
                saved.map_or_else(
                    || {
                        ApiError::new(
                            StatusCode::INTERNAL_SERVER_ERROR,
                            "Saved connection is missing.",
                        )
                        .into_response()
                    },
                    |item| (StatusCode::CREATED, Json(item)).into_response(),
                )
            }
            Err(error) => error.into_response(),
        },
        Err(e) => ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, e).into_response(),
    }
}
async fn remove(
    State(shared): State<Arc<Shared>>,
    UrlPath(name): UrlPath<String>,
    body: Option<Json<Value>>,
) -> Response {
    if !shared.connections.contains(&name) {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "There's no connection with that name.",
        )
        .into_response();
    }
    let action = Connection::removal(&name);
    let approval = body.as_ref().and_then(|Json(v)| v.get("approval")).cloned();
    if approval
        .as_ref()
        .is_none_or(|a| !shared.devices.approves_connection(a, &action))
    {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({"error":"Disconnect this app on your phone first.","action":action})),
        )
            .into_response();
    }
    match shared.connections.remove(&name) {
        Ok(true) => (StatusCode::OK, Json(json!({"removed":name}))).into_response(),
        Ok(false) => ApiError::new(
            StatusCode::NOT_FOUND,
            "There's no connection with that name.",
        )
        .into_response(),
        Err(e) => ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}
async fn agent_mcp(
    State(shared): State<Arc<Shared>>,
    UrlPath(job): UrlPath<String>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .unwrap_or("");
    if !shared.connections.allows(&job, token) {
        return ApiError::new(StatusCode::UNAUTHORIZED, crate::api::NO_TOKEN).into_response();
    }
    let value = serde_json::from_slice::<Value>(&body).unwrap_or(Value::Null);
    if value.get("method").and_then(Value::as_str) == Some("notifications/initialized") {
        return StatusCode::ACCEPTED.into_response();
    }
    match shared.connections.handle(&job, value).await {
        Some(answer) => (StatusCode::OK, Json(answer)).into_response(),
        None => StatusCode::ACCEPTED.into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn folder(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("obid-connections-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    std::thread_local! {
        /// This test's vault: its secrets, or none when it can't be read.
        static VAULT: std::cell::RefCell<Option<HashMap<String, String>>> =
            std::cell::RefCell::new(Some(HashMap::new()));
    }

    /// What `crate::vault::value` answers, from this thread's [`VAULT`].
    fn fake_vault(name: &str) -> Result<Option<String>, String> {
        VAULT.with(|v| match &*v.borrow() {
            Some(secrets) => Ok(secrets.get(name).cloned()),
            None => Err("the vault can't be read: test".into()),
        })
    }

    /// This test's vault holds `secrets` (the vault itself is #570's, tested in vault.rs).
    fn vault(_home: &Path, secrets: &[(&str, &str)]) {
        let all = secrets
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect();
        VAULT.with(|v| *v.borrow_mut() = Some(all));
    }

    fn connection(name: &str, mcp: &str, secret: &str) -> Connection {
        Connection {
            name: name.into(),
            mcp: Some(mcp.into()),
            api: None,
            secret: secret.into(),
            header: None,
            created: "2026-10-16T00:00:00Z".into(),
        }
    }

    /// A broker over `home` with `all` connected, and no jobs to ask.
    fn broker(home: &Path, all: Vec<Connection>) -> Connections {
        Connections {
            file: home.join("connections.json"),
            uses_file: home.join("vault/uses.jsonl"),
            uses_max: 1024,
            vault: fake_vault,
            all: Mutex::new(all),
            last_used: Mutex::new(HashMap::new()),
            tokens: Mutex::new(HashMap::new()),
            snapshots: Mutex::new(HashMap::new()),
            upstreams: tokio::sync::Mutex::new(HashMap::new()),
            jobs: Weak::new(),
            client: reqwest::Client::new(),
            api_url: "http://127.0.0.1:7777".into(),
            next_id: std::sync::atomic::AtomicU64::new(1),
        }
    }

    /// ConnectionTests.onlyReadOnlyToolsThatDontActAreReads, and the names whose acting word
    /// starts with a capital or ends at a digit.
    #[test]
    fn only_read_only_tools_that_dont_act_are_reads() {
        let read = json!({"annotations": {"readOnlyHint": true}});
        for name in [
            "search_threads",
            "getProfile",
            "list_posts",
            "whoami",
            "v2Search",
        ] {
            assert_eq!(access(name, &read), "read", "{name}");
        }
        assert_eq!(access("search_threads", &json!({})), "write");
        assert_eq!(
            access(
                "search",
                &json!({"annotations": {"readOnlyHint": true, "destructiveHint": true}})
            ),
            "write"
        );
        for acting in [
            "send_email",
            "createIssue",
            "delete-file",
            "pay_invoice",
            "post_message",
            "replyToThread",
            "SendEmail",
            "draftSend",
            "messageSend",
            "threadReply",
            "send2",
            "FILE_UPLOAD",
        ] {
            assert_eq!(access(acting, &read), "write", "{acting}");
        }
    }

    /// ConnectionTests.anAPIsPathStaysOnItsHost.
    #[test]
    fn an_apis_path_stays_on_its_host() {
        let api = Connection {
            name: "people".into(),
            mcp: None,
            api: Some("https://api.example.com/v2".into()),
            secret: "people-key".into(),
            header: Some("X-Api-Key".into()),
            created: String::new(),
        };
        let query = json!({"fields": "name email", "n": 3});
        assert_eq!(
            api_url(&api, "/me", query.as_object()).unwrap().as_str(),
            "https://api.example.com/v2/me?fields=name+email"
        );
        for path in [
            "//evil.example/x",
            "me",
            "/a b",
            "/x%zz",
            "/x%2",
            "http://evil.example/",
            "/\\evil.example",
            "",
        ] {
            assert!(api_url(&api, path, None).is_none(), "{path}");
        }
        for path in [
            "/@evil.example",
            "/../../../evil.example",
            "/%2e%2e/%2fevil.example",
        ] {
            let url = api_url(&api, path, None).unwrap();
            assert_eq!(url.host_str(), Some("api.example.com"), "{path}: {url}");
            assert_eq!(url.scheme(), "https", "{path}");
        }
    }

    /// The URLs and headers a connection refuses (422): the secret never goes in the clear, to a
    /// login in the URL, to a header that isn't the secret's own, or under a name a tool's
    /// `<connection>_<tool>` couldn't split from.
    #[test]
    fn connections_that_could_send_the_secret_elsewhere_are_refused() {
        let good = connection("mail", "https://mail.example.com/mcp", "mail-token");
        assert_eq!(good.problem(), None);
        let local = connection("local", "http://127.0.0.1:9/mcp", "mail-token");
        assert_eq!(local.problem(), None);
        let mut wrong = vec![
            connection("web", "http://example.com/mcp", "mail-token"),
            connection("web", "http://127.0.0.1.example.com/mcp", "mail-token"),
            connection("Mail_2", "https://example.com/mcp", "mail-token"),
            connection("", "https://example.com/mcp", "mail-token"),
            connection("-mail", "https://example.com/mcp", "mail-token"),
            connection("mail", "https://user:pw@example.com/mcp", "mail-token"),
            connection("mail", "https://example.com/mcp?key=1", "mail-token"),
            connection("mail", "https://example.com/mcp#x", "mail-token"),
            connection("mail", "ftp://example.com/mcp", "mail-token"),
            connection("mail", "not a url", "mail-token"),
            connection("mail", "https://example.com/mcp", "../secret"),
            connection("mail", "https://example.com/mcp", ""),
        ];
        let mut both = good.clone();
        both.api = Some("https://example.com".into());
        wrong.push(both);
        let mut neither = good.clone();
        neither.mcp = None;
        wrong.push(neither);
        for header in [
            "Host",
            "cookie",
            "Content-Length",
            "Mcp-Session-Id",
            "X Key",
            "",
        ] {
            let mut c = good.clone();
            c.header = Some(header.into());
            wrong.push(c);
        }
        for c in wrong {
            assert!(c.problem().is_some(), "{c:?}");
        }
    }

    /// The sentence the phone signs names the URL the secret goes to, as it goes: a URL that
    /// reads one way and parses another (a backslash, a tab or newline, a look-alike or upper-case
    /// host, a missing `/`) is refused, and the refusal says how to write it.
    #[test]
    fn the_signed_sentence_names_where_the_secret_goes() {
        for (text, goes) in [
            (
                "https://evil.example\\@slack.com/mcp",
                "https://evil.example/@slack.com/mcp",
            ),
            (
                "https://slack.com\n.evil.example/mcp",
                "https://slack.com.evil.example/mcp",
            ),
            (
                "https://slack.com\t.evil.example/mcp",
                "https://slack.com.evil.example/mcp",
            ),
            (
                "https://sl\u{0430}ck.com/mcp",
                "https://xn--slck-63d.com/mcp",
            ),
            ("https://Slack.com/mcp", "https://slack.com/mcp"),
            ("https://slack.com", "https://slack.com/"),
            ("https://slack.com:443/mcp", "https://slack.com/mcp"),
            (" https://slack.com/mcp", "https://slack.com/mcp"),
            ("https://slack.com/a/../mcp", "https://slack.com/mcp"),
        ] {
            let c = connection("mail", text, "mail-token");
            let problem = c
                .problem()
                .unwrap_or_else(|| panic!("{text:?} was let through"));
            assert!(problem.contains(goes), "{text:?}: {problem}");
            let mut api = c.clone();
            (api.mcp, api.api) = (None, Some(text.into()));
            assert!(api.problem().is_some(), "{text:?} as an API");
        }
        // Written the way it's read: the host the secret goes to, in its ASCII (xn--) form.
        let idn = connection("mail", "https://xn--slck-63d.com/mcp", "mail-token");
        assert_eq!(idn.problem(), None);
        assert!(
            idn.action()
                .contains("the MCP server https://xn--slck-63d.com/mcp "),
            "{}",
            idn.action()
        );
        assert_eq!(idn.host(), "xn--slck-63d.com");
    }

    /// When the vault can't be read, the broker fails closed: no secret, no broker for a job,
    /// no list (`503`), no call with a login.
    #[test]
    fn a_vault_that_cant_be_read_fails_closed() {
        let home = folder("unreadable");
        let mail = connection("mail", "https://mail.example.com/mcp", "mail-token");
        vault(&home, &[("mail-token", "mail-0123456789")]);
        let broker = broker(&home, vec![mail.clone()]);
        assert_eq!(
            broker.vault_value("mail-token"),
            Ok(Some("mail-0123456789".into()))
        );
        VAULT.with(|v| *v.borrow_mut() = None);
        assert!(broker.vault_value("mail-token").is_err());
        assert_eq!(broker.open_job("job1"), None);
        assert!(broker.list_json().is_err());
        let rt = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        assert!(
            rt.block_on(broker.authorized(&mail, reqwest::Client::new().get(mail.url())))
                .is_err()
        );
    }

    /// A job uses the connections it started with: one added since never reaches it, and one
    /// replaced or removed since stops at once. Each job has its own token, and an ended job's
    /// goes.
    #[test]
    fn a_job_keeps_the_connections_it_started_with() {
        let home = folder("snapshot");
        vault(
            &home,
            &[
                ("mail-token", "mail-0123456789"),
                ("people-key", "people-0123456789"),
            ],
        );
        let mail = connection("mail", "https://mail.example.com/mcp", "mail-token");
        let people = connection("people", "https://people.example.com/mcp", "people-key");
        let broker = broker(&home, vec![mail.clone(), people.clone()]);
        let names =
            |job: &str| -> Vec<String> { broker.usable(job).into_iter().map(|c| c.name).collect() };
        let (url, token) = broker.open_job("job1").unwrap();
        assert_eq!(url, "http://127.0.0.1:7777/v1/agent/mcp/job1");
        assert_eq!(broker.open_job("job1").unwrap().1, token, "one token a job");
        assert_eq!(names("job1"), ["mail", "people"]);

        let evil = connection("evil", "https://evil.example.com/mcp", "mail-token");
        let mut replaced = people.clone();
        replaced.secret = "mail-token".into();
        *broker.all.lock().unwrap() = vec![evil, mail.clone(), replaced];
        assert_eq!(names("job1"), ["mail"], "added and replaced since");
        let (_, other) = broker.open_job("job2").unwrap();
        assert_ne!(other, token);
        assert_eq!(names("job2"), ["evil", "mail", "people"]);

        *broker.all.lock().unwrap() = vec![];
        assert!(names("job1").is_empty(), "removed since");
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(broker.close_job("job1"));
        let tokens = broker.tokens.lock().unwrap();
        assert!(!tokens.contains_key(&token) && tokens.contains_key(&other));
    }

    /// A connections file with an entry no API request could have saved (edited by hand, or by
    /// an older runner) loads without it, instead of failing a request later.
    #[test]
    fn a_connection_that_wouldnt_save_doesnt_load() {
        let home = folder("load");
        let file = home.join("connections.json");
        let good = connection("mail", "https://mail.example.com/mcp", "mail-token");
        let bad = [
            connection("web", "not a url", "mail-token"),
            connection("plain", "http://example.com/mcp", "mail-token"),
            connection(
                "slack",
                "https://evil.example\\@slack.com/mcp",
                "mail-token",
            ),
        ];
        let mut all = vec![good.clone()];
        all.extend(bad);
        std::fs::write(&file, serde_json::to_vec(&all).unwrap()).unwrap();
        assert_eq!(load(&file), [good]);
        std::fs::write(&file, b"not json").unwrap();
        assert!(load(&file).is_empty());
    }

    /// The job's report keeps its latest calls and the use log starts again when full, the one
    /// before kept: neither grows without end, and the last use of each connection survives it.
    #[test]
    fn the_use_records_are_bounded() {
        let one = |n: usize| ConnectionUse {
            job: "job1".into(),
            connection: if n.is_multiple_of(2) {
                "mail"
            } else {
                "people"
            }
            .into(),
            tool: format!("tool{n}"),
            access: "read".into(),
            allowed: true,
            secret: "mail-token".into(),
            host: "mail.example.com".into(),
            date: format!("2026-10-16T00:{:02}:{:02}Z", n / 60 % 60, n % 60),
        };
        let mut uses = Vec::new();
        for n in 0..KEPT_USES + 7 {
            keep_use(&mut uses, one(n));
        }
        assert_eq!(uses.len(), KEPT_USES);
        assert_eq!(uses[0].tool, "tool7");
        assert_eq!(uses.last().unwrap().tool, format!("tool{}", KEPT_USES + 6));

        let home = folder("uses");
        vault(&home, &[]);
        let broker = broker(&home, vec![]);
        for n in 0..200 {
            broker.record(one(n));
        }
        let log = home.join("vault/uses.jsonl");
        let before = home.join("vault/uses.1.jsonl");
        for file in [&log, &before] {
            let meta = std::fs::metadata(file).unwrap();
            assert!(
                meta.len() <= broker.uses_max,
                "{}: {}",
                file.display(),
                meta.len()
            );
            assert_eq!(meta.permissions().mode() & 0o777, 0o600);
        }
        let lines = |f: &Path| std::fs::read_to_string(f).unwrap().lines().count();
        assert!(lines(&log) > 0 && lines(&before) > 0);
        assert!(
            std::fs::read_to_string(&log)
                .unwrap()
                .contains("\"tool199\"")
        );
    }

    /// With nothing connected, or no secret in the vault for it, a job gets no broker.
    #[test]
    fn with_nothing_usable_agents_get_no_broker() {
        let home = folder("lonely");
        assert_eq!(broker(&home, vec![]).open_job("lonely"), None);
        let mail = connection("mail", "https://mail.example.com/mcp", "mail-token");
        assert_eq!(broker(&home, vec![mail.clone()]).open_job("lonely"), None);
        vault(&home, &[("other", "other-0123456789")]);
        assert_eq!(broker(&home, vec![mail]).open_job("lonely"), None);
    }
}
