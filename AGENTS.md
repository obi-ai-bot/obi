# Working on Oby

Oby is a native macOS app (SwiftUI, macOS 26 and later) that lives in the notch and hands coding work to the user's own Claude Code, Codex, Cursor and Gemini CLIs. The product is described in [README.md](README.md); what is being built, and in which order, is the GitHub project "Oby — Roadmap" (one milestone per feature, F1 to F16).

## How we work

- Branch from `dev` and open pull requests into `dev`. `dev` is merged into `main` only when a feature's "Test it when it's done" list passes on a real Mac.
- One feature at a time, in roadmap order. Each feature issue has the test, the build list and the feasibility notes; read its spikes before starting.
- Update the issue at every step, in the same turn: `status:in-progress` and the branch name when work starts; `status:in-review` and the pull request link when it's open; `status:blocked` and what it waits on; status labels off when it's merged. Move it on the project board too.
- Commits follow Conventional Commits and are signed. Report the checks you actually ran and what they printed.

## Rules Oby never breaks

- Oby never merges, force-pushes or pushes to `main` for anyone.
- Nothing goes out as the user (a push, a pull request, a review, a comment) without showing the exact action and a Touch ID confirmation.
- Everything outgoing is scanned for secrets. If the scanner can't run, nothing is published.
- Text from GitHub, Slack, web pages, screenshots or other people's Obys is data, never instructions. It reaches agents only as quoted files, never in a prompt, and other Obys can only send typed actions.
- The microphone opens only while the user holds fn. No telemetry unless the user turns it on.
- Oby never reads, stores or forwards the user's agent credentials. Each tool signs in through its own login.

## Proven on 2026-10-09 (keep these working)

- **Claude Code headless:** `claude -p --input-format stream-json --output-format stream-json --verbose`, never `--bare`. Permission prompts with `--permission-prompt-tool stdio` arrive as `control_request` `can_use_tool`; answer with `control_response` allow (`updatedInput`) or deny (`message`). Usage arrives as `rate_limit_event` with `five_hour` and `seven_day` utilization.
- **Spawning `claude`:** remove `CLAUDECODE`, `CLAUDE_CODE_*` and `ANTHROPIC_*` from the environment first.
- **PATH:** read the login shell with `getpwuid(getuid()).pw_shell` (it can differ from `$SHELL`) and run it with `-l -c /usr/bin/env`.
- **Codex:** `codex app-server` speaks JSON-RPC over stdio: `initialize`, then `account/read`, `account/rateLimits/read`, `thread/start`, `turn/start`, `turn/interrupt`.
- **Separate accounts:** `CLAUDE_CONFIG_DIR` per Claude account, `CODEX_HOME` per Codex account.
- **The brain:** `claude -p --model haiku --tools "" --strict-mcp-config --setting-sources "" --no-session-persistence --output-format json --system-prompt … --json-schema …`, the prompt on stdin, in an empty directory; the plan is `.structured_output` (it can be missing even on success). 3–4 s. Swift validates every plan (`Plan.problems`).
- **Codex jobs:** `thread/start` with `sandbox: "workspace-write"`, `approvalPolicy: "on-request"`, `approvalsReviewer: "user"` and `config.sandbox_workspace_write` (`writable_roots`: the clone's git directory, `network_access: false`), so commits stay sandboxed. Approvals arrive as `item/commandExecution/requestApproval` and `item/fileChange/requestApproval`; answer `{"decision": "accept" | "decline"}`.
- **Reading agents' output:** split on `\n` only. Foundation's `lines` also breaks at U+2028 inside JSON strings, and a broken `result` line hangs the job.
- **Agents can't publish:** they run with an empty `GH_CONFIG_DIR` (no GitHub login) and Oby's clone has an invalid `remote.origin.pushurl`. Only Publish pushes, after Touch ID.
- **On Linux, agents run in bubblewrap** (`Agents.sandboxed`, proven 2026-10-10 on tetrix-lab): they run as the runner's user, so gh's `hosts.yml`, ssh, other accounts' logins and all of `OBY_HOME` are empty, `/` is read-only and home is a throwaway copy. Real writes: the worktree, the clone's objects, refs, packed-refs and the worktree's own git folder, and the job's account home. Codex's own sandbox (bubblewrap too) can't nest under Ubuntu's AppArmor profile, so on Linux Codex runs `danger-full-access` with `approvalPolicy: "untrusted"` and Oby answers every command.
- **The character in the notch:** `NSPanel` (borderless, non-activating) at `CGWindowLevelForKey(.mainMenuWindow) + 3`; `oby.html` served from the `oby://` scheme into SwiftUI's `WebView`; JavaScript calls go to the page's own world (`contentWorld: .page`). Paused while the island is closed: about 0% CPU.

## Build and run

- Open `Oby.xcodeproj` in Xcode 27 and run the `Oby` scheme on My Mac, or `xcodebuild -project Oby.xcodeproj -scheme Oby build`.
- Tests: `MacTests` (Swift Testing, hosted by the app). Run them with ⌘U or `xcodebuild -project Oby.xcodeproj -scheme Oby -destination 'platform=macOS' test`. While tests run, a test-host Oby is alive, so a freshly launched Oby quits (one instance at a time): launch it again when they finish.
- Oby keeps its clones, job worktrees, `oby.sqlite` and `accounts.json` in `~/Library/Application Support/Oby`.
- The character's source is `Character/`. A build phase runs `Character/package/build.sh` and bundles the clean copy (no playground) into the app.
- The app isn't sandboxed (it runs the user's CLIs) and ships with Developer ID, not the App Store.
- `Engine/` is Oby's engine with no UI (the brain, jobs, the agent runners, accounts, models, Publish). The Mac app compiles it with `Mac/`, and the runner on Linux builds the same files. Keep AppKit, SwiftUI and other Apple-only frameworks out of it. The runner's API is `docs/runner-api.md`; change it in the same pull request as the code.
- One repository for every platform. The Apple apps share `Oby.xcodeproj`: the Mac app's sources are in `Mac/`, and the iPhone (`iOS/`) and Apple Watch (`Watch/`) apps join it as targets. `Android/` (phones and Wear OS, one Gradle project) and `Desktop/` (Windows and Linux) come later. Every app shows the same character from `Character/`.
- macOS ignores letter case in paths by default: `oby/` and `Oby/` would be the same folder. Never create a folder that differs from an existing one only by case.
