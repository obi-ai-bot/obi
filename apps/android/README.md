# Oby for Android

One Gradle project for Android phones and, later, Wear OS. `app/` is the phone app; `wear/` joins it as a second module when the watch app is built (it's the follow-up, not here). The phone app is the iPhone app on Android: the same screens, words and flows (`apps/ios/app/README.md`), in Kotlin and Jetpack Compose, wearing Sangam's design (`design/app`, the tokens of `apps/shared/Tokens.swift`), light or dark as the system is. Oby's face comes from [`character/`](../../character/README.md), shown in a `WebView`.

It's a client of the runner through the paired Mac's gateway, as the iPhone is ([docs/runner-api.md](../../docs/runner-api.md)): it pairs by the Mac's QR code (Tailscale serve, `https://<mac>.ts.net:8443`), a pasted invitation, or the six digits for a Mac on this network, and reaches the Mac only with the device token that buys. A fresh phone talks to nobody: Connect is the first screen until it pairs, and comes back when the Mac stops taking it (revoked, or its 30 days are up).

## What's on it

Everything the iPhone has, in the same places:

- **Home**: Oby on its stage, "N running tasks · M need you" (a tap opens the decision that has waited longest), a chip per kind of work, Running and Recent, and the message box. What you send there starts a conversation and opens it.
- **The side panel** (the button at Home's top left, or a swipe from the left edge on Home): Home's tasks by kind, the Inbox, every task and Archived; or the conversations, Pinned then Recent, searched by what was said, held for Pin, Rename and Delete. Your picture at its foot, and at Home's top right, opens Settings.
- **A kind's page**: Running and Completed (and To do for Review PR and Issues: GitHub's items with one tap to start Oby on them), a card per task with its live step, its decision or what it left behind.
- **A task's page**: its decision answered in place (or what failed, with Give it another round), Result, the Timeline, Usage, Details with the full live session, what you asked and its follow-ups; ⋮ for Open conversation, Stop, Dismiss or Archive, Move to… and Mode; Publish signed on this phone; the box to tell Oby about it, with Stop while it runs.
- **A conversation**: your words in bubbles, Oby's under its face, its tool lines and its words coming in a word at a time, the tasks it started as live cards, artifacts opening in their viewer (pages in a sandboxed WebView that loads only that artifact's files under obid's Content-Security-Policy, Markdown, images, PDFs, canvases), Earlier, Stop, and words that didn't reach the Mac kept with Try again and Edit.
- **Offline**: one line over every screen says why the Mac can't be reached; what you send or answer meanwhile waits on the phone, marked "Sends when your Mac is back", and goes when it is.
- **Settings**: Your Mac, Accounts with their week, Connectors (Tetrix, held on the Mac), Models, Permissions and their rules, Routines, Notifications, Voice, Appearance, Stop every task, About, and the publishing key.

What it doesn't have yet, as the iPhone has it: the Apple Watch's relay (Wear OS is the follow-up) and a Live Activity driven by push (below).

## What's only Android's

- **Minimum Android 11 (API 30).** The publishing key needs Keystore's per-use biometric (`setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`, API 30), the iPhone's Face ID that asks for every signature. Compiled against API 37, targeting 36.
- **The publishing key** is a P-256 key in Android Keystore (StrongBox when the phone has one), invalidated when a new fingerprint or face is enrolled (`.biometryCurrentSet` on the iPhone). The runner gets its public half (X9.63, base64) and checks ECDSA SHA-256 DER signatures of exactly what the iPhone signs (`oby-publish\n<job>\n<action>\n<signedAt>`). The private key never leaves the Keystore.
- **The device token** for the Mac's gateway is sealed with an AES-GCM key that lives in Keystore, in the app's private preferences; nothing is backed up or transferred (`allowBackup` off, data extraction rules exclude everything).
- **Plain HTTP** reaches only this phone or a home-network address (the iPhone's `NSAllowsLocalNetworking`): `Runner.kt` refuses it for any other host.
- **Push is FCM**, not APNs: the phone hands obid its FCM token (`POST /v1/notifications` with `"platform": "fcm"`), and obid sends data messages that the app turns into notifications with Publish and Open (docs/runner-api.md). No token is made until you allow alerts, and nothing is reported to Google (analytics and delivery metrics are off in the manifest). A build without the owner's `google-services.json` builds and runs, and simply never registers for push: Settings › Notifications says so.
- **Notification channels**: "Needs you" (alerts, high) and "Working now" (the quiet ongoing notification that stands in for the iPhone's Live Activity while Oby is open: the job, its step and a clock; how the last job ended for 15 minutes; "Open Oby for the latest" once Oby leaves the front). Android 13 and later ask for `POST_NOTIFICATIONS` the first time Oby reaches the runner or your words start a job.
- **The camera** (CameraX with ML Kit's on-device barcode scanner, nothing leaves the phone) is asked for when you tap Scan the code.
- **The microphone** follows AGENTS.md's rule: a tap on the mic listens until Stop, at most 60 seconds; the words go into the box as they're heard and stay there as a draft; nothing is sent until you send it. Leaving the screen or the app stops listening and keeps the words. Android's recognizer, on the phone when it can (`EXTRA_PREFER_OFFLINE`), ends a segment at a pause, so while you're still listening it listens again and keeps the words so far. Replies to spoken requests are read in their own language (TextClassifier), as Settings allows.
- **Back** pops the stack (and closes the side panel first); on Home it leaves the app. Edge to edge, the bars light or dark with the app's appearance. Portrait only, as the iPhone.
- **Bonjour** is `NsdManager` for `_oby._tcp` (obid doesn't advertise it yet, so the six digits find nothing until it does; the QR code and a pasted invitation work).
- **Portuguese**: what Android itself shows (the notification channels and their actions, the microphone's reason) has Portuguese strings in `values-pt`; the app's own words are English, as the iPhone's are.
- **No telemetry**, as AGENTS.md says.

## Build and run

You need JDK 17 or later (21 is what's tested) and the Android SDK with platform 37. On a Mac:

```bash
brew install openjdk@21 android-commandlinetools
```

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
```

```bash
cd apps/android && ./gradlew assembleDebug lint testDebugUnitTest
```

The debug APK is `app/build/outputs/apk/debug/app-debug.apk`. The build runs `character/package/build.sh` (zsh and python3) and bundles the clean character into the app's assets, as the iPhone's build phase does.

Debug builds take the iPhone's sample switches as intent extras, for screenshots on an emulator with no runner (nothing is sent):

```bash
adb shell am start -n com.deskree.oby/.MainActivity --ez ObySampleTasks true --ez ObySampleOffline true --es ObySampleRoute settings
```

`ObySampleRoute` takes `settings`, `all`, `kind:review` or `task:<id>`; `--ez ObySampleUnreachable true` shows the Mac out of reach, and `--ei ObySampleTalk 8` brings Oby's answer into the thread a word at a time.

An emulator reaches the Mac's tailnet name when it uses Tailscale's resolver: `emulator -avd <name> -dns-server 100.100.100.100`.

## Owner's steps

These are yours; nothing here creates them, and none of their files or keys may go in git (`.gitignore` keeps them out).

1. **Firebase, for push.** In the [Firebase console](https://console.firebase.google.com), add a project (Deskree's; turn Google Analytics off). Add an Android app with package name `com.deskree.oby` and download its `google-services.json` into `apps/android/app/` (git ignores it; the build picks it up when it's there). Then Project settings › Service accounts › Generate new private key, and give obid that service account as docs/runner-api.md (`POST /v1/notifications`) says. Without both, alerts show only while Oby is open.
2. **Play Console.** Create the app in [Play Console](https://play.google.com/console) under Deskree's developer account: name Oby, package `com.deskree.oby`, free, the Play Store icon from `apps/icon/exports/android/play-store-512.png`. Fill in Data safety (no data collected or shared: Oby talks only to your own Mac) and the content rating. Internal testing is Play's TestFlight.
3. **An upload keystore.** Make one and keep it out of git, then turn on Play App Signing so Google holds the app signing key:

   ```bash
   keytool -genkeypair -v -keystore ~/oby-upload.jks -alias oby-upload -keyalg RSA -keysize 4096 -validity 10000
   ```

   A release build signs with it through a `keystore.properties` beside `app/` (also ignored); wiring that file into `app/build.gradle.kts` comes with the first Play upload.
