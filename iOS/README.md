# Oby for iPhone

The iPhone app is the `ObyPhone` target in `Oby.xcodeproj` (the app is called Oby). It's a client of the **runner**, Oby's engine running as a service on an always-on machine, so the work goes on while the Mac is closed. The contract between them is [`docs/runner-api.md`](../docs/runner-api.md).

What it does today:

- Shows Oby and your jobs live: the step each agent is on, how each one ended, Stop.
- Type a task, check the plan card (agent, model, account, repository, branch), and Dispatch.
- Publish a finished job: Oby shows the exact action, and Face ID signs it with a key that lives in the iPhone's Secure Enclave. Nothing is published without it, and Oby never merges. If you talk to a published job and it makes more commits, "Publish the new commits" pushes them onto the same pull request. Home says what needs you: jobs ready to publish, failed or interrupted.
- Settings: the runner's address, its accounts, and each tool's model and effort.
- Clear done: hides finished jobs from Home, and from the Mac's island too. The runner records when you pressed it (`POST /v1/clear`) and keeps every job; the list is in the same groups on both: needs you, working, in review, done.
- A Live Activity while agents work: Oby, the job, its step and a clock, on the Lock Screen and in the Dynamic Island, ending with how the last job finished. The app updates it while it's open (the `ObyActivity` extension in `LiveActivity/` draws it). In the background the runner pushes it (`POST /v1/activities`): new steps, "Done" or "Failed" when the last job ends, and a push-to-start when a job begins while the app is closed. On a runner without an APNs key, the step stays where it was (the clock keeps ticking), after a minute it says "Open Oby for the latest", and the runner's `GET /v1/jobs/{id}/wait` wakes the app when the job ends so the card says "Done" or "Failed". Push needs the `aps-environment` entitlement (`iOS/Oby.entitlements`): a build from Xcode uses Apple's development push service, TestFlight its production one.
- Notifications when a job needs you, and only then: "Ready to publish: <job>" with **Publish** (Face ID, then the draft pull request) and **Open**, or a failed or interrupted job with its reason. Tapping one opens the job. Oby asks for permission the first time you dispatch a job, hands the runner its device token (`POST /v1/notifications`), and the notification goes away once the job is published, from the iPhone or the Mac (`iOS/Notifications.swift`).

## Run it

- **Simulator:** the `ObyPhone` scheme on an iOS 26 or later simulator. Publishing needs a real iPhone, because the simulator has no Secure Enclave.
- **Your iPhone:** connect it, pick it as the destination, and run. From the command line:

  ```bash
  xcodebuild -project Oby.xcodeproj -scheme ObyPhone -destination 'id=<iPhone UDID>' -allowProvisioningUpdates build
  ```

- **Tests:** `iOSTests`, with `xcodebuild … -scheme ObyPhone -destination '<an iOS 27 simulator>' test`.
- **Reaching the runner:** the iPhone needs Tailscale on. The default runner is `https://tetrix-lab.tail8de49b.ts.net:8443`, and it answers only its owner's Tailscale login.

## Signing and TestFlight

Until Deskree's team can make certificates, the iPhone app signs with Wellington's paid personal team (`PQKAL8E36D`) under a beta bundle ID, `dev.wellprado.oby`; the Live Activity extension is `dev.wellprado.oby.activity`. On the phone it's still called Oby.

`com.deskree.oby` stays unused on purpose. Once an app record has a build, its bundle ID belongs to that account, and Apple only moves an app between accounts after it has been released on the App Store. So the beta lives on Wellington's account and the real app starts on Deskree's.

**Upload a build to TestFlight:**

1. Once, in [App Store Connect](https://appstoreconnect.apple.com): Apps › + › New App › iOS, bundle ID `dev.wellprado.oby`, name **Oby Beta**. App names are unique on the App Store, so keep "Oby" free for Deskree's app.
2. Raise `CURRENT_PROJECT_VERSION` (every upload needs a new build number).
3. In Xcode: scheme ObyPhone, destination Any iOS Device, Product › Archive, then Distribute App › TestFlight & App Store. Xcode makes the distribution certificate and profiles.
4. In App Store Connect › TestFlight, add internal testers (up to 100, no review).

The app says it uses only exempt encryption (`ITSAppUsesNonExemptEncryption` = NO: HTTPS and Face ID signing), so builds skip the export compliance question.

**Moving to Deskree's team:** set `OBY_IPHONE_BUNDLE_ID` to `com.deskree.oby` (project build settings) and the iPhone targets' team to Deskree's, then create the Oby app in Deskree's App Store Connect. Testers install it as a new app; Face ID keys register again on their own.

## Coming next

- Notifications from the Oby platform rather than the runner (F11, spike #27). The runner's pushes use Wellington's team's APNs key until then.
- Talking to Oby, and the Apple Watch app (`Watch/`).
