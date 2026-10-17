// Renders Sangam's Oby (dist/oby/oby.html) with a transparent background through headless
// Chromium's DevTools protocol. Usage: node render.mjs <out-prefix> <css-size> <oby-size> <shots>
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const [prefix, cssSize = '2048', obySize = '1', shots = '6'] = process.argv.slice(2);
const chrome = `${process.env.HOME}/Library/Caches/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell`;
const port = 9333;
const proc = spawn(chrome, [`--remote-debugging-port=${port}`, '--headless', '--hide-scrollbars', '--use-angle=metal',
  '--enable-gpu-rasterization', '--ignore-gpu-blocklist', `--user-data-dir=${process.env.TMPDIR}/oby-icon-chrome`, 'about:blank'], { stdio: 'ignore' });
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

const size = parseInt(cssSize, 10);
await send('Emulation.setDeviceMetricsOverride', { width: size, height: size, deviceScaleFactor: 2, mobile: false });
await send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
await send('Page.enable');
await send('Page.navigate', { url: `http://127.0.0.1:8770/oby.html?size=${obySize}` });
await sleep(3500);
console.log('webgl:', await js(`(() => { const c = document.querySelector('canvas'); return c ? c.width + 'x' + c.height : 'no canvas' })()`));
// Calm and looking ahead, the way Oby settles in the window.
await js(`document.dispatchEvent(new PointerEvent('pointerleave')); oby.setState('quiet', { now: true }); true`);
await sleep(2500);
for (let i = 0; i < parseInt(shots, 10); i++) {
  const shot = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
  writeFileSync(`${prefix}-${i}.png`, Buffer.from(shot.result.data, 'base64'));
  await sleep(700);
}
ws.close();
proc.kill();
console.log('done');
