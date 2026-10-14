# Oby

Oby is the face of the assistant: a soft cube with two eyes. The app tells it
what's going on (idle, listening, thinking, working) and fires one-off
expressions (agree, laugh, surprised…). Oby handles the rest on its own:
breathing, blinking, following the pointer, fidgeting when idle, and reacting
when someone clicks it.

The folder works on its own with no network or build step.

```
character/
  oby.html                 Oby: one page with all the code
  vendor/three.module.js   three.js 0.170 (MIT), the only dependency
  mac/                     sample macOS menu bar app that hosts Oby
  package/                 builds the clean copy the Oby app ships (see below)
```

## This copy vs. the package

This folder is the working copy: the playground with sliders and every
expression. The clean copy the Oby app ships is built from it:

```bash
zsh character/package/build.sh    # → dist/oby and dist/oby.zip
```

The build:

- strips every `dev:start … dev:end` block (the playground);
- keeps only the expressions in `KEEP` in `package/build.sh`;
- adds `package/README.md` (the integrator's docs) and `package/demo.html`.

The look in the package is fixed to `LOOK` in `oby.html`. The history of this
folder before it moved here is kept in the `character-dev-final` tag.

## Try it

Open the playground in a browser. It needs a local server, because browsers
block ES modules loaded from `file://`:

```bash
python3 -m http.server 5173 --directory Character
```

Then open http://localhost:5173/oby.html. The top row of buttons sets the
state, and the buttons below play single expressions. Space or → steps through
the expressions.

To try the menu bar app, run `zsh character/mac/build.sh`. Click the icon to open
Oby, and right-click it to switch states or say hi.

## Calling Oby

Everything goes through `window.oby`.

```js
oby.setState('thinking')            // what Oby does on its own until told otherwise
oby.play('Agree')                   // one expression now, then back to the state
await oby.play('Laugh')             // resolves true when it finished, false if cut off
oby.setState('idle', { now: true }) // switch without waiting for a play() to finish
oby.pause(true)                     // stop drawing (e.g. window hidden); false resumes
oby.on('poke', ({ count }) => {})   // events, see below; returns an unsubscribe function

oby.state      // 'thinking'
oby.playing    // 'Thinking', or null between expressions
oby.states     // ['idle', 'listening', 'thinking', 'working', 'quiet']
oby.expressions
```

Names are case-insensitive. An unknown name throws, and the error lists the
valid names.

`setState` waits for a running `play()` to finish first. That lets you chain
calls. For example, this is "Hi Oby":

```js
oby.play('Hello')            // waves…
oby.setState('listening')    // …then listens, once the wave is done
```

- Asking for the state Oby is already in does nothing; add `{ now: true }`
  to start it over.
- Events arrive just after the change, so a listener can call `oby` back,
  e.g. `oby.on('end', …)` can `play()` something else.

### States

A state is a list of expressions Oby picks from, with a pause between them.
During the pauses it idles: it breathes, blinks, and follows the pointer. The
states are defined in `STATES` in `oby.html`; change the lists and pauses
there.

| State       | Plays                                                 | Pause between |
|-------------|-------------------------------------------------------|---------------|
| `idle`      | Distracted, Wink, Grin, Yawn, Hiding, Sleepy (random) | 7–16 s        |
| `listening` | Listening, over and over                              | none          |
| `thinking`  | Thinking, over and over                               | none          |
| `working`   | Working and Loading, taking turns                     | 0.3–0.8 s     |
| `quiet`     | nothing; idles only                                   | none          |

### Expressions

Any of these can be passed to `play()`:

| Expression | Length | What it does |
|---|---|---|
| Hello | 3.4 s | happy bounce, a little wiggle |
| Listening | 3.8 s | turns an ear to you, eyes on you, a nod |
| Agree | 2.4 s | three clear nods |
| Disagree | 3.0 s | disappointed "no": droopy eyes, slow head shake, a sigh |
| Thinking | 4.6 s | looks up left, then up right, thought dots |
| Working | 3.8 s | spins all the way round, busy dots |
| Loading | 6.0 s | melts into three bouncing dots, then back into the cube |
| Grin | 3.0 s | happy squint with a little chuckle |
| Wink | 2.2 s | winks |
| Laugh | 3.0 s | shakes with laughter |
| Surprised | 2.8 s | jumps, eyes wide |
| Confused | 3.2 s | tilts, small round eyes, a question mark |
| Unwilling | 3.8 s | "no thanks": nose up, turns away, one side-eye back |
| Sad | 4.0 s | droops |
| Angry | 3.2 s | head down, ready to ram |
| Tired | 4.0 s | slumps, heavy lids, two long sighs |
| Yawn | 3.6 s | a big round yawn |
| Distracted | 4.0 s | follows a fly drifting past, then snaps back to you |
| Hiding | 6.8 s | ducks behind an invisible wall and peeks out |
| Sleepy | 6.8 s | nods off, snores, wakes up |

Clicking Oby plays its own reactions and fires a `poke` event:

- 1–3 clicks: startled.
- 4–5 clicks: annoyed.
- 6 or more: it turns its back, then shakes it off.

After 6 seconds without a click, it forgets the count.

### Events

| Event | Data | When |
|---|---|---|
| `state` | `{ state }` | the state changed |
| `expression` | `{ name }` | an expression started |
| `end` | `{ name, completed }` | an expression ended; `completed` is false if it was cut off |
| `poke` | `{ count }` | someone clicked Oby |

Clicks play their own reactions (`Poked`, `Annoyed`, `Ignoring you`). They
show up in `expression`/`end` and `oby.playing`, but you can't `play()` them.

A `play()` that's running while Oby is paused or hidden finishes only once
it's drawing again, because its clock stops with it.

## Putting Oby in an app

**Native macOS / iOS (WKWebView).** Bundle `oby.html` and `vendor/` together
and load the page with `loadFileURL`. Turn on `allowFileAccessFromFileURLs`
so the page can load three.js from the bundle. Then:

```swift
config.userContentController.add(self, name: "oby")  // before creating the web view; events arrive as { oby: "poke", count: 2 }
// once the page has loaded (webView(_:didFinish:)); calls before that are lost
webView.evaluateJavaScript("oby.setState('thinking')")
```

`mac/main.swift` does all of this in about 150 lines.

**Web (iframe).** Add `?embed` to the URL to hide the controls and make the
background transparent. Add `&size=1.4` to make Oby bigger in a small frame;
the default is `1`.

```html
<iframe src="oby/oby.html?embed&size=1.4" style="width:120px;height:120px;border:0"></iframe>
<script>
  const frame = document.querySelector('iframe');
  frame.addEventListener('load', () => {  // before load, messages go nowhere
    const oby = frame.contentWindow;
    oby.postMessage({ setState: 'listening' }, '*');      // { setState, now: true } switches at once
    oby.postMessage({ play: 'Agree' }, '*');
    oby.postMessage({ pause: true }, '*');
  });
  addEventListener('message', (e) => { if (e.data?.oby) console.log(e.data); }); // { oby: 'poke', count: 1 }
</script>
```

## Power

Oby was tuned after it made a laptop run hot. Keep these when changing it:

- It draws at 30 fps and nothing at all while paused or hidden. Call
  `oby.pause(true)` whenever it's off screen.
- It redraws only the box around the cube, not the whole canvas.
- No antialiasing (MSAA) and no extra render passes.
- The face texture is uploaded only when the face changes.

## Look

Its look comes from four sliders in the playground: size, roundness, width
and height. They start from `LOOK` in `oby.html` (the size slider starts at
56% to leave room for the controls). Values a viewer changes are saved in
that browser's `localStorage` under `cube.*`, but not with `?embed`.

Drawing rules:

- **The black shapes are the eyes.** The white dot is only a reflection. To
  make Oby look somewhere, move the whole eyes; never move or resize the dot.
- Keep it one squishy, fluid form. Don't build it from separate boxes.
- Props are flat ink drawn on top, with no outline of their own.
