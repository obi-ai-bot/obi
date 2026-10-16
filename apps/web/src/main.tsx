import { createRoot } from 'react-dom/client';
import './tokens.css';
import './app.css';
import './web.css';
import Home from './Home';
import { connect } from './live';

// obid's events first, then what to show (live.ts)
connect();
createRoot(document.getElementById('root')!).render(<Home />);
