# Oby app

The desktop app around Oby: Electron, with a React renderer built by Vite.

```bash
npm install     # on macOS this also builds the native window module
npm run dev     # the app, with hot reload
npm run web     # the renderer alone in a browser, on port 5175
npm run build   # into out/
npm start       # the built app
npm run typecheck
```

```
src/main/       the window (opens at 994×670, at least 420×520) and the cursor feed
src/preload/    window.app: the traffic lights' position, full screen, and the cursor feed
src/renderer/   the screens; tokens.css holds the shared look
native/         window-style: makes the window macOS's toolbar window type
build/          the app icon: icon.png, icon.icns, and make-icon.py that draws them
                (from oby-head.png: Oby's head, rising from the icon's bottom edge)
```

The renderer, in `src/renderer/src/`:

```
Home.tsx            the window: Oby's stage, the chips, the title bar and its trail
Sidebar.tsx         the side panel: Home's tasks (its foot opens Archived),
                    Conversations (yours with Oby: Pinned, Recent, each with
                    its menu), each Obysphere you're in (Knowledge, Invite
                    member, Members, Invited; its ⋮ opens its settings; + in
                    the icon strip makes another), Settings (from your
                    account picture)
GroupView.tsx       one kind of work's cards, Running or Completed
TaskView.tsx        one task on its own page; TaskCard.tsx draws its card
ChatView.tsx        a conversation: with Oby, with other people's Obys (the
                    Obysphere), or a task's own thread (one that came in from
                    GitHub, Slack…)
ObyView.tsx         someone else's Oby: your conversations with it
SettingsView.tsx    Settings' pages (as Wellington's Mac app has them, plus
                    Connectors), opened from your account menu; its page frame
                    and rows (SettingsPage, Group, Row, Switch, Select…) are
                    shared with the Obysphere's pages
SphereSettings.tsx  an Obysphere's settings: avatar, name, URL, members,
                    deleting or leaving it
KnowledgeView.tsx   an Obysphere's knowledge sources (Tetrix, MCP servers);
                    AddSourceModal.tsx connects another
ArchiveView.tsx     the archive: done tasks that left Home, as a page
InviteModal.tsx     inviting people into an Obysphere: by email, or a link
CreateSphereModal.tsx  making an Obysphere: name, URL, avatar, who to invite
EmailField.tsx      the field where addresses become tags (both modals above)
SphereTile.tsx      an Obysphere's picture: its image, a brand's mark, or a letter
Composer.tsx        the message box (its + panel, @ list and usage gauge);
                    MessageEditor.tsx is its Lexical text, and textTokens.ts
                    what it sets apart as you type
Formatted.tsx       a sent message's text, set as it was typed
Menu.tsx            the small ⋮ menu; TaskMenu.tsx is a task's, ConvoMenu.tsx a
                    conversation's
StatusDot.tsx       a task's state as one mark
Oby.tsx             Oby's frame; ObyFace.tsx its small icon and owners' pictures;
                    ObyFaceLive.tsx Oby's face in a conversation while it works
                    (2D, melting into dots)
brands.tsx          connector logos
useScrollThumb.ts   the Safari-like scroll thumb
chats.ts            your conversations with Oby (renamed, pinned, deleted), and
                    how Oby answers in the mock
tasks.ts, peers.ts  the tasks and the conversations with other Obys, as small stores
spheres.ts          the Obyspheres you're in, their members and invites
knowledge.ts        each Obysphere's knowledge sources
stream.ts           Oby's words coming in a word at a time
mock.ts             the demo data behind these stores, until the app talks to Oby's engine
tokens.css, app.css the shared look, and the rest of it
```

On macOS the window is the same type as Safari's (an empty, invisible
toolbar), so macOS draws its own macOS 26 corners and places the traffic
lights. Electron has no option for this yet (electron/electron#47514), so
`native/window-style` sets it, about 100 lines of Objective-C, and reports where
the lights are so the title bar lines up with them. Around full screen it takes
the toolbar off and puts it back, or leaving full screen would show dark
corners. Rebuild it with `npm run build:native` after an Electron upgrade.

Oby itself stays in `../oby`. In dev it's served at `/oby/`, and a build copies
`oby.html` and three.js into `out/renderer/oby/`. The main process sends the
cursor position 60 times a second while the window is visible, so Oby watches
it anywhere on screen. In a browser it follows the page's pointer instead.
