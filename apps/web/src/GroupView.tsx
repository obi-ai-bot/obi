import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useScrollThumb } from './useScrollThumb';
import TaskCard from './TaskCard';
import { useLive } from './live';
import { tasksIn, type Tab, type TaskType } from './tasks';

// how long the way out takes (the sink animation in app.css)
const LEAVE_MS = 220;
const TABS: { id: Tab; label: string }[] = [
  { id: 'running', label: 'Running' },
  { id: 'done', label: 'Completed' },
];

// One kind of work: its name, tabs for Running / Completed, and a card per
// task in the open tab; under Completed, a way to the older ones, archived.
// Everything rises in, one after another; on the way out it sinks and fades,
// then onGone lets Home bring Oby back. A card opens its task's own page
// (TaskView) over the list.
export default function GroupView({ group, tab: startTab, leaving, covered = false, onClose, onGone, onOpenTask, onOpenArchive }: {
  group: TaskType;
  tab: Tab;  // the tab it opens on (where a new task is)
  leaving: boolean;
  covered?: boolean;  // a task's page (or its conversation) is open over it
  onClose: () => void;
  onGone: () => void;
  onOpenTask: (id: string) => void;
  onOpenArchive: () => void;
}) {
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLElement>();
  // re-render whenever the tasks change
  const live = useLive();
  const [tab, setTab] = useState<Tab>(startTab);
  // after the first tab, cards come in quicker: no waiting for Oby to fade
  const [switched, setSwitched] = useState(false);
  // the line under the open tab: placed under it, then slid to the next one picked
  // (only once a tab has been picked: on opening it's just there)
  const tabRow = useRef<HTMLDivElement>(null), line = useRef<HTMLSpanElement>(null);
  useLayoutEffect(() => {
    const row = tabRow.current!, el = line.current!;
    const place = () => {
      const on = row.querySelector<HTMLElement>(`[data-tab="${tab}"]`);
      if (!on) return;
      el.style.width = `${on.offsetWidth}px`;
      el.style.transform = `translateX(${on.offsetLeft}px)`;
    };
    place();
    // the row or a tab changing size (the window, a count going up) puts it back under its tab
    const ro = new ResizeObserver(place);
    ro.observe(row);
    row.querySelectorAll('[role="tab"]').forEach((t) => ro.observe(t));
    return () => ro.disconnect();
  }, [tab]);
  // the order the cards had when the tab opened stays put while you're on it, so
  // opening a new one (its blue dot going) doesn't send it down the list;
  // anything added meanwhile goes on top
  const order = useMemo(() => tasksIn(live, group.id, tab).map((t) => t.id), [group.id, tab]);
  const cards = tasksIn(live, group.id, tab).sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
  // back from a task's page: everything rises in again, as the page did
  const wasCovered = useRef(false);
  if (covered) wasCovered.current = true;
  const returning = !covered && wasCovered.current;

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
    <div className={`group-layer${leaving ? ' is-leaving' : ''}${switched ? ' is-switched' : ''}${covered ? ' is-covered' : ''}${returning ? ' is-returning' : ''}`} inert={covered}>
      <section
        ref={list}
        className="group"
        aria-label={group.label}
        onScroll={onScroll}
        // a click anywhere that isn't the title, the tabs, a card or the archive link closes the group
        onClick={(e) => { if (!(e.target as Element).closest('.group-title, .line-tabs, .card, .group-archived')) onClose(); }}
      >
        <div className="group-column">
          <h1 className="group-title rise" style={{ '--i': 0 } as React.CSSProperties}>{group.label}</h1>
          <div ref={tabRow} className="line-tabs rise" role="tablist" aria-label={`${group.label} by status`} style={{ '--i': 1 } as React.CSSProperties}>
            {TABS.map((t) => (
              <button
                key={t.id}
                role="tab"
                aria-selected={tab === t.id}
                data-tab={t.id}
                className={`line-tab${tab === t.id ? ' is-on' : ''}`}
                onClick={() => { if (t.id !== tab) { setTab(t.id); setSwitched(true); } }}
              >
                {t.label}
                <span className="line-tab-count">{tasksIn(live, group.id, t.id).length}</span>
              </button>
            ))}
            <span ref={line} className={`line-tab-line${switched ? ' is-moving' : ''}`} aria-hidden="true" />
          </div>
          {/* keyed by tab, so switching brings the new cards in fresh */}
          <div key={tab} className="group-cards" role="tabpanel">
            {cards.map((c, i) => (
              <TaskCard key={c.id} task={c} onOpen={onOpenTask} style={{ '--i': i + 2 } as React.CSSProperties} />
            ))}
            {!cards.length && <p className="group-empty rise" style={{ '--i': 2 } as React.CSSProperties}>Nothing {tab === 'done' ? 'completed yet' : tab}</p>}
            {/* completed ones leave Home after a while (Archive completed, in Home's ⋮) */}
            {tab === 'done' && (
              <button className="group-archived rise" style={{ '--i': cards.length + 2 } as React.CSSProperties} onClick={onOpenArchive}>
                Older ones are in Archived
              </button>
            )}
          </div>
        </div>
      </section>
      <div {...thumbProps} />
    </div>
  );
}
