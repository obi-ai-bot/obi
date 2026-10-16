import { useEffect, useState } from 'react';
import { Search } from 'lucide-react';
import { BrandMark } from './brands';
import { ObyIcon } from './ObyFace';
import { useScrollThumb } from './useScrollThumb';
import { useLive } from './live';
import { AGENTS, ago, archivedTasks, typeLabel } from './tasks';

// how long the way out takes (the sink animation in app.css)
const LEAVE_MS = 220;

// The archive, as a page of its own (from the side panel's Archived, or a
// group's Completed tab): every done task that has left Home, most recently
// done first, with a search over them at the top. Each opens its page. Back
// (the title bar, or Esc) returns.
export default function ArchiveView({ leaving, covered = false, onClose, onGone, onOpenTask }: {
  leaving: boolean;
  covered?: boolean;  // a task's page is open over it
  onClose: () => void;
  onGone: () => void;
  onOpenTask: (id: string) => void;
}) {
  const live = useLive();
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLElement>();
  const [query, setQuery] = useState('');
  const q = query.trim().toLowerCase();
  const all = archivedTasks(live);
  const name = (a: (typeof all)[number]) => (a.agent ? AGENTS[a.agent].name : 'Oby');
  const shown = all.filter((a) => !q || [a.title, typeLabel(a.type), name(a)].join(' ').toLowerCase().includes(q));

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
              return (
                <li key={a.id}>
                  <button className="archive-row is-link" onClick={() => onOpenTask(a.id)}>
                    {a.agent ? <BrandMark brand={AGENTS[a.agent].brand} size={16} mono /> : <ObyIcon size={16} />}
                    <span className="archive-text">
                      <span className="archive-title">{a.title}</span>
                      <span className="archive-about">{typeLabel(a.type)} · {name(a)}</span>
                    </span>
                    <span className="archive-ago">{ago(a.finished)}</span>
                  </button>
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
