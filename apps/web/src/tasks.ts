import { BRANDS, type Brand } from './brands';
import type { Agent, InboxItem, Job, JobStatus, Stage } from './api';
import { useLive, type Live } from './live';

// Tasks are obid's jobs (and the inbox's decisions that belong to no job) as Home shows them.
// Each belongs to a kind of work (the chips on Home, the groups in the side panel) and is running,
// needs you, or done. fresh: arrived since the page opened and not opened yet, the only tasks
// with a blue dot. who: the teammate whose Oby asked for it, shown before its title.
//
// The rules of #496, which the Mac's side panel follows too (apps/shared, SwiftUI):
// - Kind of work, from fields obid sends, in this order: Review PR (`kind` review), Issues (an
//   `issue`), one group per teammate whose Oby asked you for something (a job's `obi.fromOwner`,
//   or an open `obiRequest` item's), Tasks (the rest), and Inbox (decisions that belong to no job
//   and no teammate: a plug-in's event, an audit). A teammate's request is theirs even when it's a
//   review. No group comes from a title or other words. Routines have no group: obid has no
//   routines yet (#395).
// - Status: needs you (an open inbox item, or failed or interrupted and not let go), running
//   (queued or running), done.
// - Group by Type (the default) or Status (Needs you, Running, Completed), remembered in this
//   browser. A group lists everything open, then its latest 3 done (5 in Completed), then Show
//   more; its count is its open tasks (by status, all of them); an orange dot when anything in
//   it needs you. Groups with nothing on Home aren't shown.
// - One mark per row (markOf): new, needs you, working, queued, done.
// - A chip: a blue dot while it holds a new task, an orange one while something in it needs you.
export type Status = 'running' | 'needs' | 'done';
export type TaskType = { id: string; label: string };

export const AGENTS: Record<Agent, { name: string; brand: Brand }> = {
  claude: { name: 'Claude Code', brand: BRANDS.claude },
  codex: { name: 'Codex', brand: BRANDS.openai },
  cursor: { name: 'Cursor', brand: BRANDS.cursor },
};

// What a task needs from you: an inbox item (its options are what the API offers for its kind),
// or, for a job that failed with no item, letting it go.
// A `confirm` item (obid only, #546) is headed by its title, which says exactly what Confirm does;
// the words it would send for the owner are `quoted`, shown as data, and nothing is recommended.
export type Ask = {
  kind: string;
  headline: string;
  text: string;
  options: string[];
  recommended?: number;
  detail?: string;
  quoted?: string;    // words someone else wrote, shown as quoted data
  item?: string;      // the inbox item that settles it, if any
  later: boolean;     // put off, still open
  answer?: string;    // answered from this page, until obid settles it
  source?: string;    // a plug-in's event: where it came from (`plugin.id`)
};
export const ASK_LABEL: Record<string, string> = {
  question: 'Question', permission: 'Permission', review: 'Out of reviews', failed: 'Failed',
  limit: 'Out of usage', start: 'Start it?', merge: 'Not merged', obiRequest: 'Another Oby asks',
  pluginEvent: 'From a plug-in', audit: 'Issue audit', failure: 'Oby failure', confirm: 'Confirm it?',
};
// obid's own alerting sources, by their tools' names (#1127, #1311, #1312)
export const SOURCE_LABEL: Record<string, string> = {
  sentry: 'Sentry', alertmanager: 'Prometheus', grafana: 'Grafana', pagerduty: 'PagerDuty', datadog: 'Datadog',
};
// A decision's label: a plug-in's event says where it came from
export const askLabel = (ask: Pick<Ask, 'kind' | 'source'>): string =>
  ask.kind === 'pluginEvent' && ask.source
    ? SOURCE_LABEL[ask.source] ?? `From the ${ask.source} plug-in`
    : ASK_LABEL[ask.kind] ?? ask.kind;
// an open offer to look into an alert or fix a ticket: Issues' work, as Sangam's design lists an
// outside incident; put off, it's the inbox's (as on the Mac)
const isOffer = (i: InboxItem) =>
  i.kind === 'pluginEvent' && i.state !== 'later' && i.options.some((o) => o === 'Look into it' || o === 'Fix it');

// A job as the screens show it. created and finished are minutes ago.
export type JobView = {
  id: string;
  agent: Agent | null;     // null: an inbox decision with no job
  account: string;
  model: string;
  repo: string;
  branch: string;
  base: string;
  check?: string;
  status: JobStatus;
  step: string;
  round?: [number, number];
  stages: Stage[];
  ask?: Ask;            // the first of asks
  asks: Ask[];          // every decision it needs from you, oldest first: a permission and a confirm about it both show
  summary?: string;
  commits?: number;
  published?: string;     // the pull request's URL
  request: string;
  notes: string[];
  created: number;
  finished?: number;
};
export type Task = { id: string; type: string; title: string; who?: string; brand: Brand; status: Status; fresh: boolean; job: JobView };

// The kinds of work, as Sangam's design has them (design/app tasks.ts), each teammate's group
// between Issues and Tasks
const KINDS: TaskType[] = [
  { id: 'review', label: 'Review PR' },
  { id: 'issues', label: 'Issues' },
  { id: 'tasks', label: 'Tasks' },
  { id: 'inbox', label: 'Inbox' },
];
const TEAMMATE = 'from:';
const teammate = (owner: string): TaskType => ({ id: `${TEAMMATE}${owner}`, label: owner });
const ownerOf = (who: string | undefined | null) => (who && who.trim() ? who.trim() : undefined);
const typeOf = (j: Job) => {
  const owner = ownerOf(j.obi?.fromOwner);
  return owner ? teammate(owner).id : j.kind === 'review' ? 'review' : j.issue != null ? 'issues' : 'tasks';
};

const minutesAgo = (iso: string | null | undefined, now: number) => (iso ? Math.max(0, (now - Date.parse(iso)) / 60_000) : undefined);
const accountName = (s: Live, j: Job) => s.status?.accounts.find((a) => a.id === j.account)?.name ?? j.account;
const modelOf = (s: Live, j: Job) => j.model ?? s.status?.models[j.agent]?.model ?? 'default';

// An inbox item as a decision; the job's permission's detail goes with a permission item
function itemAsk(s: Live, item: InboxItem, j?: Job): Ask {
  const base = { kind: item.kind, options: item.options, item: item.id, later: item.state === 'later', answer: s.answering[item.id] };
  // what Confirm does, in obid's words, over why it waits; never a recommendation: it's the owner's call
  if (item.kind === 'confirm') return { ...base, headline: item.title, text: item.text, quoted: confirmWords(item) };
  // Oby's plain-words headline over the item's text; with none (obid writes none yet), the text
  return {
    ...base, headline: item.headline ?? item.text, text: item.headline ? item.text : '', recommended: item.recommended ?? undefined,
    detail: item.kind === 'permission' ? j?.permission?.detail : undefined,
  };
}

// the words a confirm item would send for the owner (another Oby's question's answer, or an
// item's), from its payload
function confirmWords(item: InboxItem): string | undefined {
  const payload = item.confirm?.payload as { words?: unknown; answer?: unknown } | null | undefined;
  const words = payload?.words ?? payload?.answer;
  return typeof words === 'string' && words.trim() ? words : undefined;
}

function asksOf(s: Live, j: Job): Ask[] {
  // every open item of the job, oldest first: a confirm item about its permission doesn't hide it
  const items = s.inbox.filter((i) => i.job === j.id);
  if (items.length) return items.map((i) => itemAsk(s, i, j));
  // failed or interrupted, not let go: it needs you even with no item (docs/runner-api.md, "What needs you")
  if ((j.status === 'failed' || j.status === 'interrupted') && !j.dismissed) {
    return [{ kind: 'failed', headline: j.status === 'failed' ? 'It failed' : 'It was interrupted', text: j.summary.split('\n')[0] || j.step, options: ['Dismiss'], later: false }];
  }
  return [];
}

export function toTask(s: Live, j: Job, now = Date.now()): Task {
  const asks = asksOf(s, j);
  const ask = asks[0];
  const status: Status = ask ? 'needs' : j.status === 'queued' || j.status === 'running' ? 'running' : 'done';
  const view: JobView = {
    id: j.id, agent: j.agent, account: accountName(s, j), model: modelOf(s, j), repo: j.repo, branch: j.branch || '—',
    base: j.base ?? '—', check: j.check ?? undefined, status: j.status, step: j.step,
    round: j.rounds > 1 ? [j.round, j.rounds] : undefined, stages: j.pipeline?.stages ?? [], ask, asks,
    summary: j.summary || undefined, commits: j.commits ?? undefined, published: j.published ?? undefined,
    request: j.request, notes: j.notes ?? [], created: minutesAgo(j.created, now)!, finished: minutesAgo(j.finished, now),
  };
  return {
    id: j.id, type: typeOf(j), title: j.title, who: ownerOf(j.obi?.fromOwner), brand: AGENTS[j.agent]?.brand ?? BRANDS.claude, status,
    fresh: !s.firstJobs.has(j.id) && !s.seen.has(j.id), job: view,
  };
}

// An inbox decision that belongs to no job: another Oby's request (its teammate's group), a
// plug-in's event (Inbox)
function itemTask(s: Live, i: InboxItem, now: number): Task {
  const owner = i.kind === 'obiRequest' ? ownerOf(i.obi?.fromOwner) : undefined;
  const ask: Ask = i.kind === 'confirm' ? itemAsk(s, i) : {
    kind: i.kind, headline: i.headline ?? i.title, text: i.text, options: i.options, recommended: i.recommended ?? undefined, item: i.id,
    later: i.state === 'later', answer: s.answering[i.id], source: i.plugin?.id ?? undefined,
  };
  return {
    // (no agent's mark: it shows Oby's, TaskMark)
    id: `inbox:${i.id}`, type: owner ? teammate(owner).id : isOffer(i) ? 'issues' : 'inbox', title: ask.headline, who: owner, brand: BRANDS.github, status: 'needs',
    fresh: false,
    job: {
      id: i.id, agent: null, account: '', model: '', repo: '', branch: '—', base: '—', status: 'queued', step: '', stages: [],
      ask, asks: [ask], request: i.text, notes: [], created: minutesAgo(i.created, now)!,
    },
  };
}

// Every task, newest first
export function tasksFrom(s: Live, now = Date.now()): Task[] {
  const jobs = Object.values(s.jobs).sort((a, b) => b.created.localeCompare(a.created)).map((j) => toTask(s, j, now));
  const loose = s.inbox.filter((i) => !i.job).map((i) => itemTask(s, i, now));
  return [...loose, ...jobs];
}

let cache: { s: Live; tasks: Task[] } | null = null;
const derive = (s: Live) => {
  if (cache?.s !== s) cache = { s, tasks: tasksFrom(s) };
  return cache.tasks;
};
// every task; components that call it re-render when anything changes
export const useTasks = () => derive(useLive());

// When done tasks leave Home for the archive: how long after they're done (remembered in this
// browser), or once Clear done was pressed on any app (`clearedAt`).
export const ARCHIVE_AFTER = [
  { id: '1d', label: 'After a day', min: 24 * 60 },
  { id: '3d', label: 'After 3 days', min: 3 * 24 * 60 },
  { id: '1w', label: 'After a week', min: 7 * 24 * 60 },
  { id: 'never', label: 'Never', min: Infinity },
];
let archiveAfter = (() => { try { return localStorage.getItem('oby.archiveAfter') || '3d'; } catch { return '3d'; } })();
const archiveListeners = new Set<() => void>();
export const getArchiveAfter = () => archiveAfter;
export function setArchiveAfter(id: string) {
  archiveAfter = id;
  try { localStorage.setItem('oby.archiveAfter', id); } catch { /* not remembered, that's all */ }
  archiveListeners.forEach((l) => l());
}
export const onArchiveAfter = (l: () => void) => { archiveListeners.add(l); return () => { archiveListeners.delete(l); }; };

// every task, as of `now` (the page's own clock unless a test gives one)
const all = (s: Live, now?: number) => (now === undefined ? derive(s) : tasksFrom(s, now));
const archived = (s: Live, t: Task) => {
  if (t.status !== 'done') return false;
  const job = s.jobs[t.id];
  if (s.clearedAt && job?.finished && job.finished <= s.clearedAt) return true;
  return (t.job.finished ?? t.job.created) > (ARCHIVE_AFTER.find((a) => a.id === archiveAfter)?.min ?? Infinity);
};
const onHome = (s: Live, now?: number) => all(s, now).filter((t) => !archived(s, t));

// The archive: done tasks that have left Home, most recently done first
export type Archived = { id: string; type: string; title: string; agent: Agent | null; finished: number };
export const archivedTasks = (s: Live): Archived[] => derive(s).filter((t) => archived(s, t))
  .map((t) => ({ id: t.id, type: t.type, title: t.title, agent: t.job.agent, finished: t.job.finished ?? t.job.created }))
  .sort((a, b) => a.finished - b.finished);

// Top of each list: fresh tasks, then ones that need you, then ones waiting to start; the rest
// after, newest first.
const rank = (t: Task) => (t.fresh ? 0 : t.status === 'needs' ? 1 : t.job.status === 'queued' ? 2 : 3);
const ranked = (list: Task[]) => list.map((t, i) => [t, i] as const).sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1]).map(([t]) => t);
export const tasksWith = (s: Live, status: Status, now?: number) => ranked(onHome(s, now).filter((t) => t.status === status));
export const tasksOf = (s: Live, type: string, now?: number) => ranked(onHome(s, now).filter((t) => t.type === type));
export const countOf = (s: Live, status: Status, type?: string) => onHome(s).filter((t) => t.status === status && (!type || t.type === type)).length;
// a kind of work's count: its tasks not done yet, running or needing you
export const openOf = (s: Live, type: string) => countOf(s, 'running', type) + countOf(s, 'needs', type);
export const hasFresh = (s: Live, type: string) => tasksOf(s, type).some((t) => t.fresh);
// the kinds with anything on Home, in their order: the teammates' groups (by name) after Issues
export const typesOn = (s: Live, now?: number): TaskType[] => {
  const on = new Set(onHome(s, now).map((t) => t.type));
  const mates = [...on].filter((id) => id.startsWith(TEAMMATE)).sort((a, b) => a.localeCompare(b)).map((id) => typeById(id));
  const kinds = KINDS.filter((t) => on.has(t.id));
  const at = kinds.findIndex((t) => t.id === 'tasks' || t.id === 'inbox');
  return at < 0 ? [...kinds, ...mates] : [...kinds.slice(0, at), ...mates, ...kinds.slice(at)];
};
export const typeById = (id: string): TaskType =>
  id.startsWith(TEAMMATE) && id.length > TEAMMATE.length ? teammate(id.slice(TEAMMATE.length)) : KINDS.find((t) => t.id === id) ?? KINDS[2];
export const typeLabel = (id: string) => typeById(id).label;

// The side panel's groups: by kind of work, or by status. count: a kind's open tasks, or all of a
// status's; needs: how many need you (its orange dot)
export type GroupBy = 'type' | 'status';
export type Group = { id: string; label: string; tasks: Task[]; count: number; countLabel: 'open' | 'tasks'; needs: number };
const STATUSES = [['needs', 'Needs you'], ['running', 'Running'], ['done', 'Completed']] as const;
export function groupsOf(s: Live, by: GroupBy, now?: number): Group[] {
  const groups: Group[] = by === 'type'
    ? typesOn(s, now).map((t) => {
      const list = tasksOf(s, t.id, now);
      return { id: t.id, label: t.label, tasks: list, count: list.filter((k) => k.status !== 'done').length, countLabel: 'open', needs: list.filter((k) => k.status === 'needs').length };
    })
    : STATUSES.map(([id, label]) => {
      const list = tasksWith(s, id, now);
      return { id: `status:${id}`, label, tasks: list, count: list.length, countLabel: 'tasks', needs: id === 'needs' ? list.length : 0 };
    });
  return groups.filter((g) => g.tasks.length > 0);
}
// A group's rows: everything still open, then its done tasks, most recently done first: the latest
// 3 (5 in Completed) unless it shows them all (Show more); hidden: how many Show more adds
export function shownOf(g: { id: string; tasks: Task[] }, all: boolean): { rows: Task[]; hidden: number } {
  const open = g.tasks.filter((t) => t.status !== 'done');
  const done = g.tasks.filter((t) => t.status === 'done').map((t, i) => [t, i] as const)
    .sort(([a, i], [b, k]) => (a.job.finished ?? a.job.created) - (b.job.finished ?? b.job.created) || i - k).map(([t]) => t);
  const keep = g.id === 'status:done' ? 5 : 3;
  return { rows: all ? [...open, ...done] : [...open, ...done.slice(0, keep)], hidden: Math.max(0, done.length - keep) };
}

// A task's one mark, wherever it's listed: new (blue, until opened), needs you (orange), working,
// queued (no mark: being listed unstarted says it), done (a check). live: where you're looking
// at it already, so not new.
export type Mark = 'new' | 'needs' | 'working' | 'queued' | 'done';
export const markOf = (t: Task, live = false): Mark =>
  !live && t.fresh ? 'new' : t.status === 'needs' ? 'needs' : t.status === 'done' ? 'done' : t.job.status === 'queued' ? 'queued' : 'working';
// A kind's chip on Home: a blue dot while it holds a new task, an orange one while anything in it
// needs you; both can show
export const chipOf = (s: Live, type: string) => ({ fresh: hasFresh(s, type), needs: countOf(s, 'needs', type) > 0 });

// Group by, from Home's ⋮: Type unless Status was picked, remembered in this browser
const GROUP_BY = 'oby.groupBy';
export const readGroupBy = (): GroupBy => { try { return localStorage.getItem(GROUP_BY) === 'status' ? 'status' : 'type'; } catch { return 'type'; } };
let groupBy = readGroupBy();
const groupByListeners = new Set<() => void>();
export const getGroupBy = () => groupBy;
export function setGroupBy(by: GroupBy) {
  groupBy = by;
  try { localStorage.setItem(GROUP_BY, by); } catch { /* not remembered, that's all */ }
  groupByListeners.forEach((l) => l());
}
export const onGroupBy = (l: () => void) => { groupByListeners.add(l); return () => { groupByListeners.delete(l); }; };
// A kind of work's two tabs: Running holds everything not done, what needs you included; and Done.
export type Tab = 'running' | 'done';
const tabOf = (t: Task): Tab => (t.status === 'done' ? 'done' : 'running');
export const tasksIn = (s: Live, type: string, tab: Tab) => tasksOf(s, type).filter((t) => tabOf(t) === tab);
// the tab it opens on: where the new task is, else Running when anything's open, else Done
export const firstTab = (s: Live, type: string): Tab => {
  const f = tasksOf(s, type).find((t) => t.fresh);
  return f ? tabOf(f) : openOf(s, type) ? 'running' : countOf(s, 'done', type) ? 'done' : 'running';
};

// who has it, as one line: "Claude Code · Personal · oby"
export function metaOf(t: Task) {
  const j = t.job;
  if (!j.agent) return j.ask?.kind === 'pluginEvent' ? askLabel(j.ask) : ASK_LABEL[j.ask?.kind ?? ''] ?? 'Inbox';
  const repo = j.repo.includes('/') ? j.repo.split('/')[1] : j.repo;
  return [AGENTS[j.agent]?.name ?? j.agent, j.account, repo].filter(Boolean).join(' · ');
}

// how long ago: now, minutes under an hour, hours under a day, then days
export const ago = (min: number) => (min < 1 ? 'now' : min < 60 ? `${Math.round(min)}m` : min < 24 * 60 ? `${Math.floor(min / 60)}h` : `${Math.floor(min / 1440)}d`);
