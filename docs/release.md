# Releasing Oby

Oby ships as a notarized `.dmg` that updates itself (#282, part of F4 #8). A release runs on a Mac with Xcode 27, from [`scripts/release.sh`](../scripts/release.sh), with credentials in the keychain and nothing in git. GitHub Actions has no minutes for this ([ci.md](ci.md)), so there's no release workflow.

Teammates install the DMG once, without a Gatekeeper warning, and from then on the app checks `https://downloads.oby.deskree.com/appcast.xml` every 6 hours, downloads a new version quietly and installs it when it quits. Once one is downloaded, the menu-bar menu offers **Update ready · Restart**, which installs it and relaunches Oby (after this Mac's check for the runner, if one runs). **Check for Updates…** in the menu-bar menu and the app menu asks right away, and Settings › About says the version.

## One signing config

[`apps/config/Signing.xcconfig`](../apps/config/Signing.xcconfig) is the one place every target reads its signing from, in Debug and Release:

| Setting | Today | What it is |
| --- | --- | --- |
| `OBY_TEAM_ID` | `3UV9W5SV7W` (Deskree) | Every target's `DEVELOPMENT_TEAM`. Switching every app to the Deskree team is this one line. |
| `OBY_MAC_BUNDLE_ID` | `com.deskree.oby` | The Mac app (`.tests` for MacTests). |
| `OBY_IPHONE_BUNDLE_ID` | `com.deskree.oby` | The iPhone app (one App ID with the Mac app's; `.watchkitapp` and `.watchkitapp.widget` for the Watch) (`.activity` for the Live Activity, `.tests` for iOSTests). See [apps/ios/app/README.md](../apps/ios/app/README.md). |
| `OBY_APPCAST_URL` | `https://downloads.oby.deskree.com/appcast.xml` | Where the Mac app looks for updates (`SUFeedURL`). Hosting is this one setting. |
| `OBY_SPARKLE_PUBLIC_KEY` | `rcgwHqm6…YP34=` (generated 2026-10-20) | Sparkle's EdDSA public key (`SUPublicEDKey`). Its private half is in the release Mac's login keychain; every update must be signed with it, so export a copy (`generate_keys -x <file>`) to a safe place. |

To override any of them on one Mac, write it in `apps/config/Signing.local.xcconfig` (gitignored, included at the end). CI's command-line flags still win over both ([ci.md, Signing](ci.md#signing)).

The Mac app keeps the hardened runtime on, isn't sandboxed (it runs the user's CLIs, [AGENTS.md](../AGENTS.md)) and has one entitlement, the microphone, in [`apps/mac/app/Oby.entitlements`](../apps/mac/app/Oby.entitlements). Nothing else it does needs one under the hardened runtime: it runs CLIs as child processes through the login shell, the `oby://` character loads in WebKit's own process, screenshots go through ScreenCaptureKit, and it sends no Apple Events.

## What Dima does, once

In [developer.apple.com](https://developer.apple.com/account) and [App Store Connect](https://appstoreconnect.apple.com), as Deskree's Account Holder:

1. **A Developer ID Application certificate.** Certificates, Identifiers & Profiles › Certificates › +, *Developer ID Application*. Only the Account Holder can create one. Download it, add it to Keychain Access, then export it (the certificate with its private key) as a `.p12` with a password, for the release Mac.
2. **An App Store Connect API key for notarization.** App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys › +, with the **Developer** role. Download the `.p8` (it downloads once) and note its **Key ID** and the **Issuer ID** at the top of the page.
3. **The Team ID.** Membership details, in the developer account.

Hand the `.p12` and its password, the `.p8`, the Key ID, the Issuer ID and the Team ID over privately, never in git, an issue or a chat that's kept.

## What we do with them, once, on the release Mac

1. **Import the certificate.** Double-click the `.p12` and give its password. `security find-identity -v -p codesigning` lists `Developer ID Application: Deskree … (TEAM)`.
2. **Store the notarization credentials in the keychain.** `release.sh` uses the profile `oby-notary` (or `OBY_NOTARY_PROFILE`):

   ```sh
   xcrun notarytool store-credentials oby-notary --key ~/Downloads/AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER-UUID
   ```

   Then delete the `.p8` from Downloads: the keychain has it.
3. **Generate Sparkle's keys.** Sparkle's tools come with the package Xcode checked out; the first build of the `Oby` scheme fetches them:

   ```sh
   bin="$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/artifacts/sparkle/Sparkle/bin' | head -n 1)"
   "$bin/generate_keys"
   ```

   `generate_keys` keeps the private key in the login keychain (it prints nothing of it) and prints the public key. Put the public key in `apps/config/Signing.xcconfig` as `OBY_SPARKLE_PUBLIC_KEY`, replacing the placeholder, and commit. To release from another Mac later, `generate_keys -x key.private` exports the private key for `generate_keys -f key.private` there; delete the file afterwards. Keep a copy of the private key somewhere safe: a lost key means shipped Obys can't verify any future update.
4. **Set the team.** `OBY_TEAM_ID` in `apps/config/Signing.xcconfig`, in the same commit. Nothing else in the project names a team.
5. **Hosting.** Create the R2 bucket (`oby-downloads`, or set `OBY_R2_BUCKET`) and point `downloads.oby.deskree.com` at it as a public custom domain in Cloudflare. For the upload, either `brew install wrangler` and `wrangler login`, or an R2 API token (Account › R2 › Manage API tokens, Object Read & Write on the bucket) kept in the keychain so `aws` can use it:

   ```sh
   security add-generic-password -s oby-r2 -a account-id -w CLOUDFLARE-ACCOUNT-ID
   security add-generic-password -s oby-r2 -a access-key-id -w ACCESS-KEY-ID
   security add-generic-password -s oby-r2 -a secret-access-key -w SECRET-ACCESS-KEY
   ```

   `.env.local` at the repository root (gitignored) with `OBY_R2_ACCOUNT_ID`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` works too.
6. **Both architectures.** Homebrew's `rust` builds Apple Silicon only, and a release needs obid for both. Install `rustup` from Homebrew (`brew install rustup`), then `$(brew --prefix rustup)/bin/rustup toolchain install stable --profile minimal -t aarch64-apple-darwin,x86_64-apple-darwin`, and link its `cargo`, `rustc` and `rustup` into `~/.cargo/bin`, which the Bundle obid phase looks in first. Leave `~/.cargo/bin` off your shell's PATH if you build obid day to day with Homebrew's `rust`.
7. **Optional:** `brew install create-dmg` for a DMG with a background (`apps/icon/dmg-background.png`, when it exists). Without it, the DMG is plain: Oby.app and an Applications link.

## A release

On a clean `dev` (or `main`, once F4's test list passes):

```sh
scripts/release.sh 0.2.0
```

In order, it:

0. **Runs the checks**, `swift test` and the Mac app's `MacTests`, side by side through [`scripts/tested.sh`](../scripts/tested.sh), skipping each one that already passed on this Mac on the same files (see "Tests a release skips"). `--full` runs both whatever the records say. Nothing is built unless they pass.
1. **Bumps the version**, once it has checked that the checkout is still clean and `HEAD` hasn't moved since it started. `MARKETING_VERSION` becomes `0.2.0` and `CURRENT_PROJECT_VERSION` the git commit count including the bump commit, so build numbers only grow; both in `apps/Oby.xcodeproj`, committed as `chore(release): Oby 0.2.0 (N)`.
2. **Archives the `Oby` scheme** (Release) and exports it with Developer ID ([`apps/ExportOptions-DeveloperID.plist`](../apps/ExportOptions-DeveloperID.plist), `teamID` filled from `OBY_TEAM_ID`), on warm caches (see "Warm builds"). Then it checks that the checkout is still clean at the bump commit, the version, that the app and obid hold arm64 and x86_64 (`lipo`), every signature (`codesign --deep --strict`), and `obi-vm` (see "The guest image"), and scans the app with gitleaks before anything leaves the Mac.
3. **Notarizes the app** (`xcrun notarytool submit --keychain-profile oby-notary --wait`), staples the ticket, validates it and checks it with `spctl`. While Apple works, it scans the commits since the last `v*` tag with gitleaks, and gathers the release notes and the published appcast.
4. **Builds `Oby-0.2.0.dmg`** from the stapled app, checks the app in it with `codesign`, signs the DMG with the Developer ID, notarizes and staples it too, then checks the DMG (`stapler validate`, `hdiutil verify`, `spctl`), the app in it (`spctl`) and a copy of the app with a quarantine flag (`spctl`, `stapler validate`).
5. **Signs it for Sparkle** with `sign_update` and the EdDSA key in the keychain.
6. **Writes the appcast entry**: version, build, date, the DMG's URL, length and signature, and release notes from the merged pull requests since the last `v*` tag (`--notes <file>` gives your own, one line per item). It's put on top of the appcast published already, checked with `xmllint` and scanned with gitleaks.
7. **Uploads** the DMG to R2, downloads it back from its public URL and compares the size and SHA-256 with the file it built, and only then uploads `appcast.xml`.
8. **Tags `v0.2.0`.**

Each step prints how long the release has run (`==> [m:ss]`). Everything lands in `build/release/` (gitignored), with `swift-test.log`, `mac-tests.log`, `archive.log`, `export.log`, `notarize-app.log` and `notarize-dmg.log` when something fails. If the release stops part way, it stops what it started in the background (the checks, a notarization) and detaches any DMG it mounted. The script prints no credential and never runs with `set -x`.

Then push the commit and the tag: `git push origin HEAD v0.2.0`. Shipped Obys pick the update up within 6 hours; **Check for Updates…** gets it now.

### The guest image

Sharing a Mac (#797) runs teammates' jobs in a VM. `obi-vm` is built into the app by the "Bundle obi-vm" build phase (`apps/mac/app/Tools/bundle-obi-vm.sh`): arm64, the virtualization entitlement, and the SHA-256s of the image [`core/obi-vm/image.json`](../core/obi-vm/image.json) pins built in. The image itself (a 665 MB disk, about 170 MB zstd-compressed: no docs or translations, only the kernel modules the guest loads, no Codex) is published once per new image, compressed, and obid fetches it when an owner turns sharing on. `release.sh` checks that `obi-vm` is arm64, has the entitlement and answers `obi-vm image` with the pinned hashes and sizes, and that the pinned image's `.zst` files are published at `https://downloads.oby.deskree.com/vm/<root.img's SHA-256>/`, each its pinned size (a dry run only warns).

A new image (a change in `core/obi-vm/image/`):

```sh
core/obi-vm/image/build.sh <dir>            # Docker (OrbStack); the files, their .zst copies and <dir>/image.json
cp <dir>/image.json core/obi-vm/image.json  # commit it in the change's pull request
scripts/publish-vm-image.sh <dir>           # checks the files against the pin, uploads them, reads them back
```

### Tests a release skips

The coordinator's merge ritual already runs the full suites on the exact tree it merges, on this Mac. If it runs them through [`scripts/tested.sh`](../scripts/tested.sh), `release.sh` doesn't run them again on the same files:

- **The ritual runs** `scripts/tested.sh run mac-tests` instead of its own `xcodebuild … test` for MacTests, and `scripts/tested.sh run swift-test` instead of `swift test` (when Engine/ or RunnerTests/ change), from the checkout it's about to merge. `tested.sh` runs the suite's one command itself (MacTests: the `Oby` scheme on `platform=macOS`, with the release's DerivedData and cargo target, so it warms the release's caches too; run one MacTests at a time, since they share that DerivedData) and records it only when the command exits 0 and the checkout's fingerprint is the same before and after the run. There's no command to record a suite without running it. Squash-merging keeps the files, so the record holds for `dev` once it's merged. `release.sh` runs its checks through `tested.sh` too, so a release that fails after the checks doesn't run them again.
- **A record** is `~/Library/Application Support/Oby-release/tested/<suite>/<fingerprint>`: the fingerprint of the files, the suite, the toolchain (Xcode, Swift, and the Rust that builds obid), the commit and the time, with an HMAC-SHA256 whose key is in the login keychain (service `oby-release-tested`, made on the first record). A record edited or written by hand, or by an agent boxed away from the keychain, doesn't verify.
- **The fingerprint** is `git ls-tree -r HEAD` hashed, with the `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` lines of `project.pbxproj` normalized, so the release's version bump doesn't count as a change, plus the SHA-256 of the gitignored `apps/config/Signing.local.xcconfig` when there is one. `mac-tests` covers the whole tree; `swift-test` only the Swift package's inputs: `Package.swift`, `Package.resolved`, and every target's `path:` read from `Package.swift` (SwiftPM's default `Sources/` and `Tests/` too), so a merge that didn't touch them keeps an earlier record valid. A checkout with any change, untracked files included (`git status --porcelain --untracked-files=all`), is never run, recorded or matched; a dry run on such a checkout runs every check and records none.
- **A suite runs** when there's no record for these files, the record doesn't verify, the toolchain changed, the checkout has changes, or `--full` is given. The release prints which suites it skipped and why (`skipped mac-tests: tree 3f2a… passed it on this Mac at …`), or why each one runs.

`scripts/tested.sh check <suite>` says whether the current checkout counts as tested, without running anything.

### Warm builds

The archive no longer starts cold. `~/Library/Caches/Oby-release/<toolchain>/` keeps the release's `DerivedData` (Xcode's build and its Swift packages) and `cargo/`, obid's cargo target directory (`OBY_CARGO_TARGET_DIR`, which the Bundle obid phase reads; it builds both architectures in one cargo run). `<toolchain>` is a hash of `xcodebuild -version`, `swift --version` and `rustc -vV`, so a new Xcode or Rust starts a fresh set and the old one is deleted. Before each archive the assembled `Oby.app` in DerivedData is removed, so nothing a previous build left in the bundle reaches this one. What stays warm is obid's Rust (cargo rebuilds only what changed: 0.6 s when nothing did, against about 4 minutes cold for both architectures), the Swift packages and the module caches; `xcodebuild archive` compiles Oby's own Swift again every time (whole-module, about 3 minutes for both architectures), which a release with new code needs anyway. After the export, `release.sh` checks the version, both architectures in the app and in obid (`lipo -archs`), and every nested signature. To start cold anyway, `rm -rf ~/Library/Caches/Oby-release`.

### Notarization: the app, then the DMG

The release still notarizes twice, so the app carries its own ticket. Notarizing the DMG alone is enough online: Apple's notary service "generates a ticket for the top-level file that you specify, as well as for each nested file" ([Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)), and on 2026-10-21 `spctl` accepted the app in a DMG notarized alone and a quarantined copy of it, both `source=Notarized Developer ID`. But only the DMG gets its ticket stapled that way: an app copied out of it carries none (`stapler validate` says so), and a Mac that is offline the first time it opens that copy has nothing to check it against, which wasn't tested on a fresh Mac. So the app is notarized and stapled first (about a minute and a half on 2026-10-21), and the DMG is built from the stapled app. The app's notarization overlaps the history scan and the release notes; the DMG's runs alone, since Sparkle signs the stapled DMG.

### Trying it today

```sh
scripts/release.sh 0.2.0 --dry-run
```

A dry run needs no certificate, key or bucket: it archives with ad hoc signing (CI's flags, hardened runtime on), notarizes and uploads nothing, signs the DMG ad hoc, uses a placeholder Sparkle signature when the keychain has no key, writes the appcast to `build/release/appcast.xml`, checks it with `xmllint` and prints the entry. It commits and tags nothing, and leaves the project untouched. Put its output in the pull request.

## Moving the iPhone and Watch apps to the Deskree team

Done on 2026-10-20: every app signs with Deskree's team (`3UV9W5SV7W`) and the iPhone app is `com.deskree.oby`. The beta on Wellington's team (`dev.wellprado.oby`, "Oby Beta") stays where it is and gets no new builds. What the move needed, for the record:

The Mac app only needs `OBY_TEAM_ID`. The iPhone and Watch apps need more, because their identifiers and pushes belong to the account:

1. **Register the App IDs** under the Deskree team: the iPhone app, its Live Activity (`….activity`), the Watch app and its widget, and the **App Group** they share ([apps/ios/app/README.md](../apps/ios/app/README.md) has today's ids). Either keep `dev.wellprado.oby` as `OBY_IPHONE_BUNDLE_ID`, or set a new one there (an App Store record's bundle id stays with its account, so the real app starts fresh on Deskree's).
2. **A new APNs key** (Keys › +, Apple Push Notifications service) for the Live Activity pushes. The runner's key `8TP9AXUB64` belongs to the current team and its `.p8` lives on tetrix-lab, so the runner's `apns/apns.json` needs the new Team ID and Key ID, with the new `.p8` beside it ([Runner/README.md](../Runner/README.md), Live Activity push).
3. **Set `OBY_TEAM_ID`** and commit; every target follows.
4. **Xcode Cloud**: the workflows for `ObyPhone` and `ObyWatch` move to the Deskree team's App Store Connect, with the new app records.
