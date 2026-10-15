//! Discovery and the owner's choice (docs/ARCHITECTURE.md 5.3, steps 1 and 2): what
//! `home/plugins/` holds is listed, every plug-in is disabled until the owner enables it, and
//! the choice and settings are kept in `home/plugins.json`.

mod common;

use std::time::Duration;

use common::{Home, id, options, status};
use obi_plugin_api::{Kind, PluginError, PluginState};
use obi_plugin_host::PluginHost;
use serde_json::{Value, json};

/// An `agent-mcp` plug-in with no process, so nothing here needs the sandbox.
fn mcp_only(id: &str) -> Value {
    json!({
        "manifest": "obi-plugin/0.1",
        "id": id,
        "name": "MCP only",
        "version": "1.2.3",
        "kinds": ["agent-mcp"],
        "agentMcp": {
            "server": {"type": "http", "url": "https://mcp.example.test/mcp"},
            "allowedTools": ["search"]
        },
        "config": {
            "type": "object",
            "additionalProperties": false,
            "properties": {"depth": {"type": "integer", "minimum": 1, "maximum": 3}}
        }
    })
}

#[tokio::test]
async fn every_plugin_found_is_listed_and_disabled() {
    let home = Home::new("found");
    home.install("context-test", "context-test");
    home.install("events-test", "events-test");
    home.install("agent-mcp-test", "agent-mcp-test");
    home.install_manifest("mcp-only", &mcp_only("mcp-only"));

    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    let list = host.list();
    let ids: Vec<&str> = list.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(
        ids,
        ["agent-mcp-test", "context-test", "events-test", "mcp-only"]
    );
    for status in &list {
        assert!(!status.enabled, "{status:?}");
        assert_eq!(status.state, PluginState::Disabled, "{status:?}");
        assert_eq!(status.last_error, None);
    }
    assert_eq!(status(&host, "context-test").kinds, [Kind::Context]);
    assert_eq!(status(&host, "events-test").kinds, [Kind::Events]);
    assert_eq!(status(&host, "agent-mcp-test").kinds, [Kind::AgentMcp]);
    let mcp = status(&host, "mcp-only");
    assert_eq!(
        (mcp.name.as_str(), mcp.version.as_str()),
        ("MCP only", "1.2.3")
    );

    // Nothing was started or written: no data folders, no plugins.json.
    assert!(!home.path.join("plugin-data").exists());
    assert!(home.settings().is_none());
    assert!(host.agent_mcp_servers().is_empty());

    // As runner-api.md shows it.
    let listed = serde_json::to_value(&mcp).unwrap();
    assert_eq!(
        listed,
        json!({"id": "mcp-only", "name": "MCP only", "version": "1.2.3", "kinds": ["agent-mcp"],
               "enabled": false, "state": "disabled", "lastError": null})
    );
    host.shutdown().await;
}

#[tokio::test]
async fn a_manifest_that_does_not_parse_or_match_is_failed_with_its_reason() {
    let home = Home::new("invalid");
    let write = |id: &str, text: &str| {
        let dir = home.plugin_dir(id);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("obi-plugin.json"), text).unwrap();
    };
    write("not-json", "{ this is not json");
    let mut unknown_field = mcp_only("unknown-field");
    unknown_field["enabled"] = json!(true);
    write("unknown-field", &unknown_field.to_string());
    write("wrong-folder", &mcp_only("another-id").to_string());
    let mut pattern = mcp_only("pattern");
    pattern["config"] =
        json!({"type": "object", "properties": {"x": {"type": "string", "pattern": "^a"}}});
    write("pattern", &pattern.to_string());
    std::fs::create_dir_all(home.plugin_dir("no-manifest")).unwrap();
    // Left out: a folder whose name is not a plug-in id, and a file.
    std::fs::create_dir_all(home.plugin_dir("Not_An_Id")).unwrap();
    std::fs::write(home.path.join("plugins/README"), "not a plug-in").unwrap();

    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    let ids: Vec<String> = host.list().iter().map(|s| s.id.to_string()).collect();
    assert_eq!(
        ids,
        [
            "no-manifest",
            "not-json",
            "pattern",
            "unknown-field",
            "wrong-folder"
        ]
    );
    for status in host.list() {
        assert_eq!(status.state, PluginState::Failed, "{status:?}");
        assert!(!status.enabled);
        let reason = status.last_error.clone().unwrap();
        assert!(reason.starts_with("the manifest is invalid"), "{reason}");
    }
    let reason = |id: &str| status(&host, id).last_error.unwrap();
    assert!(
        reason("unknown-field").contains("enabled"),
        "{}",
        reason("unknown-field")
    );
    assert!(
        reason("wrong-folder").contains("folder"),
        "{}",
        reason("wrong-folder")
    );
    assert!(
        reason("pattern").contains("pattern"),
        "{}",
        reason("pattern")
    );
    assert!(reason("no-manifest").contains("obi-plugin.json"));
    // What could be read is shown.
    assert_eq!(status(&host, "pattern").name, "MCP only");
    assert_eq!(status(&host, "pattern").kinds, [Kind::AgentMcp]);
    assert_eq!(status(&host, "not-json").name, "not-json");

    // Enabling one keeps the choice but it stays failed; settings for it can't be checked.
    let enabled = host.set_enabled(&id("pattern"), true, None).await.unwrap();
    assert!(enabled.enabled);
    assert_eq!(enabled.state, PluginState::Failed);
    assert!(matches!(
        host.set_enabled(&id("pattern"), true, Some(json!({})))
            .await,
        Err(PluginError::Config(_))
    ));
    assert!(host.agent_mcp_servers().is_empty());
    host.shutdown().await;
}

#[tokio::test]
async fn enabling_checks_the_settings_and_keeps_the_choice() {
    let home = Home::new("settings");
    home.install_manifest("mcp-only", &mcp_only("mcp-only"));
    // Another plug-in's entry, not installed: kept as it is.
    std::fs::write(
        home.path.join("plugins.json"),
        r#"{"gone": {"enabled": true, "config": {"x": 1}}}"#,
    )
    .unwrap();
    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    let mcp = id("mcp-only");

    // 404 and 422 change nothing.
    assert_eq!(
        host.set_enabled(&id("nope"), true, None).await,
        Err(PluginError::Unknown(id("nope")))
    );
    for bad in [
        json!({"depth": 9}),
        json!({"other": 1}),
        json!([]),
        json!("x"),
    ] {
        assert!(
            matches!(
                host.set_enabled(&mcp, true, Some(bad.clone())).await,
                Err(PluginError::Config(_))
            ),
            "{bad}"
        );
    }
    assert_eq!(
        home.settings().unwrap(),
        json!({"gone": {"enabled": true, "config": {"x": 1}}})
    );
    assert!(!status(&host, "mcp-only").enabled);

    // Enabled with settings: ready at once (no process), its server offered, kept.
    let enabled = host
        .set_enabled(&mcp, true, Some(json!({"depth": 2})))
        .await
        .unwrap();
    assert!(enabled.enabled);
    assert_eq!(enabled.state, PluginState::Ready);
    assert_eq!(host.agent_mcp_servers().len(), 1);
    assert_eq!(
        home.settings().unwrap(),
        json!({"gone": {"enabled": true, "config": {"x": 1}},
               "mcp-only": {"enabled": true, "config": {"depth": 2}}})
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(home.path.join("plugins.json"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    // Disabled without settings: the settings are kept.
    let disabled = host.set_enabled(&mcp, false, None).await.unwrap();
    assert_eq!(disabled.state, PluginState::Disabled);
    assert!(!disabled.enabled);
    assert!(host.agent_mcp_servers().is_empty());
    assert_eq!(
        home.settings().unwrap()["mcp-only"],
        json!({"enabled": false, "config": {"depth": 2}})
    );
    host.shutdown().await;

    // A new host (obid restarted) starts what was enabled, with what was kept.
    host_restarts_with_the_choice(&home).await;
}

async fn host_restarts_with_the_choice(home: &Home) {
    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    assert_eq!(status(&host, "mcp-only").state, PluginState::Disabled);
    host.set_enabled(&id("mcp-only"), true, None).await.unwrap();
    host.shutdown().await;

    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    let mcp = status(&host, "mcp-only");
    assert!(mcp.enabled);
    assert_eq!(mcp.state, PluginState::Ready);
    assert_eq!(host.agent_mcp_servers()[0].0, id("mcp-only"));
    host.shutdown().await;
    // After shutdown nothing runs, and nothing can be enabled.
    assert!(host.agent_mcp_servers().is_empty());
    assert_eq!(status(&host, "mcp-only").state, PluginState::Disabled);
    assert_eq!(
        host.set_enabled(&id("mcp-only"), true, None).await,
        Err(PluginError::Stopped)
    );
}

#[tokio::test]
async fn a_plugin_without_a_config_schema_takes_no_settings() {
    let home = Home::new("noschema");
    let mut manifest = mcp_only("plain");
    manifest.as_object_mut().unwrap().remove("config");
    home.install_manifest("plain", &manifest);
    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    assert!(matches!(
        host.set_enabled(&id("plain"), true, Some(json!({"a": 1})))
            .await,
        Err(PluginError::Config(_))
    ));
    let status = host
        .set_enabled(&id("plain"), true, Some(json!({})))
        .await
        .unwrap();
    assert_eq!(status.state, PluginState::Ready);
    host.shutdown().await;
}

#[tokio::test]
async fn a_plugins_json_that_cannot_be_read_enables_nothing() {
    let home = Home::new("corrupt");
    home.install_manifest("mcp-only", &mcp_only("mcp-only"));
    std::fs::write(
        home.path.join("plugins.json"),
        "{\"mcp-only\": {\"enabled\": tru",
    )
    .unwrap();
    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    assert!(!status(&host, "mcp-only").enabled);
    assert_eq!(status(&host, "mcp-only").state, PluginState::Disabled);
    host.shutdown().await;

    // Saved settings that no longer match the schema: failed, with the reason, not started.
    std::fs::write(
        home.path.join("plugins.json"),
        r#"{"mcp-only": {"enabled": true, "config": {"depth": 7}}}"#,
    )
    .unwrap();
    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    let mcp = status(&host, "mcp-only");
    assert_eq!(mcp.state, PluginState::Failed);
    assert!(mcp.last_error.unwrap().contains("config.depth"));
    assert!(host.agent_mcp_servers().is_empty());
    // Enabling it with settings that match starts it.
    let fixed = host
        .set_enabled(&id("mcp-only"), true, Some(json!({"depth": 1})))
        .await
        .unwrap();
    assert_eq!(fixed.state, PluginState::Ready);
    host.shutdown().await;
}

#[tokio::test]
async fn the_spec_times_are_the_defaults() {
    let defaults = obi_plugin_host::Options::default();
    assert_eq!(defaults.initialize_timeout, Duration::from_secs(10));
    assert_eq!(defaults.ping_interval, Duration::from_secs(60));
    assert_eq!(defaults.ping_timeout, Duration::from_secs(5));
    assert_eq!(defaults.context_timeout, Duration::from_secs(5));
    assert_eq!(
        defaults.restart_delays,
        [1, 2, 4].map(Duration::from_secs).to_vec()
    );
    assert_eq!(defaults.stop_grace, Duration::from_secs(5));
    assert_eq!(defaults.sandbox_program, None);
}
