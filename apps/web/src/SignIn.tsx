import { useState } from 'react';
import { ApiError, api } from './api';
import { signedIn } from './live';

// The page asking for obid's API token, when it holds none (a new tab, or the dev server) or obid
// refused the one it held. It checks it with obid (GET /v1/status) before keeping it for this tab;
// the page sends it on every call, and obid takes nothing else (api.ts).
export default function SignIn() {
  const [value, setValue] = useState('');
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  return (
    <main className="sign-in">
      <h1>Sign in to Oby</h1>
      <p>This Oby answers only with its API token. Paste the token from the <code>api-token</code> file in obid’s home.</p>
      <form
        onSubmit={async (e) => {
          e.preventDefault();
          const t = value.trim();
          if (!t || busy) return;
          setBusy(true);
          try {
            await api.check(t);
            signedIn(t);
          } catch (err) {
            setProblem(err instanceof ApiError && err.status === 401 ? 'That isn’t this obid’s token.' : err instanceof Error ? err.message : String(err));
          } finally {
            setBusy(false);
          }
        }}
      >
        <input type="password" value={value} onChange={(e) => setValue(e.target.value)} aria-label="API token" autoComplete="off" spellCheck={false} autoFocus required />
        <button type="submit" disabled={busy}>Sign in</button>
      </form>
      {problem && <p className="sign-in-problem" role="alert">{problem}</p>}
    </main>
  );
}
