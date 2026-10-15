//! `obi-plugin.json` against docs/ARCHITECTURE.md 5.2: the example there parses as written, and
//! each rule refuses what it should.

use obi_plugin_api::{
    EventKind, Kind, MANIFEST_FILE, MAX_TOOL_NAME_BYTES, Manifest, McpServerSpec, PROTOCOL,
    PluginError, PluginId,
};
use serde_json::{Value, json};

/// The manifest docs/ARCHITECTURE.md 5.2 shows, word for word.
fn tetrix() -> Value {
    json!({
      "manifest": "obi-plugin/0.1",
      "id": "tetrix",
      "name": "Tetrix",
      "version": "0.1.0",
      "description": "A code graph and memory for agents.",
      "kinds": ["agent-mcp"],
      "run": {"command": "bin/tetrix-plugin", "args": []},
      "agentMcp": {
        "server": {"type": "http", "url": "https://mcp.tetrix.example/mcp"},
        "allowedTools": ["search_entities", "get_entity", "code_impact", "save_session"]
      },
      "network": ["mcp.tetrix.example"],
      "config": {"type": "object", "additionalProperties": false, "properties": {}}
    })
}

fn events_plugin() -> Value {
    json!({
      "manifest": "obi-plugin/0.1",
      "id": "gh-events",
      "name": "GitHub events",
      "version": "0.1.0",
      "kinds": ["events"],
      "run": {"command": "bin/events"},
      "events": {"kinds": ["pull_request.review_requested", "issue.assigned"]}
    })
}

fn parse(value: &Value) -> Result<Manifest, PluginError> {
    let folder = value["id"].as_str().unwrap_or("x").to_owned();
    Manifest::from_slice(value.to_string().as_bytes(), &folder)
}

fn refused(value: &Value) -> String {
    match parse(value) {
        Err(PluginError::Manifest(reason)) => reason,
        other => panic!("expected a manifest error for {value}, got {other:?}"),
    }
}

#[test]
fn the_architecture_example_parses() {
    let manifest = parse(&tetrix()).unwrap();
    assert_eq!(MANIFEST_FILE, "obi-plugin.json");
    assert_eq!(manifest.manifest, PROTOCOL);
    assert_eq!(manifest.id, PluginId::new("tetrix").unwrap());
    assert_eq!(manifest.kinds, vec![Kind::AgentMcp]);
    assert!(manifest.serves(Kind::AgentMcp));
    assert!(!manifest.serves(Kind::Context));
    let mcp = manifest.agent_mcp.as_ref().unwrap();
    assert_eq!(
        mcp.server,
        McpServerSpec::Http {
            url: "https://mcp.tetrix.example/mcp".into()
        }
    );
    assert_eq!(
        mcp.allowed_tools,
        [
            "search_entities",
            "get_entity",
            "code_impact",
            "save_session"
        ]
    );
    assert_eq!(manifest.network, ["mcp.tetrix.example"]);
    // It writes back as the same JSON.
    assert_eq!(serde_json::to_value(&manifest).unwrap(), tetrix());
}

#[test]
fn an_agent_mcp_only_plugin_may_leave_run_out() {
    let mut value = tetrix();
    value.as_object_mut().unwrap().remove("run");
    assert!(parse(&value).unwrap().run.is_none());
}

#[test]
fn an_events_plugin_parses() {
    let manifest = parse(&events_plugin()).unwrap();
    assert_eq!(
        manifest.events.unwrap().kinds,
        [
            EventKind::PullRequestReviewRequested,
            EventKind::IssueAssigned
        ]
    );
    assert_eq!(manifest.run.unwrap().args, Vec::<String>::new());
}

#[test]
fn a_stdio_server_parses() {
    let mut value = tetrix();
    value["agentMcp"]["server"] = json!({"type": "stdio", "command": "bin/mcp", "args": ["--x"]});
    let manifest = parse(&value).unwrap();
    assert_eq!(
        manifest.agent_mcp.unwrap().server,
        McpServerSpec::Stdio {
            command: "bin/mcp".into(),
            args: vec!["--x".into()]
        }
    );
}

#[test]
fn the_id_is_the_folder_name() {
    let error = Manifest::from_slice(tetrix().to_string().as_bytes(), "other").unwrap_err();
    assert!(matches!(error, PluginError::Manifest(reason) if reason.contains("folder")));
}

#[test]
fn a_field_the_spec_does_not_list_is_refused() {
    let mut value = tetrix();
    value["enabled"] = json!(true);
    assert!(refused(&value).contains("enabled"));

    let mut value = tetrix();
    value["agentMcp"]["server"]["headers"] = json!({"Authorization": "Bearer x"});
    assert!(refused(&value).contains("headers"));

    let mut value = tetrix();
    value["agentMcp"]["server"] =
        json!({"type": "stdio", "command": "bin/mcp", "env": {"TOKEN": "x"}});
    assert!(refused(&value).contains("env"));
}

#[test]
fn a_server_url_with_a_login_is_refused() {
    let mut value = tetrix();
    value["agentMcp"]["server"]["url"] = json!("https://user:pass@mcp.tetrix.example/mcp");
    assert!(refused(&value).contains("login"));
}

#[test]
fn a_server_url_with_a_query_or_fragment_is_refused() {
    for url in [
        "https://mcp.example/mcp?api_key=sk-live-123",
        "https://mcp.example/mcp?transport=http",
        "https://mcp.example?token=x",
        "https://mcp.example/mcp#token=x",
    ] {
        let mut value = tetrix();
        value["agentMcp"]["server"]["url"] = json!(url);
        assert!(refused(&value).contains("query"), "{url}");
    }
    let mut value = tetrix();
    value["agentMcp"]["server"]["url"] = json!("https://mcp.example/mcp\nx");
    refused(&value);
}

#[test]
fn stdio_args_that_pass_a_credential_are_refused() {
    let refused_args: [&[&str]; 8] = [
        &["-c", "curl -H 'Authorization: Bearer sk' https://x"],
        &["--header", "authorization: token abc"],
        &["--token", "abc"],
        &["--api-key=abc"],
        &["--client-secret", "abc"],
        &["GITHUB_TOKEN=abc", "bin/mcp"],
        &["--password", "hunter2"],
        &["serve", "--access_key", "abc"],
    ];
    for args in refused_args {
        let mut value = tetrix();
        value["agentMcp"]["server"] = json!({"type": "stdio", "command": "/bin/sh", "args": args});
        assert!(refused(&value).contains("credential"), "{args:?}");
    }
    let accepted_args: [&[&str]; 5] = [
        &["--x"],
        &["--port", "8080", "--read-only"],
        &["--tokens-per-minute"],
        &["--keyboard", "us", "--log=debug"],
        &["--monkey=1", "--tokenizer", "bpe"],
    ];
    for args in accepted_args {
        let mut value = tetrix();
        value["agentMcp"]["server"] = json!({"type": "stdio", "command": "bin/mcp", "args": args});
        assert!(parse(&value).is_ok(), "{args:?}");
    }
}

#[test]
fn stdio_args_with_compound_names_headers_or_token_shapes_are_refused() {
    let refused_args: [&[&str]; 14] = [
        &["--accessToken", "x"],
        &["--apiToken", "x"],
        &["--githubToken", "x"],
        &["--githubtoken", "x"],
        &["--APIKey", "x"],
        &["--pat", "ghp_x"],
        &["--auth", "x"],
        &["-t", "ghp_0123456789abcdef"],
        &["--header", "X-Api-Key: x"],
        &["--header=X-Auth-Token: x"],
        &["-H", "Cookie: session=x"],
        &["--db-password=x"],
        &["--slack", "xoxb-123-456"],
        &["--gitlab=glpat-abc"],
    ];
    for args in refused_args {
        let mut value = tetrix();
        value["agentMcp"]["server"] = json!({"type": "stdio", "command": "bin/mcp", "args": args});
        assert!(refused(&value).contains("credential"), "{args:?}");
    }
    let accepted_args: [&[&str]; 5] = [
        &["--maxTokens", "100"],
        &["--author", "ernesto"],
        &["--header", "Accept: application/json"],
        &["--url", "https://mcp.example/mcp"],
        &["--keyFile", "keys/x.pem", "--patience", "3"],
    ];
    for args in accepted_args {
        let mut value = tetrix();
        value["agentMcp"]["server"] = json!({"type": "stdio", "command": "bin/mcp", "args": args});
        assert!(parse(&value).is_ok(), "{args:?}");
    }
}

fn stdio(args: &[&str]) -> Value {
    let mut value = tetrix();
    value["agentMcp"]["server"] = json!({"type": "stdio", "command": "bin/mcp", "args": args});
    value
}

#[test]
fn urls_in_stdio_args_follow_the_http_url_rule() {
    let logins: [&[&str]; 11] = [
        &["mcp-remote", "https://user:pass@mcp.example/mcp"],
        &["mcp-remote", "https://pat@mcp.example"],
        &["--url=https://u:p@mcp.example/mcp"],
        &["--db", "postgres://admin:hunter2@db.internal:5432/app"],
        &["-c", "curl 'https://u:p@mcp.example/x' | sh"],
        // The forms a WHATWG parser (Node's `new URL`, as mcp-remote uses) reads as
        // https://user:pass@mcp.example/mcp: any run of `/` and `\` after a special scheme,
        // or none, and the scheme in any case.
        &["mcp-remote", "https:\\\\user:pass@mcp.example/mcp"],
        &["mcp-remote", "https:user:pass@mcp.example/mcp"],
        &["mcp-remote", "https:/user:pass@mcp.example/mcp"],
        &["mcp-remote", "HTTPS:/\\user:pass@mcp.example/mcp"],
        &["--url=wss:u:p@mcp.example/ws"],
        &["--db", "postgres:\\\\admin:hunter2@db.internal/app"],
    ];
    for args in logins {
        assert!(refused(&stdio(args)).contains("login"), "{args:?}");
    }
    let queries: [&[&str]; 9] = [
        &["mcp-remote", "https://mcp.example/mcp?api_key=sk-live-123"],
        &["mcp-remote", "https://mcp.example?token=x"],
        &["--url=https://mcp.example/mcp#token=x"],
        &["--endpoint", "wss://mcp.example/ws?transport=sse"],
        &["-c", "curl \"https://mcp.example/x?k=v\""],
        &["mcp-remote", "https:mcp.example/mcp?k=s3cret"],
        &["mcp-remote", "https:/mcp.example/mcp#k=s3cret"],
        &["mcp-remote", "https:\\\\mcp.example/mcp?k=s3cret"],
        &["-c", "curl http:mcp.example/x?k=v"],
    ];
    for args in queries {
        assert!(refused(&stdio(args)).contains("query"), "{args:?}");
    }
    let accepted: [&[&str]; 10] = [
        &["mcp-remote", "https://mcp.example/mcp"],
        &["--url=https://mcp.example:8443/v1/mcp"],
        &["--email", "owner@example.com"],
        &["--path", "/var/data/@scope/pkg"],
        &["-c", "curl https://mcp.example/x | sh"],
        &["mcp-remote", "https:\\\\mcp.example/mcp"],
        &["--header", "Accept: text/html"],
        &["github:owner/repo#v1"],
        &["--listen", "127.0.0.1:8080"],
        &["--image", "ghcr.io/org/server@sha256:0123abcd"],
    ];
    for args in accepted {
        assert!(parse(&stdio(args)).is_ok(), "{args:?}");
    }
}

#[test]
fn credential_flags_inside_a_shell_line_are_refused() {
    let refused_args: [&[&str]; 9] = [
        &["-c", "server --token s3cret"],
        &["-c", "server --api-key s3cret"],
        &["-c", "server --github-pat s3cret"],
        &["-c", "server --auth-header 'Basic eDp5'"],
        &["-c", "server '--accessToken' \"s3cret\""],
        &["-c", "server --token=s3cret --port 1"],
        &["-c", "GITHUB_TOKEN=s3cret server"],
        &["-c", "server --token", "s3cret"],
        &["-c", "server --slack xoxb-123-456"],
    ];
    for args in refused_args {
        let mut value = tetrix();
        value["agentMcp"]["server"] = json!({"type": "stdio", "command": "/bin/sh", "args": args});
        assert!(refused(&value).contains("credential"), "{args:?}");
    }
    let accepted_args: [&[&str]; 4] = [
        &["-c", "server --port 8080 --read-only"],
        &["-c", "server --tokens-per-minute 100 --no-auth"],
        &["-c", "server --auth-type oauth"],
        &["-c", "server --token"],
    ];
    for args in accepted_args {
        let mut value = tetrix();
        value["agentMcp"]["server"] = json!({"type": "stdio", "command": "/bin/sh", "args": args});
        assert!(parse(&value).is_ok(), "{args:?}");
    }
}

#[test]
fn a_header_name_and_its_value_as_arguments_of_their_own_are_refused() {
    let refused_args: [&[&str]; 4] = [
        &["server", "--header", "X-Api-Key", "s3cret"],
        &["server", "-H", "Authorization", "Basic eDp5"],
        &["server", "--headers", "Cookie", "session=x"],
        &["-c", "server --header X-Auth-Token s3cret"],
    ];
    for args in refused_args {
        assert!(refused(&stdio(args)).contains("credential"), "{args:?}");
    }
    let accepted_args: [&[&str]; 3] = [
        &["server", "--header", "Accept", "application/json"],
        &["server", "--header", "X-Api-Key"],
        // A positional word that names a credential is not a header: `gh auth status`.
        &["auth", "status"],
    ];
    for args in accepted_args {
        assert!(parse(&stdio(args)).is_ok(), "{args:?}");
    }
}

#[test]
fn the_stdio_command_is_held_to_the_same_rules_as_its_arguments() {
    let server = |command: &str, args: &[&str]| {
        let mut value = tetrix();
        value["agentMcp"]["server"] = json!({"type": "stdio", "command": command, "args": args});
        value
    };
    let message = refused(&server("npx mcp-remote https://u:s3cret@host/mcp", &[]));
    assert!(message.contains("login"), "{message}");
    assert!(message.contains("agentMcp.server.command"), "{message}");
    assert!(!message.contains("s3cret"), "{message}");

    let message = refused(&server("npx mcp-remote https:host/mcp?k=s3cret", &[]));
    assert!(message.contains("query"), "{message}");
    assert!(message.contains("agentMcp.server.command"), "{message}");

    for command in [
        "npx --token s3cret",
        "npx --api-key=s3cret",
        "GITHUB_TOKEN=s3cret npx server",
    ] {
        let message = refused(&server(command, &[]));
        assert!(message.contains("credential"), "{command}");
        assert!(message.contains("agentMcp.server.command"), "{message}");
        assert!(!message.contains("s3cret"), "{message}");
    }
    // A flag in the command, its value the first argument.
    let message = refused(&server("npx --token", &["s3cret"]));
    assert!(message.contains("credential"), "{message}");
    // A problem in an argument is still named by its own place.
    let message = refused(&server("npx", &["server", "--token", "s3cret"]));
    assert!(message.contains("agentMcp.server.args[1]"), "{message}");

    for command in [
        "bin/mcp",
        "/Applications/My Server.app/Contents/MacOS/mcp",
        "npx",
    ] {
        assert!(
            parse(&server(command, &["--port", "1"])).is_ok(),
            "{command}"
        );
    }
}

#[test]
fn a_refusal_names_the_argument_by_its_place_not_its_text() {
    let message = refused(&stdio(&["serve", "--token", "s3cr3t-value"]));
    assert!(message.contains("args[1]"), "{message}");
    assert!(!message.contains("s3cr3t-value"), "{message}");
    let message = refused(&stdio(&["mcp-remote", "https://u:s3cr3t@mcp.example"]));
    assert!(message.contains("args[1]"), "{message}");
    assert!(!message.contains("s3cr3t"), "{message}");
}

#[test]
fn compound_credential_flags_and_header_blobs_are_refused() {
    let refused_args: [&[&str]; 16] = [
        &["--github-pat", "x"],
        &["--githubPAT", "x"],
        &["--gitlab_pat=x"],
        &["--openai-key", "x"],
        &["--auth-header", "x"],
        &["--auth-header=Basic eDp5"],
        &["--basic-auth", "u:p"],
        &["--authorization", "x"],
        &["--headers", "{\"X-Api-Key\":\"x\"}"],
        &["--headers={\"Authorization\":\"Basic eDp5\"}"],
        &["--headers", "{ \"x-auth-token\" : \"x\" }"],
        &["--headers", "{'Cookie': 'session=x'}"],
        &["--headers", "{token: x}"],
        &["MCP_HEADERS={\"X-Api-Key\":\"x\"}"],
        &["--config", "{\"server\":{\"apiKey\":\"x\"}}"],
        &["-c", "curl -H 'X-Api-Key: x' https://mcp.example/x"],
    ];
    for args in refused_args {
        assert!(refused(&stdio(args)).contains("credential"), "{args:?}");
    }
    let accepted_args: [&[&str]; 7] = [
        &["--no-auth", "--port", "8080"],
        &["--auth-type", "oauth"],
        &["--headers", "{\"Accept\":\"application/json\"}"],
        &["--headers", "{\"X-Api-Key\":\"\"}"],
        &["--config", "{\"maxTokens\":100,\"keyFile\":\"keys/x.pem\"}"],
        &["--listen", "127.0.0.1:8080"],
        &["--keyboard", "us"],
    ];
    for args in accepted_args {
        assert!(parse(&stdio(args)).is_ok(), "{args:?}");
    }
}

#[test]
fn invisible_format_and_control_characters_are_refused() {
    for url in [
        "https://mcp.example/\u{202E}pcm",
        "https://mcp\u{200B}.example/mcp",
        "https://mcp.example/mcp\u{FEFF}",
        "https://mcp.example/\u{2066}mcp\u{2069}",
        "https://mcp.example/mcp\u{00AD}",
        "https://mcp.example/mcp\u{E0041}",
        "https://mcp.example/mcp\u{7}",
    ] {
        let mut value = tetrix();
        value["agentMcp"]["server"]["url"] = json!(url);
        assert!(
            refused(&value).contains("invisible format character"),
            "{}",
            url.escape_unicode()
        );
    }
    // Other code points Unicode shows as nothing, and line and paragraph separators.
    for url in [
        "https://mcp.example/mcp\u{3164}",
        "https://mcp.example/m\u{34F}cp",
        "https://mcp.example/mcp\u{FE0F}",
        "https://mcp.example/mcp\u{2028}",
        "https://mcp.example/mcp\u{FFA0}",
        "https://mcp.example/mcp\u{E0100}",
    ] {
        let mut value = tetrix();
        value["agentMcp"]["server"]["url"] = json!(url);
        assert!(
            refused(&value).contains("invisible format character"),
            "{}",
            url.escape_unicode()
        );
    }
    let hidden: [&[&str]; 13] = [
        &["mcp-remote", "https://mcp.example/\u{202E}pcm"],
        &["mcp-remote", "https://mcp\u{200B}.example/mcp"],
        &["--to\u{200B}ken", "x"],
        &["--api\u{2060}-key=x"],
        &["serve\u{0}", "--port", "1"],
        &["server", "--to\u{34F}ken", "x"],
        &["server", "--to\u{FE0F}ken", "x"],
        &["server", "--to\u{2028}ken", "x"],
        &["server", "--to\u{2029}ken", "x"],
        &["server", "--to\u{3164}ken", "x"],
        &["server", "--to\u{115F}ken", "x"],
        &["server", "--to\u{180B}ken", "x"],
        &["server", "--to\u{E0101}ken", "x"],
    ];
    for args in hidden {
        assert!(
            refused(&stdio(args)).contains("invisible format character"),
            "{args:?}"
        );
    }
    let mut value = tetrix();
    value["agentMcp"]["server"] =
        json!({"type": "stdio", "command": "bin/\u{202E}pcm", "args": []});
    assert!(refused(&value).contains("invisible format character"));
    // Plain non-ASCII text that shows as itself is not refused.
    assert!(parse(&stdio(&["--greeting", "héllo wörld"])).is_ok());
}

#[test]
fn a_server_url_must_be_http() {
    for url in ["ftp://mcp.tetrix.example", "mcp.tetrix.example", "https://"] {
        let mut value = tetrix();
        value["agentMcp"]["server"]["url"] = json!(url);
        refused(&value);
    }
}

#[test]
fn the_protocol_must_be_obi_plugin_0_1() {
    let mut value = tetrix();
    value["manifest"] = json!("obi-plugin/0.2");
    assert!(refused(&value).contains("obi-plugin/0.1"));
}

#[test]
fn bad_ids_are_refused() {
    for id in [
        "", "Tetrix", "te_trix", "../x", "a.b", "a/b", "é", "-", "--help", "-tetrix",
    ] {
        let mut value = tetrix();
        value["id"] = json!(id);
        assert!(
            Manifest::from_slice(value.to_string().as_bytes(), id).is_err(),
            "{id:?}"
        );
        assert!(matches!(PluginId::new(id), Err(PluginError::InvalidId(_))));
    }
    for id in ["tetrix", "a", "gh-events-2", "0x", "tetrix-"] {
        assert_eq!(PluginId::new(id).unwrap().as_str(), id);
    }
}

#[test]
fn kinds_are_one_or_more_each_once() {
    let mut value = tetrix();
    value["kinds"] = json!([]);
    assert!(refused(&value).contains("kinds"));

    let mut value = tetrix();
    value["kinds"] = json!(["agent-mcp", "agent-mcp"]);
    assert!(refused(&value).contains("twice"));

    let mut value = tetrix();
    value["kinds"] = json!(["agent_mcp"]);
    refused(&value);
}

#[test]
fn context_and_events_need_run() {
    let mut value = tetrix();
    value["kinds"] = json!(["agent-mcp", "context"]);
    value.as_object_mut().unwrap().remove("run");
    assert!(refused(&value).contains("run"));

    let mut value = events_plugin();
    value.as_object_mut().unwrap().remove("run");
    assert!(refused(&value).contains("run"));
}

#[test]
fn run_stays_inside_the_plugins_folder() {
    for command in ["/bin/sh", "../bin/x", "bin/../../x", ""] {
        let mut value = events_plugin();
        value["run"]["command"] = json!(command);
        assert!(refused(&value).contains("run.command"), "{command:?}");
    }
}

#[test]
fn agent_mcp_is_for_agent_mcp_only() {
    let mut value = tetrix();
    value.as_object_mut().unwrap().remove("agentMcp");
    assert!(refused(&value).contains("agentMcp"));

    let mut value = events_plugin();
    value["agentMcp"] = tetrix()["agentMcp"].clone();
    assert!(refused(&value).contains("agentMcp"));
}

#[test]
fn allowed_tools_are_named_once_each() {
    for tools in [json!([]), json!(["a", "a"]), json!(["a", " "])] {
        let mut value = tetrix();
        value["agentMcp"]["allowedTools"] = tools.clone();
        assert!(refused(&value).contains("allowedTools"), "{tools}");
    }
}

#[test]
fn allowed_tools_are_bare_tool_names() {
    // A wildcard, a list, a rule for another tool, a line break or a name already prefixed
    // for another server would widen what the permission gate lets agents call.
    for tool in [
        "*",
        "search_*",
        "a,Bash",
        "a Bash(rm -rf /)",
        "Bash(rm:*)",
        "a\nb",
        "mcp__other__x",
        "MCP__other__x",
        "a/b",
        "a:b",
        "é",
        &"x".repeat(MAX_TOOL_NAME_BYTES + 1),
    ] {
        let mut value = tetrix();
        value["agentMcp"]["allowedTools"] = json!(["get_entity", tool]);
        assert!(refused(&value).contains("allowedTools"), "{tool:?}");
    }
    let tools = json!([
        "search_entities",
        "get-entity",
        "tools.v2.list",
        "A1",
        "x".repeat(MAX_TOOL_NAME_BYTES)
    ]);
    let mut value = tetrix();
    value["agentMcp"]["allowedTools"] = tools.clone();
    let manifest = parse(&value).unwrap();
    assert_eq!(json!(manifest.agent_mcp.unwrap().allowed_tools), tools);
}

#[test]
fn events_is_for_events_only_and_lists_known_kinds() {
    let mut value = events_plugin();
    value.as_object_mut().unwrap().remove("events");
    assert!(refused(&value).contains("events"));

    let mut value = tetrix();
    value["events"] = json!({"kinds": ["mention"]});
    assert!(refused(&value).contains("events"));

    let mut value = events_plugin();
    value["events"]["kinds"] = json!(["push"]);
    refused(&value);

    let mut value = events_plugin();
    value["events"]["kinds"] = json!([]);
    assert!(refused(&value).contains("events.kinds"));

    let mut value = events_plugin();
    value["events"]["kinds"] = json!(["mention", "mention"]);
    assert!(refused(&value).contains("twice"));
}

#[test]
fn network_lists_host_names() {
    for host in ["https://mcp.tetrix.example", "a/b", "", "a b"] {
        let mut value = tetrix();
        value["network"] = json!([host]);
        assert!(refused(&value).contains("network"), "{host:?}");
    }
}

#[test]
fn config_is_a_schema_object() {
    let mut value = tetrix();
    value["config"] = json!("anything");
    assert!(refused(&value).contains("config"));

    let mut value = tetrix();
    value.as_object_mut().unwrap().remove("config");
    assert!(parse(&value).unwrap().config.is_none());
}

#[test]
fn name_and_version_are_not_empty() {
    for field in ["name", "version"] {
        let mut value = tetrix();
        value[field] = json!(" ");
        assert!(refused(&value).contains(field));
    }
}

#[test]
fn not_json_is_refused() {
    assert!(matches!(
        Manifest::from_slice(b"{", "tetrix"),
        Err(PluginError::Manifest(_))
    ));
}
