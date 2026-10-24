# Oby's conversation harness vs Claude Code's, mechanism by mechanism

Research snapshot: 2026-10-16, against `dev` (676b366). Companion to [claude-code-parity.md](claude-code-parity.md): that document compares the *products* from Claude Code's public docs. This one compares the *harness* (the part that turns what the user says into model calls, actions and an answer) from Claude Code's source, as published in the leaked snapshot of 2026-03-31 ([codeaashu/claude-code](https://github.com/codeaashu/claude-code)). Source references below are `cc:src/...` for that tree and plain paths for this repository.

> **Use ideas, not code.** That tree is leaked proprietary source. Oby is Apache-2.0. Copy mechanisms, thresholds and design rules described here. Never paste its code or prompt text into Oby.

## 0. The short version

- **Oby has two brains.** The Swift brain (`Engine/Brain.swift`, `Engine/Conversation.swift`, `Desk.plan` in `Engine/Desk.swift:941`, `Engine/Lead.swift`, `Engine/ResearchTools.swift`, `Engine/ReadJob.swift`, `Engine/JobActions.swift`, `Engine/Orchestrator.swift`) is rich and frozen. The `obid` brain (`core/crates/obid/src/brain.rs`) that replaces it is a one-shot: 4 actions, no briefing, no retries, no validation feedback, always Haiku, and the whole thread (up to 500 turns) in the prompt (#505). **The biggest single improvement is not a Claude Code feature: it is porting the Swift brain to `obid`.** `core/crates/obid/tests/PORTING.md` already lists 30+ brain tests as "obid has no brain".
- **The shapes differ on purpose.** Claude Code is a *model-driven tool loop*: the model calls tools, sees results, and keeps going until it stops calling tools. Oby is a *Swift-driven plan loop*: each step is a fresh `claude -p` that returns one typed action. Swift validates it (`Plan.problems`), carries it out, then asks again with "already did X". Oby's shape is safer: the model never acts, it only proposes. Keep it, and borrow the mechanisms *around* the loop.
- **Where Claude Code is far ahead:** memory and compaction, steering mid-turn, streaming, prompt caching, retries, measuring each call, how it writes briefs for workers, and completion gates.
- **Where Oby is already ahead:** typed actions with semantic validation and refusal feedback, a quoted-file channel for untrusted text, a canary, Claude → Codex → rules failover, a reply that can't contradict the header, a conservative event orchestrator, and start conditions.

---

## 1. The two loops side by side

| | Claude Code (`cc:src/query.ts`) | Oby Swift (`Desk.plan`) | Oby `obid` (`brain.rs`) |
|---|---|---|---|
| Who drives | The model (tool_use → result → next call) | Swift (plan → validate → act → re-plan) | Swift, one call |
| Unit of work | One API call per iteration, one long-lived process | One fresh `claude -p` process per step | One fresh `claude -p` |
| Ends when | No `tool_use` streamed, a stop hook, max turns, abort, budget | Reply/question/dispatch, a repeated action, 8 steps, a 110 s budget, stop | Always after one call |
| Outcome type | Typed `Terminal` / `Continue` reasons (`cc:src/query/transitions.ts`) | Strings, with `"Couldn't"` / `"Say which"` prefixes as failure signals (`Desk.swift:1115-1121`, `DeskStep.swift`) | HTTP status |
| Model | Main model, plus Haiku/Sonnet side calls | Haiku; Sonnet for later steps or text over 600 chars (`Brain.swift:818`) | `haiku` alias always |
| Output | Streamed text plus tools | `StructuredOutput` JSON (see §3.3) | Same |

---

## 2. Feature map

Each row lists one Claude Code mechanism, what each Oby brain does today, and the gap. ✅ = Oby has it (or better), 🟡 = partial, ❌ = missing. "Issue" names the open issue that already covers it, where one does.

### 2.1 Turn loop and control

| # | Claude Code mechanism | Where (cc) | Swift brain | obid | Gap / note | Issue |
|---|---|---|---|---|---|---|
| L1 | Agentic loop until no tool call | `query.ts:551-557` | ✅ up to `mostSteps = 8`, `turnBudget` 110 s (`Desk.swift:105,1134`) | ❌ one call | Port | #442 follow-up |
| L2 | Explicit state record per iteration, typed transition reasons | `query.ts:204-217`, `query/transitions.ts` | 🟡 locals (`done`, `taken`, `request`); failure found by matching reply prefixes | ❌ | Make step outcomes an enum (`acted`, `couldNot(reason)`, `askedUser`, `answered`, `budget`, `stopped`, `repeated`). Prefix matching breaks as soon as a reply is reworded. | #538 |
| L3 | Max turns | `query.ts:1704` | ✅ 8 steps | ❌ | | |
| L4 | Duplicate-action guard | (none: relies on model) | ✅ `signature` set (`Desk.swift:1149`) | ❌ | Oby is ahead | |
| L5 | Cooperative interrupt: finish the current tool, synthesize missing results, mark "interrupted" | `query.ts:1015-1052`, `handlePromptSubmit.ts:313` | ✅ Stop finishes the current action and says what was done (`stopConversation`) | ❌ | | #303 |
| L6 | **Queued steering messages read mid-turn** (a message typed while working is injected at the next iteration, priority `now > next > later`) | `query.ts:1535-1650`, `messageQueueManager.ts:49` | ❌ a new message replaces the turn | ❌ | Highest-impact missing control. Oby's step boundary is the natural injection point: before each `Planner.plan`, drain queued user words into `request`. | #379 (Part B) |
| L7 | **Stop hooks / completion gates** (a check can refuse to let the model stop and feed back why) | `query/stopHooks.ts`, `utils/hooks/execAgentHook.ts` | ❌ the brain says it's done by sending an empty `reply_only` | ❌ | Add a Swift completion check before the final reply: every repo/issue/job the user named was dispatched or acted on, or the reply says why not. If not, one more step with "you haven't handled X". | #539 |
| L8 | Stop hooks skipped after API errors (avoids error → hook → retry loops) | `query.ts:1258` | n/a | n/a | Apply to L7 | |
| L9 | Output-truncation recovery ("resume mid-thought, no recap") | `query.ts:1185-1256` | n/a (structured output) | n/a | Not needed while plans are small JSON | |
| L10 | Token-budget auto-continue | `query/tokenBudget.ts` | n/a | n/a | Not relevant | |

### 2.2 Model calls and reliability

| # | Claude Code mechanism | Where (cc) | Swift brain | obid | Gap / note | Issue |
|---|---|---|---|---|---|---|
| R1 | Retries with exponential backoff and jitter, `retry-after` honoured, 10 tries | `services/api/withRetry.ts:170-548` | 🟡 one process retry on empty output, exit 15 or timeout (`Brain.swift:716-734`), plus one plan retry per adapter | ❌ | Enough for a 20 s budget. obid needs at least Swift's. | #305 |
| R2 | Fallback model after 3× 529 | `withRetry.ts:327-365` | ✅ Claude → Codex → rules (`Planner.plan`) | ❌ | Oby's is broader (cross-vendor) | #307 |
| R3 | Foreground-only retries (background calls fail fast under load) | `withRetry.ts:62-89` | 🟡 inbox rewriter and brain are separate, but there is no policy | ❌ | Adopt the rule: InboxRewriter, titles and summaries never retry. | #537 |
| R4 | **Schema validation errors fed back to the model** | `SyntheticOutputTool.ts` (Ajv, up to 5 in-process retries) | ✅✅ plus *semantic* validation (`Plan.problems`: real job ids, accounts, repo, ranges) and "Your last plan was refused: …" (`Brain.swift:855`) | ❌ serde fails → 422 to the client, nothing retried (`brain.rs:84-316`) | Oby is ahead of Claude Code here; obid lost it | port |
| R5 | Model routing by difficulty | (side calls use Haiku/Sonnet) | ✅ Haiku vs Sonnet (`Brain.swift:818`) | ❌ | | #305 |
| R6 | Prompt-injection tripwire | (system prompt asks to flag it) | ✅ per-turn canary in the system prompt, refused if echoed | ❌ | Oby is ahead | port |
| R7 | **Cost, usage and duration per call** | `claude.ts:2924-3000`, `QueryEngine` result | ❌ `BrainTurn` logs words, plan and refusals, but no tokens, cost, cache reads, duration or `num_turns` | ❌ | `--output-format json` already returns `total_cost_usd`, `usage` (with `cache_read_input_tokens`), `duration_ms` and `num_turns`. Keep them on every brain turn. Everything in §3 needs this to be measured. | #533 |
| R8 | Stream idle watchdog, non-streaming fallback | `claude.ts:1868-2700` | 🟡 a hard timeout per attempt | 🟡 a hard 110 s timeout | Fine for one-shot JSON | |
| R9 | Thinking/effort set per request | `claude.ts:1595-1630` | ❌ not set for the brain (jobs get effort) | ❌ | Try a low effort for Haiku steps, medium for Sonnet steps; measure with R7 | #536 |

### 2.3 Context: what the model sees

| # | Claude Code mechanism | Where (cc) | Swift brain | obid | Gap / note | Issue |
|---|---|---|---|---|---|---|
| C1 | Sectioned system prompt; static sections before a cache boundary, dynamic after; sections memoized, uncached ones need a written reason | `constants/prompts.ts:444-577`, `systemPromptSections.ts` | 🟡 one string (`Planner.system`) with a per-turn canary in it | 🟡 a 1-line system prompt | See §3.3 | #534 |
| C2 | Environment and date block | `prompts.ts:651-710`, `context.ts` | ✅ "Now is …" with offset (`Briefing.stamp`) | ❌ | | port |
| C3 | **Fresh world state every iteration** (attachments: todo list, plan mode, task status, changed files, diagnostics…) | `utils/attachments.ts:743-1000` | ✅✅ the briefing is rebuilt every step: jobs grouped *Needs you → Working → Waiting → In review → Done*, inbox, failures, accounts and usage, settings (`Conversation.swift:186`) | ❌ none | This is Oby's strongest context feature, and obid has none of it | port |
| C4 | Untrusted text kept apart from instructions | system-reminder wrapping; tool results inline | ✅✅ agents' words only in `work.md`, read through `Read`, never in the prompt (`Briefing.quoted`) | ❌ | Oby is ahead | port |
| C5 | History window | Full transcript plus compaction | 🟡 last 50 turns, each cut to 500 chars (`Conversation.kept`) | ❌ every kept turn, uncut (#505) | | #505, #379 |
| C6 | **Compaction**: 9-section summary (intent, concepts, files, errors, problem solving, *all user messages*, pending tasks, current work, next step with verbatim quotes); analysis scratchpad stripped; transcript path linked for exact recall | `services/compact/prompt.ts`, `compact.ts:387-770` | ❌ | ❌ | #379 designs a structured summary with turn citations, which is better than free text. Add from the source: keep **every user message** (they are short and carry the constraints), and a "next step" quoted verbatim. | #379 |
| C7 | Re-hydration after compaction (recent files, plan, skills, running agents, "don't spawn a duplicate") | `compact.ts:1415-1706` | n/a (the briefing always carries jobs) | ❌ | Rule for #379: goals, jobs, inbox and memory never go into the summary, because they come from their own tables. #379 already says this. | #379 |
| C8 | **Session memory**: a rolling per-session notes file (Current State, Task, Errors & Corrections, Worklog…), updated in the background once growth passes a threshold. It doubles as an instant, model-free compaction summary. | `services/SessionMemory/*`, `compact/sessionMemoryCompact.ts` | ❌ | ❌ | For Oby, a per-conversation **state record** (goal, decisions, constraints, open questions, last outcome), updated by a Haiku side call after each turn that changed something and checked by Swift like a plan. The briefing reads it instead of 50 raw turns. Cheaper and steadier than summarizing on demand. | #379 |
| C9 | **Instruction memory** (CLAUDE.md user/project/local, `@imports`, path-scoped rules) | `utils/claudemd.ts` | ❌ the brain runs in a temp dir with `--setting-sources ""` | ❌ | #378 covers user and project scopes. Missing from #378: the brain also never sees the *target repo's* own conventions (its AGENTS.md or CLAUDE.md). For a dispatch to repo X, quote the first ~2 KB of X's AGENTS.md in `work.md`. | #378, #543 |
| C10 | **Auto memory**: typed (user, feedback, project, reference) with *why / how to apply*, a ≤200-line index, topic files on demand, "don't save what's derivable" | `memdir/*` | ❌ | ❌ | #378 designs this | #378 |
| C11 | **Relevance recall**: a cheap model picks ≤5 memories per turn, without blocking the turn, with per-turn and per-session caps | `memdir/findRelevantMemories.ts` | ❌ | ❌ | Add to #378 once memory passes ~50 entries: until then load the whole index | #378 |
| C12 | **Freshness labels**: "saved N days ago, verify before asserting", and "a memory naming X ≠ X exists now" | `memdir/memoryAge.ts`, `memoryTypes.ts:201-256` | ❌ | ❌ | Cheap and important: a remembered "reviews go on Codex" from 3 months ago should carry its age. Add to #378. | #378 |
| C13 | Background memory extraction after each turn (skipped if the main agent already wrote memory) | `services/extractMemories/*` | ❌ | ❌ | #378 has the user say "remember…". Add an optional extractor that *proposes* memories into the inbox ("Remember that reviews go on Codex?") instead of writing them, which keeps Oby's "Swift writes every file" rule. | #378 |
| C14 | Consolidation ("dream"): merge, absolute dates, delete contradictions, prune index; runs after 24 h and 5+ sessions | `services/autoDream/*` | ❌ | ❌ | Later, once memory exists | #378 |
| C15 | Re-read dedup, changed-file notices | `FileReadTool`, `attachments.ts:2063` | 🟡 a job read twice in one turn is quoted once (`JobReads`) | ❌ | | |
| C16 | Reply cannot contradict known state | (none) | ✅ `Briefing.contradicts` and `workingLine` | ❌ | Oby is ahead | port |

### 2.4 Tools the brain can use

| # | Claude Code mechanism | Where (cc) | Swift brain | obid | Gap / note | Issue |
|---|---|---|---|---|---|---|
| T1 | Read/Grep/Glob/Web tools called by the model | `src/tools/*` | ✅ research lookups (search_code, list_files, read_file, git_log, view_issue, view_pr, fetch_url), ≤4 per step and 12 per turn, *run by Swift* (`ResearchTools.swift`) | ❌ | Swift running them is the safer design. Missing: web **search** (fetch only). | #374, #393 |
| T2 | Parallel read-only calls, serial writes, decided from the parsed input | `services/tools/toolOrchestration.ts` | ✅ lookups in one step run as a batch | ❌ | | |
| T3 | Read a job's details | n/a | ✅ `read_job` (report, PR, Mac check, verdict, post-mortem, ~8 KB) | ❌ | Oby-specific | #302 |
| T4 | Error messages that teach the fix ("load the schema with ToolSearch", "Read before Edit") | `toolExecution.ts:578-597` | ✅ every `Plan.problems` string says what's wrong (for example "unknown effort; choices: …") | ❌ | | port |
| T5 | Large results persisted with a preview; per-message budget | `utils/toolResultStorage.ts` | ✅ caps on reads, lines and lookups | ❌ | | |

### 2.5 Orchestration: handing work to agents

| # | Claude Code mechanism | Where (cc) | Swift brain | obid | Gap / note | Issue |
|---|---|---|---|---|---|---|
| O1 | Typed delegation (`subagent_type`, model, background, isolation) | `tools/AgentTool/AgentTool.tsx:82-121` | ✅✅ `Dispatch`: kind, repo, issue/pr/epic, rounds, check, complexity, start_when, mode, reads, agent, account | 🟡 subset (no start_when, complexity, mode, epic, base_branch, reads) | | port |
| O2 | **Brief-writing discipline**: brief the worker like a colleague who just walked in; say what was ruled out; never "based on your findings"; give paths, lines and what "done" looks like | `AgentTool/prompt.ts:99-113`, `coordinator/coordinatorMode.ts` | 🟡 `task` "restates the work in the user's terms" (`Brain.swift:878`) | 🟡 same | After research (T1), the brain knows paths and causes, but the task schema has nowhere to put them. Add structured `findings` (paths, lines, cause) and `done` (acceptance) fields to `Dispatch`, filled from what was read this turn, and check that every cited path exists in a lookup result. | #540 |
| O3 | "Launch, tell the user, end the turn; never fabricate or predict results" | `AgentTool.tsx:1327`, coordinator prompt | ✅ "On it. …" reply plus the working-line guard | 🟡 reply only | | |
| O4 | One async-result envelope (`task-notification`: id, status, summary, result, usage), delivered at lower priority than user input, exactly once | `tasks/LocalAgentTask/LocalAgentTask.tsx:197-262` | ✅ orchestrator events (#351): read-before-act, an action allow-list, 3 automatic actions per job per day, repeat-signature escalation (`Desk.swift:983-1075`) | ❌ | Oby's is more conservative than Claude Code's, on purpose. | #351 |
| O5 | Continue vs start fresh, by context overlap (continue to fix a failure; fresh for verification or after a wrong approach) | coordinator prompt | 🟡 the actions exist (`retry_job`, `message_job`, `move_job`, `ask_review_again`); no rule tells the brain which to pick | ❌ | Add the rule to the system prompt: fixing a failure means retry or message the job; reviewing it means a new job (fresh eyes). | #541 |
| O6 | Message a running agent (queued to its next tool round); a stopped one is resumed from its transcript | `SendMessageTool.ts:799-870`, `resumeAgent.ts` | 🟡 `message_job` is orchestrator-only; the user can't say "tell the vault job to skip the Watch target" | ❌ | Allow `message_job` for user turns too, with the user's words as data, and auto-resume a finished job's session | #542 |
| O7 | Adversarial verification agent with a parseable `VERDICT:` and evidence blocks (command, output, result); a reminder when 3+ tasks close with no verification | `built-in/verificationAgent.ts`, `TodoWriteTool.ts:72-112` | ✅ Oby's reviewer ends with `VERDICT: APPROVED / CHANGES REQUESTED`, demands probes for security claims and refuses reading-only verdicts (`Review.swift:265-358`); plus Mac checks and `check` | — | Oby is close. Borrow two things: "try to break it" framing with at least one adversarial probe for *every* review, and the "command / output / result" block per claim. | — |
| O8 | Read-only specialists (Explore, Plan) on fresh context, returning a short memo | `built-in/exploreAgent.ts`, `planAgent.ts` | 🟡 research *jobs* (full jobs) and lookups | ❌ | #376 designs them; its design matches the source well | #376 |
| O9 | Plan mode with a single approval path and "keep planning" on reject; an interview-style plan | `EnterPlanModeTool`, `ExitPlanModeV2Tool`, `messages.ts:3207-3392` | 🟡 per-job `mode: plan` with approval in the inbox; no conversational plan | ❌ | #375 | #375 |
| O10 | Task list with `blocks` / `blockedBy`, atomic claim, completion hooks that can refuse "done" | `utils/tasks.ts`, `TaskUpdateTool.ts` | 🟡 `start_when` on job state, PR state, account window or time (`StartWhen.swift`), which is a real dependency system; no goal checklist | ❌ | #375. Keep "Swift ticks steps, the model never certifies its own progress". | #375 |
| O11 | Progress summaries every 30 s (3–5 words, "say something NEW") | `services/AgentSummary/agentSummary.ts` | 🟡 the job's `step` comes from the agent; InboxRewriter rewrites inbox items | ❌ | #381 | #381 |
| O12 | Permission requests bubbled to the lead; denials fed back with "try a legitimate alternative or stop and explain" | `utils/swarm/permissionSync.ts`, `messages.ts:207-280` | ✅ inbox permission items, `answer_permission` with the user's words | 🟡 | | #134 |
| O13 | Batch fan-out: 5–30 units in worktrees, each ends with `PR: <url>`, status table | `skills/bundled/batch.ts` | ✅ dispatches up to 10, epics (one job per sub-issue), the Lead with file-overlap awareness | 🟡 up to 10 | | |
| O14 | Recurring schedules (cron with jitter and expiry) | `ScheduleCronTool` | 🟡 one-shot `start_when` | ❌ | #395 | #395 |
| O15 | Multiple-choice questions with recommended first, multiSelect, previews | `AskUserQuestionTool` | 🟡 ≤3 options, recommended, free text | 🟡 a job's `AskUserQuestion` reaches the owner in every mode (#858): its options, multiSelect, free text, one question after another; no previews or recommended yet | #391 | #391, #858 |

### 2.6 Persistence and observability

| # | Claude Code mechanism | Where (cc) | Swift brain | obid | Gap / note | Issue |
|---|---|---|---|---|---|---|
| P1 | Sessions as transcripts, resume, fork, rewind | `utils/sessionStorage.ts`, `/branch`, `/rewind` | 🟡 one thread of 500 turns | ✅ many conversations, pin, rename, delete (#493) | Fork a conversation: later | #390 |
| P2 | AI titles (3–7 words, Haiku) | `utils/sessionTitle.ts` | — | 🟡 first line cut to 48 chars (`titled`) | #493 says "the brain may improve them". Give the brain an optional `title` on a conversation's first turn. | #493 |
| P3 | Agentic search across sessions | `utils/agenticSessionSearch.ts` | ❌ | ❌ | Later | |
| P4 | Every brain call logged with its plan and why things were refused | (transcript) | ✅ `BrainTurn.line` to the log and `oby.sqlite` | ❌ obid logs nothing about plans | Port, with R7's numbers | port |
| P5 | Prompt-cache break detection that names the cause | `promptCacheBreakDetection.ts` | ❌ | ❌ | With R7, log `cache_read_input_tokens` per turn; that's enough | #533 |

---

## 3. Findings from reading the source that matter right now

### 3.1 `obid`'s brain is a regression, and the port is the top item

What `POST /v1/plans` in `obid` does today (`brain.rs:80-485`):
- The whole conversation goes into the prompt, every kept turn, uncut (#505).
- There is no briefing. The brain can't answer "how are the jobs going?" and doesn't know what's running, so "cancel it" can't work.
- There are 4 actions (dispatch, ask_user, reply_only, ignore). Stop, move, permissions, modes, settings, read_job, research and job actions are all missing.
- If the plan doesn't parse or validate, the client gets a 422. Nothing is retried, and the model never hears why.
- It always runs `--model haiku`, with no Sonnet for long or multi-step turns, no Codex fallback, no rules fallback and no canary.
- It records nothing about the turn.

Every row marked "port" above is work the Swift brain has already done and tested. Port it in the order PORTING.md lists the tests (BrainRetry, BrainSteady, Conversation, ConversationSteps, JobActions, ReadJob, ResearchTools). Fix #505 in the same change.

### 3.2 `--json-schema` is a tool, not a constraint

In the CLI, `--json-schema` registers a synthetic tool named `StructuredOutput` whose input schema *is* the schema (`cc:src/tools/SyntheticOutputTool/SyntheticOutputTool.ts`, `cc:src/main.tsx:1879-1886`):
- Ajv validates each call. A mismatch comes back to the model as a tool error, and it tries again inside the same process, up to `MAX_STRUCTURED_OUTPUT_RETRIES` (default 5, `cc:src/QueryEngine.ts:1004-1030`).
- A Stop hook refuses to let the run end until the tool was called successfully (`cc:src/utils/hooks/hookHelpers.ts:70-83`).

Consequences for Oby:
- **`--max-turns 3` is tight.** With a quoted file (`Brain.swift:707`), one Read plus one schema retry already uses 3 turns. The run then ends `error_max_turns` without `structured_output`, which is a likely cause of the "success without structured_output" case `ClaudeBrain` works around (`Brain.swift:724`). Raise it to 5–6, and log `subtype` and `num_turns` (R7) to confirm.
- **Swift's semantic retry is still needed.** Ajv only checks shape. `Plan.problems` checks meaning. Keep both.

### 3.3 The brain's prompt is probably never cached

The API caches by prefix, in the order tools → system → messages. Oby's brain changes all three on every call:
- **Tools:** the schema, which *is* the `StructuredOutput` tool's input schema, embeds the briefing's live job ids, inbox ids and account names (`Plan.schema(for:)`, `Brain.swift:505-615`). Any new job changes the first block.
- **System:** the system prompt ends with a random per-turn canary (`Brain.swift:890`).
- **Messages:** the briefing comes first in the user message, with its clock line at the top.

Cache-friendly layout, in order:
1. A **static schema**. Use `"type": "string"` for job ids, item ids and accounts, and let `Plan.problems` reject unknown ones. It already does, with a refusal the model can act on.
2. A **byte-stable system prompt**. Move the canary to the end of the user message.
3. In the user message, stable parts first (settings, accounts), then jobs, then the conversation, then the clock and the user's words last.

Measure before and after with `usage.cache_read_input_tokens` from the JSON result (R7). This is an inference from the source, not measured yet. Haiku steps are the ones that benefit most.

### 3.4 Steering is cheap in Oby's shape

Claude Code drains queued user messages at the boundary between tool rounds (`cc:src/query.ts:1535-1650`). `Desk.plan` already has that boundary: the top of each step. Today a new message replaces the turn (#379).

The change: keep a per-conversation queue. At the top of each step, append the queued words to `request` as "The user added while you worked: …", and let the next plan take them in. Stop keeps its meaning. Anything still queued when the turn ends becomes the next turn.

### 3.5 Briefs are where orchestration quality is decided

Claude Code's coordinator rules boil down to this: the lead must *synthesize* what it learned into the worker's brief (paths, lines, cause, what "done" means). It must never write "based on your findings". It must say what was already ruled out.

Oby's `Dispatch.task` is free text "in the user's terms". After a research step, the brain knows the file and the cause, but the brief carries neither. That is O2 above. It is a schema change plus Swift checks, a few hundred lines, and it improves every job Oby starts.

---

## 4. Recommended order

| Order | What | Why it makes Oby smarter | Size | Issue |
|---|---|---|---|---|
| 1 | Port the Swift brain to `obid` (briefing, quoted file, all actions, `Plan.problems` with refusal retry, Haiku/Sonnet, Codex and rules fallback, canary, multi-step loop with step events, research and read_job, `BrainTurn` log), fixing #505 on the way | Without it, the new daemon can't talk about the work at all | Large | #442 follow-up, #505 |
| 2 | Per-turn measurements: model, `duration_ms`, `num_turns`, `subtype`, `total_cost_usd`, input/output/cache tokens on every brain turn | Every later change needs a before/after number | Small | #533 |
| 3 | Cache-friendly prompt layout (§3.3) and `--max-turns` headroom (§3.2) | Faster, cheaper brain turns, fewer missing plans | Small | #534, #535 |
| 4 | Conversation state record (C8) and compaction (C6) | Oby stops forgetting constraints after 50 turns | Medium | #379 |
| 5 | Memory with freshness labels and proposed (not silent) extraction (C9–C14), plus the target repo's AGENTS.md in the quoted file | Preferences and conventions hold across conversations | Medium | #378 |
| 6 | Steering queue (L6, §3.4) | The user can correct Oby mid-turn | Small–medium | #379 |
| 7 | Structured briefs: `findings` and `done` on `Dispatch` (O2), plus the continue-vs-fresh rule (O5) | Agents start with what Oby already learned | Medium | #540, #541 |
| 8 | Completion gate before the final reply (L7) and typed step outcomes (L2) | Multi-part requests don't end half-done; failures stop being detected by matching words | Small–medium | #539, #538 |
| 9 | `message_job` for user turns, with auto-resume (O6) | "Tell the vault job to skip the Watch target" works | Small | #542 |
| 10 | Specialists (#376), goals and checklist (#375), progress lines (#381) | Research without a job; long goals that survive restarts | Large | #376, #375, #381 |

## 5. Keep these: Oby is ahead

- **The model proposes, Swift decides.** Semantic validation with refusal feedback (R4) beats Claude Code's shape-only schema check.
- **Untrusted text only in a quoted file** (C4), and a canary (R6).
- **Failover across vendors and to rules**, with rules never acting on their own on the first step (`BrainSafety.rulesActingRefusal`).
- **The event orchestrator's guard rails** (O4): read before acting, an allow-list, 3 actions per job per day, escalation when the same failure repeats.
- **A reply can't contradict the header** (C16).
- **`start_when` dependencies** (O10) and the Lead's skip list and file-overlap awareness.
