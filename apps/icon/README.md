# Oby's icon

Every Oby icon is Sangam's character itself, rendered from `Character/` rather than drawn again, so the icon always matches the Oby that lives in the notch.

```
AppIcon.icon/    Icon Composer document: iPhone, iPad, Mac and Apple Watch
exports/         everything else, from the same render
  oby-1024.png, oby-foreground-1024.png   masters
  android/       adaptive icon layers (Android and Wear OS) and the Play Store icon
  desktop/       Windows (oby.ico) and Linux (16–512 PNGs)
  web/           favicons and the home-screen icon
render.mjs       renders the character with a transparent background (headless Chromium)
compose.swift    turns the render into all of the above
```

## The Apple icon

`AppIcon.icon` has one layer, Oby, on the island's black (a dark gradient). The Mac and iPhone targets use it as `AppIcon`; the Watch app will too. The system draws the shape, Liquid Glass, and the dark, tinted and clear looks from it. Open it in Icon Composer (Xcode › Open Developer Tool) to preview every platform and appearance.

## Make the icons again

When Sangam changes the character, render it again and rebuild everything:

```bash
zsh Character/package/build.sh
```

```bash
python3 -m http.server 8770 --bind 127.0.0.1 --directory dist/oby
```

In another terminal:

```bash
node apps/icon/render.mjs "$TMPDIR/oby-render" 2048 1 4
```

```bash
swift apps/icon/compose.swift "$TMPDIR/oby-render-0.png" apps/icon
```

`render.mjs` takes four frames of Oby calm and looking ahead, at 4096 px, using Playwright's Chromium. Pick one with the eyes open (`-0` usually is). `compose.swift` crops Oby, scales it down with high-quality resampling (about 2.6×, so the edges stay clean) and writes every icon.
