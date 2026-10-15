//! The traits of docs/ARCHITECTURE.md 5.5, implemented in process by stub plug-ins of each kind:
//! a stub Tetrix (`agent-mcp`, no credentials, no network), a context provider and an event
//! source sending through an `EventSink`.

use std::sync::Arc;

use async_trait::async_trait;
use obi_plugin_api::{
    AgentMcpProvider, ContextItem, ContextJob, ContextProvider, ContextRequest, DEFAULT_MAX_BYTES,
    Event, EventData, EventKind, EventSink, EventSource, Kind, McpServerSpec, PROTOCOL,
    PluginError, Purpose,
};
use serde_json::json;

/// Tetrix as `Engine/TetrixUse.swift` uses it: an MCP server whose graph reads and
/// `save_session` agents may call. The URL is a name only; nothing connects to it.
struct StubTetrix {
    server: McpServerSpec,
    tools: Vec<String>,
}

impl StubTetrix {
    fn new() -> StubTetrix {
        StubTetrix {
            server: McpServerSpec::Http {
                url: "https://mcp.tetrix.example/mcp".into(),
            },
            tools: [
                "search_entities",
                "get_entity",
                "code_impact",
                "save_session",
            ]
            .map(String::from)
            .to_vec(),
        }
    }
}

impl AgentMcpProvider for StubTetrix {
    fn server(&self) -> &McpServerSpec {
        &self.server
    }

    fn allowed_tools(&self) -> &[String] {
        &self.tools
    }
}

struct EchoContext;

#[async_trait]
impl ContextProvider for EchoContext {
    async fn query(&self, request: ContextRequest) -> Result<Vec<ContextItem>, PluginError> {
        Ok(vec![ContextItem {
            title: format!("About {}", request.job.repo),
            source: "echo".into(),
            uri: format!("echo://{}", request.request_id),
            text: request.job.files.join(", "),
        }])
    }
}

struct TwoEvents;

#[async_trait]
impl EventSource for TwoEvents {
    async fn run(&self, sink: EventSink) -> Result<(), PluginError> {
        for (i, kind) in [EventKind::IssueAssigned, EventKind::Mention]
            .into_iter()
            .enumerate()
        {
            sink.send(Event {
                id: format!("e{i}"),
                kind,
                occurred_at: "2026-10-14T12:00:09Z".into(),
                subject: Default::default(),
                actor: "someone".into(),
                data: EventData::default(),
            })
            .await?;
        }
        Ok(())
    }
}

fn request() -> ContextRequest {
    ContextRequest {
        request_id: "q1".into(),
        purpose: Purpose::Dispatch,
        job: ContextJob {
            id: "ab12cd34".into(),
            kind: "fix".into(),
            repo: "obi-e2e/fixture-app".into(),
            files: vec!["src/average.js".into(), "src/greet.js".into()],
            ..Default::default()
        },
        max_bytes: DEFAULT_MAX_BYTES,
    }
}

#[test]
fn the_protocol_and_kinds() {
    assert_eq!(PROTOCOL, "obi-plugin/0.1");
    assert_eq!(
        serde_json::to_value([Kind::Context, Kind::Events, Kind::AgentMcp]).unwrap(),
        json!(["context", "events", "agent-mcp"])
    );
}

#[test]
fn a_stub_tetrix_is_an_agent_mcp_provider() {
    let tetrix: Arc<dyn AgentMcpProvider> = Arc::new(StubTetrix::new());
    assert_eq!(
        serde_json::to_value(tetrix.server()).unwrap(),
        json!({"type": "http", "url": "https://mcp.tetrix.example/mcp"})
    );
    assert!(tetrix.allowed_tools().iter().any(|t| t == "save_session"));
}

#[tokio::test]
async fn a_context_provider_answers_a_query() {
    let provider: Arc<dyn ContextProvider> = Arc::new(EchoContext);
    let items = provider.query(request()).await.unwrap();
    assert_eq!(items[0].title, "About obi-e2e/fixture-app");
    assert_eq!(items[0].text, "src/average.js, src/greet.js");
}

#[tokio::test]
async fn an_event_source_sends_through_its_sink() {
    let (sink, mut receiver) = EventSink::channel(4);
    let source: Arc<dyn EventSource> = Arc::new(TwoEvents);
    source.run(sink).await.unwrap();
    assert_eq!(
        receiver.recv().await.unwrap().kind,
        EventKind::IssueAssigned
    );
    assert_eq!(receiver.recv().await.unwrap().kind, EventKind::Mention);
    // The source ended and dropped its sink, so the channel ends.
    assert!(receiver.recv().await.is_none());
}

#[tokio::test]
async fn a_sink_whose_host_stopped_listening_says_so() {
    let (sink, receiver) = EventSink::channel(1);
    drop(receiver);
    assert!(sink.is_closed());
    assert_eq!(TwoEvents.run(sink).await, Err(PluginError::Stopped));
}
