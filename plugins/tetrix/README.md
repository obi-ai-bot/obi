# Tetrix

Tetrix is a code graph and memory for agents. This plug-in lets a job's agents call Tetrix's MCP server. Obi works fully without it. It is **disabled** until the owner enables it, the same way as any other plug-in (docs/ARCHITECTURE.md, section 5).

- **Kind:** `agent-mcp` only. `obid` adds the server to each job's agent MCP configuration, and its permission gate refuses every Tetrix tool not listed below. It may add `context` later.
- **No process.** An `agent-mcp`-only plug-in may leave `run` out (docs/ARCHITECTURE.md 5.2), and this one has nothing to run. So no sandbox is needed and the plug-in is `ready` as soon as it is enabled. (The manifest example in docs/ARCHITECTURE.md 5.2 shows a `run` of `bin/tetrix-plugin`. Nothing needs it in this version.)
- **Settings:** none. Its `config` schema takes only `{}`.
- **Login:** the agent tool's own. Each account signs its agents in to Tetrix through its tool's OAuth (`/mcp` in Claude Code, `codex mcp login tetrix`, `cursor-agent mcp login tetrix`), as `Engine/TetrixUse.swift`'s `signInScript` does today. The manifest holds no secret, and no vault secret reaches the server.

## The tools agents may call

These are the tools `Engine/Jobs.swift` (`Policy.tetrixTools`) allows today: the graph reads, the digests of earlier sessions, and saving the agent's own session.

| Tool | What it gives |
|---|---|
| `graph_summary`, `search_entities`, `get_entity`, `operational_context`, `impact_radius`, `service_topology`, `code_impact`, `query_graph` | The graph: entities, owners, related pull requests and commits, impact. |
| `repo_sessions`, `list_sessions`, `session_context`, `session_digest` | What earlier sessions on the same work decided, touched and left open. |
| `save_session` | Saves the agent's own session. Commits name it in a `Tetrix-Session:` trailer. |

`resume_session` stays out because it returns the owner's private session state. So do Tetrix's admin, write and diagnostics tools.

## Enable it

```sh
curl -X PUT -H "Authorization: Bearer $OBID_API_TOKEN" \
  -d '{"enabled": true}' http://127.0.0.1:<port>/v1/obid/plugins/tetrix
```

`{"enabled": false}` disables it. `GET /v1/obid/plugins` lists it either way (docs/runner-api.md, "obid only: plug-ins").

## The server's address

`agentMcp.server.url` is still the placeholder from docs/ARCHITECTURE.md 5.2, `https://mcp.tetrix.example/mcp`. Two things are still open, and each needs the lead: the real Tetrix MCP address, or a contract change that lets the owner's settings give the address. Until one of them is settled, an enabled Tetrix offers agents a server they can't reach. The plug-in's tests run against a stub Tetrix on 127.0.0.1, with no login and no network (`core/crates/obi-plugin-host/tests/tetrix.rs`).
