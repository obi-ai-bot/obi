import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { ArrowUp, Check, ChevronLeft, File, Gauge, Laptop, ListChecks, Plus, Search, Settings, X } from 'lucide-react';
import { ObyIcon, OwnerAvatar } from './ObyFace';
import { AGENTS, OBYS, PLACES, SHARED_WITH_ME, type Attachments } from './mock';
import MessageEditor, { type EditorHandle, type MentionKey } from './MessageEditor';
import { mentioned } from './textTokens';
import StatusDot from './StatusDot';
import { useClicksEverywhere } from './Menu';
import { useTasks, type Task } from './tasks';
import { BrandMark } from './brands';
import { fullness, useAccounts } from './SettingsView';
import { useScrollThumb } from './useScrollThumb';

// What a message carries besides its words: files or photos (a photo with a
// small preview of itself), tasks attached. (Other Obys are brought in by name,
// in the words: @Wellington.) place: the Mac it runs on, when not this one
// (one at a time: picking another replaces it).
type Attached = { kind: 'file'; name: string; preview?: string } | { kind: 'task'; id: string } | { kind: 'place'; name: string };
type View = 'root' | 'oby' | 'task' | 'where' | 'usage';
const same = (a: Attached, b: Attached) =>
  a.kind === 'task' ? b.kind === 'task' && a.id === b.id : a.kind === b.kind && a.name === (b as { name: string }).name;
const keyOf = (a: Attached) => (a.kind === 'task' ? `task:${a.id}` : `${a.kind}:${a.name}`);

// The message box: Home's, and the one at the foot of a conversation (or a
// task's or an Oby's page): tags for what's attached over one row of +, the
// text and send; once the text runs past one line, the text over a row of +
// and send instead (until it's sent). At the end, voice while the box is
// empty and send in its place once there's something to send; before them,
// usage (a gauge: how much the agents' accounts have used this week). The +
// opens a panel as wide as the box:
// add files or photos (straight to the file browser), add other Obys, attach
// tasks; the last two turn the panel into a search over the Obys or your
// tasks. A task picked goes in the box as a tag (x takes it out), as does each
// file; an Oby goes in the words, as @ and its name, as if typed, which is the
// other way to bring one in: an @ typed at the start of a word opens a list of
// the Obys over the box, narrowing as you type (arrows move, Enter or Tab
// picks, Esc closes it). The text grows with what you type; the up arrow sends (lit once
// there's something to send), as does Enter; Shift+Enter starts a new line.
export default function Composer({ placeholder, label, onSend, home = false, hidden = false, autoFocus = !home, className = '', style }: {
  placeholder: string;
  label: string;
  onSend: (text: string, attached: Attachments) => void;  // its words, and what went with them
  home?: boolean;    // Home's: 480px wide, steps aside (hidden) while a page is open over it
  hidden?: boolean;
  autoFocus?: boolean;  // focused on opening (a conversation's is; Home's and a task page's aren't)
  className?: string;  // a page's own spacing around it
  style?: React.CSSProperties;
}) {
  const [filled, setFilled] = useState(false);
  // One row (+, text, send) until the text no longer fits on one line; from
  // then on, stacked (the text over a row with + and send) until it's sent,
  // however much of it you delete meanwhile
  const [stacked, setStacked] = useState(false);
  const [view, setView] = useState<View | null>(null);
  const [attached, setAttached] = useState<Attached[]>([]);
  // the Obys named in the words so far
  const [named, setNamed] = useState<string[]>([]);
  // an @ being typed: what's after it (null: none), the Oby lit in the list,
  // and whether Esc put the list away (until the @ is left)
  const [at, setAt] = useState<string | null>(null);
  const [lit, setLit] = useState(0);
  const [atClosed, setAtClosed] = useState(false);
  // a name typed out in full is done: the list goes, and Enter sends
  const fullName = at !== null && OBYS.some((o) => o.name.toLowerCase() === at.toLowerCase());
  const matches = at === null || atClosed || view || fullName ? [] : obysFor(at);
  useClicksEverywhere(matches.length > 0);
  const pickOby = (name: string) => { setView(null); box.current?.mention(name); box.current?.focus(); };
  const onMentionKey = (key: MentionKey) => {
    if (!matches.length) return false;
    if (key === 'close') setAtClosed(true);
    else if (key === 'pick') pickOby(matches[Math.min(lit, matches.length - 1)].name);
    else setLit((i) => (Math.min(i, matches.length - 1) + (key === 'down' ? 1 : matches.length - 1)) % matches.length);
    return true;
  };
  const files = useRef<HTMLInputElement>(null);
  // the buttons that open the panels; a panel put away by its button or Esc
  // hands the focus back to its button
  const plus = useRef<HTMLButtonElement>(null);
  const gauge = useRef<HTMLButtonElement>(null);
  const closePanel = () => {
    if (field.current?.querySelector('.add-panel')?.contains(document.activeElement)) (view === 'usage' ? gauge : plus).current?.focus();
    setView(null);
  };
  // Tab or Shift+Tab out of a panel puts it away (a click inside it, or another
  // app taking the focus, doesn't)
  const onPanelBlur = (e: React.FocusEvent) => {
    if (e.relatedTarget && !e.currentTarget.contains(e.relatedTarget as Node)) setView(null);
  };
  const field = useRef<HTMLDivElement>(null);
  const box = useRef<EditorHandle>(null);
  const form = useRef<HTMLFormElement>(null);
  const tasks = useTasks();
  // Past 3 rows the tags scroll: kept at the bottom, so what you just added
  // shows, and faded at the top while older ones are hidden above
  const tagRow = useRef<HTMLDivElement>(null);
  const [hiddenAbove, setHiddenAbove] = useState(false);
  useLayoutEffect(() => {
    const t = tagRow.current;
    if (!t) return;
    t.scrollTop = t.scrollHeight;
    setHiddenAbove(t.scrollTop > 0);
  }, [attached.length]);
  const add = (...picked: Attached[]) => {
    const place = picked.some((a) => a.kind === 'place');
    setAttached((all) => [...all.filter((x) => !place || x.kind !== 'place'), ...picked.filter((a) => !(a.kind === 'place' && !a.name) && !all.some((x) => same(x, a)))]);
    setView(null);
    box.current?.focus();
  };

  // files picked or pasted: each a tag, a photo with its preview
  const addFiles = (list: File[]) => {
    const picked = list.map((f): Attached => ({
      kind: 'file', name: f.name || 'Pasted image', preview: f.type.startsWith('image/') ? URL.createObjectURL(f) : undefined,
    }));
    if (picked.length) add(...picked);
  };
  // Home's box stepping aside (a page opened over it) puts its panel away
  useEffect(() => { if (hidden) setView(null); }, [hidden]);
  // a click outside the box and its panel closes the panel (anywhere in the window)
  useClicksEverywhere(!!view);
  useEffect(() => {
    if (!view) return;
    const onDown = (e: PointerEvent) => { if (!field.current?.contains(e.target as Node)) setView(null); };
    addEventListener('pointerdown', onDown, true);
    return () => removeEventListener('pointerdown', onDown, true);
  }, [view]);

  return (
    <form ref={form} className={`${home ? `composer${hidden ? ' is-hidden' : ''}` : 'composer chat-composer rise'} ${className}`.trim()} inert={hidden} style={style} onSubmit={(e) => {
      e.preventDefault();
      const b = box.current!;
      // words, or something attached, or both
      if (!b.text().trim() && !attached.length) return;
      onSend(b.text(), {
        files: attached.flatMap((a) => (a.kind === 'file' ? [{ name: a.name, preview: a.preview }] : [])),
        obys: mentioned(b.text()),
        jobs: attached.flatMap((a) => (a.kind === 'task' ? [a.id] : [])),
        on: attached.find((a) => a.kind === 'place')?.name,
      });
      b.clear();
      setFilled(false);
      setStacked(false);
      setAttached([]);
      setView(null);
      // Home's: what you sent opens as its own conversation, so the box lets go
      // (the send button too, when that's what sent it). Anywhere else the box
      // keeps the focus, even when send was clicked (it hides once it's sent)
      if (home) {
        b.blur();
        const a = document.activeElement;
        if (a instanceof HTMLElement && form.current?.contains(a)) a.blur();
      } else b.focus();
    }}>
      <div
        ref={field}
        className={`composer-field${stacked ? ' is-stacked' : ''}`}
        // A click anywhere in the box is a click in the text (the room around it,
        // between the buttons, included), not just on the text itself; its
        // buttons, tags, panel and scrollbar keep their own clicks
        onMouseDown={(e) => {
          if ((e.target as HTMLElement).closest('button, input, .composer-tags, .composer-editor, .add-panel, .scroll-thumb')) return;
          e.preventDefault();
          box.current?.focus();
        }}
        // left with nothing typed (focus gone outside the box), it goes back to one row
        onBlur={(e) => { if (!field.current?.contains(e.relatedTarget as Node) && !box.current?.text().trim()) setStacked(false); }}
      >
        {view === 'usage' && <UsagePanel onClose={closePanel} onBlur={onPanelBlur} />}
        {view && view !== 'usage' && (
          <AddPanel
            view={view}
            tasks={tasks}
            onView={(v) => (v ? setView(v) : closePanel())}
            onBlur={onPanelBlur}
            onFiles={() => { closePanel(); files.current?.click(); }}
            onPick={add}
            onPickOby={pickOby}
            isPicked={(a) => attached.some((x) => same(x, a))}
            isNamed={(name) => named.includes(name)}
          />
        )}
        {matches.length > 0 && (
          <div className="add-panel mention-panel" role="listbox" aria-label="Obys">
            {matches.map((o, i) => (
              <button
                type="button"
                role="option"
                key={o.name}
                aria-selected={i === Math.min(lit, matches.length - 1)}
                className={i === Math.min(lit, matches.length - 1) ? 'is-lit' : ''}
                // the text keeps the focus (and its cursor)
                onMouseDown={(e) => e.preventDefault()}
                onMouseEnter={() => setLit(i)}
                onClick={() => pickOby(o.name)}
              >
                <OwnerAvatar name={o.name} size={22} />
                <span className="add-item-text">{o.name}’s Oby</span>
              </button>
            ))}
          </div>
        )}
        <div className="composer-grid">
          {attached.length > 0 && (
            <div ref={tagRow} className={`composer-tags${hiddenAbove ? ' is-scrolled' : ''}`} onScroll={(e) => setHiddenAbove(e.currentTarget.scrollTop > 0)}>
              {attached.map((a) => {
                const t = a.kind === 'task' ? tasks.find((x) => x.id === a.id) : undefined;
                return (
                  <span key={keyOf(a)} className="composer-tag">
                    {a.kind === 'task' && <ListChecks size={13} strokeWidth={1.8} />}
                    {a.kind === 'place' && <Laptop size={13} strokeWidth={1.8} />}
                    {a.kind === 'file' && (a.preview ? <img className="composer-tag-thumb" src={a.preview} alt="" /> : <File size={13} strokeWidth={1.8} />)}
                    <span className="composer-tag-text">{a.kind === 'task' ? t?.title : a.kind === 'place' ? `On ${a.name}` : a.name}</span>
                    <button type="button" aria-label="Remove" onClick={() => { if (a.kind === 'file' && a.preview) URL.revokeObjectURL(a.preview); setAttached((all) => all.filter((x) => !same(x, a))); }}><X size={12} strokeWidth={2} /></button>
                  </span>
                );
              })}
            </div>
          )}
          <button
            ref={plus}
            type="button"
            className={`composer-button${view && view !== 'usage' ? ' is-on' : ''}`}
            aria-label="Add to the message"
            aria-haspopup="menu"
            aria-expanded={!!view && view !== 'usage'}
            // a click leaves the focus where it is (the panel takes it on opening)
            onMouseDown={(e) => e.preventDefault()}
            onClick={() => (view && view !== 'usage' ? closePanel() : setView('root'))}
          >
            <Plus size={18} strokeWidth={1.6} />
          </button>
          <input
            ref={files}
            type="file"
            multiple
            hidden
            onChange={(e) => {
              addFiles([...(e.currentTarget.files ?? [])]);
              e.currentTarget.value = '';  // the same file can be picked again later
            }}
          />
          <MessageEditor
            handle={box}
            autoFocus={autoFocus}
            placeholder={placeholder}
            label={label}
            onText={(t) => { setFilled(!!t.trim()); setNamed(mentioned(t)); }}
            // each change narrows the list, so the first is lit again
            onMention={(q) => { setAt(q); setLit(0); if (q === null) setAtClosed(false); }}
            onMentionKey={onMentionKey}
            onEnter={() => form.current?.requestSubmit()}
            // past one line (32px: 22 of text, 10 of padding) it stacks
            onHeight={(h) => setStacked((was) => was || h > 33)}
            onPasteFiles={addFiles}
          />
          {/* how much the agents' accounts have used this week (UsagePanel on a click) */}
          <UsageGauge ref={gauge} open={view === 'usage'} onClick={() => (view === 'usage' ? closePanel() : setView('usage'))} />
          {/* at the end: talk instead of typing while the box is empty; once there's
              something to send, send takes its place */}
          <button type="button" className={`composer-button composer-voice${filled || attached.length ? ' is-away' : ''}`} aria-label="Talk to Oby" aria-hidden={filled || attached.length > 0 || undefined} tabIndex={filled || attached.length ? -1 : 0}>
            <svg width="18" height="16" viewBox="0 0 20 18" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round">
              <path d="M2 7v4M6 4v10M10 1v16M14 4v10M18 7v4" />
            </svg>
          </button>
          <button type="submit" className={`composer-button composer-send${filled || attached.length ? ' is-ready' : ''}`} aria-label="Send" disabled={!filled && !attached.length} aria-hidden={!filled && !attached.length || undefined}>
            <ArrowUp size={18} strokeWidth={1.8} />
          </button>
        </div>
      </div>
    </form>
  );
}

// The +'s panel over the box, as wide as it. First the three things you can
// add; Obys and tasks then turn it into a search with a list under it (back
// at its left returns to the three). Esc steps back, then closes.
function AddPanel({ view, tasks, onView, onBlur, onFiles, onPick, onPickOby, isPicked, isNamed }: {
  view: View;
  onBlur: (e: React.FocusEvent) => void;
  tasks: Task[];
  onView: (v: View | null) => void;
  onFiles: () => void;
  onPick: (a: Attached) => void;
  onPickOby: (name: string) => void;
  isPicked: (a: Attached) => boolean;
  isNamed: (name: string) => boolean;  // already @named in the words
}) {
  const [query, setQuery] = useState('');
  useEffect(() => setQuery(''), [view]);
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLDivElement>();
  // The three take the focus on opening: the first, or, back from a search,
  // the one that opened it. Up and Down move between them; Tab leaves
  const menu = useRef<HTMLDivElement>(null);
  const was = useRef<View>(view);
  useEffect(() => {
    if (view === 'root') menu.current?.querySelectorAll('button')[was.current === 'oby' ? 1 : was.current === 'task' ? 2 : was.current === 'where' ? 3 : 0]?.focus();
    was.current = view;
  }, [view]);
  const onMenuKey = (e: React.KeyboardEvent) => {
    const items = [...menu.current!.querySelectorAll('button')];
    const i = items.indexOf(document.activeElement as HTMLButtonElement);
    const to = { ArrowDown: (i + 1) % items.length, ArrowUp: (i + items.length - 1) % items.length, Home: 0, End: items.length - 1 }[e.key];
    if (to === undefined) return;
    e.preventDefault();
    items[to].focus();
  };
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      e.stopImmediatePropagation();
      onView(view === 'root' ? null : 'root');
    };
    addEventListener('keydown', onKey, true);
    return () => removeEventListener('keydown', onKey, true);
  }, [view, onView]);

  if (view === 'root') {
    return (
      <div ref={menu} className="add-panel" role="menu" onKeyDown={onMenuKey} onBlur={onBlur}>
        <button type="button" role="menuitem" tabIndex={-1} onClick={onFiles}><File size={16} strokeWidth={1.6} />Add files or photos</button>
        <button type="button" role="menuitem" tabIndex={-1} onClick={() => onView('oby')}><ObyIcon size={16} />Add other Obys<kbd className="add-hint">@</kbd></button>
        <button type="button" role="menuitem" tabIndex={-1} onClick={() => onView('task')}><ListChecks size={16} strokeWidth={1.6} />Attach tasks</button>
        {/* Sharing (a preview): run it on a teammate's Mac that's free, with your own accounts */}
        <button type="button" role="menuitem" tabIndex={-1} onClick={() => onView('where')}><Laptop size={16} strokeWidth={1.6} />Run on another Mac</button>
      </div>
    );
  }

  const q = query.trim().toLowerCase();
  const obys = obysFor(q);
  const found = tasks.filter((t) => `${t.who ?? ''} ${t.title}`.toLowerCase().includes(q));
  const places = PLACES.filter((p) => p.name.toLowerCase().includes(q));
  // Enter takes the first match (a Mac: the first that's free)
  const pickFirst = () => {
    if (view === 'oby') return obys[0] && onPickOby(obys[0].name);
    if (view === 'where') { const p = places.find((x) => x.free); return p && onPick({ kind: 'place', name: p.name }); }
    return found[0] && onPick({ kind: 'task', id: found[0].id });
  };
  const hint = { oby: 'Search Obys', task: 'Search tasks', where: 'Search Macs' }[view as 'oby' | 'task' | 'where'];
  return (
    <div className="add-panel is-search" onBlur={onBlur}>
      <div className="add-search">
        <button type="button" className="add-back" aria-label="Back" onClick={() => onView('root')}><ChevronLeft size={16} strokeWidth={1.6} /></button>
        <Search size={14} strokeWidth={1.6} className="add-search-icon" />
        <input
          autoFocus
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          // Enter takes the first match
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); pickFirst(); } }}
          placeholder={hint}
          aria-label={hint}
        />
      </div>
      <div ref={list} className="add-list" role="listbox" onScroll={onScroll}>
        {view === 'oby' && obys.map((o) => (
          <button type="button" role="option" aria-selected={isNamed(o.name)} key={o.name} onClick={() => onPickOby(o.name)}>
            <OwnerAvatar name={o.name} size={22} />
            <span className="add-item-text">{o.name}’s Oby</span>
            {isNamed(o.name) && <Check size={14} strokeWidth={1.8} className="add-check" />}
          </button>
        ))}
        {view === 'task' && found.map((t) => {
          const a: Attached = { kind: 'task', id: t.id };
          return (
            <button type="button" role="option" aria-selected={isPicked(a)} key={t.id} onClick={() => onPick(a)}>
              <StatusDot task={t} />
              <span className="add-item-text">{t.who && <span className="add-item-who">{t.who}</span>}{t.title}</span>
              {isPicked(a) && <Check size={14} strokeWidth={1.8} className="add-check" />}
            </button>
          );
        })}
        {/* this Mac, then the Macs shared with you: who's away, or when one is free */}
        {view === 'where' && places.map((p) => {
          const a: Attached = { kind: 'place', name: p.name };
          const here = p.name === 'This Mac';
          return (
            <button type="button" role="option" aria-selected={isPicked(a)} aria-disabled={!p.free || undefined} disabled={!p.free} key={p.name} className="add-place" onClick={() => onPick(here ? { kind: 'place', name: '' } : a)}>
              {p.owner ? <OwnerAvatar name={p.owner} size={22} /> : <Laptop size={16} strokeWidth={1.6} />}
              <span className="add-item-text">{p.name}<span className="add-item-about">{p.about}</span></span>
              {isPicked(a) && <Check size={14} strokeWidth={1.8} className="add-check" />}
            </button>
          );
        })}
        {view === 'where' && <p className="add-note">Your job runs there with your own accounts: your logins stay on this Mac.</p>}
        {((view === 'oby' && !obys.length) || (view === 'task' && !found.length) || (view === 'where' && !places.length)) && <p className="add-empty">Nothing matches “{query.trim()}”</p>}
      </div>
      <div {...thumbProps} />
    </div>
  );
}

// The Obys a name typed so far could be: those it starts, then those it's in
function obysFor(typed: string) {
  const q = typed.trim().toLowerCase();
  const name = (o: { name: string }) => o.name.toLowerCase();
  return [...OBYS.filter((o) => name(o).startsWith(q)), ...OBYS.filter((o) => !name(o).startsWith(q) && name(o).includes(q))];
}

// Esc while there's something typed in a message box is the box's (it would
// otherwise go back, and the words with it)
export const typingIn = (e: KeyboardEvent) => {
  const box = (e.target as Element | null)?.closest?.('.composer-input');
  return !!box?.textContent?.trim();
};

// The way to how much the accounts have used this week (UsagePanel): a gauge,
// with a dot on it while any account is past 80% (yellow), or 90% (red).
function UsageGauge({ ref, open, onClick }: { ref: React.Ref<HTMLButtonElement>; open: boolean; onClick: () => void }) {
  const [accounts] = useAccounts();
  const full = fullness(Math.max(0, ...accounts.map((a) => a.used)));
  return (
    <button
      ref={ref}
      type="button"
      className={`composer-button composer-usage${open ? ' is-on' : ''}`}
      aria-label={`Usage this week${full ? ', an account is nearly full' : ''}`}
      title="Usage this week"
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

// Each account's use this week, over the box like the + panel: its agent and
// name, when it resets and how much it's used on one line, a bar under them
// (yellow past 80%, red past 90%); a gear at the top right goes to Settings ›
// Accounts, and takes the focus on opening. Esc, a click outside or Tab out
// of it closes it.
function UsagePanel({ onClose, onBlur }: { onClose: () => void; onBlur: (e: React.FocusEvent) => void }) {
  const [accounts] = useAccounts();
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopImmediatePropagation(); close.current(); } };
    addEventListener('keydown', onKey, true);
    return () => removeEventListener('keydown', onKey, true);
  }, []);
  return (
    <div className="add-panel usage-panel" role="dialog" aria-label="Usage this week" onBlur={onBlur}>
      <div className="usage-head">
        <span>Usage this week</span>
        <button type="button" autoFocus className="icon-button" aria-label="Manage accounts" title="Manage accounts" onClick={() => { onClose(); dispatchEvent(new CustomEvent('oby:open-setting', { detail: 'accounts' })); }}>
          <Settings size={15} strokeWidth={1.6} />
        </button>
      </div>
      {!accounts.length && <p className="add-empty">No accounts yet</p>}
      {accounts.map((a) => (
        <div key={a.id} className="usage-row">
          <BrandMark brand={AGENTS[a.agent].brand} size={16} mono />
          <span className="usage-text">
            <span className="usage-line">
              <span className="usage-name">{AGENTS[a.agent].name} · {a.name}</span>
              <span className="usage-about">{a.resets}</span>
              <span className={`usage-used ${fullness(a.used)}`.trim()}>{a.used}%</span>
            </span>
            <span className="set-meter"><span className={fullness(a.used)} style={{ width: `${a.used}%` }} /></span>
          </span>
        </div>
      ))}
      {/* Sharing (a preview): a part of a teammate's usage shared with you; the bar
          is your share, filled with what you've used of it */}
      {SHARED_WITH_ME.length > 0 && <p className="usage-shared">Shared with you</p>}
      {SHARED_WITH_ME.map((x) => (
        <div key={`${x.owner}-${x.account}`} className="usage-row">
          <OwnerAvatar name={x.owner} size={16} badge={false} />
          <span className="usage-text">
            <span className="usage-line">
              <span className="usage-name">{x.owner}’s {x.account}</span>
              <span className="usage-about">Your {x.share}% of its month</span>
              <span className={`usage-used ${fullness((100 * x.used) / x.share)}`.trim()}>{x.share - x.used}% left</span>
            </span>
            <span className="set-meter"><span className={fullness((100 * x.used) / x.share)} style={{ width: `${(100 * x.used) / x.share}%` }} /></span>
          </span>
        </div>
      ))}
    </div>
  );
}
