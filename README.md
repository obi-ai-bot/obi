<p align="center">
  <img src="apps/icon/exports/oby-1024.png" width="128" alt="Oby">
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
> Oby is in active development. There is no release yet; build it from source below.

## What it does

- **Delegates your coding work.** Ask for a review, a fix for failing CI, or release notes. Oby picks the agent, account and repository, and gives every job its own branch.
- **Uses the plans you already have.** Claude Code, Codex and Cursor sign in through their own tools. Oby never sees your passwords and shows how much of each plan is left.
- **Keeps the work moving.** It follows each job, nudges it when it stalls, and opens the pull request once checks pass and the secret scan is clean.
- **Only interrupts you for decisions.** When something needs you, you get the finding, the evidence and a clear next step.
- **Works with your team.** Everyone has their own Oby. In an Obysphere, Obys share updates and context and hand work off on behalf of their people.
- **Knows your systems.** Connect a [Tetrix](https://deskree.com) knowledge graph or your own MCP servers for context about your code.

## You stay in control

- Oby never merges, force-pushes or pushes to `main`.
- Everything going out is scanned for secrets first; reviews posted as you are confirmed with Touch ID.
- Every job has time and cost limits, and **⌃⌥⌘.** stops them all.
- No usage data leaves your Mac unless you turn it on.

## Build from source

Requires macOS 26 or later and Xcode 27.

1. Open `apps/Oby.xcodeproj`.
2. Run the **Oby** scheme on My Mac.

The Mac app runs Oby's server, `obid`, for you. To run `obid` on its own (on Linux, for example), see [docs/install.md](docs/install.md).

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
