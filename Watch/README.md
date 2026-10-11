# Oby for Apple Watch

The watch app is the `ObyWatch` target in `Oby.xcodeproj` (on the wrist it's called Oby), shipped inside the iPhone app: the iPhone build on TestFlight installs it on the paired watch. It's F16 ([#20](https://github.com/deskree-inc/oby/issues/20)); this is its second slice.

What it does today:

- **Home:** Oby animated (below), waving while something needs you, busy while agents work and calm otherwise, the line "1 needs you · 2 working", then the jobs that need you and the ones running, each with its title and "Stage n of m". Tapping a job shows its stages and result.
- **Publish with the crown:** on a job ready to publish, Publish shows the exact sentence the runner would carry out, and turning the Digital Crown confirms it: the ring fills as it turns, and a full turn publishes. A tap can't do it by mistake. The signature is the iPhone's (below).
- **Notifications:** the alerts the runner sends the iPhone ("Couldn't publish", "Failed", "Interrupted") reach the watch as mirrored notifications. The watch registers the same categories, so a "ready" alert offers **Publish** (the job opens and asks for the crown) and **Open**; tapping one opens the job.
- **Talk to Oby:** hold the button to talk. The microphone is open only while it's held, up to 15 seconds: permission is asked when the screen opens, so a hold starts the microphone at once, and letting go, leaving the screen or the app going inactive stops it. At 15 seconds the recorder stops itself and what it heard is sent on release. The recording (AAC, 16 kHz) goes to the iPhone, which writes it down on device with SpeechAnalyzer and asks the runner's brain (`POST /v1/plans`); the plan comes back to the watch to dispatch with one tap. Questions from the brain and replies show too. **Dictate instead** uses the system's text input (dictation or scribble). With the iPhone out of reach, only dictation is offered: the request is queued, and the phone plans it when it's back.
- **Tell the agent** and **Stop job** on a job's screen, as on the iPhone.
- **Complications and the Smart Stack:** how many things need you, with Oby in a still pose (below).

## Oby animated

watchOS has no WebKit, so Oby plays as frames rendered from `Character/oby.html`, as the preview's Oby and the icon were (`Icon/render.mjs`). There are three loops at 15 fps, 160 px (80 pt at 2x): `idle` (breathes and blinks, 4.3 s), `working` (spins round with busy dots, 4.4 s) and `needs` (Hello's bounce and wiggle, then a beat of calm, 4.5 s). They are one image set per frame in `Frames.xcassets` (`oby-idle-000`…), about 1 MB in all.

`ObyAnimation.swift` plays them with a `TimelineView`. It runs only while it's on screen, the app is in front, the wrist is up (not Always On) and Reduce Motion is off; otherwise it holds the loop's first frame. A new loop starts from its first frame.

To render them again after the character changes:

```bash
npx playwright install chromium-headless-shell    # once
node Watch/Frames/render.mjs "$TMPDIR/oby-watch"
python3 Watch/Frames/compose.py "$TMPDIR/oby-watch" .   # needs Pillow
```

- `render.mjs` serves `Character/` itself, loads `oby.html?embed` in headless Chromium and drives Oby's clock by hand: every frame is exactly 1/30 s after the last, one in two is kept, and `Math.random` is pinned, so Oby looks straight ahead, blinks on a steady beat, and two runs give the same frames. The loops, their lengths and the expression each plays are `LOOPS` at the top.
- `compose.py` crops every loop the same way (Oby doesn't jump when the loop changes), crossfades each loop's last frames into the calm frames rendered just before it so the end runs into the start, scales them down and writes `Frames.xcassets`. It also writes the complications' still poses to `Widget/Assets.xcassets`. `ObyAnimation` counts the frames at launch, so other loop lengths need no code change.

## Complications and the Smart Stack

`Widget/` is the `ObyWatchWidget` extension, embedded in the watch app: one widget in the circular, corner, inline and rectangular families. The rectangular one is also the Smart Stack's; it ranks itself high there while something needs you. It shows "1 needs you" (or "2 working", "All quiet") with Oby still: waving (`ObyNeedsYou`), busy (`ObyWorking`) or calm (`ObyCalm`), and the first job that needs you on the rectangular one.

- The watch app saves the counts to the app group `group.$(OBY_IPHONE_BUNDLE_ID).watch` (`Glance.swift`, compiled into both) whenever the phone's job list arrives, and reloads the widget only when they changed. The widget never asks for a timeline of its own (`.never`).
- The list arrives while the app is open, and also in the background: watchOS wakes the app with a `WKWatchConnectivityRefreshBackgroundTask` for the phone's application context, `WatchNotifications` hands it to `Watch`, and the task ends once the session has delivered everything.
- Both targets share the `Watch` folder. The widget's exceptions list every watch-app file, so **a new file in `Watch/` joins the widget too**: add it to the "Exceptions for "Watch" folder in "ObyWatchWidget" target" (Xcode: uncheck ObyWatchWidget in the file's Target Membership) unless the widget needs it.

## How it reaches the runner

The watch can't reach the tailnet, so the iPhone stands in between (WatchConnectivity):

- `iOS/WatchRelay.swift` is the phone's side. It keeps the jobs on the watch as the application context (what needs you first, then what's running, then what finished in the last two days, trimmed to the 65 KB WatchConnectivity carries): on every change while Oby is open on the phone, when a job ends while it's in the background (the phone's background wake), and whenever the watch asks. With Oby in the background, a running job's steps wait until the watch app comes to the front and refreshes. It carries out what the watch asks as the app itself would, calling the runner (`docs/runner-api.md`). iOS wakes the phone app in the background for a message from the watch, and the relay asks for background time to finish, so it works with the phone in a pocket.
- `Watch/Watch.swift` is the watch's side: the jobs, and the requests.
- `Shared/WatchWire.swift` is what they say to each other. Fast requests (refresh, dispatch, a message to a job, stop, the publish sentence) are answered in the reply. Planning and publishing take longer than a reply may wait for, so they're acknowledged, and the outcome comes back as a message of its own, queued if the watch app isn't up.
- **Publish needs the phone's signature.** The runner accepts a publish by hand only with a fresh signature from the iPhone's Secure Enclave key, which signs after Face ID (`iOS/DeviceKey.swift`). The watch asks, and the phone signs: the crown alone never publishes. With Oby open on the phone, Face ID comes up there right away. In the background it can't, so the phone posts a notification, "Publish from your watch", whose **Publish with Face ID** is the app's own; the watch says so. With the phone locked, that alert is mirrored to the watch with no button (on purpose: Face ID is on the phone), so pick the phone up.
- Spoken requests are transcribed on the iPhone (watchOS has no SpeechAnalyzer). The first time, the phone downloads the speech model for its language and asks the watch to try again in a minute.

The watch keeps nothing but the last application context and the id of the ask it waits for.

## Run it

- **Simulator:** the `ObyWatch` scheme on a watchOS 26 simulator paired with an iPhone simulator running `ObyPhone`. The relay only works with both up; publishing needs a real iPhone (Secure Enclave).
- **Your watch:** run `ObyPhone` on your iPhone (the watch app is embedded) and Xcode installs it on the paired watch, or run the `ObyWatch` scheme with the watch as the destination.
- **TestFlight:** the iPhone build carries the watch app. Keep `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` the same on `ObyWatch` and `ObyPhone` (Apple requires it), and raise both for every upload.
- **Bundle ID:** `$(OBY_IPHONE_BUNDLE_ID).watchkitapp`, and `.watchkitapp.widget` for the complications, so moving to Deskree's team is the same switch as for the iPhone (`iOS/README.md`). Both use the app group `group.$(OBY_IPHONE_BUNDLE_ID).watch` (`Oby.entitlements`, `Widget/ObyWidget.entitlements`); automatic signing registers it.
- **Complications:** run `ObyWatch`, then long-press the watch face, Edit, and pick Oby in a complication slot; or scroll the Smart Stack.
- **Tests:** `iOSTests/WatchRelayTests.swift` checks the trimming of the job list and the relayed plan.

## Size

The watch app is Swift, Oby's frames (about 1 MB of PNGs, 198 frames), the widget with three small still poses, and the icon: far under the 75 MB cap on watch apps.

## Part of #20

The build list, as it stands after this slice:

- [x] watchOS app, embedded in the iPhone app: Home with needs-you and the running jobs with their stage, the job's stages and result, Publish with the crown, notifications mirrored from the phone, the relay through the iPhone.
- [x] Oby animated as pre-rendered frames (the pipeline that rendered the preview does this).
- [x] Complications and the Smart Stack (still poses).
- [x] Talking: audio relayed to the iPhone and transcribed there (SpeechAnalyzer), with system dictation as the fallback.

Test it when it's done:

- [ ] An approval arrives on the watch: turn the crown to approve (built; needs a real iPhone and watch).
- [ ] Home shows Oby animated, with "1 needs you · 2 working" (built; needs a real watch).
- [ ] The complication shows how many things need you (built; needs a real watch).
- [ ] Dictate a request: the Mac runs it (built; runs on the runner).

## Coming next

- With the watch app neither open nor woken, a complication shows the counts from the last list it got. Sending the list with `transferCurrentComplicationUserInfo` from `iOS/WatchRelay.swift` when what needs you changes would wake it more often (a daily budget).
