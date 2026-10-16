# Next steps: the open-source restructure

For Wellington, from Dmytro. This is the plan for turning this repository into the open-source home of Oby. It lists what is decided, what we want to learn, the target layout, and the work in order. It has no dates on purpose. Order is what matters.

## 1. Why this document exists

Oby is being set up as an open-source experiment. We want to test two hypotheses: engineers want a personal delegate, and teams want those delegates to work together. The code moves into the `obi-ai-bot` org, under the Apache-2.0 license, so anyone can run it and anyone can build an Oby-compatible agent. Tetrix is an optional plug-in. Oby never requires it.

## 2. Decisions already made

| Decision | Choice | Why |
|---|---|---|
| Product name | **Oby** | The app, the bundle ids and `window.oby` already say Oby. The GitHub org and the protocol keep the `obi` spelling. |
| GitHub org | `obi-ai-bot` | A home that belongs to the product, not to Deskree's internal org. |
| Repositories | Two: `obi` (this monorepo: engine, apps, character, plug-ins) and `obi-sphere` (the Obi-to-Obi spec and the Sphere server) | The protocol must be readable and implementable on its own, by agents that are not Oby. The repository names stay `obi` and `obi-sphere`. |
| License | Apache-2.0 in every repo, plus a trademark on the name | Permissive with a patent grant. The trademark keeps "Oby" meaning our product. |
| Languages | Engine in Rust, UI shells native (Swift on Apple, Kotlin on Android), server in TypeScript | One portable engine for every platform. Native UI where it matters. The server matches the existing Cloudflare control plane. |
| Oberon | The `deskree-inc/oberon` repo is archived | Its ideas live on in Oby. One product, not two. |
| Tetrix | One plug-in among equals | Oby works fully on its own. Tetrix adds richer memory for those who want it. |
| Visibility | Repos stay private until launch | We launch when the Sphere works end to end, not before. |
| Deskree's pipeline rules | Xcode Cloud, dev-to-main promotion and three-review escalation move to configuration, not product code | They are how Deskree works, not how every team works. |
| The app's screens | Sangam's React screens (#491) become `apps/web`, served by `obid` (#492). The Mac window takes the same design in SwiftUI (#270). Electron isn't shipped. | The screens already exist, and they fit (f) as they are. UI shells stay native, as the Languages row says. |
| Conversations | Many conversations with Oby, sharing one memory (#493) | One thread grows until the brain forgets (#379), and most questions are quick ones that bury the work. |
| Oby to Oby | Still typed actions: `question` and `answer` join the spec, with their words as quoted data, and the apps show the exchanges as conversations (#494) | H2 needs more than review requests. Words between people's machines must stay data, never instructions. |
| Shared knowledge | An Obysphere picks the sources and tools; each member signs in with their own account (#495) | No secret is shared or kept in the Sphere, and each person's own access applies. |

## 3. The two hypotheses and how we measure them

| Hypothesis | Metric | Source |
|---|---|---|
| **H1.** Engineers want a delegate. | Weekly active Obys. | Opt-in ping in the daemon. |
| | Unattended jobs per Oby per week. | Opt-in ping in the daemon. |
| | 4-week retention. | Opt-in ping in the daemon; Sphere sign-ups. |
| **H2.** Teams want delegates that work together. | Share of installs in a Sphere with 2 or more Obys. | Sphere sign-ups. |
| | Oby-to-Oby requests per Sphere per week. | Sphere server. |
| | Acceptance rate vs decline rate of those requests. | Sphere server. |
| **Tetrix pull.** | Share of Obys that enable the Tetrix plug-in. | Opt-in ping in the daemon. |
| **Interest.** | Stars, forks, issues and outside pull requests. | GitHub. |

Telemetry is off by default. The daemon sends the ping only after the user turns it on.

## 4. Target layout of this repo

```
obi/
├── core/            Rust daemon `obid`: goals with acceptance conditions, jobs, worktrees and sandbox, a model-agnostic planner, agent adapters (Claude Code stream-json, Codex app-server, anything over ACP), decision memory ("asked once, remembered"), inbox, publish gate (secret scan, never merges), vault, accounts and usage meters, event sources (GitHub, Slack), local API and event stream, Obi-to-Obi client
├── apps/
│   ├── web/         TypeScript universal client, served by the daemon
│   ├── mac/         Swift: notch, Touch ID, character; a thin client of the daemon
│   ├── ios/         Swift thin client
│   ├── watch/       Swift thin client
│   └── android/     Kotlin thin client, later
├── character/       The three.js mascot, unchanged
├── plugins/         Context providers and event sources, each optional; Tetrix is one of them
├── mcp/             The Oby MCP server
└── docs/            Documentation
```

Today's `Engine/` and `Runner/` (Swift) are the specification for `core/`. The existing Mac, iPhone and Watch apps already talk to the runner over the documented API in [`docs/runner-api.md`](runner-api.md). So they keep working while the engine is ported: `core/` serves the same API.

Note: the character lives in `character/`. It was renamed from `Character/` with `git mv` through a temporary name, not directly, because macOS ignores letter case in paths.

## 5. Workstreams, in order

Each one has an owner. All owners are TBD.

1. **(a) Name alignment.** Cancelled. The product stays **Oby**: the apps, the bundle ids and `window.oby`. The GitHub org (`obi-ai-bot`), the repository names (`obi`, `obi-sphere`) and the daemon `obid` keep the `obi` spelling.
2. **(b) Freeze the Swift engine.**
   - What: no new features in `Engine/` and `Runner/`. Bug fixes only.
   - Done when: the freeze is written in AGENTS.md and open feature issues on the engine are moved to `core/`.
   - Owner: TBD.
3. **(c) Extract the spec.**
   - What: write `obi-sphere/spec` from [`docs/pipeline-cases.md`](pipeline-cases.md) and the `Plan` schema in `Engine/Brain.swift`.
   - Done when: the spec defines every typed action, its fields and the receiver's decision rule, and a reader can implement it without reading Swift.
   - Owner: TBD.
4. **(d) Port the engine to Rust, behind the existing runner API.**
   - What: build `core/` adapter by adapter: Claude Code first, then Codex, then Cursor and anything over ACP. Port the API-level tests from `RunnerTests`. Drop the Swift-internal ones. A human reviews every ported module.
   - Done when: the Mac, iPhone and Watch apps run against `obid` with no change to their code, and the ported API tests pass.
   - Owner: TBD.
5. **(e) Sphere server and the Obi-to-Obi client.** This is milestone F12.
   - What: the server in `obi-sphere/server` (directory, policy, relay, audit, invitations) and the client in `core/`.
   - Done when: Deskree's own five Obys run on it, and the launch demo works: Ernesto's Oby asks Wellington's Oby for a review over the real protocol.
   - Owner: TBD.
6. **(f) Web client inside the daemon.**
   - What: `apps/web`, served by `obid`, so the launch is not Mac-only. It starts from Sangam's screens in `design/app` (#491), wired to the runner API (#492).
   - Done when: a Linux user with no Apple device can set a goal, watch jobs and answer the inbox from a browser.
   - Owner: TBD.
7. **(g) Plug-in model.**
   - What: context providers and event sources become equal plug-ins. Move the Tetrix integration (`Engine/TetrixUse.swift` and the Tetrix memory decisions) behind it.
   - Done when: Oby runs with no plug-ins enabled, and Tetrix is enabled the same way as any other plug-in.
   - Owner: TBD.
8. **(h) Move Deskree-specific pipeline rules to configuration.**
   - What: Xcode Cloud, dev-to-main promotion, three-review escalation and similar rules become configuration that Deskree sets for its own repos.
   - Done when: a fresh install has none of them on, and Deskree's repos behave as today with their configuration.
   - Owner: TBD.
9. **(i) Launch readiness.**
   - What: opt-in telemetry, trademark filing, README rewrite, CONTRIBUTING.md, SECURITY.md, Show HN draft.
   - Done when: each item is merged or filed, and the repos are ready to be made public.
   - Owner: TBD.

**If scope must be cut:** cut the web client and launch Mac-first. Never cut the Sphere. It is the hypothesis.

## 6. What is NOT in scope

- A chat server. The Sphere is directory, policy, relay and audit. People talk to their own Oby.
- Replacing Claude Code, Codex or Cursor. Oby dispatches them.
- Requiring Tetrix.
- Telemetry on by default.
- Merging on anyone's behalf.

## 7. Open decisions

For Dmytro and Wellington.

- [x] Keep the `window.oby` JavaScript API name. It stays `window.oby`.
- [ ] UniFFI, or HTTP only, between the Rust core and the Swift shells.
- [ ] Whether the Cloudflare control plane (`cloud/control-plane/`) merges into the Sphere or stays in `obi`.
- [ ] Android timing relative to launch.
- [ ] Which Deskree repos run on Oby during dogfood.
- [ ] Trademark attorney.

## 8. Where things are

- This repo: [obi-ai-bot/obi](https://github.com/obi-ai-bot/obi)
- Spec and Sphere server: [obi-ai-bot/obi-sphere](https://github.com/obi-ai-bot/obi-sphere)
- Oberon (archived): [deskree-inc/oberon](https://github.com/deskree-inc/oberon)
- Runner API: [`docs/runner-api.md`](runner-api.md)
- Pipeline cases: [`docs/pipeline-cases.md`](pipeline-cases.md)
- Remote access: [`docs/remote-access.md`](remote-access.md)
- MCP server: [`docs/mcp.md`](mcp.md)
