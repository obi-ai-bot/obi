# The Oby runner API

The runner is Oby's engine without the notch: the brain, Oby's own clones and job worktrees, the Claude Code and Codex runners, accounts, routing and Publish. It runs on an always-on machine (first: `tetrix-lab`, Ubuntu, on Wellington's tailnet), so the iPhone app (and later the Watch) can plan, dispatch and follow jobs while the Mac is closed.

This document is the contract between the runner and its clients. Change it in the same pull request as the code on either side.

## Reaching it

- **Base URL:** `https://tetrix-lab.tail8de49b.ts.net:8443` (the app lets you change it). Everything is under `/v1`.
- The runner listens on `127.0.0.1:7777` only. `tailscale serve --https=8443` publishes it on the tailnet with a real HTTPS certificate, so iOS needs no exceptions, and nothing is reachable from the internet. Port 443 on tetrix-lab belongs to the Tetrix stack's own proxy, so Oby uses 8443, one of the ports Tailscale serves HTTPS on.
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
  "published": null,
  "pushed": null,
  "publishError": null,
  "summaries": null,
  "issue": null,
  "rounds": 1,
  "round": 1,
  "check": null,
  "model": null,
  "notes": null
}
```

- `agent`: `claude` or `codex`. `account`: an account `id`. `kind`: `review`, `fix`, `build`, `test` or `investigate`.
- `status`: `queued`, `running`, `done`, `failed`, `stopped` or `interrupted`.
- `step`: what it's doing now, while queued or running. `summary`: the agent's final message; its first line is the one-line notice.
- A `build`, `fix` or `test` job that ends with no commits of its own is `failed`, and its `summary` starts with `Nothing committed: ` followed by the agent's first line.
- `base`: the branch the work started from (filled in once the job is ready). `pr`: the pull request it works on, if any.
- `commits`: commits made beyond `base` (set when a job ends as done).
- Publishing happens by itself. A job that ends `done` with commits not on its pull request (its check passed, or it has none) publishes before it ends, with no device signature: `step` is `"Publishing"` meanwhile.
  - It pushes the branch and opens a pull request into `base`, ready for review (never a draft), or pushes to the one already open.
  - The secret scan still gates it. A possible secret makes the job `failed`, and its `summary` starts with `Not published: possible secret in <file>:<line> (<rule>).` Nothing goes out, and it never says the secret. If the scanner can't run, nothing goes out either.
  - Any other failure (push, `gh`) leaves the job `done` with `publishError` set. Then Publish by hand is offered (`POST /v1/jobs/{id}/publish`).
- `published`: the pull request's URL once published. Show "Published".
- `publishError`: why the runner couldn't publish the job by itself, or null. Show it instead of "Published".
- `pushed`: how many of `commits` were on the pull request when it was last published, or null before then. A published job that ran again (`POST /v1/jobs/{id}/messages`) and ended `done` with new commits pushes them to the same branch by itself, so they land on the open pull request.
- `summaries`: every round's summary from the agent, oldest first, or null. The pull request's description quotes them all.
- What needs you: a job that's `done` with commits the runner couldn't publish (`publishError`), `failed` or `interrupted`. Say so where the apps would otherwise say nothing needs you.
- `issue`: the GitHub issue the work is about. The runner fetches it for the agent, which has no GitHub login, and the pull request says `Closes #N`.
- `rounds`: how many rounds the agent may take (1 means no loop); `round`: the one it's on.
- `check`: a one-line command that must succeed for the work to count as done.
  - After each round the runner runs it in the job's worktree. If it fails and rounds are left, the agent gets another round with the command's output.
  - Without a check and with more than one round, the agent's own last line decides: `GOAL MET`, or `GOAL NOT MET: …`, which means another round.
- `model`: a stronger model the user chose for this job, or null for the one in Settings › Models.
- `notes`: what the user told the agent along the way (`POST /v1/jobs/{id}/messages`), oldest first, or null.
- What to show: the title is `"<Kind> <repo name> #<number>"` when `pr` or `issue` is set, otherwise the first line of `request`. Show "Round 2 of 5" when `rounds` is above 1.

### Account

```json
{"id": "default", "agent": "claude", "name": "Personal", "label": "Max · well0cp@gmail.com",
 "signedIn": true, "fiveHour": 0.12, "sevenDay": 0.4, "running": 1}
```

`label` is what the tool says about the login (null while signed out). `fiveHour` and `sevenDay` are 0…1 or null when unknown. Accounts are signed in on the runner itself, through each tool's own login; the app only shows them.

### Draft

What the plan card shows before anything runs:

```json
{"said": "Review oby PR #33", "reply": "Oby will review PR #33 in oby.", "guessed": false, "job": { …Job, status "queued" },
 "suggestedModel": null}
```

`guessed` is true when the brain didn't answer and rules made the plan: say so on the card.

`suggestedModel` is a stronger model (`claude-fable-5-1` or `gpt-6-astra`) when the brain judged the work complex, else null. Offer it as an opt-in; for `gpt-6-astra` on an account whose label starts with "Plus", warn that it uses the plan's limits fast.

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
{"kind": "plan", "drafts": [ …Draft ], "draft": { …the first Draft }}
{"kind": "question", "said": "Review PR 12", "question": {"text": "Which repository is PR #12 in?", "options": ["deskree-inc/oby", "deskree-inc/blok"]}}
{"kind": "reply", "text": "Oby can't merge pull requests."}
{"kind": "none"}
```

Words that ask to stop work ("stop everything") stop every queued and running job right away, with nothing to confirm, and answer with a reply that counts them: `"Stopped 2 jobs."`, or `"Nothing is running."`.

One message can plan up to 10 jobs ("work on oby #12, #15 and #18", or "work on epic #30", which becomes one job per open sub-issue). Each draft is already routed to the least busy account; dispatch each with its own `POST /v1/jobs`. `draft` is kept for apps that know only one job.

### `POST /v1/jobs`

Dispatches the draft's job. The user may have changed:
- `branch`: it must stay a valid branch name.
- `account`: any signed-in account; `agent` follows the account.
- `rounds`: 1 to 10.
- `check`: one line of up to 200 characters, or `null` for none. Leaving it out keeps the plan's check, so to clear it send `"check": null` explicitly (Swift's encoder leaves nils out).
- `model`: `claude-fable-5-1` or `gpt-6-astra` to take the stronger model, or `null` (or left out) to stay on Settings › Models. It works only on a draft that came with a `suggestedModel`. The job runs the stronger model of the tool its account uses, so a Claude draft moved to a Codex account runs GPT-6-Astra. Any other model is refused.

Leave `rounds` or `check` out to keep the plan's values (older apps do). Everything else comes from the draft unchanged.

```json
{"job": { …the draft's Job }}
```

Returns the queued `Job` (`201`). `422` if the branch isn't valid or the account isn't signed in.

### `GET /v1/jobs?limit=50`

The latest jobs, newest first.

### `GET /v1/jobs/{id}`

One job.

### `GET /v1/jobs/{id}/wait`

Answers once the job has ended (`done`, `failed`, `stopped` or `interrupted`) with the `Job`, or right away if it already has. Until then it sends a space every 15 seconds to keep the connection open, so the body is the job's JSON after some whitespace. `404` for a job the runner doesn't know.

The iPhone app waits on this as a background download: iOS keeps it going while the app is suspended and wakes the app when it's answered, so the Live Activity can say how the job ended even on a runner without push (`POST /v1/activities`).

### `POST /v1/jobs/{id}/stop`

Stops a queued or running job. Returns the job (`status: "stopped"`).

### `POST /v1/jobs/{id}/messages`

Tells the job's agent something:

```json
{"text": "Also add a test for the empty case."}
```

- **Running:** the agent hears it now, in the turn under way or as the next one (Claude Code: another message; Codex: it steers the turn).
- **Finished** (`done`, `failed`, `stopped` or `interrupted`): the runner picks the agent's session up again in the same worktree and branch. The job keeps its `id`, goes back to `running` and gets a new `round`; when `rounds` is above 1 it grows by one too, so a loop still has a round for this. It ends as usual.
- The text is saved in `notes`, and `step` shows `"You: …"` until the agent moves on.

Returns the job. `404` for an unknown job. `422` when the text isn't 1 to 2,000 characters, or the job can't take it: still getting ready, wrapping up its only turn (try again once it's done), or never started (no `session`).

### `GET /v1/events`

Server-Sent Events, so the app stays live while it's open:

```
event: job
data: { …Job }

event: accounts
data: [ …Account ]
```

- A `job` event comes with every change: a new step, a status, the summary, `commits`, `published`, `publishError`. The app replaces the job with that `id`.
- `accounts` comes when sign-ins or usage change.
- A `: ping` comment every 15 seconds keeps the connection open. Reconnect after any drop, then refetch `GET /v1/jobs` to catch up.

### `GET /v1/jobs/{id}/publish`

What publishing this job by hand would do, in one sentence: for a job whose own publish failed (`publishError`). The app shows exactly this before asking for Face ID.

```json
{"action": "Push oby/fix-ab12cd to deskree-inc/oby and open a pull request into dev.", "base": "dev"}
```

Once the job is published and has new commits, the sentence is about them: `"Push the new commits on oby/fix-ab12cd to deskree-inc/oby, for its pull request into dev."`

`409` if there's nothing to publish (no commits, not done, or published with every commit).

### `POST /v1/jobs/{id}/publish`

Publishes by hand, for a job whose own publish failed, after the user approved on a registered device. The runner has no Touch ID, so the iPhone's Face ID stands in for it.

```json
{"device": "d7c1…", "action": "Push oby/fix-ab12cd to deskree-inc/oby and open a pull request into dev.",
 "signedAt": "2026-10-09T22:01:07Z", "signature": "MEUCIQ…"}
```

- `signature`: ECDSA P-256 with SHA-256 (DER, base64) over the UTF-8 bytes of `"oby-publish\n<job id>\n<action>\n<signedAt>"`, made with the device's Secure Enclave key. The key's access control requires biometry (`.biometryCurrentSet`), so signing is what asks for Face ID.
- The runner checks:
  - the device is registered;
  - the signature;
  - `action` matches its own sentence exactly;
  - `signedAt` is within 2 minutes;
  - this signature hasn't been used before.
- Then it runs Publish, as a job's own publish does: guards, the secret scan, push one pinned commit, then the pull request, ready for review (the one already open for the branch, if there is one). It returns `{"url": "https://github.com/…/pull/42"}`, or an error line (for example the scan's findings, never the secret).

### `POST /v1/devices`

Registers the phone's publishing key, once per device:

```json
{"name": "Wellington's iPhone", "publicKey": "BJ3x…"}
```

`publicKey` is the P-256 public key, X9.63 (65 bytes, uncompressed), base64. It returns `{"id": "d7c1…"}`. Only the runner's owner can register (the tailnet header); the runner lists devices in its log.

- A key the runner knows returns its id right away, so the app registers every time it connects.
- A new key needs pairing open: the owner runs `touch $OBY_HOME/pairing` on the runner's machine, and the phone registers within 10 minutes. That key uses it up. Otherwise `403` with that one line to show.
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

- `token`: the device token from `registerForRemoteNotifications`, in hex. `topic` and `environment` as for `/v1/activities`. The app sends it on every launch once notifications are allowed (it asks the first time a job is dispatched from the phone).
- It returns `{"push": true}` or `{"push": false}`, and `422`, as `/v1/activities` does.

Two seconds after a job changes, the runner sends an alert push (`apns-push-type: alert`, the app's bundle ID as topic, priority 10) for each job whose need changed. Nothing else notifies: steps, rounds, and jobs that end needing nothing (stopped, or done without commits) only move the Live Activity.

| The job | Title | Body | `category` |
|---|---|---|---|
| Done with commits it couldn't publish by itself | `Couldn't publish: <title>` | `publishError` (else the summary's first line) | `ready` |
| `failed` | `Failed: <title>` | the reason (the summary's first line) | `job` |
| `interrupted` | `Interrupted: <title>` | the reason | `job` |

```json
{"aps": {"alert": {"title": "Couldn't publish: Review oby #33", "body": "Couldn't push oby/review-33: the remote hung up."},
         "category": "ready", "sound": "default", "thread-id": "jobs"}, "job": "9f08fd10"}
```

- `job` is the job's `id`: tapping the notification opens it. The `ready` category offers **Publish** (it unlocks the phone and brings the app forward, where Face ID signs the approval as in the app) and **Open**; `job` offers **Open**.
- `apns-collapse-id` is the job's `id`, so a newer state replaces the older notification.
- When a job stops needing you (published, from the iPhone or the Mac, or running again after a message), the runner sends a background push (`apns-push-type: background`, priority 5), `{"aps": {"content-available": 1}, "clear": "<job id>"}`, and the app removes that job's notification. The app also removes them whenever it opens and sees the job needs nothing.
- The runner remembers what it last said for each job in `apns/notices.json`, so a restart doesn't say it again, and jobs a restart interrupted notify once it's back.

### `GET /v1/settings/models` and `PUT /v1/settings/models`

Each tool's model and effort, as in `status.models`. `GET /v1/settings/models/options` lists the choices: Claude Code's models and efforts, and the models the signed-in Codex account offers (from its own `model/list`) with the efforts each takes.

```json
{"claude": {"models": [{"id": "claude-opus-5-5", "name": "Opus 5.5"}], "efforts": ["low", "medium", "high", "xhigh", "max"]},
 "codex": {"models": [{"id": "gpt-6-sol", "name": "GPT-6-Sol", "efforts": ["low", "medium", "high", "xhigh", "max", "ultra"]}]}}
```

## What the runner never does

- **Merge, force-push or push to main:** not for anyone, not even with an approval.
- **Publish what didn't pass:** only a job that ended `done` (its check passed, or it has none), with a clean secret scan, is pushed and gets a pull request; by hand, only with a fresh device signature. No review or comment goes out.
- **Touch the user's credentials:** it never reads, stores or forwards agent credentials, and each tool signs in through its own login on the runner.
- **Read outside text as instructions:** text from GitHub or other people reaches agents only as quoted files.
