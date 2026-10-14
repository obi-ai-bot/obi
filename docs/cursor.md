# Cursor in Oby (#406)

Oby runs jobs on Cursor through `cursor-agent acp`, the Agent Client Protocol over stdio, with
the generic client in `Engine/ACP.swift` and Cursor's launch in `Engine/Cursor.swift`. This page
is what Oby relies on, what the probe has proven, and what it still has to prove. Run the probe
with `scripts/cursor-probe.sh offline` and `scripts/cursor-probe.sh signed-in`.

## Probe results

### Offline half: not captured yet

The offline half was **not run** when this was written. `cursor-agent` is a symlink into
`~/.local/share/cursor-agent`, and that folder isn't in the box a job's agent works in
(`Agents.tools` lacked it until this change), so the job that built this couldn't start the CLI:

```
$ ls ~/.local/share/cursor-agent
ls: cannot access '/home/…/.local/share/cursor-agent': No such file or directory
```

Nothing below is guessed in its place. Run `scripts/cursor-probe.sh offline` on a machine where
`cursor-agent` runs and paste its report here. It records `--version`, `acp --help`, the
`initialize` response (capabilities, `authMethods`, modes, configOptions), `status` and
`session/new` while signed out, and the files a fresh `CURSOR_CONFIG_DIR` and `HOME` get.

| Item | Result |
| --- | --- |
| `cursor-agent --version` | not captured (2026-10-12 build `d47ca18` is what tetrix-lab has, per #406's comment) |
| `acp --help` exits 0 | not captured |
| `initialize` response | not captured |
| `status` signed out | not captured |
| `session/new` signed out | not captured |
| Files under a fresh `CURSOR_CONFIG_DIR` | not captured |

### What #406's comment says (2026-10-14, tetrix-lab, 2026.10.12-d47ca18)

- After `NO_OPEN_BROWSER=1 cursor-agent login`, the login lives in `~/.config/cursor/auth.json`
  (0600), a plain file on the runner (no keyring). `cursor-agent status` then says "Logged in as …".
- `~/.cursor` holds only `cli-config.json` and UI state.
- On macOS the same CLI said "Authentication tokens stored securely" (the keychain, unverified).

So `CURSOR_CONFIG_DIR` alone probably does **not** isolate a login: the first thing the signed-in
half tests is a per-account `XDG_CONFIG_HOME` (or `HOME`).

### Signed-in half: for the user to run

Run `scripts/cursor-probe.sh signed-in` with two Cursor accounts and paste its redacted report here
and in the pull request. It decides the four facts below.

## `CursorFacts` (Engine/Cursor.swift)

Each holds the **safe** value until the report says otherwise.

| Fact | Safe default | What it changes |
| --- | --- | --- |
| `separateLogins` | `false` | `true`: any number of Cursor accounts. `false`: Settings allows one Cursor account per machine and says "Cursor keeps one login per Mac user". Closes #24. |
| `editsAsk` | `false` | `false`: Cursor may write files without a permission request, so a Cursor job in Ask mode behaves as Accept edits, and the mode picker and the job's report say so. |
| `honoursMcpServers` | `false` | `false`: `session/new` carries no MCP server (the broker's token isn't handed to a tool that may ignore it), and the report says "Connected apps aren't available to Cursor jobs yet". |
| `modelOption` | `false` | `true`: the model is set with `session/set_config_option` (category `model`) and `--model` is dropped. `false`: `--model <id>`. |

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
   `edit`, `delete`, `move` are `Edit` (paths from `locations` and the diffs); `read`, `search` are
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
cursor-agent --sandbox disabled [--model <id>] acp
```

- `--model auto` is omitted: Cursor picks.
- Every Cursor job runs on an Oby-made account home (`accounts/<id>`), never `~/.cursor`:
  `CURSOR_CONFIG_DIR=<home>`. Before each start Oby rewrites only `permissions: {allow: [], deny: []}`
  and `approvalMode: "allowlist"` in `<home>/cli-config.json`, keeping `authInfo` and `version`.
- `CURSOR_API_KEY` and `CURSOR_AUTH_TOKEN` are removed from every agent's environment (Shell.swift).
- A repository's `.cursor/cli.json` with a non-empty `allow` is asked about once per repository,
  before Cursor starts.
- On Linux the box binds `.local/share/cursor-agent` (`Agents.tools`) and Cursor's own sandbox
  stays disabled (bubblewrap can't nest); Oby answers every command.
- `XDG_CONFIG_HOME` is **not** set: git reads `$XDG_CONFIG_HOME/git/config`, and the box binds
  `~/.config/git` read-only. The probe says whether Cursor needs it.
