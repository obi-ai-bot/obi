# design

Sangam's desktop app mockup: the look, the screens and how they fit together,
to take from when the real apps build them. Nothing outside this folder
depends on it, and it depends on nothing outside it.

```
app/   the mockup: an Electron app (React, Vite) with mock data. Home, task
       pages, conversations with Oby, the Obysphere (members, invites,
       settings, knowledge), Settings, the message box. app/README.md maps
       every file.
oby/   the mascot the mockup embeds (oby.html and three.js): the playground
       version, ahead of character/ (it adds the loading state,
       setState(name, { finish: true }) and a ready event).
```

Run it:

```bash
cd design/app && npm install && npm run dev
```

`npm run web` runs the same screens in a browser, without the window chrome.
