import { Fragment, useCallback, useEffect, useRef, useState } from 'react';
import { ChevronLeft, ChevronRight, EllipsisVertical, PanelLeft } from 'lucide-react';
import Oby from './Oby';
import GroupView from './GroupView';
import ChatView from './ChatView';
import TaskView from './TaskView';
import SessionView from './SessionView';
import Sidebar from './Sidebar';
import TaskMenu from './TaskMenu';
import ConvoMenu from './ConvoMenu';
import Composer from './Composer';
import ObyView from './ObyView';
import ArchiveView from './ArchiveView';
import SettingsView, { settingsLabel } from './SettingsView';
import SphereSettings, { sphereSettingsLabel } from './SphereSettings';
import KnowledgeView, { knowledgeLabel } from './KnowledgeView';
import { useSpheres } from './spheres';
import { askOby, chatOfTask, renameChat, tellAbout, useChats } from './chats';
import { useConvos } from './peers';
import { AvatarStack } from './ObyFace';
import { convoTitle, hasAttachments, type Attachments } from './mock';
import { TYPES, renameTask, tell, countOf, firstTab, hasFresh, useTasks, type Tab } from './tasks';

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
// with Oby, the archive, someone else's Oby, a conversation with it. Each
// opens over the one before; the trail follows the way you came, not a fixed
// hierarchy (a task from the side panel is just the task; from a chip, the kind
// of work, then the task; from a conversation's card, the conversation, then
// the task). Opening a step already in the trail goes back to it rather than
// adding it again, so a task and its conversation go back and forth.
type Step =
  | { kind: 'group'; id: string; tab: Tab }
  | { kind: 'task' | 'thread' | 'talk' | 'oby' | 'peer' | 'settings' | 'session'; id: string }
  // an Obysphere's settings, or its knowledge: which one
  | { kind: 'sphere' | 'knowledge'; id: string }
  | { kind: 'archive'; id?: undefined };
// a step on screen; leaving: on its way out (gone once its animation ends)
type Layer = Step & { key: string; leaving?: boolean };
const same = (a: Step, b: Step) => a.kind === b.kind && a.id === b.id;
let made = 0;

export default function Home() {
  const tasks = useTasks();  // counts and dots follow tasks being added and opened
  const chats = useChats();
  const convos = useConvos();
  const spheres = useSpheres();
  const running = countOf('running'), needsYou = countOf('needs');

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

  // the task on top, if a task's page is: its ⋮ in the title bar, and renaming it in place there;
  // the same for a conversation with Oby
  const shown = top?.kind === 'task' ? tasks.find((t) => t.id === top.id) : undefined;
  const shownTalk = top?.kind === 'talk' ? chats.find((c) => c.id === top.id) : undefined;
  const [barMenu, setBarMenu] = useState<DOMRect | null>(null);
  const [renaming, setRenaming] = useState(false);
  useEffect(() => { setBarMenu(null); setRenaming(false); }, [top?.key]);
  // deleted from its page or a conversation: its page goes too
  useEffect(() => {
    const i = live.findIndex((l) => l.kind === 'task' && !tasks.some((t) => t.id === l.id));
    if (i >= 0) backTo(i - 1);
  }, [tasks]);
  // an Obysphere deleted or left (from its settings): its settings and Knowledge pages go too
  useEffect(() => {
    const i = live.findIndex((l) => (l.kind === 'sphere' || l.kind === 'knowledge') && !spheres.some((s) => s.id === l.id));
    if (i >= 0) backTo(i - 1);
  }, [spheres]);
  // a conversation deleted (from its menu): its page goes too
  useEffect(() => {
    const i = live.findIndex((l) => l.kind === 'talk' && !chats.some((c) => c.id === l.id));
    if (i >= 0) backTo(i - 1);
  }, [chats]);

  // a task's conversation: the one with Oby it was started in (the whole of it),
  // else its own thread (one that came in from GitHub, Slack…)
  const conversationOf = (id: string): Step => {
    const c = chatOfTask(id);
    return c ? { kind: 'talk', id: c.id } : { kind: 'thread', id };
  };
  const openTask = (id: string) => push({ kind: 'task', id });
  const goToConversation = (id: string) => push(conversationOf(id));
  // asked in Home's message box: a new conversation, open straight away
  const ask = (text: string, att: Attachments) => {
    const id = askOby(text, att);
    if (id) start({ kind: 'talk', id });
  };
  // said in a task page's message box: it goes on the end of the task's
  // conversation, which opens (or comes back), so Oby's answer is where it's said
  const tellFromTask = (id: string, text: string, att: Attachments) => {
    if (!text.trim() && !hasAttachments(att)) return;
    const c = chatOfTask(id);
    if (c) tellAbout(c.id, id, text, att); else tell(id, text, att);
    goToConversation(id);
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
  // in full screen there are no traffic lights, so the title bar starts at the edge
  const [fullScreen, setFullScreen] = useState(() => window.app?.fullScreen ?? false);
  useEffect(() => window.app?.onFullScreen(setFullScreen), []);
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
    if (l.kind === 'group') return TYPES.find((t) => t.id === l.id)?.label ?? '';
    if (l.kind === 'task') { const t = tasks.find((k) => k.id === l.id); return t ? `${t.who ? `${t.who} ` : ''}${t.title}` : ''; }
    if (l.kind === 'thread') { const t = tasks.find((k) => k.id === l.id); return t ? convoTitle(t.job) : ''; }
    if (l.kind === 'talk') return chats.find((c) => c.id === l.id)?.title ?? '';
    if (l.kind === 'archive') return 'Archived';
    if (l.kind === 'session') return 'Session';
    if (l.kind === 'settings') return settingsLabel(l.id);
    if (l.kind === 'sphere') return sphereSettingsLabel(l.id, spheres);
    if (l.kind === 'knowledge') return knowledgeLabel;
    if (l.kind === 'oby') return `${l.id}’s Oby`;
    return convos.find((c) => c.id === l.id)?.title ?? '';
  };
  // the Obys in the conversation on top, if it's one with other people's Obys
  const peerWith = top?.kind === 'peer' ? convos.find((c) => c.id === top.id)?.with : undefined;
  // the side panel's highlighted row: the task, conversation or Oby on top
  const firstOby = live.find((l) => l.kind === 'oby');
  // and in Home, the task: on its page, in its thread, or in the conversation
  // opened from its page
  const under = live.at(-2);
  const rootTask = top?.kind === 'task' || top?.kind === 'thread' ? top.id : top?.kind === 'talk' && under?.kind === 'task' ? under.id : null;

  return (
    <div className={`app${sidebar ? ' has-sidebar' : ''}${resizing ? ' is-resizing' : ''}${settling ? ' is-settling' : ''}${fullScreen ? ' is-full-screen' : ''}`} style={{ '--sidebar': `${sidebarWidth}px` } as React.CSSProperties}>
      <Sidebar
        open={sidebar}
        onNewChat={newChat}
        onHome={closeAll}
        onOpenTask={(id) => start({ kind: 'task', id })}
        onOpenChat={(id) => start({ kind: 'task', id }, conversationOf(id))}
        onOpenOby={(name) => start({ kind: 'oby', id: name })}
        onOpenTalk={(id) => start({ kind: 'talk', id })}
        onOpenArchive={() => start({ kind: 'archive' })}
        onOpenSetting={(id) => start({ kind: 'settings', id })}
        activeSetting={top?.kind === 'settings' ? top.id : null}
        onOpenSphereSetting={(id) => start({ kind: 'sphere', id })}
        activeSphereSetting={top?.kind === 'sphere' ? top.id : null}
        onOpenKnowledge={(id) => start({ kind: 'knowledge', id })}
        activeKnowledge={top?.kind === 'knowledge' ? top.id : null}
        active={rootTask}
        activeTalk={top?.kind === 'talk' ? top.id : null}
        activeOby={firstOby?.id ?? null}
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
            you are (a task's: renamed in place, and its ⋮) */}
        {trail.length > 0 && (
          <nav className={`crumbs${leavingAll ? ' is-leaving' : ''}`} aria-label="Where you are">
            {trail.map((l, i) => {
              const last = i === trail.length - 1;
              return (
                <Fragment key={l.key}>
                  {i > 0 && <ChevronRight size={24} strokeWidth={1.2} className="crumb-sep" />}
                  {!last ? <Crumb onClick={() => backTo(i)}>{label(l)}</Crumb>
                    : (shown || shownTalk) && renaming ? (
                      <input
                        className="crumb-rename"
                        defaultValue={(shown ?? shownTalk)!.title}
                        autoFocus
                        onFocus={(e) => e.currentTarget.select()}
                        onBlur={(e) => {
                          if (shown) renameTask(shown.id, e.currentTarget.value);
                          else if (shownTalk) renameChat(shownTalk.id, e.currentTarget.value);
                          setRenaming(false);
                        }}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter') e.currentTarget.blur();
                          // Esc leaves the name as it was (and stays on the page)
                          if (e.key === 'Escape') { e.stopPropagation(); setRenaming(false); }
                        }}
                        aria-label={shown ? 'Task name' : 'Conversation name'}
                      />
                    ) : <>
                      <Crumb>{label(l)}</Crumb>
                      {/* a task's or a conversation's menu, as on its side panel row */}
                      {(shown || shownTalk) && !leavingAll && (
                        <button
                          className={`icon-button bar-more${barMenu ? ' is-on' : ''}`}
                          aria-label={shown ? 'Task options' : 'Conversation options'}
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
        {/* in a conversation with a few Obys, at the right: who's in it (one Oby's
            name is already the trail's) */}
        {peerWith && peerWith.length > 1 && (
          <div className="bar-end">
            <span className="bar-obys" title={peerWith.map((n) => `${n}’s Oby`).join(', ')}>
              <AvatarStack names={peerWith} />
              {/* a count only once there are 3 or more; fewer, the pictures say it */}
              {peerWith.length >= 3 && peerWith.length}
            </span>
          </div>
        )}
        {/* on a task's page, at the right: the way into its conversation */}
        {shown && (
          <div className="bar-end">
            <button className="bar-convo" onClick={() => goToConversation(shown.id)}>
              Go to conversation
            </button>
          </div>
        )}
      </header>
      {barMenu && shown && (
        <TaskMenu task={shown} at={barMenu} align="left" onClose={() => setBarMenu(null)} onOpenChat={() => goToConversation(shown.id)} onRename={() => setRenaming(true)} />
      )}
      {barMenu && shownTalk && (
        <ConvoMenu chat={shownTalk} at={barMenu} align="left" onClose={() => setBarMenu(null)} onRename={() => setRenaming(true)} />
      )}

      <main className="main">
        <div className={`stage${away ? ' is-hidden' : ''}`} inert={away}>
        <Oby paused={away} glance={onChips && !away} />
        {TYPES.length > 0 && (
          <section className="attention" aria-label="Your tasks">
            <span className={`attention-label${running || needsYou ? '' : ' is-idle'}`}>{attention(running, needsYou)}</span>
            {/* every kind of work, in its usual order, whatever's going on in it (a
                kind with nothing open opens on its completed ones), so the kinds
                show here even while the side panel groups by status */}
            <div className="chips" onPointerEnter={() => setOnChips(true)} onPointerLeave={() => setOnChips(false)}>
                {TYPES.map((c) => (
                  <button key={c.id} className="chip" onClick={() => start({ kind: 'group', id: c.id, tab: firstTab(c.id) })}>
                    {/* blue: holds a new task; orange: something in it needs you; both can show */}
                    {(hasFresh(c.id) || countOf('needs', c.id) > 0) && (
                      <span className="chip-dots">
                        {hasFresh(c.id) && <span className="is-fresh" role="img" aria-label="New" />}
                        {countOf('needs', c.id) > 0 && <span className="is-needs" role="img" aria-label="Needs you" />}
                      </span>
                    )}
                    {c.label}
                  </button>
                ))}
            </div>
          </section>
        )}
        </div>
      </main>

      {/* asking Oby: a new conversation, opened at once */}
      <Composer
        home
        hidden={away}
        placeholder="What do you want me to work on, Doti?"
        label="Message Oby"
        onSend={ask}
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
        if (l.kind === 'group') return <GroupView key={l.key} group={TYPES.find((t) => t.id === l.id)!} tab={l.tab} leaving={leaving} covered={covered} onClose={back} onGone={onGone} onOpenTask={openTask} onOpenArchive={() => push({ kind: 'archive' })} />;
        if (l.kind === 'task') return <TaskView key={l.key} id={l.id} leaving={leaving} covered={covered} onBack={back} onHome={closeAll} onGone={onGone} onTell={tellFromTask} onSession={(id) => push({ kind: 'session', id })} />;
        if (l.kind === 'session') return <SessionView key={l.key} id={l.id} leaving={leaving} covered={covered} onBack={back} onGone={onGone} onTell={tellFromTask} />;
        if (l.kind === 'archive') return <ArchiveView key={l.key} leaving={leaving} covered={covered} onClose={back} onGone={onGone} onOpenTask={openTask} />;
        if (l.kind === 'settings') return <SettingsView key={l.key} page={l.id} leaving={leaving} covered={covered} onClose={back} onGone={onGone} />;
        if (l.kind === 'sphere') return <SphereSettings key={l.key} id={l.id} leaving={leaving} covered={covered} onClose={back} onGone={onGone} />;
        if (l.kind === 'knowledge') return <KnowledgeView key={l.key} id={l.id} leaving={leaving} covered={covered} onClose={back} onGone={onGone} />;
        if (l.kind === 'oby') return <ObyView key={l.key} name={l.id} leaving={leaving} covered={covered} onClose={back} onGone={onGone} onOpenConvo={(id) => push({ kind: 'peer', id })} />;
        const kind = l.kind === 'talk' ? 'oby' : l.kind === 'peer' ? 'peer' : 'task';
        return <ChatView key={l.key} kind={kind} id={l.id} leaving={leaving} covered={covered} onBack={back} onGone={onGone} onOpenTask={openTask} />;
      })}
    </div>
      {/* stays next to the traffic lights whether the side panel is open or not.
          Last in the page on purpose: Electron reads drag areas in page order,
          so coming after the title bar keeps its click from being taken as a drag */}
      <button className="icon-button panel-toggle" aria-label={sidebar ? 'Hide sidebar' : 'Show sidebar'} aria-expanded={sidebar} onClick={() => setSidebar((v) => !v)}>
        <PanelLeft size={18} strokeWidth={1.6} />
      </button>
    </div>
  );
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
