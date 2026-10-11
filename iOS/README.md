# Oby for iPhone

The iPhone app is the `ObyPhone` target in `Oby.xcodeproj` (the app is called Oby). It's a client of the **runner**, Oby's engine running as a service on an always-on machine, so the work goes on while the Mac is closed. The contract between them is [`docs/runner-api.md`](../docs/runner-api.md).

What it does today:

- Shows Oby and your jobs live: the step each agent is on, how each one ended, Stop.
- Type a task or tap the composer’s mic to dictate, tap Stop to keep and edit the words, then Send and check the plan card (agent, model, account, repository, branch), and Dispatch.
- Publish a finished job: Oby shows the exact action, and Face ID signs it with a key that lives in the iPhone's Secure Enclave. Nothing is published without it. Oby merges only into dev, once its review approves and the checks on your Mac pass. If you talk to a published job and it makes more commits, "Publish the new commits" pushes them onto the same pull request. Home says what needs you: jobs ready to publish, failed or interrupted.
- The Inbox, at the top of Home: what only you can answer (a job's question, a job out of Oby's reviews, a failure, a job out of usage), the longest-waiting first with how long it waited. Answer with a button or your own words, or tap Later or Done; then the next one opens. A job's question waits there instead of in its report, the job waits for your answer, and the answer goes back to it as its next message. Answered here, it goes from the Mac's island too (`GET /v1/inbox`, `POST /v1/inbox/{id}/answer`).
- Settings: the runner's address, its accounts, each tool's model and effort, speech language (English or Portuguese), and whether Oby speaks replies to spoken requests. Typed requests stay silent.
- Clear done: hides finished jobs from Home, and from the Mac's island too. The runner records when you pressed it (`POST /v1/clear`) and keeps every job; the list is in the same groups on both: needs you, working, in review, done.
- A Live Activity while agents work: Oby, the job, its step and a clock, on the Lock Screen and in the Dynamic Island, ending with how the last job finished. The app updates it while it's open (the `ObyActivity` extension in `LiveActivity/` draws it). In the background the runner pushes it (`POST /v1/activities`): new steps, "Done" or "Failed" when the last job ends, and a push-to-start when a job begins while the app is closed. On a runner without an APNs key, the step stays where it was (the clock keeps ticking), after a minute it says "Open Oby for the latest", and the runner's `GET /v1/jobs/{id}/wait` wakes the app when the job ends so the card says "Done" or "Failed". Push needs the `aps-environment` entitlement (`iOS/Oby.entitlements`): a build from Xcode uses Apple's development push service, TestFlight its production one.
- Stands between the Apple Watch and the runner: the watch app ships inside this one, and `iOS/WatchRelay.swift` keeps the jobs on it and carries out what it asks, signing a publish with Face ID (`Watch/README.md`).
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

## Voice input (Part of #19)

Tap the mic beside Send to dictate. Once capture starts, a light haptic confirms listening; the button becomes Stop with a subtle input-level meter. Words appear live inside the editable composer with the cursor at the end. Final results replace the volatile words in place. Tap Stop to finish recognition and keep the words in the field, then edit or use the normal Send button. Dictating again appends to the draft with a separating space when needed. Stopping never sends a request, including the automatic stop 60 seconds after capture starts.

Starting to type stops capture and freezes the current words; late recognition results cannot overwrite keyboard edits. Going to the background stops capture and finalizes the draft. Leaving Home, opening Settings or a job, calls, Siri, or a lost audio route stops capture while preserving the words already in the composer. Permission dialogs do not cancel preparation just because the app becomes inactive; stopping during preparation prevents the microphone from opening later. The mic indicator and meter reflect capture, not preparation or finalization. Empty dictation leaves the existing draft unchanged. Tapping the mic stops Oby's speech immediately. The first tap requests microphone and speech recognition access separately; denied access leaves typing available. SpeechAnalyzer runs on the iPhone; an absent speech model downloads before a later tap can transcribe.

Sending a draft containing dictated words can speak Oby's reply, including after editing or appending more dictation; the Settings switch still controls this. Clearing the draft resets it to a typed request. Cancel waiting remains visible while planning. It stops waiting for the reply, but the runner can keep processing an accepted request, including starting jobs for a roadmap goal. Those jobs still appear in Home and can be stopped there. The Apple Watch keeps its hold-to-talk and slide-to-lock behavior.

`PhoneSpeech.swift` owns recognition, volatile/final results, context, model installation, conversion and finalization. The phone capture queue holds at least eight seconds of 2048-frame tap audio; the analyzer queue allows twice that buffer count. The Watch keeps its separate 64-chunk queue. Both remain bounded while tolerating brief slowdowns. The phone’s microphone and both Watch relay paths use it. Recognition context includes product names and repositories present in the phone’s job list (there is no repository inventory endpoint). Settings selects English, Brazilian Portuguese, Portuguese from Portugal, or the phone’s current language (including other locales supported by SpeechTranscriber). Reply speech detects the reply’s own language, independently of the speech-input setting, and prefers an installed premium/enhanced non-novelty voice in that language, with its system voice as fallback.

The iPhone target generates its Info.plist from project build settings. Both Debug and Release include these separate permission reasons:

- `NSMicrophoneUsageDescription`: “Oby listens when you tap the mic to dictate, until you stop or for up to 60 seconds.” The iPhone’s `en.lproj/InfoPlist.strings` and `pt.lproj/InfoPlist.strings` override the generated project’s old microphone reason without changing the Watch target.
- `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription`: “Oby writes down your iPhone and Apple Watch speech on this iPhone to plan your request.”

A build without either reason refuses voice input safely and leaves typing available.

On a Mac, build the ObyPhone scheme and test on a real phone:

- Tap to start and stop; light start haptic, stop icon, level meter and capture-only microphone indicator.
- Live English/Portuguese words in the field, replacement of volatile results by final results, cursor at the end, editable stopped text, repeated dictation appended to typed and dictated drafts, and silent dictation leaving the draft unchanged.
- No automatic submission on Stop, timeout or backgrounding. Normal Send reaches the planner; dictated drafts speak replies when enabled, and purely typed drafts stay silent.
- Type during capture and finalization, including immediately after Stop: audio stops and late words cannot overwrite edits. Clear the draft and verify the next typed request stays silent.
- The 60-second limit, background/foreground transitions, leaving Home, opening Settings or a job, calls/Siri and unplugging headphones; captured words remain available.
- Fresh permission prompts with the updated English/Portuguese reasons, both denied permissions, stopping during each permission prompt or model preparation, and repeated quick taps during setup.
- Recognition context, brief processing slowdowns, planner Cancel (including identical repeated requests), reply language independent of input language, the Settings speech switch, fallback TTS voices, resuming music, and both live/recorded Watch relay paths.

None of these device checks can run on the Linux runner. Swift syntax parsing does not type-check the iOS SDK or establish that the app compiles. Verify the localized privacy strings are bundled by Xcode’s synchronized iOS folder and appear in the system permission prompt on a fresh install.

Watch capture, sender backlog and the phone’s accepted stream length share the 60-second limit in `Shared/WatchWire.swift`. Watch networking implementation is unchanged.

A 60-second Watch capture is a maximum, not a guarantee of iPhone background execution. When the paired iPhone is locked or Oby is suspended, iOS may expire the relay’s background allowance sooner and cancel transcription. Verify long locked holds on a real Watch and locked iPhone before shipping; try a shorter hold if the phone reports an interrupted stream.
