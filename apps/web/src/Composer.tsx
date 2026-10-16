import { useEffect, useRef, useState } from 'react';
import { ArrowUp, Gauge, Settings } from 'lucide-react';
import MessageEditor, { type EditorHandle } from './MessageEditor';
import { useClicksEverywhere } from './Menu';
import { BrandMark } from './brands';
import { useLive } from './live';
import { AGENTS } from './tasks';
import type { Account } from './api';

// The message box: Home's, and the one at the foot of a conversation (or a task's page): one
// row of the text and send; once the text runs past one line, the text over a row with send
// instead (until it's sent). Before send, usage (a gauge: how much the agents' accounts have
// used), when obid reports any. The text grows with what you type; the up arrow sends (lit once
// there's something to send), as does Enter; Shift+Enter starts a new line. busy: Oby is still on
// the last message, so this one waits in the box.
//
// Sangam's design also adds files, other Obys (@) and tasks to a message, and talks instead of
// typing; obid takes none of those from a browser yet, so the box doesn't offer them.
export default function Composer({ placeholder, label, onSend, home = false, hidden = false, autoFocus = !home, busy = false, className = '', style }: {
  placeholder: string;
  label: string;
  onSend: (text: string) => void;
  home?: boolean;    // Home's: 480px wide, steps aside (hidden) while a page is open over it
  hidden?: boolean;
  autoFocus?: boolean;  // focused on opening (a conversation's is; Home's and a task page's aren't)
  busy?: boolean;
  className?: string;  // a page's own spacing around it
  style?: React.CSSProperties;
}) {
  const [filled, setFilled] = useState(false);
  // One row (text, send) until the text no longer fits on one line; from then on, stacked
  // until it's sent, however much of it you delete meanwhile
  const [stacked, setStacked] = useState(false);
  const [usage, setUsage] = useState(false);
  const gauge = useRef<HTMLButtonElement>(null);
  const field = useRef<HTMLDivElement>(null);
  const box = useRef<EditorHandle>(null);
  const form = useRef<HTMLFormElement>(null);
  const closeUsage = () => {
    if (field.current?.querySelector('.add-panel')?.contains(document.activeElement)) gauge.current?.focus();
    setUsage(false);
  };
  // Home's box stepping aside (a page opened over it) puts its panel away
  useEffect(() => { if (hidden) setUsage(false); }, [hidden]);
  // a click outside the box and its panel closes the panel (anywhere in the window)
  useClicksEverywhere(usage);
  useEffect(() => {
    if (!usage) return;
    const onDown = (e: PointerEvent) => { if (!field.current?.contains(e.target as Node)) setUsage(false); };
    addEventListener('pointerdown', onDown, true);
    return () => removeEventListener('pointerdown', onDown, true);
  }, [usage]);
  const ready = filled && !busy;

  return (
    <form ref={form} className={`${home ? `composer${hidden ? ' is-hidden' : ''}` : 'composer chat-composer rise'} ${className}`.trim()} inert={hidden} style={style} onSubmit={(e) => {
      e.preventDefault();
      const b = box.current!;
      if (!b.text().trim() || busy) return;
      onSend(b.text());
      b.clear();
      setFilled(false);
      setStacked(false);
      setUsage(false);
      // Home's: what you sent opens the conversation, so the box lets go (the send button too,
      // when that's what sent it). Anywhere else the box keeps the focus
      if (home) {
        b.blur();
        const a = document.activeElement;
        if (a instanceof HTMLElement && form.current?.contains(a)) a.blur();
      } else b.focus();
    }}>
      <div
        ref={field}
        className={`composer-field${stacked ? ' is-stacked' : ''}`}
        // A click anywhere in the box is a click in the text (the room around it, between the
        // buttons, included), not just on the text itself; its buttons and panel keep their own
        onMouseDown={(e) => {
          if ((e.target as HTMLElement).closest('button, input, .composer-editor, .add-panel, .scroll-thumb')) return;
          e.preventDefault();
          box.current?.focus();
        }}
        // left with nothing typed (focus gone outside the box), it goes back to one row
        onBlur={(e) => { if (!field.current?.contains(e.relatedTarget as Node) && !box.current?.text().trim()) setStacked(false); }}
      >
        {usage && <UsagePanel onClose={closeUsage} onBlur={(e) => { if (e.relatedTarget && !e.currentTarget.contains(e.relatedTarget as Node)) setUsage(false); }} />}
        <div className="composer-grid">
          <MessageEditor
            handle={box}
            autoFocus={autoFocus}
            placeholder={placeholder}
            label={label}
            onText={(t) => setFilled(!!t.trim())}
            onEnter={() => form.current?.requestSubmit()}
            // past one line (32px: 22 of text, 10 of padding) it stacks
            onHeight={(h) => setStacked((was) => was || h > 33)}
          />
          {/* how much the agents' accounts have used (UsagePanel on a click) */}
          <UsageGauge ref={gauge} open={usage} onClick={() => (usage ? closeUsage() : setUsage(true))} />
          <button type="submit" className={`composer-button composer-send${ready ? ' is-ready' : ''}`} aria-label={busy ? 'Oby is still answering' : 'Send'} disabled={!ready}>
            <ArrowUp size={18} strokeWidth={1.8} />
          </button>
        </div>
      </div>
    </form>
  );
}

// Esc while there's something typed in a message box is the box's (it would
// otherwise go back, and the words with it)
export const typingIn = (e: KeyboardEvent) => {
  const box = (e.target as Element | null)?.closest?.('.composer-input');
  return !!box?.textContent?.trim();
};

// how full an account (or an agent) is: past 80% yellow, past 90% red
export const fullness = (used: number) => (used > 90 ? 'is-over' : used > 80 ? 'is-high' : '');
// how much an account has used, in percent: its week's share, else its five hours' (the API
// sends 0…1); null when it reports neither
const usedOf = (a: Account) => { const v = a.sevenDay ?? a.fiveHour; return v == null ? null : v * 100; };
const withUsage = (accounts: Account[] = []) => accounts.filter((a) => usedOf(a) != null);

// The way to how much the accounts have used: a gauge, with a dot on it while any account is
// past 80% (yellow), or 90% (red). Not there while obid reports no account's usage.
function UsageGauge({ ref, open, onClick }: { ref: React.Ref<HTMLButtonElement>; open: boolean; onClick: () => void }) {
  const accounts = withUsage(useLive().status?.accounts);
  if (!accounts.length) return null;
  const full = fullness(Math.max(0, ...accounts.map((a) => usedOf(a)!)));
  return (
    <button
      ref={ref}
      type="button"
      className={`composer-button composer-usage${open ? ' is-on' : ''}`}
      aria-label={`Usage${full ? ', an account is nearly full' : ''}`}
      title="Usage"
      aria-haspopup="dialog"
      aria-expanded={open}
      // a click leaves the focus where it is (the panel takes it on opening)
      onMouseDown={(e) => e.preventDefault()}
      onClick={onClick}
    >
      <Gauge size={18} strokeWidth={1.6} />
      {full && <span className={`usage-dot ${full}`} aria-hidden="true" />}
    </button>
  );
}

// Each account's use, over the box: its agent and name, when it resets and how much it's used on
// one line, a bar under them (yellow past 80%, red past 90%); a gear at the top right goes to
// Settings › Accounts, and takes the focus on opening. Esc, a click outside or Tab out closes it.
function UsagePanel({ onClose, onBlur }: { onClose: () => void; onBlur: (e: React.FocusEvent) => void }) {
  const accounts = withUsage(useLive().status?.accounts);
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopImmediatePropagation(); close.current(); } };
    addEventListener('keydown', onKey, true);
    return () => removeEventListener('keydown', onKey, true);
  }, []);
  return (
    <div className="add-panel usage-panel" role="dialog" aria-label="Usage" onBlur={onBlur}>
      <div className="usage-head">
        <span>Usage</span>
        <button type="button" autoFocus className="icon-button" aria-label="Accounts" title="Accounts" onClick={() => { onClose(); dispatchEvent(new CustomEvent('oby:open-setting', { detail: 'accounts' })); }}>
          <Settings size={15} strokeWidth={1.6} />
        </button>
      </div>
      {accounts.map((a) => {
        const used = Math.round(usedOf(a)!);
        const resets = a.sevenDay != null ? a.sevenDayResets : a.fiveHourResets;
        return (
          <div key={a.id} className="usage-row">
            <BrandMark brand={AGENTS[a.agent].brand} size={16} mono />
            <span className="usage-text">
              <span className="usage-line">
                <span className="usage-name">{AGENTS[a.agent].name} · {a.name}</span>
                <span className="usage-about">{a.sevenDay != null ? 'This week' : '5 hours'}{resets ? ` · resets ${new Date(resets).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' })}` : ''}</span>
                <span className={`usage-used ${fullness(used)}`.trim()}>{used}%</span>
              </span>
              <span className="set-meter"><span className={fullness(used)} style={{ width: `${Math.min(100, used)}%` }} /></span>
            </span>
          </div>
        );
      })}
    </div>
  );
}
