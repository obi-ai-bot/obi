# CI

Three workflows run on every pull request into `dev` and on every push to `dev`, so a merge into `dev` can wait for them (#66). Nothing else triggers them. A newer push to the same pull request, or to `dev`, cancels the run it supersedes.

| Check | Workflow | What it does | Where it runs | How long |
| --- | --- | --- | --- | --- |
| **Runner on Linux** | [`runner-linux.yml`](../.github/workflows/runner-linux.yml) | Installs bubblewrap and SQLite's headers, sets up Swift 6.4.0 with swiftly, then `swift build --build-tests` and `swift test` for the runner package (`Package.swift`: `Engine/`, `Runner/`, `RunnerTests/`). | Hosted, `ubuntu-26.04` (tetrix-lab's Ubuntu) | About 9–13 min with an empty cache, 7–9 min with one (estimated, see below) |
| **Mac and iPhone** | [`apple.yml`](../.github/workflows/apple.yml) | Builds the Mac app and runs `MacTests`, then builds `ObyPhone` (with `ObyWatch` and `ObyActivity` embedded) and runs `iOSTests` on an iPhone 17 simulator. Signed ad hoc. | Hosted, `xcode-27` (Xcode 27.0 on macOS 27, Apple silicon) | About 10–16 min (estimated, see below) |
| **E2E** | [`e2e.yml`](../.github/workflows/e2e.yml) | Checks out obi-ai-bot/obi-sphere's `dev` next to this repository (it is private: the job needs the repository secret `OBI_SPHERE_READ_TOKEN`, a token with read access to it, and fails saying so without it), installs a stable Rust toolchain, then `make e2e`: it builds `obid` from `core/` (once `core/Cargo.toml` exists), then runs the preflight and the eight steps of [e2e/SCENARIO.md](../e2e/SCENARIO.md) with stub agents. Red until Phase 1 makes every step green; the log says which step fails and why. | Hosted, `ubuntu-26.04` and `macos-26` | Not measured yet |

To gate merges on the first two, add them, by these names, as required status checks in `dev`'s branch rules (Settings › Rules).

## Where it runs

Every job runs on GitHub's hosted runners; no machine of ours is involved. Runner on Linux and Mac and iPhone are described below; E2E runs `make e2e` once on `ubuntu-26.04` and once on `macos-26` (it builds nothing with Xcode, so it needs no `xcode-27` image).

- **Linux:** `ubuntu-26.04`, the same Ubuntu as tetrix-lab, so bwrap gets its user namespaces from the same AppArmor profile (`bwrap-userns-restrict`) as the runner does. A step checks that `bwrap` runs before the tests: the bubblewrap tests skip themselves when it can't, and here they must run. If AppArmor ever blocks it, that step lifts the restriction for the run (`kernel.apparmor_restrict_unprivileged_userns=0`) and leaves a warning on the run.
- **macOS:** the project needs Xcode 27. GitHub's `macos-26` and `macos-latest` images stop at Xcode 26.6, but its `xcode-27` image ships Xcode 27.0 (default), 27.1 and 27.2 beta, with iOS 27.0 and watchOS 27.0 simulators ([image readme](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md), image 20261006 checked on 2026-10-10). The workflow pins Xcode 27.0 with `DEVELOPER_DIR`. That image is a **public preview**: no SLA, and jobs can queue while GitHub balances capacity ([actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404)). When Xcode 27 reaches a GA label (`macos-27` or `macos-latest`), switch `runs-on` to it. If the preview turns out unusable, the fallback is a self-hosted Mac labeled `oby-mac` (`runs-on: [self-hosted, oby-mac]`).

If the repository is private, macOS minutes count ten times against the plan's included minutes, Linux minutes once.

## How long each job takes

The figures below for Runner on Linux and Mac and iPhone were estimated before either workflow first ran on GitHub; replace them with the times of green runs on `dev`. E2E has no figure: it is red by design until Phase 1 makes its steps green (e2e/SCENARIO.md).

**Runner on Linux.** Measured on tetrix-lab (16 cores, Swift 6.4.0) on 2026-10-10:

| Step | tetrix-lab |
| --- | --- |
| Set up Swift with swiftly (download, verify, extract) | 35 s |
| `swift build --build-tests`, nothing built yet (fetching the dependencies took about 30 s of it) | 202 s |
| The same, with the dependencies already built (Oby's own targets only) | 134–139 s |
| `swift test` (146 tests in 27 suites) | 7 s |

A hosted Linux runner has 4 cores, so the build takes roughly 2.5–3.5 times as long. Estimate: 9–13 min with an empty cache, 7–9 min when the cache restores the dependencies. Oby's own targets are most of the build, so the cache saves less than it would in a project with lighter code.

**Mac and iPhone.** Estimated, with no measurement yet: about 4–7 min for the Mac app and `MacTests`, and 5–8 min for `ObyPhone`, `ObyWatch` and `ObyActivity`, booting the simulator and `iOSTests`. Add queueing time while `xcode-27` is in preview.

## Caching

- **Linux:** `.build` and `~/.cache/org.swift.swiftpm`, keyed by the runner's architecture, the Swift version and `Package.resolved`; a run with a new `Package.resolved` starts from the newest cache for the same Swift. That keeps the dependencies' checkouts and builds; Oby's own targets rebuild from source.
- **macOS:** nothing. `apps/Oby.xcodeproj`'s one Swift package dependency, Sparkle (the Mac app's updater, #282), is a prebuilt binary that resolves in seconds.

## Signing

CI has no certificates. Both Apple builds pass `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=`, so they're signed ad hoc with no team or profile, and `ENABLE_HARDENED_RUNTIME=NO`, so the ad-hoc-signed Mac test host can load the test bundle. Hardened runtime matters only for notarized builds, which CI doesn't make: [`scripts/release.sh`](../scripts/release.sh) makes them on a Mac ([release.md](release.md)).

Every target's team and bundle id come from [`apps/config/Signing.xcconfig`](../apps/config/Signing.xcconfig) (`OBY_TEAM_ID`, `OBY_MAC_BUNDLE_ID`, `OBY_IPHONE_BUNDLE_ID`), which the project reads as its base configuration. Settings on the command line beat an xcconfig, so CI's flags above still win.

## The `Oby` scheme

`MacTests` run through the `Oby` scheme, which isn't shared in the project: only `ObyPhone` and `ObyWatch` are. Xcode makes it on each Mac, but a fresh checkout has none, so the workflow copies [`.github/ci/Oby.xcscheme`](../.github/ci/Oby.xcscheme) into the project when it has no shared `Oby` scheme. Once the project shares one (Product › Scheme › Manage Schemes, Shared), the project's wins, and the copy in `.github/ci/` can go.
