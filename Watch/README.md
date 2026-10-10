# Oby for Apple Watch

The watch app is the `ObyWatch` target in `Oby.xcodeproj` (on the wrist it's called Oby), shipped inside the iPhone app: the iPhone build on TestFlight installs it on the paired watch. It's F16 ([#20](https://github.com/deskree-inc/oby/issues/20)); this is its first slice.

What it does today:

- **Home:** Oby (a still pose, from the same render of `Character/` as the icon), the line "1 needs you · 2 working", then the jobs that need you and the ones running, each with its title and "Stage n of m". Tapping a job shows its stages and result.
- **Publish with the crown:** on a job ready to publish, Publish shows the exact sentence the runner would carry out, and turning the Digital Crown confirms it: the ring fills as it turns, and a full turn publishes. A tap can't do it by mistake. The signature is the iPhone's (below).
- **Notifications:** the alerts the runner sends the iPhone ("Couldn't publish", "Failed", "Interrupted") reach the watch as mirrored notifications. The watch registers the same categories, so a "ready" alert offers **Publish** (the job opens and asks for the crown) and **Open**; tapping one opens the job.
- **Talk to Oby:** hold the button to talk. The microphone is open only while it's held, up to 15 seconds: permission is asked when the screen opens, so a hold starts the microphone at once, and letting go, leaving the screen or the app going inactive stops it. The recording (AAC, 16 kHz) goes to the iPhone, which writes it down on device with SpeechAnalyzer and asks the runner's brain (`POST /v1/plans`); the plan comes back to the watch to dispatch with one tap. Questions from the brain and replies show too. **Dictate instead** uses the system's text input (dictation or scribble). With the iPhone out of reach, only dictation is offered: the request is queued, and the phone plans it when it's back.
- **Tell the agent** and **Stop job** on a job's screen, as on the iPhone.

## How it reaches the runner

The watch can't reach the tailnet, so the iPhone stands in between (WatchConnectivity):

- `iOS/WatchRelay.swift` is the phone's side. It keeps the jobs on the watch as the application context, on every change (what needs you first, then what's running, then what finished in the last two days, trimmed to the 65 KB WatchConnectivity carries), and carries out what the watch asks as the app itself would, calling the runner (`docs/runner-api.md`). iOS wakes the phone app in the background for a message from the watch, and the relay asks for background time to finish, so it works with the phone in a pocket.
- `Watch/Watch.swift` is the watch's side: the jobs, and the requests.
- `Shared/WatchWire.swift` is what they say to each other. Fast requests (refresh, dispatch, a message to a job, stop, the publish sentence) are answered in the reply. Planning and publishing take longer than a reply may wait for, so they're acknowledged, and the outcome comes back as a message of its own, queued if the watch app isn't up.
- **Publish needs the phone's signature.** The runner accepts a publish by hand only with a fresh signature from the iPhone's Secure Enclave key, which signs after Face ID (`iOS/DeviceKey.swift`). The watch asks, and the phone signs. With Oby open on the phone, Face ID comes up there right away. In the background it can't, so the phone posts a notification, "Publish from your watch", whose **Publish with Face ID** is the app's own; the watch says so.
- Spoken requests are transcribed on the iPhone (watchOS has no SpeechAnalyzer). The first time, the phone downloads the speech model for its language and asks the watch to try again in a minute.

The watch keeps nothing but the last application context and the id of the ask it waits for.

## Run it

- **Simulator:** the `ObyWatch` scheme on a watchOS 26 simulator paired with an iPhone simulator running `ObyPhone`. The relay only works with both up; publishing needs a real iPhone (Secure Enclave).
- **Your watch:** run `ObyPhone` on your iPhone (the watch app is embedded) and Xcode installs it on the paired watch, or run the `ObyWatch` scheme with the watch as the destination.
- **TestFlight:** the iPhone build carries the watch app. Keep `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` the same on `ObyWatch` and `ObyPhone` (Apple requires it), and raise both for every upload.
- **Bundle ID:** `$(OBY_IPHONE_BUNDLE_ID).watchkitapp`, so moving to Deskree's team is the same switch as for the iPhone (`iOS/README.md`).
- **Tests:** `iOSTests/WatchRelayTests.swift` checks the trimming of the job list and the relayed plan.

## Size

The watch app is Swift, one 60 KB PNG of Oby and the icon: far under the 75 MB cap on watch apps.

## Issue #20: where it stands

Build list:

- [x] watchOS app, embedded in the iPhone app: Home with needs-you and the running jobs with their stage, the job's stages and result, Publish with the crown, notifications mirrored from the phone, the relay through the iPhone.
- [ ] Oby animated as pre-rendered frames (the pipeline that rendered the preview does this).
- [ ] Complications and the Smart Stack (still poses).
- [x] Talking: audio relayed to the iPhone and transcribed there (SpeechAnalyzer), with system dictation as the fallback.

Test it when it's done:

- [ ] An approval arrives on the watch: turn the crown to approve (built; needs a real iPhone and watch).
- [ ] Home shows Oby animated, with "1 needs you · 2 working" (the line is there; Oby is a still until the frames land).
- [ ] The complication shows how many things need you.
- [ ] Dictate a request: the Mac runs it (built; runs on the runner).

## Coming next

- Oby animated: frames rendered from `Character/oby.html` as the preview was, played with `TimelineView`.
- Complications and the Smart Stack: how many things need you, with a still Oby.
