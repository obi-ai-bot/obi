import { Fragment, useEffect, useState, useSyncExternalStore } from 'react';
import { BookOpen, Check, ChevronDown, EllipsisVertical, Plus, type LucideIcon } from 'lucide-react';
// the icon strip uses Phosphor: it has outline and filled versions of each icon
import { ChatsCircleIcon, HouseIcon, UsersThreeIcon } from '@phosphor-icons/react';
import { ARCHIVE_AFTER, archivedTasks, countOf, getArchiveAfter, onArchiveAfter, openOf, setArchiveAfter, tasksOf, tasksWith, typesOn, useTasks, ago, type Task } from './tasks';
import { markSeen, useLive } from './live';
import { useChat } from './chats';
import { usePreview } from './preview';
import { OwnerAvatar } from './ObyFace';
import { useScrollThumb } from './useScrollThumb';
import { Menu } from './Menu';
import { SignOut, settingsPages } from './SettingsView';
import TaskMenu from './TaskMenu';
import StatusDot from './StatusDot';
import { TaskMark } from './TaskCard';

type Section = 'home' | 'conversations' | 'obysphere' | 'settings';
type StripIcon = (p: { size?: number; weight?: 'regular' | 'fill' }) => React.ReactNode;
// each section's name over it
const TITLES: Record<Section, string> = {
  home: 'Home', conversations: 'Conversations', obysphere: 'Obysphere', settings: 'Settings',
};
// What each tab can start, first thing under its title
const NEW_ACTION: Partial<Record<Section, { label: string; icon: LucideIcon }>> = {
  home: { label: 'New task', icon: Plus },
};

// The side panel, in two columns: icons on the far left pick a section (Home; with "Show screens
// still being built", Conversations and the Obysphere; Settings from the account picture at the
// foot), the column beside them shows it. It opens from the left and pushes the view over.
export default function Sidebar({ open, onNewChat, onHome, onOpenTask, onOpenChat, onOpenTalk, onOpenArchive, onOpenSetting, onOpenKnowledge, activeTalk = false, activeSetting = null, activeKnowledge = false, active = null, width, onResize }: {
  open: boolean;
  onNewChat: () => void;
  onHome: () => void;  // back to Home's own page, closing whatever is open over it
  onOpenTask: (id: string) => void;  // a task's page, on its own
  onOpenChat: (id: string) => void;  // a task's conversation, from its menu
  onOpenTalk: () => void;  // the conversation with Oby
  onOpenArchive: () => void;  // the archived tasks, as a page
  activeTalk?: boolean;  // the conversation with Oby is showing: its row is highlighted
  activeSetting?: string | null;  // the Settings page that's showing: its row is highlighted
  onOpenKnowledge: () => void;  // the Obysphere's knowledge
  activeKnowledge?: boolean;
  onOpenSetting: (id: string) => void;  // a Settings page, from the account menu or the Settings list
  active?: string | null;  // the task whose card is showing on its own: its row is highlighted
  width: number;
  onResize: (width: number | null, done?: boolean) => void;  // null: back to the default
}) {
  // drag the panel's right edge to change its width
  const startResize = (e: React.PointerEvent<HTMLDivElement>) => {
    const t = e.currentTarget, x0 = e.clientX, w0 = width;
    let x = x0;
    t.setPointerCapture(e.pointerId);
    const move = (m: PointerEvent) => { x = m.clientX; onResize(w0 + x - x0); };
    // a cancelled drag (the system took the pointer) ends like a release where
    // it last was, so the panel doesn't stay stuck mid-resize
    const up = () => {
      onResize(w0 + x - x0, true);
      t.removeEventListener('pointermove', move);
      t.removeEventListener('pointerup', up);
      t.removeEventListener('pointercancel', up);
    };
    t.addEventListener('pointermove', move);
    t.addEventListener('pointerup', up);
    t.addEventListener('pointercancel', up);
  };
  const store = useLive();
  const tasks = useTasks();
  const chat = useChat();
  const preview = usePreview();
  const archiveAfter = useSyncExternalStore(onArchiveAfter, getArchiveAfter);
  // Home's dot turns orange while any task needs you, blue while one is new
  const needsYou = countOf(store, 'needs') > 0;
  const fresh = tasks.some((t) => t.fresh);
  const [section, setSection] = useState<Section>('home');
  const sections: { id: Section; label: string; icon: StripIcon }[] = [
    { id: 'home', label: 'Home', icon: HouseIcon },
    ...(preview ? [{ id: 'conversations' as const, label: 'Conversations', icon: ChatsCircleIcon }] : []),
  ];
  // the setting turned off while one of its sections shows: back to Home
  useEffect(() => { if (!preview) setSection((s) => (s === 'conversations' || s === 'obysphere' ? 'home' : s)); }, [preview]);
  const inSettings = section === 'settings';
  // a Settings page opened from elsewhere (the message box's usage gear): the panel follows
  useEffect(() => { if (activeSetting) setSection('settings'); }, [activeSetting]);
  // groups the user folded away
  const [folded, setFolded] = useState<Set<string>>(new Set());
  // groups showing all their done tasks (Show more), not just the latest few
  const [more, setMore] = useState<Set<string>>(new Set());
  // a Home task's menu: from its ⋮ (under it), or a right-click (where the pointer is)
  const [taskMenu, setTaskMenu] = useState<{ id: string; at: DOMRect; atPointer?: boolean } | null>(null);
  const menuTask = taskMenu ? tasks.find((t) => t.id === taskMenu.id) : undefined;
  // Home's ⋮: how its tasks are grouped, and when done ones get archived
  const [archiveMenu, setArchiveMenu] = useState<DOMRect | null>(null);
  // the account menu (the picture at the icons' foot): which obid, Settings, signing out
  const [accountMenu, setAccountMenu] = useState<DOMRect | null>(null);
  // Home's groups: by kind of work (the default) or by status; remembered
  const [groupBy, setGroupBy] = useState<'type' | 'status'>(() => {
    try { return localStorage.getItem('oby.groupBy') === 'status' ? 'status' : 'type'; } catch { return 'type'; }
  });
  const pickGroupBy = (by: 'type' | 'status') => {
    setGroupBy(by); setArchiveMenu(null);
    try { localStorage.setItem('oby.groupBy', by); } catch { /* not remembered, that's all */ }
  };
  // each group: its tasks, how many to show by its name (open ones for a kind
  // of work, all of them for a status), and how many need you
  const groups = groupBy === 'type'
    ? typesOn(store).map((t) => ({ id: t.id, label: t.label, tasks: tasksOf(store, t.id), count: openOf(store, t.id), countLabel: 'open', needs: countOf(store, 'needs', t.id) }))
    : ([['needs', 'Needs you'], ['running', 'Running'], ['done', 'Completed']] as const).map(([id, label]) => {
      const list = tasksWith(store, id);
      return { id: `status:${id}`, label, tasks: list, count: list.length, countLabel: 'tasks', needs: id === 'needs' ? list.length : 0 };
    }).filter((g) => g.tasks.length > 0);
  const pickArchive = (id: string) => { setArchiveAfter(id); setArchiveMenu(null); };
  // A group's done tasks: the latest few (3 in a kind of work, 5 in Done), then
  // Show more for the rest; what's still open always shows in full. Done tasks
  // leave Home for the archive after a while (Archive completed, in Home's ⋮)
  const shownOf = (g: { id: string; tasks: Task[] }) => {
    const open = g.tasks.filter((t) => t.status !== 'done'), done = g.tasks.filter((t) => t.status === 'done');
    const keep = g.id === 'status:done' ? 5 : 3;
    return { rows: more.has(g.id) ? g.tasks : [...open, ...done.slice(0, keep)], hidden: Math.max(0, done.length - keep) };
  };
  const toggleMore = (id: string) => setMore((m) => { const next = new Set(m); if (!next.delete(id)) next.add(id); return next; });
  const archivedCount = archivedTasks(store).length;
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLDivElement>();
  const pick = (id: Section) => {
    // Home again, while it's showing: back to Home's own page (the dashboard)
    if (id === 'home' && section === 'home') onHome();
    setSection(id);
    if (list.current) list.current.scrollTop = 0;
  };
  const newAction = NEW_ACTION[section];
  const host = store.status?.runner.host ?? 'obid';

  const toggleGroup = (name: string) => setFolded((f) => {
    const next = new Set(f);
    if (!next.delete(name)) next.add(name);
    return next;
  });

  // the conversation with Oby, as a row: its name, Oby's last words, when it last moved
  const lastOby = [...chat.said].reverse().find((m) => m.who === 'oby' && m.text);
  const lastAgo = chat.said.at(-1)?.ago;
  const convoRow = (
    <button
      className={`connector task convo-row${activeTalk ? ' is-active' : ''}`}
      aria-current={activeTalk || undefined}
      onClick={onOpenTalk}
    >
      <span className="connector-text">
        <span className="connector-name">{chat.title}</span>
        <span className="connector-about">{chat.typing ? chat.step : lastOby?.text ?? 'Nothing said yet'}</span>
      </span>
      {(chat.typing || lastAgo != null) && <span className="sidebar-item-ago">{chat.typing ? 'now' : ago(lastAgo!)}</span>}
    </button>
  );

  return (
    <>
    <div className="sidebar-slot" inert={!open}>
      <nav className="sidebar" aria-label="Side panel">
        <div className="rail">
          {sections.map(({ id, label, icon: Icon }) => (
            <Fragment key={id}>
              <button className={`rail-button${section === id ? ' is-on' : ''}${id === 'home' && (needsYou || fresh) ? ' has-dot' : ''}${id === 'home' && needsYou ? ' is-needs' : ''}`} data-tip={label} aria-label={label} aria-pressed={section === id} onClick={() => pick(id)}>
                <Icon size={20} weight={section === id ? 'fill' : 'regular'} />
              </button>
            </Fragment>
          ))}
          {/* your own places above the line; the Obysphere below (#497) */}
          {preview && <>
            <span className="rail-sep" role="separator" />
            <button className={`rail-button${section === 'obysphere' ? ' is-on' : ''}`} data-tip="Obysphere" aria-label="Obysphere" aria-pressed={section === 'obysphere'} onClick={() => pick('obysphere')}>
              <UsersThreeIcon size={20} weight={section === 'obysphere' ? 'fill' : 'regular'} />
            </button>
          </>}
          {/* at the foot: the account menu (Settings is in it) */}
          <button
            className={`rail-button rail-account${inSettings || accountMenu ? ' is-on' : ''}`}
            data-tip={accountMenu ? undefined : 'Account'}
            aria-label="Account"
            aria-haspopup="menu"
            aria-expanded={!!accountMenu}
            onClick={(e) => setAccountMenu(accountMenu ? null : e.currentTarget.getBoundingClientRect())}
          >
            <OwnerAvatar name={host} size={24} badge={false} />
          </button>
        </div>

        <div className="sidebar-content">
        <div className="sidebar-title-row">
          <h2 className="sidebar-title">{TITLES[section]}</h2>
          {section === 'home' && (
            <button
              className={`icon-button${archiveMenu ? ' is-on' : ''}`}
              aria-label="Home options"
              aria-haspopup="menu"
              aria-expanded={!!archiveMenu}
              onClick={(e) => setArchiveMenu(archiveMenu ? null : e.currentTarget.getBoundingClientRect())}
            >
              <EllipsisVertical size={16} strokeWidth={1.6} />
            </button>
          )}
        </div>
        <div className="sidebar-top" />
        {/* everything under the title scrolls together; the title stays */}
        <div className="sidebar-scroll">
        <div ref={list} className="sidebar-list" onScroll={onScroll}>

        {/* the Obysphere: what its Obys share, and its members. Nothing yet (#497, #495) */}
        {section === 'obysphere' && (
          <>
            <button className={`sidebar-new is-stacked${activeKnowledge ? ' is-active' : ''}`} aria-current={activeKnowledge || undefined} onClick={onOpenKnowledge}>
              <BookOpen size={16} strokeWidth={1.6} />
              <span className="sidebar-new-label">Knowledge</span>
            </button>
            <div className="sidebar-plain">
              <p className="sidebar-empty">Your Oby works on its own for now. Obyspheres, where it works with other people’s, come with #497.</p>
            </div>
          </>
        )}
        {newAction && (
          <button className="sidebar-new" onClick={onNewChat}>
            <newAction.icon size={16} strokeWidth={1.6} />
            <span className="sidebar-new-label">{newAction.label}</span>
          </button>
        )}

        {/* the conversation with Oby: one for now; many come with #493 */}
        {section === 'conversations' && (
          <div className="sidebar-plain">
            {convoRow}
            <p className="sidebar-empty">One conversation for now: many, sharing one memory, come with #493.</p>
          </div>
        )}
        {/* Home: the conversation, then each kind of work folds open to its tasks
            (running / needs you counted on the right) */}
        {section === 'home' && (
          <div className="sidebar-plain">
            {convoRow}
            {groups.map((t) => (
              <section key={t.id} className={`sidebar-group${folded.has(t.id) ? ' is-folded' : ''}`}>
                <button className="sidebar-group-head" aria-expanded={!folded.has(t.id)} onClick={() => toggleGroup(t.id)}>
                  <h3>{t.label}</h3>
                  <ChevronDown size={12} strokeWidth={1.8} className="sidebar-chevron" />
                  {/* folded, the orange dot still says something in it needs you */}
                  {t.needs > 0 && <span className="sidebar-group-needs" aria-label={`${t.needs} need${t.needs === 1 ? 's' : ''} you`} />}
                  {/* nothing open in it: no count (a 0 says nothing) */}
                  {t.count > 0 && <span className="sidebar-group-count" aria-label={`${t.count} ${t.countLabel}`}>{t.count}</span>}
                </button>
                <div className="sidebar-group-body">
                  <div>
                    {shownOf(t).rows.map((k) => (
                      // a row with its own menu button, so the row itself isn't a <button>
                      <div
                        key={k.id}
                        role="button"
                        tabIndex={0}
                        className={`task-row${k.status === 'done' ? ' is-done' : ''}${active === k.id ? ' is-active' : ''}${taskMenu?.id === k.id ? ' is-menu-open' : ''}`}
                        aria-current={active === k.id || undefined}
                        onClick={() => { markSeen(k.id); onOpenTask(k.id); }}
                        onKeyDown={(e) => { if ((e.key === 'Enter' || e.key === ' ') && e.target === e.currentTarget) { e.preventDefault(); e.currentTarget.click(); } }}
                        // right-click: its menu, where the pointer is
                        onContextMenu={(e) => { e.preventDefault(); setTaskMenu({ id: k.id, at: new DOMRect(e.clientX, e.clientY, 0, 0), atPointer: true }); }}
                      >
                        <TaskMark task={k} size={14} />
                        <span className="sidebar-item-title">{k.title}</span>
                        {/* at the row's end, its state: new, needs you, working, queued or done;
                            on hover, its ⋮ in the same spot */}
                        <StatusDot task={k} />
                        <button
                          className="sidebar-item-more"
                          aria-label={`More for ${k.title}`}
                          aria-haspopup="menu"
                          aria-expanded={taskMenu?.id === k.id}
                          onClick={(e) => { e.stopPropagation(); setTaskMenu(taskMenu?.id === k.id ? null : { id: k.id, at: e.currentTarget.getBoundingClientRect() }); }}
                        >
                          <EllipsisVertical size={14} strokeWidth={1.6} />
                        </button>
                      </div>
                    ))}
                    {shownOf(t).hidden > 0 && (
                      <button className="sidebar-more" onClick={() => toggleMore(t.id)}>
                        {more.has(t.id) ? 'Show less' : `Show ${shownOf(t).hidden} more`}
                      </button>
                    )}
                  </div>
                </div>
              </section>
            ))}
            {!groups.length && <p className="sidebar-empty">No tasks yet</p>}
          </div>
        )}
        {section === 'settings' && (
          <div className="sidebar-plain sidebar-settings">
            {settingsPages(preview).map((p) => (
              <button
                key={p.id}
                className={`sidebar-item${activeSetting === p.id ? ' is-active' : ''}`}
                aria-current={activeSetting === p.id || undefined}
                onClick={() => onOpenSetting(p.id)}
              >
                <span className="sidebar-item-title">{p.label}</span>
              </button>
            ))}
          </div>
        )}
        </div>
        <div {...thumbProps} />
        </div>
        {/* Home's foot, held at the bottom under a line, however it's grouped:
            the archive, done tasks that have left Home; it opens as a page */}
        {section === 'home' && archivedCount > 0 && (
          <button className="sidebar-archived" onClick={onOpenArchive}>
            Archived
            <span className="sidebar-group-count">{archivedCount}</span>
          </button>
        )}
        </div>
      </nav>

      {/* A Home task's menu (TaskMenu), its page first */}
      {taskMenu && menuTask && (
        <TaskMenu
          task={menuTask}
          at={taskMenu.at}
          align={taskMenu.atPointer ? 'left' : 'right'}
          onClose={() => setTaskMenu(null)}
          onViewDetails={() => { markSeen(menuTask.id); onOpenTask(menuTask.id); }}
          onOpenChat={() => onOpenChat(menuTask.id)}
        />
      )}
      {accountMenu && (
        <Menu at={accountMenu} onClose={() => setAccountMenu(null)} align="left" width={240} height={150}>
          <div className="menu-head is-account">
            <span className="menu-head-text">
              <span className="menu-head-name">Oby on {host}</span>
              <span className="menu-head-url">{location.host}</span>
            </span>
          </div>
          <hr />
          {/* Settings opens on General, unless one of its pages is open already */}
          <button role="menuitem" onClick={() => { setAccountMenu(null); pick('settings'); if (!activeSetting) onOpenSetting('general'); }}>Settings</button>
          <hr />
          <SignOut role="menuitem">Sign out</SignOut>
        </Menu>
      )}
      {archiveMenu && (
        <Menu at={archiveMenu} onClose={() => setArchiveMenu(null)} height={290} width={180}>
          <span className="menu-label">Group by</span>
          {(['type', 'status'] as const).map((by) => (
            <button key={by} role="menuitemradio" aria-checked={groupBy === by} onClick={() => pickGroupBy(by)}>
              {by === 'type' ? 'Type' : 'Status'}
              {groupBy === by && <Check size={14} strokeWidth={1.8} className="menu-check" />}
            </button>
          ))}
          <hr />
          <span className="menu-label">Archive completed</span>
          {ARCHIVE_AFTER.map((a) => (
            <button key={a.id} role="menuitemradio" aria-checked={archiveAfter === a.id} onClick={() => pickArchive(a.id)}>
              {a.label}
              {archiveAfter === a.id && <Check size={14} strokeWidth={1.8} className="menu-check" />}
            </button>
          ))}
        </Menu>
      )}
    </div>
    {/* the panel's right edge, out here so it can reach past the edge (the slot
        clips): drag to resize, double-click for the default width */}
    {open && (
      <div
        className="sidebar-resize"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize side panel"
        onPointerDown={startResize}
        onDoubleClick={() => onResize(null, true)}
      />
    )}
    </>
  );
}
