import { $applyNodeReplacement, TextNode, type EditorConfig } from 'lexical';

// What the message box recognises in plain text as you type, and the node it
// keeps each in. Another Oby brought in (@Wellington) on a blue tint; links and
// references (#412, tetrix-ee#490) in blue; file paths and repos (src/app.tsx,
// deskree-inc/oby) and `code in backticks` in coral monospace (app.css .tok-*).
// In a file of its own, apart from MessageEditor: editing that file reloads it
// while the app runs, and a reloaded copy of this class would no longer be the
// one the open editor registered (Lexical refuses the mismatch and typing stops).

// The other Obys a message can name: they come with the Obysphere (#497). Until then there are none,
// so an @ is just text.
const OBYS: { name: string }[] = [];
// a name as it's written, in a pattern (a dot in it is a dot)
const escape = (t: string) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
type Kind = 'mention' | 'url' | 'code' | 'ref' | 'path';
// in order: where two would start at the same place, the first wins
const PATTERNS: [Kind, RegExp][] = [
  // only the Obys there are: an @ before anything else is just text
  ['mention', new RegExp(`(?<![\\w@])@(?:${OBYS.map((o) => escape(o.name)).join('|') || '(?!)'})(?!\\w)`, 'i')],
  ['url', /\bhttps?:\/\/[^\s<>"'`]*[^\s<>"'`.,;:!?)\]}]/],
  ['code', /`[^`\n]+`/],
  ['ref', /(?<![\w#])(?:[\w.-]+\/)?(?:[\w.-]+)?#\d+(?!\w)/],
  ['path', /(?<![\w.:/@-])(?:~\/|\.{1,2}\/|\/)?(?:[\w@.-]+\/)+[\w@.-]+/],
];
// the earliest thing in a stretch of text worth setting apart
export function findToken(text: string) {
  let best: { start: number; end: number } | null = null;
  for (const [, re] of PATTERNS) {
    const m = re.exec(text);
    if (m && (!best || m.index < best.start)) best = { start: m.index, end: m.index + m[0].length };
  }
  return best;
}
// what a token is (worked out from its text each time, so it follows edits)
const kindOf = (text: string): Kind | null =>
  PATTERNS.find(([, re]) => { const m = re.exec(text); return m && m.index === 0 && m[0].length === text.length; })?.[0] ?? null;

// Text cut into runs, plain or recognised (with what kind), in order: how a
// sent message shows the same things the message box did as it was typed.
export function tokenize(text: string): { text: string; kind: Kind | null }[] {
  const out: { text: string; kind: Kind | null }[] = [];
  let rest = text;
  for (let m = findToken(rest); m; m = findToken(rest)) {
    if (m.start > 0) out.push({ text: rest.slice(0, m.start), kind: null });
    const t = rest.slice(m.start, m.end);
    out.push({ text: t, kind: kindOf(t) });
    rest = rest.slice(m.end);
  }
  if (rest) out.push({ text: rest, kind: null });
  return out;
}

// A recognised stretch of text: still text, styled by what it is.
export class TokenNode extends TextNode {
  $config() {
    return this.config('oby-token', { extends: TextNode });
  }
  createDOM(config: EditorConfig): HTMLElement {
    const el = super.createDOM(config);
    el.classList.add('tok', `tok-${kindOf(this.__text) ?? 'path'}`);
    return el;
  }
  updateDOM(prev: this, dom: HTMLElement, config: EditorConfig): boolean {
    const changed = super.updateDOM(prev, dom, config);
    dom.className = `tok tok-${kindOf(this.__text) ?? 'path'}`;
    return changed;
  }
  canInsertTextBefore(): boolean { return false; }
  isTextEntity(): true { return true; }
}
export const $createTokenNode = (text = '') => $applyNodeReplacement(new TokenNode(text));

// While the app runs, a change here reloads the page instead of swapping this
// class under an open editor (which would leave it broken until a reload anyway).
if (import.meta.hot) import.meta.hot.accept(() => location.reload());

// the Obys a message brings in: those it mentions, each once, as they're named
export const mentioned = (text: string) => [
  ...new Set(tokenize(text).filter((r) => r.kind === 'mention').flatMap((r) => OBYS.filter((o) => o.name.toLowerCase() === r.text.slice(1).toLowerCase()).map((o) => o.name))),
];
