import { useEffect, useRef } from 'react';
import Composer, { typingIn } from './Composer';
import { useScrollThumb } from './useScrollThumb';
import TaskCard from './TaskCard';
import { SESSIONS } from './session';
import { markSeen, useTasks, type Task } from './tasks';
import type { Attachments } from './mock';

// how long the way out takes (the sink animation in app.css)
const LEAVE_MS = 220;

// One task on its own page: its card with everything open (stages, result,
// details, session), and at the foot the message box to tell its agent something. Opened from a card in
// its group, or from the side panel; it lies over the group's cards. Esc (or
// the trail in the title bar) returns to them as they were; back, or a click
// off the card, goes straight to Home. A conversation opened from it lies over
// it the same way.
export default function TaskView({ id, leaving, covered = false, onBack, onHome, onGone, onTell, onSession }: {
  id: string;
  leaving: boolean;
  covered?: boolean;  // its conversation is open over it
  onBack: () => void;  // one step, to the cards (Esc)
  onHome: () => void;  // straight to Home, as the title bar's back does (a click off the card)
  onGone: () => void;
  onTell: (id: string, text: string, att: Attachments) => void;  // the message box: on the end of its conversation
  onSession?: (id: string) => void;  // Full session: the job's session, over the page
}) {
  const tasks = useTasks();
  // deleted (from its conversation), it's gone from the tasks while this sinks away
  const kept = useRef<Task>(null);
  const task = tasks.find((t) => t.id === id) ?? kept.current!;
  kept.current = task;
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLElement>();
  // back from its conversation: it rises in again, as the conversation did
  const wasCovered = useRef(false);
  if (covered) wasCovered.current = true;
  const returning = !covered && wasCovered.current;

  // opened, it's seen
  useEffect(() => markSeen(id), [id]);

  // a timer, not animationend: animations don't run while the window is hidden
  useEffect(() => {
    if (!leaving) return;
    const t = setTimeout(onGone, LEAVE_MS);
    return () => clearTimeout(t);
  }, [leaving, onGone]);

  useEffect(() => {
    // with its conversation open over it, Esc is the conversation's
    if (covered) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape' && !typingIn(e)) onBack(); };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, [onBack, covered]);

  return (
    <div className={`chat-layer${leaving ? ' is-leaving' : ''}${covered ? ' is-covered' : ''}${returning ? ' is-returning' : ''}`} inert={covered}>
      <div className="chat-scroll">
        <section
          ref={list}
          className="chat task-scroll"
          aria-label={task.title}
          onScroll={onScroll}
          // a click anywhere off the card goes back to Home, like the title bar's back
          onClick={(e) => { if (!(e.target as Element).closest('.card')) onHome(); }}
        >
          <div className="chat-column">
            <TaskCard task={task} alone onSession={onSession && SESSIONS[task.id] ? () => onSession(task.id) : undefined} style={{ '--i': 0 } as React.CSSProperties} />
          </div>
        </section>
        <div {...thumbProps} />
      </div>
      {/* the same message box as Home's: what you say goes on the end of the task's
          conversation, which opens over the page so you see Oby's answer */}
      <Composer
        className="task-composer"
        autoFocus={false}
        style={{ '--i': 1 } as React.CSSProperties}
        // it goes to Oby, which passes it on to the agent (or starts a follow-up)
        placeholder="Tell Oby about this task…"
        label={`Tell Oby about ${task.title}`}
        onSend={(text, att) => onTell(task.id, text, att)}
      />
    </div>
  );
}
