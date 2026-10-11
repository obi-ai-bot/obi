# The Oby runner API

The runner is Oby's engine without the notch: the brain and the Lead, Oby's own clones and job worktrees, the Claude Code and Codex runners, accounts, routing and Publish. It runs on an always-on machine (first: `tetrix-lab`, Ubuntu, on Wellington's tailnet), so the iPhone app (and later the Watch) can plan, dispatch and follow jobs while the Mac is closed.

This document is the contract between the runner and its clients. Change it in the same pull request as the code on either side.

## Reaching it

- **Base URL:** `https://tetrix-lab.tail8de49b.ts.net:8443` (the app lets you change it). Everything is under `/v1`.
- The runner listens on `127.0.0.1:7777` only. `tailscale serve --https=8443` publishes it on the tailnet with a real HTTPS certificate, so iOS needs no exceptions, and nothing is reachable from the internet. Port 443 on tetrix-lab belongs to the Tetrix stack's own proxy, so Oby uses 8443, one of the ports Tailscale serves HTTPS on.
- **Who you are:** `tailscale serve` adds `Tailscale-User-Login` to every request. The runner answers only its owner's login (set when it's installed) and returns `401` to anyone else. The app sends no token and stores no secret for this. The one exception is `/v1/agent/…`, which agents call from their sandbox on the runner itself (`oby-check apple`, Apple check below): those requests carry their job's token instead, `Authorization: Bearer <token>`, and answer nothing else.
- **JSON** everywhere, camelCase keys, dates as ISO 8601 strings (`2026-10-09T21:43:30Z`). Errors are `{"error": "One line a person can read."}` with a 4xx or 5xx status.
- **No vault secret** in an answer or an event: every string has the vault's secrets, plain or encoded, taken out. When the runner can't read its vault, answers are `503` with the reason, and events aren't sent.

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
  "outgoing": [],
  "question": null,
  "macCheck": null,
  "mergeError": null,
  "appleCheck": null,
  "appleRan": null,
  "mergeNeedsYou": false,
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
- `base`: the branch the work started from (filled in once the job is ready). `pr`: the pull request it works on, if any.
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
- `pushed`: how many of `commits` were on the pull request when it was last published, or null before then. A published job that ran again (`POST /v1/jobs/{id}/messages`) and ended `done` with new commits pushes them to the same branch by itself, so they land on the open pull request.
- `summaries`: every round's summary from the agent, oldest first, or null. The pull request's description quotes them all.
- `outgoing`: everything the runner sent out for the job, oldest first: the job's report lists it. Always a list, empty before anything went out. Each is `{"action": "push", "repo": "deskree-inc/oby", "id": "<commit>", "branch": "oby/fix-75", "date": "2026-10-09T22:01:40Z"}`; `action` is `push` (`id` the commit pushed, `branch` where), `pullRequest` (opened; `id` its URL), `pullRequestEdit` (its description brought up to date; `id` its URL), `comment` (Oby's review, or a Mac check's results, posted on the job's pull request; `id` the comment's URL) or `merge` (squash-merged into `dev` by the runner; `id` the pull request's URL, `branch` the branch it deleted). `branch` is present on pushes and merges only. More actions may come: show one you don't know as its `action` and `id`. Ids only, never what was sent; the runner's journal keeps one line per action, ids only too.
- What needs you: a job that's `done` with commits the runner couldn't publish (`publishError`), `failed` or `interrupted`, or one Oby's review requested changes on for the fourth time (`review`, below), unless it's dismissed. Say so where the apps would otherwise say nothing needs you.
- `dismissed`: when the user let the job go (`POST /v1/jobs/{id}/dismiss`), or null. A dismissed job needs nothing: it sends no alert, offers no Publish, and its `pipeline` shows Publish as `skipped` with the detail `Dismissed`. It stays in the list and in history. Telling it something (`POST /v1/jobs/{id}/messages`) clears `dismissed`.
- `issue`: the GitHub issue the work is about. The runner fetches it for the agent, which has no GitHub login, and the pull request says `Closes #N`.
- `rounds`: how many rounds the agent may take (1 means no loop); `round`: the one it's on.
- `check`: a one-line command that must succeed for the work to count as done.
  - After each round the runner runs it in the job's worktree. If it fails and rounds are left, the agent gets another round with the command's output.
  - A run of the check that takes more than 10 minutes is ended, and fails; its output ends with `Oby stopped it after 10 minutes, the most a test run may take.`
  - Test integrity: after the check, the runner compares both the job's commits (what Publish would send) and its worktree (what the check ran, uncommitted changes and new files too) with `startCommit` itself, not with a merge base, and fails the round when either clearly weakens the tests: it deletes a test file or moves one out of the tests, adds a skip marker (`.disabled(`, `.enabled(if:`, `XCTSkip`, `it.skip`, `@pytest.mark.skip`, `t.Skip(`, `#[ignore]`…), lowers the number of tests declared or of real assertions in a test file (one commented out or one that can't fail, like `#expect(true)`, doesn't count), adds a line to an existing test file that keeps the tests below it from running (a bare `return`, a block comment left open, `#if false`, `if (false) {`), touches test or CI config (`.github/workflows/`, `jest.config.*`, `pytest.ini`, `conftest.py`…), or changes the test settings in a build file (changes or removes a `.testTarget(…)` in `Package.swift`, however many lines it spans; changes a `test` script or the `jest`, `vitest`, `mocha`, `ava`, `c8` or `nyc` settings in `package.json`, compared as JSON so a value on a line of its own counts; changes pytest's settings in `pyproject.toml` or `setup.cfg`; skips tests or takes out a test target or plan in an Xcode scheme; excludes a test file from its target or takes it out of a target's sources in `project.pbxproj`). The diff ignores what the agent could set up to hide changes: no replacement objects (`refs/replace`) or grafts, no text conversion or external diff, binary files read as text, fixed `a/` and `b/` path prefixes, and `.gitattributes` read from `startCommit`. The agent's next round lists what's wrong, even when the command passed. When git can't say, the round fails too. Other edits to existing tests, and test files moved within the tests, don't fail it: a job that ends `done` says them in its `summary`, under `Changed in the existing tests, for review:`. New tests are fine.
  - Without a check and with more than one round, the agent's own last line decides: `GOAL MET`, or `GOAL NOT MET: …`, which means another round.
- `limit`: the limit the runner stopped the job at, or null. The runner holds every job to its limits itself; no prompt states them:
  - a round's turn may take 15 minutes (a turn the user's words start between rounds, while the check runs, too), a whole job 45 minutes (every round and check included);
  - Claude Code runs with `--max-turns 200`, which counts each message's turns, so each round's (checked with Claude Code 2.1.296); Codex has no such switch, so the timer alone holds it;
  - rounds run out (the Lead's jobs get 4: one attempt and three fix rounds);
  - no progress: the same failure twice in a row (the failing tests' ids, read from all of the check's output, plus its last 20 lines, with times, durations, addresses and ids taken out), or 3 actions in a row the runner denied.

  Such a job is `failed` with `limit` set (like `"the same failure twice in a row"` or ``"`swift test` still fails after 4 rounds"``), keeps its branch and pushes nothing. Its `summary` starts with `Stopped at a limit: <limit>. The branch is kept and nothing was pushed; one more round is possible.` and the notch says `Stopped at a limit: <title>`. One more round: its inbox item (kind `failed`) offers `One more round` instead of `Try again`, or `POST /v1/jobs/{id}/messages`; either clears `limit`. Stopping a job (or a limit stopping it) also ends a check that's still running. Older runners don't send this key.
- `startCommit`: the commit the work started from (the base on origin, or the pull request's head), recorded when the worktree is set up, or null before then and on older jobs. Test integrity compares with it: an agent can move a branch or a ref, not this. Older runners don't send this key.
- `model`: a stronger model the user chose for this job, or null for the one in Settings › Models.
- `notes`: what the user told the agent along the way (`POST /v1/jobs/{id}/messages`), oldest first, or null.
- `title`: what to call the job in rows, the job screen, the notch and alerts. It's the brain's short title (3 to 6 words, like `"Mac runner notifications"`), which every planned dispatch gets and the job keeps. Jobs without one (the rules' plans when the brain is down, an epic's sub-issue jobs, jobs from before titles) get `"<Kind> <repo name> #<number>"` when `pr` or `issue` is set, otherwise the first line of `task` (falling back to `request`), capped at 60 characters. It's always a string; older runners don't send it, so clients fall back the same way. Show "Round 2 of 5" when `rounds` is above 1.
- `files`, `lead` and `claim` are set on jobs the Lead started (below), null otherwise. `files`: the files or folders (ending in `/`) the job is expected to touch, relative to the repository, from the Lead's brief. `lead`: the goal (one Lead turn) that started it. `claim`: how the runner claimed the job's issue when the job started (`"Claimed: assigned to you, labeled status:in-progress, branch noted, moved to In progress."`), or what failed, null until then. Older runners don't send these keys.
- `question`: what the job's agent asked the user, `{"text": "Should a job that commits nothing end as failed, or get a new status?", "options": ["Failed", "A new status"]}` (`options` may be empty), or null. Agents are told to end their summary with `QUESTION: …` and optionally `OPTIONS: a | b` rather than bury a decision in their report; the runner reads those last lines when a turn ends. Markdown around the label (`**QUESTION:**`) is ignored; the question and its options keep every character, like `*.swift`. The job then waits for the answer: it stays `running` with `step` `"Waiting for your answer"`, its agent idle, and its round doesn't move on (no check runs). Other jobs keep going. The question lands in the inbox (below) and alerts the phone. The answer reaches the agent as its next message, exactly as `POST /v1/jobs/{id}/messages` would send it, and `question` goes back to null. Telling the job anything else answers it too; stopping it drops it. A job whose agent ends while its question waits (it exited, or the runner restarted) is `interrupted` and keeps `question`: nothing is checked or published until it's answered, and answering picks its session up again. Older runners don't send the key.
- A job whose `files` overlap an earlier queued or running job's in the same repository (the same path, or one inside a folder the other names) waits, queued, until that job ends: its `step` reads `Waiting for <title> (<id>): both touch <files>`. Then it starts by itself. Jobs without `files` (the brain's) never wait or block.

### Job pipeline and pull request following

Every job response (list, detail, dispatch, stop, message, wait, plan and `job` SSE event) includes `pipeline`, derived in Engine from the job's execution facts and last observed PR state. Clients render it instead of reconstructing stages from `step` text.

- `pipeline.stages`: ordered `prepare`, `work`, optional `check`, `publish`, `review`, `merged`. Each has `id`, `title`, `state`, optional `detail` and optional `reason`. States are `done`, `current`, `upcoming`, `failed`, `skipped`; every failed stage includes a reason. Check is absent when no check command is configured. Work includes the round and live agent step. Publish includes secret scan, push and PR creation progress.
- `pipeline.number` and `pipeline.total`: one-based position and count of displayed stages, including skipped ones. Display “Stage n of m”. The position is the first current/failed stage, otherwise the last completed/skipped stage. A completed investigation with no commits skips Publish, Review and Merged and reports 5 of 5. A failure/cancellation marks its execution stage failed with its reason and skips downstream stages.
- A done, published job progresses through Review: waiting (`current`), changes requested (`failed`, with reason), approved (`done`, with merge current). A merged PR completes Review (`Approved`, or `Merged without review` when GitHub has no review decision) and the final stage; a closed, unmerged PR fails Review and skips Merged. The merge title uses GitHub's actual base, normally “Merged into dev”. Running again shows Work before the earlier round's PR progress.
- `phase` (optional): persisted execution phase `prepare`, `work`, `check` or `publish`. `publishStep` (optional): `scan`, `push` or `pullRequest`. These are execution facts, not separate client derivation rules. Older saved jobs have neither; Engine derives their best available progress.
- `pullRequest`: null until a successful read, otherwise `{"state":"OPEN","reviewDecision":"REVIEW_REQUIRED","base":"dev","mergedAt":null,"checkedAt":"2026-10-09T21:43:30Z"}`. State is `OPEN`, `CLOSED` or `MERGED`; review decision is `REVIEW_REQUIRED`, `CHANGES_REQUESTED`, `APPROVED`, or absent/null (no decision yet). `mergedAt` is present only after a merge. All dates are ISO 8601.
- The runner polls published PRs on startup and every three minutes while open/unknown, using its own `gh pr view` outside the agents' sandbox. It follows `published`, not the input `pr`, including saved jobs older than the latest 50. Closed and merged PRs stop polling. Fresh saved observations wait for the next interval after restart.
- `pullRequestError`: null after a successful refresh; otherwise a short retry message. Network/authentication/JSON failures preserve the last successful observation and retry at the next interval. `checkedAt` remains the date of that last success. Updates are saved and sent as `job` events without overwriting a concurrent agent step or resumed round.
- Following is read-only: it never posts a review, pushes, or merges (merging is the Mac check's, below). [`gh pr view` JSON fields](https://cli.github.com/manual/gh_pr_view) supply only typed status data; GitHub prose never enters an agent prompt.
- Older clients ignore these additive fields. New clients accept an absent pipeline from an older runner and show its ordinary status/step instead.

### Oby's review

When a job publishes (or pushes new commits to its pull request), the runner has the pull request reviewed by one of its own jobs, on a different account than the author's: it prefers the other tool (Claude Code reviews Codex's work, Codex reviews Claude Code's), takes only an account that's signed in with room on its limits (under 95% of its 5-hour window and under 80% of its weekly one, which keeps the rest for jobs the user sends to it by name), and runs it on that account's model from Settings › Models. With no such account, nothing reviews and `reviewError` says so.

- **The review job** is an ordinary `Job` in the list and the event stream: `kind` `review`, `pr` the published pull request's number, `branch` like `oby/review-80`, `task` the author's task, and `reviewOf` the author job's `id` (null on every other job). It reads the diff and the author's task, makes no commits and never publishes. Its `summary` is the review; its last line is the verdict (`VERDICT: APPROVED` or `VERDICT: CHANGES REQUESTED`).
- **On the author job:** `reviewing` is the review job's `id` while it runs, else null. `review` is Oby's latest verdict, or null:

  ```json
  {"verdict": "approved", "job": "3c9d1e20", "agent": "codex", "account": "Work", "round": 1,
   "date": "2026-10-09T22:04:11Z", "comment": "https://github.com/deskree-inc/oby/pull/80#issuecomment-1", "postError": null}
  ```

  `verdict` is `approved` or `changesRequested`; `job` the review job; `agent` and `account` the reviewer's tool and account name; `round` which of Oby's reviews of this pull request it is (1 to 4); `comment` the pull request comment it was posted as, or null with `postError` saying why it wasn't (a possible secret in the review, or `gh` failing). `reviewError` says why no review ran or none gave a verdict (no account with room, the reviewer failed, was stopped or interrupted, or gave no verdict), else null.
- **The comment.** GitHub doesn't let the user approve or request changes on their own pull request, so the runner posts the review as a regular comment, after the secret scan like everything outgoing, headed `### Oby review · Claude Code · Personal: Approved` (or `Changes requested`), the review itself in a code block, and a `by Oby` line. The secret scan gates it, with the same rules and encoded copies as publishing: a possible secret means no comment, and the verdict still counts. A posted comment is listed in the author job's `outgoing`.
- **The Review stage** shows GitHub's decision when it has one, else Oby's: `Oby is reviewing` (current), `Approved by Oby` (done, with Merged following the Mac check, below), or `Changes requested` (failed, reason `Oby requested changes.`). A failed review leaves it current with `Waiting for review · <reviewError>`. A merged pull request with no GitHub decision reads `Approved by Oby` or `Oby requested changes` instead of `Merged without review`.
- **Changes requested** go to the author's agent as its next round, in the same session and worktree: the review is quoted in a file (`.oby/inputs/review-<round>.md`), never pasted into the prompt. The job goes back to `running` with a new `round` (and one more on `rounds`, as a message does), `step` `Working on Oby's review`, and ends as usual: when its check passes and it publishes the new commits, the review runs again. At most 4 reviews per job; when the fourth requests changes, the job stays `done`, needs you (`reviewNeedsYou`, below), and the runner reviews it no more, even after you talk to it.
- **Approved:** the commit the reviewer read is checked on the user's Mac, and the runner merges it into `dev` when that passes (below).
- What needs you now also includes a `done`, published job whose `review` is `changesRequested` with `round` 4 while the pull request is open, and one whose merge stopped (`mergeNeedsYou`, Mac check below). Say so where the apps list what needs you ("1 job needs your review").

### Mac check

GitHub Actions doesn't run for deskree-inc/oby, so the user's Mac checks a pull request before the runner merges it (#66). Only the runner queues checks: on the Mac's own Oby, an approved job's Merged stage reads `Ready to merge`, for a person. When Oby's review approves a job's pull request, the runner queues a check of the commit the reviewer read, when that's still the commit the runner last pushed to the pull request. A Mac running Oby that follows the runner, with Settings › Runner › "Run merge checks on this Mac" on (the default), takes it, runs it and reports the result.

```json
{"id": "c0ffee12", "job": "9f08fd10", "repo": "deskree-inc/oby", "pr": 80, "branch": "oby/fix-75", "base": "dev",
 "head": "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b", "round": 1, "state": "failed",
 "created": "2026-10-11T09:00:00Z", "started": "2026-10-11T09:00:02Z", "finished": "2026-10-11T09:14:40Z", "mac": "Studio",
 "steps": [{"name": "Runner tests (swift test)", "passed": true, "seconds": 125},
           {"name": "Mac app and MacTests", "passed": false, "seconds": 301},
           {"name": "iPhone app with Watch, and iOSTests", "passed": true, "seconds": 412}],
 "failures": ["MacTests.PublishTests/blocksASecret()"],
 "comment": "https://github.com/deskree-inc/oby/pull/80#issuecomment-2", "postError": null}
```

- `kind`: `merge` (this section) or `apple` (an agent's Apple check, below). Always sent; checks from before Apple checks are `merge`.
- `job`: the author job. `head`: the commit checked. `round`: which of the job's checks it is (1 to 3).
- `state`: `queued`, `running` (a Mac took it: `mac` is the name it gave, `started` when), `passed`, `failed`, or `error`: the Mac couldn't run it, and `problem` says why (its checkout or the vault failed, a tool or the simulator is missing, xcodebuild failed other than with a failing build or test, or a step was stopped at its timeout without naming a failing test). An `error` is nothing the code can fix: no comment is posted, nothing goes to the author, it needs you, and Try again checks the same commit again. `handedOff` is true once a failed check's tests went to the author as a round. `steps` and `failures` (the failing tests' names) come with the result; `comment` is the pull request comment with the results, or null with `postError` saying why there's none.
- **On the Mac:** a clean worktree of `head`, detached, in Oby's own clone, then, one at a time and each with a timeout: `swift test` (30 minutes), the `Oby` scheme's build with `MacTests` (30 minutes), and the `ObyPhone` scheme (with `ObyWatch` embedded) with `iOSTests` on an iPhone 17 simulator (40 minutes), all signed ad hoc as docs/ci.md describes. Every step runs, so a failing check names everything that fails. A step writes to a file, not a pipe; at its timeout its whole process group is ended (TERM, then KILL), and the Mac stops waiting on it a few seconds later whatever is left, so a hung test can't keep the Mac busy. The commands get no GitHub login and no variable holding a vault secret, and a throwaway `OBY_HOME` (also as `TEST_RUNNER_OBY_HOME`, which xcodebuild hands to the test host without the prefix), so the MacTests host, an Oby itself, never opens the Mac's own `oby.sqlite` or marks its running jobs interrupted. They still run with the user's access to the Mac: Oby's review is the gate before pull request code runs there. The worktree is removed afterwards; build caches are kept between checks.
- **On the author job:** `macCheck` is the latest check, null before one; besides the keys above it may carry `tries` (merge attempts since it passed) and `transient` (the last attempt failed on something that may pass later). `mergeError` says why Oby couldn't check or merge the pull request, or null. `mergeNeedsYou` (always sent, derived by the runner) is true when the merge stopped where a person takes over (below).
- **The comment.** The runner posts the results on the pull request, after the secret scan: `### Oby Mac check · Studio: Passed` (or `Failed`), a table of the steps with their times, the failing tests in a code block, and a `by Oby` line. Never the build's output. It's listed in the job's `outgoing`. Results for a commit the job moved on from (it ran again, or pushed since) are kept on `macCheck` but not posted, and change nothing else.
- **Passed:** the runner merges when all of these hold: Oby's review approved, the check passed on the commit the pull request has (`head` is the last commit pushed, nothing unpushed), the pull request is open with no change request on GitHub, its base is `dev`, and the secret scan of what the merge lands (every commit not on `dev`, and their files, as publishing scans them) is clean. It reads the pull request from GitHub once more (open, into `dev`, `head` as its head), then `gh pr merge --squash --delete-branch --match-head-commit <head>`. The merge is listed in `outgoing`, `pullRequest` becomes `MERGED` and the Merged stage completes. Anything that fails leaves the job unmerged, with `mergeError` saying why (`Not merged: possible secret in README.md:3 (AWS access key).`). Never into `main`.
- **Recovery.** When the runner starts, and every five minutes, it finishes again a passed check whose pull request isn't merged: one it never finished (it stopped while posting the results or merging), and one whose last attempt failed on `gh`, the network or a scan that couldn't run, up to 3 attempts. A possible secret or a refusal isn't tried again by itself. A failed check with rounds left whose round for the author never started (the runner stopped before or after posting the results) goes on to its comment, when it has none, and the round.
- **Failed:** the failing tests go to the author's agent as its next round, in the same session and worktree, quoted in a file (`.oby/inputs/mac-check-<round>.md`, with each step's result and the end of what the failing steps printed), never in the prompt. The job goes back to `running` with a new `round` and `step` `Working on the Mac check`; when it publishes the fix, Oby reviews it again, and an approval queues the next check. After the third failed check, or when Oby's reviews are used up (its 4th review was the one that approved, so a fix could never be reviewed), no round starts: the job stays `done` and the Merged stage says so. A round that ends with no new commit leaves the failed check on the pull request's head: that needs you too, and Try again checks the same commit again (as the same round).
- **What needs you:** a merge that stopped, while the pull request is open, Oby's review approved the checked commit and the job isn't dismissed: `mergeError` set after the check, a check the Mac couldn't run (`error`), a failed check with no round left, or one whose round brought no new commit. It counts in what needs you, sends an alert (`Not merged: <title>`) and brings a `merge` inbox item.
- **The Merged stage** while Oby's review approved it: `Waiting for a Mac check` (`current`), `Checking on Studio` (`current`), `Mac check passed · merging` (`current`), `Mac check failed` (`failed`, reason like `1 test failed on Studio: MacTests.PublishTests/blocksASecret()`, plus `The Mac check failed 3 times. Take it from here.` after the third), `Mac check couldn't run` (`failed`, reason `problem`), `Not merged` (`failed`, reason `mergeError`), then `done` once merged. Before a check is queued, and wherever none is (the Mac's own jobs, older ones), `Ready to merge`.

### Apple check

Agents run on the runner, which has no Xcode, so an agent that changes the Apple apps asks the user's Mac to build and test them mid-round (#118): `oby-check apple` in its sandbox. The runner queues an Apple check of the job's worktree commit (`HEAD`), a Mac check (above) with `kind` `apple`; a Mac that follows the runner with Settings › Runner › "Build and test agents' work on this Mac" on (the default) takes it before any merge check, fetches its commits from the runner (`GET /v1/checks/{id}/bundle`: they aren't on GitHub yet), and runs the `Oby` scheme with `MacTests` and the `ObyPhone` scheme (with `ObyWatch`) with `iOSTests`, as a merge check does, without `swift test` (the agent runs that on the runner). Same clean worktree, timeouts, ad hoc signing, throwaway `OBY_HOME` and no GitHub login or vault secret. Paths in what the failing steps printed are relative to the repository.

- **On the job:** `appleCheck` is the job's latest Apple check, or null. `appleRan` is the latest one that ran (`passed` or `failed`), or null: it stays when the agent asks for a newer commit, so a newer check that can't run never hides one that did. `pr` is the job's pull request, or 0 before it has one; `round` counts the job's Apple checks (at most 20 per job). Nothing is posted on GitHub, merged or handed to another round: the result is for the agent waiting on it, and for the reviewer (Oby's review, below). What the failing steps printed is kept in memory only, for the agent and the reviewer, for the job's latest check and the latest that ran.
- **Asking again** for the same commit picks up the same check (or its result), unless it couldn't run. A new commit is a new check; the old one's result, if a Mac still sends it, is answered `404`.
- **Who takes it:** only a job that's running (`queued` or `running`) and only from a Mac that says it takes Apple checks (`kinds`, below). A Mac running another check finishes it first.
- **No Mac:** a check no Mac took within a minute while no Mac was busy, or within an hour at all, is `error` with `problem` saying so, and the agent is told to carry on and say in its summary that the Apple apps weren't built.
- **Security:** the Mac runs the agent's code (its build phases and tests) before Oby's review has read it, with the user's access to the Mac. The setting turns it off; a merge check still needs the review.
- **Reviews:** when a job's pull request is reviewed, the reviewer gets the latest Apple build and test that ran (passed or failed), the job's Apple check (`appleCheck`, else `appleRan`) or its merge check, whichever ended last, quoted in `.oby/inputs/apple-check.md` with its commit (and whether it's the pull request's head), its steps, failing tests and, for an Apple check, the end of what the failing steps printed. It's told not to request changes because the code wasn't compiled.

### Inbox item

Something only the user can answer (docs/pipeline-cases.md, "Your inbox"). Like email, it waits for them with no timeout, and its job waits too; the others keep going.

```json
{"id": "ab12cd34-question-0", "kind": "question", "job": "ab12cd34", "title": "Nothing committed status",
 "text": "Should a job that commits nothing end as failed, or get a new status?", "options": ["Failed", "A new status"],
 "created": "2026-10-10T09:12:00Z", "done": null, "later": null, "answer": null, "state": "open"}
```

- `kind`, and what each offers in `options`:

  | `kind` | Comes when | `text` | `options` |
  |---|---|---|---|
  | `question` | the job's agent asked (`question` on the job) | the question | the agent's, possibly none |
  | `review` | Oby's fourth review requested changes (`reviewNeedsYou`) | `Oby requested changes 4 times. Take it from here.` | `One more round`, `Dismiss` |
  | `failed` | the job ended `failed` or `interrupted` | the summary's first line | `Try again`, `Dismiss` (only `Dismiss` for a job that never started) |
  | `limit` | the job failed because its account hit its usage limit and no other had room | the summary's first line | `Try again`, `Dismiss` |
  | `merge` | Oby's merge stopped (`mergeNeedsYou`, Mac check below) | `mergeError`, or why the check failed and that a person takes it from here | `Try again` and `Dismiss` when it couldn't merge (merge again, or hand the check to the author again), when the Mac couldn't run the check, or when the round brought no new commit (check the same commit again); only `Dismiss` after the last failed check |

  More kinds will come (permissions, hands-on steps): show one you don't know with its `text` and `options`.
- `job`: the job's `id`. `title`: the job's `title` when the item came.
- `created`: when it came. Apps list the open ones longest-waiting first, with how long each has waited ("waiting 3m").
- `done`: when it was settled, or null. `answer`: what the user answered, or null (done without an answer, or settled by itself).
- `later`: put off until then, or null. `state`: `open`, `later` (put off until a time still to come) or `done`. Apps show a `later` item again once its time has passed.
- An item comes once: each failure (even a retry that fails again within the same second), each question and each fourth review has its own `id`, and one that's done never comes back. It's done by itself, with no `answer`, when its job needs it no more: the job runs again (told something, or Try again from either app), was dismissed or stopped, or its question was answered with a message.
- Kept in `oby.sqlite` with the jobs, so a restart keeps the inbox, and the runner loads the job of every open item however old it is (and, for a `review` item, its review), so it can still be answered. A job's own alert (below) still says it needs you; the inbox is where you answer.

### Account

```json
{"id": "default", "agent": "claude", "name": "Personal", "label": "Max · well0cp@gmail.com",
 "signedIn": true, "fiveHour": 0.12, "sevenDay": 0.4,
 "fiveHourResets": "2026-10-10T02:14:40Z", "sevenDayResets": "2026-10-14T19:27:22Z", "running": 1, "fullUntil": null}
```

- `label` is what the tool says about the login (null while signed out). Its first part is the plan (`Max`, `Team`, `Plus`), which Settings shows next to the account's name.
- `fiveHour` and `sevenDay` are 0…1 or null when unknown. An account with both null hasn't reported usage yet: Claude Code's limits arrive with its first job, Codex's when the runner asks its app-server.
- `fiveHourResets` and `sevenDayResets`: when each window resets, or null when the tool didn't say. Claude Code sends them in its `rate_limit_event` (`resetsAt` per window), Codex in `account/rateLimits/read` and its `account/rateLimits/updated` notifications (`resetsAt`). A window keeps its last reset time until the tool sends a new one. Older runners don't send these keys.
- `running`: jobs queued or running on the account.
- `fullUntil` is set while a job of the account's hit its usage limit: no job goes to it before then. Accounts are signed in on the runner itself, through each tool's own login; the app only shows them.

Accounts are signed in on the runner itself, through each tool's own login; the app only shows them. Settings shows one card per account, grouped by tool, with a bar per window, its reset time, and the running count.

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
 "models": {"claude": {"model": "claude-opus-5-5", "effort": "xhigh"}, "codex": {"model": "gpt-6-sol", "effort": "high"}},
 "clearedAt": "2026-10-10T08:12:00Z"}
```

`clearedAt` is when Clear done was last pressed, on any app (`POST /v1/clear`), or null when it never was. Every app hides the jobs that finished at that second or before (`finished` not after `clearedAt`); running jobs, and finished ones that ran again since, stay. Older runners don't send the key.

### `POST /v1/clear`

Clear done, on the iPhone or the Mac: the runner records now, on its own clock, as the last clear, and answers it. It keeps every job; only the apps' lists change, and the same way on each, so clearing on one clears on both. No body.

```json
{"clearedAt": "2026-10-10T08:12:00Z"}
```

Every app following `GET /v1/events` gets a `clear` event with the same body, and `GET /v1/status` says the time from then on. The clock never goes back: a clear earlier than the last one keeps the later time.

### `POST /v1/plans`

One turn of the conversation with Oby: words become a plan, a question, or an answer in words. Takes 3–20 seconds (the brain thinks); show Oby thinking, with a way to cancel, and let a new message replace the one under way.

```json
{"said": "Review oby PR #33"}
```

To answer the brain's question, send the original words with the answer:

```json
{"said": "Review PR 12", "answer": {"question": "Which repository is PR #12 in?", "option": "deskree-inc/oby"}}
```

**The brain answers with context.** Before the user's words it reads a briefing the runner builds: the conversation so far, the jobs (running, needing the user, in review, finished or merged in the last two days, with their titles and stages), the inbox and each account's usage. So it answers questions about the work ("how are the jobs going?", "what did the #12 job change?", "how long until Codex resets?") as a `reply`, and reads follow-ups ("and the vault one?", "cancel it"). The briefing holds only what the user and Oby said and what the runner knows; what agents wrote (a job's result and current step, an inbox question and its options, a failure's reason) reaches the brain as a quoted file it may read, never in a prompt, as every other outside text does. The typed plan is still checked in Swift. A plan acts once it's made: the runner can't tell a client that gave up waiting from a slow one, so an app that lets the user cancel a turn only drops the answer, and a stop the turn asked for still happens.

Bare cancel words ("never mind", "stop", "cancel", "forget it") never reach the brain: the answer is `none`, and nothing stops. Stopping work takes a job's name or "stop everything".

The conversation so far is the runner's own, the last 50 turns, kept in `oby.sqlite`. An app that shows its own thread sends it instead, oldest first; `who` is `user` or `oby`, `text` 1 to 2,000 characters, at most 50 turns (`422` otherwise). Either way the new exchange joins the runner's conversation.

```json
{"said": "and the vault one?",
 "turns": [{"who": "user", "text": "how is the inbox job going?"},
           {"who": "oby", "text": "Inbox on the Mac is at its check, round 2 of 4, running swift test."}]}
```

The answer is one of:

```json
{"kind": "plan", "drafts": [ …Draft ], "draft": { …the first Draft }}
{"kind": "question", "said": "Review PR 12", "question": {"text": "Which repository is PR #12 in?", "options": ["deskree-inc/oby", "deskree-inc/blok"]}}
{"kind": "reply", "text": "Oby can't merge pull requests."}
{"kind": "none"}
```

Words that ask to stop work stop jobs right away, with nothing to confirm, and answer once they have, with a reply saying what stopped. "Stop everything" or "stop all jobs" stops every queued and running job: `"Stopped 2 jobs."`, or `"Nothing is running."`. "Cancel it" or "stop the vault job" stops the job the conversation is about, by its id from the briefing: `"Stopped Vault secrets."`, or `"That job isn't running any more."`. The brain's plan says which (the jobs by id, or everything in so many words), and Swift refuses a stop that says neither; a stop that names no job while several run is answered with a question (which one, or everything?) or `"Say which job to stop, or “stop everything”."`. (On the Mac, whose brain also sees the runner's jobs, inbox and accounts, both reach the runner's jobs through `POST /v1/jobs/{id}/stop`, and a job the runner couldn't stop is said so: `"Couldn't stop Watch home: …"`.)

One message can plan up to 10 jobs ("work on oby #12, #15 and #18", or "work on epic #30", which becomes one job per open sub-issue). Each draft is already routed to the least busy account; dispatch each with its own `POST /v1/jobs`. `draft` is kept for apps that know only one job.

#### The Lead: vague goals

A vague goal, like "work on the roadmap", "Obi, next issue", "pick the next open issues" or anything naming the roadmap, the board or the backlog, goes to the Lead instead of the brain (when a Claude account is signed in). Words that stop work ("stop working on the roadmap") stay with the brain, which stops the jobs. The Lead is a fresh Claude Code turn on Sonnet 5.5 (the model the spike proved), with only Read, Grep and Glob, boxed like a job. It takes 6 to 20 seconds. Before each turn the runner:

- reads the GitHub project **Oby — Roadmap** with its own `gh` login: the open issues in board order, each with its status column, labels, milestone, assignees and the open pull requests that close it;
- builds the **skipped list** itself, never trusting the Lead's: done, in review, `status:needs-test`, blocked, `oby:skip`, assigned to someone else, a queued or running Oby job on it, or an open pull request (the board's, or one Oby published for it);
- writes `.oby/context/roadmap.md` (the board with the runner's verdict on every row, workable or why it's skipped) and `.oby/context/jobs.md` (the runner's running and recent jobs, with the files each expects to touch) where the Lead reads them.

The Lead answers one typed plan, checked in Swift and retried once with the reasons: `start_jobs` (one brief per job: repository, issue, kind, title, goal, the files it will touch, a one-line check and what's out of scope), `reply`, or `ask_user`. No push, merge, approve or publish action exists. A brief is refused unless its issue is one the board lists as workable: a skipped issue is refused with its reason, and a closed, made-up or off-board issue is refused too (Oby would claim it on GitHub). So the same request twice starts nothing new.

The jobs start right away, with no Dispatch tap, each routed to the signed-in account with the most room (the picks spread out, as a plan's drafts do), with 4 rounds (one attempt and three fix rounds) and the brief's check. Right before each job starts, the runner checks the live jobs again: an issue that got a queued or running job while the turn ran (the same request from the Mac and the iPhone at once, or repeated after the app gave up waiting) starts nothing new, and the reply says so. The answer is a `reply`: `"Started 2 jobs: Safe when nobody watches (#7), Watch first slice (#12). Skipped 8 on the board."`, and the jobs arrive as `job` events and in `GET /v1/jobs` with `files`, `lead` and, once each starts, `claim`. When nothing can start, the reply says why (every issue skipped or taken, the board unreadable, no account with room, or the Lead's plans refused twice). A `question` is answered as the brain's is. The runner keeps the last 20 goals' context folders.

When a job of the Lead's starts, the runner **claims its issue** with its own `gh` login: assigns it to you, adds `status:in-progress`, comments the branch name (`Oby is working on this on the branch `oby/build-7` (job ab12cd34).`, written by the runner, never by an agent), and moves the item to **In progress** on the board. Each step that fails is said in `claim`; the rest still happen.

Every Lead turn is logged on the runner (the words, the plan or why it was refused, the skipped list, the jobs started) and kept in `oby.sqlite` with the brain's turns.

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

One job, however old: fetch it when an inbox item or a notification names a job that isn't in `GET /v1/jobs`'s latest 50.

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

### `POST /v1/jobs/{id}/messages`

Tells the job's agent something:

```json
{"text": "Also add a test for the empty case."}
```

- **Running:** the agent hears it now, in the turn under way or as the next one (Claude Code: another message; Codex: it steers the turn).
- **Finished** (`done`, `failed`, `stopped` or `interrupted`): the runner picks the agent's session up again in the same worktree and branch. The job keeps its `id`, goes back to `running` and gets a new `round`; when `rounds` is above 1 it grows by one too, so a loop still has a round for this. A dismissed job is dismissed no more. It ends as usual, except that this round may end `done` with nothing committed: your words decide what it should do.
- The text is saved in `notes`, and `step` shows `"You: …"` until the agent moves on.

Returns the job. `404` for an unknown job. `422` when the text isn't 1 to 2,000 characters, or the job can't take it: still getting ready, wrapping up its only turn (try again once it's done), or never started (no `session`).

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
```

- A `job` event comes with every change: a new step, a status, the summary, `commits`, `published`, `publishError`, `pipeline`, `pullRequest`, `pullRequestError`, `dismissed`, `macCheck`, `mergeError`, a move to another account. The app replaces the job with that `id`.
- `accounts` comes when sign-ins, usage, reset times, running counts or `fullUntil` change.
- `clear` comes when Clear done is pressed on any app (`POST /v1/clear`): hide the jobs that finished by `clearedAt`.
- `inbox` comes with every inbox item that arrives or changes: answered, done or put off, on any app, or settled by itself. Replace the item with that `id`; one whose `state` is `done` leaves the inbox.
- `check` comes when a Mac check or an Apple check (below) is queued, taken by a Mac or ends. A Mac that runs checks asks for one (`GET /v1/checks/next`) when one is `queued`; other apps can ignore it, since the job's own event carries `macCheck` and `appleCheck` too.
- A `: ping` comment every 15 seconds keeps the connection open. Reconnect after any drop. Fetch what you show (`GET /v1/status`, `GET /v1/jobs`, `GET /v1/inbox`; a runner older than the inbox answers `404` there, which means an empty inbox, and any other failure means try again) only once the events' response has arrived, and apply the events that came meanwhile over it: the runner follows a connection before it answers, so nothing that changes in between is lost.

### `GET /v1/inbox`

The inbox items not yet done, the longest-waiting first, items put off `later` included (say so, or hide them until their time).

```json
[{"id": "ab12cd34-question-0", "kind": "question", …InboxItem}]
```

### `POST /v1/inbox/{id}/answer`

Settles an item, on the iPhone or the Mac. The body is exactly one of:

```json
{"answer": "A new status"}
{"done": true}
{"later": "2026-10-10T10:12:00Z"}
```

- `answer`: one of its `options`, or the user's own words (1 to 2,000 characters). It goes to the job:
  - `question`: the answer is the agent's next message (as `POST /v1/jobs/{id}/messages`): a waiting job goes on, an ended one picks its session up again.
  - `Dismiss` (on `review`, `failed`, `limit` and `merge`): dismisses the job (`POST /v1/jobs/{id}/dismiss`).
  - `Try again` (on `merge`): the merge is tried again, or the Mac check is handed to the author again or queued again on the same commit (Mac check, above).
  - `Try again` (on `failed` and `limit`): the job runs again in its session, told to pick up where it left off.
  - `One more round` (on `review`): Oby's last review is quoted in `.oby/inputs/review-4.md` and the agent works on it, as a message does. The runner doesn't review it again.
  - Other words: sent to the job as a message.
- `done`: settled without an answer; the job is left as it is.
- `later`: put off until that time (ISO 8601).

Returns the item. `404` for an item the runner doesn't know, `409` when it's done already, `422` for a body that isn't exactly one of these, a `later` that isn't a date, an empty or too-long answer, or a job that can't take it (the same reasons as `POST /v1/jobs/{id}/messages`). Every app following events hears the item (`inbox`) and its job (`job`).

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

### `GET /v1/checks/next?mac=Studio&kinds=merge,apple`

For a Mac that runs checks. Answers `{"check": { …Mac check }}` with the oldest queued check, now `running` and that Mac's (`mac` is the query's name, up to 100 characters, or `a Mac`), or `{"check": null}` when none waits. `kinds` lists what the Mac takes, `merge`, `apple` or both; without it, merge checks only (Macs from before Apple checks). Apple checks come first: an agent waits on them. A merge check whose job runs again or pushed a newer commit isn't handed out, nor an Apple check whose job ended. A Mac that took a check and reported nothing for 2 hours went away: the next Mac to ask gets it again. Ask when a `check` event says one is `queued`, on every (re)connection, and every 10 minutes.

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

- `problem` (optional): why the Mac couldn't run the check (one line, up to 500 characters). With it, the check is `error`, whatever else the result says.
- A pass counts only when every step the Mac runs (`Runner tests (swift test)`, `Mac app and MacTests`, `iPhone app with Watch, and iOSTests`; for an Apple check, the last two) is in `steps` and passed, and `failures` is empty. A failing test name fails the check; a pass that leaves out a step, or a failure that names nothing that failed, is the Mac's problem (`error`).
- `log` (optional): the end of what the failing steps printed. It goes to the author's agent only (and, for an Apple check, its reviewer), with the vault's secrets taken out; it's never stored or posted.
- The runner keeps at most 10 steps, 50 failing tests (each one line of up to 300 characters) and 8,000 characters of `log`. A failed step, or no steps, fails the check whatever `passed` says.
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

`oby-check apple [--wait SECONDS]` asks, prints `line` when it changes, polls every 5 seconds, and prints `report`. `--wait` (1 to 3,000; 110 by default, under a 2-minute command timeout) bounds the whole wait, the requests to the runner included: a request still unanswered at the deadline is dropped. It notes uncommitted changes, which aren't in the check. Exit status: `0` passed, `1` failed, `2` couldn't run (no Mac, the Mac's problem, no runner), `3` still running (run it again: it picks up the same check), `64` a wrong command line. Jobs whose Lead brief names `iOS/`, `Watch/`, `Mac/` or `Shared/`, or, without a brief, in a repository that has them, are told about it in their prompt.

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
| Oby's fourth review requested changes | `Changes requested: <title>` | `Oby requested changes 4 times. Take it from here.` | `job` |
| Its agent asked a question (`question`), which waits in the inbox | `Question: <title>` | the question | `job` |

```json
{"aps": {"alert": {"title": "Couldn't publish: Review oby #33", "body": "Couldn't push oby/review-33: the remote hung up."},
         "category": "ready", "sound": "default", "thread-id": "jobs"}, "job": "9f08fd10"}
```

- `job` is the job's `id`: tapping the notification opens it. The `ready` category offers **Publish** (it unlocks the phone and brings the app forward, where Face ID signs the approval as in the app) and **Open**; `job` offers **Open**.
- `apns-collapse-id` is the job's `id`, so a newer state replaces the older notification.
- When a job stops needing you (published, from the iPhone or the Mac, dismissed, or running again after a message), the runner sends a background push (`apns-push-type: background`, priority 5), `{"aps": {"content-available": 1}, "clear": "<job id>"}`, and the app removes that job's notification. The app also removes them whenever it opens and sees the job needs nothing.
- The runner remembers what it last said for each job in `apns/notices.json`, so a restart doesn't say it again, and jobs a restart interrupted notify once it's back.

### `GET /v1/settings/models` and `PUT /v1/settings/models`

Each tool's model and effort, as in `status.models`. `GET /v1/settings/models/options` lists the choices: Claude Code's models and efforts, and the models the signed-in Codex account offers (from its own `model/list`) with the efforts each takes.

```json
{"claude": {"models": [{"id": "claude-opus-5-5", "name": "Opus 5.5"}], "efforts": ["low", "medium", "high", "xhigh", "max"]},
 "codex": {"models": [{"id": "gpt-6-sol", "name": "GPT-6-Sol", "efforts": ["low", "medium", "high", "xhigh", "max", "ultra"]}]}}
```

### `POST /v1/speech?device=<UUID>&utterance=<UUID>&final=false&language=auto`

Transcribes one utterance on the runner's CPU using whisper.cpp, independently of the iPhone and of any agent. It uses the same owner gate as the other `/v1` endpoints. This is the speech service only; a Watch gateway can call it later.

The body is binary audio: signed 16-bit little-endian PCM, 16 kHz, mono (`Content-Type: audio/pcm` or `application/octet-stream`), or a complete RIFF/WAV chunk containing that same format (`audio/wav` or `audio/x-wav`). Send sequential chunks of at most ten seconds; each WAV request has its own header. The HTTP body limit is 324,096 bytes including WAV metadata. Audio for an utterance may total at most 60 seconds (1,920,000 PCM bytes).

- `device`: stable UUID chosen by the app for this device. This is a concurrency key, not authentication.
- `utterance`: a fresh UUID for each utterance. Reuse it for every chunk of that utterance.
- `final`: `false` by default. Every non-final call appends the chunk and transcribes **all** audio so far with multilingual `base-q5_1`. A `true` call appends its optional last chunk and transcribes all audio with `large-v3-turbo`, then discards the utterance. An empty final body is allowed after earlier audio. Partial text can change.
- `language`: `auto` (default, detection while transcribing), `en` or `pt`. Use the same language on every call. Transcription keeps the spoken language; it does not translate.

Returns `{"utterance":"<UUID>","text":"…","final":false}` (or `true`). Wait for each answer before sending the next chunk. Chunks append exactly once per received call; this endpoint does not deduplicate retries. After an uncertain network result, let the session expire before starting again.

Only one utterance per device is open or transcribing at once (`409` for an overlapping call, a different utterance or a changed language). At most two CLI processes and 32 open utterances are allowed across devices (`503` when busy). Idle utterances are discarded after 120 seconds following their last partial answer. `400` means invalid parameters/audio; `413` means a body or utterance is too large. Exceeding the utterance limit discards it. `415` means unsupported content type. `501` clearly identifies a missing CLI/model or invalid thread count. `500` means transcription failed or timed out: audio is discarded and the client starts a fresh utterance. Each CLI has a 120-second deadline.

Audio stays in memory between chunks. For inference only, the service writes a WAV in a private 0700 directory under `OBY_HOME/whisper/audio`, outside agent sandboxes, then deletes that directory (including transcript files) after success or failure. CLI stdout/stderr go to `/dev/null`; neither audio nor transcripts are logged, sent to agents, or dispatched as work. Startup removes crash leftovers before serving requests. A process or host crash can leave files until that restart.

Run `OBY_HOME=/srv/nvme/oby Runner/scripts/setup-whisper.sh` once as the runner's owner on tetrix-lab. It requires git, CMake, a C++ compiler, curl and flock (Ubuntu: `git cmake build-essential curl util-linux`). It pins whisper.cpp v1.8.2, builds a static release CLI optimized for this CPU with GPU backends off, and atomically downloads the two multilingual models. Repeated runs reuse the checkout/build and completed downloads; interrupted downloads are retried. The final model needs roughly 1.6 GB of disk. The build uses the [upstream CMake options](https://github.com/ggml-org/whisper.cpp/blob/v1.8.2/CMakeLists.txt) and the [upstream model distribution](https://github.com/ggml-org/whisper.cpp/blob/v1.8.2/models/download-ggml-model.sh).

The runner reads this configuration from its environment at startup (restart after changes):

| Variable | Default |
| --- | --- |
| `OBY_WHISPER_CLI` | `OBY_HOME/whisper/bin/whisper-cli` |
| `OBY_WHISPER_FAST_MODEL` | `OBY_HOME/whisper/models/ggml-base-q5_1.bin` |
| `OBY_WHISPER_FINAL_MODEL` | `OBY_HOME/whisper/models/ggml-large-v3-turbo.bin` |
| `OBY_WHISPER_THREADS` | `8` per inference process, allowing two processes to share tetrix-lab's 16 CPU cores |
| `OBY_SPEECH_NAMES` | Unset: `oby`, `tetrix` and the short names of the runner's current `Desk.repos` list. Set a comma-separated list to override these names. Duplicates are removed and the initial prompt is capped at 512 UTF-8 bytes, including for overrides. |

No GPU is needed. Actual latency and English/Portuguese recognition quality still need checking on tetrix-lab with real Watch recordings.

## What the runner never does

- **Force-push or push to main:** not for anyone, not even with an approval.
- **Merge, except into `dev` after the Mac check:** the runner squash-merges a pull request it opened only into `dev`, only when Oby's review approved it, the Mac check passed on the same commit and the secret scan is clean (Mac check, above). Never into `main`.
- **Publish what didn't pass:** only a job that ended `done` (its check passed, or it has none), with a clean secret scan, is pushed and gets a pull request; by hand, only with a fresh device signature. The only comments that go out are Oby's own review of its own pull request and the Mac check's results on it (an Apple check posts nothing), after the secret scan, and the Lead's claim on an issue a job starts on (the branch name, written by the runner); no GitHub review, approval or comment on anyone else's work.
- **Touch the user's credentials:** it never reads, stores or forwards agent credentials, and each tool signs in through its own login on the runner.
- **Read outside text as instructions:** text from GitHub or other people reaches agents only as quoted files.
