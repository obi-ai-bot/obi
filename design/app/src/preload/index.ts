import { contextBridge, ipcRenderer } from 'electron';

type Point = { x: number; y: number };

contextBridge.exposeInMainWorld('app', {
  // where macOS put the traffic lights, in CSS px (null without the native
  // window style); the page lays its title bar out from these
  chrome: ipcRenderer.sendSync('window-chrome') as { lightsCenterY: number; lightsRight: number } | null,
  // whether the window is full screen (no traffic lights), and changes to it
  fullScreen: ipcRenderer.sendSync('full-screen') as boolean,
  onFullScreen(fn: (on: boolean) => void) {
    const listener = (_: unknown, on: boolean) => fn(on);
    ipcRenderer.on('full-screen', listener);
    return () => { ipcRenderer.off('full-screen', listener); };
  },
  // the cursor in window coordinates, even when it's outside the window
  onCursor(fn: (p: Point) => void) {
    const listener = (_: unknown, p: Point) => fn(p);
    ipcRenderer.on('cursor', listener);
    return () => { ipcRenderer.off('cursor', listener); };
  },
});
