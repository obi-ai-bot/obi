//! Tetrix connected once in Oby for every agent (docs/runner-api.md, "obid only: Tetrix"): obid
//! signs in to a fake Tetrix and its fake OAuth server on 127.0.0.1, the job's agent reaches
//! Tetrix through obid without ever holding the login, and obid sends Tetrix the job's graph gaps.
//! Never the person's Keychain (support's fake `security`), ~/.claude, ~/.codex or Oby's home.

mod support;

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use serde_json::{Value, json};
use support::*;

const ACCESS_1: &str = "tetrix-access-0f9e8d7c6b5a49382716";
const ACCESS_2: &str = "tetrix-access-a1b2c3d4e5f60718293a";
const REFRESH_1: &str = "tetrix-refresh-5e4d3c2b1a0f9e8d7c6b";
const REFRESH_2: &str = "tetrix-refresh-9a8b7c6d5e4f30211203";

/// What the fake Tetrix was asked, and the state its login is in.
#[derive(Default)]
struct Seen {
    /// Every request: method, path, Authorization, body.
    requests: Vec<(String, String, String, String)>,
    challenge: String,
    access: String,
    refresh: String,
    /// The `save_session` calls' arguments.
    saved: Vec<Value>,
    /// How its earlier sessions answer: "" as they are, "leaky" listing one whose id holds a key,
    /// "slow" listing four whose context takes 9 seconds each: each call within its own 10
    /// seconds, all of them past the check's 30.
    mode: &'static str,
}

/// A key the secret scan flags, put together here so this file holds none.
fn made_up_key() -> String {
    ["AK", "IA", "QWERTYUIOPASDFGH"].concat()
}

fn reply(stream: &mut std::net::TcpStream, status: &str, kind: &str, body: &str) {
    let _ = write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
}

fn form(body: &str) -> std::collections::HashMap<String, String> {
    reqwest::Url::parse(&format!("http://x/?{body}"))
        .unwrap()
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect()
}

/// A fake Tetrix: RFC 9728 metadata, an authorization server whose RFC 8414 path isn't JSON (as
/// Keycloak's isn't) but whose OpenID discovery is, dynamic client registration, PKCE, refresh
/// with rotation, revocation, and an MCP server that wants the current access token and puts it
/// in its answers. The first access token lasts 30 seconds, so obid refreshes it.
fn fake_tetrix() -> (String, Arc<Mutex<Seen>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let seen = Arc::new(Mutex::new(Seen::default()));
    let state = seen.clone();
    let origin = base.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut request = String::new();
            let mut length = 0;
            let mut auth = String::new();
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    break;
                }
                let line = line.trim_end().to_owned();
                if request.is_empty() {
                    request = line.clone();
                }
                if line.is_empty() {
                    break;
                }
                if let Some((name, value)) = line.split_once(':') {
                    if name.eq_ignore_ascii_case("content-length") {
                        length = value.trim().parse().unwrap_or(0);
                    }
                    if name.eq_ignore_ascii_case("authorization") {
                        auth = value.trim().to_owned();
                    }
                }
            }
            let mut body = vec![0; length];
            let _ = reader.read_exact(&mut body);
            let body = String::from_utf8_lossy(&body).into_owned();
            let mut parts = request.split(' ');
            let method = parts.next().unwrap_or("").to_owned();
            let target = parts.next().unwrap_or("").to_owned();
            let path = target.split('?').next().unwrap_or("").to_owned();
            let mut seen = state.lock().unwrap();
            seen.requests
                .push((method.clone(), target.clone(), auth.clone(), body.clone()));
            let issuer = format!("{origin}/auth");
            match (method.as_str(), path.as_str()) {
                // A server whose metadata is for another one: obid must not sign in there.
                ("GET", "/.well-known/oauth-protected-resource/evil-mcp") => reply(
                    &mut stream,
                    "200 OK",
                    "application/json",
                    &json!({"resource": "https://other.example/mcp", "authorization_servers": [issuer]})
                        .to_string(),
                ),
                // Only where its 401 says: obid must read the challenge.
                ("GET", "/meta/tetrix-resource") => reply(
                    &mut stream,
                    "200 OK",
                    "application/json",
                    &json!({"resource": format!("{origin}/mcp"), "authorization_servers": [issuer],
                        "scopes_supported": ["graph:read", "sessions:write", "hitl:write"]})
                    .to_string(),
                ),
                ("GET", "/.well-known/oauth-authorization-server/auth") => {
                    reply(&mut stream, "200 OK", "text/html", "<html>not JSON</html>")
                }
                ("GET", "/auth/.well-known/openid-configuration") => reply(
                    &mut stream,
                    "200 OK",
                    "application/json",
                    &json!({"issuer": issuer, "authorization_endpoint": format!("{issuer}/authorize"),
                        "token_endpoint": format!("{issuer}/token"), "registration_endpoint": format!("{issuer}/register"),
                        "revocation_endpoint": format!("{issuer}/revoke"), "code_challenge_methods_supported": ["S256"]})
                    .to_string(),
                ),
                ("POST", "/auth/register") => reply(
                    &mut stream,
                    "201 Created",
                    "application/json",
                    r#"{"client_id": "oby-dynamic-1"}"#,
                ),
                ("GET", "/auth/authorize") => {
                    let query = form(target.split_once('?').map_or("", |(_, q)| q));
                    seen.challenge = query.get("code_challenge").cloned().unwrap_or_default();
                    reply(&mut stream, "200 OK", "text/html", "<p>Sign in</p>");
                }
                ("POST", "/auth/token") => {
                    let asked = form(&body);
                    let answer = match asked.get("grant_type").map(String::as_str) {
                        Some("authorization_code")
                            if asked.get("code").map(String::as_str) == Some("the-code")
                                && asked.get("client_id").map(String::as_str)
                                    == Some("oby-dynamic-1")
                                && base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
                                    obi_protocol::keys::sha256(
                                        asked.get("code_verifier").cloned().unwrap_or_default(),
                                    ),
                                ) == seen.challenge =>
                        {
                            seen.access = ACCESS_1.into();
                            seen.refresh = REFRESH_1.into();
                            Some(
                                json!({"access_token": ACCESS_1, "refresh_token": REFRESH_1, "expires_in": 30,
                                "scope": "graph:read sessions:write hitl:write offline_access"}),
                            )
                        }
                        Some("refresh_token")
                            if asked.get("refresh_token") == Some(&seen.refresh)
                                && seen.refresh == REFRESH_1 =>
                        {
                            seen.access = ACCESS_2.into();
                            seen.refresh = REFRESH_2.into();
                            Some(
                                json!({"access_token": ACCESS_2, "refresh_token": REFRESH_2, "expires_in": 3600}),
                            )
                        }
                        _ => None,
                    };
                    match answer {
                        Some(answer) => {
                            reply(&mut stream, "200 OK", "application/json", &answer.to_string())
                        }
                        None => reply(
                            &mut stream,
                            "400 Bad Request",
                            "application/json",
                            r#"{"error": "invalid_grant"}"#,
                        ),
                    }
                }
                ("POST", "/auth/revoke") => reply(&mut stream, "200 OK", "application/json", "{}"),
                ("POST", "/mcp") => {
                    if seen.access.is_empty() || auth != format!("Bearer {}", seen.access) {
                        reply(
                            &mut stream,
                            &format!("401 Unauthorized\r\nWWW-Authenticate: Bearer error=\"invalid_token\", resource_metadata=\"{origin}/meta/tetrix-resource\""),
                            "application/json",
                            "{}",
                        );
                        continue;
                    }
                    let message: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
                    let id = message["id"].clone();
                    let tool = message["params"]["name"].as_str().unwrap_or("").to_owned();
                    let leak = format!("seen with Bearer {}", seen.access);
                    let result = match message["method"].as_str().unwrap_or("") {
                        "initialize" => json!({"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                            "serverInfo": {"name": "tetrix", "version": "1"}}),
                        "tools/list" => {
                            let tools: Vec<Value> = ["search_entities", "get_entity", "repo_sessions",
                                "session_context", "session_digest", "save_session", "resume_session",
                                "admin_wipe_graph"].iter()
                                .map(|name| json!({"name": name, "description": name, "inputSchema": {"type": "object"}}))
                                .collect();
                            json!({"tools": tools})
                        }
                        "tools/call" => match tool.as_str() {
                            "search_entities" => {
                                let query = message["params"]["arguments"]["query"].as_str().unwrap_or("");
                                if query == "where is the nothing" {
                                    json!({"content": [{"type": "text", "text": json!({"query": query, "count": 0, "entities": []}).to_string()}]})
                                } else {
                                    json!({"content": [{"type": "text", "text": json!({"query": query, "count": 1,
                                        "entities": [{"name": "obi-e2e/fixture-app#src/index.js", "note": leak}]}).to_string()}]})
                                }
                            }
                            // The shapes of mcp_service/app/tools/{repo_sessions,session_context,
                            // session_digest}.py.
                            "repo_sessions" => {
                                let ids = match seen.mode {
                                    "leaky" => vec![made_up_key()],
                                    "slow" => (1..=4).map(|n| format!("agent_session:g{n}")).collect(),
                                    _ => vec!["agent_session:g1".to_owned()],
                                };
                                let sessions: Vec<Value> = ids.iter().map(|id| json!({"session_id": id, "title": "Earlier work", "edge_type": "worked_on"})).collect();
                                json!({"content": [{"type": "text", "text": json!({"target": {"id": "r1", "name": "obi-e2e/fixture-app", "type": "repo"},
                                    "count": sessions.len(), "sessions": sessions,
                                    "truncated": false, "has_more": false, "next_cursor": null}).to_string()}]})
                            }
                            "session_context" => {
                                if seen.mode == "slow" {
                                    std::thread::sleep(std::time::Duration::from_secs(9));
                                }
                                json!({"content": [{"type": "text", "text": json!({"id": "agent_session:g1",
                                "natural_key": "session:acme/5b0e7c1a-9d2f-4c3e-8a1b-2f3e4d5c6b7a", "title": "Earlier work",
                                "digest_summary": {"decisions": 1}, "worked_on": [], "produced": [], "references": []}).to_string()}]})
                            }
                            "session_digest" => {
                                json!({"content": [{"type": "text", "text": json!({"session_id": "5b0e7c1a-9d2f-4c3e-8a1b-2f3e4d5c6b7a",
                                    "audience": "org", "has_digest": true, "digest": {"schema_version": 1,
                                    "projects": [{"repo": "obi-e2e/fixture-app", "paths_modified": ["config.txt"]}],
                                    "decisions": [{"statement": "Keep retries at 4: the gateway rate-limits a fifth.", "status": "decided"},
                                        {"statement": "Retries were 3 before.", "status": "reverted"}]}}).to_string()}]})
                            }
                            "get_entity" => json!({"content": [{"type": "text", "text": "Entity not found"}], "isError": true}),
                            "save_session" => {
                                let arguments = message["params"]["arguments"].clone();
                                let session = if arguments["client"] == "oby" { "sess-gaps-1" } else { "sess-agent-1" };
                                seen.saved.push(arguments);
                                json!({"content": [{"type": "text", "text": json!({"session_id": session}).to_string()}]})
                            }
                            _ => json!({"content": [{"type": "text", "text": "ran"}]}),
                        },
                        _ => json!({}),
                    };
                    if message["method"]
                        .as_str()
                        .is_some_and(|m| m.starts_with("notifications/"))
                    {
                        reply(&mut stream, "202 Accepted", "application/json", "");
                    } else {
                        reply(
                            &mut stream,
                            "200 OK",
                            "application/json",
                            &json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string(),
                        );
                    }
                }
                _ => reply(&mut stream, "404 Not Found", "text/plain", "no"),
            }
        }
    });
    (base, seen)
}

/// `text` as a form or query string writes it.
fn form_encode(text: &str) -> String {
    reqwest::Url::parse_with_params("http://x/", &[("v", text)])
        .unwrap()
        .query()
        .unwrap()
        .trim_start_matches("v=")
        .to_owned()
}

/// A GET to `url` (the browser following the sign-in), its status and body.
fn browse(url: &str) -> (u16, String) {
    let url = reqwest::Url::parse(url).unwrap();
    let mut stream =
        std::net::TcpStream::connect((url.host_str().unwrap(), url.port().unwrap())).unwrap();
    let target = match url.query() {
        Some(query) => format!("{}?{query}", url.path()),
        None => url.path().to_owned(),
    };
    write!(
        stream,
        "GET {target} HTTP/1.1\r\nHost: {}:{}\r\nConnection: close\r\n\r\n",
        url.host_str().unwrap(),
        url.port().unwrap()
    )
    .unwrap();
    let mut answer = String::new();
    stream.read_to_string(&mut answer).unwrap();
    let status = answer
        .split(' ')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    (status, answer)
}

fn fake_claude() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude")
}

/// Every file under `dir`, as text.
fn every_file(dir: &Path, out: &mut Vec<(PathBuf, String)>) {
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            every_file(&path, out);
        } else if kind.is_file() {
            out.push((
                path.clone(),
                String::from_utf8_lossy(&std::fs::read(&path).unwrap()).into_owned(),
            ));
        }
    }
}

#[test]
fn obid_signs_in_to_tetrix_once_and_agents_use_it_without_its_login() {
    let folder = Folder::new("tetrix");
    let remote = fixture(&folder.0.join("fixture"));
    let (base, seen) = fake_tetrix();
    let mut config = config(&folder.0, &remote, &fake_claude());
    config["repos"][0]["check"] = Value::Null;
    let obid = start(&folder.0, &config, None);

    // Signed out, with the preset offered.
    let status = call(&obid, "GET", "/v1/tetrix", None);
    assert_eq!(status.status, 200);
    assert_eq!(status.body["connected"], false);
    assert_eq!(status.body["presets"][0]["id"], "dogfood");
    assert_eq!(status.body["presets"][0]["name"], "Tetrix Dogfood");
    // Only with the API token.
    assert_eq!(
        call_with_token(&obid, "not-the-token", "GET", "/v1/tetrix", None).status,
        401
    );
    // A URL that would carry the login in the clear, or a preset that isn't, is refused.
    for body in [
        json!({"url": "http://tetrix.example/mcp"}),
        json!({"url": "https://tetrix.example/mcp?token=x"}),
        json!({"preset": "nope"}),
        json!({"preset": "dogfood", "url": format!("{base}/mcp")}),
        json!({"other": 1}),
    ] {
        assert_eq!(
            call(&obid, "POST", "/v1/tetrix/sign-in", Some(&body)).status,
            422,
            "{body}"
        );
    }

    // Metadata for another server: a token minted for it would go to this one.
    let evil = call(
        &obid,
        "POST",
        "/v1/tetrix/sign-in",
        Some(&json!({"url": format!("{base}/evil-mcp")})),
    );
    assert_eq!(evil.status, 502, "{}", evil.text);
    assert!(evil.text.contains("another server"), "{}", evil.text);

    // A sign-in started and replaced: the second reuses the client and its port.
    let first = call(
        &obid,
        "POST",
        "/v1/tetrix/sign-in",
        Some(&json!({"url": format!("{base}/mcp")})),
    );
    assert_eq!(first.status, 200, "{}", first.text);

    // Sign in: the page to open is the fake's, with PKCE, the scopes and the resource.
    let started = call(
        &obid,
        "POST",
        "/v1/tetrix/sign-in",
        Some(&json!({"url": format!("{base}/mcp")})),
    );
    assert_eq!(started.status, 200, "{}", started.text);
    let page = reqwest::Url::parse(started.body["url"].as_str().unwrap()).unwrap();
    assert!(
        page.as_str()
            .starts_with(&format!("{base}/auth/authorize?"))
    );
    // Where the person signs in: the issuer the MCP server named.
    assert_eq!(started.body["server"], format!("{base}/auth"));
    let query: std::collections::HashMap<String, String> = page
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    assert_eq!(query["client_id"], "oby-dynamic-1");
    assert_eq!(query["code_challenge_method"], "S256");
    assert_eq!(query["resource"], format!("{base}/mcp"));
    assert_eq!(
        query["scope"],
        "graph:read sessions:write hitl:write offline_access"
    );
    let redirect = query["redirect_uri"].clone();
    assert!(redirect.starts_with("http://127.0.0.1:") && redirect.ends_with("/callback"));
    assert_eq!(
        call(&obid, "GET", "/v1/tetrix", None).body["signIn"],
        started.body
    );
    // The registration asked for a public client with this redirect alone, once.
    let registrations: Vec<Value> = seen
        .lock()
        .unwrap()
        .requests
        .iter()
        .filter(|r| r.1 == "/auth/register")
        .map(|r| serde_json::from_str::<Value>(&r.3).unwrap())
        .collect();
    assert_eq!(registrations.len(), 1, "{registrations:?}");
    let registered = &registrations[0];
    assert!(
        first.body["url"]
            .as_str()
            .unwrap()
            .contains(&format!("redirect_uri={}", form_encode(&redirect))),
        "the same port"
    );
    assert_eq!(registered["token_endpoint_auth_method"], "none");
    assert_eq!(registered["redirect_uris"], json!([redirect]));

    // The browser goes to the page, then lands on obid's: a wrong state changes nothing.
    assert_eq!(browse(page.as_str()).0, 200);
    let (status, _) = browse(&format!("{redirect}?code=the-code&state=wrong"));
    assert_eq!(status, 400);
    assert_eq!(
        call(&obid, "GET", "/v1/tetrix", None).body["connected"],
        false
    );
    let (status, said) = browse(&format!(
        "{redirect}?code=the-code&state={}",
        query["state"]
    ));
    assert_eq!(status, 200, "{said}");
    assert!(said.contains("Oby is signed in to Tetrix."));
    let status = within(10, "signed in", || {
        let status = call(&obid, "GET", "/v1/tetrix", None).body;
        (status["connected"] == true && status["signIn"].is_null()).then_some(status)
    });
    assert_eq!(status["url"], format!("{base}/mcp"));
    assert_eq!(status["error"], Value::Null);
    assert_eq!(
        status["scopes"],
        json!([
            "graph:read",
            "sessions:write",
            "hitl:write",
            "offline_access"
        ])
    );
    // Its port closed with it: the code can't be used again.
    assert!(
        std::net::TcpStream::connect(
            redirect
                .trim_start_matches("http://")
                .trim_end_matches("/callback")
        )
        .is_err()
    );

    // Every account's agents have Tetrix now.
    let accounts = call(&obid, "GET", "/v1/status", None).body["accounts"].clone();
    assert!(
        accounts
            .as_array()
            .unwrap()
            .iter()
            .all(|a| a["tetrix"] == true),
        "{accounts}"
    );

    // A job: its agent gets obid's Tetrix server and the job's token, never Oby's login.
    let made = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "build", "task": "REPORT TETRIX_CALL"}}),
        ),
    );
    assert_eq!(made.status, 201, "{}", made.text);
    let id = made.body["id"].as_str().unwrap().to_owned();
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}/wait"), None).body;
    let worktree = obid.home.join("worktrees").join(&id);
    let report: Value =
        serde_json::from_str(&std::fs::read_to_string(worktree.join(".obi/report.json")).unwrap())
            .unwrap();
    let server = &report["mcp"]["mcpServers"]["tetrix"];
    assert_eq!(
        server["url"],
        format!("http://127.0.0.1:{}/v1/agent/tetrix/{id}", obid.port)
    );
    let job_token = server["headers"]["Authorization"].as_str().unwrap();
    assert!(job_token.starts_with("Bearer ") && job_token.len() > 40);
    let allowed: Vec<&str> = report["allowed"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a.as_str().unwrap())
        .collect();
    assert!(allowed.contains(&"mcp__tetrix__get_entity"));
    assert!(allowed.contains(&"mcp__tetrix__save_session"));
    assert!(!allowed.iter().any(|a| a.contains("resume_session")));
    // Only the tools agents may call are listed, and the one it may not is refused before it
    // leaves obid.
    let listed: Vec<&str> = report["answers"]["tetrix"]["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        listed,
        [
            "get_entity",
            "repo_sessions",
            "save_session",
            "search_entities",
            "session_context",
            "session_digest"
        ]
    );
    assert_eq!(report["toolCalls"]["resume"]["result"]["isError"], true);
    // What the secret scan finds never leaves obid under Oby's login.
    let leak = &report["toolCalls"]["leak"]["result"];
    assert_eq!(leak["isError"], true, "{leak}");
    assert!(leak.to_string().contains("secret scan"), "{leak}");
    assert!(
        !seen
            .lock()
            .unwrap()
            .requests
            .iter()
            .any(|r| r.3.contains(&format!("AKIA{}", "QWERTYUIOPASDFGH"))),
        "the key never reached Tetrix"
    );
    assert!(
        !seen
            .lock()
            .unwrap()
            .requests
            .iter()
            .any(|r| r.3.contains("resume_session") && r.3.contains("tools/call")),
        "resume_session never reached Tetrix"
    );
    // The context Tetrix gave before the agent started, quoted as data, and the prompt.
    let context = std::fs::read_to_string(worktree.join(".obi/context/tetrix.md")).unwrap();
    assert!(context.contains("quoted data"), "{context}");
    assert!(context.contains("Earlier work"), "{context}");
    assert!(report["prompt"].as_str().unwrap().contains("save_session"));

    // What obid saw, and the graph's gaps sent to Tetrix as a session of Oby's own.
    let tetrix = &job["tetrix"];
    assert_eq!(tetrix["connected"], true, "{job}");
    assert_eq!(
        tetrix["calls"],
        json!({"get_entity": 1, "save_session": 1, "search_entities": 1})
    );
    assert_eq!(tetrix["context"], true);
    assert_eq!(tetrix["saved"], json!(["sess-agent-1"]));
    assert_eq!(
        tetrix["stamps"],
        json!({"commits": 1, "stamped": 1, "sessions": ["sess-agent-1"]})
    );
    let gaps = &tetrix["gaps"];
    assert_eq!(gaps["noResults"], json!(["where is the nothing"]), "{gaps}");
    assert_eq!(gaps["missing"], json!(["repo:acme/legacy"]));
    assert_eq!(gaps["unknownFiles"], json!(["tetrix.txt"]));
    assert_eq!(gaps["session"], "sess-gaps-1");
    assert!(gaps["sent"].is_string(), "{gaps}");
    assert!(
        job["outgoing"]
            .as_array()
            .unwrap()
            .iter()
            .any(|o| o["action"] == "tetrixSession" && o["id"] == "sess-agent-1"),
        "{}",
        job["outgoing"]
    );
    assert!(
        job["outgoing"]
            .as_array()
            .unwrap()
            .iter()
            .any(|o| o["action"] == "tetrixGaps" && o["id"] == "sess-gaps-1"),
        "{}",
        job["outgoing"]
    );
    assert!(
        job["summary"]
            .as_str()
            .unwrap()
            .contains("Tetrix: 3 calls (get_entity 1, save_session 1, search_entities 1). Session saved. 1 of 1 commits stamped Tetrix-Session (sess-agent-1)."),
        "{}",
        job["summary"]
    );
    let sent = seen
        .lock()
        .unwrap()
        .saved
        .iter()
        .find(|s| s["client"] == "oby")
        .cloned()
        .unwrap();
    assert_eq!(sent["state"]["kind"], "oby.graphGaps/1");
    assert_eq!(sent["state"]["job"], id.as_str());
    assert_eq!(sent["repo_hint"], "obi-e2e/fixture-app");
    assert_eq!(sent["state"]["agentSessions"], json!(["sess-agent-1"]));
    // The calls are in the job's report, by name and never by value.
    assert!(
        job["connectionUses"]
            .as_array()
            .unwrap()
            .iter()
            .any(|u| u["connection"] == "tetrix"
                && u["tool"] == "resume_session"
                && u["allowed"] == false)
    );

    // obid refreshed the 30-second token and kept the rotated refresh token.
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen.access, ACCESS_2);
        assert!(
            seen.requests
                .iter()
                .any(|r| r.1 == "/mcp" && r.2 == format!("Bearer {ACCESS_2}"))
        );
        // Tetrix only ever got Oby's login, never the job's token.
        assert!(!seen.requests.iter().any(|r| r.2 == job_token));
    }

    // Signing out revokes the refresh token and forgets the login; jobs lose Tetrix.
    assert_eq!(call(&obid, "DELETE", "/v1/tetrix", None).status, 204);
    assert!(
        seen.lock()
            .unwrap()
            .requests
            .iter()
            .any(|r| r.1 == "/auth/revoke"
                && form(&r.3).get("token").map(String::as_str) == Some(REFRESH_2))
    );
    let status = call(&obid, "GET", "/v1/tetrix", None).body;
    assert_eq!(status["connected"], false);
    assert_eq!(status["url"], format!("{base}/mcp"));

    // The login is nowhere but where the vault keeps it: not in an answer, the log, the job's
    // files, tetrix.json or the agent's report.
    let secrets = [ACCESS_1, ACCESS_2, REFRESH_1, REFRESH_2];
    let mut texts = vec![
        ("log".into(), obid.log()),
        ("job".into(), job.to_string()),
        ("status".into(), status.to_string()),
        ("report".into(), report.to_string()),
    ];
    let mut files = Vec::new();
    every_file(&obid.home, &mut files);
    for (path, text) in files {
        if path.starts_with(obid.home.join("vault")) {
            continue;
        }
        texts.push((path.display().to_string(), text));
    }
    for (name, text) in &texts {
        for secret in secrets {
            assert!(!text.contains(secret), "{secret} in {name}");
        }
    }
}

/// A stand-in `gh` in `folder/bin` that opens a pull request and keeps its description in
/// `folder/gh/body`.
fn body_keeping_gh(folder: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = folder.join("bin");
    let state = folder.join("gh");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&state).unwrap();
    let script = format!(
        r#"#!/bin/sh
dir='{state}'
prev=
case "$1 $2" in
  "pr list") exit 0 ;;
  "pr create")
    for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$dir/body"; prev="$a"; done
    echo 'https://github.com/obi-e2e/fixture-app/pull/7'
    exit 0 ;;
  "pr view") exit 1 ;;
  *) echo "gh: not in this test" >&2; exit 1 ;;
esac
"#,
        state = state.display()
    );
    std::fs::write(bin.join("gh"), script).unwrap();
    std::fs::set_permissions(bin.join("gh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

/// Signs `obid` in to the fake Tetrix at `base`, as the browser would.
fn sign_in(obid: &Obid, base: &str) {
    let started = call(
        obid,
        "POST",
        "/v1/tetrix/sign-in",
        Some(&json!({"url": format!("{base}/mcp")})),
    );
    assert_eq!(started.status, 200, "{}", started.text);
    let page = reqwest::Url::parse(started.body["url"].as_str().unwrap()).unwrap();
    let query: std::collections::HashMap<String, String> = page
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    assert_eq!(browse(page.as_str()).0, 200);
    let (status, said) = browse(&format!(
        "{}?code=the-code&state={}",
        query["redirect_uri"], query["state"]
    ));
    assert_eq!(status, 200, "{said}");
    within(10, "signed in", || {
        (call(obid, "GET", "/v1/tetrix", None).body["connected"] == true).then_some(())
    });
}

/// Decisions before publishing (docs/runner-api.md, "obid only: Tetrix"): a job that changes a
/// number an earlier session decided on gets one round, its decisions quoted as data, and
/// publishes with the conflict in its pull request; a session reference the secret scan flags is
/// never sent, and a Tetrix that doesn't answer in time still lets the job publish.
#[test]
fn a_change_against_an_earlier_decision_gets_one_round_and_never_blocks() {
    let folder = Folder::new("tetrix-decisions");
    let remote = fixture(&folder.0.join("fixture"));
    // The base holds the value the earlier session decided on.
    let work = folder.0.join("work");
    let git = |args: &[&str]| {
        let done = std::process::Command::new("git")
            .args(args)
            .current_dir(&work)
            .output()
            .unwrap();
        assert!(
            done.status.success(),
            "{}",
            String::from_utf8_lossy(&done.stderr)
        );
    };
    std::fs::create_dir_all(&work).unwrap();
    git(&["clone", "-q", "-b", "main", remote.to_str().unwrap(), "."]);
    std::fs::write(work.join("config.txt"), "retries = 4\n").unwrap();
    git(&["add", "config.txt"]);
    git(&[
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.com",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-q",
        "-m",
        "Add config",
    ]);
    git(&["push", "-q", "origin", "main"]);
    let (base, seen) = fake_tetrix();
    let bin = body_keeping_gh(&folder.0);
    let mut config = config(&folder.0, &remote, &fake_claude());
    config["repos"][0]["check"] = Value::Null;
    let obid = start(&folder.0, &config, Some(&bin));
    sign_in(&obid, &base);
    let run = |task: &str| {
        let made = call(
            &obid,
            "POST",
            "/v1/jobs",
            Some(&json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "build", "task": task}})),
        );
        assert_eq!(made.status, 201, "{}", made.text);
        let id = made.body["id"].as_str().unwrap().to_owned();
        let job = call(&obid, "GET", &format!("/v1/jobs/{id}/wait"), None).body;
        (id, job)
    };
    let body = || std::fs::read_to_string(folder.0.join("gh/body")).unwrap_or_default();

    // One round, the decision quoted as data; the agent keeps its change and says why, and the
    // job publishes with the conflict listed. No second round.
    let (id, job) = run("BUMP: config.txt 4 6");
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(
        job["published"], "https://github.com/obi-e2e/fixture-app/pull/7",
        "{job}"
    );
    assert_eq!(job["round"], 2, "{job}");
    let decisions = &job["tetrix"]["decisions"];
    assert_eq!(decisions["asked"], true, "{job}");
    assert_eq!(
        decisions["sessions"],
        json!(["5b0e7c1a-9d2f-4c3e-8a1b-2f3e4d5c6b7a"])
    );
    assert_eq!(decisions["error"], Value::Null);
    let conflict = &decisions["conflicts"][0];
    assert_eq!(
        (
            &conflict["file"],
            &conflict["line"],
            &conflict["was"],
            &conflict["now"]
        ),
        (&json!("config.txt"), &json!(1), &json!("4"), &json!("6"))
    );
    assert_eq!(
        conflict["decision"],
        "Keep retries at 4: the gateway rate-limits a fifth."
    );
    let seen_file = std::fs::read_to_string(
        obid.home
            .join("worktrees")
            .join(&id)
            .join(".obi/decisions-seen.md"),
    )
    .unwrap();
    assert!(seen_file.contains("<<<quoted-"), "{seen_file}");
    assert!(seen_file.contains("Keep retries at 4"), "{seen_file}");
    let pr = body();
    assert!(
        pr.contains("- Earlier decisions: this changes 1 value(s) an earlier Tetrix session decided on: ` config.txt:1 ` (4 → 6), session 5b0e7c1a-9d2f-4c3e-8a1b-2f3e4d5c6b7a."),
        "{pr}"
    );
    assert!(pr.contains("Kept it: the gateway allows six"), "{pr}");
    // The decision's words aren't in the pull request; the reverted one isn't a decision.
    assert!(!pr.contains("rate-limits"), "{pr}");
    // Tetrix was asked about the repository and the session, never about a file.
    let asked: Vec<Value> = seen
        .lock()
        .unwrap()
        .requests
        .iter()
        .filter_map(|r| serde_json::from_str::<Value>(&r.3).ok())
        .filter(|m| m["method"] == "tools/call")
        .map(|m| m["params"].clone())
        .collect();
    assert!(
        asked.contains(
            &json!({"name": "repo_sessions", "arguments": {"name": "obi-e2e/fixture-app"}})
        ),
        "{asked:?}"
    );
    assert!(
        asked.contains(
            &json!({"name": "session_context", "arguments": {"session": "agent_session:g1"}})
        ),
        "{asked:?}"
    );
    assert!(
        asked.contains(&json!({"name": "session_digest", "arguments":
        {"session": "session:acme/5b0e7c1a-9d2f-4c3e-8a1b-2f3e4d5c6b7a", "format": "structured"}})),
        "{asked:?}"
    );

    // A session reference the secret scan flags is never sent: the job publishes unchecked.
    seen.lock().unwrap().mode = "leaky";
    let (_, job) = run("BUMP: config.txt 4 7");
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["round"], 1, "{job}");
    assert_eq!(job["tetrix"]["decisions"]["conflicts"], json!([]), "{job}");
    assert!(
        !seen
            .lock()
            .unwrap()
            .requests
            .iter()
            .any(|r| r.3.contains("session_context") && r.3.contains(&made_up_key())),
        "the key never reached Tetrix"
    );
    assert!(!body().contains("Earlier decisions"), "{}", body());

    // A Tetrix whose every answer comes in time but whose answers together take longer than the
    // check's 30 seconds: nothing is checked, it says so, and the job still publishes.
    seen.lock().unwrap().mode = "slow";
    let (_, job) = run("BUMP: config.txt 4 8");
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(
        job["published"], "https://github.com/obi-e2e/fixture-app/pull/7",
        "{job}"
    );
    assert_eq!(job["round"], 1, "{job}");
    let decisions = &job["tetrix"]["decisions"];
    assert_eq!(decisions["conflicts"], json!([]), "{job}");
    assert_eq!(
        decisions["error"], "Tetrix didn't answer within 30 seconds: nothing was checked.",
        "{job}"
    );
}
