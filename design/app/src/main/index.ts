import { app, BrowserWindow, ipcMain, screen } from 'electron';
import { createRequire } from 'node:module';
import { join } from 'node:path';

// One small window: Oby, what needs you, and a way to talk. The renderer gets
// the cursor's position wherever it is on screen, so Oby can watch it outside
// its own frame.

type Chrome = { lightsLeft: number; lightsTop: number; lightsCenterY: number; lightsRight: number };

// macOS: the native module that gives the window Safari's window type (round
// macOS 26 corners, traffic lights placed by macOS). Built by `npm run build:native`.
// Elsewhere, or if it isn't built, the window keeps Electron's own style.
const windowStyle: { useToolbarWindow(handle: Buffer): Chrome | null } | null = (() => {
  if (process.platform !== 'darwin') return null;
  try {
    return createRequire(import.meta.url)(join(__dirname, '../../native/window-style/build/Release/window_style.node'));
  } catch (err) {
    console.warn('window-style native module not loaded:', (err as Error).message);
    return null;
  }
})();

// In dev, keep drawing while the window is behind others, so automated checks
// (scroll, animations, timers) see the same thing a visible window does.
const dev = !!process.env.ELECTRON_RENDERER_URL;
if (dev) app.commandLine.appendSwitch('disable-backgrounding-occluded-windows');

// the size the window opens at
const WIDTH = 994, HEIGHT = 670;

let win: BrowserWindow | null = null;
let chrome: Chrome | null = null;
let tracker: ReturnType<typeof setInterval> | null = null;
let last = '';

// the page asks for both before it draws, to lay its title bar out around the lights
ipcMain.on('window-chrome', (e) => { e.returnValue = chrome; });
ipcMain.on('full-screen', (e) => { e.returnValue = win?.isFullScreen() ?? false; });

function track(on: boolean) {
  if (tracker) clearInterval(tracker);
  tracker = null;
  if (!on) return;
  // 60 times a second, twice Oby's frame rate, so every frame it draws has a
  // fresh position; only sends when it moved
  tracker = setInterval(() => {
    if (!win || win.isDestroyed()) return;
    const p = screen.getCursorScreenPoint();
    const b = win.getContentBounds();
    const key = `${p.x - b.x},${p.y - b.y}`;
    if (key === last) return;
    last = key;
    win.webContents.send('cursor', { x: p.x - b.x, y: p.y - b.y });
  }, 1000 / 60);
}

function createWindow() {
  win = new BrowserWindow({
    width: WIDTH,
    height: HEIGHT,
    minWidth: 420,
    minHeight: 520,
    show: false,
    backgroundColor: '#0b0b0b',
    // A native window with its title bar hidden; the native module then makes
    // it a toolbar window (see windowStyle), and handles full screen for it.
    titleBarStyle: 'hidden',
    // the click that brings the window forward from another app also reaches
    // the page: without it, macOS keeps that click, Chromium puts the focus back
    // in the message box, and a click outside it seems to do nothing
    acceptFirstMouse: true,
    // scrollBounce: macOS's rubber-band at the ends of a scroll (off by default in Electron)
    webPreferences: { preload: join(__dirname, '../preload/index.mjs'), sandbox: false, backgroundThrottling: !dev, scrollBounce: true },
  });

  chrome = windowStyle?.useToolbarWindow(win.getNativeWindowHandle()) ?? null;
  if (chrome) {
    // keep the traffic lights where macOS put them for this window type;
    // otherwise Electron moves them back to its own default spot
    win.setWindowButtonPosition({ x: Math.round(chrome.lightsLeft), y: Math.round(chrome.lightsTop) });
    // adding the toolbar grows the window by its height; size it back
    win.setSize(WIDTH, HEIGHT);
  }
  win.once('ready-to-show', () => win?.show());
  // stop watching the cursor while nobody can see Oby
  win.on('show', () => track(true));
  win.on('restore', () => track(true));
  win.on('hide', () => track(false));
  win.on('minimize', () => track(false));
  win.on('closed', () => { track(false); win = null; });
  // full screen hides the traffic lights: the page moves its title bar over.
  // Besides entering and leaving, re-check whenever the window comes back
  // (switching Spaces between full-screen apps), so the page never drifts.
  const sendFullScreen = () => { if (win && !win.isDestroyed()) win.webContents.send('full-screen', win.isFullScreen()); };
  for (const ev of ['enter-full-screen', 'leave-full-screen', 'focus', 'blur', 'show', 'resize'] as const) win.on(ev as 'focus', sendFullScreen);

  if (dev) win.loadURL(process.env.ELECTRON_RENDERER_URL!);
  else win.loadFile(join(__dirname, '../renderer/index.html'));
}

app.whenReady().then(() => {
  // the Dock icon while developing (a packaged app takes build/icon.icns)
  if (process.platform === 'darwin') app.dock?.setIcon(join(__dirname, '../../build/icon.png'));
  createWindow();
  app.on('activate', () => { if (!win) createWindow(); });
});

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
