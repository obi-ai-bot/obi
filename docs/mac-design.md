# Oby on the Mac: Sangam's design and what's left to build

Sangam's design of Oby (`design/app`, the Electron project, run in a browser with `npm --prefix design/app run web`) compared with the Mac app (`apps/mac/app` and `apps/shared`) on `dev` at 922faca. Part 1 is his design as it applies to the Mac window and menu bar, with the obid event or field behind each element. Part 2 is what the Mac app still lacks or does differently. Part 3 is an order of work in small pull requests.

It follows the same model as docs/ios-design.md (the iPhone spec from the same design) and docs/conversation-harness.md (streamed words, tool lines that fold, artifact cards and viewer, live job cards). The API is docs/runner-api.md. The owner's rules are AGENTS.md: where Sangam's design and those rules disagree, the rules win, and the section "Where the design meets the owner's rules" says how.

How this was made: Sangam's code read file by file and run in a browser (screenshots of 29 screens and states); the Mac app's SwiftUI read screen by screen, and the running app (connected to the owner's obid, emptied) screenshotted read-only: no typing, sending, jobs or settings changed. `file:line` references are on `dev` at 922faca. Sizes: S is under a day, M a few days, L a week or more.

## Part 1: Sangam's design on the Mac

### 1.1 Tokens

`apps/shared/Tokens.swift:10-136` already carries `tokens.css` exactly: colours (`bg #0b0b0b`, `ink`, `text`, `muted`, `label`, `item`, `line`/`lineStrong`/`lineFocus`, `divider`, `hover`, `active`, `chip`/`chipHover`, `surface`/`surfaceEdge`, `field`/`fieldEdgeOn`, `danger`, `unread`, `needs`, `full`, `over`), type (12, 13, 14, 15, 24; system font, SF Mono for code), sizes (side panel 290 between 252 and 472 with a rubber band, icon strip 48, view at least 420, bar 48, gutter 20, column 540, Home's box 520), radii (card 22, decision and bubble 18, row 6, icon 8) and motion (`fade` 280 ms, `warm`, `easeIn`, `settle` 520 ms with a 3% overshoot, `spring`). Sangam's design is dark only; the Mac keeps it dark.

What isn't in Tokens yet, from `app.css`:

| Value | Sangam | Used for |
|---|---|---|
| Settings card | 16 round, `surface`, 1px `surfaceEdge`; rows at least 56 tall, 12/16 padding, `divider` between | every Settings page, an Obysphere's settings, Knowledge |
| Settings head and foot | 13/500 `item`, 16 in; foot 12 `muted`, line height 1.45 | over and under each card |
| Switch | 32 × 18, white 14% off, `ink` on, a 14pt knob in `text` (`bg` when on), 200 ms `warm` | every on/off setting (never the system's green toggle) |
| Pop-up and field | 32 tall, 8 round, `field` fill, 1px `line`, `fieldEdgeOn` hovered or focused; a field is 220 wide | Settings' selects and text fields |
| Segmented | `chip` on a 1px `line`, 26pt segments, the one on in white 12% | Runner: This Mac / Remote |
| Settings button | 32 tall, 8 round, `chipHover`, 1px `line`; `danger` text for Remove, Forget, Disconnect | Remove, Add Account, Connect |
| Usage meter | 4pt bar, 2 round, white 8% track, `text` fill, `full` past 80%, `over` past 90%, at most 280 wide | Accounts, the usage panel |
| Connected dot | 6pt, `#30d158`, before "Connected" | Runner, Remote access, Knowledge |

### 1.2 Motion

- **Pages rise in.** Each part of a page (title, tabs, every card) rises 28px with `--spring` over 620 ms, one after another (`--i`, about 40 ms apart). A page leaving sinks 12px and fades over 200 ms (`--ease-in`), and is gone at 220 ms. A page under another steps back (Oby does too: 98% and faded) and rises in again when you come back to it (`rise-again`).
- **Words arrive** one at a time, each fading in (`stream.ts`: a word every 35 ms in the mock; docs/ios-design.md gives 240 ms per word's fade).
- **Work in progress** has a sheen crossing the line every 1.6 s (band ±0.45 of the width, sweeping −0.5 to 1.5) and a dot pulsing to 35% opacity on the same beat (`pulse`). Reduce Motion stops both.
- **Folding** (side panel groups, Show more, the task card opening on its page, search sliding under the title) is a one-row grid going 0fr to 1fr with `--warm`.
- **The side panel** opens by pushing the view, settles with `--settle` when its edge is let go, rubber-bands past its limits (UIKit's curve, 60px at most), and double-click puts it back at 290.
- **Tabs** have one underline that slides to the tab picked.
- **Scrolling**: a Safari-like 6px thumb, no track, shown while scrolling and gone 800 ms after (`useScrollThumb.ts`).
- **The message box** grows a line at a time and stacks (text over its buttons) once it passes one line; its caret glides 50 ms along a line, as Word 2013's did (`MessageEditor.tsx:166-199`).

### 1.3 The character

- **On Home**: Oby itself, `character/oby.html?embed&size=1.23` (Sangam's `design/oby/oby.html` is now the same file as `character/oby.html`) in a 280 × 220 frame a little above the middle, hidden until its first frame is drawn (`ready`), paused 300 ms after a page covers it and at once when the window hides.
- **Its states**: `idle`, `listening`, `thinking`, `working`, `loading` (melts into dots; `setState(…, {finish: true})` lets the dots run back together), `quiet`; expressions with `play()`. It looks at the pointer (`look`), glances at a click (`notice`), and glances over when the pointer arrives on the chips.
- **In a conversation**: the flat face (`ObyFace.tsx`), 22pt, over the first message of each of Oby's runs. While Oby works on a turn it is `ObyFaceLive.tsx`: it spins as it shrinks into a ball, melts into three dots that bounce in a wave, and when the words land the dots run back together and it spins back to face you. Damped springs on a timeline (presets `body`, `jelly`, `pop`, `fast`, `slow`, `melt`, `spread`), drawn at 30 fps, only while it is live and in sight. Reduce Motion shows three still dots.
- **Small marks**: `ObyIcon` (a line drawing, in menus), and another person's Oby as their initials on a colour from their name with a small Oby badge (`OwnerAvatar`).

### 1.4 The window and the menu bar

- **The window**: 994 × 670, at least 420 × 520, Safari's toolbar window type so macOS draws its corners and places the traffic lights; the title bar is as tall as twice the lights' middle, and its content starts just right of them. The side panel icon sits right of the lights whether the panel is open or not.
- **The title bar**: back (to Home, from anywhere), then the trail of how you got here (a kind of work › a task › its conversation), each earlier step going back to it, the last one where you are. On a task or a conversation, a ⋮ right after its name, and its name turns into a field to rename it in place. On a task's page, "Go to conversation" at the right; in a conversation with a few Obys, their pictures.
- **The menu bar** isn't in Sangam's design (an Electron window has none). The Mac's own is `ObyApp.swift:10-43`: Oby's mark with the count of what's working or needs you, the summary line, Open Oby, Show Oby Your Screen, Stop All Agents, Settings, updates and Quit. It stays as it is; only Settings moves (Part 2).

### 1.5 Screens

Each screen: what it shows, and what in obid fills it.

**Home**
- Oby on its stage; under it the attention line, "5 running tasks · 4 need you", "All quiet. Give me something to work on" in `text` when nothing is going on. From obid: jobs `queued`/`running`, and jobs with an open inbox item (`GET /v1/jobs`, `GET /v1/inbox`, then `job` and `inbox` events).
- The chips: every kind of work, always, in a fixed order (Review PR, Issues, a teammate's name, Tasks, Routines), 34 tall, white 8%; a blue dot while the kind holds a task not opened yet, an orange one when something in it needs you. A click opens the kind's page. From obid: the job's `kind`, `issue`, `pr`, `obi.fromOwner`.
- The message box: "What do you want me to work on, <first name>?". Sending starts a new conversation and opens it: `POST /v1/plans` with `"new": true`.

**The side panel** (`Sidebar.tsx`)
- The icon strip: Home, Conversations, a line, each Obysphere you're in (its logo), + to make one, and your picture at the foot (a menu: your name and email, Settings, Log out). Home's icon has an orange dot while anything needs you.
- Home: "New task" (back to Home's box), then the tasks grouped by kind (or by status: Needs you, Running, Completed), each group folding, its open count at the right, an orange dot when folded with something needing you. Rows: the source's or agent's logo, the person first ("Ernesto #412 retry jitter"), the status mark at the end (blue new, orange needs you, grey pulsing working, nothing queued, a small check done), ⋮ on hover or right-click. Done tasks show the latest 3 (5 under Completed), then "Show N more". Home's ⋮: Group by Type or Status; Archive completed after a day, 3 days (default), a week, or never. At the foot, under a line: "Archived 11".
- **An addition to Sangam's design, approved by the owner on 2026-10-21:** a kind of work's name in the side panel (Review PR, Issues, a teammate, Tasks, Routines) opens that kind's page, the same one its chip on Home opens. On hover the name turns to ink and is underlined, and the pointer becomes a hand. The chevron and the rest of the row still fold the group, as in his design, and a folded group stays folded. VoiceOver reads the name as "Open Issues" and the chevron as "Hide Issues" or "Show Issues". A status group (when grouped by status) only folds. The iPhone and Android side panels do the same: the name opens the page, and the chevron folds.
- Conversations: search by the panel icon, Pinned then Recent (no headings while nothing is pinned); each row its name, a second line ("Started 2 tasks", else Oby's last words), when it last moved, ⋮. From obid: `GET /v1/conversations` paged by `cursor`, `?q=` to search, `conversation` events; rename and pin with `PATCH`, delete with `DELETE`.
- Settings: the list of pages, opened from your picture's menu (General first).
- An Obysphere: its name and member count, Knowledge, Invite member, Members (each person's Oby, a blue dot when something from it is unread, how many conversations), Invited (resend or cancel, for an admin).

**A kind of work's page** (`GroupView.tsx`): its name at 28/600, tabs "Running 2" and "Completed 3" (Running holds what needs you; Review PR and Issues have "To do" first, for GitHub's items no job works on yet, grouped by board column, each card labelled with its column; they never count as Running), a card per task (the order kept while you're on the tab), and under Completed "Older ones are in Archived". From obid: `GET /v1/jobs`, `job` events, and the job's open inbox item; To do from `GET /v1/github/work`.

**A task card** (`TaskCard.tsx`): the logo, the person and title (15/600, one line, fading), how long it has run or when it finished; agent · account · repo; then what's happening: the live step with the sheen and "Round 2 of 3", or the decision (its kind in orange, Oby's headline, what happened, the command or diff in a mono block, the options with `recommended` filled, Deny in `danger`, a quiet Later), or, done, "1 commit on oby/fix-377 · tetrix-ee#493 · Took 22m". The stage bar at the foot (one segment per stage, current pulsing, orange when it needs you). From obid: `step`, `round`/`rounds`, `pipeline.stages`, `commits`, `published`, `pullRequest`, `created`/`finished`; the decision is the inbox item (`kind`, `headline`, `happened`, `text`, `options`, `details`, `recommended`); answers go to `POST /v1/inbox/{id}/answer`.

**A task's page** (`TaskView.tsx`): the same card opened: the title at 22pt over agent · account · repo; the decision as a card of its own; then one card with Result (the agent's report and its result line), Stages (a mark per stage, a dotted line down, the live step under the current one, "Waiting for review", "Skipped"), Details (repository, branch, base, model, "Done when <check> passes") and Session (the agent's last tool lines: Read, Edit, Bash, Grep and what it said). The ⋮ in the title bar: Open conversation, Rename, Stop task (or Archive task once done), Delete task. At the foot the message box, "Tell Oby about this task…": what you say goes on the end of the task's conversation, which opens over the page so you see Oby's answer. From obid: `GET /v1/jobs/{id}`, `GET /v1/jobs/{id}/report`, `job` events, `POST /v1/jobs/{id}/messages`, `/stop`, `/dismiss`.

**A task's own thread** (`ChatView.tsx`, kind `task`): for a task that came in from GitHub, Slack or Gmail, or whose conversation was deleted. The message it came in on as the first bubble (under it "GitHub · 9:02 AM"), Oby's "On it. Claude Code has it in oby on Deskree.", the task's card (no chevron: you're in it), what you told the agent and Oby's reply ("Passed to Claude Code. It'll pick that up after its current step."), the decision when there is one, and last the agent's live line: the working dot, "Claude Code · Editing Mac/App/LivePanel.swift", "Round 2 of 3". The box says "Tell Claude Code…", "Ask for a follow-up…" once done. From obid: the job's `request`, `notes`, `summary`, `step`, the ended turn (`"ended": true`), `POST /v1/jobs/{id}/messages`.

**A conversation with Oby** (`ChatView.tsx`, kind `oby`; docs/conversation-harness.md): your words in bubbles on the right (white 12%, 18 round, at most 80%), what you attached over them; Oby's as plain text under its face, never in a bubble; runs 4px apart, a new run after an hour's quiet, the time under each run's end. While Oby works: its live face and one line of what it's on ("Thinking", then each step), or, with the harness, its tool lines (the last four, each with its mark, verb and path token); its first words before its tools when it writes them first. When its words start, the steps fold into one muted line over them ("Read 3 files, searched the web, ran 2 commands ›", Sangam's "Looked at 2 things, asked Wellington's Oby"), which a click opens with a check by each. Another Oby's answer is quoted in Oby's turn under its owner's picture and name. The tasks it started are cards under its words (`ThreadTask`: logo, title, "Running · Claude Code · Personal · oby", the result line once done, the status mark, a chevron); artifacts are cards that open the viewer. Oby asking you something back is held over the box (kind "Question", the question, pills, "Or answer in your own words below"). The box says "Reply to Oby…". From obid: `GET /v1/conversation?id=`, `turn`, `thinking`, `step` (with `tool`, `detail`, `state`), `delta`, `reply`, `artifact` events, the turn's `jobs` and `artifacts`; `POST /v1/plans` with `conversation`; Stop is `POST /v1/conversation/stop`.

**The message box** (`Composer.tsx`): + at the left, the text, then the usage gauge, then voice while empty and send once there's something to send. + opens a panel as wide as the box: Add files or photos, Add other Obys, Attach tasks (the last two a search). An @ typed at the start of a word lists the Obys. Links and references (#412) in blue, paths, repos and `code` in coral mono, as you type and once sent. The gauge has a yellow or red dot past 80% or 90%; its panel lists each account's week and has a gear to Settings › Accounts. From obid: `GET /v1/status` `accounts` and the `accounts` event; attachments go with `POST /v1/plans`.

**Archived** (`ArchiveView.tsx`): a search, then every done task that left Home, newest first, each with its kind and agent and how long ago; one still known opens its page.

**Settings** (`SettingsView.tsx`): pages in the window, as the Mac app has them, plus Connectors:

| Page | What it shows | From |
|---|---|---|
| General | Open at login; Permissions on this Mac (default mode, saved rules with Remove); Voice (speech language; Oby answers in writing, never aloud, the launch build's decision of 2026-10-23); Notifications | the Mac itself |
| Runner | Runner: This Mac / Remote (URL), login item, status with a green dot, job worktrees' size, last cleanup; This Mac: keep my Mac available; Permissions (the runner's default mode and rules); Checks on this Mac (merge checks, build and test agents' work); Apple Watch without iPhone; Publishing key | `GET /v1/status` (`runner`, `cleanup`, `permissions`), `GET`/`PUT /v1/settings/permissions`, `GET`/`DELETE /v1/permissions/rules`, `GET /v1/checks/next`, `GET`/`DELETE /v1/watches`, `POST /v1/devices` |
| Remote access | reach this Mac from anywhere, hostname, status, Forget This Mac (signs in with Apple or Google the first time, never keeping an email, since 2026-10-20) | the Mac and Oby's control plane |
| Accounts | "Most room: Deskree on Codex, 88% left this week"; each tool's accounts (name, "Paid by Deskree · Resets Thursday", a meter, "36% used", Remove); Add an account (Tool, Name, Paid by, Add Account) | `GET /v1/status` `accounts`, `accounts` events, `POST /v1/accounts/{id}/reserve` |
| Models | per tool: model, effort, complex job effort (Cursor: model only); "Oby's brain stays on Haiku" | `GET`/`PUT /v1/settings/models`, `GET /v1/settings/models/options` |
| Connectors | a search; Connected and Available: Deskree Ops, Tetrix, GitHub, Claude, ChatGPT, Cursor, Slack, Gmail, Google Meet, Zoom, each with its logo, what it does, Connected or Connect | `GET /v1/obid/plugins`, `PUT /v1/obid/plugins/{id}`, `GET /v1/connections`, `GET /v1/status` `github` |
| Vault | secret names with Remove; Add a secret (name, value typed once) | the Keychain items obid reads on this Mac (no API) |
| About | version, Check for Updates | the Mac (Sparkle) |

**The Obysphere** (`spheres.ts`, `peers.ts`, `knowledge.ts`): someone else's Oby (its owner's picture, "Assisted with 4 tasks", your conversations with it, each about a task, the latest first); a conversation with one or a few Obys (their words under their owner's name; yours speaks for you on the right, with no bubble); Knowledge (each source an admin connected once for everyone: Tetrix or any MCP server, who can use it, when Oby uses it, its tools on or off); the Obysphere's settings (avatar, name, URL, members, delete or leave); Invite (emails as tags, an invite link, only the org's emails); Create an Obysphere. From obid: one Sphere per obid (`GET /v1/obid/sphere`), Obi-to-Obi requests and questions (`GET /v1/obid/sphere/exchanges`, `obiRequest` inbox items), sharing rules and remembered decisions. Members, invites, several Spheres and shared knowledge aren't served yet.

### 1.6 The logic

- **Talking and work stay apart** (`chats.ts` vs `tasks.ts`). A conversation is talking: Home's box starts one, a reply carries it on, Oby works in the open and most turns end in words. It is never a task. A task is work: it exists only once Oby starts one, as a card under Oby's words and a row on Home, with its own page and its own thread. Deleting a conversation leaves its tasks; their conversation is then their own thread.
- **One answer at a time** in a conversation: words said while Oby works wait their turn (obid instead replaces the turn under way, docs/runner-api.md "obid only: conversations"; the Mac follows obid).
- **Telling a task something** from its page goes through Oby: it goes on the end of the task's conversation (or its thread), which opens, and Oby says what it did: running, "Passed to Claude Code. It'll pick that up after its current step."; waiting on a decision, the same with a nudge; done, Sangam starts a follow-up task with the same kind, agent, account and repository. obid decided otherwise (#644): a finished job picks up again in its own worktree as one more round (`POST /v1/jobs/{id}/messages`). The Mac follows obid; only the words change.
- **Decisions** live with their task: on its card in the kind's page, on its page, in its thread and in the conversation that started it. Every decision has Later. There is no Inbox screen: the orange dots (chips, rail, group heads, rows) lead to them.
- **Status**: a task with an open decision needs you whatever its agent is doing; queued counts as running; the rest is done. Lists rank new first, then needs you, then queued, then the rest in order. A task is new (blue) until it's opened.
- **Archive**: done tasks leave Home after a while (3 days unless changed) and stay in Archived; Delete removes one from Archived too.

## Part 2: what's left to build

Each row: what Sangam has, what the Mac app does today, what to change, and its size. IDs are by group: **A** missing screens and features, **B** present but different (layout, tokens, components, motion), **C** logic. "UI only" means obid already serves what it needs; "Needs obid" names the API work.

### 2.1 Settings, accounts, models, usage and connectors (first, at the owner's ask)

**What obid already supports, area by area**

| Area | obid today | So the gap is |
|---|---|---|
| Account list and usage | `GET /v1/status` `accounts` (`id`, `agent`, `name`, `label` with the plan, `signedIn`, `fiveHour`/`sevenDay` and their resets, `running`, `fullUntil`, `reserved`, `reserveLiftedUntil`, `tetrix`, `tetrixJobs`, `tetrixUsed`), the `accounts` event, `POST /v1/accounts/{id}/reserve` | UI only |
| Adding, renaming, removing an account | none: accounts are `agents.<tool>.accounts` in obid's `config.json` (`{id, name, configDir}`), read at start | Needs obid |
| Signing an account in | none: obid only checks that the login file is there (`.credentials.json`, `auth.json`), or the Keychain item with `claudeKeychain`; "Accounts are signed in on the runner itself, through each tool's own login" | Needs obid |
| Who pays | no `payer` on obid's Account | Needs obid |
| Models for jobs | `GET`/`PUT /v1/settings/models`, `GET /v1/settings/models/options` (Claude Code's list, the signed-in Codex account's, `cursor-agent models`) | UI only |
| Model for conversations | `conversation.model` in `config.json` only | Needs obid |
| Jobs at once | `GET`/`PUT /v1/settings/jobs` (`maxRunning`) | UI only (neither design nor app shows it) |
| Permissions | `GET`/`PUT /v1/settings/permissions`, `GET`/`DELETE /v1/permissions/rules` | UI only |
| Plug-ins (Tetrix and other context or MCP plug-ins) | `GET /v1/obid/plugins`, `PUT /v1/obid/plugins/{id}` with `enabled` and `config` | UI only |
| Connections (an MCP server or API with a vault secret) | `GET /v1/connections`; `DELETE` with a device's signature; `POST` needs a signature too, and "no app adds connections" yet | Needs obid (and a Mac flow) |
| Slack, Gmail, Google Meet, Zoom, Deskree Ops | not a plug-in or connection that exists | Needs obid |
| Vault | no API: `obid vault add/list/remove` on the machine; on this Mac obid reads the Keychain items the Mac's Vault page writes | UI only for This Mac; needs obid for a remote one |
| Runner status, cleanup, update | `GET /v1/status` `runner`, `cleanup`, `runner.update` | UI only |
| Watches, publishing key, Mac checks | `/v1/watches`, `POST /v1/devices`, `/v1/checks/*` | UI only |
| Remote access, voice, notifications, login item, updates | the Mac app itself | UI only |

**The add-account flow, step by step**

| Step | Sangam | Mac today | obid |
|---|---|---|---|
| Where it starts | Settings › Accounts › Add an account; also the usage panel's gear (Settings › Accounts), and Connectors' Claude / ChatGPT / Cursor rows ("Run jobs in …", Connect) | the Settings window's Accounts tab (`Settings.swift:317-335`), and First Launch's Agents step (`FirstLaunch.swift:50`, `:325-330`) | nothing to call |
| What you fill | Tool (Claude Code, Codex, Cursor), Name ("Personal"), Paid by ("Wellington"), Add Account | the same three (`Settings.swift:318-328`); a second Cursor account refused while Cursor shares one login (`:323-326`) | `name` only, from `config.json` |
| What it makes | a row in the tool's group at 0%, "Resets in 7 days" | an account in the Mac's own Swift store, with a home of its own (`Engine/Accounts.swift:168`), not in obid | needs a `configDir` (Claude Code `CLAUDE_CONFIG_DIR`, Codex `CODEX_HOME`, Cursor `HOME`/`XDG_CONFIG_HOME`/`CURSOR_CONFIG_DIR`) under obid's home |
| Signing in | not shown (the mock adds it signed in) | Sign In opens Terminal on the tool's own login with the account's home (`Settings.swift:395`, `:801`; `Setup.swift:162-169`), and the list refreshes when Oby comes back to the front (`Settings.swift:363-365`) | `signedIn` from the login file; a Claude Code login only in the Keychain counts only with `claudeKeychain` |
| Picking the account for a job | automatic (routing); nothing in Sangam's UI | automatic; Move to… on a task's page (`TaskPage.swift:513`, `MovePanel`) | routing (Account, "Routing"); `POST /v1/jobs/{id}/move` |
| Usage | one meter per account (its week), "N% used", "Paid by … · Resets …", "Most room: …"; the box's gauge and panel | a card per account with a bar per window (5 hours, 7 days), reserve switch, "Full until", "Paid by", Tetrix line (`Settings.swift:376-402`, `shared/Usage.swift:276-305`) | `fiveHour`, `sevenDay`, resets, `reserved`, `running`, `tetrix…`; no `payer` |
| Models | Settings › Models per tool, "on this Mac" | two sets: this Mac's (`@AppStorage`, `Settings.swift:697-703`) and the runner's (`:743-745`) | `GET`/`PUT /v1/settings/models` |
| Removing | Remove (danger) | Remove, confirmed, deletes the account's home (`Settings.swift:366-371`) | edit `config.json` and restart |

What the live app shows today (screenshots `mac-06` to `mac-08`): "Accounts on this Mac" lists Personal · Max and Deskree · Team as signed in (the Mac's own store), and further down "Accounts on This Mac" lists the same two as "Signed out" (obid's). Two lists with the same name disagree, and the second is wrong: obid runs with `claudeKeychain` on, and `GET /v1/status` says `signedIn: true` for all three accounts (Personal answered a real conversation turn the same day). The Mac app never reads that key. Its decoder of the runner's accounts lists no `signedIn` (`apps/shared/Runner.swift:550-552`, `init(from:)` at `:554-568`), and it works sign-in out from the label instead: `AccountState.signedIn` is `label != nil` (`Engine/Accounts.swift:47`), and so is the usage card's `Usage.Snapshot.signedIn` (`apps/shared/Usage.swift:37`), built from `label` only (`apps/mac/app/Settings.swift:789-794`). obid sends `label: null` until a tool reports one (#626), so every obid account reads as signed out. That's where "Signed out" comes from (`Usage.notice`, `apps/shared/Usage.swift:163`). The same wrong value hides the Tetrix line (`Settings.swift:351`), and the Mac's own routing and Move to… skip those accounts (`Engine/Accounts.swift:76`, `:345`, `:441`; `MoveChoice.usage`, `apps/shared/Runner.swift:1485-1486`).

**The gaps**

| ID | What Sangam has | What the Mac app does today | What to change | Size |
|---|---|---|---|---|
| A1 | Settings as pages in the window: the side panel's Settings section lists them, the account menu opens General, each page rises in under the title bar's trail, Esc goes back | a separate Settings window with a toolbar of tabs (`ObyApp.swift:53-55`, `:82-99`); the side panel opens it (`ChatWindow.swift:13-24`, `Sidebar.swift:366-372`); the window is 460 wide and hides Vault and About behind » | UI only. Add `WindowStep.settings(page)` and a Settings section in the side panel (`PanelSection`, `ChatWindow.swift:6`); build each page from the components in B1; ⌘, opens the window on General; keep a Settings scene only if the menu bar needs it | L |
| B1 | Settings components: `.set-card`, `.set-row`, head and foot, the 32 × 18 switch, select, segmented, field, button, the meter and the green dot (Part 1.1) | system `Form` with `.formStyle(.grouped)`, system toggles, pickers, `LabeledContent` and `ProgressView` (`Settings.swift:68`, `:189`, `:281`, `:359`, `:461`, `:668`, `:750`; `shared/SettingsSections.swift:23`; `shared/PermissionsSection.swift:21-56`) | UI only. `SetGroup`, `SetRow`, `SetSwitch` (a `ToggleStyle`), `SetSelect`, `SetSegmented`, `SetField`, `SetButton`, `SetMeter` in `apps/shared` on `Tokens` (the iPhone needs the same, docs/ios-design.md "Settings and Connect") | M |
| C1 | one list of accounts, grouped by tool | two lists, the Mac's own store and the runner's, both called "on this Mac" (`Settings.swift:315-316` and `:341-356`). The runner's list says every obid account is "Signed out" while obid says `signedIn: true`: the decoder drops `signedIn` (`apps/shared/Runner.swift:550-552`) and `signedIn` is worked out as `label != nil` (`Engine/Accounts.swift:47`, `apps/shared/Usage.swift:37`) | UI only. First the bug: decode `signedIn` into a stored property on `AccountState` (falling back to `label != nil` only when an older runner leaves the key out), pass it into `Usage.Snapshot` (`Settings.swift:789-794`), and add a decoding test with obid's `{"label": null, "signedIn": true}`. Then, when the runner is obid, list only obid's accounts; the Mac's own store only with no runner. The add form then needs A2 | M |
| A2 | Add an account (Tool, Name, Paid by) and Remove | adds to and removes from the Mac's own store (`Settings.swift:317-335`, `:366-371`) | Needs obid: `POST /v1/accounts` `{agent, name, payer}` makes the account and its config folder under obid's home; `PATCH /v1/accounts/{id}` (name, payer); `DELETE /v1/accounts/{id}` (refused while it runs jobs); `payer` on Account; `accounts` event; `config.json` stays the seed. Same pull request as docs/runner-api.md | L |
| A3 | (implied) a new account becomes usable | Sign In runs the tool's login in Terminal, for the Mac's own store only | Needs obid: `GET /v1/accounts/{id}/sign-in` answers the command that runs the tool's own login with that account's folder (`claude` with `CLAUDE_CONFIG_DIR`, `codex login` with `CODEX_HOME`, `cursor-agent login` with its homes); the Mac opens it in Terminal when obid is on this Mac, and says to run it on the runner otherwise. Oby never reads the login (AGENTS.md); `claudeKeychain` covers Keychain-only logins | M |
| B2 | a usage row: logo, name and plan, "Paid by … · Resets …", a 4pt meter (`full`/`over`), "N% used" and Remove at the top right; "Most room: X on Y, N% left this week" over the list | `UsageCard` with a `ProgressView` per window, reserve switch, "Full until", Tetrix line, summary "All limits under 50%" (`shared/Usage.swift:276-305`, `Settings.swift:376-402`) | UI only. Sangam's row on `SetMeter` with the week (`sevenDay`), the 5-hour window as a second line only past 80%, the reserve switch and Tetrix line as `set-about` lines; "Most room" from `sevenDay` and `sevenDayResets` | M |
| B3 | the box's usage gauge always there, a panel with each account's week, "No accounts yet", and a gear to Settings › Accounts | the gauge only once a row has usage (`MessageBox.swift:140`, `:240`); the live app shows none; its link opens the Settings window | UI only. Show the gauge whenever an account exists (usage unknown as "–"), link to the in-window Accounts page (A1) | S |
| C2 | one Models page: each tool's model, effort and complex job effort | the Mac's own `@AppStorage` set "on this Mac" and the runner's set under it (`Settings.swift:697-745`) | UI only. With obid as the runner, show only the runner's (`PUT /v1/settings/models`, options from `/options`) | S |
| A4 | (from docs/conversation-harness.md) Settings › Models › Conversations | none | Needs obid: `conversation.model` in `GET`/`PUT /v1/settings/models`; then one row on the Models page | S |
| A5 | Connectors: the catalogue (Deskree Ops, Tetrix, GitHub, Claude, ChatGPT, Cursor, Slack, Gmail, Google Meet, Zoom) with Connect | only what exists, honestly: accounts, Tetrix, GitHub, plug-ins and connections, with real actions (`Connectors.swift:3-42`) | Needs obid: plug-ins or connections for Slack, Gmail, Meet, Zoom and Deskree Ops; a way for the Mac to add a connection (`POST /v1/connections` signed after Touch ID, the secret entered through A6). Until then, show only what exists | L |
| B4 | Connectors' look: a search field, Connected and Available, brand logos (`brands.tsx`), "✓ Connected", a Connect button | a `Form` with SF Symbols and more groups (Needs attention, Not confirmed, Available) and long help text (`Settings.swift:419-461`) | Done (#813): the design's ten services, one row each with `brands.tsx`'s marks (`Assets.xcassets/Brands`), Connected and Available. The Mac's honest states (how it's signed in, how to disconnect where Oby has no button) moved to the row's tooltip, Disconnect and the rest to its context menu; under the line only what needs doing. Services A5 doesn't have yet say Coming soon | M |
| A6 | Vault: names, Remove, Add a secret | writes this Mac's Keychain (`Settings.swift:628-668`), which obid on this Mac reads; nothing for a remote obid | UI only for This Mac. Needs obid for a remote one: a write-only vault API (names listed, a value set once and never returned), signed like a connection | M |
| B5 | the account menu: your name and email, Settings, Log out | "Name · payer", Accounts…, Integrations…, Settings… (`Sidebar.swift:361-381`) | UI only. Name and this Mac's name (there's no Oby account since 2026-10-20), Settings (A1); no Log out | S |
| B6 | (none: Sangam has no first launch) | First Launch: hello, talk, permissions, agents and accounts, models, in its own window and system styles (`FirstLaunch.swift:50`) | UI only once A2 and A3 exist: the Agents step adds and signs in obid's accounts; restyle on B1 | M |

### 2.2 (a) Missing screens and features

| ID | What Sangam has | What the Mac app does today | What to change | Size |
|---|---|---|---|---|
| A7 | Archived: Home's ⋮ "Archive completed" (a day, 3 days, a week, never), "Archived N" at the side panel's foot, a page with a search, done tasks leaving Home after a while | Done in #814 (`Sidebar.swift` `ArchivedRow`, `GroupPane.swift` `ArchivePane`, `ArchiveAfter` in `shared/JobList.swift`), over the jobs the Mac holds | What's left needs obid: `GET /v1/jobs` keeps only the latest 50, so archived tasks older than those drop off the page until obid lists archived jobs (paged, `before`, or `?archived=true`) | S |
| A8 | ⋮ in the title bar after the task's or conversation's name, and rename in place | Done in #814: the last crumb's ⋮ and `crumb-rename` (`ChatWindow.swift` `TitleBar`), a task renamed through obid's `PATCH /v1/jobs/{id}` | Nothing | – |
| A9 | a task's menu: View details, Open conversation, Rename, Stop task or Archive task, Delete task | Done in #814 (`App/TaskMenu.swift`, on the row, the card and the title bar), Archive and Delete through obid's `/archive` and `DELETE /v1/jobs/{id}`; Delete asks first | Nothing for obid's jobs; this Mac's own Swift-engine jobs have no Rename, Archive or Delete | – |
| A10 | a task's own thread (the message it came in on, Oby's replies, what you told the agent, the decision, the agent's live line), and "Open conversation" leading there when a task has no conversation | no thread: "Go to conversation" only when the job has one (`ChatWindow.swift:446-453`, `Sidebar.swift:315`); the page lists "What you asked" and notes (`TaskPage.swift:318-330`) | UI only: `WindowStep.thread(job)`, built from the job's `request` (with its source), `notes`, `summary`, the ended turn and `job` events; the box sends `POST /v1/jobs/{id}/messages` | M |
| A11 | Session on a task's page: the agent's last tool lines | none: "the runner this Mac talks to doesn't serve a job's transcript" (`TaskPage.swift:278-282`) | Needs obid: a job's tool steps (`step` events with `tool` and `detail` for jobs, as conversations have, or `GET /v1/jobs/{id}/steps`); then the section, in the harness's tool-line style | M |
| A12 | Oby's live face while it works on a turn (spin, ball, three bouncing dots, back together) | a still face (`ObyMark`, `shared/DesignViews.swift:465-488`; `ConversationPage.swift:279`, `:372-391`) | UI only. Port `ObyFaceLive.tsx` (its keys and spring presets) to SwiftUI, 30 fps while live and in sight, three still dots with Reduce Motion | M |
| A13 | Oby looks at the pointer, glances at a click in the window, and glances over when the pointer arrives on the chips | the character takes no pointer (`ChatWindow.swift:368-371` `.allowsHitTesting(false)`), and nothing calls `look` or `notice` (`shared/Character.swift`) | UI only, window-local: while Home shows and the window is key, a local event monitor feeds `oby.look` and `oby.notice`, and the chips' hover sends a glance. No global monitor and no timer (AGENTS.md) | M |
| A14 | (docs/ios-design.md, the harness) Stop in the box's end slot while a turn runs | Stop is in the thread, next to "Thinking" (`ConversationPage.swift:121-124`, `:372-391`); the box's `onStop` is only for the Mac's own brain (`:206`) | UI only: Stop in the box's end slot, `POST /v1/conversation/stop` with the conversation | S |
| A15 | a conversation row's second line: "Started 2 tasks", else Oby's last words | one line: the title and when (`ConversationsPanel.swift:84-118`) | Needs obid: the latest turn's `who` and the first line of its `text`, and how many jobs the conversation started, in `GET /v1/conversations`; then a 2-line row | S |
| A16 | the box's + panel: Add files or photos, Add other Obys, Attach tasks; @ lists the Obys; links, references, paths and `code` set apart as you type; the caret glides | + menu with Screenshot, Clipboard, File (`MessageBox.swift:121-139`); plain text | UI only for the highlighting (the same tokenizer as `textTokens.ts`) and the panel's look. Needs obid for tasks and Obys sent with a message (`POST /v1/plans` takes files only) | M |
| A17 | Oby's question back, held over the box with its options and "Or answer in your own words below" | only for the Mac's own brain (`ConversationPage.swift:36-40`, `:418-433`) | UI: show obid's `question` answer (`POST /v1/plans` `kind: "question"`) the same way. The harness never asks mid-turn, by design (docs/conversation-harness.md) | S |
| A18 | asking other Obys mid-turn: "Asking Wellington's Oby if…", the answer quoted under its owner's picture, steps folded as "Looked at 1 thing, asked Wellington's Oby" | none | Needs obid: an Oby tool that asks another Obi a question inside a turn and returns its answer as quoted data (Obi-to-Obi questions exist as inbox items, not inside a turn) | L |
| A19 | the Obysphere: rail entries, Members and Invited, Invite, Create, an Obysphere's settings, Knowledge and Add a source, someone else's Oby, conversations with other Obys | none (`ChatWindow.swift:6` has Home and Conversations) | Needs obid and the Sphere: several Spheres, members, invites, shared knowledge, conversations with other Obys as threads. obid has one Sphere, its card and exchanges | L |
| A20 | a Routines kind of work | no routines kind (`shared/JobList.swift:157-158`) | Needs obid: scheduled work and its `kind` | M |

### 2.3 (b) Present but different

| ID | What Sangam has | What the Mac app does today | What to change | Size |
|---|---|---|---|---|
| B7 | every kind of work as a chip on Home, always, in the same order | only kinds with tasks (`ChatWindow.swift:292`, `:301`); the empty Home shows none (`mac-03`) | UI only: every kind (Review PR, Issues, Tasks, then teammates who have tasks); a kind with nothing open opens on Completed | S |
| B8 | one look | the old look still compiled and unused: `LiveView` (`App/LivePanel.swift`, only its `account` helper is used), `IslandInbox`'s view (`InboxView.swift`), `JobView`'s view (`JobView.swift`, its `Publishing` and `MovePanel` are used), `ChatComposer` (`App/ChatComposer.swift`), `TurnRow` and `ThinkingLine` (`ChatWindow.swift:550-634`), `JobChip` (`App/JobChip.swift`), `StepList`, `DecisionCard`, `StatusPill`, `OBYStyle` (`apps/shared`) | UI only: delete them, moving the few helpers still used (`LiveView.account`, `JobView.Publishing`, `MovePanel`, `StopButton`) next to their users | M |
| B9 | the sheen's band ±0.45, sweeping −0.5 to 1.5 | ±0.15 (`shared/DesignViews.swift:448-453`) | UI only | S |
| B10 | a page's parts rise in one after another (28px, `--spring`, 620 ms, about 40 ms apart), sink 12px over 200 ms on the way out, a covered page steps back and rises in again | one transition for the whole page, opacity and a 28pt offset with `warm` (`ChatWindow.swift:271-280`) | UI only: a `rise(index:)` modifier on each part (title, tabs, each card), the covered page's step-back, and the way out at 200 ms | M |
| B11 | search only on Conversations, by the panel icon | search on Home too (`Sidebar.swift:170-191`) | UI only: search on Conversations (and Archived's own field) | S |
| B12 | a task's page is its card opened: decision card, then one card with Result, Stages, Details, Session; Stop, Archive and Delete in the ⋮ | a header, the decision, one card with Result, "Stages · <pipeline>", Details, What you asked, then a row of pills (Start now, Use anyway, Move to…, Stop job, Dismiss) (`TaskPage.swift:305-360`, `:498-528`) | UI only: keep the Mac's extra actions (they're obid's) but in the ⋮ (Move to…, Stop, Dismiss as Archive); Start now and Use anyway stay on the page while they apply; What you asked moves to the thread (A10) | M |
| B13 | a task card in a conversation opens the task; Stop is in its menu | a Stop button over the card on hover (`ConversationPage.swift:335-337`) | UI only: Stop in the card's context menu only | S |

### 2.4 (c) Logic

| ID | What Sangam has | What the Mac app does today | What to change | Size |
|---|---|---|---|---|
| C3 | a decision lives with its task: its card, its page, its thread, and the conversation that started it | every open decision, from any job, shows in whichever conversation is open, placed by time when its job wasn't started there (`ConversationPage.swift:62-72`, `:98-119`; `shared/ConversationModel.swift:349-355`) | UI only: in a conversation, only the decisions of jobs whose `conversation` is that one; the others on their task's card, page and thread (A10) | M |
| C4 | telling a task something from its page goes on the end of its conversation (or thread), which opens, and Oby says what it did | the page's box sends straight to the agent and stays on the page; what you said is listed under "You told the agent" (`TaskPage.swift:354-358`, `:318-330`) | UI only: keep `POST /v1/jobs/{id}/messages` (#542), then open the task's conversation or thread (A10), where the words and the job's answer show | M |
| C5 | words to a done task start a follow-up task | words to a done job pick it up again as one more round (#644, obid) | Keep obid's way (the owner's decision). Only the words: "Ask for a follow-up…" becomes "Tell Claude Code to pick it up again…", and no second card appears | S |
| C6 | needs-you shows as orange dots (the rail's Home, chips, group heads, rows, cards) and the decision on the task's card; no inbox screen | a bar over the conversation, "N waiting for you ⌘J", gathering every decision (`ConversationPage.swift:76-82`, `:393-416`) | UI only: drop the bar from the conversation (C3 leaves only that conversation's decisions there); "N need you" in the attention line opens the first kind that needs you on Running. See C9 for items with no task | M |
| C7 | Oby on Home melts into loading while it thinks and works while agents work | loading only while the Mac's own brain thinks (`ObyModel.swift:81-85`); an obid turn (`thinking` events) doesn't change it | UI only: loading while any obid conversation turn runs (`thinking` `running` to `done`) | S |
| C8 | a task is new (blue) until opened | new means created after the window's state began and not opened since, kept in memory (`ChatWindow.swift:138-141`): after a relaunch nothing is new | UI only: keep the opened job ids (and when the app last ran) on disk | S |
| C9 | (not in Sangam: every decision has a task) | obid's items with no job (`audit`, `failure`, `pluginEvent`, runner updates) show in the conversation | UI only: a small Inbox page (docs/ios-design.md, "Inbox") for items with no task, reached from the attention line; Sangam's look | M |

### 2.5 How many

| Group | Gaps | Of them in 2.1 |
|---|---|---|
| A, missing screens and features | 20 (A1–A20) | 6 |
| B, present but different | 13 (B1–B13) | 6 |
| C, logic | 9 (C1–C9) | 2 |
| All | 42 | 14 |

Needing obid work: A2, A3, A4, A5, A6 (remote), A7 (paging), A8 (task title), A9 (delete), A11, A15, A16 (tasks and Obys), A18, A19, A20. Everything else is UI only.

### 2.6 Where the design meets the owner's rules

- **The pointer.** Sangam's main process sends the cursor's position 60 times a second while the window is visible, so Oby watches it anywhere on screen (`design/app/README.md`, `Oby.tsx`). AGENTS.md: no 30 Hz mouse timer and no global click monitor, about 0% CPU with the window closed. On the Mac Oby follows the pointer and clicks only inside the window, from a local event monitor, while Home is on screen (A13). The window closed or covered, the character stays paused, as it is today (`ChatWindow.swift:282`, `shared/Character.swift:60-77`).
- **The microphone.** Sangam's box has a voice button that does nothing yet (`Composer.tsx:256`). It must never open the microphone on a click: on the Mac the mic opens only while the talk key is held or after fn + Space. Keep it as the Mac has it, a hint ("Hold fn to talk", `MessageBox.swift:159-165`). Sangam's Voice footer already says the rule.
- **No always-on panel, 0% CPU closed.** Sangam has no always-on panel, but his copy still speaks of "the island" (`SettingsView.tsx:139`, `:333`), which is gone. The live face (A12) and the sheen draw only while visible; the talk pill (`TalkPill.swift`) stays the only thing on screen with the window closed.
- **Merging.** Sangam's stages end in "Merged into dev" and Runner › Publishing says "Oby merges only into dev, once its review approves". obid never merges and doesn't run Oby's review yet (docs/runner-api.md, "what obid leaves out"): its Review stage reads "Pull request open · waiting for your review on GitHub", and once GitHub approves, its last stage reads "Merge it on GitHub", which opens the pull request. The Mac shows obid's words.
- **Shared knowledge.** Sangam's Knowledge connects a source once with an admin's sign-in that every member's Oby then uses. AGENTS.md: Oby uses a secret only for a connection the user made, and never forwards a login. That needs the owner's decision before A19.
- **Other people's Obys.** Their words show in conversations (A18, A19). AGENTS.md: other Obys send typed actions only, and their text reaches agents as quoted data, never in a prompt. Displaying it is fine; asking them mid-turn (A18) must keep that.
- **Log out.** There is no Oby login for the Mac itself; only Remote access signs in to Oby's control plane (B5).
- **Follow-ups.** Sangam starts a new task; the owner decided a finished job picks up again (#644, C5).
- **The brain's model.** "Oby's brain stays on Haiku" (Models' footer) is the plan loop's; conversations run on Sonnet in Claude Code (docs/conversation-harness.md). The footer should say so.

## Part 3: order of work

Small pull requests into `dev`, biggest user-visible wins first, Settings and accounts leading at the owner's ask. Each is UI only unless it says obid.

1. **Settings components** (B1): the `Set…` views on Tokens in `apps/shared`, with tests on their states. The iPhone's Settings can use them too.
2. **Settings in the window** (A1, B5): pages over Home, the side panel's Settings section, the account menu, ⌘,; every page moved onto B1 as it is, same contents.
3. **obid accounts read as signed in** (C1, first part; small, and it can go first on its own): decode `signedIn` from the runner instead of `label != nil`. Then **one account list, Sangam's usage rows, the gauge** (C1, B2, B3), and **one Models page** (C2): with obid as the runner, only obid's accounts and models.
4. **obid: accounts API** (A2, A3): `POST`/`PATCH`/`DELETE /v1/accounts`, `payer`, `GET /v1/accounts/{id}/sign-in`, the `accounts` event; docs/runner-api.md in the same pull request.
5. **Add an account on the Mac against obid** (A2, A3, B6): Settings › Accounts' form and Sign In, and First Launch's Agents step.
6. **Connectors' look** (B4), **conversations' model** (A4, obid then Mac), **vault for a remote obid** (A6, obid then Mac).
7. **Home**: every kind as a chip (B7), Oby's mood from obid turns (C7), new tasks that stay new across launches (C8).
8. **Decisions where they belong** (C3, C6, C9): only a conversation's own decisions in it, the orange dots and the attention line leading to the rest, a small Inbox for items with no task.
9. **Oby at work**: the live face (A12), Stop in the box (A14), the sheen's width (B9), obid's question pinned over the box (A17).
10. **Task threads** (A10, C4, C5, B13): the thread page, the task page's box opening it, follow-up words, Stop in the card's menu.
11. **Task page and menus** (B12, A8, A9): the ⋮ in the title bar and the row, rename in place (conversations now; tasks after obid's `PATCH /v1/jobs/{id}`), Archive as dismiss, Delete after obid.
12. **Archive** (A7): obid's paged, searchable job list, then the rule, the foot and the page.
13. **Oby looks around the window** (A13).
14. **Motion and the side panel** (B10, B11): parts rising in turn, covered pages stepping back, search only on Conversations.
15. **Delete the old look** (B8).
16. **Conversation rows' second line** (A15, obid then Mac).
17. **The box's + panel and highlighting** (A16; tasks and Obys after obid).
18. **Session on a task's page** (A11, obid then Mac).
19. **Connectors' catalogue** (A5) as obid gains the plug-ins and the add-connection flow.
20. **Routines** (A20), **asking other Obys mid-turn** (A18) and **the Obysphere** (A19), each after obid and the Sphere serve them, and A19 after the owner decides on shared knowledge.

## Screenshots

In `/private/tmp/claude-501/mac-design-shots/` (not committed): `sangam-01` to `sangam-29` (Home with and without the side panel, a kind's page, a task's page needing you and running with its session, the task menu, Home's options, Conversations, a conversation with task cards, a turn in progress and answered with a quoted Oby, the + and usage panels, Archived, the account menu, every Settings page, the invite modal, someone else's Oby, a group conversation, Knowledge), and `mac-01` to `mac-10` (the empty conversation, Home with and without the side panel, Settings › General, Runner, Accounts top, add and obid's list, Models, Connectors).
