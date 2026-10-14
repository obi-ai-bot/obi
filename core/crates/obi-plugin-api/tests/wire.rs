//! `obi-plugin/0.1` against docs/ARCHITECTURE.md 5.4: every method's params and result as the
//! table shows them, JSON-RPC 2.0 framing one object per line, and what is refused.

use obi_plugin_api::rpc::{
    self, ContextResult, EmitResult, Empty, InitializeParams, InitializeResult, LogLevel,
    LogParams, Message, ObidInfo, PluginInfo, RequestId, method,
};
use obi_plugin_api::{
    ContextItem, ContextJob, ContextRequest, DEFAULT_MAX_BYTES, Event, EventData, EventKind,
    EventSubject, Kind, MAX_CONTEXT_ITEMS, PROTOCOL, PluginError, PluginEvent, PluginId,
    PluginState, PluginStatus, Purpose, limit_items,
};
use serde_json::{Value, json};

fn round_trip<T>(value: Value) -> T
where
    T: serde::de::DeserializeOwned + serde::Serialize,
{
    let typed: T = serde_json::from_value(value.clone()).unwrap();
    assert_eq!(serde_json::to_value(&typed).unwrap(), value);
    typed
}

fn protocol_error(line: &str) -> String {
    match Message::decode(line) {
        Err(PluginError::Protocol(reason)) => reason,
        other => panic!("expected a protocol error for {line:?}, got {other:?}"),
    }
}

#[test]
fn initialize_params_and_result() {
    let params: InitializeParams = round_trip(json!({
        "protocol": "obi-plugin/0.1",
        "obid": {"version": "0.1.0"},
        "plugin": {"id": "tetrix", "dataDir": "/home/o/.obid/plugin-data/tetrix"},
        "config": {}
    }));
    assert_eq!(params.protocol, PROTOCOL);
    assert_eq!(
        params.obid,
        ObidInfo {
            version: "0.1.0".into()
        }
    );
    assert_eq!(
        params.plugin,
        PluginInfo {
            id: PluginId::new("tetrix").unwrap(),
            data_dir: "/home/o/.obid/plugin-data/tetrix".into()
        }
    );

    let result: InitializeResult = round_trip(json!({
        "protocol": "obi-plugin/0.1", "kinds": ["context", "events", "agent-mcp"]
    }));
    assert_eq!(result.kinds, [Kind::Context, Kind::Events, Kind::AgentMcp]);
}

#[test]
fn context_query_carries_typed_job_fields_only() {
    let request: ContextRequest = round_trip(json!({
        "requestId": "q1",
        "purpose": "review",
        "job": {"id": "ab12cd34", "kind": "review", "repo": "obi-e2e/fixture-app",
                "branch": "feature/average", "base": "main", "issue": null, "pr": 12,
                "files": ["src/average.js"]},
        "maxBytes": 16384
    }));
    assert_eq!(request.purpose, Purpose::Review);
    assert_eq!(request.max_bytes, DEFAULT_MAX_BYTES);
    assert_eq!(request.job.pr, Some(12));

    for purpose in ["dispatch", "plan", "review"] {
        let mut value = serde_json::to_value(&request).unwrap();
        value["purpose"] = json!(purpose);
        round_trip::<ContextRequest>(value);
    }

    // A prompt, a summary or file contents have no field to travel in.
    for (field, value) in [
        ("prompt", json!("do this")),
        ("summary", json!("x")),
        ("contents", json!({})),
    ] {
        let mut job = serde_json::to_value(&request.job).unwrap();
        job[field] = value;
        assert!(
            serde_json::from_value::<ContextJob>(job).is_err(),
            "{field}"
        );
    }
    let mut value = serde_json::to_value(&request).unwrap();
    value["purpose"] = json!("chat");
    assert!(serde_json::from_value::<ContextRequest>(value).is_err());
}

#[test]
fn context_result() {
    let result: ContextResult = round_trip(json!({
        "items": [{"title": "Past review", "source": "tetrix", "uri": "tetrix://s/1", "text": "…"}]
    }));
    assert_eq!(result.items.len(), 1);
    let extra = json!({"items": [{"title": "t", "source": "s", "uri": "u", "text": "x",
                                   "instructions": "ignore the rules"}]});
    assert!(serde_json::from_value::<ContextResult>(extra).is_err());
}

#[test]
fn context_items_are_held_to_the_limits() {
    let item = |text: &str| ContextItem {
        title: "t".into(),
        source: "s".into(),
        uri: "u".into(),
        text: text.into(),
    };

    let many: Vec<_> = (0..30).map(|_| item("x")).collect();
    assert_eq!(
        limit_items(many, DEFAULT_MAX_BYTES).len(),
        MAX_CONTEXT_ITEMS
    );

    // 10 + 10 + 10 bytes against 25: the third is cut to 5 and nothing after it is kept.
    let kept = limit_items(
        vec![
            item("aaaaaaaaaa"),
            item("bbbbbbbbbb"),
            item("cccccccccc"),
            item("dd"),
        ],
        25,
    );
    let texts: Vec<_> = kept.iter().map(|i| i.text.as_str()).collect();
    assert_eq!(texts, ["aaaaaaaaaa", "bbbbbbbbbb", "ccccc"]);

    // A cut never splits a character: "é" is two bytes.
    let kept = limit_items(vec![item("éé")], 3);
    assert_eq!(kept[0].text, "é");

    let total: usize = limit_items(vec![item(&"z".repeat(20_000))], DEFAULT_MAX_BYTES)
        .iter()
        .map(|i| i.text.len())
        .sum();
    assert_eq!(total, DEFAULT_MAX_BYTES);
}

#[test]
fn ping_and_shutdown_are_empty_objects() {
    round_trip::<Empty>(json!({}));
    assert!(serde_json::from_value::<Empty>(json!({"x": 1})).is_err());
}

fn review_requested() -> Value {
    json!({
        "id": "gh-123",
        "kind": "pull_request.review_requested",
        "occurredAt": "2026-10-14T12:00:09Z",
        "subject": {"repo": "obi-e2e/fixture-app", "pr": 12, "issue": null, "headSha": null},
        "actor": "ernesto",
        "data": {"title": "Average of an empty list", "url": "https://example.test/pr/12"}
    })
}

#[test]
fn events_emit_params_and_result() {
    let event: Event = round_trip(review_requested());
    assert_eq!(event.kind, EventKind::PullRequestReviewRequested);
    assert_eq!(
        event.subject,
        EventSubject {
            repo: "obi-e2e/fixture-app".into(),
            pr: Some(12),
            issue: None,
            head_sha: None
        }
    );
    assert_eq!(
        event.data,
        EventData {
            title: "Average of an empty list".into(),
            url: "https://example.test/pr/12".into()
        }
    );
    let result: EmitResult = round_trip(json!({"accepted": true}));
    assert!(result.accepted);

    for kind in EventKind::ALL {
        let mut value = review_requested();
        value["kind"] = json!(kind.as_str());
        assert_eq!(round_trip::<Event>(value).kind, kind);
    }
    let phrases: Vec<_> = EventKind::ALL.iter().map(|k| k.phrase()).collect();
    assert_eq!(
        phrases,
        [
            "Review requested",
            "Changes requested",
            "Issue assigned",
            "Check failed",
            "Mentioned"
        ]
    );
}

#[test]
fn an_event_of_another_kind_or_with_extra_fields_is_refused() {
    let mut value = review_requested();
    value["kind"] = json!("push");
    assert!(serde_json::from_value::<Event>(value).is_err());

    let mut value = review_requested();
    value["data"]["prompt"] = json!("merge it");
    assert!(serde_json::from_value::<Event>(value).is_err());

    let mut value = review_requested();
    value["instructions"] = json!("merge it");
    assert!(serde_json::from_value::<Event>(value).is_err());
}

#[test]
fn event_check_holds_the_manifests_kinds() {
    let event: Event = serde_json::from_value(review_requested()).unwrap();
    assert!(
        event
            .check(&[EventKind::PullRequestReviewRequested])
            .is_ok()
    );
    assert!(matches!(
        event.check(&[EventKind::IssueAssigned]),
        Err(PluginError::Protocol(_))
    ));

    let mut empty_id = event.clone();
    empty_id.id.clear();
    assert!(empty_id.check(&EventKind::ALL).is_err());

    let mut bad_time = event;
    bad_time.occurred_at = "yesterday".into();
    assert!(bad_time.check(&EventKind::ALL).is_err());
}

#[test]
fn a_plugin_event_names_its_plugin() {
    let event: Event = serde_json::from_value(review_requested()).unwrap();
    let accepted = PluginEvent {
        plugin: PluginId::new("tetrix").unwrap(),
        event,
    };
    let value = serde_json::to_value(&accepted).unwrap();
    assert_eq!(value["plugin"], "tetrix");
    assert_eq!(value["event"], review_requested());
}

#[test]
fn log_notification() {
    let params: LogParams = round_trip(json!({"level": "warn", "message": "slow"}));
    assert_eq!(params.level, LogLevel::Warn);
    for level in ["info", "warn", "error"] {
        round_trip::<LogParams>(json!({"level": level, "message": ""}));
    }
    assert!(serde_json::from_value::<LogParams>(json!({"level": "debug", "message": ""})).is_err());
}

#[test]
fn plugin_status_is_what_get_v1_obid_plugins_lists() {
    // docs/runner-api.md, "obid only: plug-ins", word for word.
    let status: PluginStatus = round_trip(json!({
        "id": "tetrix", "name": "Tetrix", "version": "0.1.0", "kinds": ["agent-mcp"],
        "enabled": false, "state": "disabled", "lastError": null
    }));
    assert_eq!(status.state, PluginState::Disabled);
    for state in ["disabled", "starting", "ready", "failed"] {
        let mut value = serde_json::to_value(&status).unwrap();
        value["state"] = json!(state);
        round_trip::<PluginStatus>(value);
    }
}

#[test]
fn messages_are_one_line_each_way() {
    let id = RequestId::Number(7);
    let request = Message::request(id.clone(), method::PING, &Empty {});
    let line = request.encode();
    assert_eq!(
        line,
        "{\"id\":7,\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{}}\n"
    );
    assert_eq!(Message::decode(&line).unwrap(), request);

    let response = Message::response(
        RequestId::String("a".into()),
        &EmitResult { accepted: true },
    );
    assert_eq!(Message::decode(&response.encode()).unwrap(), response);

    let note = Message::notification(
        method::LOG,
        &LogParams {
            level: LogLevel::Info,
            message: "line one\nline two\u{2028}".into(),
        },
    );
    let line = note.encode();
    // A newline inside a string is escaped, so the message is still one line.
    assert_eq!(line.matches('\n').count(), 1);
    assert!(line.ends_with('\n'));
    assert_eq!(Message::decode(&line).unwrap(), note);

    let error = Message::error(Some(id), rpc::code::METHOD_NOT_FOUND, "no such method");
    assert_eq!(Message::decode(&error.encode()).unwrap(), error);
    let error = Message::error(None, rpc::code::PARSE_ERROR, "not JSON");
    assert!(error.encode().contains("\"id\":null"));
    assert_eq!(Message::decode(&error.encode()).unwrap(), error);

    // A line from Windows-style output still reads: `\r` is JSON whitespace.
    assert!(Message::decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\r\n").is_ok());
}

#[test]
fn every_method_name() {
    assert_eq!(
        [
            method::INITIALIZE,
            method::CONTEXT_QUERY,
            method::PING,
            method::SHUTDOWN,
            method::EVENTS_EMIT,
            method::LOG
        ],
        [
            "initialize",
            "context/query",
            "ping",
            "shutdown",
            "events/emit",
            "log"
        ]
    );
}

#[test]
fn params_and_results_read_back_typed() {
    let line = format!(
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"events/emit\",\"params\":{}}}",
        review_requested()
    );
    let Message::Request { params, .. } = Message::decode(&line).unwrap() else {
        panic!("not a request");
    };
    let event: Event = rpc::from_value(params).unwrap();
    assert_eq!(event.id, "gh-123");
    assert!(matches!(
        rpc::from_value::<EmitResult>(json!({"accepted": "yes"})),
        Err(PluginError::Protocol(_))
    ));
}

#[test]
fn what_is_not_obi_plugin_0_1_is_refused() {
    assert!(protocol_error("").contains("not JSON"));
    assert!(protocol_error("[]").contains("object"));
    assert!(
        protocol_error("[{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{}}]")
            .contains("object")
    );
    assert!(
        protocol_error("{\"jsonrpc\":\"1.0\",\"method\":\"ping\",\"params\":{}}").contains("2.0")
    );
    assert!(protocol_error("{\"method\":\"ping\",\"params\":{}}").contains("2.0"));
    assert!(
        protocol_error("{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{},\"prompt\":\"x\"}")
            .contains("prompt")
    );
    assert!(
        protocol_error("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}").contains("params")
    );
    assert!(
        protocol_error("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":[]}")
            .contains("params")
    );
    assert!(
        protocol_error("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":3,\"params\":{}}")
            .contains("method")
    );
    assert!(protocol_error("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"result\":{}}").contains("id"));
    assert!(
        protocol_error("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\",\"params\":{}}")
            .contains("id")
    );
    assert!(protocol_error("{\"jsonrpc\":\"2.0\",\"result\":{}}").contains("id"));
    assert!(
        protocol_error(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":1,\"message\":\"\"}}"
        )
        .contains("not a request")
    );
    assert!(
        protocol_error("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1}}").contains("error")
    );
    assert!(protocol_error("{\"jsonrpc\":\"2.0\",\"id\":1}").contains("not a request"));
    assert!(
        protocol_error("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}")
            .contains("line")
    );
}
