# The job page: a design proposal

A proposal for the page a task opens to, on the Mac and the iPhone. It's design only: nothing in the apps or obid has changed. The owner decides whether to build it, and Sangam's design stays the source of truth: this page only adds parts his task page doesn't have yet, built from his classes and tokens (the Oby design system).

Canvas (Claude Design, private until shared): https://claude.ai/artifact/Mrtz8qT4UaxLHqD8EkaJwh

The canvas follows one real job from start to finish: "Give the scan's first block a fix round" in `obi-ai-bot/obi` (the work behind #722), run by Claude Code on the Personal account. Each row is one state, with B, the layout the owner picked, on the left (`B-*` and `BP-*` boards) and A on the right. Both have the Mac page and the iPhone page, in dark and light:

1. Working: tools are streaming. This row is the hero.
2. Planning: Plan mode, reading before it changes anything.
3. Waiting for you: the plan to approve.
4. Running checks.
5. Failed, with the reason, and nothing sent.
6. Done, with the pull request.
7. The raw session on the Mac and iPhone.

## The decision: B, timeline first (2026-10-19)

The owner picked B. The stages are the page's spine: the tool groups hang under Work, the checks under Check and Publish, and usage is one line of small bars. It keeps four things from A, in a lean form:

- the stage's context sentence, under its one-line detail;
- the estimate's basis, in one line under the time track;
- the detail line (counts, files, `+/−`) on the open group only;
- this job's share of each window as a number ("46% · this job ≈ 11%").

Everything below describes the parts both layouts share; B arranges them on the timeline.

## What's on the page (A, current step first)

Sangam's order stays the same: the title and its meta line, then the decision card when there is one, then the parts as quiet cards, with the message box at the foot. While the job runs, Stop sits in the message box's end slot (A14).

- **Now.** This card leads the page.
  - Sangam's stage bar, with stage names under it.
  - One plain sentence about what the agent is doing, with the sheen while it works. A second sentence gives the context.
  - The time track: elapsed time fills the bar, a tick marks now, and the finish is drawn as a range, never as one number.
  - One line saying how the estimate was made.
  - The tool running right now.
- **Activity.** Counts by kind: read, searches, edits, commands, test runs, Tetrix, web, MCP. Then the work in a few groups, each with a plain title, what it touched, a diff stat for edits and how long it took. Only the group being worked on is open. "Full session" opens the raw log, so the page itself never reads like a log.
- **Usage.**
  - The job's tokens, split into cache reads, new tokens and tokens written.
  - The API-price value, marked "Covered by your plan" on a subscription. A real cost appears only for an API-key account.
  - The account's 5-hour and weekly windows as stacked bars: this job's share is drawn in ink and everything else on the account in grey. Each window shows when it resets and how much is left. Past 80% the bar turns `full` yellow.
- **Stages.** Sangam's list, with how long each stage took or "≈" how long it should take. The checks sit under Check, and the secret scan and what went out sit under Publish. Time spent waiting on the owner is shown as paused and isn't counted.
- **Needs you.** Sangam's decision card at the top: its kind, a headline, one or two sentences, the plan or the failing output, the recommended option filled, then Later. Under it is how long the job has waited. While it waits, the stage bar's segment and the time track turn orange.
- **Failed.** The decision card says what failed and why, in plain words, with the failing tests, and offers another round, the session, or stopping. The "What happened" card always says whether anything went out ("Nothing went out. The branch stays on this Mac") and that the secret scan didn't run.
- **Done.** Shown in this order:
  - Result: the report, then a pull request card with its state, base and diff stat.
  - "What went out": every outgoing action, as AGENTS.md requires.
  - Checks, all of them: fmt, clippy, tests, the secret scan, and the Mac check on the same commit.
  - The time it took next to the estimate given, so the estimate earns trust.
  - The message box, which asks for a follow-up.
- **Details.** Repository, branch into base, model and effort, mode (also a pill by the meta line, so it can be changed), "Done when", and where it was asked.
- **iPhone.** Same order, tighter. The counts scroll sideways, only the open group shows, and Stages and Details fold into rows once the job is done. The session opens as a sheet.

## How the estimate works (proposed)

- Per repository, agent and stage, keep the durations of past jobs. A job's kind and its plan size (the files the plan names) narrow the set to compare against.
- Show the middle 80% of those durations as a range, never one number. Plan-mode reading and time waiting on the owner aren't counted.
- Narrow the range after the first passing test run. For checks, use the last full run of the same command.
- With fewer than 5 past jobs, say "Too early to be sure" and give the repository's overall range.
- Once a job is done, show "Took 19m · estimated 12–20m".

## How a job's share of the window is worked out (proposed)

Claude's `rate_limit_event` gives the account's utilization, not each job's. While a job runs, obid can count the job's tokens and divide the rise in utilization between the jobs running on that account, by token share. That's why the share is shown with "≈". On Codex, `account/rateLimits/read` works the same way, using `thread/tokenUsage/updated` for the tokens.

## What obid doesn't expose yet (needed by this design)

These come from a read of `docs/runner-api.md` and `core/crates/obid` on 2026-10-19.

1. **Tool events for jobs.** obid drops `Tool`, `ToolDone` and `Delta` for jobs (`core/crates/obid/src/jobs.rs:2950`). Only the `step` line survives, overwritten each time. Conversations already get `{tool, detail, state, at}` (runner-api.md, the conversation harness). Jobs need the same: kept per job and sent as `step` events, plus a `GET /v1/jobs/{id}/session` for the raw log, with secrets masked.
2. **Per-tool counts.** Nothing counts reads, searches, edits, commands, test runs, web or MCP calls per job. `tetrix.calls` exists in the Swift runner only, and obid hard-codes `tetrix: null` (`job.rs:535-561`).
3. **Groups with plain titles.** These need item 1 plus the agent's own words between tool calls (its `said` text). Failing that, a rule that groups runs of the same kind ("Read 14 files").
4. **Tokens and cost per job.** Claude's `result` carries `usage` and `total_cost_usd`, but obid reads them only for brain and planner calls (`brain/planner.rs:1004-1040`). Codex's `thread/tokenUsage/updated` is read only in conversations (`codex.rs:558`).
5. **Account windows.** `fiveHour`, `sevenDay` and their reset times are in the Account object, but obid sends them as null (`api.rs:628-631`). Nothing in obid parses `rate_limit_event` or Codex's `account/rateLimits` for jobs.
6. **The job's share of each window.** Not tracked at all; see the method above.
7. **Durations and estimates.** No per-stage start and end times, no history of past durations, and no ETA. Only `created`, `started` and `finished`, plus fixed limits (45 minutes a round, 3 hours a job, 20 minutes a check run).
8. **The job's own check run.** Its steps, results, durations and test counts ("412 of 793") aren't recorded. The Mac check and the Apple check have `steps[{name, passed, seconds}]` and `failing[]`. The job's `check` doesn't.
9. **The secret scan's result.** It has no record of its own: only `publishStep: "scan"`, the Publish stage detail, or a `publishError` starting "Not published: possible secret…". The page needs `{ran, clean, commits, files, seconds}`.
10. **Diff stat.** There's only `commits` and `pushed`. Files changed and lines added and removed appear only in failure evidence.
11. **Questions on obid.** `question` is hard-coded to null on obid (`job.rs:535-561`). Plans and permissions arrive as `permission` and inbox items, and the page reads either.
12. **How long it's waited.** The time a job has spent waiting on the owner. Paused clocks exist (Plan mode says "the clocks paused"), but the waiting time isn't exposed.

Already there and used as they are: `step`, `pipeline` (stages with `state`, `detail` and `reason`), `round` and `rounds`, `check`, `mode`, `model`, `effort`, `permission`, `outgoing`, `published`, `pullRequest`, `publishError`, `macCheck`, `appleCheck`, failure records (`/v1/failures`), and `answered` (the last 50 permission rulings).

## Issues

Tracked on #739, on the roadmap board:

- design: #729
- obid: #381 (transcript, already open), #730 (activity), #731 (tokens and cost), #450 (account windows, already open), #732 (window share), #733 (timings and estimate), #734 (check run), #735 (scan record), #736 (diff stat), #448 (question, already open)
- apps: #737 (Mac), #738 (iPhone)

## Open questions for the owner and Sangam

- Is Usage a card on every job, or folded into one line (as B does) unless an account is past 80%?
- Should the raw session be a page of its own (as drawn on the Mac) or open in place under Activity?
- On the iPhone, should Stop live in the message box (as drawn) or in the ⋯ menu only?
