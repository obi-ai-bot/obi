# Obi's architecture

How Obi is put together once the engine runs as the Rust daemon `obid`, where every piece lives, which lines nothing crosses, and who edits what while Phase 1 is under way. It follows the plan in [docs/NEXT-STEPS.md](NEXT-STEPS.md) (section 4, "Target layout"); the contracts it relies on are:

- [docs/runner-api.md](runner-api.md): the API between `obid` and every shell, including its "obid only" section.
- The Obi-to-Obi protocol v0.1: `spec/` in [obi-ai-bot/obi-sphere](https://github.com/obi-ai-bot/obi-sphere).
- [e2e/SCENARIO.md](../e2e/SCENARIO.md): the run that says Phase 1 is done.

Decided and not reopened here: the product is Obi (the code still says Oby); Apache-2.0; the engine moves from Swift to `obid` behind the existing runner API; the UI shells stay native and thin; the Sphere server is TypeScript on Cloudflare Workers with D1; Tetrix is an optional plug-in; Deskree's own pipeline rules become configuration.

## 1. Layout

```
obi/
├── core/            Rust: the daemon obid and its crates (section 3)
├── apps/
│   ├── web/         TypeScript universal client, served by obid
│   ├── mac/         Swift: notch, Touch ID, character; a thin client of obid
│   ├── ios/         Swift thin client
│   ├── watch/       Swift thin client
│   └── android/     Kotlin thin client, later
├── character/       The three.js mascot, unchanged
├── plugins/         Context providers and event sources, each optional; Tetrix is one of them
├── mcp/             The Obi MCP server
├── e2e/             The end-to-end scenario: SCENARIO.md, the harness, the stub agent, fixtures
├── docs/            Documentation
└── Makefile         make e2e, make e2e-live
```

Where today's folders go. Moves happen in the restructure workstream (section 6), with `git mv` so history follows:

| Today | Target | Note |
|---|---|---|
| `Engine/`, `Runner/`, `RunnerTests/`, `Package.swift` | stay where they are | Frozen (bug fixes only). They are the specification `core/` is ported from, and the Swift runner keeps running until the apps run on `obid`. |
| `Mac/`, `MacTests/` | `apps/mac/` | |
| `iOS/`, `iOSTests/`, `LiveActivity/` | `apps/ios/` | |
| `Watch/` | `apps/watch/` | |
| `Shared/` | `apps/shared/` | Swift code the Apple shells share. |
| `Oby.xcodeproj`, `Config/`, `Icon/`, `ExportOptions-DeveloperID.plist` | under `apps/` | The restructure decides the exact paths; the Apple apps must keep building. |
| `Android/` | `apps/android/` | |
| `Character/` | `character/` | Differs only by case: on macOS move it through a temporary name (`git mv Character character.tmp && git mv character.tmp character`). |
| `MCP/`, `MCPTests/` | `mcp/` | `MCP` to `mcp` differs only by case too: same two-step move. |
| `Desktop/` | stays | Open: `apps/web` may replace it (NEXT-STEPS.md, open decisions). |
| `cloud/control-plane/` | stays | Open: whether it merges into the Sphere server. |
| `spikes/`, `scripts/`, `docs/` | stay | |

## 2. The boundary: obid and the shells

```
 apps/mac   apps/ios   apps/watch   apps/web   mcp/
     │          │           │           │        │
     └──────────┴─── HTTP + SSE: docs/runner-api.md ───┘
                              │
                            obid  ── Obi-to-Obi client ──►  Sphere (obi-sphere/server)
                              │
             agents (Claude Code, Codex, Cursor) in sandboxed worktrees
                              │
                       plug-ins (out of process)
```

- **The runner API is the only way in.** Every shell talks to `obid` over HTTP and the `GET /v1/events` stream, exactly as the apps talk to the Swift runner today. No shell links the engine, imports its types or reads its database; `obid` serves the same API, so the Mac, iPhone and Watch apps run against it with no change to their code. Whether a later version adds an in-process binding (UniFFI) is an open decision; Phase 1 is HTTP only.
- **Change the API in the same pull request as the code** (AGENTS.md). New endpoints that only `obid` serves go in the "obid only" section of runner-api.md; the Swift runner is frozen and never implements them.
- **Loopback and a token.** `obid` listens on 127.0.0.1 only, checks `Host`, and answers only requests with its API token; remote devices reach it through the gateway's allowlist, as today.

## 3. Inside core/

`core/` is one Cargo workspace whose root `core/Cargo.toml` lists `members = ["crates/*"]`, so a new crate joins it without editing the root, and declares the shared dependency versions under `[workspace.dependencies]` (serde, serde_json, tokio, thiserror, tracing, async-trait). Crates use `workspace = true` for those.

| Crate | What | Owner in Phase 1 |
|---|---|---|
| `core/crates/obid/` | The daemon: configuration, the runner API and event stream, jobs, worktrees and sandbox, agent adapters (Claude Code stream-json first, then Codex app-server, then ACP), the planner, decision memory, the inbox, the publish gate (secret scan; never merges), the vault, accounts and usage. | Rust core |
| `core/crates/obi-protocol/` | Obi-to-Obi protocol v0.1: types, canonical JSON, Ed25519 signing and checks, the agent card, the token exchange, the Sphere client. Tested against obi-sphere's conformance suite (`--impl`). | Rust core |
| `core/crates/obi-plugin-api/` | The plug-in types, traits and wire protocol (section 5). | Plug-in boundary |
| `core/crates/obi-plugin-host/` | Finds, starts, sandboxes and talks to plug-ins; what `obid` calls. | Plug-in boundary |

How the engine's parts are split into modules inside `obid` is the Rust core's choice. What `obid` does is fixed by runner-api.md and by the Swift engine it is ported from, minus what this document removes.

## 4. Trust boundaries

What crosses into Obi, and what it may become:

| Comes from | Arrives as | May become |
|---|---|---|
| The owner (a shell, the MCP server) | Runner API calls with the API token | Anything the API offers: goals, answers, settings, publishing by hand with a device signature. |
| Another Obi | A signed, typed action through the Sphere, checked against the spec (schema, signature, expiry, policy) | Only what the receiver's decision rule allows (spec `protocol.md` section 11): an inbox item, or work a remembered decision covers, and then only the typed reply to that action. Never a merge, a push, a published change, a changed setting or a changed decision. |
| GitHub, Slack, web pages, plug-ins, other people | Data | Quoted to agents as files (`.obi/inputs/`, `.obi/context/`), shown to the owner. Never part of a prompt's instructions. |
| Agents (their output, their questions) | Data and typed requests (permission prompts, `QUESTION:` lines) | What `obid`'s fixed rules and the owner's saved rules allow; everything else waits in the inbox. |

The rules every component keeps:

- **Typed actions in, data never instructions.** Other Obis can only send the seven typed actions; there is no free-text type, and a field the schema doesn't list makes a message invalid. Every human-written field (`x-obi-text: data` in the spec) reaches an agent only as a quoted file and the owner only as text. The same holds for text from GitHub, Slack, plug-ins and fixtures.
- **The publish gate.** Nothing leaves `obid` (a push, a pull request, its description, a check run, an Obi-to-Obi reply) until the secret scan has passed on everything in it, with the vault's secrets and their encoded forms. If the scanner can't run, nothing goes out.
- **Obi never merges.** Not on its owner's behalf, not on anyone else's. The Swift runner's squash-merge into `dev` after a Mac check is not ported to `obid`; merging is a person's step. Deskree's own promotion rules (Xcode Cloud, `dev` to `main`, the three-review escalation) become configuration that changes what Obi checks and reports, never something that merges.
- **Agents can't publish.** They run in sandboxed worktrees with no code-host login, no vault secret, and a clone whose push URL is invalid. Only the publish gate pushes, and only the owner's own work.
- **Secrets stay in the vault.** No agent, plug-in or other Obi receives a vault secret, in any form.
- **Telemetry is off** unless the owner turns it on.

## 5. Plug-ins

A plug-in adds context or events to Obi. Obi works fully with none: a fresh install has **zero plug-ins enabled**, and Tetrix is the first plug-in, shipped **disabled**, enabled the same way as any other.

### 5.1 Kinds

| Kind | What it gives | Used when |
|---|---|---|
| `context` | Context items for a job: past work, decisions, a code graph's answers. | `obid` dispatches, plans or reviews a job: it asks every enabled context plug-in and quotes the answers to the agent as data. |
| `events` | Events from outside: a review was requested, an issue was assigned. | Continuously, while enabled: each event becomes an inbox item, or work that a remembered decision of the owner's covers (the same rule as a request from another Obi). |
| `agent-mcp` | An MCP server the job's agents may call, limited to tools the manifest lists. | Each job: `obid` adds the server to the agent's MCP configuration, and its permission gate refuses every tool not listed. |

Tetrix is an `agent-mcp` plug-in in its first version (its graph reads and `save_session`, as `Engine/TetrixUse.swift` allows today) and may add `context` later. The Swift engine's hard-coded Tetrix handling (`TetrixUse`, the reminders, the `Tetrix-Session` trailer, the account's `tetrix` fields) becomes per-plug-in: `obid` counts each `agent-mcp` plug-in's calls per job the way it counts Tetrix's today, and keeps filling the job's and account's `tetrix` keys from the plug-in with id `tetrix` (null when it isn't enabled), so the apps keep working.

### 5.2 Manifest

Each plug-in is a folder with `obi-plugin.json`:

```json
{
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
  "events": {"kinds": ["pull_request.review_requested", "issue.assigned"]},
  "network": ["mcp.tetrix.example"],
  "config": {"type": "object", "additionalProperties": false, "properties": {}}
}
```

- `id`: lower-case letters, digits and hyphens, unique; the folder's name.
- `kinds`: one or more of `context`, `events`, `agent-mcp`.
- `run`: the process to start, relative to the plug-in's folder: needed for `context` and `events`; an `agent-mcp`-only plug-in may leave it out.
- `agentMcp`: for `agent-mcp`, the server (`{"type": "http", "url"}` or `{"type": "stdio", "command", "args"}`) and the only tools agents may call. A server that needs a secret in its configuration is refused: logins are the server's own (OAuth in its own store), never a vault secret.
- `events.kinds`: the event kinds it may emit (5.4).
- `network`: the hosts it talks to, shown to the owner before enabling. Declared in this version, not enforced.
- `config`: a JSON Schema for its settings; the owner's settings must match it.

There is no field that enables a plug-in by itself.

### 5.3 Lifecycle

1. **Discovered.** At start, `obid` reads every `home/plugins/<id>/obi-plugin.json` (plug-ins this repository ships under `plugins/` are installed there). A manifest that doesn't parse or match is listed with `state` `failed` and its reason.
2. **Enabled or not.** Only the owner enables one: `PUT /v1/obid/plugins/{id}` with `{"enabled": true}` (runner-api.md, "obid only: plug-ins"), kept in `home/plugins.json`. Disabled is the default, for every plug-in.
3. **Started.** An enabled plug-in with `run` is started in its own sandbox: working directory `home/plugin-data/<id>/` (its only writable place), an environment with only `PATH`, `HOME` (that folder), `LANG` and `TMPDIR`, no vault secret, no token, no code-host login, no access to worktrees or `obid`'s own files (bubblewrap on Linux, as agents are).
4. **Initialized.** `obid` sends `initialize`; the plug-in has 10 seconds to answer. Then `state` is `ready`.
5. **Running.** `ping` every 60 seconds; a plug-in that doesn't answer within 5 seconds, or exits, is restarted after 1, 2, then 4 seconds; after three failures in a row its `state` is `failed` and it stays stopped until the owner enables it again.
6. **Stopped.** On disable or when `obid` stops: `shutdown`, then stdin closes; a plug-in still running 5 seconds later is killed.

A plug-in never blocks Obi: a context query that fails or is late gives no context and the job goes on; a failed plug-in only shows in `GET /v1/obid/plugins`.

### 5.4 Wire protocol: `obi-plugin/0.1`

JSON-RPC 2.0 over the plug-in's stdin and stdout, one JSON object per line (split on `\n` only), UTF-8. stderr goes to `obid`'s log with the vault's secrets taken out, at most 64 KB per minute.

Requests from `obid`:

| Method | Params | Result |
|---|---|---|
| `initialize` | `{"protocol": "obi-plugin/0.1", "obid": {"version"}, "plugin": {"id", "dataDir"}, "config": { … }}` | `{"protocol": "obi-plugin/0.1", "kinds": [ … ]}`: the kinds it serves now, a subset of its manifest's |
| `context/query` | `{"requestId", "purpose": "dispatch" \| "plan" \| "review", "job": {"id", "kind", "repo", "branch", "base", "issue", "pr", "files"}, "maxBytes": 16384}` | `{"items": [{"title", "source", "uri", "text"}]}`: at most 20 items, `text` in all at most `maxBytes`; 5 seconds to answer |
| `ping` | `{}` | `{}` |
| `shutdown` | `{}` | `{}` |

Requests from the plug-in (only for the kinds it serves):

| Method | Params | Result |
|---|---|---|
| `events/emit` | `{"id", "kind", "occurredAt", "subject": {"repo", "pr", "issue", "headSha"}, "actor", "data": {"title", "url"}}` | `{"accepted": true}`; an `id` seen before is accepted and ignored |
| `log` (notification) | `{"level": "info" \| "warn" \| "error", "message"}` | none |

- `job` in a context query carries typed fields only: no prompt, no summary, no file contents.
- Context `items` and event `data` are data. `obid` writes context items to `.obi/context/<plugin id>.md` in the job's worktree, fenced and labeled as quoted data, and shows event data to the owner as text. Neither is ever placed in a prompt as an instruction.
- Event `kind`s in this version: `pull_request.review_requested`, `pull_request.changes_requested`, `issue.assigned`, `check.failed`, `mention`. An event becomes an inbox item (kind `event`) unless a remembered decision of the owner's for `(event kind, plug-in id, repo)` covers it. Events never start work by themselves.

### 5.5 Rust interface

`core/crates/obi-plugin-api` holds the types (serde, matching the manifest and the wire protocol) and these traits, which built-in plug-ins may implement in process later; out-of-process plug-ins are adapted to them by the host:

```rust
pub const PROTOCOL: &str = "obi-plugin/0.1";

pub enum Kind { Context, Events, AgentMcp }

#[async_trait]
pub trait ContextProvider: Send + Sync {
    async fn query(&self, request: ContextRequest) -> Result<Vec<ContextItem>, PluginError>;
}

#[async_trait]
pub trait EventSource: Send + Sync {
    /// Runs until shutdown, sending each event to `sink`.
    async fn run(&self, sink: EventSink) -> Result<(), PluginError>;
}

pub trait AgentMcpProvider: Send + Sync {
    fn server(&self) -> &McpServerSpec;
    fn allowed_tools(&self) -> &[String];
}
```

`core/crates/obi-plugin-host` is all `obid` calls:

```rust
impl PluginHost {
    pub async fn start(home: &Path) -> Result<PluginHost, PluginError>;   // discover, start the enabled ones
    pub fn list(&self) -> Vec<PluginStatus>;                              // GET /v1/obid/plugins
    pub async fn set_enabled(&self, id: &PluginId, enabled: bool, config: Option<serde_json::Value>)
        -> Result<PluginStatus, PluginError>;                             // PUT /v1/obid/plugins/{id}
    pub async fn context(&self, request: ContextRequest) -> Vec<(PluginId, Vec<ContextItem>)>; // never fails
    pub fn agent_mcp_servers(&self) -> Vec<(PluginId, McpServerSpec, Vec<String>)>;
    pub fn events(&self) -> tokio::sync::mpsc::Receiver<PluginEvent>;
    pub async fn shutdown(&self);
}
```

Until the plug-in crates land, the Rust core codes against these signatures with a host that has no plug-ins; nothing else about plug-ins is the core's to decide.

## 6. Phase 1: workstreams and who edits what

Four workstreams run in parallel and don't talk to each other. Each edits only what it owns; anything two of them share changes through the lead, in its own pull request, before either relies on the change. Every pull request goes into `dev`, and none merges another's.

| Workstream | Owns (may edit) | Must not touch |
|---|---|---|
| **Sphere server** (obi-sphere) | `obi-sphere/server/**`, the server's own CI workflow | `obi-sphere/spec/**` (changes go to the lead), anything in this repository |
| **Rust core** (`obid`) | `core/**` except the plug-in crates, `e2e/run.mjs` and `e2e/lib/**` (the step bodies), new endpoints in runner-api.md's "obid only" section, `.github/workflows/core.yml` | `Engine/`, `Runner/`, `RunnerTests/` (frozen), `apps/**`, `plugins/**`, `core/crates/obi-plugin-*`, `e2e/SCENARIO.md`, `e2e/fixtures/**`, `e2e/stub-agent/**` |
| **Repository restructure** | The moves in section 1 and the path changes they need (`Oby.xcodeproj`, the `path:` of `Package.swift` targets whose folders move, like `MCP/`; paths in `.github/workflows/apple.yml`; scripts and docs links that name moved folders) | `core/`, `plugins/`, `e2e/`, `Makefile`, the contents of `Engine/`, `Runner/` and `RunnerTests/`, anything else in `Package.swift`, runner-api.md |
| **Plug-in boundary** | `plugins/**`, `core/crates/obi-plugin-api/**`, `core/crates/obi-plugin-host/**` | `core/Cargo.toml` (the `crates/*` glob picks its crates up), the rest of `core/`, `Engine/TetrixUse.swift` (frozen: it is the specification for the Tetrix plug-in) |
| **Lead** (Phase 0) | This document, `e2e/SCENARIO.md`, `e2e/fixtures/**`, `e2e/stub-agent/**`, `obi-sphere/spec/**` | |

Shared files and how they are shared:

- `core/Cargo.toml` and `core/Cargo.lock`: the Rust core creates them first. The plug-in boundary uses only `[workspace.dependencies]`; when it needs another dependency it asks the core's owner to add it there. A conflict in `Cargo.lock` is settled by regenerating it.
- runner-api.md: the Rust core adds endpoints to "obid only"; the plug-in endpoints there are already written.
- `.github/workflows/`: each workstream adds its own file and edits only its own.

### Order and done-when

**Sphere server.** The protocol types and checks against the conformance suite first (the server's checker passes `run.mjs --impl` for envelopes and cards and produces chains that pass it), then Spheres, tokens, invitations and the directory, then policy, send, deliveries and the audit chain, then `pnpm run local`. Done when steps 1, 3, 5 and 7 of SCENARIO.md pass against it with a scripted client, and the conformance suite passes.

**Rust core.** The runner API skeleton serving `GET /v1/status` and the configuration file first, then jobs, worktrees and the Claude Code adapter (stream-json) running the stub agent, then `obi-protocol` (passing the conformance suite with `--impl`), then Sphere membership, exchanges, the inbox item, decisions and the Obi-to-Obi review job with its publish gate, then the step bodies in `e2e/run.mjs`. Done when `make e2e` passes all eight steps on Linux and macOS, and the ported API-level tests from `RunnerTests` pass.

**Repository restructure.** The moves in section 1, one area per pull request, the case-only renames (`Character/`, `MCP/`) each through a temporary name. Done when the Mac, iPhone and Watch apps build from their new places, `swift test` still passes for the frozen engine, and no folder differs from another only by case.

**Plug-in boundary.** The crates with the types, traits and wire protocol first, then the host (discovery, sandbox, lifecycle, `GET` and `PUT /v1/obid/plugins` behind the interface above), then `plugins/tetrix` as an `agent-mcp` plug-in, disabled. Done when `obid` runs with no plug-ins enabled, Tetrix is enabled and disabled through `PUT /v1/obid/plugins/tetrix` like any plug-in, and a test plug-in of each kind passes the host's tests.
