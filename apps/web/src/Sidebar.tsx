import { Fragment, useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { BookOpen, Check, ChevronDown, EllipsisVertical, Plus, Search, type LucideIcon } from 'lucide-react';
// the icon strip uses Phosphor: it has outline and filled versions of each icon
import { ChatsCircleIcon, HouseIcon, UsersThreeIcon } from '@phosphor-icons/react';
import { ARCHIVE_AFTER, archivedTasks, countOf, getArchiveAfter, getGroupBy, groupsOf, onArchiveAfter, onGroupBy, setArchiveAfter, setGroupBy, shownOf, useTasks, ago, type GroupBy } from './tasks';
import { markSeen, renameConversation, useLive } from './live';
import { aboutOf, listOf } from './chats';
import type { Conversation } from './api';
import ConvoMenu from './ConvoMenu';
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
// What each tab can start, first thing under its title; and which tabs can be searched
const NEW_ACTION: Partial<Record<Section, { label: string; icon: LucideIcon }>> = {
  home: { label: 'New task', icon: Plus },
  conversations: { label: 'New conversation', icon: Plus },
};
const SEARCHABLE: Section[] = ['conversations'];
const minutesSince = (iso: string) => Math.max(0, (Date.now() - Date.parse(iso)) / 60_000);

// The side panel, in two columns: icons on the far left pick a section (Home, Conversations; with
// "Show screens still being built", the Obysphere; Settings from the account picture at the
// foot), the column beside them shows it. Search, on the tabs that have it, sits by the panel
// icon. It opens from the left and pushes the view over.
export default function Sidebar({ open, onNewChat, onNewConversation, onHome, onOpenTask, onOpenChat, onOpenTalk, onOpenArchive, onOpenSetting, onOpenKnowledge, activeTalk = null, activeSetting = null, activeKnowledge = false, active = null, width, onResize }: {
  open: boolean;
  onNewChat: () => void;  // New task: Home's message box, which starts a conversation
  onNewConversation: () => void;  // New conversation: an empty one, started by its first words
  onHome: () => void;  // back to Home's own page, closing whatever is open over it
  onOpenTask: (id: string) => void;  // a task's page, on its own
  onOpenChat: (id: string) => void;  // a task's conversation, from its menu
  onOpenTalk: (id: string) => void;  // a conversation with Oby, from Conversations
  onOpenArchive: () => void;  // the archived tasks, as a page
  activeTalk?: string | null;  // the conversation with Oby that's showing: its row is highlighted
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
  const preview = usePreview();
  const archiveAfter = useSyncExternalStore(onArchiveAfter, getArchiveAfter);
  // Home's dot turns orange while any task needs you, blue while one is new
  const needsYou = countOf(store, 'needs') > 0;
  const fresh = tasks.some((t) => t.fresh);
  const [section, setSection] = useState<Section>('home');
  const sections: { id: Section; label: string; icon: StripIcon }[] = [
    { id: 'home', label: 'Home', icon: HouseIcon },
    // your conversations with Oby
    { id: 'conversations', label: 'Conversations', icon: ChatsCircleIcon },
  ];
  // the setting turned off while its section shows: back to Home
  useEffect(() => { if (!preview) setSection((s) => (s === 'obysphere' ? 'home' : s)); }, [preview]);
  const inSettings = section === 'settings';
  // a Settings page opened from elsewhere (the message box's usage gear): the panel follows
  useEffect(() => { if (activeSetting) setSection('settings'); }, [activeSetting]);
  const [query, setQuery] = useState('');
  const [searching, setSearching] = useState(false);
  const searchInput = useRef<HTMLInputElement>(null);
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
  // a conversation's menu, and renaming one in place, as a task's
  const [convoMenu, setConvoMenu] = useState<{ id: string; at: DOMRect; atPointer?: boolean } | null>(null);
  const menuConvo = convoMenu ? store.conversations.find((c) => c.id === convoMenu.id) : undefined;
  const [renamingConvo, setRenamingConvo] = useState<string | null>(null);
  // Home's groups: by kind of work (the default) or by status; remembered (tasks.ts)
  const groupBy = useSyncExternalStore(onGroupBy, getGroupBy);
  const pickGroupBy = (by: GroupBy) => { setGroupBy(by); setArchiveMenu(null); };
  // each group: its tasks, how many to show by its name (open ones for a kind
  // of work, all of them for a status), and how many need you
  const groups = groupsOf(store, groupBy);
  const pickArchive = (id: string) => { setArchiveAfter(id); setArchiveMenu(null); };
  // A group's done tasks: the latest few (3 in a kind of work, 5 in Done), then
  // Show more for the rest; what's still open always shows in full (shownOf). Done tasks
  // leave Home for the archive after a while (Archive completed, in Home's ⋮)
  const toggleMore = (id: string) => setMore((m) => { const next = new Set(m); if (!next.delete(id)) next.add(id); return next; });
  const archivedCount = archivedTasks(store).length;
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLDivElement>();
  const pick = (id: Section) => {
    // Home again, while it's showing: back to Home's own page (the dashboard)
    if (id === 'home' && section === 'home') onHome();
    setSection(id); setSearching(false); setQuery('');
    if (list.current) list.current.scrollTop = 0;
  };
  const openSearch = () => {
    if (searching) setQuery('');
    setSearching(!searching);
  };
  // the search field takes focus as it opens
  useEffect(() => { if (searching) searchInput.current?.focus(); }, [searching]);
  const newAction = NEW_ACTION[section];
  const host = store.status?.runner.host ?? 'obid';

  const toggleGroup = (name: string) => setFolded((f) => {
    const next = new Set(f);
    if (!next.delete(name)) next.add(name);
    return next;
  });

  // your conversations with Oby (matching the search): pinned ones under Pinned, the rest under
  // Recent (no headings while nothing's pinned)
  const talks = listOf(store, query);
  const convoRow = (c: Conversation) => {
    const about = aboutOf(store, c);
    const busy = store.thinking && store.asking === c.id;
    return (
      // a row with its own menu button, so the row itself isn't a <button>
      <div
        key={c.id}
        role="button"
        tabIndex={0}
        className={`connector task convo-row${activeTalk === c.id ? ' is-active' : ''}${convoMenu?.id === c.id ? ' is-menu-open' : ''}`}
        aria-current={activeTalk === c.id || undefined}
        onClick={() => onOpenTalk(c.id)}
        onKeyDown={(e) => { if ((e.key === 'Enter' || e.key === ' ') && e.target === e.currentTarget) { e.preventDefault(); e.currentTarget.click(); } }}
        // right-click: its menu, where the pointer is
        onContextMenu={(e) => { e.preventDefault(); setConvoMenu({ id: c.id, at: new DOMRect(e.clientX, e.clientY, 0, 0), atPointer: true }); }}
      >
        <span className="connector-text">
          {renamingConvo === c.id ? (
            <input
              className="sidebar-rename"
              defaultValue={c.title}
              maxLength={100}
              autoFocus
              onFocus={(e) => e.currentTarget.select()}
              onClick={(e) => e.stopPropagation()}
              onBlur={(e) => { void renameConversation(c.id, e.currentTarget.value); setRenamingConvo(null); }}
              onKeyDown={(e) => {
                if (e.key === 'Enter') e.currentTarget.blur();
                if (e.key === 'Escape') { e.stopPropagation(); e.currentTarget.value = c.title; setRenamingConvo(null); }
              }}
              aria-label="Conversation name"
            />
          ) : <span className="connector-name">{c.title}</span>}
          {about && <span className="connector-about">{about}</span>}
        </span>
        {/* when it last moved; on hover, its ⋮ in the same spot */}
        <span className="sidebar-item-ago">{busy ? 'now' : ago(minutesSince(c.lastActivity))}</span>
        <button
          className="sidebar-item-more"
          aria-label={`More for ${c.title}`}
          aria-haspopup="menu"
          aria-expanded={convoMenu?.id === c.id}
          onClick={(e) => { e.stopPropagation(); setConvoMenu(convoMenu?.id === c.id ? null : { id: c.id, at: e.currentTarget.getBoundingClientRect() }); }}
        >
          <EllipsisVertical size={14} strokeWidth={1.6} />
        </button>
      </div>
    );
  };

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
        {/* on the panel icon's row */}
        <div className="sidebar-top">
          {SEARCHABLE.includes(section) && (
            <button className={`icon-button${searching ? ' is-on' : ''}`} aria-label="Search" aria-expanded={searching} onClick={openSearch}>
              <Search size={17} strokeWidth={1.6} />
            </button>
          )}
        </div>
        {/* everything under the title scrolls together; the title stays */}
        <div className="sidebar-scroll">
        <div ref={list} className="sidebar-list" onScroll={onScroll}>
        {/* slides open under the title (a one-row grid going 0fr → 1fr) */}
        <div className={`sidebar-search-wrap${searching ? ' is-open' : ''}`}>
          <div>
            <label className="sidebar-search">
              <Search size={14} strokeWidth={1.6} />
              <input
                ref={searchInput}
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Escape') { e.stopPropagation(); setSearching(false); setQuery(''); } }}
                placeholder="Search"
                aria-label="Search"
                tabIndex={searching ? 0 : -1}
              />
            </label>
          </div>
        </div>

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
          <button className="sidebar-new" onClick={section === 'conversations' ? onNewConversation : onNewChat}>
            <newAction.icon size={16} strokeWidth={1.6} />
            <span className="sidebar-new-label">{newAction.label}</span>
          </button>
        )}

        {/* your conversations with Oby, newest first, ones still going included (#493) */}
        {section === 'conversations' && (
          <div className="sidebar-plain">
            {talks.pinned.length > 0 && <h3 className="sidebar-convo-head">Pinned</h3>}
            {talks.pinned.map(convoRow)}
            {talks.pinned.length > 0 && talks.recent.length > 0 && <h3 className="sidebar-convo-head">Recent</h3>}
            {talks.recent.map(convoRow)}
            {!talks.pinned.length && !talks.recent.length && <p className="sidebar-empty">{query.trim() ? `No conversations match “${query.trim()}”` : 'No conversations yet'}</p>}
          </div>
        )}
        {/* Home: each kind of work folds open to its tasks (running / needs you counted on the
            right) */}
        {section === 'home' && (
          <div className="sidebar-plain">
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
                    {shownOf(t, more.has(t.id)).rows.map((k) => (
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
                        <span className="sidebar-item-title">
                          {k.who && <span className="sidebar-item-who">{k.who}</span>}
                          {k.title}
                        </span>
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
                    {shownOf(t, false).hidden > 0 && (
                      <button className="sidebar-more" onClick={() => toggleMore(t.id)}>
                        {more.has(t.id) ? 'Show less' : `Show ${shownOf(t, false).hidden} more`}
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
      {/* a conversation's menu (ConvoMenu) */}
      {convoMenu && menuConvo && (
        <ConvoMenu
          convo={menuConvo}
          at={convoMenu.at}
          align={convoMenu.atPointer ? 'left' : 'right'}
          onClose={() => setConvoMenu(null)}
          onRename={() => setRenamingConvo(menuConvo.id)}
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
