import { useEffect, useRef, useState } from 'react';

type Point = { x: number; y: number };

// Oby in a small frame (character/oby.html, copied in as oby/ by the build), on
// this page's own origin, so every message goes to that origin only. The page
// sends it the pointer (`look`) and clicks (`notice`) as Sangam's design does;
// character/ follows them once #499 lands, and until then Oby watches the
// pointer only over its own frame. The frame stays hidden until Oby's first frame
// is drawn, so nothing the browser paints in it while it loads can flash; a
// character/ that doesn't say so yet (#499 adds its ready event) shows once
// its page has loaded.
export default function Oby({ paused = false, glance = false }: { paused?: boolean; glance?: boolean }) {
  const frame = useRef<HTMLIFrameElement>(null);
  // where the cursor last was, in the frame's coordinates (what a glance looks at)
  const last = useRef<Point | null>(null);
  // hidden (paused): clicks elsewhere in the app aren't Oby's business
  const hidden = useRef(paused);
  hidden.current = paused;

  useEffect(() => {
    const el = frame.current!;
    const send = (msg: object) => el.contentWindow?.postMessage(msg, location.origin);
    const look = (p: Point) => {
      const r = el.getBoundingClientRect();
      last.current = { x: p.x - r.left, y: p.y - r.top };
      send({ look: last.current });
    };

    // a click anywhere in the window catches Oby's eye,
    // while it's in sight
    const onClick = (e: PointerEvent) => {
      // (one passed on from its own frame is a poke, which the frame handles)
      if (hidden.current || e.target === el) return;
      const r = el.getBoundingClientRect();
      send({ notice: { x: e.clientX - r.left, y: e.clientY - r.top } });
    };
    addEventListener('pointerdown', onClick, true);

    // The page's pointer, plus the pointer over Oby's own frame (same origin),
    // turned into page coordinates
    const onPage = (e: PointerEvent) => look({ x: e.clientX, y: e.clientY });
    const onFrame = (e: PointerEvent) => {
      const r = el.getBoundingClientRect();
      look({ x: e.clientX + r.left, y: e.clientY + r.top });
    };
    const hookFrame = () => el.contentWindow?.addEventListener('pointermove', onFrame);
    addEventListener('pointermove', onPage);
    el.addEventListener('load', hookFrame);
    hookFrame();
    return () => {
      removeEventListener('pointerdown', onClick, true);
      removeEventListener('pointermove', onPage);
      el.removeEventListener('load', hookFrame);
      el.contentWindow?.removeEventListener('pointermove', onFrame);
    };
  }, []);

  // A click on Oby's frame is a click in the page too: passed on from the frame
  // (same origin) as a pointerdown on it, so whatever closes on a click outside
  // it (a menu, the message box's panels) hears it as well
  useEffect(() => {
    const el = frame.current!;
    const pass = (e: PointerEvent) => {
      const r = el.getBoundingClientRect();
      el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, composed: true, clientX: e.clientX + r.left, clientY: e.clientY + r.top, pointerId: e.pointerId, pointerType: e.pointerType, button: e.button, buttons: e.buttons }));
    };
    // (a frame that isn't same-origin, as a packaged build could make it, is left alone)
    const hook = () => { try { el.contentWindow?.addEventListener('pointerdown', pass, true); } catch { /* not ours to reach */ } };
    el.addEventListener('load', hook);
    hook();
    return () => { el.removeEventListener('load', hook); try { el.contentWindow?.removeEventListener('pointerdown', pass, true); } catch { /* as above */ } };
  }, []);

  // Oby says when its first frame is drawn; one that doesn't say, a moment after its page loads
  const [drawn, setDrawn] = useState(false);
  useEffect(() => {
    const el = frame.current!;
    const onMessage = (e: MessageEvent) => {
      if (e.source === el.contentWindow && e.data?.oby === 'ready') setDrawn(true);
    };
    let late = 0;
    const onLoad = () => { late = window.setTimeout(() => setDrawn(true), 600); };
    addEventListener('message', onMessage);
    el.addEventListener('load', onLoad);
    return () => { removeEventListener('message', onMessage); el.removeEventListener('load', onLoad); clearTimeout(late); };
  }, []);

  // a glance when the host asks (e.g. the pointer arriving on the chips): Oby
  // looks over, like at a click, then goes back to its own business
  useEffect(() => {
    if (glance && last.current) frame.current!.contentWindow?.postMessage({ notice: last.current }, location.origin);
  }, [glance]);

  // stop drawing while it's out of sight: once it has faded out, at once when
  // back, and at once if the frame reloads while it's hidden
  useEffect(() => {
    const el = frame.current!;
    const post = (p: boolean) => el.contentWindow?.postMessage({ pause: p }, location.origin);
    if (!paused) { post(false); return; }
    const t = setTimeout(() => post(true), 300);
    const reloaded = () => post(true);
    el.addEventListener('load', reloaded);
    return () => { clearTimeout(t); el.removeEventListener('load', reloaded); };
  }, [paused]);

  return <iframe ref={frame} className="oby-frame" src="oby/oby.html?embed&size=1.23" title="Oby" style={drawn ? undefined : { visibility: 'hidden' }} />;
}
