# Apple builds for agents (#118): spike

Oby's agents run on tetrix-lab, a Linux machine with no Xcode and no Apple SDK. On 2026-10-10 and 11 every iPhone, Watch and Mac change was written and reviewed without being compiled: reviews kept asking for "a build in Xcode", and three Mac-only breakages (a missing `OSLog` import, a duplicate `JobList`) reached review. The goal: an agent changing an Apple app sees the compiler's errors and failing tests **in its own round**, and fixes them before it publishes.

GitHub Actions is out: the Deskree org is out of Actions minutes (2026-10-11), so the workflows from #97 stay disabled.

## The options

### (a) The agent asks the Mac check runner, mid-round (built: `oby-check apple`)

The agent runs `oby-check apple` in its sandbox. The runner queues an Apple check of the job's worktree commit like #114's merge checks; the user's Mac, which already follows the runner, takes it first, fetches the commits from the runner as a git bundle (they aren't on GitHub yet), builds `Oby` with MacTests and `ObyPhone` (with `ObyWatch`) with iOSTests, and reports. The command prints the compiler's errors and failing tests. Details: docs/runner-api.md, "Apple check".

- **Speed.** No clone, no package resolution, a warm DerivedData shared across checks: an incremental build and test of both apps should take a few minutes on an Apple-silicon Mac (not measured yet; a cold first build takes longer). Feedback lands in the same round, so the agent fixes it before it publishes. One Mac runs one check at a time; a merge check in progress goes first (up to 70 minutes at worst, from its timeouts). The wait counts against the job's limits (a round's turn may take 15 minutes, a job 45), so a slow cold build can use up a round: watch this on the first real jobs.
- **What it needs from the user.** Nothing new: Oby open on the Mac, following the runner, with Settings › Runner › "Build and test agents' work on this Mac" on (the default), Xcode 27 and an iPhone 17 simulator, which #114 already needs.
- **Cost.** None in money. The Mac's CPU and battery while it builds; agent turns spent waiting (`oby-check` waits up to 2 minutes per call by default, then the agent runs it again).
- **Security.** The Mac runs the agent's code (Xcode build phases, test hosts) **before Oby's review has read it**, as the user, with the user's access to the Mac: files, keychain prompts, the network. The merge check (#114) at least had a review in front of it; this doesn't. What limits it: the code comes only from the user's own agents working on the user's own repository; text from GitHub reaches them only as quoted data; commands get no GitHub login, no vault secret and a throwaway `OBY_HOME`; and the setting turns it off. A prompt-injected agent could still write a build phase that reads `~/`. Running the steps as a separate macOS user, or in a VM (Tart/Virtualization.framework), is the upgrade if this matters more. Unrelated to this but worth knowing: the runner trusts `Tailscale-User-Login`, and agents in bubblewrap can reach `127.0.0.1:7777` and set that header themselves (Engine/Jobs.swift notes it as a ponytail). The agent endpoints added here use a per-job token, but the owner's endpoints are only as safe as that header. A Unix socket for `tailscale serve`, or a separate Unix user for agents, would close it.
- **When the Mac is off.** Nothing runs. After a minute with no Mac taking the check (and none busy with another), `oby-check` says so and exits 2. The agent is told to carry on and say in its summary that the Apple apps weren't built, and the reviewer gets no result, so it can still ask for a build.

### (b) An Xcode Cloud workflow that builds and tests each pull request

Apple's machines build and test every pull request into `dev` and report to GitHub as checks; Oby reads them.

- **Speed.** Slower per run: queueing, a fresh clone, package resolution and a clean build each time, on shared machines. Expect roughly 10–25 minutes per pull request with both test actions running in parallel (not measured on this repository). It runs on what's **pushed**, so it can't help an agent mid-round: the agent writes, publishes, and only then learns it doesn't compile. It catches breakage before merge and before review, not before publishing.
- **What it needs from the user.** One-time setup by the Account Holder or an Admin: an App Store Connect app record for the product, the Xcode Cloud GitHub app installed on deskree-inc with access to the repository, and the shared schemes committed (see below). Oby needs no new credential: it reads the checks with its `gh` login.
- **Cost.** The Apple Developer Program includes 25 compute hours a month; more is US$49.99 for 100 hours, US$99.99 for 250, US$399.99 for 1,000 ([Apple](https://developer.apple.com/xcode-cloud/get-started)). Two test actions of about 15 minutes each, on each push to a pull request, is about 0.5 hours per push: 25 hours covers about 50 pushes a month, which Oby's loop (review rounds push again) would pass quickly. Plan on the 100-hour tier.
- **Security.** The best of the three: pull request code runs on Apple's machines, never on the user's Mac. The GitHub app gets read access to the code and writes check runs. Secrets: none needed (no signing for simulator and macOS tests with Xcode Cloud's managed signing).
- **When the Mac is off.** It doesn't matter: it runs anyway.

**What to set in App Store Connect › Xcode Cloud** (or Xcode › Product › Xcode Cloud › Create Workflow, same settings):

1. Before you start: Xcode Cloud sees only shared schemes. `Oby`, `ObyPhone` and `ObyWatch` are shared already (`apps/Oby.xcodeproj/xcshareddata/xcschemes/`); keep them that way. Create the product on the app record for the iPhone app (`ObyPhone`); the Mac app's scheme is used as an action in the same workflow.
2. **General:** name `PR checks`, the deskree-inc/oby repository, "Restrict editing" on.
3. **Environment:** Xcode 27 (Latest Release), macOS Latest; "Clean" off (builds reuse what Xcode Cloud caches; turn it on if a stale build ever passes).
4. **Start condition:** "Pull Request Changes", source branch "Any branch" (or custom: `oby/*`), target branch `dev`. Files and folders: start only when something changes in `apps/ios/app/`, `apps/watch/`, `apps/mac/app/`, `apps/shared/`, `Engine/`, `apps/ios/live-activity/`, `character/`, `apps/ios/tests/`, `apps/mac/tests/` or `apps/Oby.xcodeproj`. "Auto-cancel builds" on, so a new push cancels the run of the old one. Add no "Branch Changes" or schedule.
5. **Actions:**
   - Test: scheme `Oby`, platform macOS, destination Mac, the scheme's tests (MacTests). "Required to pass" on.
   - Test: scheme `ObyPhone`, platform iOS, destination simulator iPhone 17 (latest iOS), the scheme's tests (iOSTests; the Watch app builds as part of ObyPhone). "Required to pass" on.
   - No Archive, no TestFlight, no App Store action.
6. **Post-actions:** none (Oby reads the results; email or Slack notifications are optional).
7. Optionally, in GitHub › Settings › Branches, make both checks required on `dev`. Oby's own merge rule (docs/runner-api.md) would then read them too.

**How Oby would read the results.** Xcode Cloud reports each action as a GitHub check run on the pull request's head commit, made by its GitHub app. The runner would read them with its own `gh` login, outside the agents' sandbox, as it follows pull requests (Runner/PullRequests.swift), every three minutes:

```sh
gh api repos/deskree-inc/oby/commits/<head>/check-runs --jq '.check_runs[] | select(.app.name | test("Xcode Cloud")) | {name, status, conclusion, details_url, output: .output.summary}'
```

or `gh pr checks <pr> -R deskree-inc/oby --json name,state,bucket,link`. A check run is `queued`, `in_progress` or `completed`, with `conclusion` `success`, `failure`, `cancelled`, `timed_out` or `action_required`. Only typed fields (names, states, conclusions) would go on the job. The failing tests and compiler errors are in Xcode Cloud's report (`details_url`, App Store Connect), not in the check run's summary in a form an agent can use without signing in to App Store Connect; an agent could wait for the conclusion, but it would only learn *that* it failed. Confirm the check runs' exact names and the app's name on the first run before matching on them. Apple's forums report intermittent trouble with "Pull Request Changes" triggers in 2026 ([thread](https://developer.apple.com/forums/thread/839031)), so a missing check should read as "not run", never as passed.

### (c) Route Apple-only jobs to the Mac

Jobs that only touch Apple code run on the Mac's own Oby desk, where Xcode is, so the agent builds and tests as it goes.

- **Speed.** The fastest loop: the agent runs `xcodebuild` as often as it likes, with no queue and no round trip.
- **What it needs from the user.** The Mac on, awake and logged in with Oby open for the whole job; Claude Code and Codex signed in on the Mac too; a router that decides which jobs are "Apple-only" (most jobs touch `Engine/` as well, which the runner's `swift test` checks, so the split is fuzzy); jobs moving between desks.
- **Cost.** No money; the Mac's CPU for the whole job, not just the build.
- **Security.** The worst: on the Mac, agents run without bubblewrap (`Agents.sandboxed` passes the command through), as the user, for the whole job, not just its build. Codex keeps its own sandbox there; Claude Code has only Oby's permission policy.
- **When the Mac is off.** The job waits, or falls back to the runner and runs blind again.

## Recommendation

**(a), built in this slice.** It's the only option that puts the compiler's errors in front of the agent **in its round**, which is what the issue's first test asks for. It costs nothing, reuses #114's runner, queue, timeouts and throwaway `OBY_HOME`, and needs no new setup. Its two weak points are the Mac being off and unreviewed code running on the Mac. For the first, (b) is the natural backstop later, if the Mac turns out to be off too often: it costs about US$50 a month and gives a check that doesn't depend on the Mac. For the second, the setting turns it off, and a separate macOS user for checks is the upgrade. (c) costs the most security for a loop (a) mostly gets.

Follow-ups this slice leaves open:

- The issue's second test ("a Mac-only compile error never reaches review") still depends on the agent running `oby-check apple`. A runner-side Apple check before publishing, for jobs whose commits touch the Apple folders, would make it hold whatever the agent does.
- Measure a real check's time, cold and warm, against the 15-minute turn limit.
- The rest of #118 (clear actions when a job needs you, no stale verdicts) is a separate slice.
