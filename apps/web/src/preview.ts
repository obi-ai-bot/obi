import { useSyncExternalStore } from 'react';

// Settings › General › "Show screens still being built": the Obysphere (#497) and its knowledge
// (#495) have no backend in obid yet, and the list of conversations (obid keeps many since #493)
// is still to come, so they stay hidden; shown, each says so and shows nothing made up.
// Remembered in this browser.
let on = (() => { try { return localStorage.getItem('oby.preview') === '1'; } catch { return false; } })();
const listeners = new Set<() => void>();
export const usePreview = () => useSyncExternalStore((l) => { listeners.add(l); return () => { listeners.delete(l); }; }, () => on);
export function setPreview(next: boolean) {
  on = next;
  try { localStorage.setItem('oby.preview', next ? '1' : '0'); } catch { /* not remembered, that's all */ }
  listeners.forEach((l) => l());
}
