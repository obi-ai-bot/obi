import { Fragment, useEffect, useRef, useState } from 'react';
import { BookOpen, Check, Mail, UserPlus, ChevronDown, EllipsisVertical, Plus, Search, type LucideIcon } from 'lucide-react';
// the icon strip uses Phosphor: it has outline and filled versions of each icon
import { ChatsCircleIcon, HouseIcon, PlusIcon } from '@phosphor-icons/react';
import { BrandMark } from './brands';
import { ARCHIVE_AFTER, TYPES, archivedTasks, countOf, getArchiveAfter, markSeen, openOf, renameTask, setArchiveAfter, tasksOf, tasksWith, useTasks, type Task } from './tasks';
import { OBYS, ago } from './mock';
import { OwnerAvatar } from './ObyFace';
import { useScrollThumb } from './useScrollThumb';
import { Menu } from './Menu';
import { SETTINGS_PAGES } from './SettingsView';
import InviteModal from './InviteModal';
import CreateSphereModal from './CreateSphereModal';
import SphereTile from './SphereTile';
import { ME, cancelInvite, invite, memberCount, urlOf, useSpheres, type Sphere } from './spheres';
import TaskMenu from './TaskMenu';
import ConvoMenu from './ConvoMenu';
import StatusDot from './StatusDot';
import { convosWith, hasUnread, useConvos } from './peers';
import { lastAgo, renameChat, useChats, type Chat } from './chats';

type Section = 'home' | 'conversations' | 'obysphere' | 'settings';
type StripIcon = (p: { size?: number; weight?: 'regular' | 'fill' }) => React.ReactNode;
// sections with something new get a blue dot on their icon
const UNREAD: Section[] = ['home'];
const SECTIONS: { id: Section; label: string; icon: StripIcon }[] = [
  { id: 'home', label: 'Home', icon: HouseIcon },
  // your conversations with Oby
  { id: 'conversations', label: 'Conversations', icon: ChatsCircleIcon },
];
// each section's name over it (an Obysphere's is its own)
const TITLES: Record<Exclude<Section, 'obysphere'>, string> = {
  home: 'Home', conversations: 'Conversations', settings: 'Settings',
};

// What each tab can start, first thing under its title; and which tabs can be searched.
const NEW_ACTION: Partial<Record<Section, { label: string; icon: LucideIcon }>> = {
  home: { label: 'New task', icon: Plus },
};
const SEARCHABLE: Section[] = ['conversations'];
// a conversation's line under its name: the tasks it started, else Oby's last words
const convoAbout = (c: Chat) => {
  const n = c.said.flatMap((m) => m.jobs ?? []).length;
  if (n) return `Started ${n} task${n === 1 ? '' : 's'}`;
  return [...c.said].reverse().find((m) => m.who === 'oby' && m.text)?.text ?? 'Oby is on it';
};

// The side panel, in two columns: icons on the far left pick a section
// (Home, Conversations, then each Obysphere you're in and + to make another;
// Settings from your account picture at the foot), the column beside
// them shows it. Search, on the tabs that have it, sits by the panel icon.
// It opens from the left and pushes the view over.
export default function Sidebar({ open, onNewChat, onHome, onOpenTask, onOpenChat, onOpenOby, onOpenTalk, onOpenArchive, onOpenSetting, onOpenSphereSetting, onOpenKnowledge, activeOby = null, activeTalk = null, activeSetting = null, activeSphereSetting = null, activeKnowledge = null, active = null, width, onResize }: {
  open: boolean;
  onNewChat: () => void;
  onHome: () => void;  // back to Home's own page, closing whatever is open over it
  onOpenTask: (id: string) => void;  // a task's page, on its own
  onOpenChat: (id: string) => void;  // a task's conversation, from its menu
  onOpenOby: (name: string) => void;  // someone else's Oby, from the Obysphere: its conversations
  onOpenTalk: (id: string) => void;  // a conversation with Oby, from Conversations
  onOpenArchive: () => void;  // the archived tasks, as a page
  activeOby?: string | null;  // the Oby whose page is showing: its row is highlighted
  activeTalk?: string | null;  // the conversation with Oby that's showing: its row is highlighted
  activeSetting?: string | null;  // the Settings page that's showing: its row is highlighted
  onOpenSphereSetting: (sphere: string) => void;  // an Obysphere's settings, from its ⋮
  activeSphereSetting?: string | null;  // the Obysphere whose settings are showing
  onOpenKnowledge: (sphere: string) => void;  // an Obysphere's knowledge, from Knowledge
  activeKnowledge?: string | null;  // the Obysphere whose knowledge is showing: Knowledge is highlighted
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
  const tasks = useTasks();
  const convos = useConvos();
  const chats = useChats();
  // Home's dot turns orange while any task needs you
  const needsYou = countOf('needs') > 0;
  const [section, setSection] = useState<Section>('home');
  // the Obyspheres you're in (spheres.ts), under the line in the icon strip:
  // an Obysphere (a focused workspace: your Oby with other people's, sharing
  // what the org knows) by its name, under its own logo. Which one is showing
  const spheres = useSpheres();
  const [sphereId, setSphereId] = useState(() => spheres[0]?.id ?? '');
  // (the last one shown, while it goes: deleted or left, the panel goes back to Home)
  const lastSphere = useRef<Sphere>(spheres[0]);
  const sphere = spheres.find((x) => x.id === sphereId) ?? lastSphere.current;
  lastSphere.current = sphere;
  const inSphere = section === 'obysphere';
  const members = memberCount(sphere);
  // an invite's menu (⋮ or right-click on it; an admin's): send it again, or take it back.
  // resent: the one just sent again, which says so for a moment
  const [inviteMenu, setInviteMenu] = useState<{ email: string; at: DOMRect; atPointer?: boolean } | null>(null);
  const [resent, setResent] = useState<string | null>(null);
  useEffect(() => {
    if (!resent) return;
    const t = setTimeout(() => setResent(null), 2000);
    return () => clearTimeout(t);
  }, [resent]);
  // making a new one (CreateSphereModal): its modal is open
  const [creating, setCreating] = useState(false);
  const inSettings = section === 'settings';
  // a Settings page opened from elsewhere (the message box's usage gear): the panel follows
  useEffect(() => { if (activeSetting) setSection('settings'); }, [activeSetting]);
  // and an Obysphere's settings or knowledge: the panel shows that Obysphere
  useEffect(() => {
    const id = activeSphereSetting ?? activeKnowledge;
    if (!id) return;
    setSphereId(id);
    setSection('obysphere');
  }, [activeSphereSetting, activeKnowledge]);
  useEffect(() => {
    if (spheres.some((x) => x.id === sphereId)) return;
    if (spheres[0]) setSphereId(spheres[0].id);
    setSection((s) => (s === 'obysphere' ? 'home' : s));
  }, [spheres, sphereId]);
  const [query, setQuery] = useState('');
  const [searching, setSearching] = useState(false);
  const searchInput = useRef<HTMLInputElement>(null);
  // groups the user folded away; while searching, every group with a match opens
  const [folded, setFolded] = useState<Set<string>>(new Set());
  // groups showing all their done tasks (Show more), not just the latest few
  const [more, setMore] = useState<Set<string>>(new Set());
  // a Home task's menu: from its ⋮ (under it), or a right-click (where the pointer is)
  const [taskMenu, setTaskMenu] = useState<{ id: string; at: DOMRect; atPointer?: boolean } | null>(null);
  const menuTask = taskMenu ? tasks.find((t) => t.id === taskMenu.id) : undefined;
  // a Home task being renamed in place
  const [renamingTask, setRenamingTask] = useState<string | null>(null);
  const doneRenamingTask = (id: string, title: string) => { renameTask(id, title); setRenamingTask(null); };
  // a conversation's menu, and renaming one in place, as a task's
  const [convoMenu, setConvoMenu] = useState<{ id: string; at: DOMRect; atPointer?: boolean } | null>(null);
  const menuConvo = convoMenu ? chats.find((c) => c.id === convoMenu.id) : undefined;
  const [renamingConvo, setRenamingConvo] = useState<string | null>(null);
  // Home's ⋮: how its tasks are grouped, and when done ones get archived
  const [archiveMenu, setArchiveMenu] = useState<DOMRect | null>(null);
  // your account's menu (your picture at the icons' foot): who you are, Settings, log out
  const [accountMenu, setAccountMenu] = useState<DOMRect | null>(null);
  // the Obysphere's ⋮: which one it is, then its settings; leave it, for those
  // invited in (not its admins; Leave does nothing yet here, Settings' does)
  const [sphereMenu, setSphereMenu] = useState<DOMRect | null>(null);
  // inviting people into the Obysphere (Invite member): its modal is open
  const [inviting, setInviting] = useState(false);
  const archiveAfter = getArchiveAfter();
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
    ? TYPES.map((t) => ({ id: t.id, label: t.label, tasks: tasksOf(t.id), count: openOf(t.id), countLabel: 'open', needs: countOf('needs', t.id) }))
    : ([['needs', 'Needs you'], ['running', 'Running'], ['done', 'Completed']] as const).map(([id, label]) => {
      const list = tasksWith(id);
      return { id: `status:${id}`, label, tasks: list, count: list.length, countLabel: 'tasks', needs: id === 'needs' ? list.length : 0 };
    });
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
  const archivedCount = archivedTasks().length;
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLDivElement>();
  const pick = (id: Section) => {
    // Home again, while it's showing: back to Home's own page (the dashboard)
    if (id === 'home' && section === 'home') onHome();
    setSection(id); setSearching(false); setQuery('');
    if (list.current) list.current.scrollTop = 0;
  };
  const q = query.trim().toLowerCase();
  const matches = (...text: string[]) => !q || text.join(' ').toLowerCase().includes(q);
  const newAction = NEW_ACTION[section];

  const toggleGroup = (name: string) => setFolded((f) => {
    const next = new Set(f);
    if (!next.delete(name)) next.add(name);
    return next;
  });
  const openSearch = () => {
    if (searching) setQuery('');
    setSearching(!searching);
  };
  // the search field takes focus as it opens
  useEffect(() => { if (searching) searchInput.current?.focus(); }, [searching]);

  // your conversations with Oby (matching the search): pinned ones first, under
  // Pinned, the rest under Recent (no headings while nothing's pinned)
  const talks = chats.filter((c) => matches(c.title, ...c.said.map((m) => m.text)));
  const pinned = talks.filter((c) => c.pinned);
  const convoRow = (c: Chat) => (
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
            autoFocus
            onFocus={(e) => e.currentTarget.select()}
            onClick={(e) => e.stopPropagation()}
            onBlur={(e) => { renameChat(c.id, e.currentTarget.value); setRenamingConvo(null); }}
            onKeyDown={(e) => {
              if (e.key === 'Enter') e.currentTarget.blur();
              if (e.key === 'Escape') { e.stopPropagation(); setRenamingConvo(null); }
            }}
            aria-label="Conversation name"
          />
        ) : <span className="connector-name">{c.title}</span>}
        <span className="connector-about">{convoAbout(c)}</span>
      </span>
      {/* when it last moved; on hover, its ⋮ in the same spot */}
      <span className="sidebar-item-ago">{c.typing ? 'now' : ago(lastAgo(c))}</span>
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

  return (
    <>
    <div className="sidebar-slot" inert={!open}>
      <nav className="sidebar" aria-label="Side panel">
        <div className="rail">
          {SECTIONS.map(({ id, label, icon: Icon }) => (
            <Fragment key={id}>
              <button className={`rail-button${section === id ? ' is-on' : ''}${UNREAD.includes(id) ? ' has-dot' : ''}${id === 'home' && needsYou ? ' has-dot is-needs' : ''}`} data-tip={label} aria-label={label} aria-pressed={section === id} onClick={() => pick(id)}>
                <Icon size={20} weight={section === id ? 'fill' : 'regular'} />
              </button>
              {/* your own places above the line; the Obyspheres (there can be several) below */}
              {id === 'conversations' && <span className="rail-sep" role="separator" />}
            </Fragment>
          ))}
          {spheres.map((x) => (
            <button key={x.id} className={`rail-button${inSphere && sphere.id === x.id ? ' is-on' : ''}`} data-tip={x.name} aria-label={x.name} aria-pressed={inSphere && sphere.id === x.id} onClick={() => { setSphereId(x.id); pick('obysphere'); }}>
              <SphereTile name={x.name} brand={x.brand} image={x.image} />
            </button>
          ))}
          {/* not a section: makes another Obysphere (CreateSphereModal) */}
          <button className="rail-button" data-tip="Create an Obysphere" aria-label="Create an Obysphere" aria-haspopup="dialog" onClick={() => setCreating(true)}>
            <PlusIcon size={20} />
          </button>
          {/* you, at the foot: your picture opens your account's menu (Settings is in it) */}
          <button
            className={`rail-button rail-account${inSettings || accountMenu ? ' is-on' : ''}`}
            data-tip={accountMenu ? undefined : 'Account'}
            aria-label={`${ME.name}’s account`}
            aria-haspopup="menu"
            aria-expanded={!!accountMenu}
            onClick={(e) => setAccountMenu(accountMenu ? null : e.currentTarget.getBoundingClientRect())}
          >
            <OwnerAvatar name={ME.name} size={24} badge={false} />
          </button>
        </div>

        <div className="sidebar-content">
        <div className="sidebar-title-row">
          <h2 className="sidebar-title">{inSphere ? sphere.name : TITLES[section]}</h2>
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
          {section === 'obysphere' && (
            <button
              className={`icon-button${sphereMenu ? ' is-on' : ''}`}
              aria-label={`${sphere.name} options`}
              aria-haspopup="menu"
              aria-expanded={!!sphereMenu}
              onClick={(e) => setSphereMenu(sphereMenu ? null : e.currentTarget.getBoundingClientRect())}
            >
              <EllipsisVertical size={16} strokeWidth={1.6} />
            </button>
          )}
        </div>
        {/* how many members it has, you included */}
        {section === 'obysphere' && <p className="sidebar-subtitle">{members} member{members === 1 ? '' : 's'}</p>}
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

        {/* the Obysphere: what its Obys share (Knowledge: the knowledge sources
            connected for everyone), and inviting someone in (InviteModal), first */}
        {section === 'obysphere' && (
          <>
            <button className={`sidebar-new is-stacked${activeKnowledge === sphere.id ? ' is-active' : ''}`} aria-current={activeKnowledge === sphere.id || undefined} onClick={() => onOpenKnowledge(sphere.id)}>
              <BookOpen size={16} strokeWidth={1.6} />
              <span className="sidebar-new-label">Knowledge</span>
            </button>
            <button className="sidebar-new is-stacked" aria-haspopup="dialog" onClick={() => setInviting(true)}>
              <UserPlus size={16} strokeWidth={1.6} />
              <span className="sidebar-new-label">Invite member</span>
            </button>
          </>
        )}
        {newAction && (
          <button className="sidebar-new" onClick={onNewChat}>
            <newAction.icon size={16} strokeWidth={1.6} />
            <span className="sidebar-new-label">{newAction.label}</span>
          </button>
        )}

        {/* your conversations with Oby, newest first, ones still going included */}
        {section === 'conversations' && (
          <div className="sidebar-plain">
            {pinned.length > 0 && <h3 className="sidebar-convo-head">Pinned</h3>}
            {pinned.map(convoRow)}
            {pinned.length > 0 && pinned.length < talks.length && <h3 className="sidebar-convo-head">Recent</h3>}
            {talks.filter((c) => !c.pinned).map(convoRow)}
            {!talks.length && <p className="sidebar-empty">{query.trim() ? `No conversations match “${query.trim()}”` : 'No conversations yet'}</p>}
          </div>
        )}
        {/* Home: each kind of work folds open to its tasks (running / needs you
            counted on the right) */}
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
                        <BrandMark brand={k.brand} size={14} mono />
                        {renamingTask === k.id ? (
                          <input
                            className="sidebar-rename"
                            defaultValue={k.title}
                            autoFocus
                            onFocus={(e) => e.currentTarget.select()}
                            onClick={(e) => e.stopPropagation()}
                            onBlur={(e) => doneRenamingTask(k.id, e.currentTarget.value)}
                            onKeyDown={(e) => {
                              if (e.key === 'Enter') e.currentTarget.blur();
                              if (e.key === 'Escape') { e.stopPropagation(); setRenamingTask(null); }
                            }}
                            aria-label="Task name"
                          />
                        ) : (
                          <span className="sidebar-item-title">
                            {k.who && <span className="sidebar-item-who">{k.who}</span>}
                            {k.title}
                          </span>
                        )}
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
          </div>
        )}
        {/* the Obysphere: the people in it (their Obys); a conversation with one
            starts from its page. Then who's been invited and hasn't joined yet */}
        {section === 'obysphere' && (
          <div className="sidebar-plain">
            {/* Members, then Invited (who hasn't joined yet: once they do, they're
                in Members), each folding as Home's groups do */}
            <SphereGroup id={`members:${sphere.id}`} label="Members" folded={folded} onToggle={toggleGroup}>
            {!sphere.members.length && <p className="sidebar-empty">Just you so far</p>}
            {OBYS.filter((o) => sphere.members.includes(o.name) && matches(o.name)).map((o) => (
              <button key={o.name} className={`connector oby-row${activeOby === o.name ? ' is-active' : ''}`} aria-current={activeOby === o.name || undefined} onClick={() => onOpenOby(o.name)} aria-label={`Chat with ${o.name}’s Oby${hasUnread(convos, o.name) ? ', new messages' : ''}`}>
                <OwnerAvatar name={o.name} size={22} />
                <span className="connector-text">
                  <span className="connector-name">{o.name}</span>
                </span>
                {/* something new from it: a blue dot, just before the count */}
                {hasUnread(convos, o.name) && <span className="status-dot is-new" role="img" aria-label="New messages" />}
                {/* how many conversations with it, if any */}
                {convosWith(convos, o.name).length > 0 && <span className="connector-count" aria-label={`${convosWith(convos, o.name).length} conversations`}>{convosWith(convos, o.name).length}</span>}
              </button>
            ))}
            </SphereGroup>
            {sphere.invited.length > 0 && (
              <SphereGroup id={`invited:${sphere.id}`} label="Invited" count={sphere.invited.length} folded={folded} onToggle={toggleGroup}>
                {sphere.invited.map((e) => (
                  <div
                    key={e}
                    className={`connector oby-row invited-row${inviteMenu?.email === e ? ' is-menu-open' : ''}`}
                    onContextMenu={sphere.admin ? (ev) => { ev.preventDefault(); setInviteMenu({ email: e, at: new DOMRect(ev.clientX, ev.clientY, 0, 0), atPointer: true }); } : undefined}
                  >
                    <span className="invited-mark"><Mail size={12} strokeWidth={1.8} /></span>
                    <span className="connector-text"><span className="connector-name">{e}</span></span>
                    {resent === e && <span className="invited-sent">Sent</span>}
                    {sphere.admin && (
                      <button
                        className="sidebar-item-more"
                        aria-label={`More for ${e}`}
                        aria-haspopup="menu"
                        aria-expanded={inviteMenu?.email === e}
                        onClick={(ev) => setInviteMenu(inviteMenu?.email === e ? null : { email: e, at: ev.currentTarget.getBoundingClientRect() })}
                      >
                        <EllipsisVertical size={14} strokeWidth={1.6} />
                      </button>
                    )}
                  </div>
                ))}
              </SphereGroup>
            )}
          </div>
        )}
        {section === 'settings' && (
          <div className="sidebar-plain sidebar-settings">
            {SETTINGS_PAGES.map((p) => (
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
          onRename={() => setRenamingTask(menuTask.id)}
        />
      )}
      {/* an invite's menu: send it again; take it back */}
      {inviteMenu && (
        <Menu at={inviteMenu.at} align={inviteMenu.atPointer ? 'left' : 'right'} onClose={() => setInviteMenu(null)} height={100} width={168}>
          <button role="menuitem" onClick={() => { setResent(inviteMenu.email); setInviteMenu(null); }}>Resend invite</button>
          <hr />
          <button role="menuitem" className="is-danger" onClick={() => { cancelInvite(sphere.id, inviteMenu.email); setInviteMenu(null); }}>Cancel invite</button>
        </Menu>
      )}
      {/* a conversation's menu (ConvoMenu) */}
      {convoMenu && menuConvo && (
        <ConvoMenu
          chat={menuConvo}
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
              <span className="menu-head-name">{ME.name}</span>
              <span className="menu-head-url">{ME.email}</span>
            </span>
          </div>
          <hr />
          {/* Settings opens on General, unless one of its pages is open already */}
          <button role="menuitem" onClick={() => { setAccountMenu(null); pick('settings'); if (!activeSetting) onOpenSetting('general'); }}>Settings</button>
          <hr />
          <button role="menuitem" onClick={() => setAccountMenu(null)}>Log out</button>
        </Menu>
      )}
      {inviting && <InviteModal sphere={{ name: sphere.name, url: urlOf(sphere) }} domain={sphere.domain} onSent={(emails) => invite(sphere.id, emails)} onClose={() => setInviting(false)} />}
      {creating && <CreateSphereModal email={ME.email} onCreated={(id) => { setCreating(false); setSphereId(id); pick('obysphere'); }} onClose={() => setCreating(false)} />}
      {sphereMenu && (
        <Menu at={sphereMenu} onClose={() => setSphereMenu(null)} height={sphere.admin ? 120 : 170} width={201}>
          {/* which Obysphere: its picture, then its name and URL under it */}
          <div className="menu-head is-stacked">
            <SphereTile name={sphere.name} brand={sphere.brand} image={sphere.image} />
            <span className="menu-head-text">
              <span className="menu-head-name">{sphere.name}</span>
              <span className="menu-head-url">{urlOf(sphere)}</span>
            </span>
          </div>
          <hr />
          <button role="menuitem" onClick={() => { setSphereMenu(null); onOpenSphereSetting(sphere.id); }}>Settings</button>
          {!sphere.admin && <>
            <hr />
            <button role="menuitem" className="is-danger" onClick={() => setSphereMenu(null)}>Leave {sphere.name}</button>
          </>}
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

// One of an Obysphere's lists in the side panel (Members, Invited), folding
// as Home's groups do: its name, a chevron after it, a count at the right
function SphereGroup({ id, label, count, folded, onToggle, children }: {
  id: string;
  label: string;
  count?: number;
  folded: Set<string>;
  onToggle: (id: string) => void;
  children: React.ReactNode;
}) {
  const shut = folded.has(id);
  return (
    <section className={`sidebar-group sphere-group${shut ? ' is-folded' : ''}`}>
      <button className="sidebar-group-head" aria-expanded={!shut} onClick={() => onToggle(id)}>
        <h3>{label}</h3>
        <ChevronDown size={12} strokeWidth={1.8} className="sidebar-chevron" />
        {count !== undefined && <span className="sidebar-group-count">{count}</span>}
      </button>
      <div className="sidebar-group-body"><div>{children}</div></div>
    </section>
  );
}
