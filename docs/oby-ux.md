# Oby's UX model: one logic, Mac and iPhone

One page that says how Oby works for the person using it, the same on the Mac and on the iPhone, and then every place the apps or obid don't follow it yet. **Sangam's design (`design/app`, run with the `sangam-design` configuration in `.claude/launch.json`) is the model** (AGENTS.md, "Sangam's design leads", the owner's decision of 2026-10-18): where the apps, obid or a doc differ from it about what the user sees or does, they change. AGENTS.md's rules are how his design is built underneath, never a reason to change what the user sees. Where his design says nothing (setup, offline, memory), this page fills the gap in his language. docs/mac-design.md (PR #663) and docs/ios-design.md are the per-platform gap lists; docs/conversation-harness.md is the logic under a conversation; docs/runner-api.md is the API.

The setup of a new Mac and iPhone is its own document, [onboarding.md](onboarding.md).

How this was made: Sangam's code read (`tasks.ts`, `chats.ts`, `StatusDot.tsx`, `TaskCard.tsx`, `SettingsView.tsx`, `mock.ts`) and run in a browser; the Mac app (`apps/mac/app`, `apps/shared`) and the iPhone app (`apps/ios/app`, `apps/shared`) read screen by screen on `dev` at 9545d1c (`dbf9857` changed only AGENTS.md). `file:line` references are at that commit. Nothing was changed in either app.

## 1. The model

### Talking and work

There are two things in Oby, and they never turn into each other.

- **A conversation is talking.** You say something; Oby answers. It reads, searches and runs things in the open while it thinks (tool lines), its words arrive a word at a time, and most turns end in words. Home's message box starts a new conversation; a reply carries one on. A conversation is never a task.
- **A task is work.** It exists only once Oby starts one: an agent (Claude Code, Codex or Cursor) on one of your accounts, in its own worktree of one repository, with a check that says when it's done. It shows as a card under the words that started it, a row on Home, a page of its own, and its own thread with its agent.

Deleting a conversation leaves its tasks; each then keeps its own thread. Telling a task something always goes to that task's agent (through Oby, which says what it did with it), never into a new conversation.

### Home

Home answers one question at a glance: **does anything need me, and is anything running?** Then it lets you start talking.

- Oby, the character, on its stage. Its mood is Oby's: listening while you talk, thinking while a turn runs, working while agents work, quiet otherwise. While the window is visible it follows the pointer anywhere on screen and glances at clicks; it stops the moment the window closes or goes out of sight.
- The attention line: "2 running tasks · 1 needs you", or "All quiet. Give me something to work on". "needs you" leads to the first decision.
- The kinds of work as chips, every kind, always, in one order (Review PR, Issues, a teammate, Tasks, Routines): a blue dot when one holds a task you haven't opened, an orange one when something in it needs you.
- The message box: "What do you want me to work on, <first name>?".

Home isn't an inbox and isn't a dashboard. On the Mac the side panel lists the tasks and conversations; the iPhone has no side panel, so its Home adds two short lists under the chips (up to three running tasks, the three latest conversations), which are the same lists, cut short.

### A task's life

| State | Means | Its mark | Which tab |
|---|---|---|---|
| **New** | Started, and you haven't opened it yet (kept across launches) | blue dot | where its state puts it |
| **Queued** | Waiting for room (an account, a slot, a time it was told to wait for) | none: being in the list unstarted says it | Running |
| **Running** | Its agent is at work; the card shows the live step and the round | grey dot, pulsing | Running |
| **Needs you** | A decision is open on it, whatever its agent is doing | orange dot | Running |
| **Done** | Ended with what it was asked: commits, a pull request, a report | grey check | Done |
| **Failed** | Ended without it, or was interrupted; a `failed` decision ("Try again", "Dismiss") comes with it, so it needs you until you answer | orange dot while the decision is open, then the grey check, its failed stage red on its card (`sangam/TaskCard.tsx:211-218`) | Done |
| **Stopped** | You stopped it | grey check, "Stopped" as its step | Done |

- One mark in one spot. A row never carries two.
- **Follow-up.** Telling a done task something starts a follow-up task with the same kind of work, agent, account and repository, its card under Oby's reply ("This one's finished, so I started a follow-up. Claude Code has it in obi on Personal.", `sangam/tasks.ts:108-114`). The box on a done task says "Ask for a follow-up…". This replaces #644's extra round.
- **Archive.** Done tasks leave Home three days after they finish (a day, a week or never, from Home's ⋮), and stay in Archived. Archive on a task does it at once; Delete removes it from Archived too.
- **Order.** New first, then needs you, then queued, then the rest as they came.

### Decisions

A decision is an inbox item: something only you can answer. It waits with no timeout, and only its task waits.

| Kind (as shown) | When | Answers |
|---|---|---|
| **Permission** | the agent wants to run or edit something its mode doesn't allow | Allow, Always allow, Deny |
| **Question** | the agent asked (a plan to approve is a question too) | the agent's options, or your own words |
| **Start it?** | Oby guessed the plan, or looked into it first | Start, Cancel |
| **Confirm** | Oby planned something only you may allow: a job in Bypass, an always-allow rule, accepting another Oby's request | Confirm, Cancel |
| **Remember?** | you said or did something that sounds like a rule (Memory, below) | Remember, Only this time |
| **Failed**, **Out of usage** | the task failed or was interrupted, or every account was full | Try again, Dismiss |
| **Out of reviews**, **Not merged** | Oby's review or merge check gave up | One more round / Try again, Dismiss |

- **Where they live:** with their task. On its card, its page, its thread, and in the conversation that started it. A conversation shows only its own tasks' decisions.
- **How they reach you:** the orange dots (the chip, the row, the side panel's Home, the attention line) and a notification. There is no Inbox screen for decisions that belong to a task; a small Inbox lists only what has no task (a daily audit, an Oby failure, a runner update).
- **How they read:** the kind in orange, a headline of at most eight words, what happened in a sentence or two, the command or diff in a mono block, the options with the recommended one filled (else the first, as Sangam's card does), Deny in red, and always a quiet **Later**. Underneath, Return never picks Deny, Dismiss, Stop or Confirm: the fill is what you see, the keyboard stays safe.
- **Answered once, everywhere.** Answering on the iPhone clears it on the Mac and the notification on both.

### Artifacts

What an agent makes to be looked at: a page, a document, a chart, a canvas of design options, an image or a PDF. It shows as a card under the words (or in the task) that made it, and opens in a viewer: a window on the Mac, a full-height sheet on the iPhone. A page runs with no network, from obid's own files only. Every version is kept; the viewer's version menu moves between them.

### Accounts and agents

- **An agent** is a coding tool: Claude Code, Codex, Cursor. **An account** is one login of that tool (Personal, Deskree), with a folder of its own, and who pays for it.
- **Oby never sees a login.** Signing in is always the tool's own sign-in (its browser page, its device code), on the machine obid runs on. Oby only learns that the tool says it's signed in, and as what plan.
- **Oby picks the account.** Every task goes to the account with the most weekly room per day left, unless you named one. You name one only when you want to ("on Personal"), or with Move to… on a task.
- **One list.** Every app shows obid's accounts, and only those: grouped by tool, each with its plan, who pays, and its week.

### Usage

- **The week is the number.** Each account shows how much of its week is used, and when it resets. The 5-hour window shows only past 80%.
- **The gauge** sits in the message box whenever there's an account; its dot turns yellow past 80% and red past 90%; it opens each account's week, with "Most room: Deskree on Codex, 88% left this week".
- **The reserve.** Oby keeps the last 20% of each week for work you send to that account by name. A task held only by reserves says so and offers "Use Personal anyway (82% of week)".

### Notifications

A notification is a decision you can make from where it lands, or news that work ended badly. Nothing else notifies.

- **Needs you:** a permission (Allow, Always allow, Deny right in the notification), a question, a Confirm, a task that couldn't publish (Publish, which asks for Face ID or Touch ID).
- **Ended badly:** failed, interrupted, Oby's review gave up.
- **Never:** steps, rounds, a task that finished fine. On the iPhone a running task is a Live Activity instead (Lock Screen, Dynamic Island), which ends a while after the work does.
- **One place at a time.** Answered anywhere, it's cleared everywhere.
- Asked for at the moment it matters: the first time a task you started could need you, never on first launch.

### Talking to Oby out loud

The window's voice button listens on a click, until a second click or Stop, at most a minute, and leaves the words as a draft (Sangam's button; AGENTS.md). On the Mac, fn held (or fn + Space) talks from any app; on the iPhone a tap on the mic does what the click does. Nothing else ever opens the microphone. Your words show as you talk, in the window and, with the window closed, in the talk pill; Oby answers in writing, never aloud (the owner's decision of 2026-10-23). The pill shows "Thinking", then the first lines of the reply for a few seconds or until the next press; after fn + Space, Oby listens again once its reply shows.

### Other people's Obys: the Obysphere

An Obysphere is a team or community (Sangam's "Deskree"). Its admins are whoever made it and whoever they made admins; one person can be an admin in one sphere and a member in another. Admins invite and remove people and connect its Knowledge (Tetrix, or any MCP server) once, for that sphere only: every member's Oby uses it as Sangam designed, while the admin's sign-in stays with the admin's Oby or Oby Cloud, which answers members' lookups and returns only the answer. Other Obys reach yours only with typed requests (a review, a question); their words show quoted under their owner's name, and you decide what yours answers. Obyspheres are part of Oby Cloud (onboarding.md, section 4).

### Memory: how you like work done

How you or a repository likes work done (merge into dev, never touch main, rebase first, who reviews) isn't a product rule: Oby learns it. When you say or do something that sounds like one, it asks "Can I remember that?" and saves it only with your yes. From then on it follows it and says so ("Merged into dev, as you like"), and Settings › Memory lists every memory by repository and "About you", to edit or delete. Until it has learned anything for a repository it takes the safe default: it opens the pull request, asks before any merge, and never touches the default branch. Only AGENTS.md's safety rules (secrets, logins, the secret scan, outside text as data, the microphone) are fixed; a memory never widens them.

### Two ways to run Oby

Oby is open source. **Just this Mac** runs everything on the Mac with no account; the iPhone pairs on the local network and reaches the Mac away from home through the owner's own Tailscale or server. **Oby Cloud** adds remote access with nothing to set up, teams and Obyspheres. Either way code, logins, secrets and pairing keys stay on the devices, and a Just-this-Mac Oby signs in to Cloud later without starting over.

### Offline, and when the Mac sleeps

obid, on the Mac, is where everything lives. The apps are windows onto it.

- **The Mac app and obid** are on the same Mac, so the window works offline; agents need the network for their models, and say so on their task.
- **The iPhone** reaches obid on the same network directly, and from anywhere else through the route its owner chose: their own Tailscale or server (Just this Mac), or Oby's relay (Oby Cloud), sealed end to end either way (onboarding.md, "Remote access, by path"). When it can't, it says why in one line, the same words on every screen, and shows what it last knew: "Your Mac is asleep. Oby picks up when it wakes.", "Can't reach your Mac. Check it's on and online.", "No internet on this iPhone." What you send meanwhile waits on the iPhone, marked "Sends when your Mac is back", and goes when it is; an answer to a decision goes with its item's id, and obid refuses it if the decision was settled meanwhile.
- **Sleep.** A running task keeps the Mac awake. On power, "Keep my Mac available" stops idle sleep too. With the lid closed on battery the Mac sleeps, its tasks wait, and they carry on where they were when it wakes.
- **After a restart** obid picks its tasks up again; an interrupted one says so and needs you.

## 2. Where the apps differ from the model, or from each other

Every row is something to change in the apps or obid toward Sangam's design, except where a row says the platform needs it (a sheet on the iPhone where the Mac has a page or a window, the iPhone's lists on Home where the Mac has a side panel, fn on the Mac where the iPhone has a tap): those follow his logic in the platform's own way.

References: Sangam's files are under `design/app/src/renderer/src/` (shown as `sangam/`), the Mac app's under `apps/mac/app/` (`mac/`), the iPhone app's under `apps/ios/app/` (`ios/`), and what both compile under `apps/shared/` (`shared/`). docs/mac-design.md's gap IDs (A1–C9) are given where a row is already one of them, so the two lists don't get built twice.

### The ten that matter most

1. **Decisions live in three different places.** Sangam keeps a decision with its task. The Mac puts every open decision, from any job, into whichever conversation is open, with a "N waiting for you ⌘J" bar; the iPhone has a "Needs you" page and a "Needs you · N" chip on Home. (rows 9–11)
2. **"Needs you" is counted four ways.** Mac menu bar badge vs its own summary line; iPhone chip vs its own attention line. The same Mac can say 1 and "Nothing needs you" at once. (row 5)
3. **Notifications differ in what they say and what they let you do.** The Mac doesn't notify permission waits, Start it?, Out of usage or Confirm; neither app offers Allow/Deny in the notification although the API's `permission` category is for exactly that; both ask for notification permission on the first connection instead of when it matters. (rows 14–16)
4. **Offline looks different on each.** The Mac shows it only on the conversation page, in other words; the iPhone shows it on Home and in conversations, says "asleep or offline" even while just connecting, and queues sends with no visible state. (rows 17–18)
5. **One task, several vocabularies.** Working vs Running for the same state, Ready vs Done, Blocked for interrupted. (row 6)
6. **Home's chips.** Sangam shows every kind always; both apps show only kinds that have tasks, the iPhone adds a "Needs you" chip, and the teammate kind is never produced on either. (rows 3–4)
7. **Task actions and follow-ups.** Sangam starts a follow-up task when you tell a done task something; obid resumes the old one instead (#644), the Mac hides the box unless the job can resume, and the iPhone always shows it; the iPhone has a red "Stop all" on Home with no confirmation; actions are pills on both where Sangam has a ⋮ menu. (rows 19–22)
8. **Accounts.** The Mac has two lists with the same name and calls obid's accounts signed out; the iPhone shows them read-only with a "sign in" line nothing acts on; the two apps colour usage at different thresholds. (rows 24–26)
9. **Pairing and first run.** The Mac won't make a pairing code without Remote access; obid doesn't advertise, so the iPhone's code entry can't find it; a fresh iPhone talks to the owner's own tailnet address; the 30-day token expiry isn't handled and its 401 blames Tailscale. (rows 31–34)
10. **Theme.** Both apps force dark; the Mac's Settings window alone follows the system; the iPhone design calls for light and dark. (row 1)

### The full list

| # | Concept | Sangam | Mac | iPhone | Fix |
|---|---|---|---|---|---|
| 1 | Theme | dark only (`sangam/tokens.css`) | forced dark: `mac/App/ChatWindow.swift:74`, `:208`, `mac/FirstLaunch.swift:32`; the Settings window follows the system | forced dark: `ios/ObyPhoneApp.swift:32`, `apps/Oby.xcodeproj/project.pbxproj:1001`, `:1045` | Both follow the system with the design system's light set; Settings › Appearance (System, Light, Dark) on both. |
| 2 | The character on Home | 280 × 220, `embed&size=1.23` (`sangam/Oby.tsx`) | 280 × 220, `embed` (`mac/App/ChatWindow.swift:301`, `:368-382`) | 240 × 200 (`ios/Home.swift:109-115`) | Platform: smaller on the phone. Use `embed&size=1.23` and docs/ios-design.md's size. |
| 3 | Home's chips | every kind, always (`sangam/tasks.ts:18-24`, `sangam/Home.tsx:352`) | only kinds with tasks (`mac/App/ChatWindow.swift:292`, `:301`) (B7) | only kinds with tasks, plus "Needs you · N" first (`ios/Home.swift:104`, `:127-129`) | Every kind on both; drop the Needs you chip (the orange dots and the attention line do that job). |
| 4 | The teammate kind | a teammate's name is a kind (`sangam/tasks.ts:21`) | `requester` always nil (`mac/App/Sidebar.swift:30-32`, `:43`) | `requester: nil` (`ios/Phone.swift:13`, `:20`) | Pass the job's `obi.fromOwner` on both, so a teammate's work groups under their name. |
| 5 | Counting "needs you" | tasks with a decision (`sangam/tasks.ts:28-29`) | menu bar badge counts permissions, questions and inbox entries (`mac/ObyModel.swift:63-75`), its summary uses `NeedsYou.line`, which doesn't (`shared/Runner.swift:894-910`) | chip counts `InboxItem.waiting`, attention line counts `.needs` jobs (`ios/Home.swift:105-106`) | One function in `shared/`: jobs with an open decision, plus inbox items with no job. Every count uses it. |
| 6 | Status words | Running, Queued, Needs you, Done, Failed; the mark's label says "Working" (`sangam/StatusDot.tsx:15`) | mark "Working", thread card "Running" (`shared/ChatRuns.swift:121`); badges "Ready" for done, "Blocked" for interrupted (`shared/Runner.swift:843-862`) | the same shared code | One vocabulary on both and in Sangam's labels: Queued, Running, Needs you, Done, Failed, Stopped, Interrupted. |
| 7 | Oby follows the pointer | looks at the pointer anywhere on screen while the window is visible (`sangam/Oby.tsx`, `design/app/README.md`) | takes no pointer: `.allowsHitTesting(false)` (`mac/App/ChatWindow.swift:368-371`); nothing calls `look` or `notice` (`shared/Character.swift`) (A13) | glances at a tap (docs/ios-design.md), not built | Mac: follow the pointer anywhere on screen while the window is visible, stopping the moment it closes or goes out of sight (AGENTS.md, as decided); iPhone: the glance at a tap. |
| 8 | The words "All quiet" | "All quiet. Give me something to work on" | Home the same (`shared/WindowTrail.swift:71-80`); menu bar "All quiet." (`shared/JobList.swift:10`) | the same as the Mac's Home | Keep: the menu bar is outside his window, and its line is short. |
| 9 | Where a decision shows | with its task: card, page, thread, its conversation (`sangam/TaskCard.tsx:139-163`) | every open decision in the open conversation, placed by time (`mac/App/ConversationPage.swift:62-72`, `:98-119`) (C3) | under the turn that started its job (`ios/Chat.swift:263-265`), and on the Needs you page | Only that conversation's tasks' decisions in a conversation, on both. |
| 10 | An inbox screen | none | "N waiting for you ⌘J" bar over the conversation (`mac/App/ConversationPage.swift:76-82`, `:393-416`) (C6) | "Needs you" page, longest-waiting first (`ios/Home.swift:350-378`) | Both: no decisions bar; the attention line opens the first task that needs you; a small Inbox only for items with no task (C9, docs/ios-design.md "Inbox"). |
| 11 | Decision cards | one card (`.tc-ask`) | `InlineDecision` / `InlinePermission` (`mac/App/InlineDecision.swift`) | `AskCard` (`shared/DesignViews.swift:13`); the Watch and old Mac code use `DecisionCard` | One card in `shared/` on both; delete the unused one (B8). |
| 12 | The recommended option | filled: `recommended`, else the first (`sangam/TaskCard.tsx:157`) | filled only when first, recommended and safe on Return (`shared/DesignViews.swift:72-73`, `shared/Decisions.swift:168-174`) | the same | Fill as Sangam does on both; keep the safety underneath: Return never picks Deny, Dismiss, Stop or Confirm, whatever is filled. |
| 13 | The permission answers | Allow, Always allow, Deny (`sangam/mock.ts`) | "Allow once", "Always allow", "Deny" (`shared/Decisions.swift:185`, `:236`) | the same | "Allow", as Sangam has it, on both and in notifications. |
| 14 | What notifies | needs you: ready to publish, failed or interrupted, a question, out of reviews, not merged (`sangam/SettingsView.tsx:122`) | questions, ready to publish, review, merge, failed, interrupted; not permissions, Start it?, Out of usage, Confirm (`mac/RunnerFeed.swift:595-607`) | the runner's pushes; with obid, nothing (obid has no `/v1/notifications`) | The owner's rule of 2026-10-23 (Mac: #862, #863, #613, `mac/Alerts.swift`): something that needs you (a job's ask, the conversation's shell ask, a Confirm, a Start it?, Oby's question), a job you started that ends done or failed, Oby's answer while the window isn't showing that conversation, and an outside item obid sorts as needing you. Never progress, an FYI or what the window shows; one alert per thing, gone once it's settled anywhere. |
| 15 | Notification actions | n/a | `ready`: "Publish with Touch ID", Open; `job`: Open (`mac/RunnerFeed.swift:667-674`) | `ready`: "Publish", Open; `job`: Open; `approve`: "Publish with Face ID" (`ios/Notifications.swift:20-28`); no `permission` category though the API sends it | Both: `permission` with Allow, Always allow, Deny; `ready` with "Publish" (the system names Touch ID or Face ID in its own prompt). |
| 16 | When notifications are asked for | n/a | first live runner connection (`mac/RunnerFeed.swift:327`, `:677-686`), and FirstLaunch | first successful connection (`ios/Phone.swift:427-428`) | After the first task you start, with one sentence on what will notify (onboarding.md, iPhone 3). |
| 17 | Offline | not designed | "<name> isn't reachable. Oby will reconnect automatically." on the conversation page only (`mac/App/RunnerOfflineNotice.swift:7`, `mac/App/ConversationPage.swift:76`) | "Your Mac is asleep or offline. Last seen …" on Home and in conversations (`ios/Phone.swift:238-242`); Settings shows it while still connecting (`ios/SettingsScreen.swift:24`) | One line in `shared/`, on every page, telling apart connecting, asleep, unreachable, no internet and unpaired (onboarding.md, "Errors and recovery"). |
| 18 | Sending while offline | n/a | n/a (obid is local) | words queued and sent on reconnect, with no visible state (`ios/Offline.swift:77-78`, `ios/Phone.swift:605-664`); answers to decisions queued and the item removed at once (`ios/Phone.swift:775-780`) | Show "Sends when your Mac is back" on what waits; keep a queued answer's decision on screen, marked, until obid takes it. |
| 19 | Telling a done task something | "Tell Claude Code…"; done: "Ask for a follow-up…", which starts a follow-up task with the same kind, agent, account and repository (`sangam/ChatView.tsx:226`, `sangam/tasks.ts:108-114`) | only while running or resumable (`shared/TaskFacts.swift:92-96`); a finished job resumes as one more round (#644) | the box always, ignoring those gates (`ios/TaskPage.swift:213`, `:231`); the same round | Sangam's follow-up task on both, replacing #644's extra round in obid (the follow-up-task session is on it); the box on every task, with his words. |
| 20 | Stopping everything | none (an Electron window has no menu bar) | menu bar "Stop All Agents" ⌃⌥⌘. (`mac/ObyApp.swift:10-40`) | red "Stop all" on Home's toolbar, no confirmation (`ios/Home.swift:79-85`, `ios/Phone.swift:749-751`) | Keep the Mac's menu bar as it is (outside his window). iPhone: off Home, as his Home has none; in Settings, with a confirmation. |
| 21 | A task's actions | ⋮: Open conversation, Rename, Stop task or Archive task, Delete task (`sangam/TaskMenu.tsx:21-27`) | pills: Start now, Use … anyway, Move to…, Stop job, Dismiss (`mac/App/TaskPage.swift:500-527`); hover Stop on cards (`mac/App/ConversationPage.swift:335-337`) | pills: Start now, Use … anyway, Move to…, Mode, Stop task, Dismiss (`ios/TaskPage.swift:378-398`) | The ⋮ on both, same items and words ("Stop task", "Archive task"); Start now and Use anyway stay on the page while they apply (B12, B13). |
| 22 | Archive | done tasks leave Home after 3 days, Archived page (`sangam/tasks.ts:152-175`) | none: "Clear done", "isn't on the Mac yet" (`mac/App/GroupPane.swift:15`) | kept on the phone only (`ios/Phone.swift:25-29`, `ios/Home.swift:312-347`) | obid's paged list of settled jobs; the same rule and page on both (A7). |
| 23 | Running and Recent on Home | in the side panel | side panel (`mac/App/Sidebar.swift`) | not on Home; tasks behind a toolbar button (`ios/Home.swift:76-77`) | Platform: the iPhone has no side panel, so Home lists up to three running tasks and three conversations (docs/ios-design.md). |
| 24 | Accounts | one list, Add (Tool, Name, Paid by), Remove (`sangam/SettingsView.tsx:201-240`) | two lists, "Accounts on this Mac" and "Accounts on This Mac"; obid's read as signed out (`mac/Settings.swift:315-357`) (C1) | read-only "Accounts on the runner" (`ios/SettingsScreen.swift:45-53`); "Tetrix: not connected: sign in" with nothing to tap (`shared/Usage.swift:250-257`) | One list from obid on both (being built: the mac-settings and obid-accounts sessions). Platform: signing in happens on the Mac, where the tools run; the iPhone says "Sign in on your Mac". |
| 25 | Usage colours | yellow past 80%, red past 90% | the gauge 80/90 (`shared/ChatRuns.swift:148-154`); `Usage.level` 70/90 (`shared/Usage.swift:130`) | the same two | One level function, 80/90. |
| 26 | Usage in the box | the gauge always (`sangam/Composer.tsx`) | only when a signed-in account has usage (`mac/App/MessageBox.swift:139-141`) (B3) | none | The gauge on both, whenever an account exists. |
| 27 | Stop in a conversation | in the box's end slot | next to "Thinking" in the thread (`mac/App/ConversationPage.swift:121-124`) (A14) | in the box's end slot (`ios/Composer.swift:71-102`) | The Mac follows the iPhone. |
| 28 | Oby's question, Later | Later keeps it | `BrainQuestion` (`mac/App/ConversationPage.swift:420-433`) | Later calls `phone.cancel()` and drops the words (`ios/Chat.swift:273-277`) | Later puts it off on both; nothing is dropped. |
| 29 | Artifact viewer | not designed | a sheet, at least 760 × 560 (`shared/HarnessViews.swift:294-296`, `:361`) | a sheet | Platform: a sheet on the iPhone. On the Mac a window of its own, so it sits beside the conversation. |
| 30 | Permission modes | "Permissions on this Mac" and the runner's (`sangam/SettingsView.tsx:109`, `:152`) | two pickers; the task's mode menu offers Sandbox to local jobs (`mac/App/TaskPage.swift:387`, `:529-543`) though General excludes it (`shared/Decisions.swift:27`) | the runner's only (`shared/PermissionsSection.swift`) | With obid there is one runner: one Permissions section on both. |
| 31 | Where pairing lives | not designed | Settings › Runner › Pair a device, which refuses without Remote access (`mac/PairingView.swift:64-66`, `:81-82`) | Settings › Your Mac › Scan QR code, Paste, Enter code (`ios/ConnectScreen.swift:45-74`) | Mac: Settings › iPhone, no prerequisite; iPhone: Connect is the first screen (onboarding.md). |
| 32 | Finding the Mac | not designed | obid's gateway binds 127.0.0.1 and isn't advertised (`core/crates/obid/src/gateway.rs:13-14`) | browses `_oby._tcp` (`ios/ConnectScreen.swift:255-278`), so code entry fails against obid (`:168`) | Advertise `_oby._tcp` for obid (onboarding.md, build list). |
| 33 | A fresh iPhone | not designed | n/a | talks to `https://tetrix-lab.tail8de49b.ts.net:8443` (`shared/Runner.swift:928`); Settings › Runner has an address field and says the iPhone needs Tailscale | No default address; first run is Connect; the Runner section goes. |
| 34 | Pairing expiry | n/a | lists devices and their expiry (`mac/PairingView.swift:33-57`) | drops `expiresAt` (`ios/Phone.swift:890-894`); a 401 reads "The runner only answers its owner's Tailscale login." (`shared/Runner.swift:1386`) | Renew while in use (onboarding.md); a 401 from the gateway says "This iPhone was removed from your Mac. Scan the code to connect again." |
| 35 | Voice | the box's voice button (`sangam/Composer.tsx:256`) | no click-to-talk in the window; hold fn or Control-Option, fn + Space hands-free (`mac/TalkKey.swift`) | tap the mic, up to 60 s, words stay a draft (`ios/PhoneVoice.swift:150-183`) | Mac: the voice button listens on a click, as the iPhone's tap does (until a second click or Stop, at most 60 s, a draft; AGENTS.md as decided); fn stays for talking from any app. |
| 36 | Asking for the microphone | n/a | on the first talk (`mac/Voice.swift:220-224`), or in FirstLaunch's Permissions step | on the first mic tap, microphone then speech (`ios/PhoneVoice.swift:83-93`) | Both on first use, with one line before the system prompt. |
| 37 | Publishing by hand | "this Mac's key, like the iPhone's, signs only after Touch ID" (`sangam/SettingsView.tsx:167`) | Touch ID (`mac/RunnerFeed.swift:669`) | Face ID ("Publish with Face ID", `shared/DeviceKey.swift:41`) | Platform: each device's own biometrics. The button says "Publish" on both. |
| 38 | Kind labels | Question, Permission, Out of reviews, Failed, Out of usage, Start it?, Not merged (`sangam/mock.ts:36`) | the same plus "Confirm it?", "Issue audit", "Oby failure" (`shared/ChatRuns.swift:98-118`) | the same shared labels | "Confirm", to match the API and docs/ios-design.md. |
| 39 | Settings | pages in the window (`sangam/SettingsView.tsx`) | a separate window with tabs: General, Runner, Remote, Accounts, Models, Connectors, Vault, About (`mac/ObyApp.swift:88-97`) (A1) | Runner, Your Mac, Voice, Notifications, Accounts, Permissions, Models, Watch, Publishing key, About (`ios/SettingsScreen.swift`) | The same sections, names and order on both: Your Mac (iPhone) or iPhone (Mac), Accounts, Models, Permissions, Notifications, Voice, Appearance, About; Mac-only pages after them. Platform: pages in the window on the Mac, as he has them; a pushed list on the iPhone. |
| 40 | First run | none | FirstLaunch: hello, talk, permissions, agents, models (`mac/FirstLaunch.swift:50`); copy says "I live in your menu bar" and "Screen Recording isn't asked" (`:146`), both no longer true | none: opens on Home, pairing only in Settings | onboarding.md. |
| 41 | The Obysphere | icon-strip entries, Members and Invited, Invite, Create, the sphere's settings, someone else's Oby, conversations with other Obys (`sangam/spheres.ts`, `sangam/SphereSettings.tsx:119-140`, `sangam/InviteModal.tsx`, `sangam/CreateSphereModal.tsx`) | none (`mac/App/ChatWindow.swift:6` has Home and Conversations) (A19) | none | His screens on both, per sphere: admin and member roles (whoever made it, plus whoever an admin makes one; "Make admin" in a member's ⋮ is the one addition), invites, joining, leaving. obid and Oby Cloud serve several spheres (onboarding.md, section 4). |
| 42 | Shared Knowledge | an admin connects a source once; every member's Oby uses it with the admin's sign-in; Who can use it, When Oby uses it, tools on or off (`sangam/knowledge.ts`, `sangam/KnowledgeView.tsx:55-90`) | none | none | Exactly as he designed, per sphere; underneath, the admin's secret stays with the admin's Oby or Oby Cloud, which runs members' lookups and returns only answers (AGENTS.md as decided). |
| 43 | Merging | stages end "Merged into dev" (`sangam/mock.ts:76`); Runner › Publishing says "Oby merges only into dev, once its review approves" (`sangam/SettingsView.tsx:167`) | obid never merges; its last stage reads "Ready for you to merge" (docs/runner-api.md, "what obid leaves out") | the same | Merging is learned workflow: obid merges as a remembered rule says, and the stage and result line read "Merged into dev, as you like"; until a repository has one, the safe default (open the pull request, ask before merging, never the default branch). The fixed sentence in Publishing becomes the remembered rule. |
| 44 | Memory | none | none (#378 was designed for the Swift engine) | none | "Can I remember that?" as a decision card, "as you like" on result lines, Settings › Memory on both apps, on his settings components (onboarding.md, section 5). |
| 45 | Remote access and the Oby account | Settings › Remote access: "Oby account", signed in as, "Reach this Mac from anywhere", hostname, Forget This Mac (`sangam/SettingsView.tsx:174-188`) | the same page without the Oby account group: Sign in with Apple on the web since 2026-10-20 (no email), and the Mac registers by its own key | none | His page is the Oby Cloud page (Sign in with Apple or email); beside it, Just this Mac's own routes: Tailscale found on the Mac, or a server address (onboarding.md, Mac 7b). |

## 3. Friction: what the app could know or decide instead

Every place a person has to know something, type something, or decide something today. Setup items have their full design in [onboarding.md](onboarding.md); this list is the reason for it.

### Knowing

| What you must know today | Where | Proposal |
|---|---|---|
| That obid exists, how to build it (Rust, `install/package.sh`) and install it (`install/install.sh`) | docs/install.md | Oby.app carries obid and starts it itself (onboarding.md, Mac 2). |
| That the Swift runner's login item ("This Mac") races obid for 7777 and 8810, and to turn it off in System Settings | docs/install.md, `mac/LoginItem.swift:24-40`, `mac/Settings.swift:111-118` | Oby.app registers obid, never `oby-runner`; it moves an existing install over once. |
| That obid reads accounts from `config.json`, not from the accounts the Mac app adds (`accounts.json`) | `Engine/Accounts.swift`, docs/install.md "You redo by hand" | One account store, obid's (the obid-accounts session's accounts API). |
| That `claudeKeychain` must be on when Claude Code keeps its login only in the Keychain, or every Claude job reads as signed out | `core/crates/obid/src/jobs.rs:4245-4300` | obid turns it on by itself on macOS when Claude Code's login is only in the Keychain, and Settings › Accounts says so in one line (the owner's decision of 2026-10-17 already allows it). |
| That private https clones need `gh auth setup-git` as well as `gh auth login` | `core/crates/obid/src/git.rs:23-33` | obid clones and fetches with gh's credential helper, as it already pushes (`core/crates/obid/src/publish.rs:483-502`), so your global git settings stay as they are (onboarding.md, Mac 5). |
| That pairing needs the gateway set in `config.json`, `tailscale serve`, and an invitation made with `curl` and the API token | docs/install.md (PR #638), `core/crates/obid/src/gateway.rs` | The gateway is on by default; the Mac shows a QR code; nothing else (onboarding.md, Mac 7 and iPhone 1). |
| That the iPhone needs Tailscale (its Settings › Runner footer) | `ios/SettingsScreen.swift` | Gone: the same network over Bonjour; away from home, the route picked at setup (your Tailscale, found by Oby; your server; or Oby Cloud). |
| That a device's publishing key registers only within 10 minutes of `touch home/pairing` | docs/runner-api.md `POST /v1/devices` | The key registers with the pairing itself: a paired device's token may register its own key once. |
| That pairing ends after 30 days | `core/crates/obid/src/gateway.rs` | A token renews while it's used; it ends only when revoked or unused for 30 days. |
| That the Watch needs a Cloudflare Access client ID and secret pasted on the iPhone | `ios/SettingsScreen.swift:59-87` | The Watch pairs through the iPhone's own pairing, with Face ID; no secret to paste. |
| That Screen Recording is needed for "Show Oby your screen" (FirstLaunch says it isn't) | `mac/FirstLaunch.swift:146`, `mac/Snapshot.swift:87-89` | Ask the first time it's used; fix the copy. |
| What "the island" and "the menu bar" are (copy from before the window) | `mac/Settings.swift:139`, FirstLaunch's hello | Fix the copy. |
| What "Integrations…" opens (it opens Runner) | `mac/App/Sidebar.swift:368-372` | Settings › Connectors, or drop it. |
| The difference between "This Mac" and "Remote" runners | Settings › Runner (`mac/Settings.swift:108-187`) | With obid in the app, This Mac is the only choice most people have; Remote moves under Advanced. |

### Typing

| What you type today | Proposal |
|---|---|
| `config.json` by hand: `repos` (owner/name, remote URL, default branch, `check`), accounts, `gateway`, `claudeKeychain` | A repository picker from your GitHub (onboarding.md, Mac 6); everything else is set by the app. |
| A repository's `check` command | obid finds it from the repository (`Package.swift` → `swift test`, `package.json` → `npm test`, `Cargo.toml` → `cargo test`, `go.mod` → `go test ./...`, `pyproject.toml` → `pytest`), shown on the row and editable later. |
| An account's name and "Paid by" before it exists | The first login of a tool is "Personal", paid by you; rename later. |
| Sign-in commands in Terminal (`claude auth login`, `codex login`) | The app runs the tool's own login and shows its page or code; Terminal only when a tool asks for a code pasted back (onboarding.md, Mac 4). |
| Installing a missing CLI (the Cursor install command copied from FirstLaunch) | "Get Cursor" opens the vendor's own installer or page; Oby never runs an installer silently. |
| The runner's address on the iPhone | Gone. |
| A six-digit code, when the camera would do | The QR code first; the code is the fallback. |
| An email and a code for Remote access, again every 90 days | Just this Mac needs no account at all; Oby Cloud signs in once with Apple or email, and the Mac's installation then keeps its own key (onboarding.md, "Remote access, by path"). |
| Secrets for a remote obid with `obid vault add` | Out of setup's scope; Settings › Vault on the Mac writes them for a local obid already. |

### Deciding

| What you decide today | Proposal |
|---|---|
| Which model each tool uses for routine and complex jobs, and the Lead's (FirstLaunch's Models step) | Good defaults, no step; Settings › Models to change them. |
| A permission mode out of five (Sandbox, Ask, Accept edits, Plan, Bypass) with no context | Default Sandbox for obid's jobs; the first time an agent asks, the decision card explains "Always allow" there. |
| Granting Accessibility, Microphone and Notifications in one batch on first launch | Each at the moment it's needed, after one line saying why (onboarding.md, "Asked later"). |
| Whether to keep the Mac awake, and System Settings' "Wake for network access" | On by default for a desktop Mac and for a laptop on power, with one line in Settings › iPhone. |
| Which account a task goes to | Already automatic (routing); keep it so. |
| Whether a second Cursor account is allowed (the Mac refuses it, `mac/Settings.swift:323-326`) | obid keeps Cursor logins apart (docs/cursor.md): allow it. |
| Whether to turn on Remote access before pairing | Pairing needs nothing first; how to reach the Mac away from home is the next screen, with what Oby found already picked (onboarding.md, Mac 7b). |
| When to ask for notifications | After the first task starts (row 16). |
