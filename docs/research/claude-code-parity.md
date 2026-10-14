# Claude Code UX/DX gaps in Oby

Research snapshot: 2026-10-13, against `origin/dev`. This is a product-gap inventory, not a claim that Claude Code and Oby have the same product shape. Claude Code changes quickly; the upstream links below are the source of truth. “Claude Code” includes CLI, Desktop, and Claude Design only where called out. The comparison is about the listed experience and cross-agent behavior: Oby must own a feature when it should work the same with Claude Code, Codex, Cursor, or Gemini.

Claude source pages: [Desktop](https://code.claude.com/docs/en/desktop), [commands](https://code.claude.com/docs/en/commands), [routines](https://code.claude.com/docs/en/routines), [checkpointing](https://code.claude.com/docs/en/checkpointing), [MCP](https://code.claude.com/docs/en/mcp), [web search](https://code.claude.com/docs/en/web-search), [attachments](https://code.claude.com/docs/en/desktop#attach-files), and [Claude Design](https://www.anthropic.com/news/claude-design). Claude features and availability vary by surface and plan. In particular, Claude Code's team sharing and private artifacts are not all features of the local CLI.

## Comparison

| Item | Claude Code | Oby today | Gap size |
|---|---|---|---|
| Artifacts: HTML, docs, decks, designs; versions/comments/live data; private share links; Claude Design/design systems | Claude Design creates editable visual work and artifacts can be shared privately; Claude Code Desktop previews local HTML/PDF/images/video in an embedded browser and can interact with a running app. | Oby bundles `oby.html` in its `WKWebView` using its `oby://` scheme for its own character ([Character README](https://github.com/deskree-inc/oby/blob/dev/Character/README.md#L154)). The Mac can snapshot/copy selected files as job attachments ([Snapshot](https://github.com/deskree-inc/oby/blob/dev/Mac/Snapshot.swift#L45)). The control plane currently has installation/auth/notification routes, not artifact storage, versioning, comments, or share links ([worker](https://github.com/deskree-inc/oby/blob/dev/cloud/control-plane/src/app.ts#L86), [schema](https://github.com/deskree-inc/oby/blob/dev/cloud/control-plane/migrations/0001_init.sql#L1)). No user artifact viewer or cross-agent artifact contract found. | **Very large** — there is a character renderer and remote service substrate, no artifact product. Engine artifact contract + Mac/iOS viewers + control-plane private storage/shares; runner API transports agent-produced outputs. |
| Sharing: sessions/results with teammates; Oby-to-Oby (F12) | Claude Code supports sharing selected sessions/results through its hosted surfaces and team features; availability differs by surface. | Oby has an owner-scoped shared conversation across that owner's devices: `/v1/conversation` and local storage ([Conversation](https://github.com/deskree-inc/oby/blob/dev/Engine/Conversation.swift#L8), [storage](https://github.com/deskree-inc/oby/blob/dev/Engine/Conversation.swift#L436)). F12 team-to-team chat is roadmap intent, not present in this code. Control-plane identity is an installation, not a team/session sharing model. | **Large** — add explicit teammate identity, authorization, session/result shares and Oby-to-Oby messaging. Control plane + runner API + Mac/iOS/Watch UI; Engine sharing policy. |
| Slash/custom commands, plugins/marketplace, user-added MCP, output styles, status line | Built-in slash commands and custom skills/commands, plugins from marketplaces (skills/agents/hooks/MCP/LSP), user-configured MCP servers, output styles and configurable status line. | Brain uses typed natural-language actions; the agent CLIs retain their own native extension settings in their isolated accounts. Oby partially supports MCP: vault-backed connected apps/APIs expose their tools to job agents through a job-scoped brokered MCP server named `oby` ([Connected](https://github.com/deskree-inc/oby/blob/dev/Engine/Connected.swift#L3), [broker setup](https://github.com/deskree-inc/oby/blob/dev/Engine/Desk.swift#L2095)). This is F17, not Tetrix. It is not an arbitrary MCP-server configuration UI. Oby has no cross-tool slash/custom-command or plugin marketplace, nor Oby output-style/status-line surface. | **Medium-large** — build a command and plugin catalog around the existing MCP broker; do not duplicate F17's connected-apps broker. Add user-configured MCP server support only for the capability beyond vault-backed connections. |
| Sessions: resume/fork/name/rewind/checkpoints, `/context`, usage/cost | Named/listable sessions; resume and fork; automatic checkpoints and rewind file edits; context-window inspection/compaction; usage display. Cost depends on subscription/provider/surface. | Oby persists job-agent session IDs and resumes that same job after interruptions ([Desk](https://github.com/deskree-inc/oby/blob/dev/Engine/Desk.swift#L2068), [job session](https://github.com/deskree-inc/oby/blob/dev/Engine/Desk.swift#L2138)); conversation stores the last 500 turns, with no fork/rewind/checkpoint timeline ([Conversation](https://github.com/deskree-inc/oby/blob/dev/Engine/Conversation.swift#L36)). Oby shows account usage windows/resets in shared settings ([Usage](https://github.com/deskree-inc/oby/blob/dev/Shared/Usage.swift#L1)); it does not offer token/cost totals, per-session context use, arbitrary resume/fork/name or undo of agent file edits. | **Large** — preserve Oby's job resumption, add user-visible session lifecycle and recoverable checkpoints, and normalize context/cost telemetry where tools provide it. Engine + runner API + app UI. |
| Attachments and research: images/screenshots/PDF/files in chat; brain web search/fetch | Desktop attaches images and PDFs, and can preview generated files; Claude Code has web search/fetch tools where enabled. | Mac chat offers screenshot capture and explicit file/image attachment copied for a job ([ChatWindow](https://github.com/deskree-inc/oby/blob/dev/Mac/App/ChatWindow.swift#L365), [Snapshot](https://github.com/deskree-inc/oby/blob/dev/Mac/Snapshot.swift#L114)); attachments are delivered to dispatched jobs ([Desk](https://github.com/deskree-inc/oby/blob/dev/Engine/Desk.swift#L1478)). iOS/watch speech/chat are text-oriented. Brain plans from conversation, jobs, inbox and usage ([Conversation briefing](https://github.com/deskree-inc/oby/blob/dev/Engine/Conversation.swift#L53)); no first-party web search/fetch tool found. PDF is passed as a file, not shown as a chat preview. | **Medium-large** — broader cross-device attachment handling/preview and safe, cited web search/fetch for the brain. Runner API + Engine + Mac/iOS UI. |
| Tool UIs: question previews/multiselect, todos, diffs, PR/CI status, auto-fix | Questions can render choices and previews; agent plans/tasks, diffs, PR and checks are surfaced; Claude can loop on detected failures. | Oby already has recommended question cards with up to three options and free-text answer ([Plan.Question](https://github.com/deskree-inc/oby/blob/dev/Engine/Brain.swift#L54), [DecisionCard](https://github.com/deskree-inc/oby/blob/dev/Shared/DecisionCard.swift#L7)), live job steps ([StepList](https://github.com/deskree-inc/oby/blob/dev/Shared/StepList.swift#L14)), PR/check workflow and bounded fix rounds ([Desk review fix](https://github.com/deskree-inc/oby/blob/dev/Engine/Desk.swift#L2627)). Failed Xcode Cloud results also create an inbox item with retry, Ask Oby and dismiss actions ([Inbox](https://github.com/deskree-inc/oby/blob/dev/Engine/Inbox.swift#L179), [Xcode Cloud](https://github.com/deskree-inc/oby/blob/dev/Engine/XcodeCloud.swift#L10)); `docs/runner-api.md` currently says otherwise at L235, so that sentence is stale. Remaining gaps are generalized multi-select question payloads, rich file/image previews in decision cards, canonical todo lists and in-chat diff review. | **Medium** — build on existing cards and pipeline: typed multi-select/preview data, todos and reviewable diffs. PR/check status and Xcode Cloud failure inbox handling already exist. |
| Browser preview, simulators, scheduled/recurring work | Desktop has embedded browser preview and optional computer-use for native apps/simulators; `/schedule` and cloud/local routines handle one-off and recurring tasks. | Oby's embedded WebView is the character surface, not a project preview. It has no browser app preview or simulator control. Natural-language jobs support rounds (“loop”) and `start_when` conditions including a date/account/job/PR ([Brain](https://github.com/deskree-inc/oby/blob/dev/Engine/Brain.swift#L742), [StartWhen](https://github.com/deskree-inc/oby/blob/dev/Engine/StartWhen.swift#L103)); these are deferred one-shot starts, not recurring routines. | **Large** — project preview/test loop and recurring schedule trigger/storage/management. Mac + runner API + Engine; control plane if schedules must run while devices are offline. |
| Notifications, voice, device handoff | Desktop can continue sessions on web/mobile via hosted session/remote control; notification and voice affordances depend on Claude surface. | Oby has push notifications on iPhone/Watch and shared chat on Mac/iPhone/Watch ([iOS notifications](https://github.com/deskree-inc/oby/blob/dev/iOS/Notifications.swift#L14), [shared conversation](https://github.com/deskree-inc/oby/blob/dev/Engine/Conversation.swift#L8)); voice is implemented with held/toggle rules on Mac and explicit tap-to-record drafts on mobile ([Watch voice](https://github.com/deskree-inc/oby/blob/dev/Watch/TalkView.swift#L54)). Job state is shared through runner API. This is substantially present; missing is transferring/attaching the *same live coding session* to another device/surface and resuming its UI/context there. | **Small-medium** — preserve the existing notification, voice and shared conversation behavior; add a live-session handoff/resume affordance if it should match Claude hosted sessions. |

## Issue drafts

The following are real gaps after excluding already-filed chat investigation, goal plans, delegation, chat-to-issue, memory, compaction/steering, skills/hooks, live agent activity and research jobs. Each is a standalone draft; related implementation can be split during roadmap planning. Layers identify likely ownership, not a claim about feature ordering.

### 1. Private, versioned artifacts across agents

#### What
Add first-class job artifacts that any agent can produce: HTML pages, documents, decks, images and designs. Render safe previews in Oby's Mac and iOS apps, retain versions, support comments and live data bindings where applicable, and let the owner create/revoke private share links for teammates. Use the same contract regardless of Claude Code, Codex, Cursor or Gemini.

#### Why
A developer should be able to inspect and share the result of coding/design work without opening a worktree or moving files by hand. Oby's existing `oby://` WebView proves a native viewer path, while the current control plane has no artifact persistence or share authorization.

#### How
Define an artifact manifest and version model in Engine/runner API; collect output files from each runner; store bytes and metadata behind authenticated control-plane routes; provide expiring/revocable, least-privilege links; render HTML in a restricted origin/WebView with no agent secrets; add previews/version history/comments to Mac/iOS. Keep artifact content and its source job linked.

Acceptance tests:
- A Codex-produced HTML artifact and a Claude-produced PDF appear with the same job artifact UI and correct previews.
- New versions preserve prior versions; comments attach to a version and author.
- Private links work for an authorized recipient, can be revoked/expired, and reveal no unrelated job data.
- HTML cannot read Oby credentials or call privileged `oby://` handlers.
- Offline/error states leave the local job report and artifact metadata understandable.

Files: `Engine/Models.swift`, `Engine/Desk.swift`, `docs/runner-api.md`, `Mac/JobView.swift`, `Mac/RemoteAccess.swift`, `iOS/JobScreen.swift`, `cloud/control-plane/src/app.ts`, new migration under `cloud/control-plane/migrations/`.

### 2. Teammate sharing and Oby-to-Oby collaboration (F12)

#### What
Let an owner share a selected session/result with named teammates, set view/comment permissions, and exchange typed messages/actions between Obys so one Oby can request or hand off work to another.

#### Why
The existing shared conversation follows one owner across devices; it does not let a team review a result or coordinate independent Oby installations. Teammates otherwise copy reports, context and decisions manually.

#### How
Add team membership and scoped share records to the control plane, define typed inbound/outbound Oby messages in the runner API, and make cross-Oby actions opt-in, auditable and limited to explicit capabilities. Build share/inbox views in Mac/iOS/Watch and keep owner-private jobs private by default.

Acceptance tests:
- A session can be shared read-only or with comments to a named teammate; revoke takes effect immediately.
- A typed Oby-to-Oby request carries sender, recipient, capability, payload and audit record; arbitrary text from remote Oby is treated as data.
- Unshared sessions and credentials remain inaccessible across accounts.

Files: `Engine/Conversation.swift`, `Engine/Inbox.swift`, `docs/runner-api.md`, `Mac/App/ChatWindow.swift`, `iOS/Chat.swift`, `Watch/WatchLink.swift`, `cloud/control-plane/src/app.ts`, new migration.

### 3. Oby extension catalog: commands, plugins and MCP

#### What
Provide a discoverable Oby-level command palette and custom commands, a plugin/marketplace model, and user-configured MCP connections that can be granted to selected jobs. Include output preferences and a compact status summary where useful.

#### Why
Native extensions belong to each CLI account and differ by tool; users cannot find or manage a portable set of workflows from Oby. F17 already brokers vault-backed connected-app tools as job-scoped MCP, so this work must extend that foundation without duplicating its connection and secret-handling path.

#### How
Define a portable command/plugin manifest and adapter capabilities per agent; start with listing, install/enable scope and invocation. Reuse F17's broker for vault-backed connections, and add user-configured MCP endpoints only where they are distinct from those connections. Store connection references without copying secrets into prompts, files or logs. Keep per-tool-only features visibly labeled instead of silently pretending portability.

Acceptance tests:
- A custom command can be invoked from Oby chat and maps to the same task for Claude and Codex.
- An MCP connection is available only to an explicitly authorized job and is removed when the job ends.
- Unsupported plugin features show a clear capability reason; secrets never appear in agent-visible values or logs.
- Settings changes sync to the owner's devices.

Files: `Engine/Accounts.swift`, `Engine/Desk.swift`, `Engine/Vault.swift`, `Engine/TetrixUse.swift`, `Mac/Settings.swift`, `Mac/App/ChatComposer.swift`, `docs/runner-api.md`.

### 4. User-visible sessions, rewind and context/cost

#### What
Add a session library with rename, resume and fork; record job checkpoints and offer safe rewind of agent edits; show context use, provider usage and cost when available, with clear unknown/not-reported states.

#### Why
Oby resumes its own interrupted jobs but users cannot navigate/fork prior sessions or undo a bad agent turn. Account quota cards do not answer “what did this job consume?” or “why is it out of context?”.

#### How
Normalize session metadata and telemetry in Engine without assuming providers report comparable cost; checkpoint file state before turns and persist references to commits/worktree snapshots; expose restore previews and require an explicit selection before destructive rollback. Distinguish conversation history truncation from model context compaction.

Acceptance tests:
- A user can rename, reopen and fork a completed job session without changing the original worktree.
- Rewind previews changed files and restores only the selected checkpoint; unrelated/newer work is preserved or the operation is refused.
- Context, token/cost and quota values show their provider, timestamp and unavailable state accurately.
- Restarting the runner preserves checkpoint/session metadata.

Files: `Engine/Jobs.swift`, `Engine/Desk.swift`, `Engine/Conversation.swift`, `Engine/LocalRunner.swift`, `docs/runner-api.md`, `Mac/JobView.swift`, `Mac/App/Sidebar.swift`, `Shared/Usage.swift`.

### 5. Attachments and cited web research in chat

#### What
Support image, screenshot, PDF and general file attachments in the shared conversation on Mac and iPhone, with previews and explicit job delivery; add safe web search/fetch for brain planning and answers with source links.

#### Why
Today attachment selection is Mac-centered and attachments go to jobs, while the brain cannot inspect a URL or search the web to answer a research question. A developer must switch apps or restate visual/web context.

#### How
Extend the conversation/runner API with typed attachment metadata and bounded upload/download; add iOS pickers and previews; keep raw files out of unrelated jobs. Add an allowlisted, cited search/fetch tool to the brain adapter and treat retrieved pages as untrusted data, never instructions.

Acceptance tests:
- A user can attach a screenshot, PDF and file from Mac or iPhone, inspect the preview, remove it before send, and explicitly dispatch it to a job.
- Attachments remain available after app/runner restart and are access-controlled to the owner/job.
- A brain web answer includes working citations; injected instructions in a fetched page cannot change policy or dispatch work.
- Unsupported/oversize files produce an actionable error without sending a partial attachment.

Files: `Engine/Conversation.swift`, `Engine/Brain.swift`, `Engine/Desk.swift`, `docs/runner-api.md`, `Mac/Snapshot.swift`, `Mac/App/ChatComposer.swift`, `iOS/Composer.swift`, `iOS/Chat.swift`.

### 6. Rich task cards, todos and diff review

#### What
Extend existing question cards to represent previews and multi-select; add agent todo lists and an in-chat diff review surface connected to Oby's PR/check status.

#### Why
Oby already asks clear questions, shows live steps, reports PR/check status, and sends failed Xcode Cloud checks to the inbox. Structured previews/multiple selections, persistent task checklists and reviewable in-chat diffs are missing. Developers currently jump to the worktree to inspect proposed edits.

#### How
Version the runner API event schema for typed question options, preview attachments, selections, todo state and diff references. Reuse `DecisionCard`, `StepList`, job and existing PR/check models instead of adding parallel status concepts.

Acceptance tests:
- Single-choice behavior remains compatible; multi-select returns only declared option IDs and free text remains possible.
- Question preview images/files are sanitized and available on Mac/iPhone.
- Todo state survives reconnect/restart and cannot mark a failed check as passing.
- Diff view names changed files and shows the exact job commit, while preserving the existing PR/check and Xcode Cloud inbox behavior.

Files: `Engine/Brain.swift`, `Engine/Jobs.swift`, `docs/runner-api.md`, `Shared/DecisionCard.swift`, `Shared/StepList.swift`, `Mac/JobView.swift`, `iOS/JobScreen.swift`.

### 7. Project browser preview, simulator testing and recurring routines

#### What
Add a project preview panel that can start/stop a job's dev server and inspect local HTML/web output; support an explicit simulator test target where the runner has a Mac; let users create/manage recurring schedules in addition to existing one-shot `start_when` and bounded rounds.

#### Why
The existing WebView renders Oby's character only. Developers cannot see an agent's running UI in Oby, drive an app simulator, or ask Oby to repeat maintenance on a schedule. One-shot delayed dispatch does not cover routines.

#### How
Add preview lifecycle/port metadata to runner API, bind preview access to the job and stop it on job end; add simulator capabilities only on a paired Mac and report unavailable elsewhere. Model recurring triggers, timezone, missed-run policy and owner pause/delete in Engine/control plane, then route each firing through existing job safety/check/report behavior.

Acceptance tests:
- A job can expose a local web preview to its owner and stop it; another job/user cannot access it.
- Simulator actions run only on an available paired Mac and surface results/screenshots in the job report.
- A daily schedule fires once per intended local date, handles daylight-saving changes, and can be paused/deleted; missed-run behavior is deterministic.
- Existing date/account/job/PR `start_when` remains one-shot and keeps its current meaning.

Files: `Engine/StartWhen.swift`, `Engine/Desk.swift`, `docs/runner-api.md`, `Mac/JobView.swift`, `Mac/RemoteAccess.swift`, `cloud/control-plane/src/app.ts`, new migration.

### 8. Live coding-session handoff between devices

#### What
Let the user move an active coding session from Mac to iPhone/Watch and back, preserving the selected job, conversation, current agent turn and available controls.

#### Why
Oby already shares chat, jobs, voice and notifications across devices. What is missing is a clear handoff of the same active coding context; users can monitor or message work but cannot move their current coding surface/session as a first-class action.

#### How
Add a session/job handoff pointer and capability set to the runner API; let apps resume the same session with device-appropriate controls and avoid starting duplicate turns. Keep microphone behavior governed by existing explicit hold/toggle/tap rules.

Acceptance tests:
- Handoff from Mac to iPhone opens the same job/session and does not duplicate a user message or agent turn.
- Returning to Mac refreshes the same live state and preserves unsent drafts on the originating device.
- Watch offers status and permitted quick actions without pretending to provide a full code editor.
- Voice capture continues to obey Oby's hold/toggle/tap/stop limits.

Files: `Engine/Conversation.swift`, `Engine/Desk.swift`, `docs/runner-api.md`, `Mac/App/ChatWindow.swift`, `iOS/Chat.swift`, `iOS/Phone.swift`, `Watch/WatchLink.swift`, `Watch/TalkView.swift`.

## Existing implementation and exclusions

The research intentionally does not reopen the already-filed areas listed in the request. Existing foundations that should be reused are Oby's natural-language multi-action chat and bounded orchestration ([Brain](https://github.com/deskree-inc/oby/blob/dev/Engine/Brain.swift#L659)), job-session resume ([Desk](https://github.com/deskree-inc/oby/blob/dev/Engine/Desk.swift#L2068)), shared owner conversation ([Conversation](https://github.com/deskree-inc/oby/blob/dev/Engine/Conversation.swift#L8)), question cards ([DecisionCard](https://github.com/deskree-inc/oby/blob/dev/Shared/DecisionCard.swift#L7)), step list ([StepList](https://github.com/deskree-inc/oby/blob/dev/Shared/StepList.swift#L14)), bounded automated review/fix ([Desk](https://github.com/deskree-inc/oby/blob/dev/Engine/Desk.swift#L2627)), notifications ([iOS](https://github.com/deskree-inc/oby/blob/dev/iOS/Notifications.swift#L14)), voice ([Watch](https://github.com/deskree-inc/oby/blob/dev/Watch/TalkView.swift#L54)), and one-shot scheduling ([StartWhen](https://github.com/deskree-inc/oby/blob/dev/Engine/StartWhen.swift#L103)).

## Prior-session context and departure

Tetrix search found the 2026-10-13 Claude Code parity handoff (`936f3d4a-f3fc-4e25-ba29-34d6f7b3c05e`) and its continuation (`67f20969-3ef9-4ebc-b395-7851a7b7087e`). They document the product choice that Oby is a cross-tool orchestrator, recent orchestration/notification work, F12 as future Oby-to-Oby collaboration, and the shared owner conversation. This report follows those choices and excludes their already-filed areas. It departs by testing each remaining capability against current code and upstream docs, grouping confirmed gaps into these eight issue drafts, and narrowing session parity to user-visible resume/fork/rewind/telemetry (Oby already resumes interrupted job sessions). Tetrix `code_impact` could not resolve the proposed new report path, and `repo_sessions` could not resolve `docs/pipeline-cases.md`; no indexed file-level impact/session claims are made.
