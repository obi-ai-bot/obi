import { tokenize } from './textTokens';

// A sent message's text, set as it was in the message box: links and
// references in blue, paths and `code` in coral monospace (app.css .tok-*).
export default function Formatted({ text }: { text: string }) {
  return <>{tokenize(text).map((r, i) => (r.kind ? <span key={i} className={`tok tok-${r.kind}`}>{r.text}</span> : r.text))}</>;
}
