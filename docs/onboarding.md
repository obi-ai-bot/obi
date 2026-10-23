# Setting up Oby on a new Mac and iPhone

The owner's bar: the setup is so easy people believe Apple built it. Open the app on the Mac, and everything else is guided or automatic; on the iPhone, scan one code.

Oby is open source and self-hostable: anyone runs obid on their own Mac or server with no account. **Oby Cloud** is the paid option: remote access that just works, teams, and the Obysphere, the network between people's Obys (its protocol and server: the [`obi-ai-bot/obi-sphere`](https://github.com/obi-ai-bot/obi-sphere) repository; today's control plane: `cloud/control-plane`, docs/remote-access.md). So setup has two paths from its first screen, and neither needs an account to start Oby on the Mac.

This page is today's real setup, the design that replaces it, what each step needs built (local and cloud apart), and the order to build it in. The logic it sits on is [oby-ux.md](oby-ux.md); Sangam's design leads what the user sees, and AGENTS.md's rules are how it's built underneath.

- **The design** (Claude Design canvas, Mac and iPhone, every screen in dark and light, in Sangam's visual language from the "Oby" design system): https://claude.ai/artifact/GJvmg4g3CZHnqr1gBKJDSd
- **The design system**: https://claude.ai/artifact/3Y6y9KmLkjDALa4LexY3Sy

Both are private until shared from their Share menu.

Sizes: **S** under a day, **M** a few days, **L** a week or more. `file:line` references are on `dev` at dbf9857.

## 1. Today, from scratch

What a person does now to go from a new Mac and iPhone to a working Oby on obid. Every step is manual.

**On the Mac**

1. Install Xcode's command-line tools, git, GitHub's CLI (`gh`), and at least one agent CLI (`claude`; `codex`, `cursor-agent` if wanted). Nothing helps: FirstLaunch says "Not installed" or offers a Cursor install command to copy (`apps/mac/app/FirstLaunch.swift:307-344`).
2. `gh auth login`, and `gh auth setup-git` for private https clones: obid pushes with gh's credential helper (`core/crates/obid/src/publish.rs:483-502`) but clones with your global git settings (`core/crates/obid/src/git.rs:23-33`). Nothing says so.
3. Sign each CLI in: `claude auth login`, `codex login`.
4. Get obid: nothing is published on the download host yet (docs/install.md), so clone this repository, install Rust, `sh install/package.sh`, then `sh install/install.sh --archive build/obid/obid-macos-arm64.tar.gz`. That writes `~/Library/LaunchAgents/com.deskree.obid.plist` (`install/install.sh:488-521`), the API token, and a `config.json` with Claude Code, no repositories and no gateway (`install/install.sh:425-447`).
5. Edit `~/Library/Application Support/Oby/obid/config.json` by hand: `repos` (owner/name, remote, default branch, `check`), more accounts under `agents.*.accounts`, `"gateway": "127.0.0.1:8810"`, and `"claudeKeychain": true` when Claude Code keeps its login only in the Keychain (else every Claude job reads as signed out, `core/crates/obid/src/jobs.rs:4227-4300`). obid reads it once at start (`core/crates/obid/src/main.rs:121`): `launchctl kickstart -k gui/$(id -u)/com.deskree.obid`.
6. Install Oby.app and open it. FirstLaunch: hello, hold fn, permissions (Accessibility, Microphone, Notifications in one go), agents and accounts (which writes the app's own `accounts.json`, not obid's), models (`apps/mac/app/FirstLaunch.swift:50`).
7. Settings › Runner › This Mac. That also registers the Swift runner (`oby-runner`, bundled in the app, `apps/mac/app/LoginItem.swift:24-40`), which wants the same port 7777, and 8810 for its own gateway: turn it off in System Settings › General › Login Items.
8. Settings › Runner › "Keep my Mac available", and Energy Saver's "Wake for network access" (`apps/mac/app/Availability.swift`).

**Reaching it from the iPhone**

9. Either Tailscale on both devices, `tailscale serve --bg --https=8443 http://127.0.0.1:8810`, and an invitation made with `curl` against `POST /v1/pairing/invite` with the API token, pasted into the iPhone as JSON (docs/install.md, PR #638); the Mac's Pair a device won't make a QR code for a Tailscale address (`apps/mac/app/PairingView.swift:64-66`).
10. Or Settings › Remote access: "Reach this Mac from anywhere", which signs in with Apple or Google the first time (on the web; no email is kept) and registers the Mac by a key of its own (the control plane in `cloud/control-plane` must be deployed first, which is the owner's own Cloudflare setup, docs/remote-access.md), then Settings › Runner › Pair a device.

**On the iPhone**

11. Install the app. It opens on Home and talks to the owner's own tailnet address (`apps/shared/Runner.swift:928`). Settings › Your Mac › Scan QR code. "Enter code" can't find an obid Mac: it looks for `_oby._tcp` over Bonjour (`apps/ios/app/ConnectScreen.swift:255-278`), which obid doesn't advertise (`core/crates/obid/src/gateway.rs:13-14`).
12. Allow notifications when asked (on the first connection). With obid nothing is pushed: obid has no `/v1/notifications` or `/v1/activities`.
13. 30 days later the device token expires; the iPhone says "The runner only answers its owner's Tailscale login." (`apps/shared/Runner.swift:1386`) and the person pairs again.

## 2. The design

Principles:

- **Open the app; the rest follows.** Oby.app carries obid and starts it. Nothing to download, build, edit or restart.
- **Two paths, no account to start.** "Just this Mac" is everything local, with no account ever. "Sign in to Oby Cloud" adds reaching the Mac from anywhere with nothing to set up, teams, and Obyspheres. A self-hosted Oby moves to Cloud later without starting over (section 3, "Upgrading").
- **One decision per screen.** A screen asks one thing; anything Oby can find out, it finds out.
- **Skip what's safe to skip.** Every step but the welcome has Skip or Later, and everything skipped is one place away in Settings.
- **The system's own prompts, at the moment they're needed.** One line from Oby before each, saying why, then macOS's or iOS's prompt. Never a batch of permissions on first launch.
- **Each tool's own login.** Claude Code, Codex, Cursor and GitHub sign in through their own pages; Oby only learns that it worked. Logins and secrets never leave the Mac, on either path.
- **Sangam's language.** Near-black ground, white at low opacities, colour only for meaning, short first-person copy in sentence case, the one ink button. Light mirrors it.

### Mac, screen by screen

A window of its own over the main one (760 × 520, the Safari-style toolbar window the main window uses), dots for progress at the bottom left, Back and the primary button at the bottom right. Closing it at any point finishes setup with what's done; Settings has the rest.

| # | Screen | Copy | What happens |
|---|---|---|---|
| 1 | **Welcome** | "Hi, I'm Oby." / "I hand your coding work to the agents you already use, Claude Code, Codex and Cursor. They run on this Mac, with your own logins." / two choices: **Just this Mac** "Everything stays here. Your iPhone connects at home, or through your own Tailscale or server." and **Sign in to Oby Cloud** "Reach this Mac from anywhere with nothing to set up, and work with your team in an Obysphere." / "Either way, your code, logins and secrets stay on this Mac. You can sign in later without starting over." / **Continue** | The live character. Behind it, Oby has already started registering obid (screen 2), whichever path is picked. |
| 1b | **Sign in to Oby Cloud** (Cloud path only) | "Your iPhone reaches this Mac from anywhere, and your team's Obys find each other in your Obysphere." / **Continue with Apple**, **Continue with email** / "What stays on this Mac: your code, your agents' logins, your secrets, and the keys that pair your devices." / "What Oby Cloud carries: messages between your devices and your team's Obys, encrypted end to end so it can't read them." / **Set up this Mac first** | Signs the person in to Oby Cloud (section 3) and registers this Mac as one of their installations, with its own key. "Set up this Mac first" carries on as Just this Mac and keeps the Cloud offer in Settings. |
| 2 | **Getting Oby ready** | "Oby runs a small helper so your tasks keep going while its window is closed. Nothing to do here." Rows: Oby's engine "Running"; Agents on this Mac "2 found"; GitHub "Looking". Foot: "macOS may say Oby added a background item. Turn it off any time in System Settings › General › Login Items." / **Continue** | Registers obid with `SMAppService.agent`, makes obid's home and token, waits for `GET /v1/status` to say `"engine": "obid"`, then asks obid what's installed and signed in. No decision: Continue lights up when it's done. An existing install.sh setup is moved over (section 4). |
| 3 | **Your agents** | "Oby found these on your Mac. Each signs in with its own login, so Oby never sees your password." Rows: Claude Code "Signed in · Max", **Ready**; Codex "Installed, not signed in", **Sign in**; Cursor "Not on this Mac", **Get Cursor**. Foot: "One is enough to start. A second login of the same tool, like a work account, goes in Settings › Accounts." / **Continue** | One account per tool that's signed in, named "Personal", paid by you, added to obid. Continue is on once one tool is ready; with none, it says "Skip for now" and Oby can only talk until one is. |
| 4 | **Finish signing in to Codex** (a sheet over 3) | "Codex opened its sign-in page in your browser. Come back when it says you're done." / "Waiting for Codex" / **Cancel**, **Open the page again** / "Codex keeps its own login. Oby only learns that it worked." | obid runs the tool's own login for that account's folder and tells the app the page to open; the sheet closes when obid sees the account signed in. A tool that wants a code pasted back opens in Terminal instead, as today. |
| 5 | **Connect GitHub** | "So Oby can list your repositories and open a pull request when an agent's work passes its check. GitHub's own sign-in does it; Oby never holds the key." / the one-time code, "Copied. Paste it on the page that opens." / "Already signed in with GitHub's command-line tool? Oby uses that and skips this step." / **Skip**, **Open GitHub** | gh's own device sign-in; the login stays in gh's Keychain item. Skipped automatically when `gh auth status` is already good. Skipped by hand: Oby works, and the first finished task says it can't open a pull request until GitHub is connected. |
| 6 | **What should Oby work on?** | "Pick the repositories agents may change. Oby finds how each one is tested." / a search, then your repositories, most recently pushed first, each "Pushed today · tested with `swift test`" / "2 picked" / **Continue** | The list is `gh api user/repos` through obid. Picking one adds it to obid's repos with its remote, default branch and the check obid detected; the clone starts in the background. |
| 7 | **Oby on your iPhone** | "Point your iPhone's camera at this code. It gets Oby from the App Store if needed, and connects it to this Mac." / QR / "Waiting for your iPhone" / "At home it talks to this Mac over Wi-Fi, encrypted between the two." / "No camera nearby? In Oby on the iPhone, type 482 193." / **Later** | A pairing invitation on obid, its QR a universal link carrying the Mac's public key and every route it has (section 4). Moves on by itself when the iPhone pairs. On the Cloud path the iPhone can also sign in and confirm instead (iPhone 1c). |
| 7b | **Away from home** (Just this Mac only) | "Your iPhone is connected on this Wi-Fi. How should it reach this Mac from anywhere else?" / **Your Tailscale** "Found on this Mac: <name>.ts.net", **Ready** / **Your own server** "An https address that reaches this Mac" / **Oby Cloud** "Nothing to set up. Encrypted end to end: the relay can't read it." **Sign in** / **Only at home** "Change it any time in Settings › iPhone" / **Continue** | Tailscale found on the Mac is picked by itself: Oby runs `tailscale serve` for the gateway only with the user's OK on this screen, never `funnel`. Your own server: an address the iPhone tries away from home, the Mac's key still checked. Skipped on the Cloud path, where the relay is already on. |
| 8 | **Give Oby something to do** | "Pick one, or say anything. You'll see every step as it goes, and nothing leaves this Mac until its check passes." / "Find a small bug in obi and fix it" (a task) / "How is tetrix-ee organised?" (a conversation) / the message box / **Skip** | The two suggestions are made from the repositories picked: one task, one conversation, so the first minute shows both halves of Oby. |
| 9 | **The first task, live** | The conversation: your words, "On it. Claude Code has it in obi on Personal. I'll tell you if it needs you, and when there's a pull request to look at.", the task's card with its live step / "You can close this window. Oby keeps working and tells you when something needs you." | Setup is done. Notifications are asked for here, the first time this task could need you. |

### iPhone, screen by screen

| # | Screen | Copy | What happens |
|---|---|---|---|
| 1 | **Connect to your Mac** | "Open Oby on your Mac and point the camera at the code it shows." / the camera / "On this network": "Wellington's MacBook Pro", "Your Mac asks you to allow this iPhone" / **Type a code instead** | The first screen whenever the iPhone isn't paired; no default address. Scanning with the system Camera app works too: the code is a universal link that opens Oby on this screen with the invitation filled in. Picking a Mac found over Bonjour asks the Mac to allow it ("Allow Wellington's iPhone to use Oby?" on the Mac): the six-digit code without typing. |
| 1b | **Type the code** | "Your Mac shows six digits under its code. They work once, for two minutes." / six boxes / "Looking for Wellington's MacBook Pro on this network" / **Connect** | `POST /v1/pairing` with the code, found over Bonjour. |
| 1c | **Confirm on your Mac** (Oby Cloud) | "Oby Cloud · signed in as …" / "Wellington's MacBook Pro is asking whether to let this iPhone in. Check it shows the same numbers." / six matching digits / "Waiting for your Mac" / "The keys that pair your devices never pass through Oby Cloud. Matching numbers prove it's really your Mac on the other end." / **Scan the code instead** | Signed in to the same Oby Cloud account, the iPhone lists that account's Macs; picking one starts a key exchange through the relay, which both devices show as six digits (a short authentication string); the Mac's Allow finishes it. The relay carries only public keys and can't stand in the middle unnoticed. |
| 2 | **You're connected** | "Oby on this iPhone works with Wellington's MacBook Pro, at home and away." / "On this Wi-Fi · Connected"; "Away from home · Through your Tailscale" (or "Through Oby Cloud") / **Continue** | The device token and the Mac's key go in the Keychain; the publishing key registers with the same pairing. |
| 3 | **When something needs you** | "Oby tells you only when a task needs your answer, or ends badly. Never for progress: that stays on the Lock Screen while it runs." / an example: "Run swift test?" with Allow, Always allow, Deny / "Answer right from the notification. iOS asks next." / **Turn on notifications**, **Not now** | One line, then iOS's own prompt. Not now: asked again the first time something said on the iPhone starts a task. |
| 4 | **Home** | Oby, "1 running task", the chips, Running and Recent, "What do you want me to work on, Wellington?" | The same Home as every day (docs/ios-design.md). |

### Asked later, when it's needed

| What | The moment | Oby's line first | Then |
|---|---|---|---|
| Microphone (Mac) | The first click on the window's voice button (Sangam's) | "Oby listens until you click again, up to a minute, and your words stay a draft until you send them. macOS asks about the microphone next." | macOS's prompt. |
| Accessibility (the fn key, from any app) | Turning on "Hold fn to talk" in Settings › Voice, or the first fn press Oby can't hear yet | "To hear fn from any app, Oby needs Accessibility. It listens only while you hold it." | macOS's prompt; Oby checks for it every 2 s (macOS has no callback), as `FirstLaunch` does today. |
| Microphone and speech (iPhone) | The first tap on the mic | "Oby listens until you tap Stop, up to a minute, and your words stay a draft until you send them." | iOS's prompts, microphone then speech. |
| Screen Recording | The first "Show Oby your screen" | "To see your screen, macOS needs to let Oby record it. It looks only when you ask." | macOS's prompt; the copy in FirstLaunch that says it isn't asked goes. |
| Notifications (Mac) | The first task you start | "Oby tells you when a task needs you or ends badly. Nothing else." | macOS's prompt. |
| Face ID or Touch ID | The first time you publish by hand | (the action itself is the reason: "Publish 2 commits to obi") | the system's prompt. |
| Keep the Mac available | Pairing an iPhone, on a desktop Mac or a laptop on power | none: on by default, shown in Settings › iPhone | — |
| "Can I remember that?" | The first time you say or do something that sounds like a rule (section 5) | the question itself | your yes, or not. |

### Errors and recovery

Each one is one line where you are (Home, the conversation, the task), in Sangam's notice style, with at most two buttons. The same words on both apps.

| Situation | Where it shows | Copy | Action | Needs |
|---|---|---|---|---|
| An agent isn't installed (removed, or never there) | Mac: Home, and on each task that waits for it. iPhone: the task | "Cursor isn't on this Mac any more" / "The task on Cursor waits. Move it to Claude Code, or put Cursor back." | **Move to Claude Code**, **Get Cursor** | `GET /v1/agents` with `installed`; Move to… exists (`POST /v1/jobs/{id}/move`) |
| A login expired | Mac: Home and the waiting tasks. iPhone: the same, without the button | "Codex · Personal signed out" / "Its login expired. Two tasks wait for it; the rest go to Claude Code." / iPhone: "Oby on your Mac has the button; it signs in there, with Codex's own login." | Mac: **Sign in to Codex**, **Later** | obid noticing the tool's own "not logged in" (it already fails the job saying so) and an `accounts` event; the sign-in endpoint |
| No internet on the Mac | Mac: Home (quiet dot) | "No internet" / "Agents pause until it's back, then carry on. Nothing is lost." | none | obid's jobs retrying on network errors instead of failing |
| obid stopped | Mac: Home | "Starting Oby's engine again" / "It stopped unexpectedly. Tasks pick up where they were." | none; after three tries: **Restart Oby's engine** | launchd's KeepAlive; the app noticing `GET /v1/status` failing |
| The Mac is asleep | iPhone: Home and every page | "Your Mac is asleep" / "Since 11:02 PM. Oby picks up when it wakes; what you send waits here until then." | none | the Mac saying it's going to sleep before it does (`NSWorkspace.willSleepNotification`): to the relay on Cloud; on Just this Mac the iPhone shows "Can't reach your Mac" unless it heard it on the LAN |
| The Mac can't be reached | iPhone | "Can't reach your Mac" / "Last seen 9:41 AM. Check it's on and online." | **Try again** | — |
| No internet on the iPhone | iPhone | "No internet on this iPhone" / "Showing what Oby knew at 9:41 AM." | none | `NWPathMonitor` |
| The iPhone was removed (revoked, or unused 30 days) | iPhone: replaces Home | "This iPhone was removed from your Mac" / "Scan the code in Oby on your Mac to connect again." | **Scan the code** | the gateway's 401 told apart from others |
| GitHub not connected, a task finished | Mac and iPhone: the task | "Done, but not published" / "Connect GitHub so Oby can open the pull request." | Mac: **Connect GitHub** | `GET /v1/status` `github` |

## 3. Remote access, by path

**Recommendation: on Just this Mac, the local network plus the user's own Tailscale or server; on Oby Cloud, Oby's relay, end-to-end encrypted.** Nothing found argues otherwise: Tailscale is already how the owner reaches the Mac, it is end-to-end by construction and needs no Deskree service, and the relay is the only way to make remote access invisible for people who'd rather pay than set anything up.

| | Just this Mac | Oby Cloud |
|---|---|---|
| At home | Bonjour finds the Mac; the iPhone talks to obid's gateway on the LAN, sealed with the pairing keys | the same |
| Away | the user's Tailscale (`tailscale serve` for the gateway only, never `funnel`), or their own server's https address | Oby's relay: a Cloudflare Tunnel per installation, outbound from the Mac (`cloudflared` is already bundled), to an opaque hostname |
| What the user does | Install Tailscale themselves, or bring a server; Oby finds Tailscale and offers it (Mac 7b) | Nothing |
| Who can read the traffic | nobody but the two devices | nobody but the two devices: the relay forwards sealed messages it can't open |
| Notifications with the app closed | none from obid itself (no Deskree key on a self-hosted Mac); the iPhone checks in when it can (background refresh) and the Live Activity is updated locally | through the relay: obid hands it a sealed payload and the iPhone's push token; it sends a `mutable-content` push; the iPhone's notification service extension opens it with the pairing key |
| Wakes a sleeping Mac | at home, only through a Bonjour Sleep Proxy (an Apple TV or HomePod) and "Wake for network access" | no |

**End-to-end, on both paths.** The QR code (or the matching-digits exchange, iPhone 1c) gives each device the other's public key; the keys never leave the devices. Every request, answer and event-stream frame between the iPhone and obid is sealed between those keys (HPKE, or Noise IK), so the LAN, the user's server and Oby's relay see only ciphertext, and a stolen device token is useless without the device's key (each request is also signed by the iPhone's Secure Enclave key, the one it already makes for publishing). This is #287, and it comes before the relay is on for anyone. A Live Activity's content can't be decrypted on the way (iOS renders it directly), so through the relay it carries only counts and stages, never titles or paths.

**Upgrading without starting over.** A self-hosted Oby signs in to Oby Cloud from Settings at any time: the Mac registers as an installation with the key it already has, its paired iPhones keep their pairing and simply gain the relay as one more route (the Mac sends it to them over the sealed channel), and everything obid keeps (jobs, conversations, accounts, repositories, memory) stays where it is, on the Mac. Signing out removes the relay route and nothing else.

**Against AGENTS.md's rules:**

| Rule | How it's kept |
|---|---|
| Logins and secrets never leave the Mac | Every sign-in happens on the Mac, by the tool itself; the vault stays in its Keychain; the relay never sees a login, a secret or a pairing key. |
| Everything outgoing is scanned for secrets | The gateway already passes only allowlisted routes, with vault secrets, `session` ids and home paths taken out (docs/runner-api.md, "obid only: the gateway"); sealing happens after that. |
| Text from other people is data | Unchanged; the Obysphere carries typed actions only (`obi-sphere`'s design rules). |
| No telemetry unless the user turns it on | Just this Mac sends nothing to Deskree. Oby Cloud keeps the account, its installations and endpoints, and hashes; never content, never logs of content. |

## 4. Oby Cloud and the Obysphere

An Obysphere is a team or a community ("Deskree"), at `<name>.obysphere.com` (Sangam's `spheres.ts`). Its server is `obi-sphere`'s: directory, policy, store-and-forward relay, signed audit and invitations, self-hostable, with Deskree running the hosted one for Oby Cloud. Obyspheres are part of Oby Cloud: making or joining one signs you in if you haven't.

- **Roles, per sphere.** Admin and member. Whoever creates a sphere is its admin, and admins make other members admins (a member's ⋮: Make admin, Open their Oby, Remove). One person can be admin of one sphere and a member of another. Admins invite (emails, an invite link, optionally anyone with an address at the org's domain), cancel invites, remove members, rename the sphere, change its URL (which ends old invite links), connect Knowledge, and delete it; members see all of that and can leave. (Sangam's `SphereSettings.tsx` shows Admin, Member and Invited; Make admin is the addition.)
- **Joining.** An invite opens "Join Deskree": who invited you, how many are in it, what joining means ("Deskree's Obys can ask yours for a review or a question. You decide what it answers."), its Knowledge, and **Join Deskree**.
- **Today, on Deskree's Sphere** (https://obysphere.deskree.com, until `<name>.obysphere.com`; anyone else runs their own, obi-ai-bot/obi-sphere `docs/run-your-own.md`): the server is `OBY_SPHERE_URL` in `apps/config/Signing.xcconfig`, or Settings › Obysphere › Server on each Mac. The owner key is Oby.app's, in the login Keychain (`com.deskree.oby.owner`, this Mac only); it signs the Obi's card, the 30-day delegation and the admin's own assertions, and obid never holds it. **Creating** is the + in the icon strip (Sangam's CreateSphereModal, `apps/mac/app/CreateSphere.swift`): a name, its id, a logo (kept on this Mac only: the Sphere keeps no images yet), people to invite, and "Anyone with @domain can join", offered for a work address (GitHub's primary email, else git's). Create uses the operator token when this Mac has it (Keychain `obi-sphere-operator-token`, which the server's deploy script puts there), else signs the owner in with Google: the server lets people from its `CREATOR_WORKSPACES` create (deskree.com on Deskree's). It lets everyone ask everyone for reviews and questions, joins this Oby, makes the team link (for anyone at the domain, each one signing in with Google so the Sphere checks their Workspace, 30 days; kept in the Keychain so Settings copies it again), and opens a message to the people invited in Mail, with a link for that many people for 7 days, for the owner to send. A link keeps its secret after the `#`; opened in a browser it lands on the server's `/join` page, which says to paste it in Settings › Obysphere. There the other person sees "Join Deskree" with the server it points to, its name and member count as the Sphere says them (a link to any server but the one Oby knows warns and asks them to confirm they trust it), signs in with Google first when it's for one Workspace, and joins. The app sends the owner's signatures only over https to a public name, never to this Mac, its network or the tailnet, and follows no redirect. Then Ask for a review sends one of your open pull requests to another Oby, and what others ask waits on the same page. Not yet: renewing the delegation before its 30 days end, and the same person on a second Mac (the Sphere binds one owner key per owner).
- **Knowledge, per sphere.** An admin connects a source once (Tetrix, or any MCP server) for that sphere only; every member's Oby uses it exactly as Sangam designed (Who can use it: Everyone or Admins only; When Oby uses it: Automatically or Ask first; its tools on or off, admin tools never). The admin's sign-in stays where it was connected: in the admin's Oby, or in Oby Cloud. Members' lookups go there, and only the answer comes back; the secret never reaches a member's Mac, Oby or agent. A source held by an admin's Oby works while that Mac is reachable; one held by Oby Cloud always does.
- **Another sphere is another world.** Members, Knowledge and policy never cross from one sphere to another.

## 5. Learned workflow: memory

How a person or a repository likes work done (merge into dev, never touch main, rebase first, who reviews, which tool reviews) isn't a product rule. Oby learns it, per person and per repository, the way Claude Code keeps memory (#378 has the storage design).

1. **It notices.** You say it ("merge it into dev once the check passes, never main"), or you do it twice (you rebased before opening the pull request).
2. **It asks.** A card under its words: kind "Remember?", "Can I remember that?", the rule in one sentence and where it applies ("For obi: merge into dev once the check passes, never main. Next time I'll just do it, and say so."), **Remember**, **Only this time**, Later. Nothing is saved without Remember.
3. **It follows it, and says so.** The task's result line reads "Merged into dev, as you like · obi#671 · Took 18m", with "From your memory" opening the memory.
4. **You see and change it.** Settings › Memory: "Learn from what I say and do" (on), then one group per repository and "About you", each memory with where it came from ("You said so · Oct 18 · used 3 times"), Edit and Delete in its ⋮.
5. **A head start, when you ask.** Settings › Memory, "Find what I keep repeating": Oby reads what you said in your conversations and what reviewers wrote on each repository's recent merged pull requests, leaves out anything that looks like a secret, and suggests what it found in two places or more, each a "Can I remember that?" with the quotes and pull requests it came from, **Remember** or **Not this**. Reviewers' words are data: they only ever become a suggestion, and only your Remember saves one (docs/runner-api.md, "obid only: memory").
6. **Until it has learned a repository, the safe default.** It opens the pull request, asks before any merge ("Ready to merge? … I don't know how tetrix-ee merges yet, so I left it open. main is untouched."), and never touches the default branch on its own.

What stays fixed whatever is remembered: AGENTS.md's safety rules that aren't workflow choices (secrets and logins, the secret scan before anything goes out, outside text as data, the microphone). A memory can never widen those, and text from agents or other people can only be proposed as a memory through the same "Can I remember that?", never saved by itself.

## 6. What each step needs

What exists today, what must be built, and where. Local work (obid, the Mac and iPhone apps) is apart from Oby Cloud's.

### Local: obid, Mac, iPhone

| Step | Exists today | To build | Where | Size |
|---|---|---|---|---|
| Mac 2: obid in the app | install.sh's token and readiness poll (`install/install.sh:405-418`, `:530-541`); the `SMAppService` wrapper (`apps/mac/app/LoginItem.swift`); the app reads obid's token (`Engine/LocalRunner.swift:65-90`); the build phase pattern of `cloudflared` (`apps/mac/app/Tools/bundle-cloudflared.sh`) | A build phase that builds obid (arm64 and x86_64, `lipo`, signed with the hardened runtime) into `Contents/Helpers/obid`, with `Contents/Library/LaunchAgents/com.deskree.obid.plist`; register it with `SMAppService.agent`; make obid's home and token on first run; obid updates with the app (Sparkle), which settles #456 | Mac, obid packaging | L |
| Mac 2: moving an existing setup over | — | If `~/Library/LaunchAgents/com.deskree.obid.plist` (install.sh) exists: keep its home and `config.json`, boot it out and remove its plist, register the bundled one under the same label; stop registering `oby-runner` for This Mac and unregister it | Mac | M |
| Mac 2: the gateway on by default | `gateway` in `config.json` (`core/crates/obid/src/config.rs:385-391`) | Default `127.0.0.1:8810` on macOS when left out | obid | S |
| Mac 3: what's installed and signed in | PATH from the login shell (`core/crates/obid/src/process.rs:103-150`); `signedIn` per account (`core/crates/obid/src/api.rs:476`, `:573`); the Mac's own detection (`apps/mac/app/Setup.swift:128-160`) | `GET /v1/agents`: each tool's path, version, and the accounts' `signedIn`; obid turns `claudeKeychain` on by itself on macOS when Claude Code's login is only in the Keychain | obid | S |
| Mac 3: adding the first account | The Mac's own store (`Engine/Accounts.swift`), which obid doesn't read | obid's accounts API (`POST`/`PATCH`/`DELETE /v1/accounts`, `payer`): **being built by the obid-accounts session** (docs/mac-design.md A2); then the Agents step calls it | obid, Mac | (A2) |
| Mac 4: signing in | Terminal `.command` scripts (`apps/mac/app/Settings.swift:801-807`, `Engine/Accounts.swift:487-518`); the sign-in command endpoint, **being built by the obid-accounts session** (A3) | `POST /v1/accounts/{id}/sign-in`: obid runs the tool's own login for that account's folder and reports, as events, only what the tool shows the person (the page to open, a device code) and when it's signed in; Terminal stays for a tool that wants a code pasted back | obid, Mac | M |
| Mac 4: installing a missing tool | The Cursor install command (`apps/mac/app/FirstLaunch.swift:307`, `:339-344`) | "Get …" opens the vendor's own page or installer in Terminal, never silently | Mac | S |
| Mac 5: GitHub | obid uses `gh` with the owner's login (`core/crates/obid/src/github.rs:1-23`); the Connectors row (`apps/mac/app/Connectors.swift:205-222`) | Bundle a pinned, signed `gh` like `cloudflared`; drive its device sign-in (`gh auth login --web`), showing its one-time code; `gh auth status` in `GET /v1/status` (#517); obid clones and fetches with gh's credential helper as it pushes (`core/crates/obid/src/publish.rs:483-502`), so no `gh auth setup-git` | Mac, obid | M |
| Mac 6: repositories | `repos` in `config.json`, read once at start | `GET /v1/github/repos` (`gh api user/repos --paginate`, loopback only); `POST`/`DELETE /v1/repos` that write obid's settings, start the clone and detect the check (`Package.swift`, `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, a `test` target in a `Makefile`); docs/runner-api.md in the same pull request | obid | M |
| Mac 6: the picker | — | The screen, on obid's API | Mac | S |
| Mac 7 and iPhone 1: pairing with no prerequisite | Invitations (`core/crates/obid/src/gateway.rs:209-235`); the QR (`apps/mac/app/PairingView.swift:113-136`); the iPhone's scanner, envelope check and token store (`apps/ios/app/QRScanner.swift`, `apps/ios/app/ConnectScreen.swift:187-220`) | The QR carries the Mac's public key and every route (LAN, `ts.net`, a server URL, the relay when signed in); no Remote-access prerequisite; the QR is a universal link (the invitation in its fragment, so it never reaches a server) with its `apple-app-site-association` | Mac, iPhone, a static page | M |
| Mac 7b: the user's own route | `MacLink` accepts `*.ts.net:port` (`apps/shared/RemoteRoute.swift:20-24`) | Find Tailscale on the Mac and its name; run `tailscale serve --bg --https=8443 http://127.0.0.1:8810` with the user's OK (never `funnel`); a server URL field; Settings › iPhone to change it | Mac | S |
| iPhone 1: finding the Mac | The iPhone browses `_oby._tcp` (`apps/ios/app/ConnectScreen.swift:255-388`); the Swift runner's advertiser (`Runner/Bonjour.swift`) | obid's gateway reachable on the local network and advertised as `_oby._tcp` under the Mac's name: the Mac app forwards a LAN port to `127.0.0.1:8810` and advertises it, so obid stays on loopback | Mac | M |
| iPhone 1: "Allow this iPhone?" on the Mac | — | A pairing request from a Bonjour-found iPhone shows on the Mac (Allow, Don't Allow) and pairs it as the code would | obid, Mac, iPhone | M |
| iPhone 1: Connect as the first screen | ConnectScreen in Settings | Connect as the first run when unpaired; drop `Runner.defaultURL` and Settings › Runner's address field and Tailscale footer | iPhone | S |
| iPhone 2: the publishing key with the pairing | `POST /v1/devices` behind `touch home/pairing` (`core/crates/obid/src/devices.rs:113-123`) | A paired device's token may register its own key once | obid | S |
| Pairing that doesn't lapse | 30-day tokens (`core/crates/obid/src/gateway.rs:238-288`) | Renew on use; end only when revoked or unused for 30 days; the iPhone keeps `expiresAt` and tells a gateway 401 apart ("This iPhone was removed…") | obid, iPhone | S |
| End-to-end encryption (#287) | — | Keys from pairing; sealed requests, answers and event frames through the gateway on every route; the device-key signature on each request | obid, Mac, iPhone | L |
| iPhone 3: asking at the right time | `Notifications.ask()` on connection (`apps/ios/app/Phone.swift:427-428`) | The screen, and asking after the first task otherwise | iPhone | S |
| Mac 8 and 9: the first task | `POST /v1/plans` | Two suggestions made from the picked repositories; ask for notifications when the first task starts | Mac | S |
| The setup window | FirstLaunch (`apps/mac/app/FirstLaunch.swift`) | Replace its steps with the screens above on Sangam's components (docs/mac-design.md B1); drop the Models and Permissions steps; fix "menu bar" and "Screen Recording" copy | Mac | M |
| Asked later | Permission rows (`apps/mac/app/Setup.swift:9-101`) | The one-line explainers before each system prompt, at the moments above; the window's voice button listening on a click (AGENTS.md, as decided) | Mac, iPhone | S |
| Errors and recovery | Mac offline banner (`apps/mac/app/App/RunnerOfflineNotice.swift`), iPhone offline line (`apps/ios/app/Phone.swift:238-242`) | One notice view in `apps/shared` and the states in the table above | Mac, iPhone | M |
| Keep the Mac available | `MacAvailability` (`apps/mac/app/Availability.swift:77-100`), app-side only | On by default on a desktop Mac and on power; obid itself holds the assertion while jobs run, so it holds with the app closed | Mac, obid | S |
| Memory: storage | obid keeps them, lists and deletes them (#378, first part; docs/runner-api.md, "obid only: memory") | obid keeps memories per person and per repository in its home (`home/memory/user/`, `home/memory/repos/<owner>/<name>/`), each a small file with where it came from and how often it was used; nothing saved without the user's yes | obid | M |
| Memory: a head start | — | "Find what I keep repeating" in Settings › Memory: the owner's own words and the reviews on merged pull requests, scanned, quoted to the brain, kept only when quoted word for word in two places, each saved only on Remember (#378, first part) | obid, Mac | M |
| Memory: reading it | — | The conversation harness and the brain get the person's and the repository's memories in their briefing (quoted, short, capped); a job's agent gets the repository's as quoted context; publishing reads the merge rule (until one exists, the safe default: open the PR, ask before any merge, never the default branch) | obid | M |
| Memory: the API | — | `GET /v1/memory`, `PATCH`/`DELETE /v1/memory/{id}`, a `memory` inbox kind for "Can I remember that?" answered like any decision, a `memory` event; on the gateway's allowlist; docs/runner-api.md with it | obid | M |
| Memory: merging when learned | obid never merges (docs/runner-api.md) | Merge a pull request through `gh` when a remembered rule says so and its check passed, the result line saying "as you like"; never the default branch without a rule naming it | obid | M |
| Memory: the screens | — | The "Remember?" card (the decision card), "as you like" on result lines, Settings › Memory on both apps | Mac, iPhone | M |

### Oby Cloud

| Piece | Exists today | To build | Size |
|---|---|---|---|
| **The relay** | `cloud/control-plane`: Sign in with Apple on the web as the gate (`sub` only), installations registered and signed by the Mac's P-256 key (Secure Enclave when there is one), per-account limits with per-network backstops, unconnected tunnels reclaimed and a 30-day idle sweep, one Cloudflare Tunnel per installation to the gateway (docs/remote-access.md); `cloudflared` bundled and `RemoteAccess.swift` on the Mac; not deployed for others | Deploy and run it as Deskree's; the iPhone's routes and the matching-digits pairing through it (iPhone 1c); the push relay (sealed payloads, Deskree's APNs key, the iPhone's notification service extension); the Mac's "going to sleep" notice | L |
| **Accounts and billing** | Apple Accounts by `sub`, for remote access only (2026-10-20): no email, no profile | Sign in with Apple and email (#282); the subscription (App Store in-app purchase on the apps, or a web checkout), entitlements the apps and the relay check; Settings › Oby Cloud (plan, devices, sign out) | L |
| **Teams** | — | An organization on the account: people, seats, roles for billing; the bridge to an Obysphere's members | M |
| **The Obysphere** | `obi-sphere`: the Obi-to-Obi protocol draft and a server outline (directory, policy, store-and-forward relay, signed audit, invitations), pre-alpha; obid's one Sphere, its card and exchanges (docs/runner-api.md, "obid only: Sphere membership" and after) | Several spheres per person; roles (admin, member, Make admin), invites (emails, link, domain), joining, leaving, deleting; Knowledge per sphere with the admin's secret held by the admin's Oby or by Oby Cloud, which runs members' lookups and returns only answers; hosted at `<name>.obysphere.com`; the apps' sphere screens (Sangam's) | L |

### The build list by size

- **Local, S:** gateway on by default · `GET /v1/agents` and `claudeKeychain` by itself · "Get …" for a missing tool · the repository picker screen · the user's own route (Tailscale found, a server URL) · Connect as the iPhone's first run · the publishing key with the pairing · pairing that renews, and a clear 401 · notifications asked at the right time · the first-task suggestions · the explainers before system prompts · keep-awake by default, held by obid.
- **Local, M:** moving an install.sh setup over and retiring `oby-runner` · signing in with each tool's own login without Terminal · GitHub through a bundled `gh` · the repositories API with check detection · pairing with no prerequisite, every route in the QR, a universal link · Bonjour and a LAN path for obid's gateway · "Allow this iPhone?" on the Mac · the new setup window · errors and recovery · memory storage · memory in the briefings · the memory API · merging when learned · the memory screens.
- **Local, L:** obid inside Oby.app with `SMAppService` · end-to-end encryption (#287).
- **Oby Cloud:** the relay (L) · accounts and billing (L) · teams (M) · the Obysphere (L).
- **Being built elsewhere:** obid's accounts API and its sign-in command (the obid-accounts session, docs/mac-design.md A2, A3); Settings' components, Settings in the window and one account list (the mac-settings session, B1, A1, C1).

## 7. Order of work

Small pull requests into `dev`, each usable on its own: first the ones that remove a terminal step from Just this Mac, then memory. Items 19–22 (Oby Cloud) are for the future (section 8).

1. **fix(ios): Connect is the first screen.** No default runner address; Settings' Runner section and Tailscale footer go; a gateway 401 says the iPhone was removed; keep `expiresAt`. (S)
2. **fix(mac): FirstLaunch's copy.** "Menu bar", "Screen Recording isn't asked". (S)
3. **feat(obid): the gateway on by default, and `claudeKeychain` by itself on macOS.** (S)
4. **feat(obid): `GET /v1/agents`.** docs/runner-api.md with it. (S)
5. **feat(obid): pairing renews, and the publishing key registers with it.** (S)
6. **feat(mac): pairing with no prerequisite; your own route.** Every route in the QR, the Mac's key in it, Tailscale found and offered, a server URL. (S each)
7. **feat(mac): Bonjour and a LAN path for obid's gateway.** (M)
8. **feat(obid): repositories API with check detection, and gh's credential helper for clones.** (M)
9. **feat(mac): obid inside Oby.app.** (L)
10. **feat(mac): move an install.sh setup over, retire `oby-runner` from This Mac.** (M)
11. **feat(mac): the new setup window,** both paths' first screen, using 3–10 and the obid-accounts session's API; bundled `gh` and its device sign-in. (M each, two PRs)
12. **feat(ios): the setup screens,** the universal link and its association file. (M)
13. **feat(obid, mac): signing in without Terminal.** (M, after the obid-accounts session's sign-in command)
14. **feat: errors and recovery.** (M)
15. **feat(obid, mac, ios): end-to-end encryption (#287).** (L)
16. **feat(obid): memory storage, the API and the briefings** (#378). (M each)
17. **feat(mac, ios): "Can I remember that?", "as you like", Settings › Memory.** (M)
18. **feat(obid): merging when a remembered rule says so.** (M)
19. **feat(cloud): the relay as Deskree's service,** installations by key, the iPhone through it, matching digits. Only after 15. (L)
20. **feat(cloud): accounts and billing,** Sign in with Apple, the subscription, Settings › Oby Cloud. (L)
21. **feat(cloud, obid, ios): pushes through the relay.** (part of the relay's L)
22. **feat(cloud, apps): the Obysphere,** on `obi-sphere`'s server: several spheres, roles, invites, Knowledge per sphere held by its admin. (L), with **teams** (M) for billing.

## 8. Decided

The owner's decisions of 2026-10-18, besides the paths, remote access per path, Sangam's lead, follow-up tasks, the pointer, the voice button, Knowledge per sphere and learned workflow:

1. **GitHub:** Oby.app bundles a pinned, signed `gh` and drives its own device sign-in; nobody installs `gh` to use Oby.
2. **`claudeKeychain`:** obid turns it on by itself on macOS when Claude Code's login is only in the Keychain, and Settings › Accounts says so.
3. **The Swift runner:** once obid is bundled, Oby.app registers obid and no longer registers `oby-runner`; an existing install.sh setup is moved over.
4. **Merge rules:** AGENTS.md keeps only the safety rules; how this repository merges is its remembered workflow, and every other repository starts on the safe default.

5. **Oby Cloud is for the future.** Build Just this Mac first: everything in section 6's local table. Oby Cloud's relay, accounts and billing, teams and the Obysphere wait, and so does how it bills (the App Store or a web checkout). The setup's first screen offers only Just this Mac until then.
