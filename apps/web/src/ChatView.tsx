import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { ChevronRight } from 'lucide-react';
import ObyFaceLive from './ObyFaceLive';
import StatusDot from './StatusDot';
import { AskBlock, TaskMark, resultLine } from './TaskCard';
import { useScrollThumb } from './useScrollThumb';
import Composer, { typingIn } from './Composer';
import Formatted from './Formatted';
import { tokenize } from './textTokens';
import { answerQuestion, ask, loadOlder, markSeen, openConversation, tellJob, useLive, type Live } from './live';
import { isNew, layerOf, startOf, toMessage, useChat, type Message } from './chats';
import { AGENTS, metaOf, useTasks, type Ask, type Task } from './tasks';

// how long the way out takes (the sink animation in app.css)
const LEAVE_MS = 220;
// a quiet this long between two messages (minutes) starts a new run, with its own time
const GAP = 60;
// a message's time: the clock today, else the day and the clock
export const clock = (ago: number) => {
  const d = new Date(Date.now() - ago * 60_000);
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  return d.toDateString() === new Date().toDateString() ? time : `${d.toLocaleDateString([], { weekday: 'short' })} ${time}`;
};

// One entry in the thread: a message, or the decision the task needs from you
// (Oby asking, so it sits on Oby's side).
type Entry = Message | { id: string; who: 'oby'; ask: Ask; ago?: number; text?: undefined };

// A task's own thread, oldest first: what started it (your words in the conversation, or its
// request), Oby's answer that started it with its card (or just its card, when it started
// elsewhere), what you've told its agent since (its notes, which have no times), and its agent's
// report once it's done.
function threadOf(s: Live, t: Task): Message[] {
  const now = Date.now(), j = t.job;
  const start = startOf(s, t.id);
  const out: Message[] = [
    start?.asked ? toMessage(start.asked, now) : { id: 'request', who: 'you', text: j.request, ago: j.created },
    start ? toMessage(start.answer, now) : { id: 'started', who: 'oby', text: '', ago: j.created, jobs: [t.id] },
    ...j.notes.map((text, i): Message => ({ id: `note-${i}`, who: 'you', text })),
  ];
  if (t.status !== 'running' && j.summary) out.push({ id: 'summary', who: 'oby', text: j.summary, ago: j.finished });
  return out;
}

// A conversation. kind 'oby': one with Oby (chats.ts), `id` (or NEW, one its first words start),
// opened from the side panel or a task, or started on Home: what you asked, Oby's answers with
// the tasks they started as cards under them; the message box carries it on (POST /v1/plans). kind 'task': a task's own thread (threadOf), and
// its agent's live line while it works; the message box tells the agent. Whatever is happening
// now comes last. It lies over what was open; back (in the title bar, or Esc) returns to it.
export default function ChatView({ id, kind = 'task', leaving, covered = false, onBack, onGone, onOpenTask }: {
  id: string;
  kind?: 'task' | 'oby';
  leaving: boolean;
  covered?: boolean;  // a task's page (from one of its cards) is open over it
  onBack: () => void;
  onGone: () => void;
  onOpenTask: (id: string) => void;       // a card in the thread: that task's page
}) {
  const live = useLive();
  const tasks = useTasks();
  const chat = useChat();
  // gone while this sinks away: keep showing the last of it
  const keptTask = useRef<Task>(null);
  const task = kind === 'task' ? tasks.find((t) => t.id === id) ?? keptTask.current! : null;
  if (task) keptTask.current = task;
  const j = task?.job;
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLElement>();
  const agent = j?.agent ? AGENTS[j.agent].name : 'Oby';
  // The conversation this layer is for: `id`, shown again when it's on top again after another
  // was opened over it (nothing of that other one meanwhile). NEW until its words start one, which
  // it then is; deleted (here or elsewhere), NEW again, so the next words start one shown here.
  const [own, setOwn] = useState(id);
  const listed = live.conversations.some((c) => c.id === own);
  useEffect(() => {
    if (kind !== 'oby' || covered || leaving) return;
    const next = layerOf(own, live.shown, listed);
    if (next !== own) setOwn(next);
    else if (!isNew(own) && listed) void openConversation(own);
  }, [kind, own, covered, leaving, listed, live.shown]);
  const mine = kind === 'oby' && (isNew(own) || live.shown === own);
  // Oby's question back, when it asked it in this conversation
  const waiting = !task && mine && live.waiting && live.waiting.conversation === live.shown ? live.waiting : null;
  // a task's: what came before, the decision (if any) where things stand
  const before = task ? threadOf(live, task) : [];
  const thread: Entry[] = task ? [
    ...before,
    ...(task.status === 'needs' ? j!.asks.map((a, i) => ({ id: `ask:${a.item ?? i}`, who: 'oby' as const, ask: a })) : []),
  ] : mine ? chat.said : [];
  // Oby at work on an answer, and what it's on
  const typing = !task && mine && chat.typing, step = !task && mine ? chat.step : undefined;
  // the first message of the run at the end, if it's Oby's: its face is live while Oby still
  // works on that turn
  let head = -1;
  for (let k = thread.length - 1; k >= 0 && thread[k].who === 'oby'; k--) head = k;
  const working = typing && head >= 0;

  // opened, it's seen; it opens at the latest message, and anything new scrolls into view
  useEffect(() => { if (kind === 'task') markSeen(id); }, [id, kind]);
  const first = useRef(true);
  useLayoutEffect(() => {
    const l = list.current;
    if (!l) return;
    l.scrollTo({ top: l.scrollHeight, behavior: first.current ? 'instant' : 'smooth' });
    first.current = false;
  }, [thread.length, typing, step]);

  // a timer, not animationend: animations don't run while the window is hidden
  useEffect(() => {
    if (!leaving) return;
    const t = setTimeout(onGone, LEAVE_MS);
    return () => clearTimeout(t);
  }, [leaving, onGone]);

  useEffect(() => {
    // with a task's page open over it, Esc is the page's
    if (covered) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape' && !typingIn(e)) onBack(); };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, [onBack, covered]);

  const send = (text: string) => {
    if (task) void tellJob(task.id, text);
    else if (waiting) answerQuestion(text);
    else void ask(text);
  };

  return (
    <div className={`chat-layer${leaving ? ' is-leaving' : ''}${covered ? ' is-covered' : ''}`} inert={covered}>
      <div className="chat-scroll">
        <section ref={list} className="chat" aria-label={task ? `Conversation about ${task.title}` : chat.title} onScroll={onScroll}>
          <div className="chat-column">
            {!task && mine && live.older && (
              <button className="chat-older" onClick={() => void loadOlder()}>Earlier messages</button>
            )}
            {!task && !thread.length && !typing && (
              <p className="chat-empty rise" style={{ '--i': 1 } as React.CSSProperties}>Nothing said yet. Tell Oby what to work on below.</p>
            )}
            <ol className="chat-thread rise" style={{ '--i': 1 } as React.CSSProperties}>
              {[...thread.map((m, i) => {
                const prev = thread[i - 1], next = thread[i + 1];
                // A run: the same side, one after another, 4px apart (a long quiet
                // starts a new one). Oby's face by the first of its run; the time
                // under the end of the last, at its right edge (Oby's at its left)
                const near = (a?: number, b?: number) => a == null || b == null || a - b < GAP;
                const cont = !!prev && prev.who === m.who && near(prev.ago, m.ago);
                const last = !next || next.who !== m.who || !near(m.ago, next.ago);
                const side = m.who === 'you' ? 'you' : m.who === 'oby' ? 'oby' : 'source';
                const parts = [
                  // the decision the task needs from you, as on its card
                  'ask' in m ? (
                    <div key="ask" className="msg-ask"><AskBlock task={task!} ask={m.ask} inChat /></div>
                  ) : side !== 'oby' ? (
                    // yours, set as typed
                    m.text ? <p key="text" className="msg-bubble"><Formatted text={m.text} /></p> : null
                  ) : m.text ? (
                    // Oby's as it said it, and its longer answer under it
                    <div key="text" className="msg-bubble"><Said text={m.text} />{m.details && <div className="msg-details"><Said text={m.details} /></div>}</div>
                  ) : null,
                  // what this message started
                  ...('jobs' in m ? m.jobs ?? [] : []).map((jid) => {
                    const t = tasks.find((x) => x.id === jid);
                    return t && <ThreadTask key={jid} task={t} current={kind === 'task' && jid === id} onOpen={onOpenTask} />;
                  }),
                ].filter(Boolean);
                const end = parts.pop();
                const ago = 'ask' in m ? undefined : m.ago;
                return (
                  <li key={m.id} className={`msg is-${side}${cont ? ' is-cont' : ''}${ago != null && ago < 1 ? ' is-new' : ''}`}>
                    {side === 'oby' && !cont && <span className="msg-face"><Face live={working && i === head && !covered} /></span>}
                    {parts}
                    {last && ago != null && !(typing && i === thread.length - 1 && side === 'oby') ? (
                      <div className={`msg-end${end?.type === ThreadTask || 'ask' in m ? ' is-wide' : ''}`}>
                        {end}
                        <time className="msg-time">{clock(ago)}</time>
                      </div>
                    ) : end}
                  </li>
                );
              }),
              // Oby at work: Oby itself, melting into bouncing dots, and under it what it's on now
              // (the turn's steps, from the event stream)
              typing && (
                <li key="working" className={`msg is-oby is-new${working ? ' is-cont' : ''}`}>
                  {!working && <span className="msg-face"><Face live={!covered} /></span>}
                  {step && <p className="msg-step" role="status">{step}</p>}
                </li>
              )]}

              {/* a task's agent at work: its live line, last */}
              {task && j && task.status === 'running' && (
                <li className={`chat-live${j.status === 'queued' ? '' : ' is-working'}`}>
                  <StatusDot task={task} live />
                  <span className="tc-step">{agent} · {j.step}</span>
                  {j.round && <span className="tc-round">Round {j.round[0]} of {j.round[1]}</span>}
                </li>
              )}
            </ol>
          </div>
        </section>
        <div {...thumbProps} />
      </div>

      {/* Oby asking you something back (POST /v1/plans answered with a question): held over
          the message box until you answer, with a pick or in your own words below */}
      {waiting && !live.thinking && (
        <div className="chat-ask" role="group" aria-label="Oby is asking">
          <div className="chat-ask-card">
            <span className="tc-ask-kind">Question</span>
            <p className="tc-ask-head">{waiting.question.text}</p>
            <div className="tc-options">
              {waiting.question.options.map((o, i) => (
                <button key={o} className={`tc-option${i === waiting.question.recommended ? ' is-primary' : ''}`} onClick={() => answerQuestion(o)}>{o}</button>
              ))}
            </div>
            <p className="chat-ask-hint">Or answer in your own words below</p>
          </div>
        </div>
      )}
      {(!task || j?.agent) && (
        <Composer
          style={{ '--i': 2 } as React.CSSProperties}
          placeholder={!task ? (waiting ? 'Answer Oby…' : live.shown ? 'Reply to Oby…' : 'What do you want me to work on?') : task.status === 'done' ? 'Ask its agent for more…' : `Tell ${agent}…`}
          label={task ? `Tell the agent about ${task.title}` : 'Reply to Oby'}
          busy={!task && live.thinking}
          onSend={send}
        />
      )}
    </div>
  );
}

// What Oby said: paragraphs (a blank line between), and lines starting "- " as a list,
// with links, references, paths and `code` set apart as in the message box.
function Said({ text }: { text: string }) {
  return text.split(/\n{2,}/).map((b) => b.trimEnd()).filter(Boolean).map((block, i) => {
    const lines = block.split('\n');
    return lines.every((l) => l.startsWith('- '))
      ? <ul key={i}>{lines.map((l, k) => <li key={k}>{words(l.slice(2))}</li>)}</ul>
      : <p key={i}>{words(block)}</p>;
  });
}
// links, references, paths and `code` set apart as in the message box (Formatted)
const words = (s: string) => tokenize(s).map((r, i) => (r.kind ? <span key={i} className={`tok tok-${r.kind}`}>{r.text}</span> : r.text));

// Oby's face over what it says. live (while it works): the face melts into bouncing dots; once
// its words are in, they run back together into the face
const Face = ({ live = false }: { live?: boolean }) => <ObyFaceLive live={live} />;

// A task started in the conversation, as a small card under Oby's message:
// its title, how it stands and who has it, what it left behind once done, and
// its status mark (as in the side panel). A click opens the task's page; in a
// task's own thread, its own card just shows where it stands.
function ThreadTask({ task, current, onOpen }: { task: Task; current: boolean; onOpen: (id: string) => void }) {
  const j = task.job;
  const body = <>
    <TaskMark task={task} size={16} />
    <span className="msg-task-text">
      <span className="msg-task-title">{task.title}</span>
      <span className="msg-task-meta">
        {task.status === 'running' ? (j.status === 'queued' ? 'Queued' : 'Running') : task.status === 'needs' ? 'Needs you' : j.status === 'done' ? 'Done' : j.status[0].toUpperCase() + j.status.slice(1)}
        {' · '}{metaOf(task)}
      </span>
      {task.status === 'done' && resultLine(task)}
    </span>
    <StatusDot task={task} />
    {!current && <ChevronRight size={14} strokeWidth={1.8} className="msg-task-go" />}
  </>;
  return current
    ? <div className="msg-task">{body}</div>
    : <button className="msg-task is-link" onClick={() => onOpen(task.id)} aria-label={`Open ${task.title}`}>{body}</button>;
}
