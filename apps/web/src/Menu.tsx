import { useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';

// A small menu under its ⋮ button (above it if there's no room below), e.g. a
// task's, or a section's options; lined up with the button's right edge, or its
// left (align: 'left') where it would otherwise cover what's before the button. Drawn over everything, so the folding groups
// can't clip it. Esc or a click outside closes it (anywhere: see useClicksEverywhere);
// a click on the button that opened it is left to that button, which closes it
// (a toggle, not a reopen). The window changing size closes it too, as a macOS
// menu does, rather than leaving it where the button no longer is.
export function Menu({ at, onClose, height = 90, align = 'right', width, children }: {
  at: DOMRect;
  onClose: () => void;
  height?: number;  // about how tall it is, to tell whether it fits below
  align?: 'left' | 'right';
  width?: number;  // wider than its 148px least, where its items want room
  children: React.ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useClicksEverywhere(true);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopImmediatePropagation(); onClose(); } };
    const onDown = (e: PointerEvent) => {
      const onButton = e.clientX >= at.left && e.clientX <= at.right && e.clientY >= at.top && e.clientY <= at.bottom;
      if (!ref.current?.contains(e.target as Node) && !onButton) onClose();
    };
    addEventListener('keydown', onKey, true);
    addEventListener('pointerdown', onDown, true);
    addEventListener('resize', onClose);
    return () => { removeEventListener('keydown', onKey, true); removeEventListener('pointerdown', onDown, true); removeEventListener('resize', onClose); };
  }, [onClose, at]);

  const up = at.bottom + height > innerHeight;
  const style: React.CSSProperties = {
    ...(align === 'left' ? { left: at.left } : { right: innerWidth - at.right }),
    ...(width ? { minWidth: width } : {}),
    ...(up ? { bottom: innerHeight - at.top + 4 } : { top: at.bottom + 4 }),
  };
  return createPortal(
    <div ref={ref} className={`row-menu${up ? ' is-up' : ''}${align === 'left' ? ' is-left' : ''}`} style={style} role="menu">{children}</div>,
    document.body,
  );
}

// The side panel's empty room and the title bar drag the window, and macOS keeps
// a click there from ever reaching the page, so a popover listening for clicks
// outside it never hears those. While one is open (open: true), they're plain
// page instead (html.is-popover-open in app.css): a click anywhere closes it,
// and dragging the window waits until it's closed, as with macOS's own menus.
let openPopovers = 0;
export function useClicksEverywhere(open: boolean) {
  useEffect(() => {
    if (!open) return;
    if (openPopovers++ === 0) document.documentElement.classList.add('is-popover-open');
    return () => { if (--openPopovers === 0) document.documentElement.classList.remove('is-popover-open'); };
  }, [open]);
}
