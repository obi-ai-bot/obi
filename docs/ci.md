# CI

Every workflow below runs on GitHub's hosted runners, on pull requests into `dev` and on pushes to `dev` (Restructure: on pull requests that touch the folders it moves, and by hand). Nothing else triggers them, and no machine of ours is involved. A newer push to the same pull request, or to `dev`, cancels the run it supersedes. Each workflow belongs to one workstream (docs/ARCHITECTURE.md, section 6), which edits only its own; this page is the lead's.

## obi (this repository)

| Check | Workflow | Where it is | What it does | Where it runs |
| --- | --- | --- | --- | --- |
| **E2E** | [`e2e.yml`](../.github/workflows/e2e.yml) (lead) | `dev` | Checks out obi-ai-bot/obi-sphere's `dev` next to this repository (it is private: the job needs the repository secret `OBI_SPHERE_READ_TOKEN`, a token with read access to it, and fails saying so without it; the token is not kept after that checkout). Checks that obi-sphere's server's copies of the e2e fixtures still match this repository's (`OBI_DIR=obi node obi-sphere/server/scripts/check-fixtures.mjs`), or says with a notice that the script isn't in obi-sphere's `dev` yet. Installs a stable Rust toolchain, then `make e2e`: it builds `obid` from `core/` (once `core/Cargo.toml` exists), then runs the preflight and the eight steps of [e2e/SCENARIO.md](../e2e/SCENARIO.md) with stub agents. Red until Phase 1 makes every step green; the log says which step fails and why. | `ubuntu-26.04` and `macos-26` |
| **Core** | `core.yml` (Rust core) | open Phase 1 pull request | In `core/`, against the committed `Cargo.lock`: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked`. Caches the cargo registry and `core/target`. | `ubuntu-26.04` and `macos-26` |
| **Restructure** | `restructure.yml` (repository restructure) | open Phase 1 pull requests | No folders differ only by case; `swift build --build-tests` for the Swift package; the Mac, iPhone and Watch apps built unsigned (`CODE_SIGNING_ALLOWED=NO`) from wherever the project is (`Oby.xcodeproj` before the move, `apps/Oby.xcodeproj` after it); `MacTests` and `iOSTests` compiled with `build-for-testing`; the Mac and iPhone apps bundle the character. It runs no tests. | `ubuntu-26.04` (the case check), `xcode-27` (the rest) |
| **Plug-ins** | none yet | | The plug-in boundary has added no workflow of its own. | |
| **Runner on Linux** | [`runner-linux.yml`](../.github/workflows/runner-linux.yml) | `dev`, **disabled on GitHub** | `swift build --build-tests` and `swift test` for the runner package (`Package.swift`: `Engine/`, `Runner/`, `RunnerTests/`), with bubblewrap. | `ubuntu-26.04` |
| **Apple apps** | [`apple.yml`](../.github/workflows/apple.yml) | `dev`, **disabled on GitHub** | Builds the Mac app and runs `MacTests`, then builds `ObyPhone` (with `ObyWatch` and `ObyActivity` embedded) and runs `iOSTests` on an iPhone simulator. Signed ad hoc. | `xcode-27` |

`apple.yml` and `runner-linux.yml` are disabled in this repository's Actions settings: they never run, so no CI runs the apps' tests or `swift test` for the frozen engine. Those run locally (`swift test`; `xcodebuild test` on a Mac with Xcode 27).

## obi-sphere

| Check | Workflow | Where it is | What it does | Where it runs |
| --- | --- | --- | --- | --- |
| **Spec** | `spec.yml` (lead) | `dev` | `make spec-check`: the schemas compile and lint, the fixtures are reproducible, and the reference verifier judges every fixture as it says (spec/conformance/README.md). | `ubuntu-latest` |
| **Server** | `server.yml` (Sphere server) | open Phase 1 pull request | Installs `spec/` and `server/`; compares `server/e2e/fixtures/` with this repository's e2e fixtures (needs obi-sphere's secret `OBI_READ_TOKEN`, a token with read access to obi; without it the run warns and skips the comparison); the validators against the spec's schemas; types; the tests inside workerd with D1; the scripted client's tests; the conformance suite with the server's checker; scenario steps 1, 3, 5 and 7 against a local Sphere; 200 concurrent sends against a local Sphere. | `ubuntu-latest` and `macos-latest` |

## The runners

- **Linux:** `ubuntu-26.04`, the same Ubuntu as tetrix-lab, so bubblewrap gets its user namespaces from the same AppArmor profile (`bwrap-userns-restrict`) as the runner does.
- **macOS without Xcode:** `macos-26` for E2E and Core, which build nothing with Xcode.
- **macOS with Xcode:** the project needs Xcode 27. GitHub's `xcode-27` image ships it ([image readme](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)); the workflows pin Xcode 27.0 with `DEVELOPER_DIR`. That image is a **public preview**: no SLA, and jobs can queue while GitHub balances capacity ([actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404)). When Xcode 27 reaches a GA label (`macos-27` or `macos-latest`), switch `runs-on` to it.

Both repositories are private, so macOS minutes count ten times against the plan's included minutes, Linux minutes once.

## Signing

CI has no certificates. Restructure builds the apps with `CODE_SIGNING_ALLOWED=NO`; `apple.yml`, when enabled, signs ad hoc with no team or profile. Notarized builds are made on a Mac by [`scripts/release.sh`](../scripts/release.sh) ([release.md](release.md)), never in CI.
