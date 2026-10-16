import { useEffect, useRef } from 'react';

// gap from the list's top and bottom edges, from its right edge, and the
// thumb's shortest length
const INSET = 8, EDGE = 5, MIN = 32;

// A Safari-like scroll thumb for a list: 6px, no track, shown while scrolling
// (or dragging) and faded out 800ms after it stops. Drawn by hand because
// Chromium's macOS scrollbar shows a track on hover. The list hides its own
// scrollbar (scrollbar-width: none); the thumb goes next to the list, and is
// placed over the list's right edge wherever the list sits in their parent.
export function useScrollThumb<T extends HTMLElement>() {
  const list = useRef<T>(null);
  const thumb = useRef<HTMLDivElement>(null);
  const hide = useRef<ReturnType<typeof setTimeout>>(undefined);

  const place = () => {
    const l = list.current, t = thumb.current;
    if (!l || !t) return;
    const track = l.clientHeight - 2 * INSET;
    const h = Math.max(MIN, track * l.clientHeight / l.scrollHeight);
    const room = l.scrollHeight - l.clientHeight;
    t.hidden = room <= 0;
    t.style.height = `${h}px`;
    const x = l.offsetLeft + l.offsetWidth - EDGE - t.offsetWidth;
    t.style.transform = `translate(${x}px, ${l.offsetTop + INSET + (room > 0 ? (track - h) * l.scrollTop / room : 0)}px)`;
  };
  const show = () => {
    place();
    thumb.current?.classList.add('is-shown');
    clearTimeout(hide.current);
    hide.current = setTimeout(() => thumb.current?.classList.remove('is-shown'), 800);
  };
  useEffect(() => () => clearTimeout(hide.current), []);

  // dragging the thumb scrolls the list, like a native scrollbar
  const drag = (e: React.PointerEvent<HTMLDivElement>) => {
    const l = list.current!, t = e.currentTarget, y0 = e.clientY, top0 = l.scrollTop;
    const perPx = (l.scrollHeight - l.clientHeight) / Math.max(1, l.clientHeight - 2 * INSET - t.offsetHeight);
    t.setPointerCapture(e.pointerId);
    const move = (m: PointerEvent) => { l.scrollTop = top0 + (m.clientY - y0) * perPx; };
    const up = () => {
      t.removeEventListener('pointermove', move); t.removeEventListener('pointerup', up); t.removeEventListener('pointercancel', up);
    };
    t.addEventListener('pointermove', move);
    t.addEventListener('pointerup', up);
    t.addEventListener('pointercancel', up);  // the system took the pointer
  };

  return {
    list,
    onScroll: show,
    thumbProps: { ref: thumb, className: 'scroll-thumb', onPointerDown: drag, onPointerMove: show, hidden: true },
  };
}
