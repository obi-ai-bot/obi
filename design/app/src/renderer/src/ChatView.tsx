import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Check, ChevronRight, File as FileIcon } from 'lucide-react';
import { BrandMark } from './brands';
import { ObyFace, PeerByline } from './ObyFace';
import ObyFaceLive from './ObyFaceLive';
import { markRead, say, useConvos } from './peers';
import StatusDot from './StatusDot';
import { AskBlock, resultLine } from './TaskCard';
import { useScrollThumb } from './useScrollThumb';
import Composer, { typingIn } from './Composer';
import Formatted from './Formatted';
import { tokenize } from './textTokens';
import { AGENTS, convoTitle, threadOf, type Message } from './mock';
import { markSeen, tell, useTasks, type Task } from './tasks';
import { obys, tellChat, useChats, type Chat } from './chats';

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
type Entry = Message | { who: 'oby'; ask: true; ago: number };

// A conversation. kind 'oby': one with Oby (chats.ts), opened from
// Conversations or started on Home: what you asked, Oby's answers with the
// tasks they started as cards under them; the message box carries it on. kind
// 'task': a task's own thread, for a task that came in from elsewhere (GitHub,
// Slack…): the message it came in on, Oby's replies, what you've told the agent
// since, and the agent's live line while it works; the message box tells the
// agent. kind 'peer': one with someone else's Oby (or a few) in the Obysphere
// (peers.ts): each Oby's words under its owner's picture and name. Whatever is
// happening now comes last: an Oby at work, or the agent's line. It lies over
// what was open; back (in the title bar, or Esc) returns to it.
export default function ChatView({ id, kind = 'task', leaving, covered = false, onBack, onGone, onOpenTask }: {
  id: string;
  kind?: 'task' | 'oby' | 'peer';
  leaving: boolean;
  covered?: boolean;  // a task's page (from one of its cards) is open over it
  onBack: () => void;
  onGone: () => void;
  onOpenTask: (id: string) => void;       // a card in the thread: that task's page
}) {
  const tasks = useTasks();
  const chats = useChats();
  const convos = useConvos();
  // deleted, it's gone while this sinks away: keep showing the last of it
  const keptTask = useRef<Task>(null), keptChat = useRef<Chat>(null);
  const task = kind === 'task' ? tasks.find((t) => t.id === id) ?? keptTask.current! : null;
  const talk = kind === 'oby' ? chats.find((c) => c.id === id) ?? keptChat.current! : null;
  const convo = kind === 'peer' ? convos.find((c) => c.id === id)! : null;
  if (task) keptTask.current = task;
  if (talk) keptChat.current = talk;
  const name = task ? convoTitle(task.job) : talk ? talk.title : convo!.title;
  const j = task?.job;
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLElement>();
  const agent = j ? AGENTS[j.agent].name : 'Oby';
  // a task's: what came before, the decision (if any) where things stand, then
  // what's been said since (the decision has been waiting since Oby's last
  // word, so no time of its own)
  const before = j ? threadOf(j) : [];
  const thread: Entry[] = task ? [
    ...before,
    ...(task.status === 'needs' && j!.ask ? [{ who: 'oby' as const, ask: true as const, ago: before.at(-1)!.ago }] : []),
    ...(task.said ?? []),
  ] : talk ? talk.said : convo!.messages.map((m): Message => (m.who === 'you'
    ? { who: 'you', text: m.text, ago: m.ago, jobs: [...(m.task ? [m.task] : []), ...(m.jobs ?? [])], files: m.files, obys: m.obys }
    // your Oby (answering another Oby for you) as in your own conversations; another
    // person's Oby from the same side, under its owner's name (by). Only you, the
    // person, get a bubble
    : { who: 'oby', by: m.who === 'oby' ? undefined : m.who, text: m.text, ago: m.ago, jobs: m.task ? [m.task] : undefined, streaming: m.streaming }));
  // an Oby at work on an answer, and what it's on (someone else's: writing)
  const typing = !!(task ?? talk ?? convo)!.typing, step = talk ? talk.step : convo?.typing ? 'Writing' : undefined;
  // who's writing, in a conversation with other people's Obys: the first in it
  const writer = convo?.with[0];
  // Whose run a message is in: another Oby answering what Oby asked is part of
  // Oby's turn (quoted in it), not a turn of its own; with other people's Obys,
  // each Oby's words are a run of their own
  const runOf = (e: Entry) => (e.who === 'peer' ? 'oby' : e.who === 'oby' && (e as Message).by ? `oby:${(e as Message).by}` : e.who);
  // the first message of the run at the end, if it's Oby's: its face is live
  // while Oby still works on that turn
  let head = -1;
  for (let k = thread.length - 1; k >= 0 && runOf(thread[k]) === 'oby'; k--) head = k;
  const working = typing && head >= 0 && !convo;

  // opened, it's seen; it opens at the latest message, and anything new scrolls into view
  useEffect(() => { if (kind === 'task') markSeen(id); if (kind === 'peer') markRead(id); }, [id, kind]);
  const first = useRef(true);
  useLayoutEffect(() => {
    const l = list.current;
    if (!l) return;
    l.scrollTo({ top: l.scrollHeight, behavior: first.current ? 'instant' : 'smooth' });
    first.current = false;
  }, [thread.length, typing, step, (thread.at(-1) as Message | undefined)?.text?.length]);  // (the last, as its words come in)

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

  return (
    <div className={`chat-layer${leaving ? ' is-leaving' : ''}${covered ? ' is-covered' : ''}`} inert={covered}>
      <div className="chat-scroll">
        <section ref={list} className="chat" aria-label={task ? `Conversation about ${task.title}` : name} onScroll={onScroll}>
          <div className="chat-column">
            <ol className="chat-thread rise" style={{ '--i': 1 } as React.CSSProperties}>
              {[...thread.map((m, i) => {
                const prev = thread[i - 1], next = thread[i + 1];
                // A run: the same side, one after another, 4px apart (a long quiet
                // starts a new one). Oby's face by the first of its run; the time
                // under the end of the last, at its right edge (Oby's at its left)
                const cont = !!prev && runOf(prev) === runOf(m) && prev.ago - m.ago < GAP;
                const last = !next || runOf(next) !== runOf(m) || m.ago - next.ago >= GAP;
                // with other people's Obys, yours speaks for you: on your side (the
                // right), still as an Oby (its face, no bubble)
                const mine = !!convo && m.who === 'oby' && !(m as Message).by;
                const side = m.who === 'you' ? 'you' : m.who === 'oby' || m.who === 'peer' ? 'oby' : 'source';
                const parts = [
                  // what Oby did on the way, folded
                  ...('steps' in m && m.steps?.length ? [<Steps key="steps" steps={m.steps} looked={m.looked ?? m.steps.length} asked={m.asked} />] : []),
                  // what went with yours: photos and files (Obys are @mentions in the words; tasks: cards, below)
                  ...('files' in m && m.files?.length ? [<Attached key="att" files={m.files} />] : []),
                  // the decision the task needs from you, as on its card
                  'ask' in m ? (
                    <div key="ask" className="msg-ask"><AskBlock task={task!} inChat /></div>
                  ) : m.who === 'peer' ? (
                    // another Oby's answer to what Oby asked: quoted in Oby's turn,
                    // under its owner's picture and name
                    <blockquote key="text" className="msg-quote"><PeerByline name={(m as Message).by!} /><Said text={m.text} /></blockquote>
                  ) : side !== 'oby' ? (
                    // yours (and the ask it came in on), set as typed (none: only attachments)
                    m.text ? <p key="text" className="msg-bubble"><Formatted text={m.text} /></p> : null
                  ) : m.text ? (
                    // Oby's as it said it (its steps alone, folded where another
                    // Oby's answer came in, have no words)
                    <div key="text" className="msg-bubble"><Said text={m.text} /></div>
                  ) : null,
                  // what this message started
                  ...('jobs' in m ? m.jobs ?? [] : []).map((jid) => {
                    const t = tasks.find((x) => x.id === jid);
                    return t && <ThreadTask key={jid} task={t} current={kind === 'task' && jid === id} onOpen={onOpenTask} />;
                  }),
                ].filter(Boolean);
                const end = parts.pop();
                return (
                  <li key={i} className={`msg is-${side}${mine ? ' is-mine' : ''}${cont ? ' is-cont' : ''}${m.ago === 0 ? ' is-new' : ''}${(m as Message).streaming ? ' is-streaming' : ''}`}>
                    {side === 'oby' && !cont && ((m as Message).by && m.who === 'oby'
                      ? <PeerByline name={(m as Message).by!} />
                      // yours among other people's Obys: named, as theirs are
                      : mine ? <span className="peer-by"><ObyFace size={22} /><span>Your Oby</span></span>
                      : <span className="msg-face"><Face live={working && i === head && !covered} /></span>)}
                    {parts}
                    {last && !(m as Message).streaming && !(typing && i === thread.length - 1 && side === 'oby') ? (
                      <div className={`msg-end${end?.type === ThreadTask || 'ask' in m ? ' is-wide' : ''}`}>
                        {end}
                        <time className="msg-time">{clock(m.ago)}</time>
                      </div>
                    ) : end}
                  </li>
                );
              }),
              // Oby at work: Oby itself, melting into bouncing dots, and under it
              // what it's on now. Keyed as its words will be, so when they land it's
              // the same row and the same live Oby, which then comes back together
              // (carrying on a turn already under way, its face is up there already).
              // Someone else's Oby: its name, unless its words are just above
              typing && (step || !working) && (() => {
                const cont = writer ? runOf(thread.at(-1) ?? { who: 'you', text: '', ago: 0 }) === `oby:${writer}` : working;
                return (
                  <li key={thread.length} className={`msg is-oby is-new${cont ? ' is-cont' : ''}`}>
                    {!cont && (writer ? <PeerByline name={writer} /> : <span className="msg-face"><Face live={!covered} /></span>)}
                    {step && <p className="msg-step" role="status">{step}</p>}
                  </li>
                );
              })()]}

              {/* a task's agent at work: its live line, last */}
              {task && j && task.status === 'running' && !typing && (
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

      {/* Oby waiting on you (a question back, not a task's): held over the message
          box until you answer, with a pick or in your own words below */}
      {talk?.waiting && (
        <div className="chat-ask" role="group" aria-label="Oby is asking">
          <div className="chat-ask-card">
            <span className="tc-ask-kind">Question</span>
            <p className="tc-ask-head">{talk.waiting.question}</p>
            <div className="tc-options">
              {talk.waiting.options.map((o) => (
                <button key={o} className="tc-option" onClick={() => tellChat(talk.id, o)}>{o}</button>
              ))}
            </div>
            <p className="chat-ask-hint">Or answer in your own words below</p>
          </div>
        </div>
      )}
      <Composer
        style={{ '--i': 2 } as React.CSSProperties}
        placeholder={convo ? `Message ${convo.with.length > 1 ? 'the group' : `${writer}’s Oby`}…` : !task ? 'Reply to Oby…' : task.status === 'done' ? 'Ask for a follow-up…' : `Tell ${agent}…`}
        label={convo ? `Message ${convo.title}` : task ? `Tell the agent about ${task.title}` : 'Reply to Oby'}
        onSend={(text, att) => (task ? tell(task.id, text, att) : talk ? tellChat(talk.id, text, att) : say(convo!.id, text, att))}
      />
    </div>
  );
}

// The steps Oby took, as one line over its words ("Looked at 2 things, asked
// Wellington's Oby"); a click opens the list of them, each with a check
function Steps({ steps, looked, asked = [] }: { steps: string[]; looked: number; asked?: string[] }) {
  const [open, setOpen] = useState(false);
  const label = [
    looked > 0 && `Looked at ${looked} thing${looked === 1 ? '' : 's'}`,
    asked.length > 0 && `asked ${obys(asked)}`,
  ].filter(Boolean).join(', ');
  return (
    <div className={`msg-steps${open ? ' is-open' : ''}`}>
      <button type="button" className="msg-steps-head" aria-expanded={open} onClick={() => setOpen(!open)}>
        {label[0].toUpperCase() + label.slice(1)}
        <ChevronRight size={14} strokeWidth={1.8} />
      </button>
      {open && (
        <ul>
          {steps.map((st, i) => <li key={i}><Check size={12} strokeWidth={2} />{st}</li>)}
        </ul>
      )}
    </div>
  );
}

// What went with a message of yours: photos as pictures, files as small tags,
// on your side over your words (Obys brought in are named in the words: @Wellington)
function Attached({ files = [] }: { files?: { name: string; preview?: string }[] }) {
  return (
    <div className="msg-attached">
      {files.map((f, i) => (f.preview
        ? <img key={i} className="msg-photo" src={f.preview} alt={f.name} />
        : <span key={i} className="msg-file"><FileIcon size={14} strokeWidth={1.8} /><span>{f.name}</span></span>))}
    </div>
  );
}

// What Oby said: paragraphs (a blank line between), and lines starting "- " as a list,
// with links, references, paths and `code` set apart as in the message box.
// Each word its own span, so a word coming in can fade in (see .is-streaming)
function Said({ text }: { text: string }) {
  return text.split(/\n{2,}/).map((b) => b.trimEnd()).filter(Boolean).map((block, i) => {
    const lines = block.split('\n');
    return lines.every((l) => l.startsWith('- '))
      ? <ul key={i}>{lines.map((l, k) => <li key={k}>{words(l.slice(2))}</li>)}</ul>
      : <p key={i}>{words(block)}</p>;
  });
}
// links, references, paths and `code` set apart as in the message box (Formatted)
const words = (s: string) => tokenize(s).map((r, i) => (r.kind ? <span key={i} className={`tok tok-${r.kind}`}>{split(r.text)}</span> : split(r.text, i)));
const split = (s: string, at = 0) => s.split(/(\s+)/).map((w, k) => (!w || /\s/.test(w) ? w : <span key={`${at}.${k}`} className="w">{w}</span>));

// Oby's face over what it says. live (while it writes): the face melts into
// bouncing dots; once its words are in, they run back together into the face
// live: at work, and in sight (under a page opened over it, it rests: the power budget)
const Face = ({ live = false }: { live?: boolean }) => <ObyFaceLive live={live} />;

// A task started in the conversation, as a small card under Oby's message:
// its title, how it stands and who has it, what it left behind once done, and
// its status mark (as in the side panel). A click opens the task's page; in a
// task's own thread, its own card just shows where it stands.
function ThreadTask({ task, current, onOpen }: { task: Task; current: boolean; onOpen: (id: string) => void }) {
  const j = task.job;
  const repo = j.repo.includes('/') ? j.repo.split('/')[1] : null;
  const body = <>
    <BrandMark brand={AGENTS[j.agent].brand} size={16} mono />
    <span className="msg-task-text">
      <span className="msg-task-title">
        {task.who && <span className="tc-who">{task.who}</span>}
        {task.title}
      </span>
      <span className="msg-task-meta">
        {task.status === 'running' ? (j.status === 'queued' ? 'Queued' : 'Running') : task.status === 'needs' ? 'Needs you' : 'Done'}
        {' · '}{AGENTS[j.agent].name} · {j.account}{j.on && <> · on {j.on}</>}{repo && <> · {repo}</>}
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
