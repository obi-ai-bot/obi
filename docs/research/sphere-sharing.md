# Sharing in the Obysphere: my idle Mac, and a share of my usage

Research and design, 2026-10-20. Not built yet: both features are on the roadmap as `future`. The preview for Sangam is in `design/app` (Settings › Sharing, the message box's **Run on another Mac**, the usage panel's **Shared with you**, four inbox cards). Screenshots are in `docs/images/sphere-sharing/`.

- **Feature A, my idle Mac as a runner for my Sphere.** When my Mac is idle, people in my Obysphere can run their jobs on it, with their own AI accounts.
- **Feature B, a share of my usage.** I let someone in my Sphere use part of one of my agent accounts.

## The short answer

- **A works, built so that a member's login never comes to my Mac.** Their job runs on my Mac in a Linux VM of its own. The VM reaches their AI account, and the network, only through their own Oby: their obid adds their login to each model call on their Mac, and the call leaves from their Mac. No copy of their login is ever made, so there is nothing to delete afterwards.
- **B as asked (30% of my Claude Max for Sangam) breaks all three providers' terms.** Anthropic, OpenAI and Cursor all keep a personal plan to one person, whether it's shared by handing over a login or by running someone else's tasks on it and returning the results. Per-person Team and Business seats are the same.
- **B is redesigned, and the owner accepted it on 2026-10-20 (section 7).** Only an account the company pays by use can be shared: an organisation's API key, under its own budget. A shared job runs on the key holder's Mac, in the same VM as A, and its model calls go through the key holder's obid, which adds the key and meters the share. API accounts have no 5-hour or weekly window, so the share is a percentage of a monthly budget the owner sets.

## 1. What the providers' terms allow

Sources were read on 2026-10-20. Quotes are verbatim. "Reading" marks our interpretation.

| | Someone else uses my personal plan (a login handed over, or their tasks run on my account) | My login used on someone else's machine | Pooling across an organisation | Automated or headless use |
|---|---|---|---|---|
| **Anthropic** (Free, Pro, Max) | **Not allowed** | Unclear: there's no device clause, but a token the other person can read counts as a shared credential | **Allowed** with Console API keys and usage-based Enterprise. Team and Enterprise seats are per person, with optional extra usage under an organisation cap | Allowed only for your own use, in Claude Code itself |
| **OpenAI** (Plus, Pro, Codex) | **Not allowed** | Unclear: copying `auth.json` is documented only for your own headless machine | **Allowed** with workspace credits, Enterprise access tokens and API keys | Unclear. Codex points automation to API keys |
| **Cursor** | **Not allowed**. The terms say "lend"; Cursor staff on the forum say "account sharing" outright | Unclear | **Allowed** with the team's shared extra-usage balance and Enterprise pooled usage. Teams seats don't share pools | Allowed with a user API key |
| **Gemini CLI** | Unclear | Unclear | Allowed with Workspace licences, Vertex AI and API keys | Its docs recommend an API key or Vertex AI |

### Anthropic

- **Consumer Terms §2:** "You may not share your Account login information, Anthropic API key, or Account credentials with anyone else." "You also may not make your Account available to anyone else."
  - https://www.anthropic.com/legal/consumer-terms
- **Consumer Terms §3:** no "automated or non-human means" of access, "Except when you are accessing our Services via an Anthropic API Key or where we otherwise explicitly permit it".
- **Claude Code, Legal and compliance:**
  - "Advertised usage limits for Pro and Max plans assume ordinary, individual usage of Claude Code and the Agent SDK."
  - Third-party developers may not "route requests through Free, Pro, or Max plan credentials on behalf of their users", and may not "collect, store, or intermediate Claude.ai credentials or session tokens".
  - An API key "for use by the customer's own authorized users", "billed to the key owner", is allowed.
  - https://code.claude.com/docs/en/legal-and-compliance
- **Usage Policy, "Do Not Abuse Our Platform":** "Resell, proxy, or otherwise provide access to Claude through unauthorized means, including services that route requests through consumer subscriptions".
  - https://www.anthropic.com/legal/aup
- **Weekly limits (from August 2025):** Anthropic gave "account sharing and reselling access to Claude Code" as a reason for them (reported by TechCrunch and VentureBeat).
- **Reading:** running Sangam's job on my Max account and handing Sangam the result is "making my account available" to Sangam. It is also outside "individual usage". This holds whichever machine the job runs on.

### OpenAI

- **Terms of Use, "Registration":** "You may not share your account credentials or make your account available to anyone else."
  - https://openai.com/policies/row-terms-of-use/
- **Services Agreement §3.1** (Business, Enterprise and API): "Customer will not share Account access credentials or individual login credentials between multiple users."
  - https://openai.com/policies/services-agreement/
- **Codex authentication docs:** "Use API key authentication for programmatic Codex CLI workflows, such as CI/CD jobs." Enterprise access tokens are for "trusted scripts, schedulers, and private CI runners."
  - https://learn.chatgpt.com/docs/auth

### Cursor

- **Terms of Service** (updated 2026-09-03): you may not "rent, lease, lend, or sell the Service".
  - https://cursor.com/terms-of-service
- **Teams docs:** "Seats don't share weekly pools with each other, and usage doesn't transfer between team members."
  - https://cursor.com/docs/account/teams/pricing
- **Cursor staff on the forum:** "Account sharing is against the Cursor terms of service".
  - https://forum.cursor.com/t/can-multiple-people-use-one-cursor-account/158868

### Gemini CLI

- **Authentication docs:** personal accounts versus licences from "a company, school, or Google Workspace". For headless runs, "Use Gemini API Key or Vertex AI".
  - https://geminicli.com/docs/get-started/authentication/

### What this means for us

- **For A:** a member's job uses the member's own account, for the member's own work. That's individual use. The one new thing is where the job's tools run.
  - Copying their token to my Mac is risky under every provider's terms: I am an administrator of my Mac, so I could read it.
  - The design below never copies the token. The model calls still leave from the member's Mac, with the member's login, added there.
  - Doing that through a base-URL relay is not a documented setup for subscription logins, for either Claude Code or Codex. **Before A ships for subscription logins, ask Anthropic and OpenAI.** Org API keys are clearly allowed today.
- **For B:** only an organisation's pay-as-you-go account can serve several people.
  - Anthropic's Console allows "API key … for use by the customer's own authorized users". The same goes for an OpenAI API project, Cursor's team balance and Vertex AI.
  - A per-person seat (Claude Team, ChatGPT Business, Cursor Teams) can't be shared. The provider's own answer for more usage is extra usage on that person's seat, which an admin sets.

## 2. Prior art: what makes sharing clear and safe

- **GitHub Actions self-hosted runners.** GitHub warns they "should almost never be used for public repositories". Runner groups limit which repositories can use a runner. Just-in-time runners take one job and are then removed.
  - Lesson: lend to named people and repositories, and give every job a fresh box.
  - https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions
- **Buildkite agents.** Revoking a token stops new agents connecting, but agents already connected keep running. The machine owner can lock things down on the agent itself: an allow-list of plugins, a hook that rejects unapproved repositories, signed pipelines.
  - Lesson: my obid enforces my policy, whatever the other side claims. Stop must kill the running job too.
  - https://buildkite.com/docs/agent/v3/securing
- **Xcode Cloud.** Apple-hosted only, with build environments destroyed after each build.
  - Lesson: be honest that a teammate's Mac is a weaker boundary than a provider's cloud. Say what the host can see.
  - https://developer.apple.com/xcode-cloud/
- **distcc and icecream.** distcc: "Anyone who can connect to the distcc server port can run arbitrary commands." icecream's README: "Never use icecream in untrusted environments."
  - Lesson: an allow-list of addresses on a trusted LAN was their whole trust model. We cross the internet between people, so we need real identities (the Sphere's signed cards) and a sealed box per job.
  - https://www.distcc.org/security.html
- **BOINC.** Its preferences: suspend while the computer is in use (input in the last N minutes), suspend on battery, CPU and memory caps (in use and idle), time-of-day windows. Users complain that any mouse twitch counts as "in use".
  - Lesson: idle, power and schedule are the knobs people understand. Pause at once when the owner comes back, but don't throw the work away.
- **Tailscale node sharing.** You share one machine, not your network. The person you share with sees only that node, and shared nodes are quarantined: they accept connections but can't start them. Revoking takes effect at once.
  - Lesson: lend one capability, one way. The box can't reach back into my Mac or my LAN.
  - https://tailscale.com/kb/1084/sharing
- **Family Sharing, Google One, Spotify Family.** One organiser, a cap on members, everyone keeps their own login, the resource is pooled and the content stays private.
  - Lesson: share an amount, never a login. Each person sees only their own use of the share.

### macOS limits without cgroups

| Mechanism | What it does |
|---|---|
| A Virtualization.framework VM (Apple's `container` / Containerization, Tart) | **Enforces** vCPU count, memory size and disk size, behind its own kernel. This is our box for other people's work. |
| `taskpolicy -b` / `PRIO_DARWIN_BG` | **Enforces throttling**: lowest CPU priority, throttled disk and network I/O. We run the VM process with it, so it yields to the owner. |
| `RLIMIT_CPU`, `RLIMIT_NOFILE`, `RLIMIT_NPROC`, `RLIMIT_FSIZE` | Enforced, per process or per user ID. |
| `RLIMIT_RSS`, `RLIMIT_DATA` | **Advisory**, or ignored for `malloc`. There's no hard memory cap on macOS without a VM. |
| A fixed-size disk image, or an APFS volume with `-quota` | Enforces disk size. APFS has no per-folder quotas. |
| `CGEventSourceSecondsSinceLastEventType`, `IOPSGetProvidingPowerSourceType`, `isLowPowerModeEnabled`, `thermalState` | **Signals only**: idle time, AC or battery, Low Power Mode, heat. |
| Seatbelt (`sandbox-exec`) | Good for files and network, but no resource limits and a shared kernel. That's fine for my own jobs (obid uses it today), not enough for someone else's. |
| macOS guest VMs | The licence allows **2 at a time** per Mac, and the framework enforces it. |

## 3. Feature A: my idle Mac runs my Sphere's jobs

### What it does

- I turn on **Share this Mac with Deskree** (Settings › Sharing). It's off by default.
- **When:** "When I'm away" (no input for 10 minutes), "Nights and weekends", or both. Never on battery, in Low Power Mode, or when the Mac is hot.
- **Who:** "Everyone, ask me first" (the default; the first job from each person waits for my Allow, with "Allow Sangam from now on"), "Everyone in Deskree", or "Only people I choose".
- **Jobs at once:** 1 to 3, default 1.
- **Each job gets:** "4 cores · 8 GB · 30 GB of disk", or "6 cores · 12 GB · 60 GB". That's one setting for the VM's size, not three separate knobs.
- **Work:** any job in the organisation's repositories, or reviews and checks only.
- **Stop:** "On this Mac now" lists every job with its owner, title, account, repository, time and use, each with Stop, plus Stop All. Turning sharing off stops them all.
- A member picks **Run on another Mac** in the message box. The list shows free or busy, never whether the owner is at their Mac.
- When the owner comes back, the job pauses. If the Mac isn't free again within 10 minutes, the job returns to its member's Oby with its commits and notes, and the member chooses **Run it here** or **Wait for Wellington's Mac**.

### Where the credential lives (decided: it never leaves the member's Mac)

| Option | How | Verdict |
|---|---|---|
| 1. A copy, deleted after | The member's obid sends a run-only copy of the login (no refresh token), encrypted to my obid. It's deleted when the job ends. | **Rejected.** As an administrator of my Mac I can read a VM's disk and memory, so this is a shared credential under every provider's terms. It also breaks "never forwarded" (AGENTS.md). |
| **2. The login stays home** | The CLI in the VM is pointed at a local endpoint (`ANTHROPIC_BASE_URL`, or Codex's `model_providers.base_url`) and gets a placeholder token. My obid relays each request over the job's encrypted channel to the member's obid, which adds the real login and sends the call from the member's Mac. | **Recommended.** The token never leaves its Mac. The member's obid sees and meters every call, and revokes access by closing the channel. The member's Mac must stay online, and every call adds one relay hop. Cursor has no base-URL override, so it isn't offered. **Confirm with Anthropic and OpenAI before using it with subscription logins.** |
| 3. Tools run remotely | The agent runs on the member's Mac, and only its tools (shell, edits) run on mine, as MCP tools. | **Rejected.** It loses Claude Code parity, and every file read crosses the network. |

### Protocol (new typed actions, spec `protocol.md`)

These are added the way `review_request` is today. Every one is signed, scanned for secrets, and quoted as data on arrival.

- **`runner_status`**, from the owner's Obi to the Sphere directory. It goes out on change, and at most once a minute: `{free: bool, slots: 0–3, size: "small" | "large", agents: ["claude", "codex"], kinds: ["job", "review", "check"], freeAt?: <time>}`.
  - Members see it only if the owner's "Who" covers them (the directory filters by the owner's policy, and so does the owner's obid).
  - It never says "away".
- **`run_request`**, member to owner:
  - `{title, request (quoted), agent, model, mode, check, repo, base, branch, bundle: {sha256, bytes}, size, maxMinutes}`.
  - The code comes as a git bundle over the job channel, as the Mac check's `/v1/checks/{id}/bundle` already does (`docs/runner-api.md`, "Mac check"). My Mac never fetches from GitHub for a guest.
- **`accept` / `decline`** (these exist already). `decline.reason` can be `busy`, `policy`, `not_free` or `owner_declined`.
- **`run_progress`**, owner to member: stage, step and heartbeat. The live transcript streams over the job channel.
- **`run_return`**, owner to member: the job paused and came back, with a bundle of its commits, its notes and the transcript reference.
- **`result`** (this exists): outcome, a commits bundle and a report, plus `host: {wallSeconds, cpuSeconds, peakMemory}`.
  - **The member's obid publishes**: secret scan, push, pull request, under the member's identity. My Mac never pushes for anyone.
- **`run_cancel`**, member to owner.
- **The job channel.** It carries the model calls, the bundles and the transcript, and is end-to-end encrypted:
  - An X25519 key exchange, each side signed with its Obi's Ed25519 key and bound to the exchange's `correlation_id`.
  - Relayed by the Sphere server, so neither Mac opens a port. The relay sees sizes and timing, never contents or tokens.

### Scheduling in obid

1. **Admission, on my obid** (whatever the Sphere or the member claims):
   - the sender is an active member covered by "Who";
   - a remembered Allow exists, or the owner taps Allow;
   - the kind and repository are allowed;
   - a slot is free;
   - the Mac is free (idle at least 10 minutes or inside the schedule, on AC, not in Low Power Mode, thermal state below `serious`);
   - the VM image is present.
   - If any check fails, obid declines with the reason.
2. **Box:** one Linux VM per job (Apple's Containerization, Virtualization.framework):
   - the vCPUs and memory the owner chose;
   - a fixed-size encrypted disk image, whose key lives only in obid's memory and is thrown away at the end (crypto-erase);
   - no host folders mounted, and no network device.
   - Its only link is a vsock to obid's per-job relay. Inside runs obid's Linux runner, already proven with bubblewrap, so the agent sandbox inside is the one we know.
   - The VM process runs at background QoS (`PRIO_DARWIN_BG`).
3. **The owner comes back:** the VM is paused at once (`VZVirtualMachine.pause`), freeing the CPU immediately. If the Mac is free again within 10 minutes, the VM resumes. Otherwise obid stops it, takes the commits out of the disk image from outside the VM (as `git::keep_commits` does), and sends `run_return`.
4. **Caps:** a job runs for at most 2 hours by default; the member can see this and the owner can change it. Disk, CPU and memory are capped by the VM.
5. **Placement (#767):** the member's conversation chooses a Mac from the `runner_status` entries it can see. It uses the same placement logic #767 uses for the owner's own machines, with "someone else's Mac" ranked after the member's own machines. A guest slot never takes more than the owner set.

### Security model

- **Isolation from my Mac:** the guest's own kernel, no host mounts, and no Keychain, pasteboard, preferences, LaunchServices or Apple events (it's Linux in a VM). There's no network device, so my LAN, my IP and my other Macs can't be reached.
- **Network:** everything the box sends goes through the member's obid and leaves from the member's Mac, under the member's network policy (#616: the model's API only, or allowed registries). My IP is never used for someone else's job.
- **Between members:** one VM per job. Nothing is shared between jobs, and the disk is crypto-erased afterwards.
- **What the member must know:** their code is on my Mac while the job runs, and I administer that Mac. The member's picker says so plainly, and only repositories the member chooses are sent.
- **Secrets:** the member's vault secrets and logins never come. My vault, my logins and my Tetrix never reach the box. Tetrix for a guest job is the member's own, through the member's obid's MCP over the channel, or none in v1.
- **Abuse:** work is capped by the VM size and time limit. There's no network except the member's own. Every job is a signed record. The owner can stop a job at once and remove a person from "Who".
- **Audit:** every `run_request`, `accept`, `run_return` and `result` is in the Sphere's signed audit chain (its `seq`). obid keeps a local log of each job's host use. Settings shows the week, and Sphere admins can export it.
- **Revoking access mid-job:**
  - On my side, Stop or sharing off kills the VM at once and returns the job.
  - On the member's side, closing the channel stops the box's access to their account at the next call.
  - Removing a person from the Sphere revokes their token, and their jobs stop.

### Accounting

- **AI usage:** counted on the member's own account, as usual. The member's meters see it, because the calls go out from their obid.
- **My Mac:** each job's wall time, CPU-seconds and peak memory are recorded in the `result`, the audit chain and Settings › Sharing ("On this Mac now", and the week).
- **Money:** none in v1.

## 4. Feature B: a share of my usage, redesigned

### Why it changed

- Sharing a percentage of my Claude Max, ChatGPT Pro or Cursor Pro window breaks those providers' terms (section 1).
- So does running someone else's job on my personal plan "as my job". The job serves them, and Anthropic's terms also name "route requests through consumer subscriptions" on someone's behalf.
- Team and Business seats are one person's each.

### What B becomes

- **Share an account Deskree pays by use.** That's a Console API key, an OpenAI API project key, or Vertex AI.
- **Per account:** **who** (nobody, everyone, or one person) and **how much** (10–100% of its month), under a monthly budget the owner sets on the account. That's needed because API keys have no 5-hour or weekly window.
- Personal plans and seats are listed under **Kept for you**, with the reason, so nobody wonders where the option went.
- The owner's question to answer first: Anthropic's Console workspaces, and OpenAI projects, can already give each person their own key with its own spend limit. B is only worth building if it adds something to that:
  - one place in Oby,
  - shares that move with the Sphere's membership,
  - no key handed to anyone.

### Where it runs, whose Mac, how it's counted

- **B1, as asked: on the key holder's Mac.**
  - The member's job runs on my Mac, in the same VM as A.
  - The VM's model calls go to my obid, which adds my key. **The key never enters the VM or leaves my Mac.**
  - The member gets the result, and their own obid publishes it.
  - It needs my Mac free, as A does.
- **B2, considered and not chosen (section 7): anywhere, with model calls through the key holder's Oby.**
  - The member's job runs on the member's own Mac, and its model calls relay to my obid, which adds the key.
  - No one's code comes to my Mac, and my Mac only needs to be online, not free.
  - It's the same relay as A, the other way round.
- **Metering:** my obid counts cost per call from each response's usage: input, output and cache tokens at list price, with Claude Code's own `total_cost_usd` checked against it. It keeps the count per grant per month.
- **Caps:**
  - A job isn't accepted when the share left is less than its estimate.
  - Once the share is used, my obid lets the call in flight finish, refuses the next one, and the job ends with its notes ("share used").
  - The owner gets an inbox item: "Share 20% more this month" or "Leave it".
- **Counting my own use:** my own jobs on the account count against the budget too. The share is a ceiling for that person, not money set aside. Optionally, the owner keeps a reserve for themselves (open question).

### Protocol

- **`share_offer`**, owner to grantee: `{grant, agent, account (its label), share, period: "month", resets}`.
  - It's sent when a grant is made or changed. The member's usage panel shows it under **Shared with you**.
- **`share_status`**, owner to grantee: `{grant, used, share}`, after each job and at most hourly.
- **`share_revoke`**, owner to grantee.
- **`run_request`** with `account: {grant}`: the same as A, otherwise.
- Grants are kept in `home/sharing.json`, next to the sharing rules, and only the owner changes them, through the runner API (`docs/runner-api.md`, "sharing rules").

### Security

- The key never leaves my Mac: no prompt, environment variable, file or log gets it. The VM sees only a placeholder.
- The member's job is someone else's code and instructions, so it runs in the VM, not in my own jobs' Seatbelt box.
- Every shared job, and its cost, is in the signed audit chain.

## 5. UX (the preview)

The preview is Sangam's Electron design (`design/app`); run it with the `sangam-design` launch configuration.

- **Settings › Sharing** (new page, after Runner):
  - **This Mac:** the switch, plus When, Who, Jobs at once, Each job gets, and Work.
  - **On this Mac now:** each job with Stop, and Stop All.
  - **Share your usage:** only API accounts, each with who and how much, and a meter of the share used.
  - **Kept for you:** personal plans and seats, with the reason they can't be shared.
- **Message box:**
  - **+ › Run on another Mac:** this Mac, then teammates' Macs, each free or busy, and when it will be free. Picking one adds an "On Wellington's Mac" tag. A note says your job runs there with your own accounts, and your logins stay on this Mac.
  - **Usage panel › Shared with you:** whose account, your share of its month, and how much is left.
- **Inbox (cards on Home):**
  - **Start it?** "Sangam asks to use this Mac while you're away", with Allow, "Allow Sangam from now on" and Decline.
  - **Out of usage** (member): "Your Claude is full until 4 PM. Wellington shares 30% of Deskree API's month with you", with "Use Wellington's share", "Run it on Codex" and "Wait for the reset".
  - **Out of usage** (owner): "Sangam used the share of Deskree API", with "Share 20% more this month" and "Leave it".
  - **Came back** (member): "Wellington is back at that Mac. Your job paused there after 18 minutes and came back with its notes and its 2 commits", with "Run it here" and "Wait for Wellington's Mac".
- **Job card:** "Claude Code · Personal · on Wellington's Mac · oby".
- **Notifications** follow the inbox items. They go to the owner for a first-time ask and for a used-up share, and to the member when a job returns or a share runs low (80%).

## 6. Open questions

1. **Subscription logins through the relay (A):** do Anthropic and OpenAI accept a member's own Claude Code or Codex session whose calls go out from the member's Mac while its tools run on a teammate's Mac? Ask both before shipping, and ship API-key accounts first.
2. **The relay:** run it on the Sphere server (Deskree's, on DigitalOcean), or go directly between the two Macs over each Mac's Cloudflare tunnel? We recommend the Sphere server, with end-to-end encryption.
3. **Dependencies:** with all guest traffic leaving from the member's Mac, `npm install` and the like work under the member's policy. Is the bandwidth acceptable on a laptop over hotel Wi-Fi?
4. **Apple checks for guests:** Linux VMs can't run Xcode. Should we offer one of the two macOS VM slots later, given the image size and setup time?
5. ~~**B:** build it at all, and B1 or B2?~~ Decided: build it for company-paid API accounts, on the key holder's Mac (B1). See section 7.
6. **The owner's reserve on a shared API account** (for example "keep 20% for me"): is it worth one more knob?
7. **Members outside the company's Google Workspace** (guests in a Sphere): exclude them from both features by default?
8. **Cursor:** offer it for A only if Cursor adds a base-URL override or an API-key flow that works through a relay?

## 7. Decided (owner, 2026-10-20)

The owner accepted the redesign and its defaults. Both features stay `future`: nothing is built yet.

1. **B's scope:** only company-paid API accounts (organisation keys) can be shared, as a share of a monthly budget. Personal plans and seats show under **Kept for you**, with the reason.
2. **Where B runs:** on the key holder's Mac (B1), in the same VM as A. The key never leaves that Mac.
3. **A's login:** the member's login stays on the member's Mac, and their obid adds it to each call. No copies are ever made.
4. **A's box:** one Linux VM per guest job, with no Seatbelt-only mode for other people's work. So there are no Apple checks for guests in v1.
5. **Guest network:** all of it leaves from the member's Mac, never the host's.
6. **Defaults:** sharing is off. Once on: "When I'm away", "Everyone, ask me first", 1 job, 4 cores · 8 GB · 30 GB, 2 hours per job.
7. **Privacy:** members see only free or busy, never "away".

**Still open:** ask Anthropic and OpenAI whether a subscription login's calls may be routed through another Mac. Until they confirm, A uses API-key accounts only (open question 1).
