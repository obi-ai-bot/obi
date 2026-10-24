# Oby for iPhone

The iPhone app is the `ObyPhone` target in `apps/Oby.xcodeproj` (the app is called Oby). It's a client of the **runner**, Oby's engine running as a service on an always-on machine, so the work goes on while the Mac is closed. The contract between them is [`docs/runner-api.md`](../../../docs/runner-api.md).

It wears Sangam's design (`design/app`, `apps/shared/Tokens.swift`), light or dark as the system is (Settings › Appearance). There is no tab bar: Home is the one stack, and Sangam's side panel opens from the left (the panel button at Home's top left, or a swipe from the screen's left edge on Home; a tap beside it or a swipe back closes it). Its icon strip shows Home's tasks by kind or the conversations, and your picture at its foot (also at Home's top right) opens Settings.

- Home, the stage: Oby, "N running tasks · M need you", a chip per kind of work (Review PR, Issues, Tasks) and the message box. "Needs you" counts the tasks with an open decision plus the decisions with no task, and a tap on it opens the one that has waited longest: its task, or the Inbox when it has no task on Home. A decision lives with its task (its card, its page, its conversation), so there is no Needs you page. What you send there starts a conversation of its own (obid, #493) and opens it. A chip opens its kind's page (Running and Completed, a card per task with its live step, its decision or what it left behind); the list button shows every task by type or status, Clear done and Archived (kept by the phone: what Clear done or Dismiss took off Home). Under the chips, Running (up to three open tasks; See all) and Recent (the three latest conversations).
- The side panel's Conversations: obid's conversations, Pinned then Recent, searchable (`GET /v1/conversations?q=`), swipe to delete, hold to pin or rename. A runner with one thread lists just that one.
- A task's page: its result, stages, details and what you asked, its decision answered in place, Move, Mode, Stop, Dismiss, Publish with Face ID, and the box that tells Oby about it (`POST /v1/jobs/{id}/messages`).
- Debug builds launched with `-ObySampleTasks YES` show three made-up tasks, for screenshots on a simulator with no jobs; add `-ObySampleTalk 15` and Oby's answer comes into the Oby thread, a word at a time, 15 seconds after launch. `-ObySampleHarness 4` plays a turn as the conversation harness brings it (tool lines, words streaming in, an artifact card and a live job card), and `-ObySampleOpenArtifact 8` opens the sample artifact in the viewer 8 seconds after its card shows. `-ObySampleHold 30` holds it 30 seconds at work and again halfway through its words. Add `-ObySampleOffline YES` so the app reaches no runner meanwhile, and `-ObySampleUnreachable YES` to show the Mac out of reach (the notice over every screen; what you send waits, marked "Sends when your Mac is back"). `-ObySampleUnpaired YES` with `-ObySampleOffline YES` shows the first screen of an iPhone that hasn't paired.
- A fresh iPhone talks to nobody: there's no default runner address. Until it pairs, the first screen is only Oby, one line saying where to pair on the Mac (Settings › Runner › Pair a device) and Connect, which opens the camera on the Mac's QR code; "Use the six-digit code instead" there opens Connect (the Macs on this network with the six digits for one, or an invitation pasted). Pairing lasts 30 days; once the Mac stops taking this iPhone (revoked, or the 30 days are up), the first screen comes back, its line saying which.
- A QR code made while the Mac's obid is in an Obysphere carries the relay (`link.relay`: the Sphere, the relay id, this phone's relay token and the Mac's X25519 key; docs/runner-api.md, "obid only: the phone relay"). Then the iPhone reaches the Mac only through it (apps/shared/PhoneRelay.swift): one WebSocket to the Sphere, every request, answer and event sealed end to end to the key the QR code pinned, never plain HTTP and never the tunnel or the home network. The relay, its token and the key are kept in the keychain on this device only (`RelayStore`), beside the device token; a welcome that doesn't open with that key is ignored (obid answers nothing to a hello it can't open, so it's a late or forged one), and only scanning the Mac's code again pins a new key; until then a Mac whose key changed reads as "Your Mac isn't answering". The Camera app isn't a way in: Oby scans the code itself.

Before the redesign, in three tabs (Home, Chat, Settings); all of it still works, in the places above:

- Home, the glance: shows Oby and your jobs live, the step each agent is on, how each one ended, Stop.
- Chat (#11): the one conversation with Oby every device shares, the same thread as the Mac's Oby window (`GET /v1/conversation`, followed over its `turn` event; `apps/shared/ConversationModel.swift` pages it and groups it by day). Oby's turns with its face and the time, yours as bubbles ("You, by voice" when the words were dictated), day separators, a card under Oby's words for each job it started and the Inbox's decision cards, all opening the job's screen; "Working now" at the top with every agent at work. What you send shows at once and is listed by the runner with Oby's answer; words that didn't reach the runner stay in the thread with why, Try again and Edit. The plan and the brain's question are cards in the thread, and Earlier loads older turns without losing your place. It reads at every Dynamic Type size.
- Type a task or tap the composer’s mic to dictate it, on Home or in Chat, check the plan card (agent, model, account, repository, branch), and Dispatch.
- Publish a finished job: Oby shows the exact action, and Face ID signs it with a key that lives in the iPhone's Secure Enclave. Nothing is published without it. Oby merges only into dev, once its review approves and the checks on your Mac pass. If you talk to a published job and it makes more commits, "Publish the new commits" pushes them onto the same pull request. Home says what needs you: jobs ready to publish, failed or interrupted.
- The Inbox, at the top of Home: what only you can answer (a job's question, a job out of Oby's reviews, a failure, a job out of usage), the longest-waiting first with how long it waited. Answer with a button or your own words, or tap Later or Done; then the next one opens. A job's question waits there instead of in its report, the job waits for your answer, and the answer goes back to it as its next message. Answered here, it goes from the Mac's window too (`GET /v1/inbox`, `POST /v1/inbox/{id}/answer`).
- Settings, its own tab: the runner's address, its accounts, each tool's model and effort, speech language (English or Portuguese), and whether Oby speaks replies to spoken requests. Typed requests stay silent.
- Clear done: hides finished jobs from Home, and from the Mac's window too. The runner records when you pressed it (`POST /v1/clear`) and keeps every job; the list is in the same groups on both: working, waiting (each saying what for), needs you, in review, done.
- A Live Activity while agents work: Oby, the job, its step and a clock, on the Lock Screen and in the Dynamic Island, ending with how the last job finished. The app updates it while it's open (the `ObyActivity` extension in `apps/ios/live-activity/` draws it). In the background the runner pushes it (`POST /v1/activities`): new steps, "Done" or "Failed" when the last job ends, and a push-to-start when a job begins while the app is closed. On a runner without an APNs key, the step stays where it was (the clock keeps ticking), after a minute it says "Open Oby for the latest", and the runner's `GET /v1/jobs/{id}/wait` wakes the app when the job ends so the card says "Done" or "Failed". Push needs the `aps-environment` entitlement (`apps/ios/app/Oby.entitlements`): a build from Xcode uses Apple's development push service, TestFlight its production one.
- Stands between the Apple Watch and the runner: the watch app ships inside this one, and `apps/ios/app/WatchRelay.swift` keeps the jobs on it and carries out what it asks, signing a publish with Face ID (`apps/watch/README.md`).
- Notifications when a job needs you, and only then: "Ready to publish: <job>" with **Publish** (Face ID, then the draft pull request) and **Open**, or a failed or interrupted job with its reason. Tapping one opens the job. Oby asks for permission the first time you dispatch a job, hands the runner its device token (`POST /v1/notifications`), and the notification goes away once the job is published, from the iPhone or the Mac (`apps/ios/app/Notifications.swift`).

## Run it

- **Simulator:** the `ObyPhone` scheme on an iOS 26 or later simulator. Publishing needs a real iPhone, because the simulator has no Secure Enclave.
- **Your iPhone:** connect it, pick it as the destination, and run. From the command line:

  ```bash
  xcodebuild -project apps/Oby.xcodeproj -scheme ObyPhone -destination 'id=<iPhone UDID>' -allowProvisioningUpdates build
  ```

- **Tests:** `iOSTests`, with `xcodebuild … -scheme ObyPhone -destination '<an iOS 27 simulator>' test`.
- **Reaching the runner:** the iPhone needs Tailscale on. The default runner is `https://tetrix-lab.tail8de49b.ts.net:8443`, and it answers only its owner's Tailscale login.

## Signing and TestFlight

The iPhone app signs with Deskree's team (`3UV9W5SV7W`) as `com.deskree.oby.ios`, an App ID of its own: the Mac app is `com.deskree.oby`, and sharing one made Xcode see a single "Oby (iOS, macOS)" product, which Xcode Cloud couldn't tie to the iOS-only App Store Connect record (2026-10-23). The Live Activity extension is `com.deskree.oby.ios.activity`, the Watch app `com.deskree.oby.ios.watchkitapp` (and `.watchkitapp.widget`), and the App Group they share `group.com.deskree.oby.ios.watch`. Builds 432 and 458 went to the earlier record, "Oby by Deskree" (`com.deskree.oby`), which gets no new ones. Both the team (`OBY_TEAM_ID`) and the bundle ID (`OBY_IPHONE_BUNDLE_ID`) are set once, in `apps/config/Signing.xcconfig` ([docs/release.md](../../../docs/release.md)).

Until 2026-10-20 the beta signed with Wellington's personal team (`PQKAL8E36D`) as `dev.wellprado.oby`, "Oby Beta" in App Store Connect. That record stays on his account (an app record's bundle ID belongs to its account) and gets no new builds; testers install the Deskree app as a new app, and Face ID keys register again on their own.

**Upload a build to TestFlight:**

1. Once, in Deskree's [App Store Connect](https://appstoreconnect.apple.com): Apps › + › New App › iOS, bundle ID `com.deskree.oby.ios`, name **Oby** (or another free name), SKU of your choice. The bundle ID appears in the list once Xcode has registered it (step 3 does, with automatic signing), or register it first under Certificates, IDs & Profiles › Identifiers.
2. Every upload needs a new build number; the export options' `manageAppVersionAndBuildNumber` raises it.
3. In Xcode, signed in with an account in Deskree's team (Settings › Accounts): scheme ObyPhone, destination Any iOS Device, Product › Archive, then Distribute App › TestFlight & App Store. Xcode makes the distribution certificate, the App IDs, the App Group and the profiles.
4. In App Store Connect › TestFlight, add internal testers (up to 100, no review).

The app says it uses only exempt encryption (`ITSAppUsesNonExemptEncryption` = NO: HTTPS and Face ID signing), so builds skip the export compliance question.

## Coming next

- Notifications from the Oby platform rather than the runner (F11, spike #27). Pushes need an APNs key in Deskree's team (docs/release.md, step 2).

## Voice input (Part of #19)

Tap the mic beside Send to dictate (`apps/ios/app/Composer.swift`, the same composer on Home and in Chat). Once the microphone is open a light haptic says so, and the mic turns into a red Stop with the input's level under it. What you say goes into the field as it's heard, after what the field already held, with the cursor at the end; the final words replace the tentative ones in place. Tap Stop and the words stay in the field to edit, then Send as usual: stopping never sends anything, and neither does the automatic stop 60 seconds after the microphone opens. Dictating again adds to the draft, with a space between. Nothing heard leaves the draft as it was and says “Oby didn't catch that.”

Typing while it listens or writes down stops it there: the words already in the field stay, and later ones can't overwrite your edits. The same goes for the field being filled from elsewhere (Edit on a plan card or a failed message). Going to the background stops listening and writes down the final words. Leaving the tab, opening a job, a call, Siri or a lost audio route stop it with the words already in the field. The microphone and speech recognition prompts don't stop it while the microphone is being prepared; anything else that takes the app out of the front then (Control Center, a notification, the background) stops it, and Stop during preparation means the microphone never opens. The mic shows Stop and the meter only while it really listens; “Getting ready…” and “Writing down…” show above the field before and after. Tapping the mic stops Oby talking, and a reply that arrives while you dictate stays silent. The first tap asks for microphone and speech recognition access, separately; refused, typing still works. SpeechAnalyzer runs on the iPhone; a speech model that isn't there yet downloads first.

A draft with dictated words in it is a spoken request when you send it, even after edits or more typing, so Oby can speak its reply (Settings decides); clearing the field makes it a typed one again. Cancel waiting stays in sight while Oby plans. It stops the phone waiting for the reply; the runner can still carry out a request it already took, such as starting jobs for a roadmap goal, and those jobs show on Home where they can be stopped. The Apple Watch dictates the same way (`apps/watch/README.md`).

`PhoneSpeech.swift` owns recognition, volatile/final results, context, model installation, conversion and finalization. The phone capture queue holds at least eight seconds of 2048-frame tap audio; the analyzer queue allows twice that buffer count. The Watch keeps its separate 64-chunk queue. Both remain bounded while tolerating brief slowdowns. The phone’s microphone and both Watch relay paths use it. Recognition context includes product names and repositories present in the phone’s job list (there is no repository inventory endpoint). Settings selects English, Brazilian Portuguese, Portuguese from Portugal, or the phone’s current language (including other locales supported by SpeechTranscriber). Reply speech detects the reply’s own language, independently of the speech-input setting, and prefers an installed premium/enhanced non-novelty voice in that language, with its system voice as fallback.

The iPhone target generates its Info.plist from project build settings. Both Debug and Release include these separate permission reasons:

- `INFOPLIST_KEY_NSMicrophoneUsageDescription`: “Oby listens when you tap the mic to dictate, until you tap stop or for up to 60 seconds.” In Portuguese, `apps/ios/app/pt.lproj/InfoPlist.strings` replaces it, as `apps/watch/pt.lproj` does for the Watch.
- `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription`: “Oby writes down your iPhone and Apple Watch speech on this iPhone to plan your request.”

A build without either reason refuses voice input safely and leaves typing available.

On a Mac, build the ObyPhone scheme and test on a real phone, on Home and in Chat:

- Tap to start and to stop: the haptic once the microphone opens, the Stop icon, the level meter, and the system's microphone indicator only while listening.
- Live English and Portuguese words in the field, tentative words replaced by final ones, the cursor at the end, dictating after typed or dictated words, and silence leaving the draft as it was.
- Nothing sent on Stop, at 60 seconds or in the background; Send reaches the planner. Dictated drafts get spoken replies when Settings allows, typed ones stay silent, and a cleared draft is typed again.
- Typing while listening and while writing down, right after Stop too: listening stops and late words never overwrite the edit. Edit on a plan card or a failed message while dictating.
- Background and back, switching tabs, opening a job, calls, Siri and unplugging headphones: the words heard stay.
- A fresh install's permission prompts with the new reasons in English and Portuguese, both refused, Stop during each prompt and during model preparation, Control Center pulled down during “Getting ready…” (the microphone must not open), and quick repeated taps.
- A reply arriving while dictating stays silent and doesn't break the recording; tapping the mic while Oby talks stops it; music resumes after.
- Both Watch relay paths, unchanged.

None of these can run on the Linux runner.

Watch capture, sender backlog and the phone’s accepted stream length share the 60-second limit in `apps/shared/WatchWire.swift`. Watch networking implementation is unchanged.

A 60-second Watch capture is a maximum, not a guarantee of iPhone background execution. When the paired iPhone is locked or Oby is suspended, iOS may expire the relay’s background allowance sooner and cancel transcription. Verify long locked holds on a real Watch and locked iPhone before shipping; try a shorter hold if the phone reports an interrupted stream.
