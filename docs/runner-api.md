# The Oby runner API

The runner is Oby's engine without the notch: the brain, Oby's own clones and job worktrees, the Claude Code and Codex runners, accounts, routing and Publish. It runs on an always-on machine (first: `tetrix-lab`, Ubuntu, on Wellington's tailnet), so the iPhone app (and later the Watch) can plan, dispatch and follow jobs while the Mac is closed.

This document is the contract between the runner and its clients. Change it in the same pull request as the code on either side.

## Reaching it

- **Base URL:** `https://tetrix-lab.tail8de49b.ts.net` (the app lets you change it). Everything is under `/v1`.
- The runner listens on `127.0.0.1:7777` only. `tailscale serve` publishes it on the tailnet with a real HTTPS certificate, so iOS needs no exceptions, and nothing is reachable from the internet.
- **Who you are:** `tailscale serve` adds `Tailscale-User-Login` to every request. The runner answers only its owner's login (set when it's installed) and returns `401` to anyone else. The app sends no token and stores no secret for this.
- **JSON** everywhere, camelCase keys, dates as ISO 8601 strings (`2026-10-09T21:43:30Z`). Errors are `{"error": "One line a person can read."}` with a 4xx or 5xx status.

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
  "published": null
}
```

- `agent`: `claude` or `codex`. `account`: an account `id`. `kind`: `review`, `fix`, `build`, `test` or `investigate`.
- `status`: `queued`, `running`, `done`, `failed`, `stopped` or `interrupted`.
- `step`: what it's doing now, while queued or running. `summary`: the agent's final message; its first line is the one-line notice.
- `base`: the branch the work started from (filled in once the job is ready). `pr`: the pull request it works on, if any.
- `commits`: commits made beyond `base` (set when a job is done). Publish is offered only when it's above 0.
- `published`: the draft pull request's URL once published.
- What to show: the title is `"<Kind> <repo name> #<pr>"` when `pr` is set, otherwise the first line of `request`.

### Account

```json
{"id": "default", "agent": "claude", "name": "Personal", "label": "Max · well0cp@gmail.com",
 "signedIn": true, "fiveHour": 0.12, "sevenDay": 0.4, "running": 1}
```

`label` is what the tool says about the login (null while signed out). `fiveHour` and `sevenDay` are 0…1 or null when unknown. Accounts are signed in on the runner itself, through each tool's own login; the app only shows them.

### Draft

What the plan card shows before anything runs:

```json
{"said": "Review oby PR #33", "reply": "Oby will review PR #33 in oby.", "guessed": false, "job": { …Job, status "queued" } }
```

`guessed` is true when the brain didn't answer and rules made the plan: say so on the card.

## Endpoints

### `GET /v1/status`

```json
{"runner": {"version": "0.2.0", "host": "tetrix-lab"},
 "accounts": [ …Account ],
 "models": {"claude": {"model": "claude-opus-5-5", "effort": "xhigh"}, "codex": {"model": "gpt-6-sol", "effort": "high"}}}
```

### `POST /v1/plans`

Turns words into a plan. Takes 3–20 seconds (the brain thinks); show Oby thinking.

```json
{"said": "Review oby PR #33"}
```

To answer the brain's question, send the original words with the answer:

```json
{"said": "Review PR 12", "answer": {"question": "Which repository is PR #12 in?", "option": "deskree-inc/oby"}}
```

The answer is one of:

```json
{"kind": "plan", "draft": { …Draft }}
{"kind": "question", "said": "Review PR 12", "question": {"text": "Which repository is PR #12 in?", "options": ["deskree-inc/oby", "deskree-inc/blok"]}}
{"kind": "reply", "text": "Oby can't merge pull requests."}
{"kind": "none"}
```

### `POST /v1/jobs`

Dispatches the draft's job. The user may have changed `branch` (must stay a valid branch name) and `account` (any signed-in account; `agent` follows the account). Everything else comes from the draft unchanged.

```json
{"job": { …the draft's Job }}
```

Returns the queued `Job` (`201`). `422` if the branch isn't valid or the account isn't signed in.

### `GET /v1/jobs?limit=50`

The latest jobs, newest first.

### `GET /v1/jobs/{id}`

One job.

### `POST /v1/jobs/{id}/stop`

Stops a queued or running job. Returns the job (`status: "stopped"`).

### `GET /v1/events`

Server-Sent Events, so the app stays live while it's open:

```
event: job
data: { …Job }

event: accounts
data: [ …Account ]
```

- A `job` event comes with every change: a new step, a status, the summary, `commits`, `published`. The app replaces the job with that `id`.
- `accounts` comes when sign-ins or usage change.
- A `: ping` comment every 15 seconds keeps the connection open. Reconnect after any drop, then refetch `GET /v1/jobs` to catch up.

### `GET /v1/jobs/{id}/publish`

What publishing this job would do, in one sentence. The app shows exactly this before asking for Face ID.

```json
{"action": "Push oby/fix-ab12cd to deskree-inc/oby and open a draft pull request into dev.", "base": "dev"}
```

`409` if there's nothing to publish (no commits, not done, already published).

### `POST /v1/jobs/{id}/publish`

Publishes after the user approved on a registered device. Nothing goes out without that approval: the runner has no Touch ID, so the iPhone's Face ID stands in for it.

```json
{"device": "d7c1…", "action": "Push oby/fix-ab12cd to deskree-inc/oby and open a draft pull request into dev.",
 "signedAt": "2026-10-09T22:01:07Z", "signature": "MEUCIQ…"}
```

- `signature`: ECDSA P-256 with SHA-256 (DER, base64) over the UTF-8 bytes of `"oby-publish\n<job id>\n<action>\n<signedAt>"`, made with the device's Secure Enclave key. The key's access control requires biometry (`.biometryCurrentSet`), so signing is what asks for Face ID.
- The runner checks:
  - the device is registered;
  - the signature;
  - `action` matches its own sentence exactly;
  - `signedAt` is within 2 minutes;
  - this signature hasn't been used before.
- Then it runs Publish: guards, the secret scan, push one pinned commit, draft pull request. It returns `{"url": "https://github.com/…/pull/42"}`, or an error line (for example the scan's findings, never the secret).

### `POST /v1/devices`

Registers the phone's publishing key, once per device:

```json
{"name": "Wellington's iPhone", "publicKey": "BJ3x…"}
```

`publicKey` is the P-256 public key, X9.63 (65 bytes, uncompressed), base64. It returns `{"id": "d7c1…"}`. Only the runner's owner can register (the tailnet header); the runner lists devices in its log.

### `GET /v1/settings/models` and `PUT /v1/settings/models`

Each tool's model and effort, as in `status.models`. `GET /v1/settings/models/options` lists the choices: Claude Code's models and efforts, and the models the signed-in Codex account offers (from its own `model/list`) with the efforts each takes.

```json
{"claude": {"models": [{"id": "claude-opus-5-5", "name": "Opus 5.5"}], "efforts": ["low", "medium", "high", "xhigh", "max"]},
 "codex": {"models": [{"id": "gpt-6-sol", "name": "GPT-6-Sol", "efforts": ["low", "medium", "high", "xhigh", "max", "ultra"]}]}}
```

## What the runner never does

- **Merge, force-push or push to main:** not for anyone, not even with an approval.
- **Publish without a fresh device signature:** no push, pull request, review or comment goes out otherwise.
- **Touch the user's credentials:** it never reads, stores or forwards agent credentials, and each tool signs in through its own login on the runner.
- **Read outside text as instructions:** text from GitHub or other people reaches agents only as quoted files.
