# oby-mcp: Oby for Claude Code and other assistants

`oby-mcp` is a small MCP server over stdio (#137). Claude Code, Claude Desktop, Cursor or any assistant that speaks MCP can use it to read Oby's jobs, inbox and accounts, hand work to Oby (which starts it, with nothing to confirm), and settle the inbox, with the same rules as Oby's apps. Work still runs only on the runner: `oby-mcp` is a thin wrapper around [the runner API](runner-api.md), so that API is where the actual behaviour is defined.

## Ship it with Oby.app

On the Mac, Oby bundles `oby-mcp` at `Contents/Helpers/oby-mcp` (#385), so Sparkle updates it with the app. Settings › Assistants has **Add to Claude Code** (`claude mcp add --scope user oby -- <bundled path>`) and **Add to Codex** (`codex mcp add oby -- <bundled path>`): each shows the command, then runs it. Point at the bundled path, never a copy.

`initialize` sends the binary's build commit as `serverInfo.version` (from `Contents/Resources/oby-mcp.commit` in the app, a sidecar beside a hand-built binary, or `OBY_MCP_COMMIT`). The first tool call of a session compares that with the runner's `GET /v1/status` `runner.update.commit`; when they differ, the first tool result starts with one line: `oby-mcp is older than the runner: update Oby or rebuild it.` Later calls in that session are quiet.

## Build and add it

On the Mac (or any machine on the tailnet), when you aren't using the bundled binary:

```sh
swift build -c release --product oby-mcp
# the binary: .build/release/oby-mcp
git rev-parse HEAD > .build/release/oby-mcp.commit
```

**Replacing a signed binary:** `cp` over an existing `oby-mcp` is killed on launch (exit 137: the cached code signature no longer matches). Always `rm` first, then copy, then ad-hoc sign:

```sh
rm -f ~/.local/bin/oby-mcp
cp .build/release/oby-mcp ~/.local/bin/oby-mcp
cp .build/release/oby-mcp.commit ~/.local/bin/oby-mcp.commit
codesign -s - -f ~/.local/bin/oby-mcp
```

Claude Code:

```sh
claude mcp add --scope user oby -- /Applications/Oby.app/Contents/Helpers/oby-mcp
# or a hand-built path:
claude mcp add --scope user oby -- /path/to/oby/.build/release/oby-mcp
```

Codex:

```sh
codex mcp add oby -- /Applications/Oby.app/Contents/Helpers/oby-mcp
```

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{"mcpServers": {"oby": {"command": "/Applications/Oby.app/Contents/Helpers/oby-mcp"}}}
```

**Where the runner is:** `OBY_RUNNER_URL` if it's set (`claude mcp add … -e OBY_RUNNER_URL=https://…`, or `"env"` in Claude Desktop's JSON). Otherwise, the address in Oby's Settings › Runner on this Mac (`runnerURL` in `com.deskree.oby`'s defaults). Otherwise, `https://tetrix-lab.tail8de49b.ts.net:8443`. Like the apps, `oby-mcp` sends no token: `tailscale serve` adds the owner's `Tailscale-User-Login`, so it only works from a machine on the owner's tailnet, signed in as the owner.

## Tools

| Tool | What it does | Runner call |
|---|---|---|
| `status` | The accounts with their usage (5-hour and weekly windows, reset times, running jobs, full until), each tool's model, Tetrix, and who GitHub calls go as (`github`). | `GET /v1/status` |
| `jobs` | The latest jobs (20 by default, up to 50), newest first: id, status, stage, title, tool and account, and whether each needs you. | `GET /v1/jobs?limit=` |
| `job` | One job in full: every pipeline stage, step, branch, pull request, Oby's review, Mac check and Apple check (steps, failing tests, build errors, which Mac), question, notes, summary and whether a research report is saved. | `GET /v1/jobs/{id}` |
| `inbox` | The open inbox, longest-waiting first, with each item's kind, text and options. With `state: done`, the settled history instead (latest first). A runner older than the inbox has an empty one. | `GET /v1/inbox`, `GET /v1/inbox?state=done` |
| `wait` | Waits until a job's status or stage changes, or it asks a question, up to `timeout` seconds (50 by default, at most 600), and then returns the job. It checks every 5 seconds. | `GET /v1/jobs/{id}`, repeated |
| `ask` (also `plan`, its older name) | The user's words go to Oby's brain, just as if they'd said them to Oby, and the work it plans starts at once, with nothing to confirm (#269). It answers with the jobs it started (each in full: id, title, kind, repository, branch, account, rounds, check, files, what it waits for), a question, or a reply. To answer the brain's question, call `ask` again with the same words and `answer`. Words that ask to stop work stop it right away, as they do in the apps; `stop` stops a job it started. | `POST /v1/plans` |
| `dispatch` | Starts a job you describe whole, for work the brain needn't plan: `repo`, `kind` (`review`, `fix`, `build`, `test`, `investigate`) and `task` are required; `pr` or `issue` say what it's about; `title`, `branch`, `base`, `account` (its id or name, or `Claude Code`/`Codex` when that tool has a single account; left out, Oby picks the one with the most room), `rounds` (1 to 10), `check`, `model` (one of the tool's), `mode` (`ask`, `acceptEdits`, `plan` or `bypass`; left out, Settings › Permissions' default), `files` (a list of paths and folders ending in `/`, up to 30: a job touching the same files waits for it until its pull request is merged; left out, the issue's; an empty list claims none) and `startWhen` (up to 5 conditions: `{"job": id, "is": "done"/"merged"/"published"/"ended"}`, `{"pr": number, "is": "merged"/"closed"}`, `{"account": id or name, "window": "fiveHour"/"sevenDay", "under": 0.5}` (`under` left out: once it has room), `{"account": id or name, "onPace": true}` or `{"at": ISO 8601 time}`; a job waiting on an account runs on it; runner API, "Start when"). The runner checks it as it checks a plan. | `POST /v1/jobs` |
| `start` | A job waiting for its `startWhen`: starts it now, or with `startWhen`, changes what it waits for (an empty list starts it). `job` shows what it waits for. Cancel one with `stop`. | `POST /v1/jobs/{id}/start`, `POST /v1/jobs/{id}/start-when` |
| `message` | Tells a job's agent something, 1 to 2,000 characters. A running job hears it now. A finished job picks its session up again. | `POST /v1/jobs/{id}/messages` |
| `stop` | Stops a queued or running job. | `POST /v1/jobs/{id}/stop` |
| `dismiss` | Lets go of a job that needs you. | `POST /v1/jobs/{id}/dismiss` |
| `move` | Moves a job to another tool, account or model (`agent`, `account`, `model`, `why`). At least one of the first three is required. | `POST /v1/jobs/{id}/move` |
| `failures` | Oby's failure records, newest first. | `GET /v1/failures` |
| `failure` | One failure record in full. | `GET /v1/failures/{id}` |
| `report` | A job's saved research report (Markdown and proposals), or an error when none was saved. | `GET /v1/jobs/{id}/report` |
| `answer` | Settles an inbox item with one of its own `options`. Case and accents don't matter, and the option goes out spelled as the item spells it. A `question` item also takes the user's own words. | `POST /v1/inbox/{id}/answer` `{"answer"}` |
| `later` | Puts an item off until a time: `until` (ISO 8601) or `minutes`. | `POST /v1/inbox/{id}/answer` `{"later"}` |
| `done` | Settles an item without an answer. | `POST /v1/inbox/{id}/answer` `{"done": true}` |

### The inbox, as the apps settle it

`answer` takes only an item's own options, whatever its kind: `Try again`, `Dismiss`, `One more round`, `Fix it`, and a permission prompt's choices (allow, deny, a mode). Kinds it doesn't know yet, like permission items before the runner sends them, are handled the same way. The runner then does what the app would. A permission it fences off stays refused, whatever the answer. Any other words are refused with "answer that in Oby", except on a `question`, where they become the agent's next message. An item with no options (an `audit`) takes only `done` or `later`.

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
- The sources are in `MCP/` and the tests in `MCPTests/`. Each tool is tested against a stub runner for the call it makes, refusals, option checking and the quoting. They're a separate test target because a round that changes `RunnerTests`' target in `Package.swift` fails Oby's test-integrity check.
