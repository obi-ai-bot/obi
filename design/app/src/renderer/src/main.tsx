import { createRoot } from 'react-dom/client';
import './tokens.css';
import './app.css';
import Home from './Home';

// Line the title bar up with the traffic lights, where macOS actually put them
const chrome = window.app?.chrome;
if (chrome) {
  const root = document.documentElement.style;
  root.setProperty('--bar', `${Math.round(chrome.lightsCenterY * 2)}px`);
  root.setProperty('--after-lights', `${Math.round(chrome.lightsRight + 10)}px`);
}

createRoot(document.getElementById('root')!).render(<Home />);
