//! `obi-plugin.json` against docs/ARCHITECTURE.md 5.2: the example there parses as written, and
//! each rule refuses what it should.

use obi_plugin_api::{
    EventKind, Kind, MANIFEST_FILE, Manifest, McpServerSpec, PROTOCOL, PluginError, PluginId,
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
