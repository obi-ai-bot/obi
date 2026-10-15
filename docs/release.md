# Releasing Oby

Oby ships as a notarized `.dmg` that updates itself (#282, part of F4 #8). A release runs on a Mac with Xcode 27, from [`scripts/release.sh`](../scripts/release.sh), with credentials in the keychain and nothing in git. GitHub Actions has no minutes for this ([ci.md](ci.md)), so there's no release workflow.

Teammates install the DMG once, without a Gatekeeper warning, and from then on the app checks `https://downloads.oby.deskree.com/appcast.xml` every 6 hours, downloads a new version quietly and installs it when it quits. Once one is downloaded, the island offers **Update ready · Restart**, which installs it and relaunches Oby (after this Mac's check for the runner, if one runs). **Check for Updates…** in the menu-bar menu and the app menu asks right away, and Settings › About says the version.

## One signing config

[`apps/config/Signing.xcconfig`](../apps/config/Signing.xcconfig) is the one place every target reads its signing from, in Debug and Release:

| Setting | Today | What it is |
| --- | --- | --- |
| `OBY_TEAM_ID` | `PQKAL8E36D` | Every target's `DEVELOPMENT_TEAM`. Switching every app to the Deskree team is this one line. |
| `OBY_MAC_BUNDLE_ID` | `com.deskree.oby` | The Mac app (`.tests` for MacTests). |
| `OBY_IPHONE_BUNDLE_ID` | `dev.wellprado.oby` | The iPhone app (`.activity` for the Live Activity, `.tests` for iOSTests). See [apps/ios/app/README.md](../apps/ios/app/README.md). |
| `OBY_APPCAST_URL` | `https://downloads.oby.deskree.com/appcast.xml` | Where the Mac app looks for updates (`SUFeedURL`). Hosting is this one setting. |
| `OBY_SPARKLE_PUBLIC_KEY` | a placeholder of 32 zero bytes | Sparkle's EdDSA public key (`SUPublicEDKey`). With the placeholder, Oby starts fine and accepts no update, and `release.sh` refuses a real release. |

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
6. **Optional:** `brew install create-dmg` for a DMG with a background (`apps/icon/dmg-background.png`, when it exists). Without it, the DMG is plain: Oby.app and an Applications link.

## A release

On a clean `dev` (or `main`, once F4's test list passes):

```sh
scripts/release.sh 0.2.0
```

In order, it:

1. **Bumps the version.** `MARKETING_VERSION` becomes `0.2.0` and `CURRENT_PROJECT_VERSION` the git commit count including the bump commit, so build numbers only grow; both in `apps/Oby.xcodeproj`, committed as `chore(release): Oby 0.2.0 (N)`.
2. **Archives the `Oby` scheme** (Release) and exports it with Developer ID ([`apps/ExportOptions-DeveloperID.plist`](../apps/ExportOptions-DeveloperID.plist), `teamID` filled from `OBY_TEAM_ID`).
3. **Notarizes the app** (`xcrun notarytool submit --keychain-profile oby-notary --wait`), staples the ticket, and checks it with `spctl`.
4. **Builds `Oby-0.2.0.dmg`**, signs it with the Developer ID, notarizes and staples it too.
5. **Signs it for Sparkle** with `sign_update` and the EdDSA key in the keychain.
6. **Writes the appcast entry**: version, build, date, the DMG's URL, length and signature, and release notes from the merged pull requests since the last `v*` tag (`--notes <file>` gives your own, one line per item). It's put on top of the appcast published already, and checked with `xmllint`.
7. **Uploads** the DMG and `appcast.xml` to R2.
8. **Tags `v0.2.0`.**

Everything lands in `build/release/` (gitignored), with `archive.log` and `export.log` when something fails. The script prints no credential and never runs with `set -x`.

Then push the commit and the tag: `git push origin HEAD v0.2.0`. Shipped Obys pick the update up within 6 hours; **Check for Updates…** gets it now.

### Trying it today

```sh
scripts/release.sh 0.2.0 --dry-run
```

A dry run needs no certificate, key or bucket: it archives with ad hoc signing (CI's flags, hardened runtime on), notarizes and uploads nothing, signs the DMG ad hoc, uses a placeholder Sparkle signature when the keychain has no key, writes the appcast to `build/release/appcast.xml`, checks it with `xmllint` and prints the entry. It commits and tags nothing, and leaves the project untouched. Put its output in the pull request.

## Moving the iPhone and Watch apps to the Deskree team

The Mac app only needs `OBY_TEAM_ID`. The iPhone and Watch apps need more, because their identifiers and pushes belong to the account:

1. **Register the App IDs** under the Deskree team: the iPhone app, its Live Activity (`….activity`), the Watch app and its widget, and the **App Group** they share ([apps/ios/app/README.md](../apps/ios/app/README.md) has today's ids). Either keep `dev.wellprado.oby` as `OBY_IPHONE_BUNDLE_ID`, or set a new one there (an App Store record's bundle id stays with its account, so the real app starts fresh on Deskree's).
2. **A new APNs key** (Keys › +, Apple Push Notifications service) for the Live Activity pushes. The runner's key `8TP9AXUB64` belongs to the current team and its `.p8` lives on tetrix-lab, so the runner's `apns/apns.json` needs the new Team ID and Key ID, with the new `.p8` beside it ([Runner/README.md](../Runner/README.md), Live Activity push).
3. **Set `OBY_TEAM_ID`** and commit; every target follows.
4. **Xcode Cloud**: the workflows for `ObyPhone` and `ObyWatch` move to the Deskree team's App Store Connect, with the new app records.
