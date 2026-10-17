// Renders Oby's watch loops from character/oby.html, frame by frame, through headless Chromium's
// DevTools protocol (the pipeline of apps/icon/render.mjs, on a stepped clock so every frame is
// exactly 1/30 s after the last and two runs give the same frames).
// Usage: node apps/watch/Frames/render.mjs <out-dir> [css-size] [oby-size]
// Then: python3 apps/watch/Frames/compose.py <out-dir> apps/watch/Frames.xcassets
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir, homedir } from 'node:os';

const [out = join(tmpdir(), 'oby-watch-frames'), cssSize = '320', obySize = '1.25'] = process.argv.slice(2);
const characterDir = resolve(dirname(fileURLToPath(import.meta.url)), '../../../character');

// The loops. Oby is simulated at 30 fps and every `every`th frame is kept (15 fps on the watch).
// `pre` frames of calm come before the loop starts; compose.py crossfades the loop's last frames
// into them, so the end runs into the start without a jump.
const LOOPS = [
  // Calm: breathes, blinks, glances about.
  { name: 'idle', frames: 64, pre: 8, every: 2 },
  // Spins all the way round with busy dots, then settles.
  { name: 'working', play: 'Working', frames: 66, pre: 8, every: 2 },
  // A happy bounce and a wiggle to say something is waiting, then a beat of calm.
  { name: 'needs', play: 'Hello', frames: 68, pre: 8, every: 2 },
  // Tapping Oby, played once each, as oby.html reacts to clicks: the first pokes startle it, the
  // 4th annoys it, the 6th makes it turn away and then shake it off. `poke` is how many clicks
  // land at once (oby.html counts them; only the last one's reaction plays).
  { name: 'poked', poke: 1, frames: 26, pre: 6, every: 2 },
  { name: 'annoyed', poke: 4, frames: 38, pre: 6, every: 2 },
  { name: 'ignoring', poke: 6, frames: 80, pre: 6, every: 2 },
];

function findChrome() {
  if (process.env.CHROME) return process.env.CHROME;
  for (const root of [join(homedir(), 'Library/Caches/ms-playwright'), join(homedir(), '.cache/ms-playwright')]) {
    if (!existsSync(root)) continue;
    for (const dir of readdirSync(root).filter((d) => d.startsWith('chromium_headless_shell')).sort().reverse()) {
      for (const sub of readdirSync(join(root, dir))) {
        const bin = join(root, dir, sub, 'chrome-headless-shell');
        if (existsSync(bin)) return bin;
      }
    }
  }
  throw new Error('No chrome-headless-shell: run `npx playwright install chromium-headless-shell` or set CHROME.');
}

// character/ over HTTP: browsers won't load ES modules from file://.
const types = { '.html': 'text/html', '.js': 'text/javascript' };
const server = createServer((req, res) => {
  const path = resolve(characterDir, '.' + decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!path.startsWith(characterDir) || !existsSync(path)) { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'content-type': types[extname(path)] || 'application/octet-stream' }).end(readFileSync(path));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const pagePort = server.address().port;

const port = 9334;
// On Linux, WebGL runs on SwiftShader, and Chromium's own sandbox can't start inside another
// one (Oby's runner): it only ever loads character/ from this machine.
const platform = process.platform === 'darwin' ? ['--use-angle=metal'] : ['--use-angle=swiftshader', '--no-sandbox'];
const proc = spawn(findChrome(), [`--remote-debugging-port=${port}`, '--headless', '--hide-scrollbars', ...platform,
  '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', `--user-data-dir=${join(tmpdir(), 'oby-watch-chrome')}`, 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let targets;
for (let i = 0; i < 50 && !targets; i++) {
  try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); } catch { await sleep(200); }
}
const page = targets.find((t) => t.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0;
const pending = new Map();
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
});
const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
const js = async (expression) => {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails));
  return r.result?.result?.value;
};

// Oby's clock is driven by hand: requestAnimationFrame only queues and performance.now() is what
// we say it is. Math.random is always 0.5: Oby looks straight at you and blinks on a steady beat
// (every 3.95 s), so every run gives the same frames and a loop's end meets its start without
// the eyes jumping.
const STEP = `(() => {
  let now = 0, n = 0;
  const queue = new Map();
  window.requestAnimationFrame = (cb) => { queue.set(++n, cb); return n; };
  window.cancelAnimationFrame = (k) => { queue.delete(k); };
  performance.now = () => now;
  Math.random = () => 0.5;
  window.__step = (frames) => {
    for (let i = 0; i < frames; i++) {
      now += 1000 / 30;
      const due = [...queue.values()]; queue.clear();
      for (const cb of due) cb(now);
    }
    return true;
  };
})();`;

const size = parseInt(cssSize, 10);
await send('Emulation.setDeviceMetricsOverride', { width: size, height: size, deviceScaleFactor: 2, mobile: false });
await send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
await send('Page.enable');
await send('Page.addScriptToEvaluateOnNewDocument', { source: STEP });

const shot = async (file) => {
  const s = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
  writeFileSync(file, Buffer.from(s.result.data, 'base64'));
};

for (const loop of LOOPS) {
  const dir = join(out, loop.name);
  mkdirSync(dir, { recursive: true });
  await send('Page.navigate', { url: `http://127.0.0.1:${pagePort}/oby.html?embed&size=${obySize}` });
  for (let i = 0; i < 50 && !(await js('!!window.oby && !!window.__step')); i++) await sleep(100);
  // Calm and looking ahead, the way Oby settles on the watch; nothing plays on its own.
  await js(`document.dispatchEvent(new PointerEvent('pointerleave')); oby.setState('quiet', { now: true }); true`);
  await js('__step(45)');
  for (let i = 0; i < loop.pre; i++) {
    await js(`__step(${loop.every})`);
    await sleep(30);
    await shot(join(dir, `pre-${String(i).padStart(3, '0')}.png`));
  }
  if (loop.play) await js(`oby.play('${loop.play}'); true`);
  if (loop.poke) {
    // Clicks land only on Oby's drawn body (oby.html reads the pixel), so the first click searches
    // the stage for it, and the rest land on the same spot.
    const pokes = await js(`(async () => {
      let count = 0; const off = oby.on('poke', (e) => { count = e.count; });
      const settle = () => new Promise((r) => queueMicrotask(r));  // oby.html emits in a microtask
      const stage = document.getElementById('stage');
      const click = (x, y) => stage.dispatchEvent(new PointerEvent('pointerdown', { clientX: x, clientY: y, bubbles: true }));
      let hit;
      for (let y = innerHeight * 0.3; y < innerHeight * 0.8 && !hit; y += 6)
        for (let x = innerWidth * 0.3; x < innerWidth * 0.7 && !hit; x += 6) { click(x, y); await settle(); if (count) hit = [x, y]; }
      for (let i = 1; hit && i < ${loop.poke}; i++) click(...hit);
      await settle(); off(); return count;
    })()`);
    if (pokes !== loop.poke) throw new Error(`${loop.name}: ${pokes} pokes landed, wanted ${loop.poke}`);
  }
  for (let i = 0; i < loop.frames; i++) {
    await js(`__step(${loop.every})`);
    await sleep(30);
    await shot(join(dir, `${String(i).padStart(3, '0')}.png`));
  }
  console.log(`${loop.name}: ${loop.frames} frames`);
}

ws.close();
proc.kill();
server.close();
console.log('done:', out);
