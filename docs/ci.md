# Checks

GitHub Actions doesn't run for obi-ai-bot's repositories (there's no Actions budget), so their workflows were removed on 2026-10-23. Every check runs on a Mac: workers run the checks for what they changed, the coordinator runs the full suites before a merge (the merge ritual), and every pull request says what was run and what it printed.

## What runs

| Area | On a Mac |
| --- | --- |
| Rust core | In `core/`: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked` (workers: only the test binaries they touched; before a merge: all of obid, with `--no-fail-fast`). |
| Plug-ins | In `core/`: `OBI_PLUGIN_HOST_REQUIRE_SANDBOX=1 cargo test --locked -p obi-plugin-api -p obi-plugin-host`. |
| Swift package | `scripts/tested.sh run swift-test` when `Engine/`, `Runner/` or `RunnerTests/` change. |
| Mac app | `scripts/tested.sh run mac-tests` (the `Oby` scheme's MacTests; one run at a time). |
| iPhone and Watch | `xcodebuild -project apps/Oby.xcodeproj -scheme ObyPhone -destination 'platform=iOS Simulator,name=iPhone 17' test`. |
| E2E | `make e2e` with obi-sphere checked out beside this repository (or `OBI_SPHERE_DIR`). |
| Secrets | `gitleaks git --log-opts=origin/dev..HEAD`. |
| obi-sphere | In `server/`: `pnpm run check`, `pnpm test`, `pnpm run check:validators`, `pnpm run test:client`, and `pnpm run conformance` with `spec/` installed. |

`scripts/tested.sh` records a suite that passed on a clean checkout, so `scripts/release.sh` doesn't run it again (docs/release.md).

## Signing

The checks need no certificates. The Mac checks (docs/runner-api.md, "Mac check") and `scripts/release.sh`'s test step pass these to `xcodebuild test`:

```
CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= ENABLE_HARDENED_RUNTIME=NO
```

- `CODE_SIGN_IDENTITY=-` with `CODE_SIGN_STYLE=Manual`, an empty `DEVELOPMENT_TEAM` and an empty `PROVISIONING_PROFILE_SPECIFIER`: the apps are signed **ad hoc**, with no team and no profile, because CI has no certificate, team or profile to sign with.
- `ENABLE_HARDENED_RUNTIME=NO`: so the ad-hoc-signed Mac test host can load the test bundle. Hardened runtime matters only for notarized builds, which the checks don't make.

Notarized builds are made on a Mac by [`scripts/release.sh`](../scripts/release.sh) ([release.md](release.md)), never by a check.
