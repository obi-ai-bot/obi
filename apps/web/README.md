# Oby in a browser

Sangam's screens (`design/app`, #491) as a web app served by `obid`: Home, task pages, the
conversation with Oby and Settings, showing obid's real jobs, conversation and inbox. It is a client
of [docs/runner-api.md](../../docs/runner-api.md) like the Mac and iPhone apps, and the way to use
Oby with no Apple device (#492).

```bash
npm ci
npm run build       # into dist/, which obid serves at /app/
npm run typecheck
npm test            # vitest: the client, the event stream, jobs as tasks, what events own
```

## Opening it

obid serves `dist/` on its own address (`web` in its configuration, this folder's `dist/` unless
set): open `http://127.0.0.1:7777/app/` (or obid's `listen`) and paste the token from `api-token` in
obid's home. The page keeps it in this tab's session storage and sends it as
`Authorization: Bearer` on every call to obid, the event stream included; obid's API takes nothing
else. The sign-in also opens a random page session (a cookie for `/app` only) so the page's own
files stay behind the token; it opens nothing under `/v1` ("obid only: the web app" in
runner-api.md). A new tab asks for the token again; Settings › General signs the tab out.

`npm run dev` runs the same page with hot reload on port 5175 and passes `/v1` on to obid as it is
(`OBID_URL`, `http://127.0.0.1:7777` unless set): the page asks for the token there too, and the
dev server adds nothing, so it opens nothing to anyone without it.

```bash
npm run dev
```

## What's in it

From Sangam's renderer, with `tokens.css` and `app.css` as they were. The Electron window
(`window.app`: the traffic lights, full screen, the cursor feed) is gone: the page sends Oby its
own pointer instead, which `character/` follows once #499 lands (until then Oby watches the pointer
only over its own frame). Screens with no backend in obid yet stay hidden behind Settings ›
General › "Show screens still being built", and say so when shown: the Obysphere (#497) and its
knowledge (#495), Connectors (#498) and many conversations (#493). Nothing shows made-up data.

```
api.ts              the runner API's types and calls, each with the token: status, jobs, the inbox,
                    the conversation, plans, and the event stream, read as it comes (sseReader)
live.ts             what obid has, kept live: the events first, then the status, jobs, inbox and
                    conversation, the events that came meanwhile applied over them; and what the
                    page does (ask Oby, answer a decision, tell a job, stop, dismiss), where an
                    answer only adds jobs it didn't know: the events own a job's state
SignIn.tsx          the page asking for the token, when this tab holds none or obid refused it
tasks.ts            jobs (and the inbox's decisions that belong to no job) as Home's tasks: kind of
                    work, running / needs you / done, new, archived
chats.ts            the conversation with Oby, and where a job was started in it
preview.ts          the "Show screens still being built" setting
Home.tsx            the window: Oby's stage, the chips, the title bar and its trail
Sidebar.tsx         the side panel: the conversation and Home's tasks (its foot opens Archived),
                    Settings from the account picture; with the setting on, Conversations and the
                    Obysphere, empty
GroupView.tsx       one kind of work's cards, Running or Completed
TaskView.tsx        one task on its own page; TaskCard.tsx draws its card and its decision
ChatView.tsx        the conversation with Oby, or a task's own thread
SettingsView.tsx    Settings' pages: General (this browser's), Runner, Accounts and Models (obid's
                    status, read-only), Connectors (with the setting on, empty)
KnowledgeView.tsx   the Obysphere's knowledge (with the setting on, empty)
ArchiveView.tsx     done tasks that left Home, as a page
Composer.tsx        the message box (MessageEditor.tsx is its Lexical text, textTokens.ts what it
                    sets apart as you type) and the usage gauge, when obid reports usage
Oby.tsx             Oby's frame: character/oby.html, copied in by the build as dist/oby/
ObyFace.tsx, ObyFaceLive.tsx, StatusDot.tsx, Menu.tsx, TaskMenu.tsx, Formatted.tsx, brands.tsx,
useScrollThumb.ts   as in Sangam's design
web.css             the little the web app adds: how the page stands with obid, earlier messages
```
