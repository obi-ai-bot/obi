# Oby

Oby is the assistant's face: a soft cube with two eyes. Your app tells it
what's going on (idle, listening, thinking, working) and can trigger one-off
reactions (agree, laugh, surprised…). Oby handles the rest on its own:
breathing, blinking, following the pointer, fidgeting while idle, and
reacting when it's clicked.

Everything runs locally: no network, no build step, no settings.

```
oby/
  oby.html                 Oby. Load it in a web view or an iframe.
  vendor/three.module.js   three.js 0.170 (MIT), its only dependency. Keep it next to oby.html.
  demo.html                every state and expression on one page
  mac/                     sample macOS menu bar app hosting Oby (main.swift, build.sh, Info.plist)
```

## See it

```bash
python3 -m http.server 8000 --directory oby
```

Open http://localhost:8000/demo.html. A server is needed because browsers
block ES modules loaded from `file://`. Native web views load the files
directly (see below).

## API

Everything goes through `window.oby` inside `oby.html`.

```js
oby.setState('thinking')            // what Oby does until told otherwise
oby.play('Agree')                   // one reaction now, then back to the state
await oby.play('Laugh')             // true when it finished, false if cut off
oby.setState('idle', { now: true }) // switch without waiting for a reaction to finish
oby.setState('idle', { finish: true }) // let what's playing end first (Loading: its dots run back into Oby)
oby.pause(true)                     // stop drawing while off screen; false resumes
oby.look(x, y)                      // look at a point, in the page's CSS px from its top-left; outside the frame too
oby.look(null)                      // let go: Oby looks around on its own
oby.notice(x, y)                    // something happened there (a click): a glance, then back to its business
oby.attend(true)                    // watch the pointer the whole time; false goes back to its own rhythm
oby.on('poke', ({ count }) => {})   // events (below); returns an unsubscribe function

oby.state        // current state
oby.playing      // expression playing now, or null
oby.states       // list of states
oby.expressions  // list of expressions
```

- Names are case-insensitive.
- An unknown name throws, and the error lists the valid names.
- `setState` waits for a running `play()` to finish, so calls chain:
  `oby.play('Agree'); oby.setState('working')` nods first, then gets to work.
- Asking for the state Oby is already in does nothing; add `{ now: true }`
  to start it over.
- Events arrive just after the change, so a listener can call `oby` back,
  e.g. `oby.on('end', …)` can `play()` something else.

### States

| State | What Oby does |
|---|---|
| `idle` | Waits, watching the pointer now and then. Every 7–16 s it fidgets: Distracted, Grin, Yawn or Hiding. |
| `listening` | Turns an ear to you and nods, over and over. Use it for "Hi Oby" and while the user talks. |
| `thinking` | Looks up one way, then the other, with thought dots, over and over. |
| `working` | Spins (Working) or melts into three bouncing dots (Loading), one after the other. |
| `loading` | Melts into three bouncing dots (Loading), over and over. Leave it with `{ finish: true }` and the dots run back together into Oby first. |
| `quiet` | Only breathes, blinks and follows the pointer. |

Oby starts in `idle`.

### Expressions for `play()`

| Expression | Length | Looks like |
|---|---|---|
| `Hello` | 3.4 s | happy bounce, a little wiggle, the ears wave |
| `Agree` | 2.4 s | three clear nods |
| `Disagree` | 3.0 s | disappointed "no": droopy eyes, slow head shake, a sigh |
| `Grin` | 3.0 s | happy squint with a little chuckle |
| `Laugh` | 3.0 s | shakes with laughter |
| `Surprised` | 2.8 s | jumps, eyes wide |
| `Confused` | 3.2 s | tilts, small round eyes, a question mark |
| `Tired` | 4.0 s | slumps, heavy lids, two long sighs |
| `Yawn` | 3.6 s | a big round yawn |
| `Distracted` | 4.0 s | follows a fly drifting past, then snaps back to you |
| `Hiding` | 6.8 s | ducks behind an invisible wall and peeks out |
| `Loading` | 6.0 s | melts into three bouncing dots, then back into the cube |

`Listening`, `Thinking` and `Working` can also be played once, but they're
meant for the states.

When it's clicked, Oby reacts on its own and fires `poke`:

- 1–3 clicks: startled.
- 4–5 clicks: annoyed.
- 6 or more: it turns its back, then shakes it off.

Oby forgets the clicks after 6 seconds.

### Events

| Event | Data | When |
|---|---|---|
| `ready` | `{}` | the first frame is drawn: show Oby's frame from here on, so nothing flashes while it loads |
| `state` | `{ state }` | the state changed |
| `expression` | `{ name }` | an expression started |
| `end` | `{ name, completed }` | an expression ended; `completed` is false if it was cut off |
| `poke` | `{ count }` | someone clicked Oby |

Oby doesn't stare at the pointer all the time: it watches it for 2–4 s, then
looks around or fidgets for 14–26 s. The pointer coming close to its face, or
a click, catches its eye at once; `oby.attend(true)` holds its attention.
Ease the pointer slowly towards its face and it backs away, as if the pointer
had something icky on it.

Clicks play their own reactions (`Poked`, `Annoyed`, `Ignoring you`). So does
spinning the pointer round fast (`Dizzy`), and whipping it side to side while
Oby follows it (`Shaking it off`). They show up in `expression`/`end` and
`oby.playing`, but you can't `play()` them.

A `play()` that's running while Oby is paused or hidden finishes only once
it's drawing again, because its clock stops with it.

## Integrating

The page is transparent and has no controls, so put any background behind it.
Oby sizes itself to its frame. Add `?size=1.4` to the URL to draw it bigger;
the default is `1`, which leaves room for it to move.

**macOS / iOS (WKWebView).** Bundle `oby.html` and `vendor/` side by side.

```swift
config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs") // lets it load vendor/ from the bundle
config.userContentController.add(self, name: "oby")                      // events: { oby: "poke", count: 2 }
webView.setValue(false, forKey: "drawsBackground")                       // macOS: see through to your view
webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())

// once the page has loaded (webView(_:didFinish:)); calls before that are lost
webView.evaluateJavaScript("oby.setState('thinking')")
```

- Keep the web view transparent (`alphaValue = 0`) until the `ready` event
  arrives, so nothing flashes while it loads. Don't hide it or take it out of
  the window instead: Oby draws nothing while its page is hidden, so `ready`
  would never come.
- On iOS, use `webView.isOpaque = false` and `backgroundColor = .clear` instead
  of `drawsBackground`.
- `add(self, name:)` keeps `self` alive. In a view controller, call
  `removeScriptMessageHandler(forName: "oby")` when you're done with it.

`mac/main.swift` is a complete example in about 140 lines. Run
`zsh mac/build.sh` to try it, then right-click the menu bar icon to switch
states.

**Web (iframe).**

```html
<iframe src="oby/oby.html?size=1.2" style="width:160px;height:160px;border:0"></iframe>
<script>
  const frame = document.querySelector('iframe');
  frame.addEventListener('load', () => {  // before load, messages go nowhere
    const oby = frame.contentWindow;
    oby.postMessage({ setState: 'listening' }, '*');      // { setState, now: true } switches at once
    oby.postMessage({ play: 'Agree' }, '*');
    oby.postMessage({ pause: true }, '*');
    oby.postMessage({ look: { x: 300, y: -40 } }, '*');  // frame coordinates; outside is fine
  });
  addEventListener('message', (e) => { if (e.data?.oby) console.log(e.data); }); // { oby: 'poke', count: 1 }
</script>
```

To make Oby watch the cursor across a whole window or screen, pass the
cursor's position from the frame's top-left corner to `oby.look(x, y)`; past
the frame's edge the head keeps turning but eases off. Once you call
`look()`, Oby ignores the pointer over its own frame.

Oby only takes messages from the page it's embedded in. On the same origin
you can also call `iframe.contentWindow.oby` directly.

## Power

Oby is tuned to stay cool on laptops:

- It draws at 30 fps.
- It draws nothing while paused or while the page is hidden.
- It redraws only the area around itself.

Call `oby.pause(true)` whenever it's off screen, for example when a popover
closes.
