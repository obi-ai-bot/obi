# Oby's architecture

How Oby is put together once the engine runs as the Rust daemon `obid`, where every piece lives, which lines nothing crosses, and who edits what while Phase 1 is under way. It follows the plan in [docs/NEXT-STEPS.md](NEXT-STEPS.md) (section 4, "Target layout"); the contracts it relies on are:

- [docs/runner-api.md](runner-api.md): the API between `obid` and every shell, including its "obid only" section.
- The Obi-to-Obi protocol v0.1: `spec/` in [obi-ai-bot/obi-sphere](https://github.com/obi-ai-bot/obi-sphere).
- [e2e/SCENARIO.md](../e2e/SCENARIO.md): the run that says Phase 1 is done.

Decided and not reopened here: the product is Oby (apps, bundle ids, `window.oby`); Apache-2.0; the engine moves from Swift to `obid` behind the existing runner API; the UI shells stay native and thin; the Sphere server is TypeScript on Cloudflare Workers with D1; Tetrix is an optional plug-in; Deskree's own pipeline rules become configuration. The GitHub org, the repository names and the daemon keep the `obi` spelling.

## 1. Layout

```
obi/
├── core/            Rust: the daemon obid and its crates (section 3)
├── apps/
│   ├── web/         TypeScript universal client, served by obid
│   ├── mac/         Swift: window, menu bar, Touch ID, character; a thin client of obid
│   ├── ios/         Swift thin client
│   ├── watch/       Swift thin client
│   └── android/     Kotlin thin client, later
├── character/       The three.js mascot, unchanged
├── plugins/         Context providers and event sources, each optional; Tetrix is one of them
├── mcp/             The Oby MCP server
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
- **Loopback and a token.** `obid` listens on 127.0.0.1 only, checks `Host`, and answers only requests with its API token; remote devices reach it through the gateway's allowlist, as today. The web app (`apps/web`) is no exception: the page sends the token on every API call, from the browser's session storage for its own origin. The one thing obid opens without the token is reading the web app's own files under `/app/`, which hold no data, with a page session: a random value obid keeps in memory, opened by signing in with the token and ended by signing out or a restart. It exists because a browser can't send a header when it opens a page and #492 keeps the page closed without the token; it admits nothing under `/v1`, since anything on the machine can replay a cookie and the headers a browser adds (runner-api.md, "obid only: the web app"). On macOS it listens on `127.0.0.1:7777` unless its configuration says otherwise: the address the Mac app already uses for a runner on the same Mac (runner-api.md, "Reaching it" and "obid only: configuration"). The Oby app's own Swift runner (its login item) listens there too, so one Mac runs one of the two: when the address is taken, `obid` doesn't start and says why in one line; it never moves to another port by itself. Its API token is only ever in `home/api-token`, never in its environment or arguments (5.3).
- **The existing Mac app on `obid`.** In Phase 1 the Mac app is shown to pair with `obid` and list its jobs by a test that builds the app's own client code and drives it against a running `obid` (the Rust core's, section 6: it builds the app's files where they are and edits none of them). For This Mac, the app reads `api-token` from `~/Library/Application Support/Oby/Runner` (configure obid with that home and the default port); the Swift runner's keychain item remains its fallback. See runner-api.md, "obid only: configuration" (#440).

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

What crosses into Oby, and what it may become:

| Comes from | Arrives as | May become |
|---|---|---|
| The owner (a shell, the MCP server) | Runner API calls with the API token | Anything the API offers: goals, answers, settings, publishing by hand with a device signature. |
| Another Oby | A signed, typed action through the Sphere, checked against the spec (schema, signature, expiry, policy) | Only what the receiver's decision rule allows (spec `protocol.md` section 11): an inbox item, work a remembered decision covers, or, for a `question`, an `answer` the Oby writes by itself from what one of its owner's sharing rules allows (a model run on the owner's account, limited per sender), and then only the typed reply to that action. Never a merge, a push, a published change, a changed setting or a changed decision. |
| GitHub, Slack, web pages, plug-ins, other people | Data | Quoted to agents as files (`.obi/inputs/`, `.obi/context/`), shown to the owner. Never part of a prompt's instructions. |
| Connected apps (through `obid`'s broker) | MCP tool results the agent asked for, with the vault's secrets taken out, each block fenced as quoted data (#575) | Untrusted data inside the agent's context, labelled: every block of a broker result is text between `<<<quoted-<nonce>` and `quoted-<nonce>>>>`, with a random nonce per job that is taken out of the text first, so nothing an app answers can close its fence; the job's prompt says once what the fence means. Non-text blocks (resource links, embedded resources) become fenced JSON text, images and audio stay as they are, and `structuredContent` is dropped (and `outputSchema` with it), since MCP asks a tool that returns it to send the same in a text block, which is fenced. Even so, it can steer the agent within what the agent may do, never past `obid`'s rules: the broker forwards only read-only tools, and agents can't publish. |
| `agent-mcp` plug-ins' servers | MCP tool results the agent asked for, straight from the plug-in's server | Untrusted data inside the agent's context, not marked as data: `obid` isn't between the agent and these servers. It can steer the agent within what the agent may do, never past `obid`'s rules. |
| Agents (their output, their questions) | Data and typed requests (permission prompts, `QUESTION:` lines) | What `obid`'s fixed rules and the owner's saved rules allow. In the default `sandbox` mode, `obid` answers by itself, and records on the job, whatever stays inside the job's OS sandbox (edits in its worktree, commands, tests, reads); what leaves it or sticks (the network beyond the model's API, secrets or the vault, a read outside the worktree, standing rules) and the agent's own questions wait in the inbox (runner-api.md, "obid only: permissions answered without the owner"). |

The rules every component keeps:

- **Typed actions in, data never instructions.** Other Obys can only send the eight typed actions; there is no free-text type, and a field the schema doesn't list makes a message invalid. Every human-written field (`x-obi-text: data` in the spec) reaches an agent only as a quoted file and the owner only as text. The same holds for text from GitHub, Slack, plug-ins and fixtures.
- **The publish gate.** Nothing leaves `obid` (a push, a pull request, its description, a check run, an Obi-to-Obi reply) until the secret scan has passed on everything in it, with the vault's secrets and their encoded forms. If the scanner can't run, nothing goes out.
- **Oby never merges.** Not on its owner's behalf, not on anyone else's. The Swift runner's squash-merge into `dev` after a Mac check is not ported to `obid`; merging is a person's step. Deskree's own promotion rules (Xcode Cloud, `dev` to `main`, the three-review escalation) become configuration that changes what Oby checks and reports, never something that merges.
- **Agents can't publish.** They run in sandboxed worktrees with no code-host login, no vault secret, and a clone whose push URL is invalid. Only the publish gate pushes, and only the owner's own work.
- **Secrets stay in the vault.** No agent, plug-in or other Oby receives a vault secret, in any form. No vault secret and no token is ever in `obid`'s environment or arguments either, because other processes of the same user can read those (5.3, "What the sandbox can't hide").
- **Telemetry is off** unless the owner turns it on.

## 5. Plug-ins

A plug-in adds context or events to Oby. Oby works fully with none: a fresh install has **zero plug-ins enabled**, and Tetrix is the first plug-in, shipped **disabled**, enabled the same way as any other.

### 5.1 Kinds

| Kind | What it gives | Used when |
|---|---|---|
| `context` | Context items for a job: past work, decisions, a code graph's answers. | `obid` dispatches, plans or reviews a job: it asks every enabled context plug-in and quotes the answers to the agent as data. |
| `events` | Events from outside: a review was requested, an issue was assigned. | Continuously, while enabled: each event becomes an inbox item of kind `pluginEvent` for the owner to read (runner-api.md, "obid only: plug-ins"). In this version an event never starts work, and no remembered decision applies to events. |
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
    "server": {"type": "http", "urlFromConfig": "url"},
    "allowedTools": ["search_entities", "get_entity", "code_impact", "save_session"]
  },
  "network": [],
  "config": {"type": "object", "additionalProperties": false, "required": ["url"],
             "properties": {"url": {"type": "string", "pattern": "^https://", "maxLength": 2048}}}
}
```

- `id`: lower-case letters, digits and hyphens, unique; the folder's name. `oby` is reserved: it is the connected-app broker's server name in an agent's MCP config.
- `kinds`: one or more of `context`, `events`, `agent-mcp`.
- `run`: the process to start, relative to the plug-in's folder: needed for `context` and `events`; an `agent-mcp`-only plug-in may leave it out.
- `agentMcp`: for `agent-mcp`, the server (`{"type": "http", "url"}`, `{"type": "http", "urlFromConfig": "<config key>"}` or `{"type": "stdio", "command", "args"}`) and the only tools agents may call. With `urlFromConfig` the server's URL is the owner's setting under that key: the manifest's `config` schema must require the key and give it no default, so the plug-in can't be enabled (`422`) until the owner has set it. A server that needs a secret in its configuration is refused: logins are the server's own (OAuth in its own store), never a vault secret.
- Tetrix's MCP URL is such a setting: `url`, required, with no default. Its manifest names no host of its own: there is no placeholder URL to fall back on.
- `events`: required for an `events` plug-in and refused on any other: `{"kinds": [ … ]}`, the event kinds it may emit (5.4), like `{"kinds": ["pull_request.review_requested", "issue.assigned"]}`. An event of a kind not listed is refused.
- `network`: the hosts it talks to, shown to the owner before enabling, together with the host of a server URL that comes from its settings. Declared in this version, not enforced.
- `config`: a JSON Schema for its settings; the owner's settings must match it.

There is no field that enables a plug-in by itself.

### 5.3 Lifecycle

1. **Discovered.** At start, `obid` first installs every plug-in it ships (this repository's `plugins/<id>`) into `home/plugins/<id>` when `home/plugins/<id>` is missing, **disabled**: the Rust core does this before it calls `PluginHost::start`, which then discovers what is in `home/plugins/`. A folder already there is left as it is, and so is whether the owner enabled it. Then it reads every `home/plugins/<id>/obi-plugin.json`. A manifest that doesn't parse or match is listed with `state` `failed` and its reason.
2. **Enabled or not.** Only the owner enables one: `PUT /v1/obid/plugins/{id}` with `{"enabled": true}` (runner-api.md, "obid only: plug-ins"), kept in `home/plugins.json`. Disabled is the default, for every plug-in.
3. **Started.** An enabled plug-in with `run` is started in its own sandbox, made with **bubblewrap on Linux and a Seatbelt profile run with `sandbox-exec` on macOS**, the same tools as the job sandbox (runner-api.md, "obid only: Obi-to-Obi review jobs"). For the plug-in's process and everything it starts:
   - **Writes** go only to `home/plugin-data/<id>/`, its working directory, which is also its `HOME` and holds its `TMPDIR` (`home/plugin-data/<id>/tmp/`).
   - **Reads, from `obid`'s `home`**: its own folder `home/plugins/<id>/` (read-only) and its data folder. Nothing else of `home`: no worktrees, clones, database, keys, `api-token`, other plug-ins' folders.
   - **Reads elsewhere**: the system's files and the tools it runs (read-only); not the person's real `HOME`.
   - **Environment**: only `PATH`, `HOME`, `LANG` and `TMPDIR`; no vault secret, no token, no code-host login.
   - **Network**: allowed (a plug-in talks to the hosts its manifest's `network` lists; declared, not enforced, in this version). On Linux the plug-in has a network namespace of its own (`--unshare-net`) with `slirp4netns` in it, so an abstract-namespace Unix socket on the host (an address starting with a NUL byte, which has no file) is not reachable, and the hosts it needs still are. An agent is the same (`an_agent_reaches_its_api_but_not_an_abstract_socket`, `a_sandboxed_plugin_reaches_the_network_but_not_an_abstract_socket`). The repository's check has no network at all.
   - **macOS services** (the job sandbox denies the same, runner-api.md, "The job sandbox"): no preference reads or writes through `cfprefsd` outside its own `HOME` (the profile denies `user-preference-read` and `user-preference-write` and the `com.apple.cfprefsd.daemon` and `com.apple.cfprefsd.agent` mach services, or does something else a test proves equivalent), no pasteboard (`com.apple.pasteboard.1`), and no keychain through `securityd` (`com.apple.SecurityServer`) where Seatbelt allows denying it. Each is shown by a test that tries it from inside the sandbox.
   - **Its processes**: `obid` tracks every process the plug-in starts, including any that left its process group or session (`setsid`), so that stopping it ends all of them (step 6).

   When `obid` can't make this sandbox on the machine, the plug-in isn't started: its `state` is `failed`, with the reason. On macOS the profile denies `file-write*` everywhere but the data folder and `file-read*` under `home` but the two folders above.

   **What the sandbox can't hide**. On macOS a process can read the arguments of every other process of the same user (`sysctl` `KERN_PROCARGS2`), and the environment when the kernel still includes it, and Seatbelt can't block that read. So **no vault secret and no token is ever in `obid`'s environment or arguments**: `obid` takes its API token only from `home/api-token` (runner-api.md, "obid only: configuration"), reads the vault itself, and gets its Sphere token over HTTP. `a_sandboxed_job_reads_other_processes_but_finds_no_secret` and `a_sandboxed_plugin_reads_other_processes_but_finds_no_secret` show a sandboxed job and a sandboxed plug-in can read a marker planted in another process's arguments, and that the API token and a vault secret kept only in files are in no process's arguments or environment.

   What else Seatbelt can't enforce, on the job sandbox or this one, with the test that shows the part it does hold:

   - **A keychain file outside the person's home.** securityd's file-based keychains stay reachable, so a keychain file the job can read, outside the hidden homes and unlocked by the person, gives up the items whose access list lets the reading program in. `a_job_reaches_no_preferences_pasteboard_or_keychain` shows the person's login keychain (a file in their home) and secd are out of reach.
   - **A job's own preferences.** cfprefsd keeps preferences in the person's home whatever the job's `HOME` says, so the profile denies preference reads and writes. The same test shows a job has none.
4. **Initialized.** `obid` sends `initialize`; the plug-in has 10 seconds to answer. Then `state` is `ready`.
5. **Running.** `ping` every 60 seconds; a plug-in that doesn't answer within 5 seconds, or exits, has failed. After its first failure in a row it is restarted after 1 second, after its second after 2 seconds, and its **third failure in a row** makes its `state` `failed`: it stays stopped until the owner enables it again. An answered `ping` ends the run of failures.
6. **Stopped.** On disable or when `obid` stops: `shutdown`, then stdin closes; a plug-in still running 5 seconds later is killed. Either way **no process it started is left running**: `obid` kills the whole tree it tracked, descendants that called `setsid` included (on Linux bubblewrap's own PID namespace with `--die-with-parent`; on macOS the sandbox's watcher kills every process in the sandbox, and if the plug-in killed that watcher first the host kills whatever is still in that sandbox).

A plug-in never blocks Oby: a context query that fails or is late gives no context and the job goes on; a failed plug-in only shows in `GET /v1/obid/plugins`.

### 5.4 Wire protocol: `obi-plugin/0.1`

JSON-RPC 2.0 over the plug-in's stdin and stdout, one JSON object per line (split on `\n` only), UTF-8. stderr goes to `obid`'s log, at most 64 KB per minute, as events of the `tracing` target `obi_plugin`, and so does every `log` notification. **The vault's secrets, and their encoded forms, are taken out by `obid`'s log layer for that target** before anything is written: the layer is the Rust core's, and the plug-in host only logs to the target, never writes a log of its own.

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
- Event `kind`s in this version: `pull_request.review_requested`, `pull_request.changes_requested`, `issue.assigned`, `check.failed`, `mention`. Each accepted event becomes one inbox item of kind `pluginEvent` (runner-api.md, "obid only: plug-ins", where its fields and its one answer are defined). Events never start work, and no remembered decision covers them in this version: acting on an event is the owner's step. Remembered decisions for events, and work started from them, are a later version's, specified in runner-api.md before anyone builds them.

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
    pub fn take_events(&self) -> Option<tokio::sync::mpsc::Receiver<PluginEvent>>; // Some on the first call only, None after
    pub async fn shutdown(&self);
}
```

The plug-in boundary's first pull request is these two crates with exactly these signatures, `start` finding no plug-ins yet (so `list` is empty, `context` and `agent_mcp_servers` give nothing, and the receiver from `take_events` never yields). Every event from every plug-in goes to that one receiver: `take_events` hands it over on its first call and answers `None` on every later call, so there is one consumer (`obid`, which takes it once at start) and no event is split between two. The receiver ends (`recv` gives `None`) only after `shutdown`. From then on the Rust core depends on the real crates; it never writes a stand-in of its own. What `obid` does with the host (when it starts and stops it, the two HTTP routes, where context, MCP servers and events go) is the Rust core's; everything behind these signatures is the plug-in boundary's.

## 6. Phase 1: workstreams and who edits what

Four workstreams run in parallel and don't talk to each other. Each edits only what it owns; anything two of them share changes through the lead, in its own pull request, before either relies on the change. Every pull request goes into `dev`, and none merges another's.

| Workstream | Owns (may edit) | Must not touch |
|---|---|---|
| **Sphere server** (obi-sphere) | `obi-sphere/server/**`, the server's own CI workflow | `obi-sphere/spec/**` (changes go to the lead), anything in this repository |
| **Rust core** (`obid`) | `core/**` except the plug-in crates (including wiring `PluginHost` into `obid` and serving `GET` and `PUT /v1/obid/plugins` with it), the step bodies in `e2e/run.mjs` (the `run` of each entry in `steps`) and helper files it adds under `e2e/lib/`, new endpoints in runner-api.md's "obid only" section, `.github/workflows/core.yml`, installing the bundled plug-ins at start (5.3, step 1), and the Mac app's client test (below): `core/crates/obid/tests/mac_client.rs` and the files it adds under `core/crates/obid/tests/mac-client/` | `Engine/`, `Runner/`, `RunnerTests/` (frozen), `apps/**`, `plugins/**`, `core/crates/obi-plugin-*`, the lead's files below |
| **Repository restructure** | The moves in section 1 and the path changes they need (`Oby.xcodeproj`, the `path:` of `Package.swift` targets whose folders move, like `MCP/`, and the comments in `Package.swift`; paths in `.github/workflows/apple.yml`; scripts and docs links that name moved folders). In the frozen engine, only the hard-coded paths that point at moved folders, a bug fix the freeze allows: the path constants in `Engine/AppleChecks.swift` (`folders`, `promptedFolders`) and the paths in its `AppleCheck.agentLine`, `Engine/Checks.swift` (the `-project` arguments and the scheme path), `Engine/XcodeBuild.swift` (its paths) and `Engine/Review.swift` (the `securityPath` roots), and the `RunnerTests` assertions that name those paths (including the one in `RunnerTests/AppleCheckTests.swift` that quotes `AppleCheck.agentLine`'s text). In runner-api.md, only the sentences that list the apps' folders. | `core/`, `plugins/`, `e2e/`, `Makefile`, everything else in `Engine/`, `Runner/` and `RunnerTests/`, anything else in `Package.swift`, the rest of runner-api.md |
| **Plug-in boundary** | `plugins/**`, `core/crates/obi-plugin-api/**`, `core/crates/obi-plugin-host/**` | `core/Cargo.toml` (the `crates/*` glob picks its crates up), the rest of `core/`, `Engine/TetrixUse.swift` (frozen: it is the specification for the Tetrix plug-in) |
| **Lead** (Phase 0) | This document, `e2e/SCENARIO.md`, `e2e/fixtures/**`, `e2e/stub-agent/**`, the rest of `e2e/run.mjs` (preflight, the step loop, process handling), `e2e/lib/fixture.mjs`, `e2e/lib/scenario.mjs`, `e2e/lib/scenario-doc.mjs`, `e2e/lib/snapshot.mjs` (the scenario's fixed values and the checks' definitions), the `Makefile`, `.github/workflows/e2e.yml`, `docs/ci.md` (the list of every workflow and what each runs), `obi-sphere/spec/**`, and, for the bug fix for the five tests that already fail on `dev` under `swift test` (below), `RunnerTests/StartWhenTests.swift`, `RunnerTests/VaultTests.swift` and, in the frozen engine, only the clock `Engine/StartWhen.swift` reads and how `Engine/Publish.swift` runs gitleaks. Once the restructure is in `dev`: the old-layout paths left in `docs/runner-api.md` (beyond the sentences that list the apps' folders, which are the restructure's) and in `docs/research/` | |

Shared files and how they are shared:

- `core/Cargo.toml` and `core/Cargo.lock`: the Rust core creates them first. The plug-in boundary uses only `[workspace.dependencies]`; when it needs another dependency it asks the core's owner to add it there. A conflict in `Cargo.lock` is settled by regenerating it.
- runner-api.md: the Rust core adds endpoints to "obid only"; the plug-in endpoints there are already written.
- `.github/workflows/`: each workstream adds its own file and edits only its own. `e2e.yml` and the `Makefile` are the lead's and already build `obid` for `make e2e` (`cargo build --locked -p obid` in `core/` once `core/Cargo.toml` exists, with a stable Rust toolchain in CI), so no workstream needs to edit them to reach its done-when; a change one needs goes to the lead.

The five tests that already fail on `dev` under `swift test` (four date-dependent `StartWhenTests`, and `VaultTests`' `theSquashCommitIsScannedBeforeTheMerge`) are fixed by a separate bug-fix pull request from the lead, without weakening them (for example, the date-dependent tests get an injected clock, and the gitleaks test stops depending on the machine's gitleaks configuration and version while still asserting that the scan runs before the merge). No workstream fixes, skips or deletes them.

What waits on what (everything else runs in parallel):

1. `core/Cargo.toml` (the workspace) comes in the Rust core's first pull request. The plug-in boundary's crates build only inside it, so its first Rust pull request follows that one; until then it works on `plugins/tetrix/` (manifest, docs) and its tests' plug-ins.
2. The plug-in boundary's first Rust pull request is the two crates with section 5.5's signatures and a host that finds no plug-ins.
3. The Rust core wires `PluginHost` into `obid` (start and shutdown, `GET` and `PUT /v1/obid/plugins`, context for dispatch, plan and review, agent MCP servers, events into `pluginEvent` inbox items) once (2) is in `dev`, and does everything else before that.
4. The plug-in boundary's done-when goes through `obid`'s routes, so it is reached once (3) is in `dev`.
5. The repository restructure's done-when includes `swift test` passing for the frozen engine, so it is reached once the lead's bug fix for the five tests that already fail on `dev` (above) is in `dev`. Until then its pull requests show `swift test` failing in those five tests only, exactly as on `dev`.

### Order and done-when

**Sphere server.** The protocol types and checks against the conformance suite first (the server's checker passes `run.mjs --impl` for envelopes and cards and produces chains that pass it), then Spheres, tokens, invitations and the directory, then policy, send, deliveries and the audit chain, then `pnpm run local`. Done when steps 1, 3, 5 and 7 of SCENARIO.md pass against it with a scripted client, and the conformance suite passes.

**Rust core.** The workspace (`core/Cargo.toml`, `core/Cargo.lock`) and the runner API skeleton serving `GET /v1/status` and the configuration file first, then jobs, worktrees, the sandbox and the Claude Code adapter (stream-json) running the stub agent, then `obi-protocol` (passing the conformance suite with `--impl`), then Sphere membership, exchanges, the inbox item, decisions and the Obi-to-Obi review job with its publish gate, then the step bodies in `e2e/run.mjs`, then the plug-in host's wiring and routes (once the plug-in crates are in `dev`). Done when:

- **The scenario's `obid` steps pass with the stub adapter**: steps 2 to 8 of SCENARIO.md, with the Sphere server's steps, under `make e2e` on Linux and macOS.
- **The existing Mac app pairs with `obid` and lists its jobs**, shown by a test that builds the app's own client code and drives it against a running `obid` on `127.0.0.1` (section 2; the app discovers the private file token in the shared This Mac home, #440). The test is the Rust core's and lives in `core/`: `core/crates/obid/tests/mac_client.rs`, macOS only, compiles with `xcrun swiftc` the files the Mac app builds its client from, read where they are and never edited (`Shared/Runner.swift` with the `Shared/` files it needs, `Decisions.swift`, `JobList.swift`, `DeviceKey.swift` and `Elapsed.swift`, and `Engine/`, whose `Job` the Mac app reads jobs into; wherever the restructure has moved them), with `Package.swift`'s Swift settings, together with its own driver under `core/crates/obid/tests/mac-client/` (a `main.swift` that calls the client's `Runner(base:token:)`, `status()` and `jobs()`). It runs the driver against `obid` with the token from `obid`'s `home/api-token` and checks what the client decoded. It adds no target to `Package.swift` or the Xcode project and touches nothing under `apps/`, `Shared/` or `Engine/`.
- **`obid`'s side of 5.3 and 5.4**: its API token only from `home/api-token`, never from its environment or arguments, and no vault secret there either; `listen` defaulting to `127.0.0.1:7777` on macOS and refusing to start when the address is taken; the bundled plug-ins installed into `home/plugins/<id>` at start when missing, disabled, before `PluginHost::start` (a folder already there left as it is); and the log layer that takes the vault's secrets and their encoded forms out of the `obi_plugin` target. Each has a test.
- **The API-level tests for every feature `obid` implements pass**: the `RunnerTests` ported to it (`core/crates/obid/tests/PORTING.md`) and its own. Among those features: the job sandbox, with a test that shows an agent and the repository's check can't write outside the job's worktree, the worktree's git directory and the job's temporary folder, can't read `obid`'s `home` beyond the worktree and the clone's git common directory, nor reach the network for the check, on Linux and on macOS, and on macOS can't reach preferences outside their own `HOME`, the pasteboard or the keychain as section 5.3 says (runner-api.md, "The job sandbox"), and that nothing the agent or the check started is left running when the job stops or ends, a descendant that called `setsid` included, on Linux and on macOS; and `GET` and `PUT /v1/obid/plugins`, answering as runner-api.md says with the host from `obi-plugin-host`.

What `obid` doesn't implement yet is not part of this done-when. Each feature group whose `RunnerTests` stay unported (the 39 API-level tests PORTING.md lists as not ported: plans and the brain, the LAN gateway and pairing, the Watch API, speech, Mac and Apple checks, the owner's publishing, the vault, `startWhen`, usage, move, questions, Xcode Cloud, connections, and the rest) becomes **one GitHub issue per feature group** in obi-ai-bot/obi, labeled `core-port`, naming the Swift source to port and the `RunnerTests` that specify it. They are filed: [#442](https://github.com/obi-ai-bot/obi/issues/442) to [#458](https://github.com/obi-ai-bot/obi/issues/458), [label `core-port`](https://github.com/obi-ai-bot/obi/issues?q=label%3Acore-port), seventeen groups that between them name all 39 tests. The Rust core links each issue from its rows in PORTING.md, and files one the same way for any group that has none, when a test is added to the not-ported list.

**Repository restructure.** The moves in section 1, one area per pull request, the case-only renames (`Character/`, `MCP/`) each through a temporary name. Done when the Mac, iPhone and Watch apps build from their new places, `swift test` still passes for the frozen engine, and no folder differs from another only by case.

**Plug-in boundary.** The crates with the types, traits, wire protocol and a host that finds no plug-ins first (exactly section 5.5's signatures), then the host's discovery, sandbox and lifecycle behind them (`list` and `set_enabled` are what the Rust core's `GET` and `PUT /v1/obid/plugins` call), then `plugins/tetrix` as an `agent-mcp` plug-in, disabled. Done when:

- `obid` runs with no plug-ins enabled, and Tetrix is enabled and disabled through `PUT /v1/obid/plugins/tetrix` like any plug-in (the route is the Rust core's, the host behind it this workstream's).
- A test plug-in of each kind passes the host's tests.
- `plugins/tetrix/obi-plugin.json` takes its MCP URL from its settings (`"urlFromConfig": "url"`, the `url` key required with no default, and no placeholder URL or host in the manifest), and `obi-plugin-api` and `obi-plugin-host` implement `urlFromConfig` as 5.2 says: enabling Tetrix without a `url` answers `422`.
- The restart policy of 5.3 step 5 has a test: a plug-in that fails is restarted after 1 second, then after 2 seconds, and its third failure in a row makes it `failed`, with no fourth start.
- The plug-in sandbox's tests from inside the sandbox (5.3 step 3), on Linux and on macOS: writes only to the data folder, no reads of `home` beyond its two folders, only the four environment variables; on macOS, no preference read or write through `cfprefsd` outside its own `HOME`, no pasteboard and no keychain through `securityd` as 5.3 says. What Seatbelt can't enforce is listed in 5.3 and runner-api.md, "The job sandbox", with the test that shows it, and tracked in [#439](https://github.com/obi-ai-bot/obi/issues/439).
- A test that a plug-in disabled, and one still running when `obid` shuts down, leave no process running, including a descendant that called `setsid` (5.3 step 6), on Linux and on macOS.
- The host logs only to the `obi_plugin` target and writes no log of its own (5.4).
