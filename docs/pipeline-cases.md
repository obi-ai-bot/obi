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
- **Oby is a whiteboard (2026-10-10).** Like Claude Code, Cursor and Codex, it starts as a generic default pipeline. You reshape it by telling it, for example "add a Slack ping as a step", and over time it learns how you work, until the process is as automatic as possible.
- **Oby talks (2026-10-10).** Oby is an assistant you reach with as little effort as possible. It asks in the conversation when it needs something, instead of popping up UI. It answers in words you read, and you type or speak (hold fn, like Wispr Flow). Spoken replies come later.
- **Cost first (2026-10-10).** When two choices are otherwise equal, Oby picks the cheaper one, for example acting only on reviews that request changes (5.2).
- **Reviews go Oby to Oby (2026-10-10).** Requests go to the reviewer's Oby inside Oby, not through Slack (unless you add Slack as a step). See 5.1.
- **AGENTS.md rewritten to match (2026-10-10).**
  - Oby merges a PR into `dev` after the review approves and CI is green. It merges `dev` into `main` only when a feature's "Test it when it's done" list passes and CI is green on `dev`. It never pushes straight to `main`.
  - It force-pushes only branches it created.
  - Nothing goes out unless the checks, the Lead's review and the secret scan pass.
  - Vault secrets never reach an agent.

## Roadmap

Being built in deskree-inc/oby#68, in this order:
1. #62 Before Oby works alone: logs, honest endings, fenced secrets, a true board
2. #63 Spike: the Lead's turn
3. #64 Oby leads
4. #65 Your inbox and a conversation
5. #66 From PR to merge without you
6. #67 Oby learns how you decide

Related issues:
- F17 #60: the vault.
- F12 #16: Oby-to-Oby reviews.
- F14 #18: models chosen at first launch.
- F3 #7: rewritten as "Safe when nobody is watching".
- F6 #10: Gemini is out of the MVP.
- #28: Tetrix sign-in.

## How it works

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
- **Decided 2026-10-10:** you choose at first launch, from defaults Oby fills in: Sonnet 5.5 for routine jobs, Opus 5.5 for complex ones, and Fable 5.1 only when you allow it.

### 0.2 Only Codex
- **What happens:** Oby asks Codex which models this account may use (`model/list`, which includes each model's efforts) and picks from that list, never from a hard-coded name. Goes to 1.
- **Lead thinks with:** a Codex model at lower effort. Which one is still to check.
- **Jobs work with:** gpt-6-sol at high effort today. The code's default is gpt-6.1-sol, which a ChatGPT Plus login can't use. gpt-6-astra is stronger but uses up a Plus plan fast.
- **Typed plan:** enforced. `codex exec --output-schema` was 4 of 4 valid in #31, at about 9 s and 18k tokens a call. Whether app-server turns accept a schema is still to check.
- **Oby today:** Broken. Jobs run on Codex, but planning is Claude-only: without Claude, Oby falls back to keyword rules.
- **Decided 2026-10-10:** you choose at first launch, from the account's own list: a smaller Codex model for routine jobs, a stronger one for complex jobs, and Astra only if you pick it.

### 0.3 Only Cursor
- **What happens:** Oby lists the account's models with `agent models` after you sign in, picks two and shows them. Goes to 1.
- **Lead and jobs:** unknown until we can list the models. The Cursor CLI on Wellington's Mac (2026.10.01) isn't signed in. Using two Cursor accounts is spike #24.
- **Typed plan:** not enforced. The CLI returns a JSON wrapper with free text in `.result` (#31). The schema goes in the prompt, and Swift checks the reply and retries.
- **Oby today:** Missing. There's no Cursor runner yet (F6, #10) and no Cursor brain.
- **Decided 2026-10-10:** the same flow. Oby proposes defaults from the account's list, and you choose.
- **Decided 2026-10-10:** with only Cursor connected, Oby shows a warning that it may ask you more often.

### 0.4 Only Gemini
- **What happens:** same as Cursor: list the models, pick, show. Goes to 1.
- **Lead and jobs:** unknown.
- **Typed plan:** not enforced. Free text in `.response`. Google ended personal sign-in for the CLI on 2026-06-18, so it needs an API key or Vertex.
- **Oby today:** Missing. Not built (F6).
- **Decided 2026-10-10:** not in the first version. The MVP covers Claude Code, Codex and Cursor, the three Deskree uses most.

### 0.5 Several tools
- **What happens:** one tool thinks, and jobs spread across every account by usage. First launch shows "Oby thinks with X and works with Y and Z". Goes to 1.
- **Lead thinks with:** the best planner connected: Claude (enforced schema), then Codex, then Cursor, then Gemini.
- **Jobs work with:** every connected account, routed by usage. The score is the higher of the 5-hour and 7-day use, plus 0.15 per running job.
- **Oby today:** Partial. Jobs are routed across Claude and Codex, and the brain is always Claude.
- **Decided 2026-10-10:** you pick the Lead's model at first launch, like the jobs' models. If you connect a new tool later, Oby asks in the conversation whether to change anything: no pop-ups.
- **Approved 2026-10-10:** the Lead's own usage counts toward routing.

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
- **Decided 2026-10-10:** only its job. Other jobs, worktrees and agents keep going.

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
- **Decided 2026-10-10:** yes, once you tell it to ("don't ask, review it yourself"). Near your limits, it asks before spending them on someone else's review.

### I.5 Follow-up
- **Lands here when:** something waits on someone else: a silent reviewer, a flaky check, a blocked dependency.
- **Your actions:** Nudge, Hand to someone else, or Later.
- **What Oby learns:** when to nudge on its own, and whom to hand work to.
- **How others do it:**
  - Google: respond within one business day at most.
  - Meta's NudgeBot pings after 24 hours with no action, and cut time to a reviewer's first action by 9.9%.
  - Microsoft's Nudge sends one reminder per PR and skips PRs with activity in the last 24 hours and weekends. Naive nudges drew 53% negative replies; the refined system was about 80% positive.
  - GitHub scheduled reminders default to weekdays at 9:00, with age and staleness filters.
  - GitHub team assignment can load-balance reviewers and skips people marked Busy.
  - Superhuman reminds you about mail that needs a reply, and Linear snoozes until new activity.
- **Decided 2026-10-10:**
  - Obys are the main reviewers, so waits are short, apart from limit resets.
  - A person marked as reviewer is always waited for. Oby never merges without their review, and it swaps them only where GitHub's branch rules and CODEOWNERS allow, through a Follow-up to you.
  - Nudging a person follows best practice (delegated by Wellington):
  - The first nudge comes after one business day with no reviewer activity, counted in the reviewer's working hours. Any comment, commit or review resets the clock.
  - At most two nudges per PR (day 1 and day 3), then Oby stops pinging.
  - Weekdays only, in the reviewer's time zone, skipping holidays and time off. One daily digest per reviewer, never a ping per comment.
  - After 3 business days of silence, a Follow-up in your inbox offers a second reviewer, where the rules allow a swap: someone with a light load, skipping anyone Busy or out of office. Oby never swaps reviewers silently, and it learns your answer (X.4).
  - When the reviewer is another Oby, it should acknowledge within minutes to an hour. If it doesn't, Oby retries once, then falls back to the human path.

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
  - Decided 2026-10-10: anything workable, in board order. Oby skips what's done, in review, blocked, waiting for your test or assigned to someone else, and an `oby:skip` label keeps an item out. Oby keeps the board's statuses true as it works.

### 1.2 Named issues or an epic: "#12, #15 and #18", "epic #30"
- **What happens:** one job per issue. An epic becomes one job per open sub-issue, and sub-issues that depend on each other run in order. Goes to 2.
- **Oby today:** Partial. Up to 10 jobs; epics through the sub-issues API or the task list (#44, #45). Each plan still waits for a Dispatch tap.
- **Claude Code:** `claude --bg` and `--cloud` run parallel sessions, each in its own worktree. Projects turns several tasks or a spec into threads and can propose them first; the cap is 200 threads a day.
- **Cursor:** Projects delegates to many parallel agents. No documented cap for cloud agents.
- **Codex:** each cloud task runs in its own workspace, in parallel. No epic splitting found.
- **Others:** Copilot does one task, one branch, one PR. Devin's coordinator splits big tasks into child Devins, each in its own VM, and you can approve each batch.
- **Open for Oby:**
  - Proposal: keep Swift's epic expansion. The Lead orders dependent sub-issues, and the Dispatch tap goes away.
  - Decided 2026-10-10: no fixed cap. Oby runs as many jobs as your accounts' remaining limits allow, routed by how big each job is and how much room each account has.
  - Open: the machine (tetrix-lab's CPU and memory) is the other limit.

### 1.3 Already taken: in progress, in review, waiting for your test
- **What happens:** before starting, check for an open PR on the issue, an Oby job on it, an assignee, and the board status. Skip it and say why. Goes to the skipped list in the report.
- **Oby today:** Missing. Nothing checks. #6, waiting for your test, got two jobs and PR #55.
- **Claude Code:** Code Review skips PRs it already commented on, and Tag flags duplicate requests. No assignee or open-PR check is documented.
- **Cursor:** Bugbot avoids repeating existing PR comments. No issue-level check found.
- **Codex:** not found.
- **Others:** Devin's preflight script dedupes by item id and version. Copilot: not found.
- **Open for Oby:** nobody has a claim check.
  - Decided 2026-10-10: when a job starts, Oby assigns the issue to you and moves it to In progress. Swift refuses a job on an issue that already has a running job or an open PR.

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
  - Decided 2026-10-10: Oby plans the work to keep conflicts rare. Each job claims the files it will touch, and overlapping jobs run one after another.
  - With Tetrix, `code_impact` predicts overlap. Without it, the Lead's list is checked against the real diff (X.7).

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
  - Decided 2026-10-10: network by allowlist. The first time a job wants a new site, it asks you. A yes adds that site to your allowlist, shown as a rule you can remove.
  - Approved 2026-10-10: start from a small list of package registries, so the first job doesn't flood your inbox, the way Claude Code cloud's "Trusted" level does.
  - Approved 2026-10-10: ask separately before a job sends data to a new site, because that's how secrets leak. The vault's proxy enforces both rules.

### 2.3 Stuck: needs a decision only you can make
- **What happens:** the job asks the Lead first. The Lead answers from the issue, the roadmap, Tetrix and past jobs. Only a real product decision reaches you, as one question with options. Goes back to 2, or to you.
- **Oby today:** Partial. You can talk to a job, but nothing notices when it's stuck, and questions only come from the brain before dispatch.
- **Claude Code:** Remote Control pushes questions to your phone. Agent view marks "Needs input", Projects has "Waiting on you", and Tag asks in the Slack thread.
- **Cursor:** iOS Live Activities and a push when an agent needs input or is ready; you reply in the Slack thread.
- **Codex:** a private Allow/Deny card in Slack. Mobile push not found.
- **Others:** Devin's coordinator is woken when a child needs input. Copilot requests your review when done, and you can steer a running session.
- **Open for Oby:**
  - Proposal: the Lead answers first, from what Oby has learned about you (X.4) and the graph. Only what it knows nothing about reaches you, through the Live Activity and a push, and your answer is learned.
  - Decided 2026-10-10: spending, deleting and security always reach you, even if Oby could guess, unless you tell it to handle one of them itself. Oby first shows you the risks, and your choice becomes a rule.

### 2.4 Usage limit: the account runs out mid-job
- **What happens:** the job pauses, then carries on with another account of the same tool (same worktree, a new session given the summary so far) or waits for the reset. Goes back to 2.
- **Oby today:** Partial. Routing skips accounts at 95% when a job starts. A job already running on a full account just fails.
- **Claude Code:** shows the reset time, and interactive sessions can continue at the reset. Headless auto-resume is undocumented. Project threads retry after the reset.
- **Cursor:** not found.
- **Codex:** 5-hour and weekly limits. What happens mid-task: not found.
- **Others:** Devin sleeps at its credit limit until woken (from 2025, may be stale). Copilot sessions stop at 59 minutes.
- **Open for Oby:**
  - Decided 2026-10-10: the first time, Oby asks whether to move the job to another account or wait for the reset, and shows #23's terms note.
  - From then on it does what you said, until you change it or describe a case that calls for something else, like "switch for urgent jobs". Rules can carry a condition (X.7's "when this applies").

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
  - Decided 2026-10-10: all of them in the first version: API keys, sudo and logins.

---

## 3 · Test until green

A job counts as done only when its check passes. Then the Lead reviews the diff against the brief and sends it back until it's satisfied.

### 3.1 Tests fail
- **What happens:** Oby runs the job's check itself, for example `swift test`. On failure, the output goes back to the agent for another round, within limits that Oby holds, never the agent. Goes to 4 when green and the Lead approves, or to your inbox when the limit is hit.
- **Oby today:** Partial. A check command and rounds, or the agent's own GOAL MET line (#44), but only when the brain set a check. No time limit and no no-progress check.
- **Claude Code:** turn and budget caps (`--max-turns`, `--max-budget-usd`) are off by default. A Stop hook can send the agent round again, and Claude Code overrides it after 8 blocks in a row. Cloud Auto-fix pushes clear fixes. Nothing guards against test cheating.
- **Cursor:** Bugbot Autofix makes at most 3 attempts per PR in 24 hours, and stop hooks loop at most 5 times. CI auto-fix works on its own PRs. The CLI has no turn limit.
- **Codex:** no turn limit found, though goals take a token budget. CI fixes only on demand. The sandbox keeps `.git` read-only.
- **Others:**
  - OpenClaw: a 48-hour default limit, and 3 identical tool errors end a turn.
  - Hermes: goals pause after 20 turns, and test gates retry 3 times. An optional check refuses "done" without fresh test evidence.
  - Copilot: a hard 59-minute cap.
  - None moves to a stronger model by itself.
  - METR has documented models editing tests and scorers to pass.
- **Open for Oby:**
  - Decided 2026-10-10: 1 attempt and 3 fix rounds. About 15 minutes a round, 45 minutes a job, 10 minutes a test run.
  - Stop early when the same failure repeats twice (failures compared with timestamps and durations stripped), the failure count doesn't drop in 2 rounds, a round changes nothing, or 3 actions in a row are denied.
  - At the limit: stop, keep the branch and push nothing. The inbox offers "one more round" or "one more round on the stronger model".
  - Limits live in Swift, never in prompts, and Oby tunes them per repo (X.4).
  - Inside a round: Claude Code jobs run with `--max-turns` and Oby's own timer. Codex and Cursor have no turn limit, so the timer alone applies.

### 3.2 No test command: the check isn't obvious
- **What happens:** the Lead finds the check in the repo: AGENTS.md, the CI workflow, Package.swift. If there's none, the agent writes a test for its change. Goes to 3.1.
- **Oby today:** Missing. There's a check only when you name one.
- **Claude Code:** commands live in CLAUDE.md, and project instructions can require test-summary lines in the final message.
- **Cursor:** not found.
- **Codex:** commands live in AGENTS.md.
- **Others:** not found.
- **Open for Oby:**
  - Decided 2026-10-10: tests are a hard gate twice: they must pass in the worktree before the PR opens, and CI must be green on the PR before the merge.
  - Decided 2026-10-10 (strict): Oby runs the tests itself. A round fails on deleted or edited existing tests, new skip markers, a falling test count, or changed test or CI config. New tests are allowed and flagged for the Lead, which asks for a test with every change.

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
  - Decided 2026-10-10: under your GitHub account, always ready for review, never a draft.
  - Signing is automatic. Agents commit unsigned, and Oby signs at push with your own signing key, which never reaches an agent. On tetrix-lab the key lives in the vault (F17). GitHub signs the squash-merge into `dev`.
  - Approved 2026-10-10: the PR and Oby's comments say "by Oby", so teammates know a machine wrote them.

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
- **What happens:** request a review from the owner on GitHub, and send the request to their Oby with the PR link and three lines on what changed. Slack happens only if you add it to your workflow as a step. Then wait for the review.
- **Oby today:** Missing. No review request and no Slack yet (F10).
- **Claude Code:** Tag's PRs land in your review queue, linked to the Slack thread, and routines can post a Slack summary. CODEOWNERS: not found.
- **Cursor:** automations can request reviewers, and Slack gets a completion message with the PR link.
- **Codex:** the result goes back to the Slack thread.
- **Others:** Copilot requests your review, and your approval doesn't count toward the required ones. Devin posts the PR link on the Linear ticket.
- **Open for Oby:**
  - Decided 2026-10-10: reviews go Oby to Oby, inside Oby (F11, F12), not through Slack.
  - The reviewer's Oby asks its person once: "review it yourself, or shall I?" "Don't ask, review it yourself" becomes a rule.
  - Near the reviewer's limits, their Oby asks again before spending them.
  - Who reviews: CODEOWNERS or your past choices. Otherwise Oby asks once and remembers (X.4).
  - Nudges: see I.5 in your inbox.

### 5.2 Changes requested
- **What happens:** each review that requests changes becomes another round for the same job, in the same worktree and session. It tests again, pushes, replies and asks for a new review, until approved. Goes to 3, then back to 5.
- **Oby today:** Partial. Talking to a finished job picks its session up again, but nothing watches the PR.
- **Claude Code:** cloud Auto-fix pushes clear fixes and asks you about unclear ones, replying under your account labelled Claude Code. Project threads watch their PR. The GitHub Action acts only on @claude.
- **Cursor:** Bugbot Autofix pushes to the PR branch (3 attempts at most) or to a new branch.
- **Codex:** `@codex fix the P1 issue` pushes if allowed. Handling of requested changes isn't documented.
- **Others:** Devin's Auto-Fix pushes commits. It acts on other bots' comments only if allowed, because "all bots" can loop. Copilot acts only on @copilot.
- **Open for Oby:**
  - Decided 2026-10-10: only reviews that request changes start a round, to keep cost down. Plain comments are read as context in that round.
  - Approved 2026-10-10: the runner polls Oby's open PRs every minute.
  - Approved 2026-10-10: after 3 review rounds, Oby asks you (Bugbot stops at 3).

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
- **What happens:** Oby rebases the job's branch onto dev, the agent resolves the conflicts, the tests run again, and Oby pushes. Goes to 3.
- **Oby today:** Missing.
- **Claude Code:** GitHub sends no event for a conflict. You ask Claude to rebase, or press "Resolve conflicts".
- **Cursor:** not found.
- **Codex:** not automatic.
- **Others:** Copilot has `@copilot` and a "Fix with Copilot" button. Devin has a scheduled check for stale PRs.
- **Open for Oby:** nobody does this on their own.
  - Decided 2026-10-10: with parallel work, Oby always accounts for rebasing. Once a job is done, it rebases the job's branch onto dev (rather than merging dev into the branch) when the PR opens.
  - It rebases again whenever a conflict appears while the PR waits for review. The tests run again (3.2), and Oby force-pushes the job's own branch, which AGENTS.md allows.
  - Proposal: GitHub's merge queue does this natively for PRs waiting together. It's off for oby today.
  - Note: a rebase after approval may need a fresh approval, depending on branch rules ("dismiss stale approvals").

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
  - Decided 2026-10-10: Oby merges approved PRs into `dev`.
  - It merges `dev` into `main` when a feature's "Test it when it's done" list passes: you confirm the real-Mac items, Oby checks the rest, and CI is green on `dev`. Then it fast-forwards `dev`, as the release flow does today.

## 7 · Report back

### 7.1 Report
- **What happens:** each job carries its own report, shown on the notch and the iPhone and saved in the Tetrix session:
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
  - Decided 2026-10-10: the report stays in its job, as today, with a much better screen.
  - Clear only hides a job. A history list keeps it, and you can ask Oby about any past job and get the answer in words.
  - Open: redesign the job report screen on the Mac and the iPhone. Today's screen is hard to read.

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
  - Decided 2026-10-10: only a change request from the PR's assigned reviewers or code owners starts work. Anyone else's review is shown to the Lead as information.

### X.2 Memory between jobs
- **What happens:** every job is saved to Tetrix: summary, decisions, files. The Lead reads what was done before it starts, instead of exploring the repo again, which also saves tokens. Feeds stages 1 and 2.
- **Oby today:** Missing. The second #6 job knew nothing of the first. Oby's Tetrix login waits on #28.
- **Claude Code:** CLAUDE.md, AGENTS.md and auto memory. Projects keep a MEMORY.md and up to 16,000 characters of instructions. Tag remembers per channel.
- **Cursor:** MEMORIES.md for automations. Projects keep shared files. Bugbot learns from `@cursor remember`.
- **Codex:** AGENTS.md. Its memory is described only by third parties.
- **Others:** Copilot Memory is per repo, cited, expires in 28 days and is off by default. Devin has a knowledge base and playbooks.
- **Open for Oby:**
  - Proposal: Tetrix sessions with digests, and a `Tetrix-Session` line on every PR.
  - Decided 2026-10-10: unblock #28 now. The realm admin registers the `oby-desktop` client, or clears the stale dynamically registered clients. The Lead still runs on local memory whenever Tetrix isn't there.

### X.3 When Oby may interrupt you
- **What happens:** only for a decision only you can make, a hard stop (a secret, or the same failure after every round), or done. Everything else waits for the report.
- **Oby today:** Broken. Every plan needs a Dispatch tap, and every Publish needs Touch ID.
- **Claude Code:** Projects shows "Waiting on you" and can be told to post only when finished or blocked. Auto mode pauses after repeated blocks.
- **Cursor:** a push when an agent finishes, needs input or is ready for review.
- **Codex:** Allow/Deny cards in Slack.
- **Others:** Devin's coordinator handles its children's questions, with optional batch approval. Copilot sends a review request when done.
- **Open for Oby:**
  - Decided 2026-10-10: every new inbox item notifies you, because it means Oby couldn't handle it. Nothing else does.
  - No quiet hours: items simply wait in the inbox until you're there.

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
  - Decided 2026-10-10: you see and correct what Oby learned by talking to it. A list in Settings is the secondary way, never the first.

### X.5 Oby's work queue: requests handled one by one
- **What happens:** everything that comes in waits in one durable queue: your goals, workers' questions and permission requests, review comments, red CI. The Lead takes them one at a time, in priority order: you first, then hard stops, then workers, then GitHub events, then new work. Events about the same job are merged, so three review comments in a minute make one round. Jobs still run in parallel. Each event goes to the stage it belongs to.
- **Oby today:** Partial. Worktree setup is serialized per repo, and everything else starts at once. Plans sit in memory (the last 20) and are lost on restart.
- **Claude Code:** Code Review queues a review when one is already running. Routines never reuse a session across events.
- **Cursor:** not found.
- **Codex:** automations feed an inbox.
- **Others:** Devin's preflight step dedupes events by id and version, and a full queue drops new ones. Copilot: not found.
- **Open for Oby:**
  - Proposal: the queue lives in the runner's database, so it survives restarts and the Mac and iPhone see the same one.
  - Decided 2026-10-10: one Lead per goal. Goals move side by side, and each Lead's context stays small, which keeps turns cheap. 2.1's file claims keep two Leads off the same files.

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
  - Decided 2026-10-10: no second copy kept in sync. "Export what you know" writes a Markdown file whenever you or another AI needs one.
  - Claude Code keeps its memory as Markdown, and Cursor its rules. Codex generates memory files it says not to edit.

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
- **Guardrails research (2026-10-10):**
  - code.claude.com/docs/en: cli-reference, agent-sdk/agent-loop, hooks-guide, goal, permission-modes, scheduled-tasks, routines, sandboxing
  - cursor.com: docs/bugbot, workflows/autonomous-agents/ci-autofix, docs/hooks, docs/cli/headless, docs/agent/security/run-modes
  - Cursor forum threads on Bugbot limits and on hard stops (2nd-hand)
  - developers.openai.com/codex: app-server, agent-approvals-security
  - learn.chatgpt.com/docs/hooks
  - docs.openclaw.ai: concepts/agent-loop, tools/loop-detection, gateway/sandboxing, tools/exec-approvals
  - OpenClaw incident reports in TechCrunch and The Hacker News (2nd-hand)
  - hermes-agent.nousresearch.com/docs/user-guide: configuration, features/goals, security
  - docs.github.com: Copilot coding agent
  - metr.org/blog/2025-06-05-recent-reward-hacking
- **Review nudge research (2026-10-10):**
  - docs.github.com: managing scheduled reminders, managing code review settings for your team
  - google.github.io/eng-practices/review/reviewer/speed.html
  - sback.it/publications/icse2018seip.pdf
  - 2022.esec-fse.org: Using Nudges to Accelerate Code Reviews at Scale
  - engineering.fb.com/2022/11/16/culture/meta-code-review-time-improving
  - arXiv 2011.12468 (Microsoft Nudge)
  - axolo.co/docs/application-settings/reminders
  - linearb.io/library/engineering-benchmarks-and-research
  - graphite.com/blog/graphite-changelog-4-18-23
  - github.com/danielma/reviewbot
- **Oby's own spikes:** deskree-inc/oby#31 (the brain on any tool), #24 (Cursor with two accounts), #23 (switching accounts near a limit), #28 (Tetrix login)
