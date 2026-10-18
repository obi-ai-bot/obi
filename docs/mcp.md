# oby-mcp: Oby for Claude Code and other assistants

`oby-mcp` is a small MCP server over stdio (#137). Claude Code, Claude Desktop, Cursor or any assistant that speaks MCP can use it to read Oby's jobs, inbox and accounts, hand work to Oby (which starts it, with nothing to confirm), and settle the inbox, with the same rules as Oby's apps. Work still runs only on the runner: `oby-mcp` is a thin wrapper around [the runner API](runner-api.md), so that API is where the actual behaviour is defined.

## Build and add it

On the Mac (or any machine on the tailnet):

```sh
swift build -c release --product oby-mcp
# the binary: .build/release/oby-mcp
```

Claude Code:

```sh
claude mcp add --scope user oby -- /path/to/oby/.build/release/oby-mcp
```

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{"mcpServers": {"oby": {"command": "/path/to/oby/.build/release/oby-mcp"}}}
```

**Where the runner is:** `OBY_RUNNER_URL` if it's set (`claude mcp add … -e OBY_RUNNER_URL=https://…`, or `"env"` in Claude Desktop's JSON). Otherwise, the address in Oby's Settings › Runner on this Mac (`runnerURL` in `com.deskree.oby`'s defaults). Otherwise, obid on this machine (`http://127.0.0.1:7777`) when its token is there. Otherwise, `https://tetrix-lab.tail8de49b.ts.net:8443`.

**The token:** a runner on this machine (`127.0.0.1`, `localhost` or `[::1]`) gets obid's own token as `Authorization: Bearer`, read from `api-token` in obid's home (`~/Library/Application Support/Oby/Runner` on a Mac, `~/.local/share/obid` elsewhere), and only when that is a regular file of yours that no one else may read, as the Mac app reads it ([install.md](install.md), "The token, and how the apps find obid"). It is never sent to a runner anywhere else. Over the tailnet `oby-mcp` sends no token: `tailscale serve` adds the owner's `Tailscale-User-Login`, so that works only from a machine on the owner's tailnet, signed in as the owner. To reach obid on this Mac while Oby's Settings name another runner, set `OBY_RUNNER_URL=http://127.0.0.1:7777`.

## Tools

| Tool | What it does | Runner call |
|---|---|---|
| `status` | The accounts with their usage (5-hour and weekly windows, reset times, running jobs, full until), each tool's model, Tetrix, and who GitHub calls go as (`github`). | `GET /v1/status` |
| `jobs` | The latest jobs (20 by default, up to 50), newest first: id, status, stage, title, tool and account, and whether each needs you. | `GET /v1/jobs?limit=` |
| `job` | One job in full: every pipeline stage, step, branch, pull request, Oby's review, Mac check, question, notes and summary. | `GET /v1/jobs/{id}` |
| `inbox` | The open inbox, longest-waiting first, with each item's kind, text and options. A runner older than the inbox has an empty one. | `GET /v1/inbox` |
| `wait` | Waits until a job's status or stage changes, or it asks a question, up to `timeout` seconds (50 by default, at most 600), and then returns the job. It checks every 5 seconds. | `GET /v1/jobs/{id}`, repeated |
| `ask` (also `plan`, its older name) | The user's words go to Oby's brain, just as if they'd said them to Oby, and the work it plans starts at once, with nothing to confirm (#269). It answers with the jobs it started (each in full: id, title, kind, repository, branch, account, rounds, check, files, what it waits for), a question, or a reply. To answer the brain's question, call `ask` again with the same words and `answer`. Words that ask to stop work stop it right away, as they do in the apps; `stop` stops a job it started. | `POST /v1/plans` |
| `dispatch` | Starts a job you describe whole, for work the brain needn't plan: `repo`, `kind` (`review`, `fix`, `build`, `test`, `investigate`) and `task` are required; `pr` or `issue` say what it's about; `title`, `branch`, `base`, `account` (its id or name, or `Claude Code`/`Codex` when that tool has a single account; left out, Oby picks the one with the most room), `rounds` (1 to 10), `check`, `model` (one of the tool's), `mode` (`ask`, `acceptEdits`, `plan` or `bypass`; left out, Settings › Permissions' default), `files` (a list of paths and folders ending in `/`, up to 30: a job touching the same files waits for it until its pull request is merged; left out, the issue's; an empty list claims none) and `startWhen` (up to 5 conditions: `{"job": id, "is": "done"/"merged"/"published"/"ended"}`, `{"pr": number, "is": "merged"/"closed"}`, `{"account": id or name, "window": "fiveHour"/"sevenDay", "under": 0.5}` (`under` left out: once it has room), `{"account": id or name, "onPace": true}` or `{"at": ISO 8601 time}`; a job waiting on an account runs on it; runner API, "Start when"). The runner checks it as it checks a plan. | `POST /v1/jobs` |
| `start` | A job waiting for its `startWhen`: starts it now, or with `startWhen`, changes what it waits for (an empty list starts it). `job` shows what it waits for. Cancel one with `stop`. | `POST /v1/jobs/{id}/start`, `POST /v1/jobs/{id}/start-when` |
| `message` | Tells a job's agent something, 1 to 2,000 characters. A running job hears it now. A finished job picks its session up again. | `POST /v1/jobs/{id}/messages` |
| `stop` | Stops a queued or running job. | `POST /v1/jobs/{id}/stop` |
| `dismiss` | Lets go of a job that needs you. | `POST /v1/jobs/{id}/dismiss` |
| `answer` | Settles an inbox item with one of its own `options`. Case and accents don't matter, and the option goes out spelled as the item spells it. A `question` item also takes the user's own words. | `POST /v1/inbox/{id}/answer` `{"answer"}` |
| `later` | Puts an item off until a time: `until` (ISO 8601) or `minutes`. | `POST /v1/inbox/{id}/answer` `{"later"}` |
| `done` | Settles an item without an answer. | `POST /v1/inbox/{id}/answer` `{"done": true}` |

Moving a job to another account (`move`) comes when the runner can do it (#118).

### The inbox, as the apps settle it

`answer` takes only an item's own options, whatever its kind: `Try again`, `Dismiss`, `One more round`, `Fix it`, and a permission prompt's choices (allow, deny, a mode). Kinds it doesn't know yet, like permission items before the runner sends them, are handled the same way. The runner then does what the app would. A permission it fences off stays refused, whatever the answer. Any other words are refused with "answer that in Oby", except on a `question`, where they become the agent's next message. An item with no options (an `audit`) takes only `done` or `later`. A `confirm` item (obid only, #546: something Oby's brain planned that persists or widens trust, like always allowing a command) is refused whatever the answer, `Confirm` and `Cancel` alike: only the user's own answer in Oby carries it out.

`Try again` on a `merge` item asks the runner to retry its own merge. That merge keeps all of its gates: Oby's review approved, the Mac check passed on the same commit, and a clean secret scan, as it does from the apps.

## Refused

These answer "answer that in Oby" and call nothing on the runner:

- `publish`: publishing by hand needs a device signature (Face ID or Touch ID), and only the user's device can make one.
- `merge`: Oby merges into `dev` by itself after its review and the Mac check. Nobody merges by hand from here, and nothing merges into `main`.
- `settings`: the vault, secrets and Settings (accounts, models, the runner) change only in Oby.

These tools exist so that an assistant asked to do one of these things gets a clear answer instead of trying another route.

## Quoted data

Whatever jobs, agents, GitHub or other people wrote reaches the assistant as quoted data, never as instructions (AGENTS.md): job titles, steps and summaries, the brain's replies and questions, inbox texts and options, account labels. Every tool's answer puts what the runner said inside a fenced block. The block carries a label saying it is quoted data, and its fence is longer than any run of backticks inside, so the quoted text can't close it. Only `oby-mcp`'s own sentences appear outside the blocks. The server's MCP `instructions` tell the client the same thing.

## How it works

- It speaks JSON-RPC 2.0, one message per line on stdin and stdout, with MCP's `initialize`, `ping`, `tools/list` and `tools/call`. It runs calls concurrently, so a `wait` holds nothing else up. It answers protocol versions 2024-11-05 through 2025-11-25.
- Read tools are marked `readOnlyHint`, so clients can run them without asking.
- When the runner returns an error, the tool's error quotes that line in a fenced block too, since it can name a job's title or an account. When the runner can't be reached, the tool says so and asks whether Tailscale is up.
- Ids go into the path percent-encoded, so an id can't reach another endpoint.
- The sources are in `mcp/server/` and the tests in `mcp/tests/`. Each tool is tested against a stub runner for the call it makes, refusals, option checking and the quoting. They're a separate test target because a round that changes `RunnerTests`' target in `Package.swift` fails Oby's test-integrity check.
