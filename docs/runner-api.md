# The Oby runner API

The runner is Oby's engine without the notch: the brain and the Lead, Oby's own clones and job worktrees, the Claude Code and Codex runners, accounts, routing and Publish. It runs on an always-on machine (first: `tetrix-lab`, Ubuntu, on Wellington's tailnet), so the iPhone app (and later the Watch) can say what to do, and follow the jobs, while the Mac is closed.

This document is the contract between the runner and its clients. Change it in the same pull request as the code on either side.

## Reaching it

## LAN gateway (#284)

A Mac runner (below) keeps its API on loopback and starts one more listener, the gateway, on every interface at `:8810` (`OBY_GATEWAY_PORT`), advertised over Bonjour as `_oby._tcp` under the Mac's name so the iPhone finds it without an address. A tailnet runner has `tailscale serve` instead and binds nothing else. On the local network the gateway is plain HTTP plus a device token; away from home the Mac's tunnel carries the same requests.

- **Pairing.** The Mac app makes an invitation on the loopback API, with the runner's own token: `POST /v1/pairing/invite` with `{"url": "https://oby-….tetrix.pro", "name": "<the Mac's name>", "hostname": "oby-….tetrix.pro"}` answers `{"url", "name", "hostname", "link", "secret", "code", "expiresAt"}`: a high-entropy one-time `secret` (in the QR code, with the `url` and the `link`), a six-digit `code` to type instead, both good for two minutes and once; five wrong tries end the invitation. These endpoints exist on a Mac runner only and are never reachable through the gateway: nothing that reaches the gateway can mint an invitation, and no file on the Mac stands for the app.
- **Redeeming.** The phone sends `POST /v1/pairing` to the gateway with `{"credential": "<the secret or the code>", "name": "<the phone's name>"}` and gets `{"token": "<device token>", "deviceID": "…", "expiresAt": "…", "link": {"name": "<the Mac's name>", "hostname": "oby-….tetrix.pro"}}`. The token is shown once: the runner keeps only its SHA-256 digest, with the device's name, in `devices.json`, and the phone keeps it in its keychain. Tokens last 30 days. The `link` lets a phone that typed the code link the Mac as the QR code would.
- **Paired devices.** `GET /v1/pairing/devices` on the loopback API lists them, `[{"id", "name", "created", "expiresAt"}]`, never a token or digest; `DELETE /v1/pairing/devices/{id}` revokes one (`204`), and the phone must pair again. Settings › Runner › Paired devices on the Mac shows this list with Revoke.
- **Every other gateway request** sends `Authorization: Bearer <device token>`. The gateway checks the method and path against an explicit allowlist (Runner/Routes.swift: exactly the routes the iPhone uses, and the Watch through it) before forwarding to the loopback API with the runner's own token. A route not on the list is `404` whatever the token; a missing, wrong, expired or revoked token is `401`. Adding a route to the loopback API doesn't open it through the gateway: that's a change to the list, on purpose. Off the list: `/v1/checks/…` and `/v1/agent/…` (the Mac's own and an agent's own calls, over loopback), `/v1/connections…` (managed on the Mac), `/v1/speech` (the Watch's own API has it), `PUT /v1/settings/jobs` and the pairing endpoints.
- **Scrubbing.** Before an answer or an event leaves the Mac, the gateway nulls every `session` (an agent's session id, which resumes its conversation), replaces the accounts' home paths with `[home]` in every string, and runs the vault's redaction over the text (`[vault: name]`), the same that cleans the runner's logs. Event streams are scrubbed a frame at a time, so a secret split across chunks never goes out in pieces.

- **Base URL:** `https://tetrix-lab.tail8de49b.ts.net:8443` (the app lets you change it), or `http://127.0.0.1:7777` for the runner on the Mac itself (below). Everything is under `/v1`.
- The runner listens on `127.0.0.1:7777` only. `tailscale serve --https=8443` publishes it on the tailnet with a real HTTPS certificate, so iOS needs no exceptions, and nothing is reachable from the internet. Port 443 on tetrix-lab belongs to the Tetrix stack's own proxy, so Oby uses 8443, one of the ports Tailscale serves HTTPS on.
- **Who you are:** `tailscale serve` adds `Tailscale-User-Login` to every request. The runner answers only its owner's login (set when it's installed) and returns `401` to anyone else. The app sends no token and stores no secret for this. The one exception is `/v1/agent/…`, which agents call from their sandbox on the runner itself (`oby-check apple`, Apple check below): those requests carry their job's token instead, `Authorization: Bearer <token>`, and answer nothing else.
- **On a Mac** (#283): the same runner runs on the user's own Mac, as the Oby app's login item (`Contents/Helpers/oby-runner` in Oby.app, registered from `Contents/Library/LaunchAgents/com.deskree.oby.runner.plist`; Settings › Runner › "This Mac"). It's a Mac runner when `OBY_OWNER` is unset (on Linux that's an error), and then nothing publishes it: the base URL is `http://127.0.0.1:7777`, and there's no login header to read.
  - **The local token.** The first time it starts, the runner makes a token of its own, 64 hex characters, and keeps it in the macOS keychain; `OBY_HOME` defaults to `~/Library/Application Support/Oby/Runner` on a Mac, inside the app's own folder but never the same (each has its own `oby.sqlite`, clones and worktrees). The Oby app on the same Mac reads that keychain item and sends the token on every request, `Authorization: Bearer <token>`. Anything else is `401` (`This runner answers only Oby on this Mac.`). `/v1/agent/…` carries its job's token, as above. The token never leaves the Mac: it's not in any answer, event or log.
  - **Loopback only.** A Mac runner binds `127.0.0.1` and, before anything else, refuses with `403` (`This runner answers only on 127.0.0.1.`) every request whose `Host` isn't `127.0.0.1`, `localhost` or `[::1]`, with or without a port: a web page the user opens can't have their browser reach it through a name that resolves to 127.0.0.1 (DNS rebinding), and a request with no `Host` isn't let in either. Remote devices reach a Mac runner only through the gateway (F18), never directly.
  - A Mac runner doesn't update itself (Sparkle updates the app, #282) and runs agents in their own sandboxes rather than bubblewrap (`Agents.sandboxed`). Everything else in this document holds. Its keychain items are its own (`com.deskree.oby.runner.vault`), apart from the app's.
- **JSON** everywhere, camelCase keys, dates as ISO 8601 strings (`2026-10-09T21:43:30Z`). Errors are `{"error": "One line a person can read."}` with a 4xx or 5xx status.
- **No vault secret** in an answer or an event: every string has the vault's secrets, plain or encoded, taken out. When the runner can't read its vault, answers are `503` with the reason, and events aren't sent.
- **The Apple Watch** can't run Tailscale, so without its iPhone it uses a second, smaller API through a Cloudflare Tunnel: [The Watch API](#the-watch-api), below.

## Objects

### Job

```json
{
  "id": "9f08fd10",
  "request": "Review oby PR #33",
  "agent": "claude",
  "account": "default",
  "repo": "deskree-inc/oby",
  "branch": "oby/review-33",
  "base": "dev",
  "pr": 33,
  "kind": "review",
  "task": "Review pull request #33 in deskree-inc/oby…",
  "status": "running",
  "step": "Running pnpm test",
  "summary": "",
  "session": "e6a24229-3d3b-417b-a610-691c636b4c49",
  "created": "2026-10-09T21:42:53Z",
  "started": "2026-10-09T21:42:55Z",
  "finished": null,
  "commits": null,
  "published": null,
  "pushed": null,
  "publishError": null,
  "summaries": null,
  "issue": null,
  "fromPR": null,
  "rounds": 1,
  "round": 1,
  "check": null,
  "model": null,
  "complexity": "complex",
  "effort": "high",
  "notes": null,
  "pullRequest": null,
  "pullRequestError": null,
  "dismissed": null,
  "reviewing": null,
  "review": null,
  "reviewError": null,
  "reviewOf": null,
  "files": null,
  "lead": null,
  "claim": null,
  "limit": null,
  "startCommit": null,
  "firstSwiftBuildSeconds": null,
  "outgoing": [],
  "moves": [],
  "question": null,
  "mode": "bypass",
  "permission": null,
  "macCheck": null,
  "mergeError": null,
  "appleCheck": null,
  "appleRan": null,
  "tetrix": null,
  "startWhen": null,
  "waiting": null,
  "mergeNeedsYou": false,
  "reviewNeedsYou": false,
  "title": "Review oby #33",
  "pipeline": {
    "number": 2,
    "total": 5,
    "stages": [
      {"id": "prepare", "title": "Prepare", "state": "done", "detail": "Clone and worktree"},
      {"id": "work", "title": "Work", "state": "current", "detail": "Round 1 of 1 · Running pnpm test"},
      {"id": "publish", "title": "Publish", "state": "upcoming", "detail": "Secret scan, push and pull request"},
      {"id": "review", "title": "Review", "state": "upcoming", "detail": "Waiting for review"},
      {"id": "merged", "title": "Merged into dev", "state": "upcoming"}
    ]
  }
}
```

- `agent`: `claude` or `codex`. `account`: an account `id`. `kind`: `review`, `fix`, `build`, `test` or `investigate`.
- `status`: `queued`, `running`, `done`, `failed`, `stopped` or `interrupted`.
- `step`: what it's doing now, while queued or running. `summary`: the agent's final message; its first line is the one-line notice.
- A `build`, `fix` or `test` job that ends with no commits of its own is `failed`, and its `summary` starts with `Nothing committed: ` followed by the agent's first line. Not a round the user started with `POST /v1/jobs/{id}/messages`: their words say what it should do (reset the branch, drop the work), so that round ending with nothing committed is `done`.
- When the job's account hits its usage limit mid-round (Codex: "You've hit your usage limit… try again at 10:45 PM"; Claude Code: a `rate_limit_event` at 100%, or a usage-limit result), the runner marks the account full until the reset time it named (an hour when it named none), and the job does that round over on the next account with room, the same tool first, then another tool, in the same worktree and branch with a new session: `account`, `agent` and `session` change, and `step` says so. Its `summary` then ends with a line like `Codex · Deskree hit its limit (resets 10:45 PM); continued on Claude Code · Personal.` When no account has room, the job is `failed`, and its `summary` says when the first one resets. An account marked full isn't picked for a new job before its reset (`fullUntil`).
- `base`: the branch the work started from (filled in once the job is ready). `pr`: the pull request it works on, if any. `fromPR`: on a job about an `issue` that picks up an existing pull request ("finish #19 from PR #124"), that pull request: the job's branch starts from its head, `base` stays the branch it would have had (`dev`), only the commits after that head count as the job's, and the job publishes a pull request of its own. Null otherwise; older runners don't send this key.
- `commits`: commits made beyond `base` (set when a job ends as done).
- Publishing happens by itself. A job that ends `done` with commits not on its pull request (its check passed, or it has none) publishes before it ends, with no device signature: `step` is `"Publishing"` meanwhile, and `publishStep` follows the scan, push and PR creation.
  - It pushes the branch and opens a pull request into `base`, ready for review (never a draft), or pushes to the one already open.
  - The secret scan still gates it. It reads every line the commits add, every commit's message (merges too), and the pull request's title and description, in plain text and in base64 (standard or URL-safe, also wrapped over several lines), hex (also `\x41…` and `0x41, …`) and URL-encoded copies (the rule then reads like `AWS access key, base64`). A possible secret makes the job `failed`, and its `summary` starts with `Not published: possible secret in <file>:<line> (<rule>).`, where `<file>` is the file, or `commit message`, `pull request title` or `pull request description`. Nothing goes out, and it never says the secret. If the scanner can't run, nothing goes out either.
  - Stopped while publishing (`POST /v1/jobs/{id}/stop` or `POST /v1/stop-all`): nothing more goes out. The runner checks right before the push and right before the pull request; a push that already went out is listed in `outgoing`.
  - Only a job that ends while the runner is up, with commits made since its agent started, publishes by itself. A job that ended before the runner started never does, and one whose own publish failed isn't tried again by itself (a round with no new commits keeps its `publishError`).
  - Before publishing, the runner fetches `base` and compares the job's commits with it by patch (`git cherry`, then a trial merge for squash merges). When they're all on it already, nothing goes out: the job stays `done` with `commits` 0, and its `summary` starts with `Not published: its commits are already on <base>.`
  - Any other failure (push, `gh`) leaves the job `done` with `publishError` set. Then Publish by hand is offered (`POST /v1/jobs/{id}/publish`).
- `published`: the pull request's URL once published. Use `pipeline` to show publishing, review and merge progress.
- `publishError`: why the runner couldn't publish the job by itself, or null. Show it instead of "Published".
- `pushed`: how many of `commits` the pull request has: all of them when it was last published, or null before then. A published job that ran again (`POST /v1/jobs/{id}/messages`) and ended `done` with new commits pushes them to the same branch by itself, so they land on the open pull request. A round that rebased the branch rewrote its commits: they count from the commit the runner last pushed, so `pushed` drops (to 0 after a full rebase) and the rewritten commits are unpublished until they're pushed, with the same number of commits.
- `summaries`: every round's summary from the agent, oldest first, or null. The pull request's description quotes them all.
- `outgoing`: everything the runner sent out for the job, oldest first: the job's report lists it. Always a list, empty before anything went out. Each is `{"action": "push", "repo": "deskree-inc/oby", "id": "<commit>", "branch": "oby/fix-75", "date": "2026-10-09T22:01:40Z"}`; `action` is `push` (`id` the commit pushed, `branch` where), `pullRequest` (opened; `id` its URL), `pullRequestEdit` (its description brought up to date; `id` its URL), `checkRun` (Oby's review, or a Mac check's results, written as a check run on the job's pull request; `id` the check run's URL), `comment` (the same from runners before check runs; `id` the comment's URL), `merge` (squash-merged into `dev` by the runner; `id` the pull request's URL, `branch` the branch it deleted), `issueLabels` (issue URL and labels added/removed), `issueClaim`, `issueChecklist`, or `projectStatus` (issue URL and action); older jobs may list `issueAssignment`. `branch` is present on pushes and merges only. More actions may come: show one you don't know as its `action` and `id`. Ids only, never what was sent; the runner's journal keeps one line per action, ids only too.
- What needs you: a job that's `done` with commits the runner couldn't publish (`publishError`), `failed` or `interrupted`, or one Oby's review requested changes on for the fourth time (`review`, below), unless it's dismissed. Say so where the apps would otherwise say nothing needs you.
- `dismissed`: when the user let the job go (`POST /v1/jobs/{id}/dismiss`), or null. A dismissed job needs nothing: it sends no alert, offers no Publish, and its `pipeline` shows Publish as `skipped` with the detail `Dismissed`. It stays in the list and in history. Telling it something (`POST /v1/jobs/{id}/messages`) clears `dismissed`.
- `issue`: the GitHub issue the work is about. The runner fetches it for the agent, which has no GitHub login, and the pull request says `Closes #N`, or `Part of #N` when the issue's body has a checklist (a feature or an epic: its items are ticked as slices merge, and it closes once its tests pass) or `gh` can't read it.
- `rounds`: how many rounds the agent may take (1 means no loop); `round`: the one it's on.
- `check`: a one-line command that must succeed for the work to count as done.
  - After each round the runner runs it in the job's worktree. If it fails and rounds are left, the agent gets another round with the command's output.
  - A run of the check that takes more than 20 minutes is ended, and fails; its output ends with `Oby stopped it after 20 minutes, the most a test run may take.`, followed by `The last test that started: <name>.` when Swift Testing's or XCTest's output names one.
  - Test integrity: after the check, the runner compares both the job's commits (what Publish would send) and its worktree (what the check ran, uncommitted changes and new files too) with `startCommit` itself, not with a merge base, and fails the round when either clearly weakens the tests: it deletes a test file or moves one out of the tests, adds a skip marker (`.disabled(`, `.enabled(if:`, `XCTSkip`, `it.skip`, `@pytest.mark.skip`, `t.Skip(`, `#[ignore]`…), lowers the number of tests declared or of real assertions in a test file (one commented out or one that can't fail, like `#expect(true)`, doesn't count), adds a line to an existing test file that keeps the tests below it from running (a bare `return`, a block comment left open, `#if false`, `if (false) {`), touches test or CI config (`.github/workflows/`, `jest.config.*`, `pytest.ini`, `conftest.py`…), or changes the test settings in a build file (changes or removes a `.testTarget(…)` in `Package.swift`, however many lines it spans; changes a `test` script or the `jest`, `vitest`, `mocha`, `ava`, `c8` or `nyc` settings in `package.json`, compared as JSON so a value on a line of its own counts; changes pytest's settings in `pyproject.toml` or `setup.cfg`; skips tests or takes out a test target or plan in an Xcode scheme; excludes a test file from its target or takes it out of a target's sources in `project.pbxproj`). The diff ignores what the agent could set up to hide changes: no replacement objects (`refs/replace`) or grafts, no text conversion or external diff, binary files read as text, fixed `a/` and `b/` path prefixes, and `.gitattributes` read from `startCommit`. The agent's next round lists what's wrong, even when the command passed. When git can't say, the round fails too. Other edits to existing tests, and test files moved within the tests, don't fail it: a job that ends `done` says them in its `summary`, under `Changed in the existing tests, for review:`. New tests are fine.
  - Without a check and with more than one round, the agent's own last line decides: `GOAL MET`, or `GOAL NOT MET: …`, which means another round.
- `limit`: the limit the runner stopped the job at, or null. The runner holds every job to its limits itself; no prompt states them:
  - a round's turn may take 45 minutes (a turn the user's words start between rounds, while the check runs, too), a whole job 3 hours (every round and check included). The round's clock stands still while an Apple check the agent asked for (`oby-check apple`) is queued or running (one the job's final check asked for first too, once the agent asks for it), however long it waits: the job's 3 hours still count it. When the round runs out, the runner ends the agent; if the work is all committed, the agent's latest Apple check of the last commit didn't fail, and the check passes on that commit, the job ends `done` and publishes as any finished job does (its `summary` starts with `The round ran past 45 minutes before …`, `limit` stays null, and the review still gates the merge). Otherwise, or without a check, it's held as below;
  - Claude Code runs with `--max-turns 200`, which counts each message's turns, so each round's (checked with Claude Code 2.1.296); Codex has no such switch, so the timer alone holds it;
  - rounds run out (the Lead's jobs get 4: one attempt and three fix rounds);
  - no progress: the same failure twice in a row (the failing tests' ids, read from all of the check's output, plus its last 20 lines, with times, durations, addresses and ids taken out), or 3 actions in a row the runner denied.

  Such a job is `failed` with `limit` set (like `"the same failure twice in a row"` or ``"`swift test` still fails after 4 rounds"``), keeps its branch and pushes nothing. Its `summary` starts with `Stopped at a limit: <limit>. The branch is kept and nothing was pushed; one more round is possible.` and the notch says `Stopped at a limit: <title>`. One more round: its inbox item (kind `failed`) offers `One more round` instead of `Try again`, or `POST /v1/jobs/{id}/messages`; either clears `limit`. Stopping a job (or a limit stopping it) also ends a check that's still running. Older runners don't send this key.
- `startCommit`: the commit the work started from (the base on origin, or the pull request's head), recorded when the worktree is set up, or null before then and on older jobs. Test integrity compares with it: an agent can move a branch or a ref, not this. Older runners don't send this key.
- `firstSwiftBuildSeconds`: how long the job's first `swift build` check took, in whole seconds, or null when the job has not run one. The runner includes `First swift build: …` in the finished job's summary. Older runners don't send this key.
- `model`: a model the user chose for this job (the stronger one on the plan's card, or one it was moved to), or null for the one in Settings › Models.
- `complexity`: the brain's `routine` or `complex` classification, or null on older and internal jobs. `effort` is the reasoning effort this job's turns use; complex dispatches use that tool's `complexEffort`, routine dispatches and review/verdict jobs use `effort`. A move selects the destination tool's effort for the saved complexity. Complex job reports name the effort; this field records it for every job.
- `moves`: every time the user moved the job to another tool, account or model (`POST /v1/jobs/{id}/move`), oldest first. Always a list, empty when it never moved. Each is `{"from": "Codex · Deskree", "to": "Claude Code · Personal", "why": "Codex keeps looping", "date": "2026-10-11T14:02:10Z"}`: `from` and `to` are the tool and the account, with the model after another ` · ` when the job ran one of its own (`"Claude Code · Personal · Fable 5.1"`); `why` is what the user said when they moved it, or null. The job screens show the latest as "Moved from Codex · Deskree to Claude Code · Personal".
- `connectionUses`: every call the job's agent made to a connected app through the broker (Connected apps, below), oldest first. Always a list, empty before the first. Each records the job, connection, tool, `read` or `write`, whether it was allowed, the vault secret's name, host and date; it never records a value or request or response body.
- `notes`: what the user told the agent along the way (`POST /v1/jobs/{id}/messages`), oldest first, or null.
- `startWhen`: what the job waits for before it starts (Start when, below), as a list of conditions, or null for a job that starts at once and once it started. `waiting`: why a queued job isn't running yet (#238's shape), or null: while it waits for its `startWhen`, `{"kind": "limit", "text": "for Codex · Deskree: 5-hour window resets at 4:59 PM", "job": null}`. `kind` is `limit` when the first thing it still waits for is an account's room, else `schedule`; `text` follows "Waiting", as `step` says it whole (`"Waiting for Codex · Deskree: 5-hour window resets at 4:59 PM"`); `job` is the first job it still waits for, by id, or null. `reserved`, only while it waits for room (`{"room": true}`, Start when) that just accounts in their weekly reserve could give: those accounts' ids, on each of which the apps offer `Use Personal anyway (82% of week)` (`POST /v1/accounts/{id}/reserve`); left out otherwise. It's null once the job isn't queued. Grouping waiting jobs under Waiting in the apps comes with #238. Older runners don't send these keys.
- `title`: what to call the job in rows, the job screen, the notch and alerts. It's the brain's short title (3 to 6 words, like `"Mac runner notifications"`), which every planned dispatch gets and the job keeps. Jobs without one (the rules' plans when the brain is down, an epic's sub-issue jobs, jobs from before titles) get `"<Kind> <repo name> #<number>"` when `pr` or `issue` is set, otherwise the first line of `task` (falling back to `request`), capped at 60 characters. It's always a string; older runners don't send it, so clients fall back the same way. Show "Round 2 of 5" when `rounds` is above 1.
- `files`: the files or folders (ending in `/`) the job is expected to touch, relative to the repository: its claim (below). From the Lead's brief, from the client that started it (`POST /v1/jobs`), or else from its issue: the issue's `Files:` line (paths and folders, in backticks or separated by commas), or when it has none, the paths its title and text name (in backticks, or with a folder, like `Engine/Checks.swift` or `MCP/`). The runner reads the issue as it plans, so a job `POST /v1/plans` starts has them from the start; a job that still has none claims them when its worktree gets ready. Null when nothing named any (the job then neither waits nor blocks), `[]` when the client claimed none. `lead` is set on jobs the Lead started (below), null otherwise: the goal (one Lead turn) that started it. `claim` also reports issue-sync errors on any job; successful changes are listed in `outgoing`. Older runners don't send these keys.
- `question`: what the job's agent asked the user, `{"text": "Should a job that commits nothing end as failed, or get a new status?", "options": ["Failed", "A new status"]}` (`options` may be empty), or null, with `details` (what each option does, or null) and `recommended` (the index of the option the agent recommends, or null) when the agent gave them. Agents are told to end their summary with `QUESTION: …` and optionally `OPTIONS: <label> — <what choosing it does> | …` rather than bury a decision in their report, the way Claude Code asks: 2 or 3 short labels, each followed by ` — ` and one plain sentence, the recommended one first with `(Recommended)` after its label (taken off the label, which is what the answer sends back). Descriptions are kept only when every option has one; the runner reads those last lines when a turn ends. Markdown around the label (`**QUESTION:**`) is ignored; the question and its options keep every character, like `*.swift`. The job then waits for the answer: it stays `running` with `step` `"Waiting for your answer"`, its agent idle, and its round doesn't move on (no check runs). Other jobs keep going. The question lands in the inbox (below) and alerts the phone. The answer reaches the agent as its next message, exactly as `POST /v1/jobs/{id}/messages` would send it, and `question` goes back to null. Telling the job anything else answers it too; stopping it drops it. A job whose agent exits while its question waits is `interrupted` and keeps `question`: nothing is checked or published until it's answered, and answering picks its session up again. Across a runner restart it keeps waiting instead: still `running` with `step` `"Waiting for your answer"` and its `question`, nothing running until the answer picks its session up again, in the same round. Neither is recorded as a failure. Older runners don't send the key.
  - `plan`: an agent's plan waiting for approval, in Markdown, or null (Permission modes, below). Older runners don't send it.
- `tetrix`: what the runner saw of the job's agent and Tetrix (#130), or null before its tool said (and on older jobs):

  ```json
  {"connected": true, "calls": {"search_entities": 2, "get_entity": 1, "save_session": 1}, "rounds": [4],
   "reminded": null, "stamps": {"commits": 2, "stamped": 2, "sessions": ["ses_8f2a"]}, "author": null}
  ```

  `connected`: whether the agent had Tetrix's MCP server connected, from Claude Code's stream-json `init` (`mcp_servers`, a server named for Tetrix with `status` `connected`) or Codex's app-server (`mcpServerStatus/list`: one with tools that isn't `notLoggedIn`); a call to a Tetrix tool counts as connected too. Null when the tool didn't say. `calls`: the agent's calls to Tetrix's tools by name, over every round (Claude Code's `tool_use` named `mcp__<server>__<tool>`, Codex's `mcpToolCall` items, where the server's name holds `tetrix`). `rounds`: Tetrix calls in each round that ended, oldest first, or null. `reminded`: true once a round that had Tetrix connected and called none of it got a reminder in the next round's message (once a job). `stamps`: the job's commits since `startCommit` and how many carry a `Tetrix-Session: <id>` trailer, with the sessions they name, read when its last round ends done, or null. `author`: on Oby's review jobs, what the runner saw of the author's agent, as the reviewer is told; else null.
  - Agents are told to start by asking Tetrix about the job's issue or pull request and the area it touches (`search_entities`, `get_entity`, `code_impact` where the repository's code is indexed) before reading many files, and to end with `save_session` and the `Tetrix-Session:` trailer on their commits. Among MCP tools, agents may call only Tetrix's graph reads and `save_session`.
  - When the job ends, its `summary` ends with a line like `Tetrix: 4 calls (search_entities 2, get_entity 1, save_session 1). Session saved. 2 of 2 commits stamped Tetrix-Session (ses_8f2a).`, or `Tetrix: connected, but the agent didn't use it.`, or `Tetrix: not connected for this account's agent, so it wasn't asked. …`. Not on review jobs: their last line is the verdict. Older runners don't send the key.
- `mode`: how much the job asks the user, `ask`, `acceptEdits`, `plan` or `bypass` (Permission modes, below). Jobs from before modes are `bypass`. Older runners don't send the key.
- `permission`: the command or edit the job's agent waits for the user's OK on, or null:

  ```json
  {"id": "p1a2b3c", "tool": "Bash", "title": "Run swift test", "detail": "swift test --filter SpeechTests",
   "rule": "Bash(swift test:*)", "always": "Yes, and don't ask again for swift test in deskree-inc/oby"}
  ```

  `tool` is Claude Code's tool name (Codex's commands are `Bash`, its file changes `Edit`). `title` is what the card asks ("Run swift test", "Edit Jobs.swift", "Fetch example.com"), `detail` the whole command, the files (relative to the repository) or the address. `rule` is what "always" saves, in Claude Code's syntax, and `always` the sentence to show for it; both are null when the runner can't make a safe rule (a command chained with `&&`, `;` or a pipe, or one that runs whatever follows it: a shell, an interpreter or a wrapper like `bash -c`, `python3`, `node`, `env`, `sudo`, `xargs`, `uv run`, `npm exec`): then it can only be allowed once. While it's set the job stays `running` with `step` `"Waiting for your OK"`, its agent idle, and its round and job clocks paused: waiting doesn't count toward the 45-minute round or the 3-hour job. Other jobs keep going. It lands in the inbox (kind `permission`) and alerts the phone and the Watch. Answer it with `POST /v1/jobs/{id}/permission`, the inbox, or in words. When it's answered, the agent's next waiting prompt (if any) takes its place. Stopping the job drops it. A job whose agent ends while one waits (the runner restarted) is `interrupted` and keeps `permission`: answering it picks the session up again and tells the agent the answer. Older runners don't send the key.
- **Jobs run side by side, at most `maxRunning` at once** (#237, `GET /v1/status`, `PUT /v1/settings/jobs`, 6 unless changed). A job whose worktree is ready starts when fewer than `maxRunning` jobs are running and no older job waits; otherwise it waits, `queued`, with `step` `Waiting for a free slot: 6 of 6 jobs running`, and the waiting jobs start oldest first as slots free up. Every job whose agent is running takes a slot: Oby's reviews, and the rounds of a job that started already (a review's changes, a rebase, a failed Mac check, the user's words), which never wait for one, so the count can briefly pass the cap. A job waiting for the user's answer takes none. Before a job that waited starts, its branch moves to its base as GitHub has it now (`step` `Bringing <branch> up to date with dev`), so it works on top of what merged meanwhile: only while its worktree has no work of its own, and never on a pull request's branch. When `dev` can't be fetched, it's `failed` with `Couldn't bring <branch> up to date with dev: <why>` rather than start on stale code. Account routing still picks each job's account.
- **`files` is the job's claim, and holds nothing back.** Jobs whose `files` overlap in the same repository (the same path, or one inside a folder the other names) run side by side, each in its own worktree; conflicts are settled when they merge. A claim lasts while the job is queued or running, and after, while its pull request is open or its commits wait to be published (#209); it ends when the pull request is merged or closed, the user dismisses or stops the job, or the job ends with nothing to publish. It does two things. The agent's prompt names the in-flight jobs whose claims overlap its own, with their titles, ids, branches and pull requests, and asks it to keep its change small and expect a rebase. And when two approved pull requests overlap, the older job's merges first: the newer one's Mac check stays queued while the older one's is queued, running or passed and not merged yet, then it's checked, and a conflict with what merged is rebased (Mac check, below).
- `waiting`: why a `queued` job hasn't started (#238), `{"kind": "cap", "text": "a slot opens"}`, or null when nothing holds it (its worktree is getting ready, it's being brought up to date, or it's about to start) and on every job that isn't `queued`. `text` is what every app shows after **Waiting**, like "Waiting · a slot opens"; `job` is the job it waits behind, for `job` and `files`, else absent. `kind` is one of:
  - `cap`: every slot is taken (`maxRunning`, above): `"a slot opens"`. Its `step` reads `Waiting for a free slot: 6 of 6 jobs running`.
  - `update`: the runner is draining for an update (below): `"runner update"`. Its `step` reads `Waiting for runner update`.
  - `schedule`, `limit`: what its `startWhen` waits for (Start when, below): another job, a pull request or a time (`schedule`), or an account's room (`limit`). Its `step` says the same, like `Waiting for Cards screen (#250) to merge`.
  - `job`, `files`: another job, or its claim. Jobs on the same files run side by side (#237), so this runner doesn't set them.

  The apps list a job with `waiting` set under **Waiting**, with a gray `Waiting` badge, between **Working** (running jobs, and queued ones getting ready, badged `Starting`) and **Needs you**. Counts and headlines count running jobs as working, and waiting ones apart: "1 agent is working, 14 waiting." Older runners don't send the key: their queued jobs read as getting ready.

### Start when

A job can wait for something before it starts (#216): another job or a pull request to finish, an account to have room, or a time. Its `startWhen` lists what must all hold, each one of:

- `{"job": "ab12cd34", "is": "done"}`: after another job, by id. `is` is `done` (it ended done), `merged` (its pull request was merged), `published` (its pull request is out) or `ended` (it ended in any way); left out, `done`.
- `{"pr": 205, "is": "merged"}`: after a pull request in the job's repository. `is` is `merged` or `closed` (closed in any way, a merge too); left out, `merged`.
- `{"account": "<id or name>", "window": "fiveHour", "under": 0.5}`: once the account has room in its 5-hour (`fiveHour`) or weekly (`sevenDay`) window: its use is under `under` (a share above 0 and up to 1; left out, 0.8, the share routing calls busy). A window whose reset time has passed counts as empty (Claude Code reports usage only during a job, so its last share would stay), so `"do this on Codex once its 5-hour window resets"` starts at the reset, or at once when Codex has room already. Not while the account is signed out or stopped at its limit. The runner keeps every account's last usage, reset times and limit in `usage.json`, so a restart doesn't forget a window it waits on (Claude Code reports usage only during a job).
- `{"account": "<id or name>", "onPace": true}`: once the account's weekly use is back on pace (Account, `isAhead` false: its share of the week used is no more than the share of the week gone).
- `{"room": true, "agent": "claude"}`: once routing has an account for it, of that tool (`claude` or `codex`; left out, any). Its `account` until then is one it may run on; when this holds it runs on the account routing picks then, as if just sent, and its report says why. A request that only accounts in their weekly reserve could take starts with this (below, Routing): `waiting.kind` is `limit` and `step` says `"Waiting for room: Personal and Codex are in their weekly reserve"`, or `"Waiting for an account with room"` when no lift would help.
- `{"at": "2026-10-13T09:00:00-03:00"}`: at a time, ISO 8601 with its offset.

At most 5. The runner checks them when the job is dispatched (`422` with why: an unknown job, account or tool, the job itself, a share out of range, two accounts, or room with an account), and keeps accounts by id. A job waiting on an account runs on it: `account` and `agent` are that account's. Picking another account on the plan card, or moving the job, drops waiting for room: it runs where it was put.

The job gets its worktree ready, then waits `queued`, with `waiting` and `step` saying what for, joining every condition still to hold with ", and": `"Waiting for Cards screen (#250) to merge, and until 9:00 AM"`. It doesn't count as running on its account, takes no slot (`maxRunning`), and its `files` claim holds from when it was queued, like any queued job's. The runner checks every minute, and as soon as any job ends: pull requests it waits on (and the pull request of a job it waits to see merged) are read from GitHub then. Once everything holds, `startWhen` goes back to null, it's brought up to date with its base and starts (or waits for a slot), and its report says `Started when what it waited for came: …`. It keeps waiting across runner restarts, however many: it never ran, so it isn't picked up like a job whose agent crashed. What changes while its worktree gets ready (started now, told to wait for something else) holds once it's ready. The Mac's, the iPhone's and the Watch's job screens have Start now, and the Watch's list says `Scheduled, waiting …` where it would say Starting.

A condition that can never hold (the job it waits on failed, was stopped or ended with nothing published; the pull request was closed without merging; the account is gone) makes it a decision: `step` is `"Waiting for you: Broken build failed, so it won't be done."` and `question` asks `"It can't start as planned: …. Start it anyway, cancel it, or wait for something else?"` with the options `Start anyway`, `Cancel` and `Wait for something else`, as a `question` inbox item. `Start anyway` starts it now; `Cancel` stops it; `Wait for something else` keeps it waiting, unasked (a failed job tried again, a pull request reopened, may still come), until you change what it waits for (`POST /v1/jobs/{id}/start-when`), start it or stop it. Other words are refused (`422`). After a restart it asks again.

A waiting job can be started now (`POST /v1/jobs/{id}/start`), told to wait for something else (`POST /v1/jobs/{id}/start-when`), moved (`POST /v1/jobs/{id}/move`: what it waited for on an account it left goes, and with nothing left it starts; a new model on the same account keeps it) or stopped (`POST /v1/jobs/{id}/stop`). In words, the brain fills `startWhen` on the job it plans (`POST /v1/plans`), which then starts waiting: "do this on Codex when it resets", "after the cards job merges", "once #205 is merged", "tomorrow at 9", "when Personal has room".

### Job pipeline and pull request following

Every job response (list, detail, dispatch, stop, message, wait, plan and `job` SSE event) includes `pipeline`, derived in Engine from the job's execution facts and last observed PR state. Clients render it instead of reconstructing stages from `step` text.

- `pipeline.stages`: ordered `prepare`, `work`, optional `check`, `publish`, `review`, `merged`. Each has `id`, `title`, `state`, optional `detail` and optional `reason`. States are `done`, `current`, `upcoming`, `failed`, `skipped`; every failed stage includes a reason. Check is absent when no check command is configured. Work includes the round and live agent step. Publish includes secret scan, push and PR creation progress.
- `pipeline.number` and `pipeline.total`: one-based position and count of displayed stages, including skipped ones. Display “Stage n of m”. The position is the first current/failed stage, otherwise the last completed/skipped stage. A completed investigation with no commits skips Publish, Review and Merged and reports 5 of 5. A failure/cancellation marks its execution stage failed with its reason and skips downstream stages.
- A done, published job progresses through Review: waiting (`current`), changes requested (`failed`, with reason), approved (`done`, with merge current). A merged PR completes Review (`Approved`, or `Merged without review` when GitHub has no review decision) and the final stage; a closed, unmerged PR fails Review and skips Merged. The merge title uses GitHub's actual base, normally “Merged into dev”. Running again shows Work before the earlier round's PR progress.
- `phase` (optional): persisted execution phase `prepare`, `work`, `check` or `publish`. `publishStep` (optional): `scan`, `push` or `pullRequest`. These are execution facts, not separate client derivation rules. Older saved jobs have neither; Engine derives their best available progress.
- `pullRequest`: null until a successful read, otherwise `{"state":"OPEN","reviewDecision":"REVIEW_REQUIRED","base":"dev","mergedAt":null,"checkedAt":"2026-10-09T21:43:30Z"}`. State is `OPEN`, `CLOSED` or `MERGED`; review decision is `REVIEW_REQUIRED`, `CHANGES_REQUESTED`, `APPROVED`, or absent/null (no decision yet). `mergedAt` is present only after a merge. `head` is the pull request's head commit as GitHub has it (absent on older observations): one Oby didn't push is an intervention (Failure record, below). All dates are ISO 8601.
- The runner polls published PRs on startup and every three minutes while open/unknown, using its own `gh pr view` outside the agents' sandbox. It follows `published`, not the input `pr`, including saved jobs older than the latest 50. Closed and merged PRs stop polling. Fresh saved observations wait for the next interval after restart.
- `pullRequestError`: null after a successful refresh; otherwise a short retry message. Network/authentication/JSON failures preserve the last successful observation and retry at the next interval. `checkedAt` remains the date of that last success. Updates are saved and sent as `job` events without overwriting a concurrent agent step or resumed round.
- Following is read-only: it never posts a review, pushes, or merges (merging is the Mac check's, below). [`gh pr view` JSON fields](https://cli.github.com/manual/gh_pr_view) supply only typed status data; GitHub prose never enters an agent prompt.
- Older clients ignore these additive fields. New clients accept an absent pipeline from an older runner and show its ordinary status/step instead.

### Oby's review

When a job publishes (or pushes new commits to its pull request), the runner has the pull request reviewed by one of its own jobs, on a different account than the author's: it prefers the other tool (Claude Code reviews Codex's work, Codex reviews Claude Code's), takes only an account that's signed in with room on its limits (under 95% of its 5-hour window and under 80% of its weekly one, which keeps the rest for jobs the user sends to it by name), preferring one running ahead of its weekly pace, since a review is short (Routing, under Account), and runs it on that account's model from Settings › Models. With no such account, nothing reviews and `reviewError` says so.

Oby reviews a pull request up to 6 times (`Review.maxRounds`; 2 until 2026-10-13). A round that answers changes requested is always reviewed. Rounds a Mac check, a conflict, Xcode Cloud or the user started count toward the 6, so a fix after an approval gets its review and goes on to the Mac check and the merge. A blocker that comes back still stops the job and asks the user. When the runner starts, new commits that were refused a review under the old cap (`reviewError` "Oby reviewed it N times already…") get their review.

- **The review job** is an ordinary `Job` in the list and the event stream: `kind` `review`, `pr` the published pull request's number, `branch` like `oby/review-80`, `task` the author's task, and `reviewOf` the author job's `id` (null on every other job). It reads the diff and the author's task, makes no commits and never publishes. Its `summary` is the review; its last line is the verdict (`VERDICT: APPROVED` or `VERDICT: CHANGES REQUESTED`).
- A first review checks the issue's acceptance criteria and completion tests, bugs in the change and called code, repository rules, and end-to-end behavior on each affected platform in one pass. A blocker must include `Evidence:`: a failing test or probe with its command and relevant output, or exact lines proving the bug for an input. A `Blocking:` item without evidence is treated as worth doing later. Blockers are limited to 10 and ordered by severity; style, pre-existing issues, general requests for more tests, wording and lint findings do not block.
- When the PR merges with review follow-ups, Oby creates one issue containing the accumulated list. Its stable marker lets a retry after a runner restart find the issue it already created; `review.followUpIssue` contains its URL once filed.
- **On the author job:** `reviewing` is the review job's `id` while it runs, else null. `review` is Oby's latest verdict, or null:

  ```json
  {"verdict": "approved", "job": "3c9d1e20", "agent": "codex", "account": "Work", "round": 1,
   "date": "2026-10-09T22:04:11Z", "checkRun": "https://github.com/deskree-inc/oby/runs/41800000001"}
  ```

  `verdict` is `approved` or `changesRequested`; `job` the review job; `agent` and `account` the reviewer's tool and account name; `round` which of Oby's reviews of this pull request it is (from 1: rounds that fix the last blocker are reviewed however many it takes); `checkRun` the check run it was written as, or absent with `postError` saying why it wasn't (a possible secret in the review, `gh` failing, or the GitHub app missing or without Checks: write: `Not posted: the Oby app needs Checks: Read and write on its installation.`). Reviews from runners before check runs carry `comment`, the pull request comment they were posted as, instead. `applying` is true from the moment the verdict is recorded until its check run is posted and the author's round started (or the approval's Mac check queued), and absent after: it's cleared in the same save as the round (after the round's message is in `restarts.json`) or the Mac check, so a restart anywhere before leaves it set, and the runner does them when it starts again ("After any restart"). `reviewError` says why no review ran or none gave a verdict (no account with room, the reviewer failed, was stopped or interrupted, or gave no verdict), else null.
- **The check run** (#198). GitHub doesn't let the user approve or request changes on their own pull request, and a comment from the app emails the owner, so the runner writes the review as a check run named `Oby review` on the commit the reviewer read, as the GitHub app (`POST repos/{owner}/{repo}/check-runs`, `status` `completed`): `conclusion` `success` when approved and `failure` when changes are requested, titled `Oby review · Claude Code · Personal: Approved` (or `Changes requested`), its summary the review itself in a code block (so no mention, link or image in it takes effect) and a `by Oby` line. A check run sends nobody an email. Another review of the same commit updates the app's own `Oby review` check run there (`PATCH …/check-runs/{id}`) rather than adding one. The secret scan gates it, with the same rules and encoded copies as publishing: a possible secret means no check run, and the verdict still counts. Only a GitHub app can write check runs, and only with **Checks: Read and write**: with no app, or until the owner grants that permission, nothing goes on the pull request, the review stays in Oby (the job, the inbox, the apps), `postError` says why, and [`GET /v1/status`](#get-v1status) says `"checks": "missing permission"` (or `"no app"`). Oby never comments on a pull request. A written check run is listed in the author job's `outgoing`.
- **The Review stage** shows GitHub's decision when it has one, else Oby's: `Oby is reviewing` (current), `Approved by Oby` (done, with Merged following the Mac check, below), or `Changes requested` (failed, reason `Oby requested changes.`). A failed review leaves it current with `Waiting for review · <reviewError>`. A merged pull request with no GitHub decision reads `Approved by Oby` or `Oby requested changes` instead of `Merged without review`.
- **Changes requested** go to the author's agent as its next round, in the same session and worktree: the review is quoted in a file (`.oby/inputs/review-<round>.md`), never pasted into the prompt. The job goes back to `running` with a new `round` (and one more on `rounds`, as a message does), `step` `Working on Oby's review`, and ends as usual: when its check passes and it publishes the new commits, the review runs again. Rounds go on while each one fixes what the last review blocked on (#224): a follow-up reviewer starts a blocking finding with `Again:` when it's one an earlier review blocked on that the new commits didn't fix, or that came back (its file quotes the last review's blocking findings and the earlier ones fixed since). Such a review carries `repeated: true`, and the job stops there, and only there, however many reviews came before: it stays `done` and needs you (`reviewNeedsYou`, below). A round that doesn't answer changes requested (one you start after it stopped, or a Mac check's fix after an approval) is reviewed only while Oby has reviewed the job fewer than 2 times (more after `One more round` on a stopped merge, `extraReviews`): after a stop, the runner reviews it no more, even after you talk to it. A review's `blocking` lists what it found blocking and `blockedBefore` what the earlier ones did.
- **Approved:** the commit the reviewer read is checked on the user's Mac, and the runner merges it into `dev` when that passes (below). A `Blocking:` section containing `(none)` has no blocking findings; an approved follow-up proceeds even at the review cap.
- What needs you now also includes a `done`, published job whose review stopped (`reviewNeedsYou`, always sent, derived by the runner: its `review` is `changesRequested` with `repeated` true, or `round` 2 or more on reviews from runners before `repeated`) while the pull request is open, and one whose merge stopped (`mergeNeedsYou`, Mac check below). Say so where the apps list what needs you ("1 job needs your review").

### Mac check

GitHub Actions doesn't run for deskree-inc/oby, so the user's Mac checks a pull request before the runner merges it (#66). Only the runner queues checks: on the Mac's own Oby, an approved job's Merged stage reads `Ready to merge`, for a person. When Oby's review approves a job's pull request, the runner queues a check of the commit the reviewer read, when that's still the commit the runner last pushed to the pull request. A Mac running Oby that follows the runner, with Settings › Runner › "Run merge checks on this Mac" on (the default), takes it, runs it and reports the result.

Jobs started by one chat message share a build batch; jobs started by one Lead goal share its goal id. A job started alone is its own batch. Once a batch settles (all its jobs merged into `dev`, stopped or dismissed), the runner waits two hours for other batches to settle (a batch with a job still running is not tagged); the wait is saved with the jobs, so a runner restart picks it up again, then compares `dev` with the last `oby-build/*` tag. Settled batches for the same repo in that window share one tag. If a file under `iOS/`, `iOSTests/`, `Shared/`, `Watch/`, `LiveActivity/`, `Character/`, `Icon/` or `Oby.xcodeproj` changed, it creates `oby-build/<yyyy-MM-dd>.<n>` at `dev`'s head. Configure Xcode Cloud's TestFlight workflow to start on tag changes matching `oby-build/`, and turn off its pull request workflow in App Store Connect. Runner-only batches are recorded in each job's report without a tag. The chat does not yet offer a “Build now” action, and the runner does not yet report Xcode Cloud results to the inbox. A pull request without Xcode Cloud checks still waits only for Oby's review and the user's Mac check; no Cloud result is required to merge.

```json
{"id": "c0ffee12", "job": "9f08fd10", "repo": "deskree-inc/oby", "pr": 80, "branch": "oby/fix-75", "base": "dev",
 "head": "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b", "round": 1, "state": "failed",
 "created": "2026-10-11T09:00:00Z", "started": "2026-10-11T09:00:02Z", "finished": "2026-10-11T09:14:40Z", "mac": "Studio",
 "steps": [{"name": "Runner tests (swift test)", "passed": true, "seconds": 125},
           {"name": "Mac app and MacTests", "passed": false, "seconds": 301},
           {"name": "iPhone app with Watch, and iOSTests", "passed": true, "seconds": 412}],
 "failures": ["MacTests.PublishTests/blocksASecret()"],
 "checkRun": "https://github.com/deskree-inc/oby/runs/41800000002", "comment": null, "postError": null}
```

- `kind`: `merge` (this section) or `apple` (an agent's Apple check, below). Always sent; checks from before Apple checks are `merge`.
- `job`: the author job. `head`: the commit checked. `round`: which of the job's checks it is (1 to 3).
- `state`: `queued`, `running` (a Mac took it: `mac` is the name it gave, `started` when), `passed`, `failed`, or `error`: the Mac couldn't run it, and `problem` says why (its checkout or the vault failed, a tool or the simulator is missing, xcodebuild failed other than with a failing build or test, a step was stopped at its timeout without naming a failing test (`problem` names the last test that started), or the Mac's own trouble got in the way of a step twice (an xcodebuild step whose build didn't fail but that wrote no result bundle and named no failing test counts too: PR #140's ended after 1011 seconds like that): `Mac check couldn't run: the iPhone simulator's test runner hung, and again after Oby restarted the simulators and ran … once more.`). An `error` is nothing the code can fix: its check run is `neutral`, nothing goes to the author, it needs you, and Try again checks the same commit again. `handedOff` is true once a failed check's tests went to the author as a round. `steps` and `failures` (the failing tests' names) come with the result; a failed step may carry `failing`, its failing tests with their messages (`[{"test": "iOSTests/JobRowTests/testTitle()", "message": "XCTAssertEqual failed: …"}]`), and `retried: true` when it ran a second time; `runtime`, the simulator runtime its last run used, like `iOS 26.5 (23F77)`; `checkRun` is the check run with the results, or null with `postError` saying why there's none (as for the review); `comment`, always null now, is the pull request comment a runner from before check runs posted them as.
- **On the Mac:** a clean worktree of `head`, detached, in Oby's own clone, then, one at a time and each with a timeout: `swift test` (30 minutes), the `Oby` scheme's build with `MacTests` (20 minutes), and the `ObyPhone` scheme (with `ObyWatch` embedded) with `iOSTests` on an iPhone 17 simulator (20 minutes), all signed ad hoc as docs/ci.md describes. Every step runs, so a failing check names everything that fails. A step writes to a file, not a pipe; at its timeout its whole process group is ended (TERM, then KILL), and the Mac stops waiting on it a few seconds later whatever is left, so a hung test can't keep the Mac busy. Each xcodebuild step writes a result bundle (`-resultBundlePath`); when it fails, the Mac reads its failing tests and their messages with `xcrun xcresulttool get test-results summary`, else from what the step printed. A merge check whose report has only environmental trouble after its runner tests pass can reuse a passed Apple check for the same commit's two app steps, so the earlier code test and the current runner test count as a pass. **The Mac's own trouble:** when a failed xcodebuild step names no failing test of its own and its result bundle or output shows that the test runner hung before establishing a connection (or never began executing tests), lost its connection to the test manager, the simulator failed to boot or the app or test runner to install (`Mach error -308`), or the test daemon never got ready, the Mac shuts every simulator down (`xcrun simctl shutdown all`), ends `com.apple.CoreSimulator.CoreSimulatorService` (launchd starts it again) and `dtdeviceinfod` (a crashed one fails the next install with `Mach error -308 - (ipc/mig) server died`), ends whatever the check built that's still running (its test runners and hosts, by their DerivedData path) and runs that step once more: the iPhone step on the newest older iOS runtime that has an iPhone 17 and never hung there (`xcrun simctl list runtimes --json` and `list devices --json`), else on the same one. **Simulator runtimes:** the iPhone step runs on `name=iPhone 17,OS=<version>`: the runtime that last got past the simulator while it's installed, else the newest that never hung, else the newest (`OS=latest` when simctl can't say). The Mac remembers both in `checks/runtimes.json` under Oby's folder: a runtime the Mac's trouble stopped a run on is marked hung (the iOS 27.0 runtime 24A434 hung every time in October 2026, while 26.5 passed in about two minutes), and one a run got past (passed, or failed in the code) is used until it fails. Failing the same way again, the check is `error` with a `problem` that starts `Mac check couldn't run: ` and says which trouble: nothing goes to the author. A compiler error in the output always makes it the code's. The commands get no GitHub login and no variable holding a vault secret, and a throwaway `OBY_HOME` (also as `TEST_RUNNER_OBY_HOME`, which xcodebuild hands to the test host without the prefix), so the MacTests host, an Oby itself, never opens the Mac's own `oby.sqlite` or marks its running jobs interrupted. They still run with the user's access to the Mac: Oby's review is the gate before pull request code runs there. The worktree is removed afterwards; build caches are kept between checks.
- **On the author job:** `macCheck` is the latest check, null before one; besides the keys above it may carry `tries` (merge attempts since it passed) and `transient` (the last attempt failed on something that may pass later). `mergeError` says why Oby couldn't check or merge the pull request, or null. `mergeNeedsYou` (always sent, derived by the runner) is true when the merge stopped where a person takes over (below).
- **The check run** (#198). The runner writes the results on the checked commit as the GitHub app, after the secret scan, as a check run named `Oby Mac check`, never a comment: `conclusion` `success` when it passed, `failure` when it failed and `neutral` when the Mac couldn't run it (`error`, its `problem` in a code block), titled `Oby Mac check · Studio: Passed` (or `Failed`, `Couldn't run`), its summary a table of the steps with their times (the iPhone step names the simulator runtime it ran on, like `iPhone app with Watch, and iOSTests on iOS 26.5 (23F77)`; `Failed (second run)` for a step that ran twice), each failed step's failing tests with their messages in a code block (`Failing tests in Mac app and MacTests:`; just `Failing tests:` with the names from a Mac from before steps carried them), and a `by Oby` line. Never the build's output. A later check of the same commit (Try again) updates the app's own `Oby Mac check` check run there. Without the app or its Checks: write permission nothing is written, as for the review. It's listed in the job's `outgoing`. Results for a commit the job moved on from (it ran again, or pushed since) are kept on `macCheck` but not posted, and change nothing else.
- **Passed:** the runner merges when all of these hold: Oby's review approved, the check passed on the commit the pull request has (`head` is the last commit pushed, nothing unpushed), the pull request is open with no change request on GitHub, its base is `dev`, and the secret scan of what the merge lands (every commit not on `dev`, and their files, as publishing scans them) is clean. It reads the pull request from GitHub once more (`GET repos/{owner}/{repo}/pulls/{n}`: open, into `dev`, `head` as its head), then merges it through the REST API, as the GitHub app when there is one ([`GET /v1/status`](#get-v1status)): `PUT …/pulls/{n}/merge` with `merge_method` `squash`, `sha` `head`, and Oby's own `commit_title` and `commit_message`, on the REST budget rather than GraphQL's. The title is the pull request's with ` (#n)`; the message is what its commits say (`GET …/pulls/{n}/commits`), as GitHub's default squash message has it, with every closing keyword (`Closes #116`, `fixes o/r#7`) turned into `Part of`. Right before the merge, both go through the secret scan with the vault as it is then; a finding, or a scan that can't run, leaves the job unmerged. Nothing from the description lands in `dev`, whatever the repository's squash setting, so its `Closes #N` links the pull request to its issue without closing an epic when `dev` reaches `main`, and reviewers are told not to block on it (#167). Then it deletes the branch when it's in the same repository (`DELETE …/git/refs/heads/<branch>`); a branch left over doesn't fail the merge. The merge is listed in `outgoing`, `pullRequest` becomes `MERGED` and the Merged stage completes. Anything that fails leaves the job unmerged, with `mergeError` saying why (`Not merged: possible secret in README.md:3 (AWS access key).`). Never into `main`.
- **Conflicts with `dev`:** when GitHub says the pull request can't merge (`mergeable` false or `mergeable_state` `dirty` on `GET …/pulls/{n}`, read before the merge and again when it fails), the merge isn't tried again by itself. Instead the runner fetches `dev` from GitHub into the job's clone (the agent's sandbox has no GitHub login) and hands the author's agent a rebase round, in the same session and worktree: the job goes back to `running` with a new `round` and `step` `Rebasing onto dev`, and the prompt names the commit of `origin/dev` to rebase onto and says never to merge `dev` in. When the round ends, the rebased commits publish by themselves with `--force-with-lease` ([`GET /v1/jobs/{id}/publish`](#get-v1jobsidpublish)), and Oby reviews, checks and merges the new head as before; one more review is allowed for it (`extraReviews`). When the rebase leaves the patch as it was (#237), it isn't reviewed again: `git range-diff` of the old commits on their old base and the new ones on `dev` pairs every commit, none added or dropped, and where a pair differs, only in files the pull request touched already (the conflict's resolution). Then Oby's approval carries over to the new head, its Mac check is queued at once, and the job's report says `Rebased onto dev with the same patch: Oby's approval carries over to <commit>, and its Mac check is next.` Anything else, or a `range-diff` git can't run, is reviewed as before. A conflict handled so needs nobody: `mergeError` stays null, nothing reaches the inbox and no failure is recorded (#209). Only a rebase that can't settle it sets `mergeError`, `Not merged: it conflicts with dev.` and why, which needs you and is a `mergeError` failure: the same conflict with the same `dev` again (`… Oby rebased it onto <commit> already, and it still conflicts.`), 6 rebases of the pull request in the last 24 hours already (`… Oby rebased it 6 times today already: a person takes it from here.`, `rebases` lists when), a job with no session to rebase it, or `dev` that couldn't be fetched. A rebase round that fails is a `failed` job, as any. Try again, once `dev` moved on, rebases once more.
- **Recovery.** When the runner starts, and every five minutes, it finishes again a passed check whose pull request isn't merged: one it never finished (it stopped while posting the results or merging), and one whose last attempt failed on `gh`, the network or a scan that couldn't run, up to 3 attempts. A possible secret or a refusal isn't tried again by itself. A failed check with rounds left whose round for the author never started (the runner stopped before or after posting the results) goes on to its check run, when it has none, and the round.
- **Failed:** the failing tests go to the author's agent as its next round, in the same session and worktree, quoted in a file (`.oby/inputs/mac-check-<round>.md`, with each step's result, each failed step's failing tests with their messages, and, for a failed step that names no test, the compiler's errors or else the last 40 lines it printed), never in the prompt. The job goes back to `running` with a new `round` and `step` `Working on the Mac check`; when it publishes the fix, Oby reviews it again, and an approval queues the next check. After the third failed check, or when Oby's reviews are used up (its 6th review was the one that approved, so a fix could never be reviewed; the cap was 2 until 2026-10-13, and every fix after a second review stalled), no round starts: the job stays `done` and the Merged stage says so. Its inbox item's Try again checks the same commit again (as the same round), and when the check named failing tests and Oby's reviews are used up, One more round hands them to the author anyway and lets Oby review the fix once more (the job's `extraReviews`, left out until then, counts the reviews allowed beyond the usual cap). A round that ends with no new commit leaves the failed check on the pull request's head: that needs you too, and Try again checks the same commit again (as the same round).
- **What needs you:** a merge that stopped, while the pull request is open, Oby's review approved the checked commit and the job isn't dismissed: `mergeError` set after the check, a check the Mac couldn't run (`error`), a failed check with no round left, or one whose round brought no new commit. It counts in what needs you, sends an alert (`Not merged: <title>`) and brings a `merge` inbox item.
- **The Merged stage** while Oby's review approved it: `Waiting for a Mac check` (`current`), `Checking on Studio` (`current`), `Mac check passed · merging` (`current`), `Mac check failed` (`failed`, reason like `1 test failed on Studio: MacTests.PublishTests/blocksASecret()`, plus `The Mac check failed 3 times. Take it from here.` after the third), `Mac check couldn't run` (`failed`, reason `problem`), `Not merged` (`failed`, reason `mergeError`), then `done` once merged. Before a check is queued, and wherever none is (the Mac's own jobs, older ones), `Ready to merge`.

### Apple check

Agents run on the runner, which has no Xcode, so an agent that changes the Apple apps asks the user's Mac to build and test them mid-round (#118): `oby-check apple` in its sandbox. The runner queues an Apple check of the job's worktree commit (`HEAD`), a Mac check (above) with `kind` `apple`; a Mac that follows the runner with Settings › Runner › "Build and test agents' work on this Mac" on (the default) takes it before any merge check, fetches its commits from the runner (`GET /v1/checks/{id}/bundle`: they aren't on GitHub yet), and runs the `Oby` scheme with `MacTests` and the `ObyPhone` scheme (with `ObyWatch`) with `iOSTests`, as a merge check does, without `swift test` (the agent runs that on the runner). Same clean worktree, timeouts, ad hoc signing, throwaway `OBY_HOME` and no GitHub login or vault secret. Paths in what the failing steps printed are relative to the repository.

- **On the job:** `appleCheck` is the job's latest Apple check, or null. `appleRan` is the latest one that ran (`passed` or `failed`), or null: it stays when the agent asks for a newer commit, so a newer check that can't run never hides one that did. `pr` is the job's pull request, or 0 before it has one; `round` counts the job's Apple checks (at most 20 per job). Nothing is posted on GitHub, merged or handed to another round: the result is for the agent waiting on it, and for the reviewer (Oby's review, below). What the failing steps printed is kept in memory only, for the agent and the reviewer, for the job's latest check and the latest that ran.
- **Asking again** for the same commit picks up the same check (or its result), unless it couldn't run. A new commit is a new check; the old one's result, if a Mac still sends it, is answered `404`.
- **Who takes it:** only a job that's running (`queued` or `running`) and only from a Mac that says it takes Apple checks (`kinds`, below). A Mac running another check finishes it first.
- **No Mac:** a check no Mac took within a minute while no Mac was busy (counted from when a Mac last ended a check, if that's later than it was queued), or within an hour at all, is `error` with `problem` saying so, and the agent is told to carry on and say in its summary that the Apple apps weren't built.
- **As a job's check** (#68): a job whose check runs `oby-check apple` gets the same command, API address and `PATH` as its agent, with a token of the final check's own and `OBY_CHECK_WAIT` (the test-run limit, 20 minutes, less 30 seconds), so the command waits that long for the result. The check it asks for carries `finalCheck` (when it asked) and waits for a Mac, busy or not, until 1 minute before that limit; an agent's own check of the same commit, still queued, waits as long from then. A Mac busy with a merge check takes it next, before any waiting merge check. When no Mac took it by the time the check ends, it's `error` (withdrawn if still queued), and the rest of the command still decides: when the check failed, Oby runs it again with `OBY_CHECK_SKIP=1`, where `oby-check apple` says so and exits `0`. Passing that way, the job ends done with a note that the Apple apps weren't built, and its pull request says the check passed without its Apple build; the Mac check before merging builds and tests them. Failing, it's an ordinary failed round.
- **Security:** the Mac runs the agent's code (its build phases and tests) before Oby's review has read it, with the user's access to the Mac. The setting turns it off; a merge check still needs the review.
- **Reviews:** when a job's pull request is reviewed, the reviewer gets the latest Apple build and test that ran (passed or failed), the job's Apple check (`appleCheck`, else `appleRan`) or its merge check, whichever ended last, quoted in `.oby/inputs/apple-check.md` with its commit (and whether it's the pull request's head), its steps, failing tests and, for an Apple check, the end of what the failing steps printed. It's told not to request changes because the code wasn't compiled.

### Xcode Cloud

Xcode Cloud builds and tests every pull request into `dev` (the "Pull Requests" workflow), as GitHub check runs like `Test - iOS` (#122). GitHub Actions stays off. Each time the runner follows a published pull request (every 3 minutes, with the same login), it reads the pull request's head (`headRefOid`), then that commit's check runs (`repos/<repo>/commits/<sha>/check-runs`, every page). Only Xcode Cloud's runs on that commit count, and of each task only the newest run (a rerun replaces the one before it); Oby's own check runs aren't Xcode Cloud's. Each failed task's failure annotations (failing tests, compiler errors) are read too, and come first.

- `xcodeCloud`: null until the pull request has Xcode Cloud checks, otherwise `{head, state, details, conflict, checkedAt, rounds, handedOff, problem, stops}`. `state` is `pending`, `passed` (every task succeeded) or `failed` (one finished otherwise). `details` is each task's conclusion and what it reported, 16,000 characters at most. `conflict`: Xcode Cloud said “Your source code changes conflict with changes made on the pull request target branch”. `rounds` counts the fix rounds Oby handed to the author, on any head. `handedOff`: this head's failure reached the author. `problem`: why Oby couldn't hand it on, or null, and `stops` how many times that happened on this head (each brings its own inbox item). Once the pull request has Cloud checks, a new head is `pending` until its own appear.
- `xcodeCloudError`: null, or `Couldn't refresh Xcode Cloud. Will try again shortly.` The last result stays, and the merge waits until a read succeeds.
- **A failed build or test** goes back to the author's agent by itself, once (`rounds` 1), as its next round in the same session and worktree: `running`, a new `round`, `step` `Working on Xcode Cloud`. What Xcode Cloud reported is vault-filtered and quoted as data, every line, in `.oby/inputs/xcode-cloud-<the head's first 12 characters>.md`. When the round ends, its commits publish by themselves, Oby reviews them (one more review is allowed for it, `extraReviews`), and Xcode Cloud runs on the new head.
- **A conflict** is rebased as one found at merge is (Mac check, “Conflicts with `dev`”, above): the runner fetches `dev`, and the author's agent rebases onto it, `step` `Rebasing onto dev`, never merging `dev` in. Its limits are the rebase's, the same `dev` twice or 6 rebases in a day; then `problem` is `Xcode Cloud says it conflicts with dev.` and why.
- `cloudNeedsYou`: Xcode Cloud still fails on the pull request's head, and Oby won't hand it back by itself: its fix round was used (`Xcode Cloud still fails after Oby's fix round. Take it from here.`), the round on this head brought nothing new or failed (`Xcode Cloud still fails, and the round on it brought nothing new. Take it from here.`), or `problem`. Only while the job isn't running, its pull request is open and it isn't dismissed. It counts in what needs you and brings a `failed` inbox item offering **One more round** (the author gets the failure again, past the limit; a conflict is fetched and rebased again, even onto the same `dev`), **Ask Oby** (the author's agent reads it again and explains what fails and what you could do, changing nothing) and **Dismiss**. While Oby reviews the pull request, One more round answers why it can't start yet, and the item stays open. Nothing reaches the inbox while Oby handles it.
- The pipeline adds a `cloud` stage, **Xcode Cloud**, before Merged: `Pending` (`current`), `Passed` (`done`) or `Failed` (`failed`, `reason` the problem or what failed). Only a result on the pull request's head completes it.
- **The merge waits** for Xcode Cloud to pass on the commit the Mac checked, whenever the pull request has its checks: the Merged stage says `Mac check passed · waiting for Xcode Cloud`, with no merge error or inbox item, and the merge goes on when the follower sees it pass. Right before merging, the runner reads that commit's checks again, as the GitHub app; a failed read (`xcodeCloudError`, until the follower reads it again) or a result that isn't `passed` keeps it waiting, with no merge error and none of the merge's tries used. A pull request without Xcode Cloud checks merges as before.

### Connection

An app or API the user connected (F17, #60), which agents use through Oby while the login stays in Oby, like a password manager filling the fields: no agent ever sees the secret (not in a prompt, its environment, a file, an argument, a log or a tool's result).

```json
{"name": "mail", "mcp": "https://mcp.example.com/mcp", "api": null, "secret": "mail-token", "header": "Authorization", "created": "2026-10-11T16:02:11Z", "secretSaved": true, "lastUsed": "2026-10-11T16:20:03Z"}
```

- `name`: up to 32 lower-case letters, digits or dashes. Agents see its tools as `<name>_<tool>`.
- `mcp`: a remote MCP server's URL (Streamable HTTP), or `api`: an API's base URL; exactly one of them. HTTPS, with no login, query or fragment in it; plain HTTP only on 127.0.0.1 or localhost.
- `secret`: the name of the vault secret it uses. The value enters the vault through `oby-runner vault add`; the API never takes or returns it. `secretSaved` says whether the vault has it now.
- `header`: where the secret goes: `Authorization` sends `Authorization: Bearer <secret>`; any other header sends it as is.
- The broker runs in the runner process outside every agent sandbox. Each job receives a job-only token for `POST /v1/agent/mcp/{job}` on 127.0.0.1; tokens are rejected for other or ended jobs. The agent sees only that token, in its MCP configuration.
- `tools/list` exposes connected tools as `<connection>_<tool>`; `tools/call` forwards read-only tools with the vault header. Acting tools are refused with `Acting as you needs your OK, which arrives with permission modes.` API paths stay on their connection host and redirects are not followed.
- Every result, including tool lists, is scrubbed of every vault value in plain, base64, hex and URL-encoded forms. Every call is recorded in the job report and vault use log by connection, tool, access, decision, secret name, host and date, never by value.
- Connections are changed only with the user's phone approval, and each job uses the snapshot it started with. OAuth, site logins, repository binding and user approval for writes are later slices.

### Inbox item

Something only the user can answer (docs/pipeline-cases.md, "Your inbox"). Like email, it waits for them with no timeout, and its job waits too; the others keep going.

```json
{"id": "ab12cd34-question-0", "kind": "question", "job": "ab12cd34", "title": "Nothing committed status",
 "text": "Should a job that commits nothing end as failed, or get a new status?", "options": ["Failed", "A new status"],
 "created": "2026-10-10T09:12:00Z", "done": null, "later": null, "answer": null, "state": "open",
 "headline": "Pick a status for empty jobs", "happened": "The job found nothing to commit. It needs to know how to end.",
 "recommended": 1, "why": "A new status keeps real failures apart."}
```

- `kind`, and what each offers in `options`:

  | `kind` | Comes when | `text` | `options` |
  |---|---|---|---|
  | `question` | the job's agent asked (`question` on the job) | the question | the agent's, possibly none |
  | `review` | Oby's review stopped asking for changes (`reviewNeedsYou`) | `Oby's review found a blocker it asked to fix before. Take it from here.` | `One more round`, `Dismiss` |
  | `failed` | the job ended `failed` or `interrupted` | the summary's first line | `Try again`, `Dismiss` (only `Dismiss` for a job that never started) |
  | `limit` | the job failed because its account hit its usage limit and no other had room | the summary's first line | `Try again`, `Dismiss` |
  | `merge` | Oby's merge stopped (`mergeNeedsYou`, Mac check below) | `mergeError`, or why the check failed and that a person takes it from here | `Try again` and `Dismiss` when it couldn't merge (merge again, or hand the check to the author again), when the Mac couldn't run the check, when the round brought no new commit, or after the last failed check (check the same commit again, as the same round); `One more round` first, then `Try again` and `Dismiss`, when the check named failing tests after Oby's last review (its reviews used up): the failing tests go to the author as its next round, and Oby may review the fix once more (`extraReviews`) |
  | `audit` | the runner's daily issue/board reconciliation (Issue sync, below): a Status column the roadmap lacks (title `Roadmap column <column>`), or a report that something failed (title `Daily issue audit`) | which column is missing and the issues that belong there; or the drift count and what failed | for a missing column, `Add the column` (recommended: `recommended` is 0), `Use <closest column> instead` (when the roadmap has one before it: `In review` for `Needs test`, `In progress` for `In review` or `Blocked`) and `Ignore this status`; for failures, `Try again` |
  | `failure` | a failure's post-mortem found an Oby bug, or a cause seen twice in 7 days, with no fix for it merged into `dev`, queued, running or in review (Failure record, below); one open per signature, aliases included | the cause, how often it was seen this week, and what happened | `Fix it`, `Dismiss` |
  | `start` | the brain didn't answer and rules guessed the plan (#269): one item per guessed job, `job` its id (the job isn't in `GET /v1/jobs` until it starts), `title` its heading | `Oby's brain didn't answer, so this plan is a guess. Start Fix oby #12 on Claude Code · Deskree?` | `Start` (recommended: `recommended` is 0), `Cancel`, each with what it does (`details`) |
  | `permission` | the job's agent waits for the user's OK (`permission` on the job) | the permission's `title` | `Allow`, `Always allow`, `Deny` (only `Allow` and `Deny` when it has no `rule`) |

  **Only decisions wait in the inbox (#215).** Every item offers at least one answer that changes something, besides done and later: a `question` takes the agent's options or the user's words, and every other kind declares its own (above). An item with nothing to decide arrives already `done`, with no `answer`: it's kept in `oby.sqlite` with the reports (the job's own report, or the audit's `outgoing`) and comes as an `inbox` event whose `state` is `done`, so it never shows in the inbox. That's the audit's report when it fixed the drift by itself, and a `failure` whose fix is already underway. A new kind declares its answers, or none of its items reach the inbox.

  More kinds will come (hands-on steps): show one you don't know with its `text` and `options`. A plan waiting for approval is a `question` item (its job's `question` has the `plan`).
- `details`: what each option does, one plain sentence each, in the same order as `options` (as Claude Code describes the options it asks with), shown under each button; null when there are none (older items, or a question whose agent gave none). Oby's own items always have them; a `question` has them when its agent wrote them (`question` on the job, above). Older runners don't send the key.
- `job`: the job's `id`, `runner-update` for the runner's own update, or empty for an audit item or a failure (it's about Oby, not one job). `title`: the job's title, "Daily issue audit", `Roadmap column <column>`, or `Oby failure: <signature>`. Optional `outgoing` on audits lists repairs using the same records as a job's report.
- `headline`, `happened`, `recommended`, `why`: the item in plain words, for a card. `headline` says what it's about in at most 8 plain words; `happened` what happened, in one or two short sentences with no ids or hashes; `recommended` the index into `options` of the answer Oby recommends, or null (when Oby or the job's agent recommends one already, like `Add the column`, it's set from the start and the model only says why); `why` one sentence saying why. The runner's brain model (Haiku, through the same `claude` as the brain, with no tool but reading the quoted item) writes them in the background, once per item and text: what the item says, its title and its options reach the model only as a quoted file, never in its prompt. The runner checks the lengths, the sentences, that there's no id or hash, and that `recommended` is one of `options`. The item arrives at once with all four null and they follow in an `inbox` event; when the model fails, is slow (20 s) or writes something the runner refuses, they stay null for good. `text` is always the full detail: show it when they're null, and under them otherwise. Older runners don't send these keys.
- `created`: when it came. Apps list the open ones longest-waiting first, with how long each has waited ("waiting 3m").
- `done`: when it was settled, or null. `answer`: what the user answered, or null (done without an answer, or settled by itself).
- `later`: put off until then, or null. `state`: `open`, `later` (put off until a time still to come) or `done`. Apps show a `later` item again once its time has passed.
- One open item per job: a newer item for the same job settles the older (done, with no `answer`), and audits share one per `title` (an empty `job`), so a newer report settles the older report, never a missing column's decision. Failures keep their own rule, one open per signature.
- An item comes once: each failure (even a retry that fails again within the same second), each question and each fourth review has its own `id`, and one that's done never comes back. It's done by itself, with no `answer`, when its job needs it no more: the job runs again (told something, or Try again from either app), was dismissed or stopped, or its question was answered with a message.
- Kept in `oby.sqlite` with the jobs, so a restart keeps the inbox, and the runner loads the job of every open item however old it is (and, for a `review` item, its review), so it can still be answered. A job's own alert (below) still says it needs you; the inbox is where you answer.

### Account

```json
{"id": "default", "agent": "claude", "name": "Personal", "label": "Max · well0cp@gmail.com",
 "signedIn": true, "fiveHour": 0.12, "sevenDay": 0.4,
 "fiveHourResets": "2026-10-10T02:14:40Z", "sevenDayResets": "2026-10-14T19:27:22Z", "running": 1, "fullUntil": null,
 "tetrix": true, "tetrixJobs": 12, "tetrixUsed": 9, "reserved": false, "reserveLiftedUntil": null}
```

- `label` is what the tool says about the login (null while signed out). Its first part is the plan (`Max`, `Team`, `Plus`), which Settings shows next to the account's name.
- `fiveHour` and `sevenDay` are 0…1 or null when unknown. An account with both null hasn't reported usage yet: Claude Code's limits arrive with its first job, Codex's when the runner asks its app-server.
- `fiveHourResets` and `sevenDayResets`: when each window resets, or null when the tool didn't say. Claude Code sends them in its `rate_limit_event` (`resetsAt` per window), Codex in `account/rateLimits/read` and its `account/rateLimits/updated` notifications (`resetsAt`). A window keeps its last reset time until the tool sends a new one. Older runners don't send these keys.
- `running`: jobs queued or running on the account.
- `fullUntil` is set while a job of the account's hit its usage limit: no job goes to it before then. Accounts are signed in on the runner itself, through each tool's own login; the app only shows them.
- `tetrix`: whether the account's agents have Tetrix's MCP server connected, or null before the runner knows. The runner asks on startup (Claude Code: `claude mcp list`, with claude.ai's connectors off as for agents; Codex: its app-server's `mcpServerStatus/list`), and every job's tool says it again as its session starts. `tetrixJobs`: of the account's recent jobs (the latest 50 the runner keeps in memory) that ended and whose tool said what it had, how many there are; `tetrixUsed`: how many of them called Tetrix. Settings shows `Tetrix: connected · used in 9 of 12 recent jobs (75%)`, or `Tetrix: not connected: sign in` (signing in is the tool's own login for its `tetrix` server, on the runner; never Oby holding the token). Older runners don't send these keys.
- `reserved`: the account is at 80% of its week before `sevenDayResets`, so it gets only jobs sent to it by name (and reviews, last: Routing below). False while its reserve is lifted. `reserveLiftedUntil`: until when the user let it past its reserve (`POST /v1/accounts/{id}/reserve`), its week's reset; null when they didn't, or once that time has passed. Older runners don't send these keys.

Accounts are signed in on the runner itself, through each tool's own login; the app only shows them. Settings shows one card per account, grouped by tool, with a bar per window, its reset time, and the running count.

**Routing.** Oby budgets each subscription by its weekly pace, not just the 5-hour window: new work goes to accounts on pace, accounts running ahead of pace get reviews or nothing, and the account with the most weekly room per remaining day wins. Every automatic choice goes through it (the brain's dispatch, the Lead's picks, failure fixes, failover, reviews); a job named to an account skips it.

- An account gets nothing while it's signed out, marked `fullUntil`, at 95% of either window, or at 80% of its week (`reserved`: kept for jobs sent to it by name until `sevenDayResets`; a review may take it, last). Above 80% of its 5-hour window it gets work only when every account is.
- **Use anyway:** the user can lift an account's reserve until its week resets (`POST /v1/accounts/{id}/reserve`): it then takes new work, failovers, the Lead's picks and moves like any account, still never at 95% of a window or while marked full. When only reserves keep a request from starting, its job still starts, waiting for room (`startWhen` `[{"room": true}]`, on the first of those accounts until then), and the reply says so: `On it. Claude Code will fix oby on Personal once what it waits for has happened. Waiting: Personal and Codex are in their weekly reserve. Use one anyway to start it now; otherwise it starts when an account has room.` Queued, the job's `waiting.reserved` names those accounts, and the Mac's and the iPhone's job screens show `Use Personal anyway (82% of week)` for each one still under 95% of both windows, with `Oby keeps 20% of each week in reserve; this lifts it for Personal until Thu 7:00 PM.` under it: one tap lifts that reserve and the job starts there. A failover with nowhere to go, and the Lead's jobs that found no account, say `Personal and Codex are in their weekly reserve: use one anyway from Settings › Accounts.` Settings shows `Use past reserve this week` on an account in its reserve, with `Oby keeps 20% of each week in reserve; this lifts it for Personal until Thu 7:00 PM.`
- **Room per remaining day:** `(1 − sevenDay) / daysLeft`, `daysLeft` from `sevenDayResets` (at least 0.25; 7 when null). Higher is better.
- **Ahead of pace:** `sevenDay / max(weekGone, 1/7) > 1`, the share used over the share of the week gone: at this burn it runs out before its reset. The floor keeps the first hours of a week from swinging it.
- **New work** takes an account on pace first, then one whose `sevenDay` is null (unknown, not 0%: Claude Code reports usage only during a job), then one ahead of pace. **A review** takes one ahead of pace first, then on pace, then unknown; the other tool still comes first.
- Within those, the most room per day; within 0.01/day of it, the fewest `running`, then list order.
- The job's report says why, once (a review's, whose last line is its verdict, in the runner's log): `On Claude Code · Deskree: most weekly room per day left (0.12/day), though 1.4× ahead of pace: none is on pace; Codex · Deskree is 2.3× ahead of pace.` After failover, the handoff says it: `Codex · Deskree hit its limit; continued on Claude Code · Default: its usage isn't known yet.`

### No Dispatch card (#269)

There's no draft to confirm any more: the work the brain plans starts as it's planned, like the Lead's, and `POST /v1/plans` answers the jobs it started. Everything the card let you change before the start changes after it: the account, tool or model (`POST /v1/jobs/{id}/move`), the mode (`POST /v1/jobs/{id}/mode`), what it waits for (`POST /v1/jobs/{id}/start-when`), a message to the agent, Stop. The outgoing gates don't move: checks, the secret scan and Oby's review still gate every push and merge. A plan rules guessed (the brain didn't answer) is the one thing that still asks: a `start` inbox item (Inbox, below), and nothing starts until its `Start`.

## Endpoints

### `GET /v1/status`

```json
{"runner": {"version": "0.2.0", "host": "tetrix-lab"},
 "accounts": [ …Account ],
 "models": {"claude": {"model": "claude-opus-5-5", "effort": "xhigh", "complexEffort": "xhigh"}, "codex": {"model": "gpt-6-sol", "effort": "high", "complexEffort": "high"}},
 "maxRunning": 6, "running": 4,
 "clearedAt": "2026-10-10T08:12:00Z",
 "github": "app", "checks": "ok", "permissions": {"mode": "bypass"},
 "cleanup": {"path": "/srv/nvme/oby/jobs", "bytes": 8912896, "lastRun": "2026-10-13T08:00:00Z"}}
```

`permissions.mode` is Settings › Permissions: the mode new jobs get (`PUT /v1/settings/permissions`). Older runners don't send the key.

`cleanup` is the runner's job-worktree disk usage and cleanup status. `path` is the worktree folder, `bytes` is its allocated disk usage, and `lastRun` is when the last cleanup pass completed, or null before the first pass. The runner runs cleanup at startup and every three hours. It removes a worktree only for a settled job finished more than 24 hours ago (merged, closed, dismissed or stopped), or immediately after an Oby review job has a verdict; open pull requests, jobs needing the user, queued or waiting jobs, and worktrees in use by an agent, check, publish or merge are kept. Older runners don't send the key.

`runner.version` is the running API version. `runner.update` adds `{"commit": "<dev SHA>", "waiting": "<candidate SHA>", "phase": "draining"}` for Settings › Runner. `commit` is the running executable's dev commit, or null before its first self-install or after an untracked manual install. `waiting` is null when no update is pending. `phase` is `idle`, `building`, `ready` (built and tested, waiting for its turn to restart), `draining`, `restarting` or `failed`. Clients of older runners accept an absent `update`; refresh status to observe progress.

The runner checks `dev` every three minutes, using its own checkout in `OBY_HOME/updates/source`, outside agent sandboxes. It pins the fetched commit, runs `swift build -c release` then `swift test` (with a throwaway `OBY_HOME`, also as `TEST_RUNNER_OBY_HOME`, like a Mac check, so the tests never open the runner's own data), and drains only after both pass. Drain pauses new jobs, reviews and follow-up rounds while current rounds finish, for at most 30 minutes; a job waiting for the user's answer or OK doesn't hold it up. The drain covers the end of a turn too (#212): the runner restarts only between the steps that follow an agent's last turn, never inside one: counting a job's commits and publishing it, a review's verdict reaching its author (the verdict recorded, the `Oby review` check run posted, then the author's round started or the approval's Mac check queued), and posting a Mac check's results and merging. Past the 30 minutes it still waits for the step under way to end. Updates are batched: when `dev` moves while a tested commit waits (for its turn or for the drain), the newer commit is built and tested and replaces it, and the drain carries on meanwhile, so two merges in quick succession make one restart; if the newer commit fails, the one it was to replace still installs. The runner restarts for an update at most once every 15 minutes (`ready` until then, with no agent held back), unless the update brings the fix of one of Oby's own failures: a fix of an `oby-bug` failure of the last 7 days that merged into `dev` since the last update's restart installs at once. The tested executable is kept as `OBY_HOME/updates/candidate`; it atomically replaces the installed binary, then the runner exits with code 75 so the systemd user service (`Restart=on-failure`) restarts it. Its journal is `OBY_HOME/updates/state.json`, with when the last update restarted the runner.

After the restart, its jobs carry on like after any other restart ("After any restart", below). If `swift test` fails naming tests, the runner waits until the 1-minute load is below the machine's thread count, for up to 10 minutes, then reruns only those tests once with `swift test --filter`. If they pass, the update is tested and may install; Oby records a `flaky-test` failure with the test names and messages for its failure study, and adds no inbox item. If tests still fail, the old binary stays and one durable inbox item (`kind: failed`, `job: runner-update`, `options` `Try again`) names the failing tests and their messages. A failed build or install, or a test failure that cannot be identified by name, is reported immediately; compiler errors include their diagnostic lines. That commit is not retried on later polls or restarts, only by its Try again (#215); the next dev commit is tried. Each try that fails is its own item (`runner-update-<commit>`, then `…-try-2`, `…-try-3`), so a retry that fails again offers Try again again; while one is open, the same commit adds no other. A commit whose build or tests a restart cut short is tried again. A fetch failure adds one item per outage, however many polls or restarts it lasts; once a fetch succeeds, the next outage adds another. No unrelated build output or credentials enter the inbox.

**After any restart.** Whatever restarted the runner (a crash, a reboot, `systemctl restart`, a manual deploy or its own update), every job that was `queued` or `running` when it went down carries on once it's back, after its first refresh of the accounts: stopping the runner leaves them on disk as they were, not `interrupted`. A job with a session picks it up again in its own worktree, keeping its round. Its agent first hears `Oby's runner restarted while you were working…`, then the message it was about to get, if any: the next round's message, the user's words or answer, Oby's review hand-off or a failed Mac check's hand-off. That message is saved in `OBY_HOME/restarts.json` the moment Oby hands it over (while draining for an update too), and kept until the agent's turn ends, so a turn the restart cut short hears it again; the notice never replaces it. A queued job starts when its worktree is ready, when there's a free slot, oldest first; one whose worktree was set up before the restart is brought up to date with its base first, as a job that waited is. A job waiting on a question keeps waiting, `running` with its question and no agent, until its answer picks the session up. A job waiting on a permission is `interrupted`, keeping it: its answer picks the session up, telling the agent what it asked and the answer. One stays `interrupted`: a job picked up twice in the last 30 minutes, when the runner keeps going down with it (the runner's own update restarts don't count: it notes them in `restarts.json` before it exits): its summary starts `Oby's runner restarted 3 times in 30 minutes while this ran…`, and it gets one `failed` inbox item with `Try again`. Telling it something picks its session up with the message it was about to get, then the user's words. A job the user stopped stays `stopped`. Quitting Oby on the Mac still leaves its jobs `interrupted`.

End-of-turn work a restart cut short carries on too (a crash or `systemctl restart` can stop the runner anywhere; its own update waits for it). A review that ended while its author still shows it `reviewing` has its verdict applied now, as when it ends. A verdict on the author whose check run and hand-off didn't happen (the author's `review` is saved with `applying: true` until both are done) gets them now: the `Oby review` check run is posted (possibly a second time, if the restart came just after GitHub took it: never lost), then changes requested start the author's round with the quoted review, or an approval queues its Mac check. A restart after the round's message was saved but before the round was finds the review still `applying`: the round starts once, with that message. A merge whose check passed is finished on the first refresh ("Mac check", above), and a job that was publishing is still `running`, so it carries on and publishes when its agent ends.

`maxRunning` is how many jobs run at once (#237; Job, above), and `running` how many slots are taken now: jobs whose agent is running, reviews and rounds included, and waiting jobs on their way to a slot. Older runners don't send them.

`clearedAt` is when Clear done was last pressed, on any app (`POST /v1/clear`), or null when it never was. Every app hides the settled jobs that finished at that second or before (`finished` not after `clearedAt`): dismissed or stopped, with their pull request merged or closed, or ended with nothing to publish (`JobList.settled`, Shared/JobList.swift). Jobs still queued, running or waiting, needing the user, with their pull request open, or reviewing one that isn't settled stay, and so do finished ones that ran again since. Older runners don't send the key.

`github` is who the runner's own GitHub calls act as: `app` when the GitHub app is set up (`OBY_GITHUB_APP_ID` and its key, Runner/README.md) and its latest request for a token worked, `owner` otherwise (the owner's `gh` login, as before). Older runners don't send the key. Who does what:

- **As the app** (`oby-by-deskree[bot]` on GitHub), with an installation token in `GH_TOKEN` for that one call: reading pull requests, checks, issues, sub-issues and the board (the Lead, issue sync and its daily audit, a job's quoted issue and pull request, following published pull requests, Publish's lookup of the branch's open pull request), writing Oby's reviews and Mac check results as check runs, merging into `dev`, and the failure records. The token is the installation's for the account the call names (`-R owner/repo`, `--owner`, a `repos/…` path; a call that names none, like a GraphQL query by node ID, uses the app's only installation), minted with a JWT signed by the app's key and kept until five minutes before it expires. A call GitHub refuses with `401` gets a fresh token and runs once more.
- **As the owner** (their `gh` login): pushing branches, opening and editing pull requests, cloning, `gh api user` and `user/…` (the owner's name and email for agents' commits, the repositories the brain may pick), and anything that names `@me` (the owner's own projects). The calls above too, when there's no app, its key is missing or refused, or it isn't installed for that account.
- **Agents** get neither: `GH_TOKEN`, `GITHUB_TOKEN`, `OBY_GITHUB_APP_ID` and `OBY_GITHUB_APP_KEY` are taken out of their environment, and their gh has no login.

`checks` says whether Oby's review and Mac check go on pull requests as check runs (#198): `ok` when the app's installations have **Checks: Read and write** (read from GitHub at start) or the last check run went through, `missing permission` when they don't or GitHub refused the last one for it (the owner grants it on the installation, where GitHub shows the app's request; the next check run goes through by itself), `no app` when the runner's calls go as the owner, who can't write check runs. Until it's `ok`, reviews and Mac check results stay in Oby, and nothing goes on the pull request. Older runners don't send the key.

### `POST /v1/clear`

Clear done, on the iPhone or the Mac: the runner records now, on its own clock, as the last clear, and answers it. It keeps every job; only the apps' lists change, and the same way on each, so clearing on one clears on both. No body.

```json
{"clearedAt": "2026-10-10T08:12:00Z"}
```

Every app following `GET /v1/events` gets a `clear` event with the same body, and `GET /v1/status` says the time from then on. The clock never goes back: a clear earlier than the last one keeps the later time.

### `POST /v1/plans`

One turn of the conversation with Oby: words become work that starts, a question, or an answer in words. Takes 3–20 seconds (the brain thinks); show Oby thinking, with a way to cancel, and let a new message replace the one under way. Cancelling only drops the answer: work the plan started goes on, and Stop ends it.

```json
{"said": "Review oby PR #33"}
```

To answer the brain's question, send the original words with the answer:

```json
{"said": "Review PR 12", "answer": {"question": "Which repository is PR #12 in?", "option": "deskree-inc/oby"}}
```

**The brain answers with context.** Before the user's words it reads a briefing the runner builds: the conversation so far, the jobs (running, needing the user, in review, finished or merged in the last two days, with their titles and stages), the inbox, each account's usage, and the week's failure records (below: counts by cause, the rounds the failed jobs used, and each record's trigger, cause, signature, issue and fix job; what the post-mortem wrote is in the quoted file). So it answers "why did jobs fail this week?", questions about the work ("how are the jobs going?", "what did the #12 job change?", "how long until Codex resets?") as a `reply`, and reads follow-ups ("and the vault one?", "cancel it"). The briefing holds only what the user and Oby said and what the runner knows; what agents wrote (a job's result and current step, an inbox question and its options, a failure's reason), and an inbox item's `headline`, `happened` and recommendation, which a model wrote from those words, reach the brain as a quoted file it may read, never in a prompt, as every other outside text does. The typed plan is still checked in Swift. A plan acts once it's made: the runner can't tell a client that gave up waiting from a slow one, so an app that lets the user cancel a turn only drops the answer, and a stop the turn asked for still happens.

Bare cancel words ("never mind", "stop", "cancel", "forget it") never reach the brain. When a conversation turn is underway they request a boundary stop; otherwise the answer is `none` and nothing stops. Stopping coding work still takes a job's name or "stop everything".

The conversation so far is the runner's own, the last 50 of the turns it keeps (`GET /v1/conversation`, below). An app that shows its own thread sends it instead, oldest first; `who` is `user` or `oby`, `text` 1 to 2,000 characters, at most 50 turns (`422` otherwise). Either way the new exchange joins the runner's conversation.

While a turn carries out actions, `GET /v1/events` sends a `step` event when each action starts and when it ends. Its `turn` is the user's turn id, `index` starts at 1, `action` is the plan action, `text` is a short description, `state` is `running`, `done` or `failed`, and `at` is ISO 8601 time:

```json
{"turn":"8d…","index":1,"action":"move_job","text":"Moving Vault secrets to Codex · Deskree","state":"running","at":"2026-10-12T12:00:00Z"}
```

`POST /v1/conversation/stop` asks the turn underway to stop after its current action. The in-flight `POST /v1/plans` then returns a reply describing what it completed. The cancel words `stop` and `never mind` have the same effect. The turn budget is 110 seconds; clients should wait 120 seconds while following its step events.

```json
{"said": "and the vault one?",
 "turns": [{"who": "user", "text": "how is the inbox job going?"},
           {"who": "oby", "text": "Inbox on the Mac is at its check, round 2 of 4, running swift test."}]}
```

The answer is one of:

```json
{"kind": "reply", "text": "On it. Claude Code is reviewing oby PR #33 on Deskree.", "jobs": [ …Job, status "queued" ], "drafts": []}
{"kind": "question", "said": "Review PR 12", "question": {"text": "Which repository is PR #12 in?", "options": ["deskree-inc/oby", "deskree-inc/blok"], "recommended": 0, "plan": null}, "jobs": [], "drafts": []}
{"kind": "reply", "text": "Oby can't merge pull requests.", "jobs": [], "drafts": []}
{"kind": "none", "jobs": [], "drafts": []}
```

**Planned work starts at once (#269).** A plan that dispatches work starts its jobs right there, as the Lead does: each routed to an account (Routing, under Account; a job that names an account or waits on one runs there), its issue's files claimed, its `startWhen` set, nothing to confirm. The reply says what started, in Oby's voice (`"On it. Claude Code is fixing oby #12 (Login screen) on Deskree."`; a job that waits says so), and `jobs` holds the started jobs in full, the same `Job` as `GET /v1/jobs/{id}`, in the plan's order: show each as a job card under Oby's words, with Stop. They come as `job` events too. `jobs` is always a list, empty on a question, on a reply that started nothing and on `none`. `drafts` is always empty, for clients from before: a `plan` with no drafts.

When the brain didn't answer and rules guessed the plan (`by` is `rules` in the runner's log), nothing starts: the reply says it's a guess, and each guessed job waits as a `start` inbox item (`Start Fix oby #12 on Claude Code · Deskree?`, with `Start` recommended and `Cancel`), which the thread shows as a decision card. `Start` queues the job as planned and adds an Oby turn with its card; `Cancel`, `done` or `later` start nothing. A plan whose repository is unclear is still a `question`.

Words that ask to stop work stop jobs right away, with nothing to confirm, and answer once they have, with a reply saying what stopped. "Stop everything" or "stop all jobs" stops every queued and running job: `"Stopped 2 jobs."`, or `"Nothing is running."`. "Cancel it" or "stop the vault job" stops the job the conversation is about, by its id from the briefing: `"Stopped Vault secrets."`, or `"That job isn't running any more."`. The brain's plan says which (the jobs by id, or everything in so many words), and Swift refuses a stop that says neither; a stop that names no job while several run is answered with a question (which one, or everything?) or `"Say which job to stop, or “stop everything”."`. (On the Mac, whose brain also sees the runner's jobs, inbox and accounts, both reach the runner's jobs through `POST /v1/jobs/{id}/stop`, and a job the runner couldn't stop is said so: `"Couldn't stop Watch home: …"`.)

The brain's `question` has at most 3 options and `recommended` (the index of the one it recommends, shown first, or null), like a job's; the user may also answer in words of their own.

Words about permissions act right away too, checked in Swift like a stop, and answer with a reply saying what happened (never the command itself). "Allow it", "always allow that" and "no, run only the runner tests" answer the permission waiting on the job the conversation is about (allow, always, or deny with the user's words for the agent): `"Allowed it for Vault secrets."`, `"Allowed it for Vault secrets, and saved the rule for oby: it won't ask again for that."`, `"Told Vault secrets no, with your words."`. On a job whose plan waits, a yes approves it in Accept edits and a no sends it back with the words. "Stop asking on the Watch job" (`bypass`), "ask me before anything" (`ask`), "let it edit but ask before commands" (`acceptEdits`) and "plan first for the vault job" (`plan`) change a running job's mode, as `POST /v1/jobs/{id}/mode` does: `"Watch home is in Bypass mode now."`. New work said with "plan first" starts with that mode on the job it plans. The brain names the job by its id from the briefing, and Swift refuses a plan that names a job that isn't running or waiting for the user's OK. On the Mac, the runner's jobs are answered the same way: the app passes a permission's answer on to `POST /v1/jobs/{id}/permission`, a plan's to `POST /v1/jobs/{id}/messages` (`Approve: Accept edits`, or the user's words), and a mode to `POST /v1/jobs/{id}/mode`.

Words that ask to move a job ("move the vault job to Claude", "use Fable for that one", "put the Watch job on Codex") move it right away too, as `POST /v1/jobs/{id}/move` would, and answer with a reply: `"Moved Vault secrets from Codex · Deskree to Claude Code · Personal. It goes on there now."`, or `"Couldn't move it: …"` with why. The brain names the job by its id from the briefing (its title, its issue or pull request, or "that one" in the conversation) and where it goes (a tool, an account by name, a model), and Swift checks both before anything moves: the job must be one the briefing listed, the account one it knows, and the model one of that tool's. (On the Mac, a runner's job moves through the runner's `POST /v1/jobs/{id}/move`.)

**One request, several steps, like Claude Code.** A turn can take up to 6 actions. The brain picks one action. When it changes something (a stop, a move, a permission answer, a mode), Oby does it, then asks the brain again. The brain gets the user's words, what Oby did so far this turn, and a fresh briefing, and it plans the next action until the request is done. For example, "Deskree's limit is full, move its jobs to Personal and Codex" is a move of some of Deskree's jobs to Personal, then a move of the rest to Codex. The turn ends:

- on an answer (a reply, a question, or jobs it started);
- on an action the brain already took this turn, or one that couldn't happen (with why);
- on a later step only Oby's keyword rules could plan;
- or after 110 seconds (`Desk.turnBudget`, under the apps' 120-second wait). Then the reply ends with "say “continue” for the rest".

The reply lists everything that happened, in order: `"Moved Vault secrets from Claude Code · Deskree to Claude Code · Personal. It goes on there now. Moved Watch home from Claude Code · Deskree to Codex · Deskree. It starts again there."` One move may name up to 10 jobs going to the same place. A job that had failed or was interrupted (an account's limit, a restart) starts again where it went ("It starts again there"). The briefing names each job's account (`… · Claude Code · Deskree · running on tetrix-lab …`), so "its jobs" and "everything on Deskree" resolve.

One message can start up to 10 jobs ("work on oby #12, #15 and #18", or "work on epic #30", which becomes one job per open sub-issue), each routed knowing where the ones before it went, so they spread out.

#### The Lead: vague goals

A vague goal, like "work on the roadmap", "Obi, next issue", "pick the next open issues" or anything naming the roadmap, the board or the backlog, goes to the Lead instead of the brain (when a Claude account is signed in). Words that stop work ("stop working on the roadmap") stay with the brain, which stops the jobs. The Lead is a fresh Claude Code turn on Sonnet 5.5 (the model the spike proved), with only Read, Grep and Glob, boxed like a job. It takes 6 to 20 seconds. Before each turn the runner:

- reads the GitHub project **Oby — Roadmap** with its own `gh` login: the open issues in board order, each with its status column, labels, milestone, assignees and the open pull requests that close it;
- builds the **skipped list** itself, never trusting the Lead's: done, in review, `status:needs-test`, blocked, `oby:skip`, assigned to someone else, a queued or running Oby job on it, or an open pull request (the board's, or one Oby published for it);
- writes `.oby/context/roadmap.md` (the board with the runner's verdict on every row, workable or why it's skipped) and `.oby/context/jobs.md` (the runner's running and recent jobs, with the files each expects to touch) where the Lead reads them.

The Lead answers one typed plan, checked in Swift and retried once with the reasons: `start_jobs` (one brief per job: repository, issue, kind, title, goal, the files it will touch, a one-line check and what's out of scope), `reply`, or `ask_user`. No push, merge, approve or publish action exists. A brief is refused unless its issue is one the board lists as workable: a skipped issue is refused with its reason, and a closed, made-up or off-board issue is refused too (Oby would claim it on GitHub). So the same request twice starts nothing new.

The jobs start right away, with no Dispatch tap, each routed to the signed-in account with the most room (the picks spread out, as a plan's drafts do), with 4 rounds (one attempt and three fix rounds) and the brief's check. Right before each job starts, the runner checks the live jobs again: an issue that got a queued or running job while the turn ran (the same request from the Mac and the iPhone at once, or repeated after the app gave up waiting) starts nothing new, and the reply says so. The answer is a `reply`: `"Started 2 jobs: Safe when nobody watches (#7), Watch first slice (#12). Skipped 8 on the board."`, and the jobs arrive as `job` events and in `GET /v1/jobs` with `files`, `lead` and, once each starts, `claim`. When nothing can start, the reply says why (every issue skipped or taken, the board unreadable, no account with room, or the Lead's plans refused twice). A `question` is answered as the brain's is. The runner keeps the last 20 goals' context folders.

All issue jobs use `Engine/IssueSync.swift` on the runner and in the Mac app, with Oby's own `gh` login. Issue sync never comments on an issue or assigns it: the app's comments and assignments email the owner, and the labels, the board and Oby's inbox already say it (#162). Starting adds `status:in-progress`, writes a hidden claim line (`<!-- oby-claim: job <id> -->`, one at the end of the issue's body, replacing any earlier one) and moves its existing roadmap item to **In progress**. An opened PR adds `status:in-review`; GitHub links it to the issue through its `Closes #N` (an issue with a checklist gets `Part of #N`, below). Waiting for an answer, a failed publish or the review cap adds `status:blocked`. A merged PR ticks issue checklist tasks explicitly checked in the PR description by exact text or a unique bold heading. Unfinished tasks in `## Build`, or another active slice, keep `status:in-progress`; otherwise the issue gets `status:needs-test`. Ending another slice preserves this handoff. Real-device testing remains a user handoff. PR descriptions say `Closes #N` so GitHub links the PR to its issue, or `Part of #N` for an issue with a checklist, which one slice must never close; the Lead reads `closingIssuesReferences` and the `(#N)` that ends Oby's PR titles.

An unlinked job is linked only when a standalone `Part of #N` line, an exact brain title (or its `(#N)` suffix), or an `oby/<kind>-N` branch identifies one open issue; incidental issue references and ambiguous jobs stay unlinked. Lifecycle hooks are serialized, and a transition repeats only what isn't on GitHub yet. Every claim, label, checklist and project mutation passes the existing secret scan first and is listed in the job's report. Failure stops that transition and is reported in `claim`. A failed transition backs off per job (1 minute, doubling, at most an hour, kept in `issue-audit.json` across restarts) and stops after 4 tries until the job's state changes; agent steps in between send nothing. Only the Desk whose job the issue's claim line names (or, on an issue claimed before #162 that has no claim line, its latest `Oby is working on …` comment, read only) removes `status:in-progress` or `status:blocked`: a Desk can't see another's jobs (the runner can't see the Mac's), so it leaves those labels alone otherwise.

The runner checks hourly whether the UTC day's audit has run, using a separate persisted ledger (`issue-audit.json`). It resolves `Oby — Roadmap` by title and owner as the Lead does, reads its fields and paginated items once, and audits only open issues already on that project that it has jobs for; issues it has no job for are left alone. It posts no comments. It fixes labels and board columns, removes unsupported running/review/blocked labels, and preserves merged slices' remaining Build work or device-test handoff. Board updates never add items, set Todo, or move Done/Shipped/Closed items. A desired status with no Status option on the roadmap leaves the column alone and is a decision for the owner (#215): one `audit` item per missing column, titled `Roadmap column <column>`, naming the issues that belong there, offering `Add the column` (recommended), `Use <closest column> instead` (when the roadmap has one) and `Ignore this status`, each with what it does (`details`). The answer is remembered for that status in `issue-audit.json` and applies to issue sync and the audit from then on; while it waits, or is put off, the audit doesn't ask again, and once nothing needs that column any more (it was added, or no issue belongs there) the item is done by itself. A report appears only for drift or errors, with a one-line report, an empty `job` and optional `outgoing` records of its repairs: already `done` when nothing failed (the runner fixed the drift itself, which needs nobody), otherwise waiting with `Try again`. Repairs for existing jobs also appear in those jobs' reports; no audit jobs enter history. Limited issue/PR results refuse cleanup instead of assuming unseen work is absent. Missing project scopes from `gh project` (gh prints the scopes line before its refresh hint; any line counts) report exactly: `Runner gh login lacks read:project or project scope; run gh auth refresh -s read:project,project on the runner`. The Lead reports the same fix rather than claiming the project does not exist; repository permission failures retain their actual cause.

Every Lead turn is logged on the runner (the words, the plan or why it was refused, the skipped list, the jobs started) and kept in `oby.sqlite` with the brain's turns.

### `GET /v1/conversation?before=&limit=`

One thread for every device (#11): the conversation the runner keeps, which every `POST /v1/plans` joins, whichever app sent it. The runner keeps the last 500 turns in `oby.sqlite`, the oldest pruned; the brain reads the last 50 of them. Answers one page, oldest first:

```json
[{"id": "7c1e2f30-…", "who": "user", "text": "Review oby PR #33", "at": "2026-10-11T09:12:00Z", "jobs": []},
 {"id": "9a4b5c60-…", "who": "oby", "text": "Oby will review PR #33 in oby.", "at": "2026-10-11T09:12:04Z", "jobs": ["9f08fd10"]}]
```

- `who` is `user` or `oby`. `at` is when it was said. `jobs` is always a list: the jobs the turn started, by id, for a card under Oby's words, with Stop. Oby's reply to a plan carries the jobs it started (#269), as the Lead's does; `Start` on a guessed plan's inbox item adds an Oby turn carrying that job. Fetch one that isn't in `GET /v1/jobs` with `GET /v1/jobs/{id}`.
- `limit`: how many, 50 unless asked, 1 to 500. `before`: the `id` of the oldest turn you show, for the turns before it; leave it out for the latest. Fewer than `limit` turns means there are no older ones. `404` for an id that isn't in the thread (a turn pruned since).
- A `turn` event (`GET /v1/events`, below) comes with every turn added, and again for a turn that changed (its `jobs`): replace the turn with that `id`, or add it in `at` order.

### `POST /v1/jobs`

Starts a job described whole, for clients that know the work already (oby-mcp, scripts); what the user says starts through `POST /v1/plans`. The body is the job as the brain would have planned it:

```json
{"job": {"repo": "deskree-inc/oby", "kind": "fix", "task": "Fix the login screen's empty state (#12).", "issue": 12,
         "title": "Login screen empty state", "account": "Deskree", "rounds": 4, "check": "swift test",
         "files": ["iOS/Home.swift"], "startWhen": [{"pr": 205, "is": "merged"}]}}
```

- `repo` (a known repository), `kind` (`review`, `fix`, `build`, `test` or `investigate`) and `task` (1 to 2,000 characters) are required.
- `pr` or `issue` says what it's about; both only for an issue's work started from a pull request's head (a `fix`, `build` or `test`). `title` is 1 to 60 characters, one line.
- `account`: an account by id or name, or `auto` (or left out) for routing (Routing, under Account); `agent` (`claude` or `codex`) keeps routing to one tool. The job runs on the account named, or on the one its `startWhen` waits on.
- `branch` (a name git accepts; left out, Oby names one, like `oby/fix-12`), `base` (left out, the repository's default branch), `rounds` (1 to 10; 1 unless given), `check` (one line of up to 200 characters), `model` (a model of the job's tool, like `claude-fable-5-1`; left out, Settings › Models), `files` (up to 30 paths inside the repository; `[]` claims none; left out, the issue's), `startWhen` (Start when, above; left out or `[]`, it starts at once), `request` (the user's own words; left out, the task), `mode` (`ask`, `acceptEdits`, `plan` or `bypass`, Permission modes below; left out, Settings › Permissions' default; anything else is `422`). A job the brain plans gets the mode the user named ("plan first") the same way, else the default.

Returns the queued `Job` (`201`), routed and claimed as a planned one, as a `job` event too. `422` with why when something's wrong: an unknown repository or kind, an empty task, an account that isn't signed in, a path outside the repository, a model the tool doesn't have, or `startWhen` that can't be (Start when). `410 Gone` for a body from before #269, a plan's draft (`id` with no `repo`, `kind` and `task`): `Oby starts planned work by itself now`.

### `GET /v1/jobs?limit=50`

The latest jobs, newest first.

### `GET /v1/jobs/{id}`

One job, however old: fetch it when an inbox item or a notification names a job that isn't in `GET /v1/jobs`'s latest 50. Every job's routes (`/dismiss`, `/messages`, `/stop`, `/move`, `/publish`, `/wait`) work on any job the runner ever had, after any number of restarts; `404` means it never had it. An app that gets `404` for a job it holds drops the job from its lists (the Mac does) instead of keeping it under Needs you.

On startup the runner keeps the latest 50 jobs in memory, plus every job that still needs something however old: queued, running or interrupted, needing you or waiting for your answer, or published with a pull request that isn't merged or closed, whose reviews, checks and merge it goes on following. Not once dismissed.

### `GET /v1/jobs/{id}/wait`

Answers once the job has ended (`done`, `failed`, `stopped` or `interrupted`) with the `Job`, or right away if it already has. Until then it sends a space every 15 seconds to keep the connection open, so the body is the job's JSON after some whitespace. `404` for a job the runner doesn't know.

The iPhone app waits on this as a background download: iOS keeps it going while the app is suspended and wakes the app when it's answered, so the Live Activity can say how the job ended even on a runner without push (`POST /v1/activities`).

### `POST /v1/jobs/{id}/stop`

Stops a queued or running job. Returns the job (`status: "stopped"`).

### `POST /v1/stop-all`

Stop all (⌃⌥⌘. or the menu on the Mac, Stop all on the iPhone): every queued and running job stops at once, as `POST /v1/jobs/{id}/stop` does for one. Each agent is asked to stop and ended within 2 seconds, with everything it started; a job that was publishing sends nothing more. No body. Answers with how many it stopped and those jobs, now `stopped`:

```json
{"stopped": 2, "jobs": [{"id": "9f08fd10", "status": "stopped", …}, …]}
```

With nothing running: `{"stopped": 0, "jobs": []}`.

### `POST /v1/jobs/{id}/dismiss`

Lets go of a job that needs you (`done` with commits it couldn't publish, `failed` or `interrupted`): it stays as it ended, in the list and in history, and needs nothing. Its alert clears (the runner sends the clearing push below), Home stops counting it, and Publish isn't offered. Returns the job with `dismissed` set. A job dismissed already comes back as it is. No device signature: nothing goes out.

`404` for an unknown job. `409` when the job doesn't need you (running, stopped, done and published, or done with nothing to publish).

### `POST /v1/jobs/{id}/move`

Moves a job to another tool, account or model:

```json
{"agent": "claude", "account": "Personal", "model": "claude-fable-5-1", "why": "Codex keeps looping"}
```

Every key may be left out (or null), but not all of the first three. `agent` is `claude` or `codex`; `account` is an account's `id` or its `name`; `model` is a model's id (Claude Code's from Settings › Models, Codex's from `GET /v1/settings/models/options`), or `default` to drop the job's own model and run the tool's from Settings › Models; `why` is the user's reason, up to 500 characters, which the agent taking over hears. What's left out follows from the rest: a model names its tool (`claude-…` is Claude Code's, any other Codex's), an account its tool too; with no account named, the job keeps its own when the tool stays, else goes to the tool's account Routing picks (under Account), among those signed in and under 80% of both their 5-hour and their weekly window. An account named takes it however busy it is, but not while it's signed out or stopped at its limit. With no model named, the job keeps its own on the same tool; on another, the strongest stays the strongest (`claude-fable-5-1` and `gpt-6-astra`) and any other model gives way to Settings › Models.

- **Queued:** it starts on the new choice.
- **Running:** its agent is stopped, and once it, everything it started and any check it was running have ended (so their edits can't cross the new agent's), the round starts over on the new choice with a new session, in the same worktree and branch. Until then `step` is `Moving to …`, and a message to the job answers 422 ("It's moving to … Tell it again in a moment."). The new agent hears the task, the earlier rounds' summaries, what the user told it, the message that started the round, that the user moved the job to it from where, and `why`. The job's report says `Moved from … to … by you.` A `permission` or plan the agent it left waited for is dropped with it (`permission` and `question` go back to null): the new agent asks again if it needs to.
- **Finished** (`done`, `failed`, `stopped` or `interrupted`): it stays as it ended, and its next round (`POST /v1/jobs/{id}/messages`, or Try again from the inbox) runs on the new choice, with a new session that hears what a running job's would, then the user's words.

The job keeps its `id`, branch and history, and a move is added to `moves`. Returns the job. `404` for an unknown job. `422` with why when it can't move: nothing named, an unknown tool, account or model, a model of another tool, an account signed out or at its limit, no account of the tool with room, the job already there, one of Oby's own reviews (they pick their account themselves), or a job wrapping up its only turn or publishing (move it once it's done).
### `POST /v1/jobs/{id}/mode`

Changes how much the job asks, from now on: `{"mode": "acceptEdits"}`. Returns the `Job`. Claude Code's session follows at once; Codex's next turn runs with the mode's sandbox and approvals. A permission waiting now that the new mode allows is answered (switching to `bypass` answers every waiting one, and the ones after it), and a plan waiting for approval is approved in the new mode. A finished job keeps the mode for when it runs again. `404` for an unknown job, `422` for a mode that isn't one.

### `POST /v1/jobs/{id}/permission`

Answers the job's waiting `permission`:

```json
{"id": "p1a2b3c", "decision": "allow" | "always" | "deny", "message": "optional words for the agent"}
```

- `allow`: it goes ahead, once (Claude Code's `control_response` allow with its `updatedInput`; Codex's `accept`).
- `always`: it goes ahead, and the permission's `rule` is saved for the repository in `oby.sqlite` (`GET /v1/permissions/rules`): later prompts it covers, in this job and every other in that repository, go through without asking. The agent itself gets a plain allow (Claude Code's allow without `updatedPermissions`, Codex's `accept`, never `acceptForSession`): a rule of its own would let later calls through without asking the runner, past the user's deny rules and a rule they forgot, so every call still comes to the runner and its saved rules answer it. Only for a permission with a `rule` (`422` otherwise).
- `deny`: it doesn't happen, and the agent hears `message` as why (Claude Code's deny `message`; Codex's `decline`, then the words as a message to its turn), or a plain no without one. The user's own no never counts toward the runner's limit on denials in a row.

Returns the `Job`, with the next waiting permission or null. `404` for an unknown job, `409` when `id` isn't the permission waiting now, `422` for another `decision`, a `message` over 2,000 characters, or `always` without a rule. A job interrupted with its permission kept picks its session up again, the agent told what it asked and the answer. Telling a job something (`POST /v1/jobs/{id}/messages`) while a permission waits is a deny with those words.

### Permission modes

How much a job asks, like Claude Code's modes. Each job has its `mode`; new jobs get Settings › Permissions' default (`bypass`, as before modes).

| Mode | Reads | File edits in the worktree | Commands and everything else |
|---|---|---|---|
| `ask` | go | ask | ask |
| `acceptEdits` | go | go | ask |
| `plan` | go | refused | ask |
| `bypass` | go | go | go |

- First, in every mode, `bypass` too, the runner's fixed rules: no pushing or posting (only Publish does), the worktree only, no background work, and among MCP tools only Tetrix's reads. Bypass skips questions, not fences: a push is refused in every mode.
- Then the saved rules for the job's repository: a deny rule refuses, and beats an allow rule; an allow rule lets it go without asking, except in `plan`, where everything but reads asks (an allow rule like `Bash(touch:*)` would change files while planning). A rule like `Bash(swift test:*)` covers that command with anything after it, `Bash(make lint)` exactly that, `Edit` every file edit and `Edit(Engine/*)` a folder's. An allow rule never covers a chained command (`&&`, `;`, a pipe); a deny rule covers one when any of its commands matches.
- Then the mode, as in the table. Reads (Read, Grep, Glob, Tetrix's graph reads) and the agent's own bookkeeping (its to-do list, a helper agent, whose own actions ask) never ask.
- The runner never starts Claude Code with its own bypass: it answers every prompt over stdio, so the fixed rules hold. Jobs start with `--permission-mode default` (or `plan`) and read no settings file, the account's included (`--setting-sources ""`): an allow list or a `defaultMode` there would let commands through before the runner is asked. The account's own MCP servers (Tetrix) come from its `.claude.json` through `--mcp-config` with `--strict-mcp-config`, each with only what starts it (`type`, `url`, `command`, `args`): a server that needs `headers` or `env` (a token) is left out, and an OAuth login stays in the account's own store. The file is `OBY_HOME/mcp/<job>.json`, outside the worktree, written 0600 as the agent starts, shown read-only in its box (the rest of `OBY_HOME` stays hidden), and removed once its first turn ends or it exits.
- **Plan:** Claude Code runs in its own plan mode and the agent is told to read only, then present its plan. Its `ExitPlanMode` request becomes the job's `question`: `{"text": "Approve the plan?", "plan": "…", "options": ["Approve: Accept edits", "Approve: Bypass", "Change it"], "recommended": 0}`, with `step` `"Waiting for your OK on the plan"` and the clocks paused. `Approve: <mode>` (any mode but plan, through the inbox, `POST /v1/jobs/{id}/messages` or `POST /v1/jobs/{id}/mode`) sets the job's `mode`, switches the session out of plan mode and lets it go on. An approval that says more (`Approve, but keep the old API`) approves in Accept edits and the agent hears the user's words with it. `Change it`, or the user's own words, sends the plan back with them. Codex runs a read-only turn (its own `read-only` sandbox on the Mac) that ends with its plan as its summary: the same question, and approving it runs the next turn in the mode picked. An agent whose plan-mode turn ends without `ExitPlanMode` is treated the same way.
- **Codex:** in `ask`, `acceptEdits` and `plan` its approval policy is `untrusted`, so every command that isn't a known read, and every file change, comes to the runner; `bypass` keeps `on-request`. Answers are `accept` (an always too) and `decline`. The runner applies saved rules to Codex's later prompts itself.

### `POST /v1/jobs/{id}/start`

Start now: a job waiting for its `startWhen` starts as if it had come (or waits for a slot); one still getting its worktree ready starts once it's ready. No body. Returns the job, with `startWhen` null; its report says `Started by you before what it waited for came.` `404` for an unknown job, `409` when it isn't waiting to start.

### `POST /v1/jobs/{id}/start-when`

Changes what a job that hasn't started waits for:

```json
{"startWhen": [{"pr": 205, "is": "merged"}, {"at": "2026-10-13T09:00:00Z"}]}
```

The list replaces the job's (Start when); `[]` starts it now. A condition on an account moves the job to that account. A job waiting to be asked about a condition that can't hold stops asking. Returns the job. `404` for an unknown job; `422` with why for a job that started already, one of Oby's own reviews, or conditions that can't be.

### `POST /v1/accounts/{id}/reserve`

Lifts an account's weekly reserve, or puts it back (#278):

```json
{"lift": true}
```

With `true`, the account takes automatic work past 80% of its week until `sevenDayResets` (a week from now while that's unknown or past), then it's reserved again by itself; `false` puts the reserve back now. Saved with the account's usage, so a restart keeps it. Jobs waiting for room (Start when) and reviews waiting for an account look again at once. Returns the Account, and every app following `GET /v1/events` gets `accounts`. `404` for an unknown account.

### `POST /v1/jobs/{id}/messages`

Tells the job's agent something:

```json
{"text": "Also add a test for the empty case."}
```

- **Running:** the agent hears it now, in the turn under way or as the next one (Claude Code: another message; Codex: it steers the turn).
- **Finished** (`done`, `failed`, `stopped` or `interrupted`): the runner picks the agent's session up again in the same worktree and branch (a job moved since its last round starts a new session on its new choice instead: `POST /v1/jobs/{id}/move`). The job keeps its `id`, goes back to `running` and gets a new `round`; when `rounds` is above 1 it grows by one too, so a loop still has a round for this. A dismissed job is dismissed no more. It ends as usual, except that this round may end `done` with nothing committed: your words decide what it should do.
- The text is saved in `notes`, and `step` shows `"You: …"` until the agent moves on.

Returns the job. `404` for an unknown job. `422` when the text isn't 1 to 2,000 characters, or the job can't take it: still getting ready, wrapping up its only turn (try again once it's done), or never started (no `session`, and never moved).

### `GET /v1/events`

Server-Sent Events, so the app stays live while it's open:

```
event: job
data: { …Job }

event: accounts
data: [ …Account ]

event: clear
data: {"clearedAt": "2026-10-10T08:12:00Z"}

event: inbox
data: { …InboxItem }

event: check
data: { …Mac check }

event: turn
data: { …Turn }
```

- A `job` event comes with every change: a new step, a status, the summary, `commits`, `published`, `publishError`, `pipeline`, `pullRequest`, `pullRequestError`, `dismissed`, `macCheck`, `mergeError`, a move to another account. The app replaces the job with that `id`.
- `accounts` comes when sign-ins, usage, reset times, running counts, `fullUntil`, a lifted reserve (`reserveLiftedUntil`) or Tetrix (`tetrix`, `tetrixJobs`, `tetrixUsed`) change.
- `clear` comes when Clear done is pressed on any app (`POST /v1/clear`): hide the settled jobs that finished by `clearedAt`.
- `inbox` comes with every inbox item that arrives or changes: answered, done or put off, on any app, or settled by itself. Replace the item with that `id`; one whose `state` is `done` leaves the inbox.
- `check` comes when a Mac check or an Apple check (below) is queued, taken by a Mac or ends. A Mac that runs checks asks for one (`GET /v1/checks/next`) when one is `queued`; other apps can ignore it, since the job's own event carries `macCheck` and `appleCheck` too.
- `turn` comes with every turn of the conversation that's added, from any app, and again when one changes (its `jobs`): the turn as `GET /v1/conversation` lists it. Replace the turn with that `id`, or add it in `at` order. Older runners don't send it.
- Settled jobs, failed checks, review errors and studied failures wake Oby's orchestrator. Events arriving within 30 seconds are handled in one turn. Event summaries are written by Oby; the brain must read the related job before acting, and agent/check output remains quoted evidence.
- A `: ping` comment every 15 seconds keeps the connection open. Reconnect after any drop. Fetch what you show (`GET /v1/status`, `GET /v1/jobs`, `GET /v1/inbox`; a runner older than the inbox answers `404` there, which means an empty inbox, and any other failure means try again) only once the events' response has arrived, and apply the events that came meanwhile over it: the runner follows a connection before it answers, so nothing that changes in between is lost.

### Orchestrator policy

The event turn uses the same brain account routing as a user turn, including Codex fallback when Claude accounts have reached their limits. Swift validates its actions against the event and the job it read first.

| Action | Automatic policy |
| --- | --- |
| `retry_job` | Retry the job's offered Try again or One more round action. |
| `message_job` | Send the agent Oby's concrete findings and requested correction. |
| `answer_inbox` | Use only Try again, One more round, Rebase now or Wait for the reset. Permission and product questions stay with the owner. |
| `start_now` | Start a job whose start condition can safely be skipped. |
| `move_job` | Move work to an account with room. |
| `fix_failure` | Start a fix for a studied record marked `obyCouldHandle`, with cause `oby-bug`, `agent-mistake` or `flaky-test`. |
| `ask_review_again` | Retry a review that ended with `reviewError`, using another account when needed. |

The orchestrator never merges, publishes, pushes, changes settings, dismisses committed work, handles credentials, or answers permission and product-decision items. Those events remain in Needs you with Oby's diagnosis. Swift permits at most 3 automatic actions per job per day, stops after a repeated failure signature, and starts no more than 10 event turns an hour; excess events wait for the next hour.

### `GET /v1/inbox`

The inbox items not yet done, the longest-waiting first, items put off `later` included (say so, or hide them until their time).

```json
[{"id": "ab12cd34-question-0", "kind": "question", …InboxItem}]
```

`GET /v1/inbox?state=done` is the history instead (#215): the items that are done, the latest settled first, at most `limit` (50 unless asked, at most 1,000). Reports with nothing to decide arrive there directly, never in the inbox: the audit's report of drift it fixed by itself (with its `outgoing` repairs), a `failure` whose fix was already under way, and items saved before #215 that offered no answer (done once when the runner starts). Answered, dismissed and settled items are there too, with their `answer`. `state=open` is the default; any other `state` is `422`. Older runners ignore `state` and list the open items.

### `POST /v1/inbox/{id}/answer`

Settles an item, on the iPhone or the Mac. The body is exactly one of:

```json
{"answer": "A new status"}
{"done": true}
{"later": "2026-10-10T10:12:00Z"}
```

- `answer`: one of its `options`, or the user's own words (1 to 2,000 characters). It goes to the job:
  - `question`: the answer is the agent's next message (as `POST /v1/jobs/{id}/messages`): a waiting job goes on, an ended one picks its session up again. A plan's question takes `Approve: <mode>` or `Change it` (Permission modes, below).
  - `permission`: `Allow`, `Always allow` or `Deny`, as `POST /v1/jobs/{id}/permission`; any other words are a deny with those words as the message for the agent.
  - `Dismiss` (on `review`, `failed`, `limit` and `merge`): dismisses the job (`POST /v1/jobs/{id}/dismiss`).
  - `Try again` (on `merge`): the merge is tried again, or the Mac check is handed to the author again or queued again on the same commit (Mac check, above).
  - `Try again` (on `failed` and `limit`): the job runs again in its session, told to pick up where it left off.
  - `One more round` (on `review`): Oby's last review is quoted in `.oby/inputs/review-4.md` and the agent works on it, as a message does. The runner doesn't review it again.
  - `Fix it` (on `failure`): the fix job starts, as `POST /v1/failures/{id}/fix` does, and the signature's items are done. When the cause is being fixed or is fixed already, nothing starts and the answer is refused (`422`) saying so, like `Fixed by #189 on dev.` `Dismiss` (on `failure`): done, nothing starts. Other words on a `failure` are refused (`422`).
  - `Add the column` (on an `audit` item about a missing column): the column joins the roadmap's Status field, then the audit runs again and moves its issues there. GraphQL's `updateProjectV2Field` keeps an option, and the cards on it, when the option goes back with its `id`, and the runner checks that by reading the ids back: it reads the field's options (`id`, `name`, `color`, `description`), sends every one back with its `id`, in its order, to GraphQL's `updateProjectV2Field` (`singleSelectOptions`), with the new one (gray, no description, no `id`) after the column it would stand in for (`Needs test` after `In review`), else last, and reads the options back: any old option whose `id` or name changed, or that moved, refuses the answer (`422`) and the item still waits. The request passes the secret scan first and is listed in the audit's ledger. When it fails the item waits, and the answer's error says why.
  - `Use <column> instead` (on an `audit` item about a missing column): remembered for that status in `issue-audit.json`, and the audit runs again now, moving its issues to that column; from then on issue sync and the audit put them there. `Ignore this status`: remembered too; from then on their column is left where it is. Neither asks again.
  - `Try again` (on an `audit` report of what failed): the audit runs again now, whatever the day; its report is a new item.
  - `Start` (on `start`): the guessed job is queued as planned, routed as it was when planned, and an Oby turn carrying it joins the conversation; `422` when its account has been signed out since (ask again). `Cancel`: done, nothing starts. Other words on a `start` item are refused (`422`).
  - `Try again` (on `failed` with `job` `runner-update`): the runner tries that commit again now (Runner update, below).
  - Other words: sent to the job as a message. On an `audit` or `runner-update` item, only its `options` are taken; other words are refused (`422`).
- `done`: settled without an answer; the job is left as it is.
- `later`: put off until that time (ISO 8601).

Returns the item. `404` for an item the runner doesn't know, `409` when it's done already, `422` for a body that isn't exactly one of these, a `later` that isn't a date, an empty or too-long answer, or a job that can't take it (the same reasons as `POST /v1/jobs/{id}/messages`). Every app following events hears the item (`inbox`) and its job (`job`).

### Failure record

Oby studies every failure and fixes the cause itself (#139, Engine/Failures.swift). Whenever a job fails, stalls, or someone had to step in, the runner writes a record in `oby.sqlite` with the evidence, kept for good, after the job list forgets the job.

```json
{"id": "ab12cd34-limit-1791582173", "trigger": "limit", "date": "2026-10-09T21:42:53Z", "job": "ab12cd34", "repo": "deskree-inc/oby",
 "title": "Mac runner notifications", "what": "Stopped at a limit: the same failure twice in a row", "rounds": 3, "intervention": false,
 "evidence": {"summary": "…", "step": "Stage 3 of 6, Check: swift test · phase check · round 3 of 4", "check": "`swift test` printed (its end): …",
              "reviews": [], "log": ["2026-10-09 21:42:50 UTC notice [jobs] job ab12cd34 stopped at a limit: …"],
              "worktree": "git status --porcelain:\n?? Engine/Left.swift\n\ngit diff --stat HEAD:\n(nothing)", "source": "b11afca…"},
 "postMortem": {"happened": "…", "cause": "environment", "obyCouldHandle": true, "signature": "simulator-hung-before-connecting",
                "fix": {"files": ["Engine/AppleChecks.swift"], "change": "…"}, "by": "claude Sonnet 5.5", "date": "2026-10-09T21:44:10Z"},
 "tries": 1, "acted": true, "studyError": null, "issue": "https://github.com/deskree-inc/oby/issues/140", "issueError": null, "fix": null,
 "fixedBy": null, "fixedAt": null}
```

- `trigger`: what Oby saw. `failed`, `interrupted` (a restart or quit cut it off) and `limit` (case 3.1); `reviewCap` (Oby's review requested changes for the last time it may), `noVerdict` (the review ended with no verdict, failed or was interrupted), `noReviewer` (no account could review it); `checkError` (the Mac couldn't run a merge or Apple check) and `unnamedFailure` (one failed without naming a test); `publishError` and `mergeError` (not a conflict Oby rebased by itself, Mac check above); `stuck` (it stayed in one step past its own limit: work 10 minutes past the round's, a check 10 minutes past the test run's, publishing 20 minutes, getting ready 30; or a Mac check queued 2 hours, or running past its lease); `brainFallback` (the brain didn't answer and rules planned: `job` is null); and the interventions, `handMerge` (a pull request Oby opened was merged, and Oby never merged it) and `outsideCommit` (its head is a commit Oby didn't push), with `intervention` true. A review job's own end reaches its author as `noVerdict`; a job the user stopped isn't a failure. Each is recorded once, and only while it's news (within a day).
- `what`: what Oby saw, in its own words. `rounds`: the rounds the job had used. `evidence`, with the vault's secrets taken out: `summary` (the job's report, or what the user said and why the brain failed), `step` (its stage and step), `check` (the end of what its check printed, and its Mac checks with what they printed, or null), `reviews` (Oby's reviews of it, oldest first), `log` (the runner's log lines of the last hour that name the job, and the last few of all), `worktree` (#221: what the job left in its worktree, `git status --porcelain` and `git diff --stat HEAD`, read at its first post-mortem, so a "nothing committed" failure shows the work left behind; null for the brain or with no worktree) and `source` (the commit of `origin/dev` the last post-mortem read, or null).
- `postMortem`: null until it's studied. A fresh, read-only turn boxed like the Lead's (`claude-sonnet-5-5`, only Read, Grep and Glob, no settings or MCP) reads the evidence as a quoted file and Oby's own source at a freshly fetched `origin/dev` (#221: a detached worktree of the runner's clone of `deskree-inc/oby`, `failures/source` in `OBY_HOME`, reset before each study; never the clone's own working tree, which is on whatever branch a job left it; the evidence names the commit), and answers in a JSON schema: `happened`; `cause`, one of `oby-bug`, `environment`, `agent-mistake`, `account-limit`, `flaky-test`, `feedback-not-converging`, `outside-service`; `obyCouldHandle`; `fix`, the `files` in Oby and the `change`; `signature`, a short kebab-case name for the cause that groups repeats (the turn sees the signatures used before); and `sameAs` (#197), `{"kind": "issue" | "pull-request", "number": N}` or null. Before the turn the runner reads the open `oby-failure` issues (number, signature, one-line cause) and the pull requests merged into `dev` in the last 7 days (with the issues their `Closes #N` lines name), and quotes them in a second file, `.oby/evidence/known.md`; `sameAs` is the one with the same root cause, and Swift drops one it wasn't offered. With an issue, the record's signature is kept as an **alias** of that issue's (in `oby.sqlite`), so later records with either name count, file and offer as one; with a merged pull request, it's an alias of the signature whose issue that pull request closes, when Oby knows it. It runs on the least busy Claude account with room, one record at a time, never holding a job up; with no account, it waits for the next minute's sweep. `tries` counts the turns (3 at most), and `studyError` says why the last one didn't answer.
- **Acting on it** (`acted`): the job's report (`summary`) gets a `What went wrong: <what happened> (cause: <cause>)` paragraph, before the review's follow-ups. When a fix merged into `dev` in the last 7 days already handles the cause (`sameAs` a merged pull request, a fix job of the signature's issue merged, or a merged pull request that closes it), the record is against that fix, `fixedBy` its pull request's URL and `fixedAt` when it merged, and nothing is filed or offered. The 7 days run from the merge, never from the records in between: a cause that still comes back after them is filed again. Otherwise an `oby-bug`, a signature seen twice in 7 days (an `environment` cause 3 times: most were a missing Mac or an old rate limit), or a record `sameAs` an open issue, becomes or updates one open GitHub issue labeled `oby-failure` in `deskree-inc/oby` (created as the GitHub app, after the secret scan of its title and text, with no assignee and no mention; a repeat, or a `sameAs`, brings that issue's body up to date instead of filing a new one, with how many times it was seen and the alias, never a comment, which would email the owner (#198); an issue Oby didn't file keeps its own body), with the post-mortem, the record and the evidence fenced; `issue` is its URL, or `issueError` why it couldn't. It also brings a `failure` inbox item offering `Fix it`, one open per signature; an `environment` cause seen twice brings only the item. When a fix of its cause is already underway (a fix job queued or running, or its pull request open, on the record's issue, its signature's or an alias's: what `Fix it` would refuse), it reaches no inbox (#215): the issue's body counts it and carries its evidence as any repeat, its item arrives `done` saying `Already being fixed by …` with no options, and the signature's open item is done by itself. A `failure` item that's open when a fix job on its cause starts or opens its pull request is done then too (Fix it would be refused), and the runner checks the open ones once after it restarts.
- **Closing** (#197): GitHub honours `Closes #N` only on merges into the default branch (`main`), and Oby merges into `dev`. So when a pull request of Oby's in `deskree-inc/oby` is merged into `dev` (Oby's merge, or one the runner sees merged), within a minute's sweep the runner closes every issue it closes (its job's `issue` and its description's `Closes`/`Fixes`/`Resolves #N`) that's open and labeled `oby-failure`: its body ends with `Fixed by #<pr>, merged into dev as <merge commit>. …` (after the secret scan), then it's closed as completed, never with a comment (#198). Feature issues keep their own lifecycle (#116). The closed issue's records get `fixedBy`, and their open `failure` inbox items are done. When GitHub fails, it's tried again 5 minutes later.
- `fixedBy`: the fix pull request merged into `dev` the record is against, or null; `fixedAt`: when it merged, or null.
- `fix`: the fix job Fix it started, or null. It's a `fix` job in `deskree-inc/oby` (on the account with the most room; the issue's when it has one, so its branch is `oby/fix-<issue>`), checked with `swift test` over up to 4 rounds, told only Swift's words; the post-mortem and the evidence are quoted in `.oby/inputs/failure-<record>.md`, as data.

### `GET /v1/failures?limit=50`

The failure records, newest first, each with its post-mortem (null until studied). `limit` goes up to 1,000.

### `GET /v1/failures/{id}`

One record. `404` for one the runner doesn't know.

### `POST /v1/failures/{id}/fix`

Fix it: starts the fix job (Failure record, above) and answers it, `201`, as `POST /v1/jobs` does; the signature's `failure` inbox items are done. `404` for a record the runner doesn't know; `409` when it isn't studied yet (`"Oby hasn't studied this failure yet."`), no account has room, or the cause is being fixed or is fixed already (#197): on the record's issue, its signature's or an alias's, a job is running (`"Already being fixed by job <id>."`), a pull request of Oby's is open (`"Already being fixed by #<pr>, its pull request open."`), or a fix merged into `dev` in the last 7 days (`"Fixed by #<pr> on dev."`). Then nothing starts.

### `GET /v1/jobs/{id}/publish`

What publishing this job by hand would do, in one sentence: for a job whose own publish failed (`publishError`). The app shows exactly this before asking for Face ID (the iPhone) or Touch ID (the Mac).

```json
{"action": "Push oby/fix-ab12cd to deskree-inc/oby and open a pull request into dev.", "base": "dev"}
```

Once the job is published and has new commits, the sentence is about them: `"Push the new commits on oby/fix-ab12cd to deskree-inc/oby, for its pull request into dev."` A rebased branch's rewritten commits are new commits too, until they're pushed.

`409` if there's nothing to publish (no commits, not done, or published with every commit: the branch on GitHub is at the worktree's head).

How a push goes out, by itself or by hand: the runner reads the branch's head on GitHub. No branch yet, the same commit, or one the new head builds on: a plain push. Anything else is a rebase, pushed with `--force-with-lease=refs/heads/<branch>:<the commit there>`, and only when that's the commit the runner itself pushed last (`outgoing`) and the branch is one of its own `oby/` branches. When someone else pushed to it, nothing goes out: `publishError` is `Not published: oby/fix-75 on GitHub is at <commit>, not the commit Oby pushed, so the rebase would overwrite someone else's work.` (or `… moved on GitHub while Oby pushed the rebase …` when the lease didn't hold). The secret scan, the pinned commit and the stop checks are the same either way.

### `POST /v1/jobs/{id}/publish`

Publishes by hand, for a job whose own publish failed, after the user approved on a registered device. The runner has no Touch ID of its own, so a registered device's stands in for it: the iPhone's Face ID, or the Mac's Touch ID (`Mac/MacDevice.swift`). Each has its own key (`Shared/DeviceKey.swift`); either one opens the same door.

```json
{"device": "d7c1…", "action": "Push oby/fix-ab12cd to deskree-inc/oby and open a pull request into dev.",
 "signedAt": "2026-10-09T22:01:07Z", "signature": "MEUCIQ…"}
```

- `signature`: ECDSA P-256 with SHA-256 (DER, base64) over the UTF-8 bytes of `"oby-publish\n<job id>\n<action>\n<signedAt>"`, made with the device's Secure Enclave key. The key's access control requires biometry (`.biometryCurrentSet`), so signing is what asks for Face ID or Touch ID. A cancelled prompt signs nothing, so nothing is sent.
- The runner checks:
  - the device is registered;
  - the signature;
  - `action` matches its own sentence exactly;
  - `signedAt` is within 2 minutes;
  - this signature hasn't been used before.
- Then it runs Publish, as a job's own publish does: guards, the secret scan, push one pinned commit, then the pull request, ready for review (the one already open for the branch, if there is one). It returns `{"url": "https://github.com/…/pull/42"}`, or an error line (for example the scan's findings, never the secret).

### `GET /v1/checks/next?mac=Studio&kinds=merge,apple`

For a Mac that runs checks. Answers `{"check": { …Mac check }}` with the oldest queued check, now `running` and that Mac's (`mac` is the query's name, up to 100 characters, or `a Mac`), or `{"check": null}` when none waits. `kinds` lists what the Mac takes, `merge`, `apple` or both; without it, merge checks only (Macs from before Apple checks). Apple checks come first: an agent waits on them. A merge check whose job runs again or pushed a newer commit isn't handed out, nor an Apple check whose job ended. A Mac that took a check and reported nothing for 2 hours 20 minutes (every step to its timeout, each xcodebuild step twice, and half an hour more) went away: the next Mac to ask gets it again. A Mac runs one check at a time and asks only when it's free, so a Mac that asks while it holds one lost it (Oby on it quit or relaunched mid-check): it gets that same check back first, `started` now, while its job still waits for it, even past the 2 hours 20 minutes if no other Mac took it meanwhile. Not a Mac without a name (`a Mac`): those can't be told apart. Ask when a `check` event says one is `queued`, on every (re)connection, and every 10 minutes.

### `GET /v1/checks/{id}/bundle`

For the Mac that took an Apple check: its commits as a git bundle (`application/octet-stream`) of the ref `refs/oby/apple-check-<id>`, holding the commits that aren't on `origin/<base>`. The Mac fetches `base` from GitHub first, then the bundle. Empty when the commit is on `base` already. `404` for a check the runner doesn't have, `409` for one no Mac has taken.

### `POST /v1/checks/{id}/result`

What the Mac found:

```json
{"passed": false,
 "steps": [{"name": "Mac app and MacTests", "passed": false, "seconds": 301}],
 "failures": ["MacTests.PublishTests/blocksASecret()"],
 "log": "Mac app and MacTests:\nPublishTests.swift:12: error: Expectation failed"}
```

- `problem` (optional): why the Mac couldn't run the check (one line, up to 500 characters). With it, the check is `error`, whatever else the result says. A result with no failing test whose `log` shows the Mac's own trouble (above) and no compiler error is `error` too, with `problem` `Mac check couldn't run: <the trouble>.`: Macs from before the retry report it as a failure, and it never goes to the author.
- `steps[].failing` (optional): the step's failing tests, `[{"test": …, "message": …}]`, from its result bundle or its output. `steps[].retried` (optional): `true` when the Mac's own trouble made it run a second time; the step's result and time are both runs'.
- A pass counts only when every step the Mac runs (`Runner tests (swift test)`, `Mac app and MacTests`, `iPhone app with Watch, and iOSTests`; for an Apple check, the last two) is in `steps` and passed, and `failures` is empty. A failing test name fails the check; a pass that leaves out a step, or a failure that names nothing that failed, is the Mac's problem (`error`).
- `log` (optional): for each failed step that names no failing test, the compiler's errors or else the last 40 lines it printed; for a step stopped at its timeout, the last test that started and the last 40 lines. It goes to the author's agent only (and, for an Apple check, its reviewer), with the vault's secrets taken out; it's never stored or posted.
- The runner keeps at most 10 steps, 50 failing tests (each one line of up to 300 characters; per step too, each message on one line of up to 500) and 8,000 characters of `log`. A failed step, or no steps, fails the check whatever `passed` says.
- Answers `{"check": { …Mac check }}` with the result on it. `404` for a check the runner doesn't have, `409` for one no Mac has taken (`GET /v1/checks/next`) or that has its result already.

### `POST /v1/agent/apple-check` and `GET /v1/agent/apple-check`

For `oby-check apple` in an agent's sandbox, with `Authorization: Bearer <its job's token>` instead of a Tailscale login. The runner gives each job's agent its token (`OBY_CHECK_TOKEN`), the API's address (`OBY_CHECK_URL`, `http://127.0.0.1:7777`) and the command (first on `PATH`, a script in `OBY_HOME/bin` that runs `oby-runner check`, both shown read-only in bubblewrap). `POST` asks for an Apple check of the job's worktree commit (or picks up the one already asked for that commit); `GET` says where the job's latest one is. Both answer:

```json
{"check": { …Mac check, "kind": "apple" },
 "line": "Apple check c0ffee12 of commit 1a2b3c4d5e6f is building and testing on Studio.",
 "report": null}
```

- `line`: where it is, in one line: queued (`waiting for a Mac`, or `Studio is running another check first`), building and testing, or how it ended.
- `report`: once it ended, what the command prints: each step with its time, the failing tests and the end of what the failing steps printed (the compiler's errors when there are any), with the vault's secrets taken out. For a check that couldn't run, why, followed by whatever the steps that did run found (one app's compiler errors still show when the other's simulator is missing). Null before then.
- `401` without a job's token, `409` when the job isn't running, its worktree commit can't be read, it asked for 20 already, or the runner doesn't queue checks; `404` (`GET`) before the job asked for one; `503` when the vault can't be read.

`oby-check apple [--wait SECONDS]` asks, prints `line` when it changes, polls every 5 seconds, and prints `report`. `--wait` (1 to 3,000; 110 by default, under a 2-minute command timeout, or `OBY_CHECK_WAIT` in a job's check) bounds the whole wait, the requests to the runner included: a request still unanswered at the deadline is dropped. It notes uncommitted changes, which aren't in the check. Exit status: `0` passed (or, with `OBY_CHECK_SKIP=1`, didn't ask for the build), `1` failed, `2` couldn't run (no Mac, the Mac's problem, no runner), `3` still running (run it again: it picks up the same check), `64` a wrong command line. Jobs whose Lead brief names `iOS/`, `Watch/`, `Mac/` or `Shared/`, or, without a brief, in a repository that has them, are told about it in their prompt.

### `POST /v1/devices`

Registers a device's publishing key, once per device: the iPhone's (named "iPhone") or a Mac's (named after the Mac, `Host.current().localizedName`):

```json
{"name": "Wellington's MacBook Air", "publicKey": "BJ3x…"}
```

`publicKey` is the P-256 public key, X9.63 (65 bytes, uncompressed), base64. It returns `{"id": "d7c1…"}`. Only the runner's owner can register (the tailnet header); the runner lists devices in its log.

- A key the runner knows returns its id right away, so the app registers every time it connects.
- A new key needs pairing open: the owner runs `touch $OBY_HOME/pairing` on the runner's machine, and the device registers within 10 minutes. That key uses it up, so the iPhone and the Mac each need it opened once. Otherwise `403` with that one line to show: the Mac shows it in Settings › Runner, with Try again.
- Why: agents run on the runner's machine, so through its tailnet address they arrive with the owner's header. They can't touch `pairing`, because `OBY_HOME` is empty inside their bubblewrap.

### `POST /v1/activities`

Hands the runner a Live Activity push token, so it can keep the phone's Lock Screen and Dynamic Island current while the app is suspended:

```json
{"token": "80a1f2…", "kind": "update", "topic": "dev.wellprado.oby", "environment": "development"}
```

- `token`: the push token in hex. `kind`: `"update"` for one activity's token, `"start"` for the app's push-to-start token (a newer one replaces the older for the same app and environment). `topic`: the app's bundle ID. `environment`: `"development"` (a build from Xcode) or `"production"` (TestFlight and the App Store).
- It returns `{"push": true}` when the runner pushes, `{"push": false}` when it has no APNs key (the token isn't kept). `422` for a token, kind, topic or environment that isn't one of those.

Two seconds after a job changes, the runner pushes what its jobs look like then (one Live Activity, as the app shows it):

- **A job is active** and the runner has update tokens: an `update` with the newest active job (priority 5, skipped when nothing the card shows changed).
- **A job is active**, no update tokens, and it hasn't started one yet: a push-to-start (`start`, priority 10, with an alert) to the start tokens. The phone then hands over the new activity's update token.
- **Nothing is active:** an `end` with how the last job finished and a dismissal 15 minutes after it finished, with no alert (a job that needs you says so with its own notification, below); then the update tokens are dropped.

Apple's answer `410` or `BadDeviceToken` drops a token. The runner keeps tokens in `apns/tokens.json`.

### `POST /v1/notifications`

Hands the runner the app's device token, so it can tell the phone when a job needs you:

```json
{"token": "5b0e9c…", "topic": "dev.wellprado.oby", "environment": "production"}
```

- `token`: the device token from `registerForRemoteNotifications`, in hex. `topic` and `environment` as for `/v1/activities`. The app sends it on every launch once notifications are allowed (it asks the first time something said on the phone starts a job).
- It returns `{"push": true}` or `{"push": false}`, and `422`, as `/v1/activities` does.

Two seconds after a job changes, the runner sends an alert push (`apns-push-type: alert`, the app's bundle ID as topic, priority 10) for each job whose need changed. Nothing else notifies: steps, rounds, and jobs that end needing nothing (stopped, or done without commits) only move the Live Activity.

| The job | Title | Body | `category` |
|---|---|---|---|
| Done with commits it couldn't publish by itself | `Couldn't publish: <title>` | `publishError` (else the summary's first line) | `ready` |
| `failed` | `Failed: <title>` | the reason (the summary's first line) | `job` |
| `interrupted` | `Interrupted: <title>` | the reason | `job` |
| Oby's review stopped asking for changes | `Changes requested: <title>` | `Oby's review found a blocker it asked to fix before. Take it from here.` | `job` |
| Its agent asked a question (`question`), which waits in the inbox | `Question: <title>` | the question | `job` |
| Its agent waits for the user's OK (`permission`), which waits in the inbox | `<permission title>?`, like `Run swift test?` | `<title>: <detail>` | `permission` |

```json
{"aps": {"alert": {"title": "Couldn't publish: Review oby #33", "body": "Couldn't push oby/review-33: the remote hung up."},
         "category": "ready", "sound": "default", "thread-id": "jobs"}, "job": "9f08fd10"}
```

- `job` is the job's `id`: tapping the notification opens it. The `ready` category offers **Publish** (it unlocks the phone and brings the app forward, where Face ID signs the approval as in the app) and **Open**; `job` offers **Open**; `permission` is for **Allow**, **Always allow** and **Deny** (`POST /v1/jobs/{id}/permission` with the job's `permission.id`) and **Open**.
- `apns-collapse-id` is the job's `id`, so a newer state replaces the older notification.
- When a job stops needing you (published, from the iPhone or the Mac, dismissed, or running again after a message), the runner sends a background push (`apns-push-type: background`, priority 5), `{"aps": {"content-available": 1}, "clear": "<job id>"}`, and the app removes that job's notification. The app also removes them whenever it opens and sees the job needs nothing.
- The runner remembers what it last said for each job in `apns/notices.json`, so a restart doesn't say it again, and jobs a restart interrupted notify once it's back.

### `GET /v1/settings/permissions` and `PUT /v1/settings/permissions`

Settings › Permissions: `{"mode": "ask"}`, the mode new jobs get (`bypass` until changed), kept in the runner's `oby.sqlite`. `PUT` answers with the setting; `422` for a mode that isn't one. Jobs already dispatched keep theirs.

### `GET /v1/permissions/rules` and `DELETE /v1/permissions/rules/{id}`

The saved rules, oldest first:

```json
[{"id": "r1a2b3c4d", "rule": "Bash(swift test:*)", "repo": "deskree-inc/oby", "decision": "allow", "created": "2026-10-11T09:12:00Z"}]
```

`decision` is `allow` or `deny`; deny beats allow. "Always" on a permission saves one. `DELETE` forgets one and answers with the rules left; `404` for a rule the runner doesn't know.

### `GET /v1/settings/models` and `PUT /v1/settings/models`

Each tool's model, routine effort and complex-job effort, as in `status.models`. `GET /v1/settings/models/options` lists the choices: Claude Code's models and efforts, and the models the signed-in Codex account offers (from its own `model/list`) with the efforts each takes. Defaults are Claude Code `xhigh` and Codex `high` for `complexEffort`; older clients that omit it keep the current value.

The chat's set_setting action uses those same choices. It changes one tool's model, routine effort or `complexEffort`, maxRunning (1 through 20), or an account's weekly reserve (lift true or false). For example, "complex jobs on Codex at xhigh" sets Codex's `complexEffort`. Swift checks every value against the briefing before the runner applies it; a rejected model or effort includes the available choices. Each action reply names the old and new value. A request that changes two tools is planned as two actions so the brain receives a fresh briefing between them.

```json
{"claude": {"models": [{"id": "claude-opus-5-5", "name": "Opus 5.5"}], "efforts": ["low", "medium", "high", "xhigh", "max"], "complexEfforts": ["low", "medium", "high", "xhigh", "max"]},
 "codex": {"models": [{"id": "gpt-6-sol", "name": "GPT-6-Sol", "efforts": ["low", "medium", "high", "xhigh", "max", "ultra"]}], "complexEfforts": ["low", "medium", "high", "xhigh", "max", "ultra"]}}
```

### `GET /v1/settings/jobs` and `PUT /v1/settings/jobs`

How many jobs run at once, as in `status.maxRunning`: `{"maxRunning": 6}`, 1 to 20 (anything else is `422`). The runner keeps it across restarts. Raising it starts waiting jobs at once; lowering it stops nothing, and new jobs wait until fewer than the new cap run.

### `POST /v1/speech?device=<UUID>&utterance=<UUID>&final=false&language=auto`

Transcribes one utterance on the runner's CPU using whisper.cpp, independently of the iPhone and of any agent. It uses the same owner gate as the other `/v1` endpoints. This is the speech service only; a Watch gateway can call it later.

The body is binary audio: signed 16-bit little-endian PCM, 16 kHz, mono (`Content-Type: audio/pcm` or `application/octet-stream`), or a complete RIFF/WAV chunk containing that same format (`audio/wav` or `audio/x-wav`). Send sequential chunks of at most ten seconds; each WAV request has its own header. The HTTP body limit is 324,096 bytes including WAV metadata. Audio for an utterance may total at most 60 seconds (1,920,000 PCM bytes).

- `device`: stable UUID chosen by the app for this device. This is a concurrency key, not authentication.
- `utterance`: a fresh UUID for each utterance. Reuse it for every chunk of that utterance.
- `final`: `false` by default. Every non-final call appends the chunk and transcribes **all** audio so far with multilingual `base-q5_1`. A `true` call appends its optional last chunk and transcribes all audio with `small-q5_1`, then discards the utterance. An empty final body is allowed after earlier audio. Partial text can change.
- `language`: `auto` (default, detection while transcribing), `en` or `pt`. Use the same language on every call. Transcription keeps the spoken language; it does not translate. With `auto`, partials keep detecting the language from all audio so far. After at least five seconds of partial audio, the final pass reuses the latest detected English or Portuguese language to avoid a second encoder pass. Final-only requests, shorter partials and other detected languages still use automatic detection.

Returns `{"utterance":"<UUID>","text":"…","final":false}` (or `true`). Wait for each answer before sending the next chunk. Accepted chunks append exactly once per received call; this endpoint does not deduplicate retries. After an uncertain network result, let the session expire before starting again.

Only one utterance per device is open or transcribing at once (`409` for an overlapping call, a different utterance or a changed language). One resident server per distinct model and 32 open utterances are allowed across devices. Each model accepts one inference at a time (`503` when busy). A busy `503` consumes none of the rejected chunk and preserves earlier audio and its idle deadline; retry the same chunk with the same utterance UUID. Fast and final models can work independently. Idle utterances are discarded after 120 seconds following their last partial answer. `400` means invalid parameters/audio; `413` means a body or utterance is too large. Exceeding the utterance limit discards it. `415` means unsupported content type. `501` clearly identifies a missing server/model or invalid thread count. `500` means transcription failed or timed out: audio is discarded and the client starts a fresh utterance. Each inference has a 120-second deadline; a timeout kills that model’s server to release its audio. The next request or five-second maintenance pass restarts it.

Audio stays in memory throughout: normalized WAV is posted as multipart `file` data to whisper-server's `/inference` endpoint, with `language`, `prompt`, `response_format=verbose_json`, `no_language_probabilities=true` and `no_context=true`. Language probabilities are disabled because upstream otherwise encodes the audio again for that response. The runner consumes only the text and detected language; its public response is unchanged. Neither Oby nor the server writes audio or transcript files (`--convert` is never enabled). Servers bind only to `127.0.0.1`, have a random request-path prefix, receive no agent/login environment, and run directly under the runner outside `Agents.sandboxed`. Their stdout/stderr go to `/dev/null`; audio and transcripts never reach logs or agents. Startup removes legacy crash leftovers from `OBY_HOME/whisper/audio`. HTTP uses a fresh, verified loopback socket for each request, without cookies, cache or proxies. No previous utterance's decoder context is carried into another request.

The runner starts both model servers before serving requests and keeps them resident, restarting exited servers during maintenance or on demand. Startup warms each server with one second of generated silence (not microphone audio) using the short encoder window, and discards the result. Readiness and warmup share a 120-second startup deadline. A missing installation leaves the other API routes usable and returns `501` for speech. Runner shutdown kills its servers; systemd's default control-group cleanup also covers a runner crash. If both model paths are identical, they share one server. Reserve the configured loopback ports for this runner; an occupied port causes readiness to fail. Before sending any request bytes (including warmup), the runner verifies that the connected peer socket belongs to its spawned child: `/proc/net/tcp` and the child’s descriptors on Linux, `lsof` on macOS. Audio travels over that same verified socket, with no redirects or automatic reconnects, so a different listener cannot receive it even if the port changes hands. If ownership cannot be verified, speech fails closed.

Run `OBY_HOME=/srv/nvme/oby Runner/scripts/setup-whisper.sh` once as the runner's owner on tetrix-lab. It requires git, CMake, a C++ compiler, curl and flock (Ubuntu: `git cmake build-essential curl util-linux`). It pins whisper.cpp v1.8.2, builds static release `whisper-cli` and `whisper-server` binaries optimized for this CPU with GPU backends off, and atomically downloads multilingual `base-q5_1`, `large-v3-turbo-q5_0` and `small-q5_1`. Repeated runs reuse the checkout/build and completed downloads; interrupted downloads are retried. Existing unquantized models are retained but unused by default. See the [upstream server](https://github.com/ggml-org/whisper.cpp/blob/v1.8.2/examples/server/server.cpp) and [model distribution](https://github.com/ggml-org/whisper.cpp/blob/v1.8.2/models/download-ggml-model.sh).

Short audio no longer pays for Whisper's default 30-second padding. Each request sets `audio_ctx` to `min(1500, max(600, (ceil(seconds) + 1) * 50))`: at least 12 seconds, a second beyond the audio, and at most the full 30-second encoder window. The 11-second sample uses 600 frames. Utterances of 30–60 seconds use the full window and whisper.cpp's successive-window processing; the 60-second input cap is unchanged.

Measured on tetrix-lab (16 CPU cores), 2026-10-11, with whisper.cpp v1.8.2's 11-second `samples/jfk.wav`, CPU-only, eight inference threads, `no_context=true`, no timestamps, and prompt `oby, tetrix`. Timing covers the loopback inference request through the parsed response, excluding startup/model loading. Models were resident and warmed with generated silence. Loads are one-minute averages recorded before each request; concurrent work changed between runs, so this is not a controlled comparison with the earlier load-13.6 CLI measurements (base-q5_1 4.3 s, unquantized turbo 27 s).

| Model / language | Encoder frames | Inference seconds | Load before each request |
| --- | --- | --- | --- |
| small-q5_1 / en | 600 | 1.710, 2.083, 1.632 | 28.12, 27.15, 27.15 |
| large-v3-turbo-q5_0 / en | 600 | 13.129, 12.826, 13.715 | 48.08, 49.90, 46.28 |
| small-q5_1 / auto | 600 | 9.764, 2.991 | 27.15, 40.65 |
| large-v3-turbo-q5_0 / auto | 600 | 25.900, 24.094 | 49.00, 53.18 |

These first measurements used the text-only JSON response. A repeat with the production verbose response and language probabilities disabled measured small-q5_1 at **27.008, 10.515, 11.136 s**, at loads **76.72, 77.19, 74.21**. The same production-response repeat measured quantized turbo at **13.181, 12.641, 12.174 s**, at loads **75.15, 70.89, 60.78**. The returned word sequence matched in the response-format checks. Earlier full-window (1500-frame) resident runs were also slow: small 47.923/63.658 s (loads 75.91/83.18), quantized turbo 50.006/36.528 s (loads 71.16/73.02). Reducing threads to one, two or four did not improve the best eight-thread result; retain eight by default.

**Default: small-q5_1.** It reached about two seconds on the warmed English sample; turbo remains too slow. Startup warmup, the smaller encoder window and reuse of a sufficiently long partial's detected language avoid repeated setup and detection work in the live speech path. This is not a two-second guarantee under heavy contention: the current machine sometimes ran at loads above 100, and even the small model missed the target badly. Final-only automatic detection is also slower. Use `en`/`pt` when the device knows its language, or send live partials; longer utterances and Portuguese recognition still need real Watch measurements.

The runner reads this configuration from its environment at startup (restart after changes):

| Variable | Default |
| --- | --- |
| `OBY_WHISPER_SERVER` | `OBY_HOME/whisper/bin/whisper-server` |
| `OBY_WHISPER_FAST_MODEL` | `OBY_HOME/whisper/models/ggml-base-q5_1.bin` |
| `OBY_WHISPER_FINAL_MODEL` | `OBY_HOME/whisper/models/ggml-small-q5_1.bin` |
| `OBY_WHISPER_THREADS` | `8` per model server, allowing two inferences to share tetrix-lab's 16 CPU cores |
| `OBY_WHISPER_FAST_PORT` | `8171` (loopback only) |
| `OBY_WHISPER_FINAL_PORT` | `8172` (loopback only) |
| `OBY_SPEECH_NAMES` | Unset: `oby`, `tetrix` and the short names of the runner's current `Desk.repos` list. Set a comma-separated list to override these names. Duplicates are removed and the initial prompt is capped at 512 UTF-8 bytes, including for overrides. |

No GPU is needed. The sample timings above do not replace checks with real Watch recordings.

### `GET /v1/watches`, `POST /v1/watches` and `DELETE /v1/watches/{id}`

The Apple Watches paired with the runner, for [the Watch API](#the-watch-api). On this API, so only the owner's iPhone over the tailnet reaches them.

`POST /v1/watches` pairs one. The Watch makes its key in its Secure Enclave and hands the public half to the iPhone over WatchConnectivity; the iPhone signs the pairing with its Face ID key and sends it with the Cloudflare Access service token it gives the Watch:

```json
{"name": "Wellington's Apple Watch", "publicKey": "BK9…",
 "accessClientId": "4a1c….access", "accessClientSecret": "9f2e…",
 "approval": {"device": "d7c1…", "signedAt": "2026-10-11T09:12:30Z", "signature": "MEUCIQ…"}}
```

- `publicKey`: the Watch's P-256 key, X9.63, base64. `approval.signature`: ECDSA P-256 with SHA-256 (DER, base64) by the registered phone's key (`POST /v1/devices`) over `"oby-pair-watch\n<publicKey>\n<signedAt>"`, within 2 minutes, once. Agents on the runner's machine reach this API as the owner, but they can't make that signature.
- The service token goes to the runner's vault (`watch-access-client-id`, `watch-access-client-token`), where no agent sees it and the secret scan learns it, so nothing outgoing carries it. A newer pairing replaces it. No answer or event carries it.
- It returns `201` with `{"id": "5e0f…", "url": "https://oby-watch.example.com"}`: the Watch's id and the Watch API's address, which the iPhone hands the Watch with the token. A key the runner knows keeps its id. `409` when the runner has no `watch.json` yet, `403` for an approval that doesn't pass, `422` for a key or token that isn't one.

`GET /v1/watches` lists them, `[{"id": "5e0f…", "name": "Wellington's Apple Watch", "registered": "2026-10-11T09:12:31Z"}]`, never a key or the token. `DELETE /v1/watches/{id}` removes one (the iPhone's Settings): its requests fail from then on and its push tokens are dropped; with the last Watch gone, the service token leaves the vault. `404` for a Watch the runner doesn't know.

## The Watch API

The Watch works without its iPhone. While the phone is in reach, the Watch goes through it as before (WatchConnectivity, `Shared/WatchWire.swift`); otherwise it calls this API itself, and goes back to the phone once it's in reach again. watchOS has no Tailscale or VPN, and only plain HTTPS through `URLSession` (no WebSockets), so:

- **Where:** the runner listens on a second address, `127.0.0.1:7778` (`OBY_WATCH_PORT`), which serves only the endpoints below. A Cloudflare Tunnel (`cloudflared`) publishes it at a hostname of the owner's, and a Cloudflare Access application on that hostname lets through only requests carrying its service token (`CF-Access-Client-Id` and `CF-Access-Client-Secret` headers, a Service Auth policy).
- **Set up** on the runner's machine, in `$OBY_HOME/watch.json`, read again whenever it changes:

  ```json
  {"url": "https://oby-watch.example.com", "team": "example",
   "audience": "4714c1358e65fe4b408ad6d432a5f878f08194bdb4752441fd56faefa9b2b6f2",
   "keys": [{"kid": "…", "kty": "RSA", "alg": "RS256", "n": "…", "e": "AQAB"}]}
  ```

  `url` is the tunnel's hostname, `team` the Zero Trust team name, `audience` the Access application's AUD tag, and `keys` the `keys` list from `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`. Cloudflare rotates those keys every six weeks: paste the new list in. Without a usable `watch.json`, every request is `503`.
- **Never** `Tailscale-User-Login`: it means nothing here. Every request needs both of these, or it's `401` with the reason:
  1. **`Cf-Access-Jwt-Assertion`**, which Access adds to every request it lets through: an RS256 JWT, checked against `keys` (by `kid`), with `audience` in `aud`, `iss` `https://<team>.cloudflareaccess.com`, and `exp`, `nbf` and `iat` current (a minute of clock difference allowed).
  2. **A signature from a paired Watch**, over the request:
     - `Oby-Watch`: the Watch's id from pairing.
     - `Oby-Time`: when it was signed, in seconds since 1970. At most 2 minutes behind the runner's clock and 5 seconds ahead of it.
     - `Oby-Nonce`: 16 to 64 letters, digits, `-` or `_`, new for every request. A nonce the runner has seen from that Watch is refused, so a replayed request fails, after a restart too: the runner keeps used nonces in `$OBY_HOME/watch-nonces.json` (0600) until their request is too old to get in. When it can't save or read that file, Watch requests are `503`.
     - `Oby-Signature`: ECDSA P-256 with SHA-256 (DER, base64), by the Watch's Secure Enclave key, over the UTF-8 bytes of `"oby-watch\n<METHOD>\n<path and query, as sent>\n<Oby-Time>\n<Oby-Nonce>\n<hex SHA-256 of the body>"` (the body's hash is that of no bytes for a `GET`).
- Answers and errors are as on the tailnet API, vault secrets taken out the same way.

The endpoints, each as on the tailnet API unless it says otherwise:

| Endpoint | |
|---|---|
| `GET /v1/jobs?limit=50` | The jobs. |
| `GET /v1/jobs/{id}` | One job. |
| `GET /v1/events` | The event stream. The Watch follows it only while Oby is on screen. |
| `POST /v1/plans` | What was dictated: the work it plans starts, and the answer carries the jobs. |
| `POST /v1/jobs` | A job described whole; a plan's draft from before #269 is `410`. |
| `POST /v1/jobs/{id}/messages` | A word to the job's agent. |
| `POST /v1/jobs/{id}/dismiss` | Dismiss. |
| `POST /v1/jobs/{id}/move` | Move to another tool, account or model. |
| `POST /v1/jobs/{id}/start` | Start now, a job waiting for its `startWhen`. |
| `POST /v1/jobs/{id}/permission` | Answer a waiting permission. |
| `POST /v1/jobs/{id}/mode` | Change a job's mode. |
| `GET /v1/jobs/{id}/publish` | The sentence publishing would carry out. |
| `POST /v1/jobs/{id}/publish` | Publish, approved on the Watch (below). |
| `POST /v1/notifications` | The Watch's push tokens (below). |
| `POST /v1/speech` | A piece of a held recording (below). |

### `POST /v1/jobs/{id}/publish` on the Watch API

The Watch approves with a turn of the crown, after showing the runner's sentence. `{"action": "Push oby/fix-ab12cd to deskree-inc/oby and open a pull request into dev."}`: the signed request is the approval (fresh, once, from a paired Watch's key), and `action` must be the runner's own sentence exactly, else `403`. Then Publish runs as for `POST /v1/jobs/{id}/publish` above, and returns `{"url": …}`.

### `POST /v1/notifications` on the Watch API

The Watch's own push tokens: `{"token": "5b0e9c…", "topic": "dev.wellprado.oby.watchkitapp", "environment": "production", "kind": "alert"}`.

- `kind` `"alert"` (the default) is the Watch app's device token. The runner sends it exactly the alerts and clearing pushes it sends the iPhone (`POST /v1/notifications` above), the same payload with the same `apns-collapse-id`, so the Watch shows each alert once.
- `kind` `"widget"` is the complications' WidgetKit push token. When the number of jobs that need you or are working changes, the runner sends `{"aps": {"content-changed": true}}` (`apns-push-type: widgets`, topic `<topic>.push-type.widgets`), and the complications fetch the jobs themselves. A newer widget token replaces the Watch's older one.
- It returns `{"push": true}` or `{"push": false}`, and `422`, as `POST /v1/notifications` does. Unpairing the Watch drops its tokens.

### `POST /v1/speech?request={id}&sequence={n}` on the Watch API

A piece of the recording the user is holding the talk button for: the body is mono signed 16-bit little-endian PCM at 16 kHz (`application/octet-stream`), up to 32,000 bytes (one second), `request` the hold's id (8 to 64 letters, digits or `-`) and `sequence` 0, 1, 2… in order.

The Watch API doesn't pass pieces on to the runner's speech service (`POST /v1/speech` on the tailnet API, above) yet: a well-formed piece is answered `501`, `{"error": "Speech-to-text isn't set up on the runner yet. Dictate instead."}`, and the Watch stops recording and offers the system's dictation. `400` without `request` and `sequence`, `422` for an empty, odd or too-long piece.

## What the runner never does

- **Push to main:** not for anyone, not even with an approval.
- **Force-push, except a rebase of its own branch:** only an `oby/` branch the runner made, only over the commit it pushed there last (`--force-with-lease`), never `main` or `dev` ([`GET /v1/jobs/{id}/publish`](#get-v1jobsidpublish)).
- **Merge, except into `dev` after the Mac check:** the runner squash-merges a pull request it opened only into `dev`, only when Oby's review approved it, the Mac check passed on the same commit and the secret scan is clean (Mac check, above). Never into `main`.
- **Publish what didn't pass:** only a job that ended `done` (its check passed, or it has none), with a clean secret scan, is pushed and gets a pull request; by hand, only with a fresh device signature. No comment goes out: Oby's own review of its own pull request and the Mac check's results on it are check runs (an Apple check posts nothing), and the `oby-failure` issues its post-mortems file in Oby's own repository (Engine/Failures.swift) are updated in place, all after the secret scan; no agent posts to GitHub, and no GitHub review, approval or comment goes on anyone else's work.
- **Touch the user's credentials:** it never reads, stores or forwards agent credentials, and each tool signs in through its own login on the runner.
- **Read outside text as instructions:** text from GitHub or other people reaches agents only as quoted files.
