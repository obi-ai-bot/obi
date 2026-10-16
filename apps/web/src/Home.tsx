import { Fragment, useCallback, useEffect, useRef, useState } from 'react';
import { ChevronLeft, ChevronRight, EllipsisVertical, PanelLeft } from 'lucide-react';
import Oby from './Oby';
import GroupView from './GroupView';
import ChatView from './ChatView';
import TaskView from './TaskView';
import Sidebar from './Sidebar';
import TaskMenu from './TaskMenu';
import Composer from './Composer';
import ArchiveView from './ArchiveView';
import SettingsView, { settingsLabel } from './SettingsView';
import KnowledgeView, { knowledgeLabel } from './KnowledgeView';
import { isNew, newStep, startOf, startedIn, titleOf } from './chats';
import { ask, newConversation, openConversation, tellJob, useLive } from './live';
import { chipOf, countOf, firstTab, typeById, typesOn, useTasks, type Tab } from './tasks';

// the line over the chips: what's running and what needs you; with neither,
// Oby asking for something to do
function attention(running: number, needs: number) {
  const r = `${running} running task${running === 1 ? '' : 's'}`;
  const n = `${needs} need${needs === 1 ? 's' : ''} you`;
  if (running && needs) return `${r} · ${n}`;
  if (running) return `${r} · nothing needs you`;
  if (needs) return n;
  return 'All quiet. Give me something to work on';
}

// side panel width limits, icons (48px) included
const SIDEBAR_DEFAULT = 290, SIDEBAR_MIN = 252, SIDEBAR_MAX = 472;
// How far past a limit the panel can stretch, and how stiffly (UIKit's
// rubber-band curve: gives STIFF of the drag at first, approaching STRETCH)
const STRETCH = 60, STIFF = 0.55;
const band = (over: number) => (1 - 1 / ((over * STIFF) / STRETCH + 1)) * STRETCH;
function rubberBand(w: number) {
  if (w > SIDEBAR_MAX) return SIDEBAR_MAX + band(w - SIDEBAR_MAX);
  if (w < SIDEBAR_MIN) return SIDEBAR_MIN - band(SIDEBAR_MIN - w);
  return w;
}

// Where you are, as the steps that got you there (the title bar's trail): a
// kind of work's cards, a task's page, a task's own thread, a conversation
// with Oby (by its id, or a new one's step, newStep, for one its first words will start), the archive,
// Settings, an Obysphere's knowledge. Each
// opens over the one before; the trail follows the way you came, not a fixed
// hierarchy (a task from the side panel is just the task; from a chip, the kind
// of work, then the task; from a conversation's card, the conversation, then
// the task). Opening a step already in the trail goes back to it rather than
// adding it again, so a task and its conversation go back and forth.
type Step =
  | { kind: 'group'; id: string; tab: Tab }
  | { kind: 'task' | 'thread' | 'talk' | 'settings'; id: string }
  | { kind: 'archive'; id?: undefined }
  | { kind: 'knowledge'; id?: undefined };
// a step on screen; leaving: on its way out (gone once its animation ends)
type Layer = Step & { key: string; leaving?: boolean };
const same = (a: Step, b: Step) => a.kind === b.kind && a.id === b.id;
let made = 0;

export default function Home() {
  const store = useLive();
  const tasks = useTasks();  // counts and dots follow tasks being added and opened
  const running = countOf(store, 'running'), needsYou = countOf(store, 'needs');
  const types = typesOn(store);

  const [layers, setLayers] = useState<Layer[]>([]);
  const live = layers.filter((l) => !l.leaving);
  const top = live.at(-1);
  const layer = (step: Step): Layer => ({ ...step, key: `${step.kind}:${step.id ?? ''}:${++made}` });
  // over what's open: a step, or back to it if it's already in the trail
  const push = (step: Step) => setLayers((all) => {
    const now = all.filter((l) => !l.leaving), at = now.findIndex((l) => same(l, step));
    if (at >= 0) return all.map((l) => (now.indexOf(l) > at ? { ...l, leaving: true } : l));
    return [...all, layer(step)];
  });
  // back to a step in the trail: everything over it leaves
  const backTo = (i: number) => setLayers((all) => {
    const now = all.filter((l) => !l.leaving);
    return all.map((l) => (now.indexOf(l) > i ? { ...l, leaving: true } : l));
  });
  // A fresh start (from the side panel, a chip, Home's box): what was open
  // leaves. Whatever of it is already open, from the first step on, stays as it
  // is (not a second copy rising over the first): the same task from the side
  // panel just comes back, as a step in the trail does
  const start = (...steps: Step[]) => setLayers((all) => {
    const now = all.filter((l) => !l.leaving), kept: Layer[] = [];
    for (const step of steps) {
      const at = now.findIndex((l) => same(l, step));
      if (at < 0 || (kept.length && at < now.indexOf(kept.at(-1)!))) break;
      kept.push(now[at]);
    }
    return [...all.map((l) => (kept.includes(l) || l.leaving ? l : { ...l, leaving: true })), ...steps.slice(kept.length).map(layer)];
  });
  // back to Home
  const closeAll = useCallback(() => setLayers((all) => all.map((l) => ({ ...l, leaving: true }))), []);
  // gone (its way out over): off the list. One callback per step, kept, so a
  // view's timer for it isn't restarted each time Home draws
  const goneFns = useRef(new Map<string, () => void>());
  const goneFor = (key: string) => {
    let f = goneFns.current.get(key);
    if (!f) {
      f = () => { goneFns.current.delete(key); setLayers((all) => all.filter((l) => l.key !== key)); };
      goneFns.current.set(key, f);
    }
    return f;
  };

  // the task on top, if a task's page is: its ⋮ in the title bar
  const shown = top?.kind === 'task' ? tasks.find((t) => t.id === top.id) : undefined;
  const [barMenu, setBarMenu] = useState<DOMRect | null>(null);
  useEffect(() => { setBarMenu(null); }, [top?.key]);

  // a task's conversation: the conversation with Oby it was started in, while that's still there
  // (the whole of it), else its own thread
  const conversationOf = (id: string): Step => {
    const in_ = startedIn(store, id) ?? (startOf(store, id) ? store.shown : null);
    return in_ ? { kind: 'talk', id: in_ } : { kind: 'thread', id };
  };
  const openTask = (id: string) => push({ kind: 'task', id });
  const goToConversation = (id: string) => push(conversationOf(id));
  // asked in Home's message box: to Oby (POST /v1/plans), a new conversation ("new": true, #493),
  // open straight away
  const askOby = (text: string) => {
    void ask(text, undefined, { new: true });
    start({ kind: 'talk', id: newStep() });
  };
  // a conversation from the side panel; New conversation: an empty one, which its words start
  const openTalk = (id: string) => { void openConversation(id); start({ kind: 'talk', id }); };
  const startTalk = () => { newConversation(); start({ kind: 'talk', id: newStep() }); };
  // said in a task page's message box: to its agent (POST /v1/jobs/{id}/messages), and its own
  // thread opens over the page, where what you said shows
  const tellFromTask = (id: string, text: string) => {
    if (!text.trim()) return;
    void tellJob(id, text);
    push({ kind: 'thread', id });
  };

  // the pointer arriving on the chips: Oby glances over
  const [onChips, setOnChips] = useState(false);
  // the side panel opens as you left it: closed the first time
  const [sidebar, setSidebar] = useState(() => {
    try { return localStorage.getItem('oby.sidebarOpen') === '1'; } catch { return false; }
  });
  useEffect(() => {
    try { localStorage.setItem('oby.sidebarOpen', sidebar ? '1' : '0'); } catch { /* not remembered, that's all */ }
  }, [sidebar]);
  // the side panel's width (icons included), set by dragging its edge; remembered
  const [sidebarWidth, setSidebarWidth] = useState(() => {
    try { return Number(localStorage.getItem('oby.sidebarWidth')) || SIDEBAR_DEFAULT; } catch { return SIDEBAR_DEFAULT; }
  });
  const [resizing, setResizing] = useState(false);
  // let go: the edge springs to where it settles (--settle, 520ms)
  const [settling, setSettling] = useState(false);
  const settled = useRef(0);
  // While dragging, past the limits the panel gives less and less (rubber band);
  // on release it settles within them, the eased width transition springing it back.
  const resizeSidebar = useCallback((w: number | null, done = false) => {
    if (w == null) w = SIDEBAR_DEFAULT;
    const next = done ? Math.min(SIDEBAR_MAX, Math.max(SIDEBAR_MIN, Math.round(w))) : rubberBand(w);
    setSidebarWidth(next);
    setResizing(!done);
    clearTimeout(settled.current);
    setSettling(done);
    if (done) settled.current = window.setTimeout(() => setSettling(false), 520);
    if (done) try { localStorage.setItem('oby.sidebarWidth', String(next)); } catch { /* not remembered, that's all */ }
  }, []);

  // what's showing over Oby's stage, if anything (until it has left)
  const away = layers.length > 0;
  // the message box's usage panel asks for a Settings page (Manage accounts)
  useEffect(() => {
    // over what's open, so back (or Esc) returns to it (push only uses the
    // updater, so listening once is enough)
    const open = (e: Event) => push({ kind: 'settings', id: (e as CustomEvent<string>).detail });
    addEventListener('oby:open-setting', open);
    return () => removeEventListener('oby:open-setting', open);
  }, []);
  // New task: back Home, and into its message box once what was open has gone
  // (the box can't take the focus while a page is still over it)
  const [focusHome, setFocusHome] = useState(false);
  const newChat = useCallback(() => { closeAll(); setFocusHome(true); }, [closeAll]);
  useEffect(() => {
    if (!focusHome || layers.length) return;
    document.querySelector<HTMLElement>('.composer .composer-input')?.focus();
    setFocusHome(false);
  }, [focusHome, layers.length]);
  // the trail: what's open, or (on the way back to Home) what's leaving
  const trail = live.length ? live : layers;
  const leavingAll = !live.length;
  const label = (l: Layer) => {
    if (l.kind === 'group') return typeById(l.id).label;
    if (l.kind === 'task') return tasks.find((k) => k.id === l.id)?.title ?? '';
    if (l.kind === 'thread') { const t = tasks.find((k) => k.id === l.id); return t ? `About ${t.title}` : ''; }
    // a new one, or one deleted under it: the one its words started, if they did
    if (l.kind === 'talk') return titleOf(store, isNew(l.id) || !store.conversations.some((c) => c.id === l.id) ? store.shown : l.id);
    if (l.kind === 'archive') return 'Archived';
    if (l.kind === 'settings') return settingsLabel(l.id);
    return knowledgeLabel;
  };
  // the side panel's highlighted row: in Home, the task: on its page, in its thread, or in the
  // conversation opened from its page
  const under = live.at(-2);
  const rootTask = top?.kind === 'task' || top?.kind === 'thread' ? top.id : top?.kind === 'talk' && under?.kind === 'task' ? under.id : null;

  return (
    <div className={`app is-full-screen${sidebar ? ' has-sidebar' : ''}${resizing ? ' is-resizing' : ''}${settling ? ' is-settling' : ''}`} style={{ '--sidebar': `${sidebarWidth}px` } as React.CSSProperties}>
      <Sidebar
        open={sidebar}
        onNewChat={newChat}
        onHome={closeAll}
        onOpenTask={(id) => start({ kind: 'task', id })}
        onOpenChat={(id) => start({ kind: 'task', id }, conversationOf(id))}
        onOpenTalk={openTalk}
        onNewConversation={startTalk}
        onOpenArchive={() => start({ kind: 'archive' })}
        onOpenSetting={(id) => start({ kind: 'settings', id })}
        activeSetting={top?.kind === 'settings' ? top.id : null}
        onOpenKnowledge={() => start({ kind: 'knowledge' })}
        activeKnowledge={top?.kind === 'knowledge'}
        active={rootTask}
        activeTalk={top?.kind === 'talk' ? store.shown : null}
        width={sidebarWidth}
        onResize={resizeSidebar}
      />

    <div className="home">
      <header className="bar">
        {/* back: to Home, from anywhere (the trail beside it goes to the steps between) */}
        {away && (
          <button className={`icon-button bar-back${leavingAll ? ' is-leaving' : ''}`} onClick={closeAll} aria-label="Back to Home">
            <ChevronLeft size={24} strokeWidth={1.2} />
          </button>
        )}
        {/* the trail: each step before the last goes back to it; the last is where
            you are (a task's, with its ⋮) */}
        {trail.length > 0 && (
          <nav className={`crumbs${leavingAll ? ' is-leaving' : ''}`} aria-label="Where you are">
            {trail.map((l, i) => {
              const last = i === trail.length - 1;
              return (
                <Fragment key={l.key}>
                  {i > 0 && <ChevronRight size={24} strokeWidth={1.2} className="crumb-sep" />}
                  {!last ? <Crumb onClick={() => backTo(i)}>{label(l)}</Crumb>
                    : <>
                      <Crumb>{label(l)}</Crumb>
                      {/* a task's menu, as on its side panel row */}
                      {shown && !leavingAll && (
                        <button
                          className={`icon-button bar-more${barMenu ? ' is-on' : ''}`}
                          aria-label="Task options"
                          aria-haspopup="menu"
                          aria-expanded={!!barMenu}
                          onClick={(e) => setBarMenu(barMenu ? null : e.currentTarget.getBoundingClientRect())}
                        >
                          <EllipsisVertical size={16} strokeWidth={1.6} />
                        </button>
                      )}
                    </>}
                </Fragment>
              );
            })}
          </nav>
        )}
        {/* on a task's page, at the right: the way into its conversation */}
        {shown?.job.agent && (
          <div className="bar-end">
            <button className="bar-convo" onClick={() => goToConversation(shown.id)}>
              Go to conversation
            </button>
          </div>
        )}
      </header>
      {barMenu && shown && (
        <TaskMenu task={shown} at={barMenu} align="left" onClose={() => setBarMenu(null)} onOpenChat={() => goToConversation(shown.id)} />
      )}
      <Connection />

      <main className="main">
        <div className={`stage${away ? ' is-hidden' : ''}`} inert={away}>
        <Oby paused={away} glance={onChips && !away} />
        <section className="attention" aria-label="Your tasks">
          <span className={`attention-label${running || needsYou ? '' : ' is-idle'}`}>{attention(running, needsYou)}</span>
          {/* every kind of work on Home, in its usual order, whatever's going on in it (a
              kind with nothing open opens on its completed ones), so the kinds show here
              even while the side panel groups by status */}
          {types.length > 0 && (
            <div className="chips" onPointerEnter={() => setOnChips(true)} onPointerLeave={() => setOnChips(false)}>
                {types.map((c) => {
                  const dots = chipOf(store, c.id);
                  return (
                    <button key={c.id} className="chip" onClick={() => start({ kind: 'group', id: c.id, tab: firstTab(store, c.id) })}>
                      {/* blue: holds a new task; orange: something in it needs you; both can show */}
                      {(dots.fresh || dots.needs) && (
                        <span className="chip-dots">
                          {dots.fresh && <span className="is-fresh" role="img" aria-label="New" />}
                          {dots.needs && <span className="is-needs" role="img" aria-label="Needs you" />}
                        </span>
                      )}
                      {c.label}
                    </button>
                  );
                })}
            </div>
          )}
        </section>
        </div>
      </main>

      {/* asking Oby: the conversation, opened at once */}
      <Composer
        home
        hidden={away}
        busy={store.thinking}
        placeholder="What do you want me to work on?"
        label="Message Oby"
        onSend={askOby}
      />
      {/* what's open, each over the one before; the one on top is live, the rest
          covered (and still, under it); one leaving fades out, then it's gone */}
      {layers.map((l) => {
        // covered while anything is over it, even something on its way out: going
        // back, it shows only once what was over it is gone; going Home, it never
        // shows again (the one on top fades alone)
        const i = live.indexOf(l);
        const covered = layers.indexOf(l) < layers.length - 1;
        const leaving = !!l.leaving, onGone = goneFor(l.key);
        // a page on its way out has nowhere to go back to (a second quick Esc)
        const back = () => { if (i < 0) return; if (i > 0) backTo(i - 1); else closeAll(); };
        if (l.kind === 'group') return <GroupView key={l.key} group={typeById(l.id)} tab={l.tab} leaving={leaving} covered={covered} onClose={back} onGone={onGone} onOpenTask={openTask} onOpenArchive={() => push({ kind: 'archive' })} />;
        if (l.kind === 'task') return <TaskView key={l.key} id={l.id} leaving={leaving} covered={covered} onBack={back} onHome={closeAll} onGone={onGone} onTell={tellFromTask} />;
        if (l.kind === 'archive') return <ArchiveView key={l.key} leaving={leaving} covered={covered} onClose={back} onGone={onGone} onOpenTask={openTask} />;
        if (l.kind === 'settings') return <SettingsView key={l.key} page={l.id} leaving={leaving} covered={covered} onClose={back} onGone={onGone} />;
        if (l.kind === 'knowledge') return <KnowledgeView key={l.key} leaving={leaving} covered={covered} onClose={back} onGone={onGone} />;
        return <ChatView key={l.key} kind={l.kind === 'talk' ? 'oby' : 'task'} id={l.id} leaving={leaving} covered={covered} onBack={back} onGone={onGone} onOpenTask={openTask} />;
      })}
    </div>
      {/* stays at the top left whether the side panel is open or not */}
      <button className="icon-button panel-toggle" aria-label={sidebar ? 'Hide sidebar' : 'Show sidebar'} aria-expanded={sidebar} onClick={() => setSidebar((v) => !v)}>
        <PanelLeft size={18} strokeWidth={1.6} />
      </button>
    </div>
  );
}

// How the page stands with obid, over everything: connecting, or why it can't
// reach it, or what last went wrong; nothing while all is well
function Connection() {
  const { connection, problem } = useLive();
  if (connection === 'live' && !problem) return null;
  const text = connection === 'connecting' ? 'Connecting to Oby…' : problem ?? 'Oby isn’t answering. Trying again…';
  return <p className={`connection is-${connection}`} role="status">{text}</p>;
}

// One step of the title bar's trail: a link back to it, or (no onClick) where
// you are. Its name fades out at the end only when it's cut short.
function Crumb({ onClick, children }: { onClick?: () => void; children: React.ReactNode }) {
  const ref = useRef<HTMLElement>(null);
  const [clipped, setClipped] = useState(false);
  useEffect(() => {
    const el = ref.current!;
    const ro = new ResizeObserver(() => setClipped(el.scrollWidth > el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  // and when its words change at the same width (a rename at its widest)
  useEffect(() => {
    const el = ref.current!;
    setClipped(el.scrollWidth > el.clientWidth);
  });
  const className = `crumb${onClick ? '' : ' is-here'}${clipped ? ' is-clipped' : ''}`;
  return onClick
    ? <button ref={ref as React.RefObject<HTMLButtonElement>} className={className} onClick={onClick}>{children}</button>
    : <span ref={ref} className={className} aria-current="page">{children}</span>;
}
