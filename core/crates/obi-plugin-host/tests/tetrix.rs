//! `plugins/tetrix`, the first plug-in: an `agent-mcp` plug-in, disabled until the owner enables
//! it, offering only the Tetrix tools `Engine/Jobs.swift` (`Policy.tetrixTools`) allows today.
//! Tested against a stub Tetrix MCP server on 127.0.0.1: no login, no network.

mod common;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use common::{Home, id, options, status};
use obi_plugin_api::{Kind, MANIFEST_FILE, Manifest, McpServerSpec, PluginError, PluginState};
use obi_plugin_host::PluginHost;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// The tools `Policy.tetrixTools` in `Engine/Jobs.swift` allows (the frozen engine is the
/// specification for this plug-in).
const SWIFT_TETRIX_TOOLS: [&str; 13] = [
    "graph_summary",
    "search_entities",
    "get_entity",
    "operational_context",
    "impact_radius",
    "service_topology",
    "code_impact",
    "query_graph",
    "session_digest",
    "session_context",
    "repo_sessions",
    "list_sessions",
    "save_session",
];

fn shipped() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../plugins/tetrix")
}

fn shipped_manifest() -> Value {
    serde_json::from_str(&std::fs::read_to_string(shipped().join(MANIFEST_FILE)).unwrap()).unwrap()
}

/// Installs `plugins/tetrix` into `home` as it ships.
fn install_tetrix(home: &Home) {
    home.install_manifest("tetrix", &shipped_manifest());
}

#[test]
fn the_shipped_manifest_is_valid_and_offers_only_what_the_engine_allows() {
    let bytes = std::fs::read(shipped().join(MANIFEST_FILE)).unwrap();
    let manifest = Manifest::from_slice(&bytes, "tetrix").unwrap();
    assert_eq!(manifest.id.as_str(), "tetrix");
    assert_eq!(manifest.name, "Tetrix");
    assert_eq!(manifest.kinds, [Kind::AgentMcp]);
    assert_eq!(
        manifest.run, None,
        "an agent-mcp-only plug-in with nothing to run"
    );
    assert_eq!(manifest.events, None);
    let spec = manifest.agent_mcp.unwrap();
    // Its URL is the owner's setting `url`, required and with no default: the manifest names
    // no server and no host of its own.
    assert_eq!(
        spec.server,
        McpServerSpec::HttpFromConfig { key: "url".into() }
    );
    assert!(manifest.network.is_empty());
    let text = String::from_utf8(bytes).unwrap();
    for placeholder in ["tetrix.example", "https://", "http://"] {
        assert!(!text.contains(placeholder), "{placeholder} in {text}");
    }
    let mut allowed = spec.allowed_tools.clone();
    allowed.sort();
    let mut swift = SWIFT_TETRIX_TOOLS.map(str::to_owned).to_vec();
    swift.sort();
    assert_eq!(allowed, swift);
    assert!(
        !spec
            .allowed_tools
            .iter()
            .any(|tool| tool == "resume_session")
    );
    let config = manifest.config.unwrap();
    assert_eq!(config["required"], json!(["url"]));
    assert_eq!(config["properties"]["url"]["type"], json!("string"));
    assert!(config["properties"]["url"].get("default").is_none());
}

#[tokio::test]
async fn tetrix_is_disabled_until_enabled_and_disabled_like_any_plugin() {
    let home = Home::new("tetrix");
    install_tetrix(&home);
    let host = PluginHost::start_with(&home.path, options()).await.unwrap();

    let listed = serde_json::to_value(host.list()).unwrap();
    assert_eq!(
        listed,
        json!([{"id": "tetrix", "name": "Tetrix", "version": "0.1.0", "kinds": ["agent-mcp"],
                "enabled": false, "state": "disabled", "lastError": null}])
    );
    assert!(host.agent_mcp_servers().is_empty());

    // Enabling it without its URL is refused (the route's 422), and so is a URL that breaks the
    // rule for one, or other settings; none of it changes anything.
    for config in [
        None,
        Some(json!({})),
        Some(json!({"url": "https://user:secret@tetrix.example.test/mcp"})),
        Some(json!({"url": "https://tetrix.example.test/mcp?token=secret"})),
        Some(json!({"url": "ftp://tetrix.example.test/mcp"})),
        Some(json!({"url": "https://tetrix.example.test/mcp", "other": 1})),
    ] {
        assert!(
            matches!(
                host.set_enabled(&id("tetrix"), true, config.clone()).await,
                Err(PluginError::Config(_))
            ),
            "{config:?}"
        );
        assert_eq!(status(&host, "tetrix").state, PluginState::Disabled);
        assert!(!status(&host, "tetrix").enabled);
        assert_eq!(home.settings(), None);
        assert!(host.agent_mcp_servers().is_empty());
    }

    let url = "https://tetrix.example.test/mcp";
    let enabled = host
        .set_enabled(&id("tetrix"), true, Some(json!({"url": url})))
        .await
        .unwrap();
    assert!(enabled.enabled);
    assert_eq!(enabled.state, PluginState::Ready);
    let servers = host.agent_mcp_servers();
    assert_eq!(servers.len(), 1);
    assert_eq!(servers[0].0, id("tetrix"));
    assert_eq!(servers[0].1, McpServerSpec::Http { url: url.into() });
    assert_eq!(servers[0].2, SWIFT_TETRIX_TOOLS.map(str::to_owned).to_vec());
    assert_eq!(
        home.settings().unwrap(),
        json!({"tetrix": {"enabled": true, "config": {"url": url}}})
    );
    // No process, so nothing in plugin-data.
    assert!(!home.data_dir("tetrix").exists());

    let disabled = host.set_enabled(&id("tetrix"), false, None).await.unwrap();
    assert!(!disabled.enabled);
    assert_eq!(disabled.state, PluginState::Disabled);
    assert!(host.agent_mcp_servers().is_empty());
    assert_eq!(
        home.settings().unwrap(),
        json!({"tetrix": {"enabled": false, "config": {"url": url}}})
    );
    // Enabled again, it keeps the URL it was given.
    host.set_enabled(&id("tetrix"), true, None).await.unwrap();
    assert_eq!(
        host.agent_mcp_servers()[0].1,
        McpServerSpec::Http { url: url.into() }
    );
    host.shutdown().await;
}

/// What the stub Tetrix saw.
#[derive(Default)]
struct Seen {
    methods: Vec<String>,
    calls: Vec<String>,
    authorization: Vec<String>,
}

/// A stub Tetrix MCP server on 127.0.0.1: MCP's JSON-RPC over HTTP POST, one JSON answer each.
/// It lists the tools Tetrix has (more than agents may call) and answers every call with a
/// canned result. No login, no network beyond the loopback.
async fn stub_tetrix() -> (String, Arc<Mutex<Seen>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/mcp", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Seen::default()));
    let record = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                return;
            };
            let record = record.clone();
            tokio::spawn(async move { serve_one(stream, record).await });
        }
    });
    (url, seen)
}

async fn serve_one(mut stream: TcpStream, seen: Arc<Mutex<Seen>>) {
    let (head, body) = read_http(&mut stream).await;
    for line in head.lines() {
        if line.to_ascii_lowercase().starts_with("authorization:") {
            seen.lock().unwrap().authorization.push(line.to_owned());
        }
    }
    let request: Value = serde_json::from_slice(&body).unwrap();
    let method = request["method"].as_str().unwrap_or("").to_owned();
    seen.lock().unwrap().methods.push(method.clone());
    let result = match method.as_str() {
        "initialize" => json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "stub-tetrix", "version": "0.0.0"}
        }),
        "tools/list" => {
            let mut names: Vec<&str> = SWIFT_TETRIX_TOOLS.to_vec();
            names.extend([
                "resume_session",
                "admin_reap_orphans",
                "answer_hitl_question",
                "diagnostics_platform",
            ]);
            json!({"tools": names.iter().map(|name| json!({"name": name, "inputSchema": {"type": "object"}})).collect::<Vec<_>>()})
        }
        "tools/call" => {
            let tool = request["params"]["name"].as_str().unwrap_or("").to_owned();
            seen.lock().unwrap().calls.push(tool.clone());
            json!({"content": [{"type": "text", "text": format!("stub answer from {tool}")}]})
        }
        _ => json!({}),
    };
    let answer = json!({"jsonrpc": "2.0", "id": request["id"], "result": result}).to_string();
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{answer}",
        answer.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
}

/// Reads one HTTP message: its head and its body (by `Content-Length`, or to the end).
async fn read_http(stream: &mut TcpStream) -> (String, Vec<u8>) {
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 4096];
    loop {
        if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&bytes[..end]).into_owned();
            let length = head
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())?
                })
                .unwrap_or(usize::MAX);
            let mut body = bytes[end + 4..].to_vec();
            while body.len() < length {
                let n = stream.read(&mut buffer).await.unwrap_or(0);
                if n == 0 {
                    break;
                }
                body.extend_from_slice(&buffer[..n]);
            }
            return (head, body);
        }
        let n = stream.read(&mut buffer).await.unwrap_or(0);
        if n == 0 {
            return (String::from_utf8_lossy(&bytes).into_owned(), Vec::new());
        }
        bytes.extend_from_slice(&buffer[..n]);
    }
}

/// What an agent's MCP client does with the server the host gave it: one JSON-RPC request.
async fn call(url: &str, method: &str, params: Value) -> Value {
    let rest = url.strip_prefix("http://").unwrap();
    let (authority, path) = rest.split_once('/').unwrap();
    let mut stream = TcpStream::connect(authority).await.unwrap();
    let body = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).to_string();
    let request = format!(
        "POST /{path} HTTP/1.1\r\nHost: {authority}\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(request.as_bytes()).await.unwrap();
    let (head, body) = read_http(&mut stream).await;
    assert!(head.starts_with("HTTP/1.1 200"), "{head}");
    serde_json::from_slice::<Value>(&body).unwrap()["result"].clone()
}

#[tokio::test]
async fn an_enabled_tetrix_gives_agents_the_stub_server_and_only_the_allowed_tools() {
    let (url, seen) = stub_tetrix().await;
    let home = Home::new("stub-tetrix");
    install_tetrix(&home);
    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    assert_eq!(status(&host, "tetrix").state, PluginState::Disabled);
    assert!(host.agent_mcp_servers().is_empty());

    // The owner gives the stub's URL as Tetrix's setting.
    host.set_enabled(&id("tetrix"), true, Some(json!({"url": url})))
        .await
        .unwrap();
    let servers = host.agent_mcp_servers();
    let [(plugin, McpServerSpec::Http { url: given }, allowed)] = servers.as_slice() else {
        panic!("{servers:?}");
    };
    assert_eq!(plugin, &id("tetrix"));
    assert_eq!(given, &url);

    // An agent's client reaches the stub through what the host gave it.
    let started = call(given, "initialize", json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test-agent", "version": "0"}})).await;
    assert_eq!(started["serverInfo"]["name"], json!("stub-tetrix"));
    let listed = call(given, "tools/list", json!({})).await;
    let offered: Vec<String> = listed["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap().to_owned())
        .collect();
    // Every allowed tool is one Tetrix has; what Tetrix has beyond them isn't allowed.
    for tool in allowed {
        assert!(offered.contains(tool), "{tool} is not a Tetrix tool");
    }
    for tool in [
        "resume_session",
        "admin_reap_orphans",
        "answer_hitl_question",
        "diagnostics_platform",
    ] {
        assert!(offered.iter().any(|t| t == tool));
        assert!(!allowed.iter().any(|t| t == tool), "{tool} is allowed");
    }
    // A gate holding agents to `allowed`, as obid's does, lets these calls through.
    for tool in ["search_entities", "save_session"] {
        assert!(allowed.iter().any(|t| t == tool));
        let answer = call(given, "tools/call", json!({"name": tool, "arguments": {}})).await;
        assert_eq!(
            answer["content"][0]["text"],
            json!(format!("stub answer from {tool}"))
        );
    }
    {
        let seen = seen.lock().unwrap();
        assert_eq!(
            seen.methods,
            ["initialize", "tools/list", "tools/call", "tools/call"]
        );
        assert_eq!(seen.calls, ["search_entities", "save_session"]);
        // Nothing the host gave carries a login.
        assert!(seen.authorization.is_empty());
    }

    host.set_enabled(&id("tetrix"), false, None).await.unwrap();
    assert!(host.agent_mcp_servers().is_empty());
    host.shutdown().await;
}
