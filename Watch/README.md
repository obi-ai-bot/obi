# Oby for Apple Watch

The watch app is the `ObyWatch` target in `Oby.xcodeproj` (on the wrist it's called Oby), shipped inside the iPhone app: the iPhone build on TestFlight installs it on the paired watch. It's F16 ([#20](https://github.com/deskree-inc/oby/issues/20)); this is its second slice.

What it does today:

- **Home:** Oby is centered in the upper safe area, about half the screen's width, with a separate round microphone below. There is no title or status text. The layout uses the available safe-area size, and trims only the idle/needs frames' transparent top margin; working keeps its busy dots. A small orange needs-you dot stays on Oby's corner, and VoiceOver reads the counts. Home and the job list are vertical pages: turning the Digital Crown down (or swiping up) goes to the jobs, and turning it up comes back to Oby; while the talk card is up, the crown scrolls the card first. Tapping a job opens its stages and results, and a notification still lands on its job. Tapping Oby plays a reaction, as `Character/oby.html` does for clicks: taps within 6 seconds of the last one count up; taps 1 to 3 startle him (poked), the 4th and 5th annoy him, and from the 6th on he ignores you (a tap starts that again); 6 seconds without a tap start the count over (`Shared/Pokes.swift`). Each tap gives a light haptic, and when the reaction ends Oby goes back to his loop. With Reduce Motion on, a tap gives only the haptic. VoiceOver's hint on Oby says to turn the crown or swipe up for the jobs, and Oby has a **Show jobs** action.
- **Publish with the crown:** on a job ready to publish, Publish shows the exact sentence the runner would carry out, and turning the Digital Crown confirms it: the ring fills as it turns, and a full turn publishes. A tap can't do it by mistake. The signature is the iPhone's (below).
- **Notifications:** the alerts the runner sends the iPhone ("Couldn't publish", "Failed", "Interrupted") reach the watch as mirrored notifications. The watch registers the same categories, so a "ready" alert offers **Publish** (the job opens and asks for the crown) and **Open**; tapping one opens the job.
- **Talk to Oby:** tap the round microphone and speak; tap it again (now a red Stop) to stop. The words appear live in a card under Oby as you speak: from the iPhone's transcription when it's in reach, or from the runner's Whisper through the Watch API when it isn't (below). Stopping keeps them as a draft and sends nothing; **Send** asks Oby with one tap, the mic adds more words (joined with a space), and **Clear** drops them. Listening also stops, keeping the words, after 60 seconds, when the screen turns off (wrist down, the app inactive), on leaving Home and when a notification opens a job. The microphone opens synchronously on the tap and is open only while listening: Stop, the limit, any of those, or an error closes it before anything else happens. A tap and a stop within 0.4 s with no words leaves the draft as it was, and so does an empty result ("Oby didn't catch that"). Permission is asked when Home opens. While listening, the watch converts the microphone to mono 16 kHz Int16 PCM (32 KB/s) and sends it in sequence, each chunk after the last one's acknowledgement. The watch keeps everything not yet sent (at most 60 s, ~1.9 MB), so a slow line delays the words instead of dropping them, and a backlog goes in chunks of up to a second to catch up. Audio captured before Stop still goes. Through the phone, SpeechAnalyzer with SpeechTranscriber volatile results sends back the whole evolving transcript (tentative words replace earlier guesses); Stop sends an explicit end, and the phone answers with the final words and plans nothing: only Send does (`plan`, `Shared/WatchWire.swift`). Home shows a level meter while listening, below a smaller Oby. The reply, question or plan stays in the card, scrollable with the crown; dispatch takes one tap. Done/Cancel dismisses it, and tapping the mic replaces it. If the iPhone is out of reach and the watch isn't paired, microphone permission is denied, or the line fails, what was heard stays in the draft and the mic opens system dictation/scribble instead; its words join the draft too. Requests sent while the phone is out of reach (unpaired) queue for it; dismissing cancels an undelivered transfer. Live audio and partial words are never queued for background delivery. The phone expires a stream after 30 seconds without a new chunk, or when its background time expires.
- **Tell the agent**, **Dismiss** and **Stop job** on a job's screen, as on the iPhone.
- **Without the iPhone:** once paired, the watch calls the runner itself when the phone is out of reach, and goes back to the phone when it's back (below).
- **Complications and the Smart Stack:** how many things need you, with Oby in a still pose (below).

## Oby animated

watchOS has no WebKit, so Oby plays as frames rendered from `Character/oby.html`, as the preview's Oby and the icon were (`Icon/render.mjs`). There are three loops at 15 fps, 160 px (80 pt at 2x): `idle` (breathes and blinks, 4.3 s), `working` (spins round with busy dots, 4.4 s) and `needs` (Hello's bounce and wiggle, then a beat of calm, 4.5 s). Three reactions to taps play once, at the same rate and crop, each ending calm: `poked` (startled, 1.7 s, 26 frames), `annoyed` (2.5 s, 38 frames) and `ignoring` (turns away, peeks, then shakes it off, 5.3 s, 80 frames). They are one image set per frame in `Frames.xcassets` (`oby-idle-000`…), about 1.9 MB in all.

`ObyAnimation.swift` plays them with a `TimelineView`. It runs only while it's on screen, the app is in front, the wrist is up (not Always On) and Reduce Motion is off; otherwise it holds the loop's first frame. A new loop starts from its first frame. A reaction plays once over the loop, and a new tap starts it again; when it ends, the current loop (which may have changed meanwhile) starts from its first frame. Oby stopping (the wrist down, the app in the background) drops the reaction.

To render them again after the character changes:

```bash
npx playwright install chromium-headless-shell    # once
node Watch/Frames/render.mjs "$TMPDIR/oby-watch"
python3 Watch/Frames/compose.py "$TMPDIR/oby-watch" .   # needs Pillow
```

- `render.mjs` serves `Character/` itself, loads `oby.html?embed` in headless Chromium and drives Oby's clock by hand: every frame is exactly 1/30 s after the last, one in two is kept, and `Math.random` is pinned, so Oby looks straight ahead, blinks on a steady beat, and two runs give the same frames. The loops and reactions, their lengths and the expression each plays are `LOOPS` at the top; a reaction's `poke` is how many clicks land on Oby's drawn body at once (oby.html plays the last one's reaction).
- `compose.py` takes its crop from the three loops and crops every sequence the same way (Oby doesn't jump when the loop changes or a reaction plays), crossfades each sequence's last frames into the calm frames rendered just before it so the end runs into the start, scales them down and writes `Frames.xcassets`. It also writes the complications' still poses to `Widget/Assets.xcassets`. `ObyAnimation` counts the frames at launch, so other lengths need no code change.

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
- **Publish needs the phone's signature.** The runner accepts a publish by hand only with a fresh signature from the iPhone's Secure Enclave key, which signs after Face ID (`Shared/DeviceKey.swift`). The watch asks, and the phone signs: the crown alone never publishes. With Oby open on the phone, Face ID comes up there right away. In the background it can't, so the phone posts a notification, "Publish from your watch", whose **Publish with Face ID** is the app's own; the watch says so. With the phone locked, that alert is mirrored to the watch with no button (on purpose: Face ID is on the phone), so pick the phone up.
- Spoken requests are transcribed on the iPhone (watchOS has no SpeechAnalyzer). The first time, the phone downloads the speech model for its language and asks the watch to try again in a minute.

The watch keeps the last application context and the id of the ask it waits for. Live audio is buffered only in memory while listening; no recording file is kept.

### Without the iPhone

watchOS has no Tailscale or VPN, so a paired watch reaches the runner's Watch API through a Cloudflare Tunnel behind Cloudflare Access (`docs/runner-api.md`, "The Watch API"; setting it up: `Runner/README.md`). `Watch/WatchLink.swift` is that line: plain HTTPS from `URLSession`.

- **Pairing** (`iOS/WatchPairing.swift`, Settings › Apple Watch without iPhone on the phone): the watch makes a P-256 key in its Secure Enclave (CryptoKit) and hands the public half to the phone over WatchConnectivity; Face ID on the phone approves it; the runner keeps the key, and the Access service token in its vault; the watch gets its id, the Watch API's address and the token, kept in the keychain of the app group, so the widget can use them too. Swiping the watch away on the phone unpairs it.
- **Every request** carries the service token (Access lets it through and adds its JWT) and the watch's signature over the method, path, body, time and a fresh nonce, so a replayed request fails.
- **Which way:** with the phone reachable, the relay as above; otherwise the Watch API, switching back by itself when the phone is in reach. The runner's events stream only while Oby is on screen (`ObyWatchApp` tells `Watch`); otherwise the jobs come with each refresh, push and complication reload.
- **Publish** without the phone: the crown's full turn sends the runner's sentence back in a request signed by the watch's key; there's no Face ID on the watch, and the watch locks itself off the wrist.
- **Stop** waits for the phone: the Watch API has none.
- **Notifications:** the watch registers its own device token with the runner, which sends it the same alerts as the phone, with the same payload and collapse ID, so each shows once. A background push clears an alert once its job needs nothing.
- **Complications:** the widget gets a WidgetKit push token (`GlancePushHandler`) and uploads it to the runner itself whenever it's issued or rotated; until the runner accepts the latest one, the widget and the app try again whenever they run (`Shared/WidgetToken.swift`). The runner pushes when the counts change, and the widget fetches the jobs itself.
- **Talking:** the audio goes to the runner in pieces of up to a second, in order (`POST /v1/speech?request=<id>&sequence=<n>`, PCM as above), and each answer `{"text": "…"}` is the whole transcript so far, which may change and may lag the audio: the runner decides how often Whisper runs. Stop sends the rest, then `&final=true` with an empty body, answered with the final words `{"text": "…", "final": true}`. The runner's Watch API doesn't pass pieces on to Whisper yet and answers `501` at the first piece: the watch then stops listening, keeps what it had, and the mic opens the system's dictation.

## Run it

- **Simulator:** the `ObyWatch` scheme on a watchOS 26 simulator paired with an iPhone simulator running `ObyPhone`. The relay only works with both up; publishing needs a real iPhone (Secure Enclave).
- **Your watch:** run `ObyPhone` on your iPhone (the watch app is embedded) and Xcode installs it on the paired watch, or run the `ObyWatch` scheme with the watch as the destination.
- **TestFlight:** the iPhone build carries the watch app. Keep `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` the same on `ObyWatch` and `ObyPhone` (Apple requires it), and raise both for every upload.
- **Bundle ID:** `$(OBY_IPHONE_BUNDLE_ID).watchkitapp`, and `.watchkitapp.widget` for the complications, so moving to Deskree's team is the same switch as for the iPhone (`iOS/README.md`). Both use the app group `group.$(OBY_IPHONE_BUNDLE_ID).watch` (`Oby.entitlements`, `Widget/ObyWidget.entitlements`); automatic signing registers it.
- **Complications:** run `ObyWatch`, then long-press the watch face, Edit, and pick Oby in a complication slot; or scroll the Smart Stack.
- **Tests:** `iOSTests/WatchRelayTests.swift` checks the trimming of the job list and the relayed plan; `iOSTests/PokesTests.swift` checks how taps on Oby count.

## Size

The watch app is Swift, Oby's frames (about 1.9 MB of PNGs, 342 frames), the widget with three small still poses, and the icon: far under the 75 MB cap on watch apps.

## Part of #20

The build list, as it stands after this slice:

- [x] watchOS app, embedded in the iPhone app: Home with needs-you and the running jobs with their stage, the job's stages and result, Publish with the crown, notifications mirrored from the phone, the relay through the iPhone.
- [x] Oby animated as pre-rendered frames (the pipeline that rendered the preview does this).
- [x] Complications and the Smart Stack (still poses).
- [x] Talking: audio relayed to the iPhone and transcribed there (SpeechAnalyzer), with system dictation as the fallback.

Test it when it's done:

- [ ] An approval arrives on the watch: turn the crown to approve (built; needs a real iPhone and watch).
- [ ] Home shows Oby animated, with "1 needs you · 2 working" (built: the pose and the count on Oby's corner say it, and VoiceOver reads the line; needs a real watch).
- [ ] The complication shows how many things need you (built; needs a real watch).
- [ ] Dictate a request: the Mac runs it (built; runs on the runner).

## Verification for this Home/talking rework

The Linux runner can parse Swift syntax and exercise the Watch model with a mock transport; it cannot compile or run Apple targets. Before release, verify on Xcode and paired hardware:

- Watch and iPhone builds, simulator installation and existing iOSTests.
- Layout on 41–49 mm watches, including Series 10, clock safe area, all poses, the dot, Dynamic Type and Reduce Motion.
- Live SpeechAnalyzer results, corrections without duplicate words, finalization on Stop with no plan until Send, language/model availability, PCM conversion and first-use download.
- Reachable but locked/backgrounded iPhone, disconnection while listening, slow transport, mic denial, system dictation fallback, and queued request dismissal.
- The microphone reason in `Watch/en.lproj` and `Watch/pt.lproj` (`InfoPlist.strings`) replaces the project's old hold-to-talk wording, as on the iPhone: check that Xcode bundles it (the widget picks the files up too, harmlessly) and that a fresh install shows it.
- Tap to listen and tap Stop: start/stop haptics, the red Stop, the meter, and the microphone indicator only while listening. Stop, the 60-second limit, the screen turning off, paging to the jobs and a notification all close the mic and keep the words; none sends anything.
- Live words under Oby through the phone and through the runner, the draft after Stop, Send with one tap, the mic adding more words to a draft, Clear, and a quick tap-stop or silence leaving the draft as it was.
- Crown scrolling for long drafts/replies/plans (Send scrolls into view), one-tap dispatch, and tapping the mic while planning/dispatch is pending.

## Verification for Home's pages and tap reactions

Not built here (no Xcode on the Linux runner). On a real watch:

- The crown down (or a swipe up) from Home goes to the jobs, and up comes back to Oby; the page indicator shows two pages. With a long reply or draft up, the crown scrolls the card first, then turns the page.
- Tapping a job opens it; a notification opens its job from either page; the needs-you dot stays on Oby; going to the jobs while listening stops and keeps the words.
- Taps on Oby: poked for 1 to 3, annoyed for 4 and 5, ignoring from 6 on (restarting on each tap), back to poked after 6 seconds alone; a light haptic on every tap; back to idle, working or needs at the end without a jump. With Reduce Motion on, only the haptic.
- VoiceOver: Oby's hint, and the **Show jobs** action in the actions rotor.

## Verification for the Watch without its iPhone

The runner's side (the Watch API, the JWT and signature checks, replays, pairing, pushes) is tested in `RunnerTests/WatchTests.swift`. Nothing on the Apple side could be built or run here (no Xcode on the Linux runner). To verify on Xcode and real devices:

- The watch app, the widget (it now compiles `Shared/` too, except `Character.swift`) and the iPhone app build; `WKRunsIndependentlyOfCompanionApp` is on.
- The Secure Enclave key on the watch, and the keychain items shared with the widget through the app group (`kSecAttrAccessGroup` set to the group).
- Pairing from the phone's Settings with Face ID, and removing a watch.
- With the phone off or in airplane mode, over Wi-Fi or LTE: jobs, events while on screen, planning, dispatch, a message, Dismiss, Publish with the crown, and the switch back to the relay when the phone returns.
- The watch's own APNs token (`aps-environment` in both entitlements), alerts arriving once with both devices near, and the clearing push.
- WidgetKit push (`pushHandler`, topic `<watch app bundle ID>.push-type.widgets`) reloading the complication.
- The talk button falling back to dictation at the runner's `501`, keeping what was heard; once the Watch API passes pieces to Whisper (`{"text": …}` answers and `final=true`), live words and the final draft without the phone.

## Coming next

- With the watch app neither open nor woken, a complication shows the counts from the last list it got. Sending the list with `transferCurrentComplicationUserInfo` from `iOS/WatchRelay.swift` when what needs you changes would wake it more often (a daily budget).
