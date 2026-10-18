# Cursor in Oby (#406)

Oby runs jobs on Cursor through `cursor-agent acp`, the Agent Client Protocol over stdio, with
the generic client in `Engine/ACP.swift` and Cursor's launch in `Engine/Cursor.swift`. This page
is what Oby relies on, and what the probe proved. Run the probe with
`scripts/cursor-probe.sh offline` and `scripts/cursor-probe.sh signed-in`.

## Probe results

Both halves of `scripts/cursor-probe.sh` were run by the user on tetrix-lab on 2026-10-14, with
cursor-agent 2026.10.12-d47ca18, signed in with one Cursor account. What follows is what that run
showed, and what Oby does about each.

| Fact | Result | What Oby does |
| --- | --- | --- |
| Where the login lives | A plain file, `~/.config/cursor/auth.json` (0600): the runner has no keyring. | Oby never reads it. |
| Login isolation | With `CURSOR_CONFIG_DIR` alone, both throwaway homes showed the user's real login. With `HOME`, `XDG_CONFIG_HOME` **and** `CURSOR_CONFIG_DIR` each of its own, account A was signed in and B stayed signed out (the user has one Cursor account, which shows per-folder isolation). | `separateLogins = true`. Every Cursor start, status, models and sign-in sets all three to the account's home (`CursorStatus.environment`). |
| Commands | `session/request_permission` arrives, kind `execute`. | Commands ask Oby. |
| **Edits** | With every permission rejected, `probe.txt` was **written, with no `session/request_permission` at all.** | `editsAsk = false`. See below: edits can't be gated through ACP. |
| MCP through `mcpServers` | Cursor POSTed `/mcp` on the stub server, then tried OAuth discovery: `/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`, `/.well-known/openid-configuration` and `POST /register`. | `honoursMcpServers = true`. The runner answers those paths with a plain `404` (`Gate`). |
| Model | `session/new`'s `configOptions` has a `model` select; its values carry parameters, like `gpt-5.6-luna[context=272k,reasoning=medium,fast=false]`, and `default[]` is Auto. | `modelOption = true`: `--model` is dropped and Oby sets the option (`ACPRPC.modelValue` finds the variant for the model Settings names). |
| Modes | `agent`, `plan`, `ask`. | Plan is `plan`; every other Oby mode is `agent`. |
| `session/load` | `loadSession` is true and `session/load` works in a new process. | A resumed job loads its session, and takes its modes and options from the answer. |
| Signed out | `session/new` answers `-32000` "Authentication required". | The job fails with "Cursor · <account> is signed out: sign in from Settings › Accounts". |

### Edits are not gated

Cursor, with `--sandbox disabled` and every permission rejected, wrote a file without asking.
**Edits can't be gated through ACP**, so Oby doesn't claim they ask:

- A Cursor job in Ask mode behaves as Accept edits, and the job's report and the mode picker say so.
- Policy's "stay inside the worktree" for file edits can't be applied to Cursor's own edits. What holds
  them is the job's worktree and, on Linux, bubblewrap (`own: home`: the worktree, the clone's git data
  and the account's home are the only writable places; everything else is read-only or empty).
  On a Mac there's no box: Cursor's edits are as free as Cursor's own judgment, and Plan mode is
  Cursor's own read-only mode.
- Commands do ask, so Policy's fixed rules (no push, no `gh` publishing) and the user's rules apply to
  every command.

### Not yet verified

- The offline half's raw output (`--version`, `acp --help`, the `initialize` response) wasn't pasted
  here: the facts above are what the user reported from the run.
- `HOME` is part of the isolation the probe proved, and it changes the home of every command a Cursor
  job runs (the SwiftPM and npm caches start empty in the account's home). Probe step 2b tests
  `XDG_CONFIG_HOME` + `CURSOR_CONFIG_DIR` without `HOME`; if that isolates too, `CursorStatus.environment`
  can drop `HOME`.

## `CursorFacts` (Engine/Cursor.swift)

| Fact | Value | What it changes |
| --- | --- | --- |
| `separateLogins` | `true` | Any number of Cursor accounts, each with its own `HOME`, `XDG_CONFIG_HOME` and `CURSOR_CONFIG_DIR`. Closes #24. (`false` would allow one account per machine: "Cursor keeps one login per Mac user".) |
| `editsAsk` | `false` | A Cursor job in Ask mode behaves as Accept edits, and says so. |
| `honoursMcpServers` | `true` | `session/new` carries the broker (`type: "http"`, the job's token in an `Authorization` header) when `mcpCapabilities.http` holds, and the account's own servers from `<home>/mcp.json` (only the keys that start them, never a header or env value). |
| `modelOption` | `true` | The model is set with `session/set_config_option` (category `model`), not `--model`. |

## The wire format Oby uses

Newline-delimited JSON-RPC 2.0 over stdio, split on `\n` only (U+2028 stays inside a message).

| Step | Message |
| --- | --- |
| Start | `initialize` `{protocolVersion: 1, clientCapabilities: {}, clientInfo: {name: "oby"}}`: no `fs`, no `terminal`. Oby never calls `authenticate`. |
| Session | `session/load` when `agentCapabilities.loadSession` holds and the job resumes, else `session/new {cwd: worktree, mcpServers}`. |
| Turn | `session/prompt`; progress arrives as `session/update` (`agent_message_chunk`, `tool_call`, `tool_call_update`, `plan`). |
| Permission | `session/request_permission` with options `allow_once`, `allow_always`, `reject_once`, `reject_always`. |
| Stop | `session/cancel`, every pending permission answered `{outcome: {outcome: "cancelled"}}`, then the process group ends after `Halt.grace`. |

Oby answers a permission with `{outcome: {outcome: "selected", optionId}}`, per the protocol's
schema. Its #406 text writes the cancelled answer as `{outcome: "cancelled"}`; the nested form is
what the schema and Cursor's own ACP page show.

### Permissions

1. The request names a tool call by `toolCall.toolCallId`; Oby reads the call's earlier
   `tool_call` (command, files, URL) with what the request carries.
2. `execute` is `Bash` (`rawInput.command`, a string or words joined by spaces, else the title);
   `edit`, `delete`, `move` are `Edit` (paths from `locations` and the diffs; the probe saw no edit
   request, so this is for a Cursor that sends one); `read`, `search` are
   `Read`; `fetch` is `WebFetch`; a title shaped `mcp__<server>__<tool>` is that MCP tool; anything
   else is `Cursor(<title>)`.
3. `Policy.deny` answers first (no publishing, the worktree only, only Tetrix's MCP tools): the
   answer is `reject_once`, and the reason is put before the job's next prompt ("Oby declined …").
4. Everything else is asked of `Permissions.decide` with the job's mode and rules. `Cursor(...)`
   asks in **every** mode, Bypass included, and saves no rule.
5. Allow and always answer the `allow_once` option. **`allow_always` is never sent**: it would let
   later calls past Oby. With no `allow_once` Oby rejects ("Oby can't allow this once").

### Cursor's own requests

| Method | Oby's answer |
| --- | --- |
| `cursor/create_plan` | The plan card (as `ExitPlanMode`). Approve: `{outcome: "accepted"}`, then Cursor's mode goes to `agent` and a prompt tells it to go ahead. Reject: `{outcome: "rejected", reason}`. |
| `cursor/ask_question` | `{outcome: "skipped"}`: questions go to the user in the summary, as Codex's are refused. |
| `cursor/update_todos`, `cursor/task` | Notifications: a step line for now (#381's activity list isn't in yet). |
| any other request (`fs/*`, `terminal/*`) | A JSON-RPC error: Cursor never waits on Oby. |

### Launch

```
cursor-agent --sandbox disabled acp
```

- The model is set after `session/new` through its `model` option (`--model <id>` only while
  `CursorFacts.modelOption` is false); Auto sets nothing: Cursor picks.
- Every Cursor job runs on an Oby-made account home (`accounts/<id>`), never `~/.cursor`:
  `CURSOR_CONFIG_DIR`, `XDG_CONFIG_HOME` (`<home>/.config`) and `HOME` are all the account's. Before
  each start Oby rewrites only `permissions: {allow: [], deny: []}` and `approvalMode: "allowlist"` in
  `<home>/cli-config.json`, keeping `authInfo` and `version`. (That is the Swift engine. obid gives
  each Cursor job a folder of its own instead, with a copy of the account's login file and settings,
  never the account's folder: docs/runner-api.md, "The job sandbox", #655.)
- `CURSOR_API_KEY` and `CURSOR_AUTH_TOKEN` are removed from every agent's environment (Shell.swift).
- A repository's `.cursor/cli.json` with a non-empty `allow` is asked about once per repository,
  before Cursor starts.
- On Linux the box binds `.local/share/cursor-agent` (`Agents.tools`) and Cursor's own sandbox
  stays disabled (bubblewrap can't nest); Oby answers every command.
- Sign-in is the tool's own command in Terminal: `cursor-agent login` with the three variables
  (`NO_OPEN_BROWSER=1` on the runner).
