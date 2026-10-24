<p align="center">
  <img src="docs/images/oby-logo.png" width="128" alt="Oby">
</p>

<h1 align="center">Oby</h1>

<p align="center">
  <b>Your engineering delegate.</b><br>
  Oby hands your coding work to Claude Code, Codex and Cursor, follows up with your team,<br>
  and only calls you when a decision is yours.
</p>

<p align="center">
  <a href="https://deskree.com/oby">Website</a> · macOS 26+ · Apache-2.0
</p>

<p align="center">
  <img src="docs/images/app-chat.webp" width="820" alt="The Oby window: a conversation with Oby, with the agents working on the right">
</p>

> [!NOTE]
> Oby 0.3.0 is out: [download it](https://downloads.oby.deskree.com/Oby-0.3.0.dmg) for macOS 26 or later. It updates itself. The launch build below (GitHub and Slack, the iPhone through your Obysphere) comes with the next release.

## What it does

- **Delegates your coding work.** Ask for a review, a fix for failing CI, or release notes. Oby picks the agent, account and repository, and gives every job its own branch.
- **Uses the plans you already have.** Claude Code, Codex and Cursor sign in through their own tools. Oby never sees your passwords and shows how much of each plan is left.
- **Keeps the work moving.** It follows each job, nudges it when it stalls, and opens the pull request once checks pass and the secret scan is clean.
- **Only interrupts you for decisions.** When something needs you, you get the finding, the evidence and a clear next step.
- **Works with your team.** Everyone has their own Oby. Your team's Obysphere is a server you host yourself, free on Cloudflare from one Deploy to Cloudflare button ([obi-sphere](https://github.com/obi-ai-bot/obi-sphere)). Obys ask each other for reviews there.
- **Reaches your Mac from your iPhone.** Through your Obysphere, sealed end to end: the Sphere passes frames it can't open. obid's side is done; the iPhone's, and the Mac's pairing screen for it, are in progress.
- **Connects to GitHub and Slack.** It follows your pull requests and issues, and can tell a pull request's author on Slack when a review is in.

## You stay in control

- Oby opens the pull request and leaves the merge to you. It never pushes to or force-pushes `main` or your default branch. Merging a repository's own way, once Oby has asked "Can I remember that?" and you said yes, comes later.
- Nothing goes out until the job's check passes and the secret scan is clean. A review goes out as you only after your Approve.
- Publishing by hand takes Touch ID on the Mac or Face ID on the iPhone. The Mac's password, for a Mac without Touch ID, is in progress.
- Every job has safety limits on time and tokens, and **⌃⌥⌘.** stops them all.
- No usage data leaves your Mac unless you turn it on.

## Build from source

To build it yourself, you need macOS 26 or later and Xcode 27.

1. Open `apps/Oby.xcodeproj`.
2. Run the **Oby** scheme on My Mac.

The Mac app runs Oby's server, `obid`, for you once Settings › Runner › This Mac is on (it isn't on by default yet). To run `obid` on its own (on Linux, for example), see [docs/install.md](docs/install.md).

## Repository

```
apps/        the Mac app (SwiftUI), plus iPhone, Apple Watch, Android and web clients
core/        obid, Oby's server (Rust): plans, runs and tracks jobs
character/   Oby, the 3D character (three.js)
plugins/     optional context sources, such as Tetrix
mcp/         Oby's MCP server
docs/        architecture, runner API and install guides
```

More in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Contributing

Branch from `dev` and open pull requests into `dev`. Commits follow [Conventional Commits](https://www.conventionalcommits.org). `dev` is merged into `main` once a feature's tests pass on a real Mac. See [AGENTS.md](AGENTS.md) for the full workflow and rules.

## License

[Apache-2.0](LICENSE). Made by [Deskree](https://deskree.com).
