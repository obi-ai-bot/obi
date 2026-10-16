import { useEffect, useRef } from 'react';
import { AvatarStack, OwnerAvatar } from './ObyFace';
import { clock } from './ChatView';
import Composer, { typingIn } from './Composer';
import StatusDot from './StatusDot';
import { useScrollThumb } from './useScrollThumb';
import { convosWith, start, useConvos, type Convo } from './peers';
import { useTasks } from './tasks';

// how long the way out takes (the sink animation in app.css)
const LEAVE_MS = 220;

// Someone else's Oby, opened from the Obysphere: whose it is and how many of
// your tasks it has assisted with, then every conversation you've had with it (each about a task), the
// latest first; a group (other Obys joined in) shows them all. The message box
// at the foot starts a new one; with none yet, the middle says so. A
// conversation opens over this page.
export default function ObyView({ name, leaving, covered = false, onClose, onGone, onOpenConvo }: {
  name: string;
  leaving: boolean;
  covered?: boolean;  // a conversation is open over it
  onClose: () => void;
  onGone: () => void;
  onOpenConvo: (id: string) => void;
}) {
  const convos = convosWith(useConvos(), name);
  // your tasks it has had a say in: those its conversations with you are about
  const helped = new Set(convos.flatMap((c) => c.messages.map((m) => m.task).filter(Boolean))).size;
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLElement>();
  // back from a conversation: it rises in again, as the conversation did
  const wasCovered = useRef(false);
  if (covered) wasCovered.current = true;
  const returning = !covered && wasCovered.current;

  useEffect(() => {
    if (!leaving) return;
    const t = setTimeout(onGone, LEAVE_MS);
    return () => clearTimeout(t);
  }, [leaving, onGone]);

  useEffect(() => {
    // with a conversation open over it, Esc is the conversation's
    if (covered) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape' && !typingIn(e)) onClose(); };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, [onClose, covered]);

  return (
    <div className={`chat-layer oby-layer${leaving ? ' is-leaving' : ''}${covered ? ' is-covered' : ''}${returning ? ' is-returning' : ''}`} inert={covered}>
      <div className="chat-scroll">
        <section ref={list} className="chat" aria-label={`${name}’s Oby`} onScroll={onScroll}>
          <div className="chat-column">
            <header className="oby-head rise" style={{ '--i': 0 } as React.CSSProperties}>
              <OwnerAvatar name={name} size={48} />
              <div>
                <h1 className="oby-name">{name}’s Oby</h1>
                {/* how many of your tasks it has had a say in */}
                <p className="oby-doing">{helped ? `Assisted with ${helped} task${helped === 1 ? '' : 's'}` : 'Hasn’t assisted with a task yet'}</p>
              </div>
            </header>
            {convos.length > 0 ? (
              <ol className="peer-convos">
                {convos.map((c, i) => <ConvoRow key={c.id} convo={c} with_={name} onOpen={onOpenConvo} style={{ '--i': i + 1 } as React.CSSProperties} />)}
              </ol>
            ) : (
              // none yet: a word in the middle, pointing to the message box under it
              <div className="oby-empty rise" style={{ '--i': 1 } as React.CSSProperties}>
                <p className="oby-empty-title">No conversations yet</p>
                <p className="oby-empty-line">Start your first one with {name}’s Oby below.</p>
              </div>
            )}
          </div>
        </section>
        <div {...thumbProps} />
      </div>
      {/* not focused on opening: this is a list to look over, as a task's page is */}
      <Composer
        autoFocus={false}
        style={{ '--i': 2 } as React.CSSProperties}
        placeholder={`Message ${name}’s Oby`}
        label={`Message ${name}’s Oby`}
        onSend={(text, att) => { const id = start(name, text, att); if (id) onOpenConvo(id); }}
      />
    </div>
  );
}

// One conversation: who's in it (the Oby you opened, then any others that
// joined, their owners' pictures side by side), its name, the last thing said,
// when, and how its task stands.
function ConvoRow({ convo: c, with_, onOpen, style }: { convo: Convo; with_: string; onOpen: (id: string) => void; style?: React.CSSProperties }) {
  const tasks = useTasks();
  const lastMsg = c.messages.at(-1)!;
  const others = c.with.filter((n) => n !== with_);
  const from = lastMsg.who === 'you' ? 'You' : lastMsg.who === 'oby' ? 'Your Oby' : `${lastMsg.who}’s Oby`;
  // the task it's about: the last one mentioned
  const tid = [...c.messages].reverse().find((m) => m.task)?.task;
  const task = tid ? tasks.find((t) => t.id === tid) : undefined;
  return (
    <li className="rise" style={style}>
      <button className={`peer-convo${c.unread ? ' is-new' : ''}`} onClick={() => onOpen(c.id)}>
        {/* new since you last looked: a blue dot in the margin, as on new tasks */}
        {c.unread && <span className="peer-convo-dot" role="img" aria-label="New" />}
        <span className="peer-convo-text">
          {/* who's in it, at the top: the Oby you opened first */}
          <AvatarStack names={[with_, ...others]} />
          <span className="peer-convo-title">{c.title}</span>
          <span className="peer-convo-last">{from}: {lastMsg.text}</span>
        </span>
        <span className="peer-convo-side">
          <time className="msg-time">{clock(lastMsg.ago)}</time>
          {/* how its task stands */}
          {task && <StatusDot task={task} live />}
        </span>
      </button>
    </li>
  );
}
