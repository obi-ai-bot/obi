# Oby on iPhone: the design

Sangam's design of Oby (`design/app`, the Electron project) on an iPhone 17 Pro (402 × 874 points), light and dark. It is his design on a phone, not a new one: his tokens, components and words, with only what the phone needs added (safe areas, thumb reach, sheets instead of side panes, a light theme). The logic under it is docs/conversation-harness.md; the API is docs/runner-api.md.

- **The iPhone design** (Claude Design canvas, 13 screens × light and dark): https://claude.ai/artifact/5McjUa5XfetuWbTNJpB426
- **The design system** (Sangam's tokens, the character, 17 components with live previews): https://claude.ai/artifact/3Y6y9KmLkjDALa4LexY3Sy

Both are private until shared from their Share menu.

## The design system in one page

Everything comes from `design/app/src/renderer/src/tokens.css` and `app.css`. The design system's `components/bundle.css` keeps Sangam's class names (`.task-card`, `.tc-ask`, `.msg-bubble`, `.msg-task`, `.composer-field`, `.set-card`…), so a SwiftUI view can be checked against his CSS line by line.

| | Dark (Sangam's) | Light (iPhone addition) | Used for |
|---|---|---|---|
| `bg` | `#0b0b0b` | `#f4f4f2` | every screen's ground |
| `ink` | `#ececec` | `#161617` | titles, names, what you type, the recommended option's fill |
| `text` | `#a3a3a8` | `#4a4a4f` | secondary words |
| `muted` | `#6e6e74` | `#6a6a70` | meta, times, placeholders, folded steps |
| `item` | white 80% | black 82% | Oby's words, list rows |
| `chip` | `#161617` | `#ffffff` | task cards, the decision card |
| `pill` | white 8% | black 6% | Home's chips, option pills |
| `bubble` | white 12% | black 7% | your messages |
| `card-fill` + `line` | white 6% + white 10% | white + black 10% | a task or artifact card in a conversation |
| `surface` + `surface-edge` | `#181817` + white 8% | white + black 8% | sheets, menus, settings cards |
| `unread` / `needs` / `danger` / `done` | `#0a84ff` / `#ff9f0a` / `#f07167` / `#30d158` | `#007aff` / `#ff9500` / `#d23f34` / `#28a745` | new, needs you, destructive or failed, a stage passed |
| `needs-ink` | `#ff9f0a` | `#b35900` | the orange word on a light ground (a decision's kind) |
| `oby-body` / `oby-eye` | `#f1f1ee` / `#0d0d0e` | same | Oby is white in both themes |

Type is the system font only: 28/600 a page's title, 22/600 a task page or a sheet's big title, 15/600 a task card's title, 15 what you type, 14 what you read, 13 meta and steps, 12 times and labels, 11 a message's time; SF Mono 12–13 for paths and code. Radii: 22 task card, 23 the message box, 18 bubbles and decisions, 16 settings cards and menus, 14 a card in a conversation, pills fully round. Screens have 20pt side margins under a 44pt bar, and the message box sits 8pt above the home indicator.

Long text fades out over its last 24pt instead of ending in "…". The step being worked on has a sheen crossing it every 1.6s; the working dot pulses 20% to 100% on the same beat; a word arriving fades in over 240ms. Reduce Motion stops all of it.

## Screens

Each screen below is one frame on the canvas, in dark and light. "From obid" names what fills each element.

### Home

- **Bar**: the side panel icon at the left (Sangam's panel-left; on iPhone it opens Conversations, Obyspheres and Settings as a full-height sheet from the left), your account picture at the right (Settings).
- **Oby**: the live 3D character, `character/oby.html?embed&size=1.23` in a transparent WebView, about 160 × 157pt, paused while out of sight. It glances where you tap.
- **The attention line**: "2 running tasks · 1 needs you", or "All quiet. Give me something to work on" in `text` when nothing is going on. From obid: counts of jobs `queued`/`running` and of open inbox items (`GET /v1/jobs`, `GET /v1/inbox`, then `job` and `inbox` events).
- **Chips**: every kind of work, always, in Sangam's order, wrapping and centred. A blue dot when the kind holds a task not opened yet, an orange one when something in it needs you. A tap opens that kind's tasks.
- **Running** (iPhone addition: Sangam shows these in his side panel): up to three task rows, needs-you first, then new, then the rest: source logo, title, its live `step` (or "Needs you · Question"), the status mark. "See all" opens Tasks.
- **Recent**: the latest conversations, name, the last thing said, when, a blue dot if unread. From obid: `GET /v1/conversations?limit=3`, kept current by `conversation` events. "All conversations" opens the list.
- **Message box**: "What do you want me to work on, <first name>?". Sending starts a new conversation and opens it: `POST /v1/plans` with `"new": true`.

### A conversation (three frames: Oby at work, words arriving, answered)

The conversation is talking. It never becomes a task; the tasks it starts are cards in it.

- **Your message**: a bubble on the right (`bubble`, 18 round, at most 80% wide), what you attached over it: photos at 180 × 132, files as tags. The time under the end of your run.
- **Oby at work**: Oby's face (22pt) melts into three bouncing dots (ObyFaceLive) and stays so until its words land. From obid: the `thinking` event starts it; the turn's `reply` or final `turn` ends it.
- **Oby's first words** ("Let me look at the log and the workflow.") come before its tool lines when the agent writes before using tools. Words never get a bubble: plain `item` text, full width.
- **Tool lines** (`.tool-line`): one per `step` event that carries `tool` (docs/conversation-harness.md, section 5): a 12pt mark, the verb, the detail as a path token. `state` `running`: the working dot and the sheen. `done`: the grey check. `failed`: `danger`. Verbs by `tool`: `read` Reading, `search` Searching for, `web_search` Searching the web for “…”, `web_fetch` Reading <host>, `bash` Running, `write` Writing, `agent` Asking a helper agent, `oby_dispatch` Starting a job, `oby_inbox` Checking the inbox, other `oby_*` in Oby's words. Show the last four while running.
- **Words arriving**: `delta` events append text to the turn; each new word fades in. The turn's final text (`turn` event) replaces the deltas. When the words start, the tool lines fold into one muted line over them: "Read 3 files, searched the web, ran 2 commands ›". A tap opens the list.
- **Stop**: while a turn runs, the message box's end slot is Stop (a filled square on a `hover` circle): `POST /v1/conversation/stop` with `{"conversation": id}`. Typing still works; a new message replaces the turn under way.
- **A job card** (`.msg-task`), under the words that started it: the agent's logo, the title, "Running · Claude Code · Personal · obi". iPhone addition: the current stage and the latest step on one line with the sheen ("Work · Running xcodebuild -scheme Oby"), and the stage bar under it. A tap opens the task. From obid: the turn's `jobs`, then `GET /v1/jobs/{id}` and `job` events (`status`, `step`, `pipeline.stages`, `pipeline.number`/`total`). When the job ends, the `ended: true` turn carries its card again with its result line.
- **An artifact card** (`.artifact-card`), under the words that made it: a 116pt preview of its first screen, the kind icon, the title, "Page · v2 · made by Oby" (or the job's agent). A tap opens the viewer. From obid: the turn's `artifacts: [{id, version}]`, the `artifact` event, `GET /v1/artifacts/{id}`.
- **Bar**: back to where you came from, the conversation's title, ⋮ (Rename, Pin, Delete: `PATCH`/`DELETE /v1/conversations/{id}`).

### Confirm in a conversation

When Oby plans something only the owner may allow (a job in Bypass, an always-allow rule), it says why in one sentence and the decision card follows in the thread: kind "Confirm", the headline, what it does, obid's own title for it in the mono block ("Start Rotate the CI signing certificate in Bypass"), then Confirm, Cancel and a quiet Later. obid recommends neither for a `confirm` item, so neither is filled: Sangam's design fills `recommended`, falling back to the first option, and here there is none on purpose. From obid: the `inbox` item with `kind: "confirm"` whose job is this conversation's; answers go to `POST /v1/inbox/{id}/answer`.

### Inbox

Everything that waits for the owner, longest-waiting first. Title "Inbox", "3 need you · the longest has waited 2h" under it. Each item: a row with the orange dot, its job's title and "waiting 6m", then the decision as its own card (`chip`, 18 round): the kind (Question, Permission, Out of reviews, Failed, Out of usage, Start it?, Not merged, Confirm), `headline`, `happened` or `text`, the detail in a mono block, `options` as pills with `recommended` filled, Deny in `danger`, and Later. From obid: `GET /v1/inbox` and `inbox` events (an item whose `state` is `done` leaves). Reached from the attention line's "needs you" and from notifications.

### The artifact viewer (three frames: HTML page, Markdown, canvas)

A full-height sheet over the conversation: grabber, close at the left, the title and "Page · made by Oby" in the middle, the version at the right (a menu of `versions`).

- **HTML page**: a WKWebView with scripts on and no network (the files come from `GET /v1/artifacts/{id}/{version}/{path}` with obid's CSP; the app also refuses any other load). The page keeps its own look, white or not. Under it, "Runs on this iPhone with no network".
- **Markdown**: rendered in Oby's own type: 22/600 title, 15/600 headings, 14 body in `item`, lists, code blocks in `code-bg`, paths and links as tokens.
- **Canvas**: a pannable, zoomable artboard on `bg` with a 16pt dot grid. Each frame from the canvas's JSON at its size and position, its name over it in 11pt; a frame the agent marked as picked has a 2pt `unread` ring. A pill at the bottom: −, the zoom, +, Fit. Pinch and drag move it.

### Tasks

Sangam's kind page: the kind's title at 28/600, underlined tabs "Running 2" and "Done 3" (Running holds what needs you), then the task cards 8pt apart. The same page titled "Tasks" lists every kind ("See all" on Home).

- **Task card**: the source or agent logo, the title (the person first when it is for someone), how long ago; agent · account · repo; then what is happening now: the live `step` with the sheen and "Round 1 of 2", or the decision, or, done, "1 commit on oby/fix · tetrix-ee#486 · Took 30m". The stage bar at the foot. A tap opens the task's thread.
- From obid: `GET /v1/jobs`, `job` events; the kind is the job's `kind`; the decision is the job's open inbox item.

### A task's thread

The task's own conversation with its agent. For a task that came in from GitHub or Slack, the message it came in on is the first bubble ("GitHub · 9:02 AM" under it). Then Oby's words, the task's card (no chevron: you're in it), what you told the agent, Oby's reply ("Passed to Claude Code. It'll pick that up after its current step."), and last the agent's live line: the working dot, "Claude Code · <step>", "Round 1 of 2". While your words wait, the step reads "You: Also check the jitter cap…" (obid sets it). The message box says "Tell Claude Code…" ("Ask for a follow-up…" once done). From obid: `POST /v1/jobs/{id}/messages` (running: heard at its next turn; ended: one more round), the job's `notes`, `job` events. "Details" opens the task page as a sheet: stages (`pipeline.stages`), Result, Details (repo, branch, base, model, Done when), Session.

### Connect

First run, or after Unpair. Oby (112pt), "Connect to your Mac", one line on where the code is on the Mac (Settings › Runner › Pair a phone). "On this network": Macs found over Bonjour (`_oby._tcp`), each a row. Six digit boxes for the code, the focused one edged in `field-edge-on`. "A code works once, for two minutes. This iPhone then stays paired for 30 days." Connect (the one `ink` button) and "Scan the code instead". From obid: `POST /v1/pairing` on the gateway with `{credential, name}`; the token goes to the Keychain.

### Settings

A 28/600 title, then Sangam's settings groups (`.set-card`, 56pt rows, `divider` between them; heads in `item`, never uppercase):

- **Your Mac**: its name, "Paired until Nov 16", a green dot and "Connected"; Unpair (a danger button).
- **Usage this week**: each account, a 4pt bar (`full` past 80%, `over` past 90%), when it resets, its percentage. From obid: `GET /v1/status` accounts and `accounts` events.
- **Jobs**: "New jobs start in" Sandbox, Ask, Accept edits, Plan, Bypass (`GET`/`PUT /v1/settings/permissions`).
- **Notifications**: When something needs you, When a task is done, Recap when I'm back (Sangam's 32 × 18 switch, never the system's green toggle).
- **Appearance**: System, Light, Dark.

## Where the current Swift port drifts from Sangam's design

From reading `apps/ios/app` and `apps/shared` (the iPhone target compiles all of `apps/shared`). `apps/shared/Tokens.swift:10-71` already matches tokens.css exactly, and so do TaskCard, the stage bar, AskCard, ThreadTask, bubbles and Oby's plain words, the 22pt face, the status dots and the kind page. What to change:

**Theme**
- `apps/ios/app/ObyPhoneApp.swift:32` forces dark. Add the light set (the table above) to `Tokens`, follow the system, and add Settings › Appearance.
- `apps/shared/OBYStyle.swift:4-35`, `StatusPill.swift`, the old `ObyFace.swift:7-25` and `DecisionCard.swift` are the old look, still compiled into the iPhone target. Remove them from it or move them onto `Tokens`.
- `Assets.xcassets/AccentColor.colorset` is empty (system blue): set it to `ink`.
- System colours in place of tokens: `ConnectScreen.swift:38,57,68,69`, `SettingsScreen.swift:51,82,91`, `TaskPage.swift:602,603,623`, `apps/shared/Usage.swift:284-334,357-358`, `PermissionsSection.swift:21-56`, `StepList.swift:28-47`, `ReportView.swift:33-79`. Red → `danger`, orange → `needs`, secondary → `muted`, footnote/caption → 12pt.

**Home** (`Home.swift`)
- `:113` Oby's frame 240 × 200; `:107` 16pt under it (Sangam: 8); `:173` chips 36pt tall (34).
- `:104` and `JobList.swift:240` show only kinds with tasks; show every kind.
- `:127-129` a "Needs you" chip Sangam doesn't have: needs you is the orange dot on each kind's chip, and the attention line opens the Inbox.
- `:74-86` the red "Stop all" toolbar button: drop it from Home (Stop lives in a conversation's box and on a task).
- `ObyPhoneApp.swift:9` loads the character without `embed`: use `embed&size=1.23` like the Mac.
- Add Running and Recent under the chips (above).

**A conversation** (`Chat.swift`)
- `:360` with `StepList.swift:17-49`: every step with a spinner, a green check or a red cross, in system styles, under your message. Use tool lines while running and Sangam's folded "Read 3 files, … ›" line once words arrive, as the first part of Oby's reply.
- `:420`, `:337`: the face is always still. Port ObyFaceLive (spin, ball, three dots, back together; its spring presets are in `ObyFaceLive.tsx`).
- Replies appear all at once: append `delta` text and fade each new word in over 240ms.
- `:369` Oby's run continues 4pt apart (12), answers you at 24 (16); `:336` 10pt between parts (12 for Oby's, 6 for yours). `DesignViews.swift:321` `lineSpacing(6)` is loose: about 3 for 14/20.
- `:270-278` Oby's own question sits at the end of the thread; Sangam pins it over the message box, outside the scroll, with plain pills.
- `:423-433` Stop and Cancel buttons in the thread: move Stop into the message box's end slot.
- `:388-392` a done task's card misses its result line; `:389` titles end in "…" instead of fading.
- No artifact card or viewer yet.

**Conversations list** (`Chat.swift:44-129`): `:47` system large title (use 28/600 in `ink`); `:100` rows on filled cards with system separators (no fill); `:118` names 14 medium `ink` (14 regular `item`); `:125` last line 13pt with "…" (12pt `muted`, fading); `:71,76` headers in system style (12pt `label`, `.textCase(nil)`).

**Task card and page** (`TaskPage.swift`)
- `:19` titles wrap to two lines (one line, fading); `:18` logo in `muted` (70% `ink`, the source's logo when it has one); `:66` and `:305` links in blue (`text`); `:76` no pressed state (`chipHover`).
- `DesignViews.swift:377-386` the sheen's bright band is ±0.15 wide; Sangam's is ±0.45, sweeping −0.5 to 1.5.
- `:268` the logo on the meta line (on the title row at 20pt, meta indented 30); `:271` an extra coloured badge; `:416` 14pt under section labels (16); `:351,354` facts column 92 with 8 between rows (96 and 6); `:174-191` no Session section.
- `:571-630` the Move sheet is a stock Form: restyle with Tokens.

**Decisions** (`InboxView.swift`, `DesignViews.swift:13-178`): `:83-94` an extra line per option; `:72` fills the primary only when recommended and safe (Sangam: `recommended`, else the first; a `confirm` item: none); `InboxView.swift:147-177` the inline answer field's send is a filled circle (plain arrow); `:139` 16 all round (16/18/18).

**Message box** (`Composer.swift`): `:76-81` Send is a filled `ink` circle (Sangam: a plain `ink` arrow on a clear 32pt circle); `:7,35` no + at the left; no usage gauge before voice/send; `:42` text padding 10/6 (5/4 with the +).

**Settings and Connect**: system Form cards with no edge (16 round, 1px `surfaceEdge`), system separators (`divider`), uppercase system headers (13/500 `item`), system green toggles (Sangam's 32 × 18 switch: needs a ToggleStyle), `ProgressView` meters (4pt bar on `meter`), no green dot before "Connected", system buttons (32pt, 8 round, `chipHover`, 1px `line`; danger in red text) (`SettingsScreen.swift:16,24,64,106-107`, `SettingsSections.swift:23`, `Usage.swift:280-310,351`, `ConnectScreen.swift:26-92`). Fields: 44pt, 12 round, `field`, 1px `line`, `fieldEdgeOn` when focused.

**Status dots** (`DesignViews.swift:441`): the done check is 9pt; Sangam's is 12.
