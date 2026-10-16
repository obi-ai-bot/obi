import { createRoot } from 'react-dom/client';
import './tokens.css';
import './app.css';
import './web.css';
import Home from './Home';
import SignIn from './SignIn';
import { connect, useLive } from './live';

// Signed in (the page holds obid's token): obid's events first, then what to show (live.ts).
// Otherwise the page asks for the token.
function App() {
  return useLive().signedIn ? <Home /> : <SignIn />;
}

connect();
createRoot(document.getElementById('root')!).render(<App />);
