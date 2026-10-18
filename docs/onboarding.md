# Setting up Oby on a new Mac and iPhone

The owner's bar: the setup is so easy people believe Apple built it. Open the app on the Mac, and everything else is guided or automatic; on the iPhone, scan one code. This page is today's real setup, the design that replaces it, what each step needs built, and the order to build it in. The logic it sits on is [oby-ux.md](oby-ux.md); the rules it keeps are AGENTS.md's.

- **The design** (Claude Design canvas, Mac and iPhone, every screen in dark and light, in Sangam's visual language from the "Oby" design system): https://claude.ai/artifact/GJvmg4g3CZHnqr1gBKJDSd
- **The design system**: https://claude.ai/artifact/3Y6y9KmLkjDALa4LexY3Sy

Both are private until shared from their Share menu.

Sizes: **S** under a day, **M** a few days, **L** a week or more. `file:line` references are on `dev` at 9545d1c.

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
10. Or Settings › Remote access: an email, a six-digit code, "Reach this Mac from anywhere" (the control plane in `cloud/control-plane` must be deployed first, which is the owner's own Cloudflare setup, docs/remote-access.md), then Settings › Runner › Pair a device.

**On the iPhone**

11. Install the app. It opens on Home and talks to the owner's own tailnet address (`apps/shared/Runner.swift:928`). Settings › Your Mac › Scan QR code. "Enter code" can't find an obid Mac: it looks for `_oby._tcp` over Bonjour (`apps/ios/app/ConnectScreen.swift:255-278`), which obid doesn't advertise (`core/crates/obid/src/gateway.rs:13-14`).
12. Allow notifications when asked (on the first connection). With obid nothing is pushed: obid has no `/v1/notifications` or `/v1/activities`.
13. 30 days later the device token expires; the iPhone says "The runner only answers its owner's Tailscale login." (`apps/shared/Runner.swift:1386`) and the person pairs again.

## 2. The design

Principles:

- **Open the app; the rest follows.** Oby.app carries obid and starts it. Nothing to download, build, edit or restart.
- **One decision per screen.** A screen asks one thing; anything Oby can find out, it finds out.
- **Skip what's safe to skip.** Every step but the welcome has Skip or Later, and everything skipped is one place away in Settings.
- **The system's own prompts, at the moment they're needed.** One line from Oby before each, saying why, then macOS's or iOS's prompt. Never a batch of permissions on first launch.
- **Each tool's own login.** Claude Code, Codex, Cursor and GitHub sign in through their own pages; Oby only learns that it worked (AGENTS.md).
- **Sangam's language.** Near-black ground, white at low opacities, colour only for meaning, short first-person copy in sentence case, the one ink button. Light is the iPhone addition, mirrored on the Mac.

### Mac, screen by screen

A window of its own over the main one (760 × 520, the Safari-style toolbar window the main window uses), dots for progress at the bottom left, Back and the primary button at the bottom right. Closing it at any point finishes setup with what's done; Settings has the rest.

| # | Screen | Copy | What happens |
|---|---|---|---|
| 1 | **Welcome** | "Hi, I'm Oby." / "I hand your coding work to the agents you already use, Claude Code, Codex and Cursor. They run on this Mac, with your own logins." / "About two minutes. You can skip anything and come back to it." / **Get started** | The live character. Behind it, Oby has already started registering obid (screen 2). |
| 2 | **Getting Oby ready** | "Oby runs a small helper so your tasks keep going while its window is closed. Nothing to do here." Rows: Oby's engine "Running"; Agents on this Mac "2 found"; GitHub "Looking". Foot: "macOS may say Oby added a background item. Turn it off any time in System Settings › General › Login Items." / **Continue** | Registers obid with `SMAppService.agent`, makes obid's home and token, waits for `GET /v1/status` to say `"engine": "obid"`, then asks obid what's installed and signed in. No decision: Continue lights up when it's done. An existing install.sh setup is moved over (section 3). |
| 3 | **Your agents** | "Oby found these on your Mac. Each signs in with its own login, so Oby never sees your password." Rows: Claude Code "Signed in · Max", **Ready**; Codex "Installed, not signed in", **Sign in**; Cursor "Not on this Mac", **Get Cursor**. Foot: "One is enough to start. A second login of the same tool, like a work account, goes in Settings › Accounts." / **Continue** | One account per tool that's signed in, named "Personal", paid by you, added to obid. Continue is on once one tool is ready; with none, it says "Skip for now" and Oby can only talk until one is. |
| 4 | **Finish signing in to Codex** (a sheet over 3) | "Codex opened its sign-in page in your browser. Come back when it says you're done." / "Waiting for Codex" / **Cancel**, **Open the page again** / "Codex keeps its own login. Oby only learns that it worked." | obid runs the tool's own login for that account's folder and tells the app the page to open; the sheet closes when obid sees the account signed in. A tool that wants a code pasted back opens in Terminal instead, as today. |
| 5 | **Connect GitHub** | "So Oby can list your repositories and open a pull request when an agent's work passes its check. GitHub's own sign-in does it; Oby never holds the key." / the one-time code, "Copied. Paste it on the page that opens." / "Already signed in with GitHub's command-line tool? Oby uses that and skips this step." / **Skip**, **Open GitHub** | gh's own device sign-in; the login stays in gh's Keychain item. Skipped automatically when `gh auth status` is already good. Skipped by hand: Oby works, and the first finished task says it can't open a pull request until GitHub is connected. |
| 6 | **What should Oby work on?** | "Pick the repositories agents may change. Oby finds how each one is tested." / a search, then your repositories, most recently pushed first, each "Pushed today · tested with `swift test`" / "2 picked" / **Continue** | The list is `gh api user/repos` through obid. Picking one adds it to obid's repos with its remote, default branch and the check obid detected; the clone starts in the background. |
| 7 | **Oby on your iPhone** | "Point your iPhone's camera at this code. It gets Oby from the App Store if needed, and connects it to this Mac." / QR / "Waiting for your iPhone" / "At home it talks to this Mac directly. Away, it goes through Oby's relay, encrypted end to end, so the relay can't read it." / "No camera nearby? In Oby on the iPhone, type 482 193." / **Later** | A pairing invitation on obid, its QR as a universal link (section 4). The screen moves on by itself when the iPhone pairs. |
| 8 | **Give Oby something to do** | "Pick one, or say anything. You'll see every step as it goes, and nothing leaves this Mac until its check passes." / "Find a small bug in obi and fix it" (a task) / "How is tetrix-ee organised?" (a conversation) / the message box / **Skip** | The two suggestions are made from the repositories picked: one task, one conversation, so the first minute shows both halves of Oby. |
| 9 | **The first task, live** | The conversation: your words, "On it. Claude Code has it in obi on Personal. I'll tell you if it needs you, and when there's a pull request to look at.", the task's card with its live step / "You can close this window. Oby keeps working and tells you when something needs you." | Setup is done. Notifications are asked for here, the first time this task could need you (section "Asked later"). |

### iPhone, screen by screen

| # | Screen | Copy | What happens |
|---|---|---|---|
| 1 | **Connect to your Mac** | "Open Oby on your Mac and point the camera at the code it shows." / the camera / "On this network": "Wellington's MacBook Pro", "Your Mac asks you to allow this iPhone" / **Type a code instead** | The first screen whenever the iPhone isn't paired; no default address. Scanning with the system Camera app works too: the code is a universal link that opens Oby on this screen with the invitation filled in. Picking a Mac found over Bonjour asks the Mac to allow it ("Allow Wellington's iPhone to use Oby?" on the Mac, Allow or Don't Allow): the six-digit code without typing. |
| 1b | **Type the code** | "Your Mac shows six digits under its code. They work once, for two minutes." / six boxes / "Looking for Wellington's MacBook Pro on this network" / **Connect** | `POST /v1/pairing` with the code, found over Bonjour. |
| 2 | **You're connected** | "Oby on this iPhone works with Wellington's MacBook Pro, at home and away." / "On this Wi-Fi · Connected"; "Away from home · Through Oby's relay, encrypted end to end · Ready" / **Continue** | The device token and the Mac's key go in the Keychain; the publishing key registers with the same pairing. |
| 3 | **When something needs you** | "Oby tells you only when a task needs your answer, or ends badly. Never for progress: that stays on the Lock Screen while it runs." / an example: "Run swift test?" with Allow, Always allow, Deny / "Answer right from the notification. iOS asks next." / **Turn on notifications**, **Not now** | One line, then iOS's own prompt. Not now: asked again the first time something said on the iPhone starts a task. |
| 4 | **Home** | Oby, "1 running task", the chips, Running and Recent, "What do you want me to work on, Wellington?" | The same Home as every day (docs/ios-design.md). |

### Asked later, when it's needed

| What | The moment | Oby's line first | Then |
|---|---|---|---|
| Accessibility (the fn key) | The first time you click the box's voice button or open Settings › Voice | "Hold fn to talk. Oby listens only while you hold it. To notice that one key, it needs Accessibility; macOS asks next, then asks about the microphone the first time you talk." Continue, Not now | macOS's prompt; Oby watches for it (no callback exists, so it checks every 2 s, as `FirstLaunch` does today). |
| Microphone (Mac) | The first time you hold fn | (said already) | macOS's prompt. |
| Microphone and speech (iPhone) | The first tap on the mic | "Oby listens until you tap Stop, up to a minute, and your words stay a draft until you send them." | iOS's prompts, microphone then speech. |
| Screen Recording | The first "Show Oby your screen" | "To see your screen, macOS needs to let Oby record it. It looks only when you ask." | macOS's prompt; the copy in FirstLaunch that says it isn't asked goes. |
| Notifications (Mac) | The first task you start | "Oby tells you when a task needs you or ends badly. Nothing else." | macOS's prompt. |
| Face ID or Touch ID | The first time you publish by hand | (the action itself is the reason: "Publish 2 commits to obi") | the system's prompt. |
| Keep the Mac available | Pairing an iPhone, on a desktop Mac or a laptop on power | none: on by default, shown in Settings › iPhone | — |

### Errors and recovery

Each one is one line where you are (Home, the conversation, the task), in Sangam's notice style, with at most two buttons. The same words on both apps.

| Situation | Where it shows | Copy | Action | Needs |
|---|---|---|---|---|
| An agent isn't installed (removed, or never there) | Mac: Home, and on each task that waits for it. iPhone: the task | "Cursor isn't on this Mac any more" / "The task on Cursor waits. Move it to Claude Code, or put Cursor back." | **Move to Claude Code**, **Get Cursor** | `GET /v1/agents` with `installed`; Move to… exists (`POST /v1/jobs/{id}/move`) |
| A login expired | Mac: Home and the waiting tasks. iPhone: the same, without the button | "Codex · Personal signed out" / "Its login expired. Two tasks wait for it; the rest go to Claude Code." / iPhone: "Oby on your Mac has the button; it signs in there, with Codex's own login." | Mac: **Sign in to Codex**, **Later** | obid noticing the tool's own "not logged in" (it already fails the job saying so) and an `accounts` event; the sign-in endpoint |
| No internet on the Mac | Mac: Home (quiet dot) | "No internet" / "Agents pause until it's back, then carry on. Nothing is lost." | none | obid's jobs retrying on network errors instead of failing |
| obid stopped | Mac: Home | "Starting Oby's engine again" / "It stopped unexpectedly. Tasks pick up where they were." | none; after three tries: **Restart Oby's engine**, **Send a report** (only with telemetry on) | launchd's KeepAlive; the app noticing `GET /v1/status` failing |
| The Mac is asleep | iPhone: Home and every page | "Your Mac is asleep" / "Since 11:02 PM. Oby picks up when it wakes; what you send waits here until then." | none | the Mac telling the relay it's going to sleep (`NSWorkspace.willSleepNotification`), so "asleep" isn't a guess |
| The Mac can't be reached | iPhone | "Can't reach your Mac" / "Last seen 9:41 AM. Check it's on and online." | **Try again** | — |
| No internet on the iPhone | iPhone | "No internet on this iPhone" / "Showing what Oby knew at 9:41 AM." | none | `NWPathMonitor` |
| The iPhone was removed (revoked, or unused 30 days) | iPhone: replaces Home | "This iPhone was removed from your Mac" / "Scan the code in Oby on your Mac to connect again." | **Scan the code** | the gateway's 401 told apart from others |
| GitHub not connected, a task finished | Mac and iPhone: the task | "Done, but not published" / "Connect GitHub so Oby can open the pull request." | Mac: **Connect GitHub** | `GET /v1/status` `github` |

## 3. Remote access: how the iPhone reaches the Mac

At home, the iPhone finds the Mac over Bonjour and talks to it on the local network. Away, there are three ways, and they aren't equal.

| | Tailscale | Oby's relay (`cloud/control-plane`, #285) | iCloud (CloudKit) |
|---|---|---|---|
| What the user does | Install Tailscale on both devices, sign in to it, allow its VPN profile on the iPhone; the owner also runs `tailscale serve` | Nothing: Oby sets it up when an iPhone pairs | Nothing, if both devices use the same Apple ID |
| Works like a live connection (event stream, words arriving) | Yes | Yes (Cloudflare Tunnel, outbound from the Mac, `cloudflared` already bundled in Oby.app) | No: records and pushes, seconds apart; no stream |
| Who can read the traffic | Nobody but the devices (WireGuard) | Cloudflare terminates TLS: it sees every request and answer, the device token included, until Oby adds its own end-to-end encryption (#287) | Apple can't read records encrypted with `encryptedValues` |
| What exists today | The path the owner uses; obid's docs describe it | The Worker, the Mac client (`apps/mac/app/RemoteAccess.swift`), the tunnel; not deployed for others; email sign-in every 90 days | Nothing |
| Cost and operations | Each user's Tailscale account | Deskree runs one Worker and one zone; tunnels are free | Free, Apple's |
| Wakes a sleeping Mac | No | No | No |

**Recommendation: Oby's relay, with end-to-end encryption before it's on for anyone.**

- It is the only one the user never has to know about, and it already exists on both ends. Tailscale can't be made invisible (the iPhone needs Tailscale's own app and VPN profile); CloudKit can't carry a conversation.
- **End-to-end encryption is the condition, not a later step.** The QR code carries the Mac's public key; the iPhone's key goes to the Mac with the pairing. Every request and answer through the relay (and on the local network, which is plain HTTP today) is sealed between those two keys (HPKE, or Noise IK), event-stream frames one by one. Cloudflare then sees which installation, when, and how much, never what. Until it lands, away-from-home stays Tailscale for the owner (the Mac's pairing accepts a `ts.net` address, S).
- **Bind the device token to the device.** Each gateway request also carries a signature from the iPhone's Secure Enclave key (the same P-256 key it already makes for publishing), so a copied token is useless on its own.
- **No Oby account for it.** The relay needs to know an installation, not a person: the Mac registers with its own key (and App Attest where the platform allows), and the email code goes. If abuse needs a person behind it, Sign in with Apple, once, on the Mac (#282).
- **Notifications** ride the same relay: obid hands it a sealed payload and the iPhone's push token; the relay holds Deskree's APNs key and sends a `mutable-content` push; the iPhone's notification service extension opens it with the pairing's key. Apple and the relay see that something happened, not what. A Live Activity's content can't be decrypted on the way (iOS renders it directly), so through the relay it carries only counts and stages, never titles or paths.
- **iCloud's place** is discovery, later: with the same Apple ID, the Mac can leave its pairing offer (its name and public key, sealed) in the user's private CloudKit database, and an iPhone signed in to the same Apple ID offers "Connect to Wellington's MacBook Pro?" with no QR code at all. That needs the iCloud capability on a Developer ID Mac app, to be checked.

**Against AGENTS.md's rules:**

| Rule | How the relay keeps it |
|---|---|
| Everything outgoing is scanned for secrets; if the scanner can't run, nothing is published | The gateway already passes only allowlisted routes, with vault secrets, `session` ids and home paths taken out (docs/runner-api.md, "obid only: the gateway"); the relay adds nothing to what leaves, and with #287 sees only ciphertext. |
| Oby never reads, stores or forwards the user's agent logins | Logins never cross: every sign-in happens on the Mac, by the tool itself. The relay never sees a login, and with #287 never sees a device token. |
| Secrets in Oby's vault never reach an agent | Unchanged: the relay is outside the agents' world. |
| Text from other people is data | Unchanged. |
| No telemetry unless the user turns it on | The relay keeps hashes and the installation's endpoint, never content or logs of content (docs/remote-access.md); "Send a report" on errors exists only with telemetry on. Using the relay is a connection the user made by pairing, said in one line on the pairing screen, and off in Settings › iPhone. |
| The microphone | Untouched by any of this. |

## 4. What each step needs

What exists today, and what must be built, by where it lives.

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
| Mac 6: repositories | `repos` in `config.json`, read once at start | `GET /v1/github/repos` (`gh api user/repos --paginate`, loopback only); `POST`/`DELETE /v1/repos` that write obid's settings, start the clone and detect the check (`Package.swift`, `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, a `test` target in a `Makefile`); repositories from the API kept beside `config.json`'s as accounts will be; docs/runner-api.md in the same pull request | obid | M |
| Mac 6: the picker | — | The screen, on obid's API | Mac | S |
| Mac 7 and iPhone 1: pairing with no prerequisite | Invitations (`core/crates/obid/src/gateway.rs:209-235`); the QR (`apps/mac/app/PairingView.swift:113-136`); the iPhone's scanner, envelope check and token store (`apps/ios/app/QRScanner.swift`, `apps/ios/app/ConnectScreen.swift:187-220`) | The QR carries every route (the LAN name, the relay's hostname when there is one, a `ts.net` address when given) and the Mac's public key; no Remote-access prerequisite; the QR is a universal link (`https://<Deskree's domain>/pair#…`, the invitation in the fragment so it never reaches a server) with its `apple-app-site-association` | Mac, iPhone, a static page | M |
| iPhone 1: finding the Mac | The iPhone browses `_oby._tcp` (`apps/ios/app/ConnectScreen.swift:255-388`); the Swift runner's advertiser (`Runner/Bonjour.swift`) | obid's gateway reachable on the local network and advertised as `_oby._tcp` under the Mac's name: either obid listens on the LAN itself, or the Mac app forwards a LAN port to `127.0.0.1:8810` and advertises it (simplest, keeps obid on loopback) | Mac (or obid) | M |
| iPhone 1: "Allow this iPhone?" on the Mac | — | A pairing request from a Bonjour-found iPhone shows on the Mac (Allow, Don't Allow) and pairs it as the code would | obid, Mac, iPhone | M |
| iPhone 1: Connect as the first screen | ConnectScreen in Settings | Connect as the first run when unpaired; drop `Runner.defaultURL` and Settings › Runner's address field and Tailscale footer | iPhone | S |
| iPhone 2: the publishing key with the pairing | `POST /v1/devices` behind `touch home/pairing` (`core/crates/obid/src/devices.rs:113-123`) | A paired device's token may register its own key once | obid | S |
| Pairing that doesn't lapse | 30-day tokens (`core/crates/obid/src/gateway.rs:238-288`) | Renew on use; end only when revoked or unused for 30 days; the iPhone keeps `expiresAt` and tells a gateway 401 apart ("This iPhone was removed…") | obid, iPhone | S |
| Remote: end-to-end encryption (#287) | — | Keys from pairing; sealed requests, answers and event frames through the gateway, on the LAN and the relay; the device-key signature on each request | obid, Mac, iPhone | L |
| Remote: the relay without an email code | The control plane and the Mac client (docs/remote-access.md) | Installations registered by the Mac's own key (App Attest where available); turned on by pairing; deployed and run by Deskree | cloud, Mac | M |
| Notifications from obid | The Swift runner's APNs (`Runner/Push.swift`); the iPhone's registration (`apps/ios/app/Notifications.swift`) | `POST /v1/notifications` and `/v1/activities` on obid; pushes through the relay, payload sealed; the iPhone's notification service extension; the `permission` category with Allow once, Always allow, Deny | obid, cloud, iPhone | L |
| iPhone 3: asking at the right time | `Notifications.ask()` on connection (`apps/ios/app/Phone.swift:427-428`) | The screen, and asking after the first task otherwise | iPhone | S |
| Mac 8 and 9: the first task | `POST /v1/plans` | Two suggestions made from the picked repositories; ask for notifications when the first task starts | Mac | S |
| The setup window | FirstLaunch (`apps/mac/app/FirstLaunch.swift`) | Replace its steps with screens 1 to 9 on Sangam's components (docs/mac-design.md B1); drop the Models and Permissions steps; fix "menu bar" and "Screen Recording" copy | Mac | M |
| Asked later | Permission rows (`apps/mac/app/Setup.swift:9-101`) | The one-line explainers before each system prompt, at the moments above | Mac, iPhone | S |
| Errors and recovery | Mac offline banner (`apps/mac/app/App/RunnerOfflineNotice.swift`), iPhone offline line (`apps/ios/app/Phone.swift:238-242`) | One notice view in `apps/shared` and the states in the table above; the Mac's sleep notice to the relay | Mac, iPhone, cloud | M |
| Keep the Mac available | `MacAvailability` (`apps/mac/app/Availability.swift:77-100`), app-side only | On by default on a desktop Mac and on power; obid itself holds the assertion while jobs run, so it holds with the app closed | Mac, obid | S |

### The build list by size

- **S:** gateway on by default · `GET /v1/agents` and `claudeKeychain` by itself · "Get …" for a missing tool · the repository picker screen · Connect as the iPhone's first run (no default address) · the publishing key with the pairing · pairing that renews, and a clear 401 · notifications asked at the right time · the first-task suggestions · the one-line explainers before system prompts · keep-awake by default, held by obid.
- **M:** moving an install.sh setup over and retiring `oby-runner` · signing in with each tool's own login without Terminal · GitHub through a bundled `gh` · the repositories API with check detection · pairing with no prerequisite, every route in the QR, a universal link · Bonjour and a LAN path for obid's gateway · "Allow this iPhone?" on the Mac · the relay without an email code · the new setup window · errors and recovery on both apps.
- **L:** obid inside Oby.app with `SMAppService` · end-to-end encryption (#287) · notifications from obid through the relay.
- **Being built elsewhere:** obid's accounts API and its sign-in command (the obid-accounts session, docs/mac-design.md A2, A3); Settings' components, Settings in the window and one account list (the mac-settings session, B1, A1, C1).

## 5. Order of work

Small pull requests into `dev`, each usable on its own, the ones that remove a terminal step first.

1. **fix(ios): Connect is the first screen.** No default runner address; Settings' Runner section and Tailscale footer go; a gateway 401 says the iPhone was removed; keep `expiresAt`. (S)
2. **fix(mac): FirstLaunch's copy.** "Menu bar", "Screen Recording isn't asked". (S)
3. **feat(obid): the gateway on by default, and `claudeKeychain` by itself on macOS.** (S)
4. **feat(obid): `GET /v1/agents`.** Installed, version, signed in. docs/runner-api.md with it. (S)
5. **feat(obid): pairing renews, and the publishing key registers with it.** (S)
6. **feat(mac): pairing with no prerequisite.** Every route in the QR (LAN, relay, `ts.net`), the Mac's key in it. (S, then the universal link with item 12)
7. **feat(mac): Bonjour and a LAN path for obid's gateway.** The iPhone's code entry and "On this network" start working. (M)
8. **feat(obid): repositories API with check detection, and gh's credential helper for clones.** (M)
9. **feat(mac): obid inside Oby.app.** Build phase, `SMAppService`, first-run home and token. (L)
10. **feat(mac): move an install.sh setup over, retire `oby-runner` from This Mac.** (M)
11. **feat(mac): the new setup window.** Screens 1–9 on Sangam's components, using 3–10 and the obid-accounts session's API; bundled `gh` and its device sign-in (M each, two PRs).
12. **feat(ios): the setup screens.** Connect, Type the code, Connected, Notifications; the universal link and its association file. (M)
13. **feat(obid, mac): signing in without Terminal.** (M, after the obid-accounts session's sign-in command)
14. **feat: errors and recovery.** One notice view, the states above, on both apps. (M)
15. **feat(obid, mac, ios): end-to-end encryption (#287).** (L)
16. **feat(cloud, mac): the relay without an email code, turned on by pairing.** Only after 15. (M)
17. **feat(obid, cloud, ios): notifications through the relay.** (L)
18. **feat(mac, ios): "Allow this iPhone?" from a Bonjour-found iPhone.** (M)
19. **Later:** the same Apple ID finds the Mac with no QR code (CloudKit), once the iCloud capability on a Developer ID app is confirmed.

## 6. Decisions for the owner

1. **Away from home:** Oby's relay, with end-to-end encryption first (recommended), or Tailscale.
2. **Who the relay knows:** the Mac's own key with no Oby account (recommended), or Sign in with Apple.
3. **GitHub:** a `gh` bundled in Oby.app (recommended), or require the user's own `gh`.
4. **`claudeKeychain`:** on by itself when Claude Code's login is only in the Keychain (recommended, under the decision of 2026-10-17), or asked.
5. **The Swift runner:** no longer registered by Oby.app once obid is bundled (recommended).
6. **Pushes:** Deskree's relay holds the APNs key and sends sealed payloads (recommended), or no pushes when the app is closed.
