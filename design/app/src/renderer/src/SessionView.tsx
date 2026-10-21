import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { ArrowDown, Check, ChevronRight, ShieldCheck } from 'lucide-react';
import Composer, { typingIn } from './Composer';
import Formatted from './Formatted';
import { BrandMark, type Brand } from './brands';
import { useScrollThumb } from './useScrollThumb';
import { AGENTS, type Attachments } from './mock';
import { SESSIONS, type Detail, type Entry } from './session';
import { useTasks, type Task } from './tasks';

// how long the way out takes (the sink animation in app.css)
const LEAVE_MS = 220;
// a word of what the agent is writing comes in this often
const WORD_MS = 70;

// The filters over the session: everything, or one kind, each with its count.
const FILTERS: { id: string; label: string }[] = [
  { id: 'all', label: 'All' }, { id: 'said', label: 'Said' }, { id: 'Bash', label: 'Commands' },
  { id: 'Edit', label: 'Edits' }, { id: 'Read', label: 'Reads' }, { id: 'Tetrix', label: 'Tetrix' }, { id: 'Web', label: 'Web' },
];
const filterOf = (e: Entry) =>
  e.kind === 'tool' ? (e.tool === 'Grep' ? 'Read' : e.tool) : e.kind === 'said' || e.kind === 'thought' || e.kind === 'you' ? 'said' : null;

// seconds as "0.2s", "41s" or "3m 12s"
const took = (s: number) => (s < 10 ? `${Math.round(s * 10) / 10}s` : s < 60 ? `${Math.round(s)}s` : `${Math.floor(s / 60)}m ${Math.round(s % 60)}s`);

// A job's session, live: the agent's words as it writes them, its thinking,
// each tool call as a quiet line that opens into what it ran and what came
// back, what you told it, its to-do list and the permissions it asked for.
// Opened from the task's page (Full session); it lies over it, as the task's
// conversation does, and back (or Esc) returns to the page. Values from the
// vault show as [vault: NAME], never the value.
export default function SessionView({ id, leaving, covered = false, onBack, onGone, onTell }: {
  id: string;
  leaving: boolean;
  covered?: boolean;
  onBack: () => void;
  onGone: () => void;
  onTell: (id: string, text: string, att: Attachments) => void;
}) {
  const tasks = useTasks();
  const kept = useRef<Task>(null);
  const task = tasks.find((t) => t.id === id) ?? kept.current!;
  kept.current = task;
  const entries = SESSIONS[id] ?? [];
  const running = task.status === 'running' || task.status === 'needs';
  const [filter, setFilter] = useState('all');
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLElement>();
  const [atEnd, setAtEnd] = useState(true);

  // what the agent is writing now comes in a word at a time; the tool at work counts up
  const liveSaid = entries.find((e): e is Extract<Entry, { kind: 'said' }> => e.kind === 'said' && !!e.live);
  const liveText = liveSaid?.text ?? '';
  const words = liveText.match(/\S+\s*/g) ?? [];
  const [shown, setShown] = useState(0);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!running) return;
    const w = setInterval(() => setShown((n) => Math.min(n + 1, words.length)), WORD_MS);
    const t = setInterval(() => setTick((n) => n + 1), 1000);
    return () => { clearInterval(w); clearInterval(t); };
  }, [running, words.length]);

  // it opens at the live end, as a conversation does, and stays there while you're there
  const pinned = useRef(true);
  useLayoutEffect(() => {
    const el = list.current;
    if (el && pinned.current) el.scrollTop = el.scrollHeight;
  });
  // and again once it has risen in and laid out, and whenever its size changes
  useEffect(() => {
    const el = list.current;
    if (!el) return;
    const pin = () => { if (pinned.current) el.scrollTop = el.scrollHeight; };
    const raf = requestAnimationFrame(pin);
    const ro = new ResizeObserver(pin);
    ro.observe(el);
    if (el.firstElementChild) ro.observe(el.firstElementChild);
    return () => { cancelAnimationFrame(raf); ro.disconnect(); };
  }, [list]);

  useEffect(() => {
    if (!leaving) return;
    const t = setTimeout(onGone, LEAVE_MS);
    return () => clearTimeout(t);
  }, [leaving, onGone]);
  useEffect(() => {
    if (covered) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape' && !typingIn(e)) onBack(); };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, [onBack, covered]);

  const count = (f: string) => (f === 'all' ? entries.filter((e) => e.kind !== 'start').length : entries.filter((e) => filterOf(e) === f).length);
  // keyed by their place in the whole session, so an opened line stays open across filters
  const visible = entries.map((e, n) => ({ e, n })).filter(({ e }) => filter === 'all' || e.kind === 'start' || filterOf(e) === filter);
  const agent = AGENTS[task.job.agent];

  return (
    <div className={`chat-layer${leaving ? ' is-leaving' : ''}${covered ? ' is-covered' : ''}`} inert={covered}>
      <div className="chat-scroll">
        <section
          ref={list}
          className="chat task-scroll"
          aria-label={`${task.title}: session`}
          onScroll={(e) => {
            onScroll();
            const el = e.currentTarget, end = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
            pinned.current = end;
            setAtEnd(end);
          }}
        >
          <div className="chat-column ss">
            <header className="ss-head">
              <h1>Session</h1>
              <p>
                {agent.name} · {task.job.model} · {task.job.account}
                {running && <span className="ss-live"><span className="status-dot is-working" />Live</span>}
              </p>
              <div className="ss-filters" role="tablist" aria-label="Show">
                {FILTERS.filter((f) => f.id === 'all' || count(f.id) > 0).map((f) => (
                  <button key={f.id} role="tab" aria-selected={filter === f.id} className={filter === f.id ? 'is-on' : undefined} onClick={() => setFilter(f.id)}>
                    {f.label} <span>{count(f.id)}</span>
                  </button>
                ))}
              </div>
            </header>
            <ol className="ss-entries">
              {visible.map(({ e, n }) => <Line key={n} entry={e} brand={agent.brand} live={{ shown: words.slice(0, shown).join(''), tick }} />)}
            </ol>
          </div>
        </section>
        <div {...thumbProps} />
        {/* scrolled up while it works: back to what's happening now */}
        {running && !atEnd && (
          <button className="ss-now" onClick={() => { const el = list.current; if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' }); }}>
            <ArrowDown size={14} strokeWidth={1.8} />Jump to now
          </button>
        )}
      </div>
      <Composer
        className="task-composer"
        autoFocus={false}
        placeholder={`Tell ${agent.name}…`}
        label={`Tell Oby about ${task.title}`}
        onSend={(text, att) => onTell(task.id, text, att)}
      />
    </div>
  );
}

// One entry of the session.
function Line({ entry: e, brand, live }: { entry: Entry; brand: Brand; live: { shown: string; tick: number } }) {
  const [open, setOpen] = useState(false);
  switch (e.kind) {
    case 'start':
      // a round begins: a quiet divider with the agent, model and time
      return <li className="ss-start"><span>{e.text}</span><time>{e.at}</time></li>;
    case 'said':
      return (
        <li className="ss-said">
          <span className="ss-mark"><BrandMark brand={brand} size={16} mono /></span>
          <p className="ss-words">
            <Formatted text={e.live ? live.shown : e.text} />
            {e.live && <span className="ss-caret" aria-hidden="true" />}
          </p>
        </li>
      );
    case 'thought':
      return (
        <li className={`ss-thought${open ? ' is-open' : ''}`}>
          <button onClick={() => setOpen(!open)} aria-expanded={open}>Thought for {took(e.seconds)}<ChevronRight size={12} strokeWidth={1.8} /></button>
          {open && <p>{e.text}</p>}
        </li>
      );
    case 'you':
      return <li className="ss-you"><p>{e.text}</p><time>{e.at}</time></li>;
    case 'plan':
      return (
        <li className="ss-plan">
          <span className="ss-plan-head">To do · {e.todos.filter((t) => t.state === 'done').length} of {e.todos.length} done</span>
          <ul>
            {e.todos.map((t) => (
              <li key={t.text} className={`is-${t.state}`}>
                {t.state === 'done' ? <Check size={12} strokeWidth={2} /> : <span className={`status-dot ${t.state === 'running' ? 'is-working' : 'is-queued'}`} />}
                {t.text}
              </li>
            ))}
          </ul>
        </li>
      );
    case 'asked':
      return <li className="ss-asked"><ShieldCheck size={13} strokeWidth={1.7} /><span><Formatted text={e.text} /> · {e.answer}</span></li>;
    case 'tool': {
      const secs = e.state === 'running' ? e.seconds + live.tick : e.seconds;
      return (
        <li className={`ss-tool is-${e.state}${open ? ' is-open' : ''}`}>
          <button className="ss-tool-row" onClick={() => e.detail && setOpen(!open)} aria-expanded={e.detail ? open : undefined} disabled={!e.detail}>
            <span className="ss-tool-mark">
              {e.state === 'done' ? <Check size={12} strokeWidth={2} /> : <span className={`status-dot ${e.state === 'running' ? 'is-working' : 'is-failed'}`} />}
            </span>
            <span className="ss-tool-text"><span className="ss-verb">{e.verb}</span> <code>{e.target}</code></span>
            {e.meta && <span className="ss-tool-meta">{e.meta}</span>}
            <span className="ss-took">{took(secs)}</span>
            {e.detail && <ChevronRight size={12} strokeWidth={1.8} className="ss-chev" />}
          </button>
          {open && e.detail && <ToolDetail tool={e.tool} detail={e.detail} seconds={e.seconds} />}
        </li>
      );
    }
  }
}

// What a call ran and what came back: a command and its output, an edit's
// diff, a read's lines, a search's matches, a question and its answer.
function ToolDetail({ tool, detail: d, seconds }: { tool: string; detail: Detail; seconds: number }) {
  if (d.diff) {
    return (
      <pre className="ss-code ss-diff">
        {d.diff.split('\n').map((l, i) => (
          <span key={i} className={l.startsWith('@@') ? 'is-hunk' : l[0] === '+' ? 'is-add' : l[0] === '-' ? 'is-del' : undefined}>{l}{'\n'}</span>
        ))}
      </pre>
    );
  }
  const shownLines = d.output ? d.output.split('\n').length : 0;
  return (
    <div className="ss-detail">
      {d.input && (tool === 'Bash'
        ? <pre className="ss-code"><span className="ss-prompt">$ </span>{d.input}</pre>
        : <p className="ss-input">{d.input}</p>)}
      {d.range && <p className="ss-input">{d.range}</p>}
      {d.output && <pre className="ss-code ss-out"><Masked text={d.output} /></pre>}
      {tool === 'Bash' && (
        <p className="ss-foot">
          {d.exit != null && <span className={d.exit ? 'is-failed' : undefined}>exit {d.exit}</span>}
          <span>{took(seconds)}</span>
          {d.lines && d.lines > shownLines && <span>the last {shownLines} of {d.lines.toLocaleString()} lines</span>}
        </p>
      )}
    </div>
  );
}

// a value from the vault, as obid sends it: a chip with its name, never the value
function Masked({ text }: { text: string }) {
  return <>{text.split(/(\[vault: [^\]]+\])/).map((part, i) => (part.startsWith('[vault: ') ? <span key={i} className="ss-vault" title="A value from Oby's vault, masked before it's shown here">{part.slice(1, -1)}</span> : part))}</>;
}
