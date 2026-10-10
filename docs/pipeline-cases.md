# Oby pipeline cases

The plan for making Oby run Deskree's whole pipeline by itself, case by case. This file and the Claude Design canvas carry the same content and are kept in sync: change one, change the other.

- Canvas: https://claude.ai/artifact/McR9Mme7KUiGaytKkwYsoq
- Status: planning. Nothing here is built unless "Oby today" says so.
- Last synced: 2026-10-10

## Decided

- **100% automation (2026-10-10).** Oby opens the PR without asking once the job's checks pass and the Lead approves the diff. The agent merges once the review approves. Reviewers are teammates now and other Obys later (F12). People are involved only when necessary.
- **The Lead** thinks with Sonnet 5.5 and reviews each job until it's satisfied.
- **Output.** You get the result, the steps that were followed and what's worth knowing. Never the session transcript.
- **Oby learns how you decide (2026-10-10).** Every decision on these boards (who reviews a repo, which check, where to merge, how many rounds…) is asked at most once. After that it's remembered and applied by default, and the report names the remembered decision it used. Oby asks only when it has nothing to go on, the way Claude Code applies what it remembers about how you work. The memory is yours only (each Oby is personal) and doesn't expire. Oby always learns from what you do as well as from what you answer. It lives in the Tetrix graph and is fetched only when a situation calls for it. Workers' questions and permission requests go to Oby first, and Oby answers them from that memory. See X.4.
- **An inbox like email (2026-10-10).** Anything Oby can't decide, or that only a person can do (passwords, sudo, sign-ins), waits in your inbox for your decision: no timeout, no guessing. Every decision teaches Oby, so it starts generic and becomes personal. See "Your inbox".
- **Tetrix is optional (2026-10-10).** Oby works fully on its own with local storage. Tetrix adds richer memory. See X.7.
- **A vault (2026-10-10).** Secrets live in an encrypted vault that no agent ever sees. Oby uses them only through connections you set up. See 2.6 and F17 (deskree-inc/oby#60).
- **AGENTS.md rewritten to match (2026-10-10).**
  - Oby merges into `dev` only, after the review approves and CI is green, and never pushes or merges to `main`.
  - It force-pushes only branches it created.
  - Nothing goes out unless the checks, the Lead's review and the secret scan pass.
  - Vault secrets never reach an agent.

## Working assumptions (not decided)

- **Lead:** one Claude Code session per goal. Events wake it: your message, a job ending, a job stuck. It reads the roadmap, Oby's jobs and Tetrix, starts jobs, and reviews them. It answers with typed actions that Swift checks.
- **Jobs:** Claude Code and Codex agents, each in its own worktree off Oby's clone, spread across your accounts.

## The pipeline

0 What you connected → You say a goal → 1 Pick the work → 2 Build in a worktree → 3 Test until green → 4 Open the PR → 5 Get it reviewed → 6 Merge → 7 Report back

- **Loops:** tests fail (3 → 2). Changes requested or CI red (5 → 2, then through 3 again).
- **Where Oby calls you** (it waits in your inbox, I.1–I.7):
  - Goal unclear (1): one question, with options.
  - Stuck (2): a decision only you can make.
  - Done (7): the result, the steps, what's worth knowing.
- **Where Oby doesn't ask (decided):** opening the PR (4) and merging (6).

## How to read a case

Each case has:
- **What happens:** the behavior we want, and the stage it goes to next.
- **Oby today:** Works, Partial, Missing or Broken.
- **Claude Code, Cursor, Codex, Others:** how those products handle the case today. Others means Copilot's coding agent and Devin.
- **Open for Oby:** a proposal and the decisions still to make. Each "Decide" is a question for the product now. Inside the product, the answer becomes a remembered default, asked once at most (X.4).

The competitor notes were checked against each product's docs on 2026-10-10. "2nd-hand" means a blog, forum or search summary, not official docs. Sources are at the end.

---

## 0 · What you connected

Before stage 1. People connect only what they have. That decides which model the Lead thinks with and which model the jobs work with. Oby checks those picks with you once, at first launch (F14, #18).

### 0.1 Only Claude Code
- **What happens:** Oby reads which Claude models the account offers, picks the Lead's and the jobs' models, and shows both at first launch to keep or change. Goes to 1.
- **Lead thinks with:** Sonnet 5.5 (decided).
- **Jobs work with:** Opus 5.5 at extra high effort today. Fable 5.1 is the stronger model for complex work.
- **Typed plan:** enforced. `--json-schema` fills `.structured_output`. 4 of 4 were valid in the #31 test, taking 3–6 s with Haiku.
- **Oby today:** Works. Claude is the only brain Oby has.
- **Decide:** jobs on Opus 5.5, or on Sonnet 5.5 to stretch a Pro plan's limits? When may Fable 5.1 be used without asking?

### 0.2 Only Codex
- **What happens:** Oby asks Codex which models this account may use (`model/list`, which includes each model's efforts) and picks from that list, never from a hard-coded name. Goes to 1.
- **Lead thinks with:** a Codex model at lower effort. Which one is still to check.
- **Jobs work with:** gpt-6-sol at high effort today. The code's default is gpt-6.1-sol, which a ChatGPT Plus login can't use. gpt-6-astra is stronger but uses up a Plus plan fast.
- **Typed plan:** enforced. `codex exec --output-schema` was 4 of 4 valid in #31, at about 9 s and 18k tokens a call. Whether app-server turns accept a schema is still to check.
- **Oby today:** Broken. Jobs run on Codex, but planning is Claude-only: without Claude, Oby falls back to keyword rules.
- **Decide:** the Lead's Codex model and effort. Should Astra never be the default on a Plus plan?

### 0.3 Only Cursor
- **What happens:** Oby lists the account's models with `agent models` after you sign in, picks two and shows them. Goes to 1.
- **Lead and jobs:** unknown until we can list the models. The Cursor CLI on Wellington's Mac (2026.10.01) isn't signed in. Using two Cursor accounts is spike #24.
- **Typed plan:** not enforced. The CLI returns a JSON wrapper with free text in `.result` (#31). The schema goes in the prompt, and Swift checks the reply and retries.
- **Oby today:** Missing. There's no Cursor runner yet (F6, #10) and no Cursor brain.
- **Decide:** the default models, once we can list them. Is an unenforced schema reliable enough for 100% automation, or does a Cursor-only Lead ask you more often?

### 0.4 Only Gemini
- **What happens:** same as Cursor: list the models, pick, show. Goes to 1.
- **Lead and jobs:** unknown.
- **Typed plan:** not enforced. Free text in `.response`. Google ended personal sign-in for the CLI on 2026-06-18, so it needs an API key or Vertex.
- **Oby today:** Missing. Not built (F6).
- **Decide:** support a Gemini-only setup in the first version at all?

### 0.5 Several tools
- **What happens:** one tool thinks, and jobs spread across every account by usage. First launch shows "Oby thinks with X and works with Y and Z". Goes to 1.
- **Lead thinks with:** the best planner connected: Claude (enforced schema), then Codex, then Cursor, then Gemini.
- **Jobs work with:** every connected account, routed by usage. The score is the higher of the 5-hour and 7-day use, plus 0.15 per running job.
- **Oby today:** Partial. Jobs are routed across Claude and Codex, and the brain is always Claude.
- **Decide:** always the same tool for the Lead, or the one with the most room left? Does the Lead's own usage count toward routing?

---

## Your inbox

Like email: each item waits for your decision, with no timeout and no guessing. If something is here, Oby doesn't know what to do, or only a person can do it. Every decision teaches Oby (X.4), so the inbox shrinks: generic at first, personal later. Oby today has none of this, only one card slot (`Desk.talk`).

### What the best tools teach (researched 2026-10-10)

1. **Grouped by what you must do:** Needs you, Ready for review, Working, Done. Longest-waiting first, with "waiting 3m". (Claude Code agent view)
2. **Answer in the list:** the exact question, choices on number keys, a suggested reply, and buttons on the iPhone. You never open a session to answer. (Claude Code peek panel, Linear Triage)
3. **Three ways out, then the next item opens:** Done (gone, still searchable), Later (until a time or new activity), Keep. (GitHub, Linear, Gmail's auto-advance)
4. **Learn through visible rules:** "Always" shows the rule and its scope (`npm test *`, this repo) before saving, and every rule is listed with a remove button. (Claude Code `/permissions`, HEY Screener)
5. **Nothing handled in silence:** what Oby settled alone goes to an Auto-handled list, each with a reason. (Gmail's "why", Linear's explanations, Superhuman Auto Archive)
6. **Never learn the human-only steps:** passwords, sudo, 2FA and sign-ins always reach you, as one-tap handoffs. (Claude Code keeps these out of allow rules)
7. **Push only for "needs you" and "ready":** quiet while you're at the Mac, a Live Activity on the iPhone, and a setting per kind of item. (Claude Code Remote Control, Cursor iOS)
8. **Avoid:**
   - requests that fail when nobody answers (Codex scheduled tasks)
   - broad saved rules
   - learning with no undo
   - one push per event
   - an inbox that is also the archive

### I.1 Question
- **Lands here when:** a worker or the Lead needs a decision, and nothing Oby learned answers it (X.4).
- **Your actions:** Answer (pick an option or type), Later, or Dismiss. Then the next item opens.
- **What Oby learns:** your answer, for this repo, every repo, or just this time, shown as a rule you can remove.
- **How others do it:**
  - Claude Code has a "Needs input" group. You answer inline in the peek panel (number keys, Tab for a suggested reply), it shows "waiting 3m", and questions stay open until answered.
  - Linear Triage: Accept, Decline and Duplicate on 1, 2 and 3.
- **Decide:** does a waiting question pause only its job, or its whole goal?

### I.2 Permission
- **Lands here when:** a worker asks to run something that neither Oby's fixed rules nor your learned rules settle.
- **Your actions:** Allow once, Always allow, or Deny. "Always allow" first shows the rule and its scope, such as `npm test *` in tetrix-ee.
- **What Oby learns:** a permission rule, listed in Settings with where it came from and a remove button.
- **How others do it:**
  - Claude Code: "Yes, and don't ask again" saves a per-repo rule. `/permissions` lists and removes rules, and deny beats allow.
  - Codex: accept for the session, or add to its policy.
  - Claude's Agent SDK hands Oby rule suggestions to save, and can pause a job until the answer comes (`defer`).
- **Proposal:** a job waiting on a permission pauses with `defer`, so waiting costs nothing.

### I.3 Hands-on: password, sudo, sign-in, 2FA
- **Lands here when:** a step only you can do. Oby never types it and never learns the secret.
- **Your actions:** one tap opens Terminal in the job's worktree with the command ready, or opens the sign-in link. "I did it" resumes the job.
- **What Oby learns:** nothing about the secret. A Vault connection can take over steps you choose (2.6).
- **How others do it:** nobody makes this a first-class item.
  - Claude Code: `!` runs a command in your terminal, and MCP sign-in needs `/mcp`.
  - Codex app-server sends a sign-in link (`authUrl`).
  - Cursor: open a full terminal and type the password (2nd-hand).
- **Proposal:** this is where Oby can beat everyone: a real handoff, then the job carries on.

### I.4 Review request
- **Lands here when:** someone asks you to review their PR (a teammate today, other Obys later), or the Lead couldn't approve a job on its own.
- **Your actions:** Let Oby review (it drafts, you send), Review it yourself, or Later.
- **What Oby learns:** which repos and people Oby may review for you without asking.
- **How others do it:**
  - Claude Code: a "Ready for review" group (open PR or failing checks).
  - Copilot returns a draft PR and tags you.
  - vibe-kanban moves the card to In review.
- **Decide:** may Oby approve a teammate's PR for you once it has learned enough (F12)?

### I.5 Follow-up
- **Lands here when:** something waits on someone else: a silent reviewer, a flaky check, a blocked dependency.
- **Your actions:** Nudge, Hand to someone else, or Later.
- **What Oby learns:** when to nudge on its own, and whom to hand work to.
- **How others do it:** Superhuman puts reminders on mail that needs a reply. Linear snoozes until new activity.
- **Decide:** how long a reviewer may stay silent before the first nudge.

### I.6 New task
- **Lands here when:** work arrives from outside: an issue assigned to you, a Slack mention, a request from another Oby.
- **Your actions:** Start, Later, or Decline.
- **What Oby learns:** which sources may start work without asking. The first item from a source asks, then the answer is remembered.
- **How others do it:**
  - HEY Screener: one decision per sender, reversible, with a 90-day catch-up.
  - Devin and Cursor start from Linear or Slack triggers you set up.
- **Decide:** start issues assigned to you without asking?

### I.7 Done report
- **Lands here when:** a goal finishes. It goes to Done, not the inbox, unless "worth knowing" needs a decision.
- **Your actions:** read it; tap a step to open it.
- **What Oby learns:** nothing.
- **How others do it:**
  - Claude Projects: Resolved, by you or after a week idle.
  - Codex: the Scheduled view is its inbox, with an unread dot.
  - Cursor: a completion message with the PR link.

---

## 1 · Pick the work

From your goal to a list of jobs, then on to stage 2.

### 1.1 Vague goal: "Work on the roadmap"
- **What happens:** the Lead reads the board in order and skips what's done, in review, waiting for your test or blocked. It picks the next items that can run in parallel. Goes to 2, one job each, or to a question if nothing is workable.
- **Oby today:** Broken. The Haiku brain sees only repo names. It handed "find the top issue" to one blind agent, which picked #6 twice. #6 was only waiting for your test (runner jobs 30b93910 and 93887146, PR #55).
- **Claude Code:** starts only from tasks you send. Projects splits one message into threads. Routines groom a backlog (labels, owners) but don't implement. No board polling.
- **Cursor:** Linear triage rules can assign issues to Cursor. The Projects coordinator watches Slack, a schedule or PRs, and how it prioritises is undocumented.
- **Codex:** scheduled automations feed an inbox. Picking issues isn't documented.
- **Others:** Copilot works on issues you assign, and Agentic Workflows only triage. Devin fires when a ticket newly matches a label or status filter.
- **Open for Oby:** nobody ranks a roadmap by itself. Every product starts from a label, assignee or status a person set.
  - Proposal: board order plus Status is the queue.
  - Decide: may Oby take anything on the board, or only items marked "Ready for Oby"?

### 1.2 Named issues or an epic: "#12, #15 and #18", "epic #30"
- **What happens:** one job per issue. An epic becomes one job per open sub-issue, and sub-issues that depend on each other run in order. Goes to 2.
- **Oby today:** Partial. Up to 10 jobs; epics through the sub-issues API or the task list (#44, #45). Each plan still waits for a Dispatch tap.
- **Claude Code:** `claude --bg` and `--cloud` run parallel sessions, each in its own worktree. Projects turns several tasks or a spec into threads and can propose them first; the cap is 200 threads a day.
- **Cursor:** Projects delegates to many parallel agents. No documented cap for cloud agents.
- **Codex:** each cloud task runs in its own workspace, in parallel. No epic splitting found.
- **Others:** Copilot does one task, one branch, one PR. Devin's coordinator splits big tasks into child Devins, each in its own VM, and you can approve each batch.
- **Open for Oby:**
  - Proposal: keep Swift's epic expansion. The Lead orders dependent sub-issues, and the Dispatch tap goes away.
  - Decide: how many jobs may run at once per goal (today 10)?

### 1.3 Already taken: in progress, in review, waiting for your test
- **What happens:** before starting, check for an open PR on the issue, an Oby job on it, an assignee, and the board status. Skip it and say why. Goes to the skipped list in the report.
- **Oby today:** Missing. Nothing checks. #6, waiting for your test, got two jobs and PR #55.
- **Claude Code:** Code Review skips PRs it already commented on, and Tag flags duplicate requests. No assignee or open-PR check is documented.
- **Cursor:** Bugbot avoids repeating existing PR comments. No issue-level check found.
- **Codex:** not found.
- **Others:** Devin's preflight script dedupes by item id and version. Copilot: not found.
- **Open for Oby:** nobody has a claim check.
  - Proposal: Swift refuses a job on an issue with a running job or an open PR, and Oby assigns the issue to itself when it starts.
  - Decide: self-assign on GitHub, or keep the claim inside Oby?

### 1.4 Unclear or misheard: "OB", "Obi"
- **What happens:** resolve against known repos, the conversation's last repo and similar names. Ask only when two readings lead to different work. Goes to 2, or to one question with options.
- **Oby today:** Broken. The repo must match a known name. Your first roadmap request vanished because brain failures aren't logged on the runner.
- **Claude Code:** Projects can propose threads before starting them.
- **Cursor:** posts a short plan in Slack before working.
- **Codex:** not found.
- **Others:** not found.
- **Open for Oby:**
  - Proposal: log every Lead turn. A conversation keeps its repo, so "Obi" after an Oby request means Oby.
  - Decide: nothing yet.

---

## 2 · Build in a worktree

Each job works in its own worktree off Oby's clone, on one of your accounts. These are the things that go wrong while nobody is watching.

### 2.1 Same files: two jobs would touch the same code
- **What happens:** the Lead lists the files each job will touch. Overlapping jobs run one after another, not side by side. Goes to 2 in sequence, or to 5.4 later if dev moved.
- **Oby today:** Partial. One worktree per job, but no overlap check, so parallel PRs can conflict.
- **Claude Code:** each background session and worktree subagent gets its own worktree. Cloud sessions get separate VMs and `claude/` branches. Conflicts aren't handled.
- **Cursor:** one worktree per task, 25 per machine by default. Conflicts aren't described.
- **Codex:** managed worktrees, keeping the 15 most recent. Conflicts aren't described.
- **Others:** Devin uses child VMs, and its coordinator "resolves conflicts". Copilot uses one branch per task.
- **Open for Oby:**
  - Proposal: predict overlap with Tetrix `code_impact`, and have Swift run overlapping jobs in sequence.
  - Decide: nothing yet.

### 2.2 Risky command: a permission prompt with nobody watching
- **What happens:** Oby's policy answers. Work inside the worktree is allowed. GitHub, other MCP servers, Oby's secrets and pushing are denied. Goes back to the work, or to 2.3 if the job can't proceed.
- **Oby today:** Works. The policy answers prompts. Agents have no GitHub login, a broken push URL, and only Tetrix reads among MCP tools. Gap: on tetrix-lab, agents can read the gh token and the APNs key.
- **Claude Code:** auto mode's classifier pauses after 3 blocks in a row or 20 in total, and headless runs deny the action and carry on. There's an OS sandbox for Bash. Cloud network can be none, trusted or full, and a GitHub proxy keeps credentials out of the VM.
- **Cursor:** cloud VMs can restrict domains. The local terminal sandbox is on by default (2nd-hand).
- **Codex:** in the cloud there's no internet while the agent works, with an optional allowlist. Locally, workspace-write has no network and `.git` is read-only. An optional reviewer agent can handle approvals.
- **Others:** Copilot's firewall and allowlist are on by default, and blocked requests are listed in the PR. Its workflows need a person to click "Approve and run".
- **Open for Oby:**
  - Proposal: answer in this order: Oby's fixed rules, then what you allowed before (X.4), then the Lead's judgment, then you. Your answer is remembered.
  - Proposal: fence Oby's own secrets off on tetrix-lab.
  - Decide: network for agents: none, an allowlist, or full?

### 2.3 Stuck: needs a decision only you can make
- **What happens:** the job asks the Lead first. The Lead answers from the issue, the roadmap, Tetrix and past jobs. Only a real product decision reaches you, as one question with options. Goes back to 2, or to you.
- **Oby today:** Partial. You can talk to a job, but nothing notices when it's stuck, and questions only come from the brain before dispatch.
- **Claude Code:** Remote Control pushes questions to your phone. Agent view marks "Needs input", Projects has "Waiting on you", and Tag asks in the Slack thread.
- **Cursor:** iOS Live Activities and a push when an agent needs input or is ready; you reply in the Slack thread.
- **Codex:** a private Allow/Deny card in Slack. Mobile push not found.
- **Others:** Devin's coordinator is woken when a child needs input. Copilot requests your review when done, and you can steer a running session.
- **Open for Oby:**
  - Proposal: the Lead answers first, from what Oby has learned about you (X.4) and the graph. Only what it knows nothing about reaches you, through the Live Activity and a push, and your answer is learned.
  - Decide: what always counts as "needs you", even if Oby could guess: spending, deleting, security?

### 2.4 Usage limit: the account runs out mid-job
- **What happens:** the job pauses, then carries on with another account of the same tool (same worktree, a new session given the summary so far) or waits for the reset. Goes back to 2.
- **Oby today:** Partial. Routing skips accounts at 95% when a job starts. A job already running on a full account just fails.
- **Claude Code:** shows the reset time, and interactive sessions can continue at the reset. Headless auto-resume is undocumented. Project threads retry after the reset.
- **Cursor:** not found.
- **Codex:** 5-hour and weekly limits. What happens mid-task: not found.
- **Others:** Devin sleeps at its credit limit until woken (from 2025, may be stale). Copilot sessions stop at 59 minutes.
- **Open for Oby:**
  - Decide: move the job to another account (switching near a limit is opt-in, #23) or wait for the reset?

### 2.5 Restart: the runner or the Mac restarts mid-job
- **What happens:** when Oby starts, it finds interrupted jobs and resumes their sessions in the same worktrees. Goes back to 2.
- **Oby today:** Missing. Jobs show "interrupted" and stay stopped.
- **Claude Code:** cloud sessions run on Anthropic's VMs, so closing the laptop doesn't stop them.
- **Cursor:** cloud agents run on Cursor's VMs.
- **Codex:** cloud tasks run in OpenAI's containers.
- **Others:** Devin runs on VMs, Copilot on GitHub Actions.
- **Open for Oby:**
  - Proposal: resume from the job's saved session, as talking to a finished job already does.
  - Decide: nothing yet.

### 2.6 Needs a secret: an API key, a token, sudo, a login
- **What happens:** if you connected that secret to this kind of work, Oby's vault broker uses it at the point of use, and the agent never sees the value. If not, it lands in your inbox as a hands-on item (I.3), where you can connect it for next time. Goes back to 2.
- **Oby today:** Missing. Agents get no secrets, and Publish keeps the GitHub login to itself.
- **Claude Code:**
  - In the cloud, GitHub credentials never enter the VM; a proxy swaps a short-lived credential for the real token.
  - Pro and Max "network secrets" are added outside the VM for hosts you list.
  - The local sandbox can mask credentials.
  - Plain environment variables are readable.
- **Cursor:** Runtime Secrets are environment variables shown as [REDACTED] in output, transcripts and commits. They're encrypted with per-agent KMS keys, and Cursor recommends short-lived OIDC tokens.
- **Codex:** secrets reach only setup scripts and are removed before the agent runs. Environment variables stay readable for the whole task.
- **Others:**
  - Copilot: secrets reach the agent as environment variables, masked in logs.
  - Devin: encrypted, bound only to the commands that need them.
  - In April 2026, injected PR text made agents post API keys into comments, encoded past masking (2nd-hand).
- **Open for Oby:**
  - Proposal: a broker, never environment variables. A local proxy adds keys only for their hosts, and an `oby-sudo` command checks the caller and feeds sudo itself. Roadmap: F17, deskree-inc/oby#60.
  - Decide: which secrets come first: API keys, sudo, or logins?

---

## 3 · Test until green

A job counts as done only when its check passes. Then the Lead reviews the diff against the brief and sends it back until it's satisfied.

### 3.1 Tests fail
- **What happens:** the job runs its check, for example `swift test`. On failure, the output goes back to the agent for another round, up to the job's limit. Goes to 4 when green and the Lead approves, or to 2.3 when out of rounds.
- **Oby today:** Partial. A check command and rounds, or the agent's own GOAL MET line (#44), but only when the brain set a check.
- **Claude Code:** cloud Auto-fix reads failing checks and pushes a fix when it's clear. Desktop's "Auto-fix CI" iterates on the output.
- **Cursor:** auto-fixes CI on PRs it created (GitHub Actions, Teams plan). `@cursor autofix off` stops it.
- **Codex:** only on demand, with `@codex fix the CI failures`.
- **Others:** Devin auto-fixes lint and CI, and can start on a failed check. Copilot acts only when mentioned.
- **Open for Oby:**
  - Proposal: every job has a check. Out of rounds, the Lead retries once on a stronger model, then asks you.
  - Decide: how many rounds at most (today 5, up to 10)?

### 3.2 No test command: the check isn't obvious
- **What happens:** the Lead finds the check in the repo: AGENTS.md, the CI workflow, Package.swift. If there's none, the agent writes a test for its change. Goes to 3.1.
- **Oby today:** Missing. There's a check only when you name one.
- **Claude Code:** commands live in CLAUDE.md, and project instructions can require test-summary lines in the final message.
- **Cursor:** not found.
- **Codex:** commands live in AGENTS.md.
- **Others:** not found.
- **Open for Oby:**
  - Proposal: read the CI workflow. The PR's own CI is the last check (5.3).
  - Decide: must local tests pass before the PR opens, or is green CI on the PR enough?

---

## 4 · Open the PR

Decided 2026-10-10: no confirmation. The PR opens once the check passes and the Lead approves the diff.

### 4.1 Commit, push, open
- **What happens:** commit, push the branch, and open the PR into dev with "Closes #N" and the steps and results in the body. Goes to 5.
- **Oby today:** Partial. Publish runs the secret scan, asks for Touch ID or Face ID, and opens a draft PR into dev. Agents can't sign commits, so one job (30b93910) ended with nothing committed.
- **Claude Code:** project threads open a PR on their own for a clear fix, and Slack has a Create PR button. Tag opens a draft PR as the Claude GitHub App. Cloud PRs carry your identity, and signing keys stay outside the sandbox.
- **Cursor:** Linear tasks open PRs automatically. Interactive cloud PRs are yours. Commits say "Cursor Agent" with you as co-author, and automations use cursor[bot] (2nd-hand).
- **Codex:** a Create PR button with a draft option (2nd-hand). Author and signing: not found.
- **Others:** Copilot always opens a PR, with commits co-authored by you and signed (2nd-hand), but it can't mark the PR ready, approve or merge. Devin opens PRs from its own GitHub account.
- **Open for Oby:**
  - Decide: whose name is on the PR: yours (Oby's gh login) or an Oby GitHub App (oby[bot])?
  - Decide: draft, or ready for review?
  - Decide: who signs? The agent never does; GitHub or Oby does at push.

### 4.2 Secret in the diff
- **What happens:** a hard stop: the PR doesn't open. The job removes the secret and the scan runs again. If it's still there, it comes to you. Goes to 2, or to you.
- **Oby today:** Works. Publish scans everything outgoing, and if the scanner can't run, nothing is published.
- **Claude Code, Cursor, Codex:** not found.
- **Others:** GitHub's push protection, a platform feature, blocks known secret formats on push.
- **Open for Oby:** nobody scans outgoing diffs themselves.
  - Proposal: keep the scan as the gate before every push, and turn on GitHub push protection too.
  - Decide: nothing yet.

---

## 5 · Get it reviewed

The reviewer is a teammate today and another Oby later (F12). Oby watches the PR and loops on it until it's approved.

### 5.1 Ping the reviewer
- **What happens:** request a review from the owner (CODEOWNERS, or Tetrix's owners), then post in the project's Slack channel: the PR link and three lines on what changed. Then wait for the review.
- **Oby today:** Missing. No review request and no Slack yet (F10).
- **Claude Code:** Tag's PRs land in your review queue, linked to the Slack thread, and routines can post a Slack summary. CODEOWNERS: not found.
- **Cursor:** automations can request reviewers, and Slack gets a completion message with the PR link.
- **Codex:** the result goes back to the Slack thread.
- **Others:** Copilot requests your review, and your approval doesn't count toward the required ones. Devin posts the PR link on the Linear ticket.
- **Open for Oby:**
  - Decide: who reviews each repo: CODEOWNERS, Tetrix's owners, or a list you set?
  - Decide: Slack as you, or as an Oby bot?
  - Decide: if nobody reviews in N hours, nudge, then ask someone else?

### 5.2 Changes requested
- **What happens:** each review that requests changes becomes another round for the same job, in the same worktree and session. It tests again, pushes, replies and asks for a new review, until approved. Goes to 3, then back to 5.
- **Oby today:** Partial. Talking to a finished job picks its session up again, but nothing watches the PR.
- **Claude Code:** cloud Auto-fix pushes clear fixes and asks you about unclear ones, replying under your account labelled Claude Code. Project threads watch their PR. The GitHub Action acts only on @claude.
- **Cursor:** Bugbot Autofix pushes to the PR branch (3 attempts at most) or to a new branch.
- **Codex:** `@codex fix the P1 issue` pushes if allowed. Handling of requested changes isn't documented.
- **Others:** Devin's Auto-Fix pushes commits. It acts on other bots' comments only if allowed, because "all bots" can loop. Copilot acts only on @copilot.
- **Open for Oby:**
  - Proposal: the runner polls Oby's open PRs every minute.
  - Decide: act on every comment, or only on change requests?
  - Decide: whose comments count (repo members only)?
  - Decide: how many review rounds before it asks you?

### 5.3 CI red on the PR
- **What happens:** the failing check's log goes to the job as another round, exactly like 5.2. Goes to 3.
- **Oby today:** Missing.
- **Claude Code:** Auto-fix CI, in the cloud and on Desktop.
- **Cursor:** auto-fixes CI on its own PRs (GitHub Actions, Teams plan).
- **Codex:** only on demand.
- **Others:** Devin auto-fixes CI. Copilot acts only on @copilot.
- **Open for Oby:**
  - Decide: nothing new; it follows 5.2.

### 5.4 Conflict: dev moved under the PR
- **What happens:** Oby brings dev into the job's branch, the agent resolves the conflicts, tests again and pushes. Goes to 3.
- **Oby today:** Missing.
- **Claude Code:** GitHub sends no event for a conflict. You ask Claude to rebase, or press "Resolve conflicts".
- **Cursor:** not found.
- **Codex:** not automatic.
- **Others:** Copilot has `@copilot` and a "Fix with Copilot" button. Devin has a scheduled check for stale PRs.
- **Open for Oby:** nobody does this on their own.
  - Proposal: check mergeability while watching the PR.
  - AGENTS.md now lets Oby force-push branches it created, so rebasing a job's own branch is allowed.
  - Decide: rebase, or merge dev in?

---

## 6 · Merge

Decided 2026-10-10: the agent merges once the review approves.

### 6.1 Approved: merge
- **What happens:** approved and CI green: squash-merge into dev and delete the branch. The issue closes through "Closes #N". Goes to 7.
- **Oby today:** Missing. AGENTS.md says Oby never merges, and your decision changes that rule.
- **Claude Code:** Desktop's "Auto-merge when ready" squash-merges after the checks pass, if the repo's GitHub auto-merge is on. Project cards have a "Merge it" button.
- **Cursor:** you merge, from the iOS app for example.
- **Codex:** you merge.
- **Others:** Copilot can't approve or merge. Devin leaves the PR to people.
- **Open for Oby:**
  - Proposal: turn on GitHub's own auto-merge when the PR opens, so GitHub merges the moment its rules are met.
  - Decided 2026-10-10: into `dev` only. `dev` into `main` stays after your test on a real Mac.

## 7 · Report back

### 7.1 Report
- **What happens:** one message per goal, landing in the notch, as a push on the iPhone, and in the Tetrix session:
  - The result: what merged, with links.
  - The steps: worktree, tests (3 rounds), PR, reviewed by X, 1 change, merged.
  - Worth knowing: risks, follow-ups, what was skipped and why.
- **Oby today:** Partial. Each job ends with the agent's own free text, often long.
- **Claude Code:** Slack gets progress updates, then a summary with View Session and Create PR. Tag shows a live checklist. Projects can be told "only post when it finishes or is blocked". Agent view shows one line per session.
- **Cursor:** a short plan, a short status, then a completion message with the PR link. Summaries and diff images can be turned off.
- **Codex:** the result goes to the thread. Automations post to an inbox, and runs with nothing to report archive themselves (2nd-hand).
- **Others:** Devin keeps an activity feed on the Linear ticket with the PR link. Copilot shows the full session log and the PR.
- **Open for Oby:** nobody has a fixed "result, steps, worth knowing" report.
  - Proposal: Oby writes the steps from its own events, and the agent adds only "worth knowing".
  - Decide: where it lands: the notch, a push, a Slack DM, a daily digest?

---

## Across every stage

Things that hold at every step, and matter more now that nobody confirms a PR or a merge.

### X.1 Untrusted text: issues, review comments, Slack
- **What happens:** that text reaches agents only as quoted files. The Lead's actions are typed and checked by Swift, so nothing written in a comment can trigger a merge by itself. Applies at every stage.
- **Oby today:** Works for issues and PRs: they arrive as quoted files in `.oby/inputs`.
- **Claude Code:** a GitHub proxy keeps credentials out of cloud VMs. Code Review findings never approve or block.
- **Cursor:** not found.
- **Codex:** no internet in the cloud while the agent works.
- **Others:** Copilot has a firewall, and its workflows need a person's click. Devin acts on bots' comments only if allowed.
- **Open for Oby:** with auto-merge, a hostile review comment could steer a job.
  - Decide: whose comments a job may act on: repo members only, or the PR's reviewers only?

### X.2 Memory between jobs
- **What happens:** every job is saved to Tetrix: summary, decisions, files. The Lead reads what was done before it starts, instead of exploring the repo again, which also saves tokens. Feeds stages 1 and 2.
- **Oby today:** Missing. The second #6 job knew nothing of the first. Oby's Tetrix login waits on #28.
- **Claude Code:** CLAUDE.md, AGENTS.md and auto memory. Projects keep a MEMORY.md and up to 16,000 characters of instructions. Tag remembers per channel.
- **Cursor:** MEMORIES.md for automations. Projects keep shared files. Bugbot learns from `@cursor remember`.
- **Codex:** AGENTS.md. Its memory is described only by third parties.
- **Others:** Copilot Memory is per repo, cited, expires in 28 days and is off by default. Devin has a knowledge base and playbooks.
- **Open for Oby:**
  - Proposal: Tetrix sessions with digests, and a `Tetrix-Session` line on every PR.
  - Decide: unblock #28 (the Keycloak client) before the Lead ships?

### X.3 When Oby may interrupt you
- **What happens:** only for a decision only you can make, a hard stop (a secret, or the same failure after every round), or done. Everything else waits for the report.
- **Oby today:** Broken. Every plan needs a Dispatch tap, and every Publish needs Touch ID.
- **Claude Code:** Projects shows "Waiting on you" and can be told to post only when finished or blocked. Auto mode pauses after repeated blocks.
- **Cursor:** a push when an agent finishes, needs input or is ready for review.
- **Codex:** Allow/Deny cards in Slack.
- **Others:** Devin's coordinator handles its children's questions, with optional batch approval. Copilot sends a review request when done.
- **Open for Oby:**
  - Decide: a push for "done", or only for "needs you"?
  - Decide: one push per goal, or per job?
  - Decide: quiet hours?

### X.4 Remember how you decide: decisions and preferences
- **What happens:** every question or permission request from any worker (Claude Code, Codex, Cursor) goes to Oby first. Oby answers from what it knows about you, fetched from the graph only when the situation calls for it: past answers, past actions, the repo's AGENTS.md, CODEOWNERS. Only what it knows nothing about reaches you, and your answer is learned. Oby also learns from what you do: the reviewer you pick, where you merge, the PR you close. Next time it applies what it learned and names it in the report. Applies at every stage, and it's what keeps X.3 quiet.
- **Oby today:** Missing. There's only Settings (models, accounts, runner), and nothing is learned from your answers.
- **Claude Code:** CLAUDE.md and auto memory carry your preferences into every session. Projects keep a MEMORY.md and up to 16,000 characters of instructions. Tag remembers per channel.
- **Cursor:** MEMORIES.md for automations. Bugbot learns rules from `@cursor remember`.
- **Codex:** AGENTS.md. Memory beyond it is described only by third parties.
- **Others:** Copilot Memory is per repo, cited, expires after 28 days and is off by default. Devin has a knowledge base, and suggests new entries for you to approve.
- **Open for Oby:**
  - Decided 2026-10-10: yours only (each Oby is personal), no expiry, and always learn from what you do. Stored in the Tetrix graph, not loaded into every prompt.
  - Proposal: Oby's fixed rules always come first, and nothing learned can override them: agents never push, no secrets go out, untrusted text stays data.
  - Proposal: Tetrix already holds your GitHub history (who reviewed what, where you merged), so Oby learns from it with nothing new to collect.
  - Open: Tetrix keeps owner-only items out of graph search today. Personal memory needs owner-only items to be searchable.
  - Open: how do you see and correct what Oby learned?

### X.5 Oby's work queue: requests handled one by one
- **What happens:** everything that comes in waits in one durable queue: your goals, workers' questions and permission requests, review comments, red CI. The Lead takes them one at a time, in priority order: you first, then hard stops, then workers, then GitHub events, then new work. Events about the same job are merged, so three review comments in a minute make one round. Jobs still run in parallel. Each event goes to the stage it belongs to.
- **Oby today:** Partial. Worktree setup is serialized per repo, and everything else starts at once. Plans sit in memory (the last 20) and are lost on restart.
- **Claude Code:** Code Review queues a review when one is already running. Routines never reuse a session across events.
- **Cursor:** not found.
- **Codex:** automations feed an inbox.
- **Others:** Devin's preflight step dedupes events by id and version, and a full queue drops new ones. Copilot: not found.
- **Open for Oby:**
  - Proposal: the queue lives in the runner's database, so it survives restarts and the Mac and iPhone see the same one.
  - Decide: one Lead for everything in strict order, or one per goal (goals side by side, events within a goal in order)?

### X.6 Your inbox: like email, items wait for you
- **What happens:** anything Oby can't decide, or only you can do, waits in your inbox until you decide. The job that asked waits, and the rest keep going. The same question from several workers shows once. Each decision teaches Oby, which then rechecks the inbox and clears what it can now answer itself. The decision goes back to the job that asked. Full design: "Your inbox" above.
- **Oby today:** Missing. There's one slot: a new plan or question replaces the card on screen (`Desk.talk`).
- **Claude Code:** Projects group threads under "Waiting on you", agent view marks "Needs input", and Remote Control pushes each prompt to your phone.
- **Cursor:** a push for each agent that needs input; you reply in each Slack thread.
- **Codex:** an Allow/Deny card for each request in Slack.
- **Others:** Devin's coordinator answers its children's questions first. Tetrix (ours) has a question queue with open, answered and skipped states, and a skipped question comes back later.
- **Open for Oby:**
  - Decided 2026-10-10: an inbox like email. Items wait for your decision: no timeout, no guessing. You work through a list, and the next item opens after each decision.
  - Full design: "Your inbox", I.1–I.7.

### X.7 With or without Tetrix: Tetrix is optional
- **What happens:** Oby works fully on its own. What it learns, job summaries and the work queue live in `oby.sqlite` on the Mac or the runner. They're searched with SQLite's built-in full-text search, so only what fits the situation is fetched. With Tetrix, the same entries are mirrored to the graph, and Oby gains your GitHub history, file-overlap predictions and past jobs across devices. If Tetrix is down, nothing stops. Affects X.2, X.4, 2.1 and 5.1.
- **Without Tetrix:**

  | Needs Tetrix for | Fallback |
  |---|---|
  | Memory between jobs (X.2) | Job summaries in `oby.sqlite` |
  | What Oby learned (X.4) | Entries in `oby.sqlite` |
  | File overlap (2.1) | The Lead's file list, checked against the real diff |
  | Reviewers (5.1) | CODEOWNERS, then your past choices |
  | Learning from GitHub history | What Oby saw itself, or a `gh` lookup when needed |

- **Oby today:** Partial. `oby.sqlite` holds jobs only. Tetrix is only a read tool for agents, on the Deskree Claude account.
- **Claude Code:** memory is local Markdown: a MEMORY.md index (its first 200 lines load every session) and topic files read on demand. It's never synced across machines and is edited with `/memory`. Permission rules live in `settings.local.json`, reviewed with `/permissions`.
- **Cursor:** rules live in `.cursor/rules/*.mdc` and load always, by file pattern, or when the agent decides. Permissions are in `permissions.json`. Memories are kept inside Cursor (2nd-hand).
- **Codex:** AGENTS.md for required guidance. Memories are off by default, generated into `~/.codex/memories`, and not meant to be edited by hand.
- **Others:**
  - Devin keeps knowledge in the cloud, each entry with a trigger description, fetched when relevant.
  - Copilot's memories cite their source and are checked against the current branch.
- **Open for Oby:**
  - Decided 2026-10-10: Tetrix is optional, and Oby never requires it.
  - Proposal: rules Oby applies itself (permissions, reviewer per repo) are stored as rows Swift reads directly. Preferences are entries with a "when this applies" line, like Devin's triggers, fetched by search.
  - Decide: also keep a readable Markdown copy for you and any LLM, like Claude Code's memory folder?

---

## Evidence from Oby's own runs

From the runner's database on tetrix-lab (`/srv/nvme/oby/oby.sqlite`, 7 jobs, 2026-10-09):

- **The first roadmap request** ("get some roadmap issues from OB…") left no job and no log line.
- **Job 30b93910 (Codex):** told to "find the top roadmap issue". The board was out of reach, so it picked #6 by number. It couldn't make a signed commit and ended "done" with 0 commits.
- **Job 93887146 (Codex):** the same request again. It picked #6 again and opened PR #55.
- **#6 (F2)** is merged into dev and only waiting for the owner's test. #36's checklist is unchecked, although Publish, accounts, Codex and routing are merged.

## Sources (checked 2026-10-10)

- **Claude Code** (https://code.claude.com/docs/en/): github-actions, slack, claude-code-on-the-web, claude-projects, agent-view, routines, code-review, cloud-environments, permission-modes, sandboxing, worktrees, desktop, remote-control, errors, overview
- **Claude Tag** (https://claude.com/docs/claude-tag/): overview, users/proactivity, users/use-cases/fix-bugs
- **Cursor:**
  - https://cursor.com/docs/cloud-agent, plus /capabilities
  - https://cursor.com/help/ai-features/automations
  - https://cursor.com/docs/bugbot
  - https://cursor.com/docs/integrations/linear and /slack
  - https://cursor.com/changelog/projects
  - https://cursor.com/docs/configuration/worktrees
  - https://cursor.com/blog/ios-mobile-app
  - Cursor forum thread on commit attribution (2nd-hand)
- **Codex:**
  - https://learn.chatgpt.com/docs/: cloud, third-party/github, third-party/slack, cloud/internet-access, automations, environments/git-worktrees, agent-approvals-security
  - https://developers.openai.com/codex/pricing
  - https://openai.com/index/codex-now-generally-available
  - hamy.xyz on draft PRs (2nd-hand)
- **GitHub Copilot:**
  - https://docs.github.com/copilot/concepts/coding-agent/about-copilot-coding-agent
  - kick-off-a-task, review-copilot-prs, customize-the-agent-firewall, manage-and-track-agents, copilot-memory
  - changelog 2026-04-13 (fix merge conflicts)
  - changelog 2026-02-13 (Agentic Workflows)
- **Devin** (https://docs.devin.ai/): product-guides/automations, work-with-devin/advanced-capabilities, integrations/linear, integrations/gh, use-cases/gallery/devin-review-autofix
  - Cognition blog on autofix
  - Cognition knowledge base on credit limits (2025, may be stale)
- **Others:** https://github.com/BloopAI/vibe-kanban, https://docs.factory.ai/integrations/linear
- **Inbox research (2026-10-10):**
  - docs.github.com: managing notifications from your inbox, inbox filters
  - linear.app/docs: inbox, triage, triage-intelligence
  - blog.superhuman.com/the-next-superhuman-ai/
  - hey.com/features: the Screener, the Imbox
  - support.google.com/mail: answers 186543 and 186531
  - code.claude.com/docs/en: agent-view, claude-projects, remote-control, agent-sdk/user-input, permissions, memory, interactive-mode
  - developers.openai.com/codex: app/automations, agent-approvals-security, memories
  - cursor.com: changelog/ios-mobile-app, docs/agent/run-modes, docs/context/rules, docs/reference/permissions
  - docs.devin.ai/product-guides/knowledge
  - docs.github.com/en/copilot/concepts/agents/copilot-memory
  - vibekanban.com/docs
- **Vault research (2026-10-10):**
  - code.claude.com/docs/en: security, cloud-environments, sandboxing
  - learn.chatgpt.com/docs/environments/cloud-environment
  - cursor.com/docs/cloud-agent: security-network, security
  - docs.github.com: Copilot cloud agent secrets and variables, risks and mitigations
  - docs.devin.ai/product-guides/secrets
  - 1password.dev: cli/secrets-environment-variables, cli/app-integration-security, ssh/agent, security-for-ai
  - bitwarden.com/help/secrets-manager-cli
  - developer.apple.com: TN3137, protecting keys with the Secure Enclave, SecAccessControlCreateFlags
  - github.com/remko/age-plugin-se
  - git-scm.com/docs/gitcredentials
  - the sudo(8) man page
  - vercel.com changelog on credential injection
  - docs.deno.com/sandbox/security
  - systemd.io/CREDENTIALS
  - Cloud Security Alliance note on "Comment and Control" (2nd-hand)
  - 0din.ai on the Cursor README attack (2nd-hand)
  - simonwillison.net on the lethal trifecta
- **Oby's own spikes:** deskree-inc/oby#31 (the brain on any tool), #24 (Cursor with two accounts), #23 (switching accounts near a limit), #28 (Tetrix login)
