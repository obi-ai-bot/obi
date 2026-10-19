# Tetrix

Tetrix is a code graph and memory for agents. This plug-in lets a job's agents call Tetrix's MCP server. Oby works fully without it. It is **disabled** until the owner enables it, the same way as any other plug-in (docs/ARCHITECTURE.md, section 5).

- **Kind:** `agent-mcp` only. `obid` adds the server to each job's agent MCP configuration, and its permission gate refuses every Tetrix tool not listed below. It may add `context` later.
- **No process.** An `agent-mcp`-only plug-in may leave `run` out (docs/ARCHITECTURE.md 5.2), and this one has nothing to run. So no sandbox is needed and the plug-in is `ready` as soon as it is enabled. (The manifest example in docs/ARCHITECTURE.md 5.2 shows a `run` of `bin/tetrix-plugin`. Nothing needs it in this version.)
- **Settings:** `url`, Tetrix's MCP server URL, required and with no default (`"urlFromConfig": "url"`, docs/ARCHITECTURE.md 5.2). The manifest names no server and no host of its own, so Tetrix can't be enabled until the owner gives the URL: `PUT /v1/obid/plugins/tetrix` without one answers `422`. The URL is held to the rule for a server URL in a manifest: `http` or `https`, with a host, and no login, query string or fragment (where a secret could ride).
- **Login:** Oby's, once, for every agent (the owner's decision of 2026-10-18, AGENTS.md). Settings › Connectors › Tetrix signs obid in (`POST /v1/tetrix/sign-in`, docs/runner-api.md, "obid only: Tetrix"); then every job's agent, Claude Code, Codex and Cursor on every account, gets obid's own MCP server named `tetrix` in place of this plug-in's, with a token for its job alone, and obid forwards the tools below with Oby's login. While Oby isn't signed in, this plug-in is what's left: a Claude Code agent gets the server at the URL the owner gave and signs in with the tool's own OAuth (`/mcp` in Claude Code), as `Engine/TetrixUse.swift`'s `signInScript` does. The manifest holds no secret either way, and no vault secret reaches the server through the plug-in.

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
  -d '{"enabled": true, "config": {"url": "https://<your Tetrix MCP server>/mcp"}}' \
  http://127.0.0.1:<port>/v1/obid/plugins/tetrix
```

`{"enabled": false}` disables it and keeps the URL for the next time. `GET /v1/obid/plugins` lists it either way (docs/runner-api.md, "obid only: plug-ins"). Agents get the server at the URL the owner gave, and only the tools above. With Oby signed in to Tetrix, nothing needs enabling here: obid's own server takes its place.

The plug-in's tests give it a stub Tetrix's URL on 127.0.0.1, with no login and no network (`core/crates/obi-plugin-host/tests/tetrix.rs`).
