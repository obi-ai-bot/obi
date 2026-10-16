import { useEffect, useState } from 'react';
import { Search } from 'lucide-react';
import { BrandMark } from './brands';
import { useScrollThumb } from './useScrollThumb';
import { AGENTS, ago } from './mock';
import { TYPES, archivedTasks, useTasks } from './tasks';

// how long the way out takes (the sink animation in app.css)
const LEAVE_MS = 220;
const typeLabel = (id: string) => TYPES.find((t) => t.id === id)?.label ?? 'Chats';

// The archive, as a page of its own (from the side panel's Archived, or a
// group's Completed tab): every done task that has left Home, most recently
// done first, with a search over them at the top. One still in the app opens
// its page; older ones are just listed. Back (the title bar, or Esc) returns.
export default function ArchiveView({ leaving, covered = false, onClose, onGone, onOpenTask }: {
  leaving: boolean;
  covered?: boolean;  // a task's page is open over it
  onClose: () => void;
  onGone: () => void;
  onOpenTask: (id: string) => void;
}) {
  const tasks = useTasks();
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLElement>();
  const [query, setQuery] = useState('');
  const q = query.trim().toLowerCase();
  const all = archivedTasks();
  const shown = all.filter((a) => !q || [a.who ?? '', a.title, typeLabel(a.type), AGENTS[a.agent].name].join(' ').toLowerCase().includes(q));

  // a timer, not animationend: animations don't run while the window is hidden
  useEffect(() => {
    if (!leaving) return;
    const t = setTimeout(onGone, LEAVE_MS);
    return () => clearTimeout(t);
  }, [leaving, onGone]);

  useEffect(() => {
    // with a task's page open over it, Esc is the page's
    if (covered) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, [onClose, covered]);

  return (
    <div className={`group-layer${leaving ? ' is-leaving' : ''}${covered ? ' is-covered' : ''}`} inert={covered}>
      <section ref={list} className="group" aria-label="Archived" onScroll={onScroll}>
        <div className="group-column">
          <h1 className="group-title rise" style={{ '--i': 0 } as React.CSSProperties}>Archived</h1>
          <label className="archive-search rise" style={{ '--i': 1 } as React.CSSProperties}>
            <Search size={16} strokeWidth={1.6} />
            <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search archived tasks" aria-label="Search archived tasks" />
          </label>
          <ul className="archive-list rise" style={{ '--i': 2 } as React.CSSProperties}>
            {shown.map((a) => {
              const inApp = tasks.some((t) => t.id === a.id);
              const body = <>
                <BrandMark brand={AGENTS[a.agent].brand} size={16} mono />
                <span className="archive-text">
                  <span className="archive-title">{a.who && <span className="archive-who">{a.who}</span>}{a.title}</span>
                  <span className="archive-about">{typeLabel(a.type)} · {AGENTS[a.agent].name}</span>
                </span>
                <span className="archive-ago">{ago(a.finished)}</span>
              </>;
              return (
                <li key={a.id}>
                  {inApp
                    ? <button className="archive-row is-link" onClick={() => onOpenTask(a.id)}>{body}</button>
                    : <div className="archive-row">{body}</div>}
                </li>
              );
            })}
          </ul>
          {!shown.length && <p className="group-empty">{all.length ? `Nothing archived matches “${query.trim()}”` : 'Nothing archived yet'}</p>}
        </div>
      </section>
      <div {...thumbProps} />
    </div>
  );
}
