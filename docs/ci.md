# CI

Every workflow below runs on GitHub's hosted runners, on pull requests into `dev` and on pushes to `dev` (Restructure and Plug-ins: only when a pull request or push touches the paths they check; Restructure also by hand). Nothing else triggers them, and no machine of ours is involved. A newer push to the same pull request, or to `dev`, cancels the run it supersedes. Each workflow belongs to one workstream (docs/ARCHITECTURE.md, section 6), which edits only its own; this page is the lead's.

**When jobs don't start.** While the organization's GitHub Actions budget is used up, every job ends at once with "The job was not started because recent account payments have failed". Such a run **did not run**: it is not a failing check and proves nothing either way. Until runs start again, every check below is run locally (see "Running the checks locally") and pull requests say what was run and what it printed.

## obi (this repository)

| Check | Workflow | Where it is | What it does | Where it runs |
| --- | --- | --- | --- | --- |
| **E2E** | [`e2e.yml`](../.github/workflows/e2e.yml) (lead) | `dev` | Checks out this repository and obi-ai-bot/obi-sphere's `dev` next to it (obi-sphere is private: the job needs the repository secret `OBI_SPHERE_READ_TOKEN`, a token with read access to it, and fails saying so without it); git keeps no token after either checkout. When obi-sphere's `dev` has the server's fixture check (`server/scripts/check-fixtures.mjs`), runs it with `OBI_DIR=obi node obi-sphere/server/scripts/check-fixtures.mjs`: obi-sphere's server's copies of the e2e fixtures must still match this repository's, and a difference fails the job; while the script isn't there, a notice says the comparison was skipped. Installs a stable Rust toolchain, then `make e2e`: it builds `obid` from `core/` (once `core/Cargo.toml` exists), then runs the preflight and the eight steps of [e2e/SCENARIO.md](../e2e/SCENARIO.md) with stub agents. Red until Phase 1 makes every step green; the log says which step fails and why. | `ubuntu-26.04` and `macos-26` |
| **Core** | [`core.yml`](../.github/workflows/core.yml) (Rust core) | `dev` | In `core/`, against the committed `Cargo.lock`: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked` (every crate, the plug-in crates included). Caches the cargo registry and `core/target`. | `ubuntu-26.04` and `macos-26` |
| **Plug-ins** | `plugins.yml` (plug-in boundary) | open Phase 1 pull request ([#437](https://github.com/obi-ai-bot/obi/pull/437)) | On changes to `core/crates/obi-plugin-api/`, `core/crates/obi-plugin-host/`, `plugins/`, `core/Cargo.toml`, `core/Cargo.lock` or the workflow itself: makes sure the plug-in sandbox can be made on the runner (installs bubblewrap and lets it make user namespaces on Linux; runs `sandbox-exec` once on macOS), then, for those two crates, `cargo fmt --check`, `cargo clippy --all-targets --locked -- -D warnings` and `cargo test --locked` with `OBI_PLUGIN_HOST_REQUIRE_SANDBOX=1`, so a lifecycle or sandbox test that can't make its sandbox fails instead of checking the `failed` state. | `ubuntu-26.04` and `macos-26` |
| **Restructure** | `restructure.yml` (repository restructure) | open Phase 1 pull requests | No folders differ only by case; `swift build --build-tests` for the Swift package; the Mac, iPhone and Watch apps built unsigned (`CODE_SIGNING_ALLOWED=NO`) from wherever the project is (`Oby.xcodeproj` before the move, `apps/Oby.xcodeproj` after it); `MacTests` and `iOSTests` compiled with `build-for-testing`; the Mac and iPhone apps bundle the character. It runs no tests. | `ubuntu-26.04` (the case check), `xcode-27` (the rest) |
| **Runner on Linux** | [`runner-linux.yml`](../.github/workflows/runner-linux.yml) | `dev`, **disabled on GitHub** | `swift build --build-tests` and `swift test` for the runner package (`Package.swift`: `Engine/`, `Runner/`, `RunnerTests/`), with bubblewrap. | `ubuntu-26.04` |
| **Apple apps** | [`apple.yml`](../.github/workflows/apple.yml) | `dev`, **disabled on GitHub** | Builds the Mac app and runs `MacTests`, then builds `ObyPhone` (with `ObyWatch` and `ObyActivity` embedded) and runs `iOSTests` on an iPhone simulator. Signed ad hoc (see "Signing"). | `xcode-27` |

**Disabled workflows.** `apple.yml` (Apple apps) and `runner-linux.yml` (Runner on Linux) are disabled in this repository's Actions settings (`disabled_manually`): they never run, so no CI runs the apps' tests or `swift test` for the frozen engine. Those run locally. Every other workflow here (E2E, Core, Plug-ins, Restructure) is enabled.

## obi-sphere

| Check | Workflow | Where it is | What it does | Where it runs |
| --- | --- | --- | --- | --- |
| **Spec** | `spec.yml` (lead) | `dev` | `make spec-check`: the schemas compile and lint, the fixtures are reproducible, and the reference verifier judges every fixture as it says (spec/conformance/README.md). | `ubuntu-latest` |
| **Server** | `server.yml` (Sphere server) | open Phase 1 pull request | Installs `spec/` and `server/`; compares `server/e2e/fixtures/` with this repository's e2e fixtures (needs obi-sphere's secret `OBI_READ_TOKEN`, a token with read access to obi; without it the run warns and skips the comparison); the validators against the spec's schemas; types; the tests inside workerd with D1; the scripted client's tests; the conformance suite with the server's checker; scenario steps 1, 3, 5 and 7 against a local Sphere; 200 concurrent sends against a local Sphere. | `ubuntu-latest` and `macos-latest` |

No workflow in obi-sphere is disabled.

## The runners

- **Linux:** `ubuntu-26.04`, the same Ubuntu as tetrix-lab, so bubblewrap gets its user namespaces from the same AppArmor profile (`bwrap-userns-restrict`) as the runner does.
- **macOS without Xcode:** `macos-26` for E2E, Core and Plug-ins, which build nothing with Xcode.
- **obi-sphere:** Spec runs on `ubuntu-latest`, Server on `ubuntu-latest` and `macos-latest`. Neither needs a fixed image: they install Node and pnpm and build nothing with Xcode.
- **macOS with Xcode:** the project needs Xcode 27. GitHub's `xcode-27` image ships it ([image readme](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)); the workflows pin Xcode 27.0 with `DEVELOPER_DIR`. That image is a **public preview**: no SLA, and jobs can queue while GitHub balances capacity ([actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404)). When Xcode 27 reaches a GA label (`macos-27` or `macos-latest`), switch `runs-on` to it.

Both repositories are private, so macOS minutes count ten times against the plan's included minutes, Linux minutes once.

## Signing

CI has no certificates. Restructure builds the apps with `CODE_SIGNING_ALLOWED=NO`. `apple.yml`, when enabled, passes these to both of its `xcodebuild test` runs (its `SIGNING` variable):

```
CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= ENABLE_HARDENED_RUNTIME=NO
```

- `CODE_SIGN_IDENTITY=-` with `CODE_SIGN_STYLE=Manual`, an empty `DEVELOPMENT_TEAM` and an empty `PROVISIONING_PROFILE_SPECIFIER`: the apps are signed **ad hoc**, with no team and no profile, because CI has no certificate, team or profile to sign with.
- `ENABLE_HARDENED_RUNTIME=NO`: so the ad-hoc-signed Mac test host can load the test bundle. Hardened runtime matters only for notarized builds, which CI doesn't make.

Notarized builds are made on a Mac by [`scripts/release.sh`](../scripts/release.sh) ([release.md](release.md)), never in CI.

## Running the checks locally

What each workflow runs, on a machine of your own (macOS with Xcode 27.0 for the Apple apps; Linux for bubblewrap):

| Workflow | Locally |
| --- | --- |
| E2E | `make e2e` with obi-sphere checked out beside this repository (or `OBI_SPHERE_DIR`); `OBI_DIR=. node ../obi-sphere/server/scripts/check-fixtures.mjs` for the fixture comparison. |
| Core | In `core/`: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked`. |
| Plug-ins | In `core/`: `OBI_PLUGIN_HOST_REQUIRE_SANDBOX=1 cargo test --locked -p obi-plugin-api -p obi-plugin-host`, on Linux with bubblewrap able to make user namespaces, and on macOS. |
| Restructure | The case check from `restructure.yml`; `swift build --build-tests`; the three apps with `xcodebuild … CODE_SIGNING_ALLOWED=NO build`, and `MacTests` and `iOSTests` with `build-for-testing`. |
| Apple apps | `xcodebuild -project Oby.xcodeproj -scheme Oby -destination 'platform=macOS' <the signing flags above> test`, and the same with `-scheme ObyPhone` and an iPhone simulator. |
| Runner on Linux | `swift test` (on Linux, with bubblewrap). |
| obi-sphere Spec, Server | `make spec-check`; in `server/`, the commands in its README (`pnpm test`, `pnpm run conformance`, …). |
