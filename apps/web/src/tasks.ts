import { BRANDS, type Brand } from './brands';
import type { Agent, InboxItem, Job, JobStatus, Stage } from './api';
import { useLive, type Live } from './live';

// Tasks are obid's jobs (and the inbox's decisions that belong to no job) as Home shows them.
// Each belongs to a kind of work (the chips on Home, the groups in the side panel) and is running,
// needs you, or done. fresh: arrived since the page opened and not opened yet, the only tasks
// with a blue dot.
export type Status = 'running' | 'needs' | 'done';
export type TaskType = { id: string; label: string };

export const AGENTS: Record<Agent, { name: string; brand: Brand }> = {
  claude: { name: 'Claude Code', brand: BRANDS.claude },
  codex: { name: 'Codex', brand: BRANDS.openai },
  cursor: { name: 'Cursor', brand: BRANDS.cursor },
};

// What a task needs from you: an inbox item (its options are what the API offers for its kind),
// or, for a job that failed with no item, letting it go.
export type Ask = {
  kind: string;
  headline: string;
  text: string;
  options: string[];
  recommended?: number;
  detail?: string;
  item?: string;      // the inbox item that settles it, if any
  later: boolean;     // put off, still open
};
export const ASK_LABEL: Record<string, string> = {
  question: 'Question', permission: 'Permission', review: 'Out of reviews', failed: 'Failed',
  limit: 'Out of usage', start: 'Start it?', merge: 'Not merged', obiRequest: 'Another Oby asks',
  pluginEvent: 'From a plug-in', audit: 'Issue audit', failure: 'Oby failure',
};

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
  ask?: Ask;
  summary?: string;
  commits?: number;
  published?: string;     // the pull request's URL
  request: string;
  notes: string[];
  created: number;
  finished?: number;
};
export type Task = { id: string; type: string; title: string; who?: string; brand: Brand; status: Status; fresh: boolean; job: JobView; answer?: string };

// The kinds of work, until #496 groups them as Sangam's design does: reviews, issues, the rest;
// and decisions in the inbox that belong to no job.
const ALL_TYPES: TaskType[] = [
  { id: 'review', label: 'Reviews' },
  { id: 'issues', label: 'Issues' },
  { id: 'tasks', label: 'Tasks' },
  { id: 'inbox', label: 'Inbox' },
];
const typeOf = (j: Job) => (j.kind === 'review' ? 'review' : j.issue != null ? 'issues' : 'tasks');

const minutesAgo = (iso: string | null | undefined, now: number) => (iso ? Math.max(0, (now - Date.parse(iso)) / 60_000) : undefined);
const accountName = (s: Live, j: Job) => s.status?.accounts.find((a) => a.id === j.account)?.name ?? j.account;
const modelOf = (s: Live, j: Job) => j.model ?? s.status?.models[j.agent]?.model ?? 'default';

function askOf(j: Job, item: InboxItem | undefined): Ask | undefined {
  if (item) {
    // Oby's plain-words headline over the item's text; with none (obid writes none yet), the text
    return {
      kind: item.kind, headline: item.headline ?? item.text, text: item.headline ? item.text : '', options: item.options,
      recommended: item.recommended ?? undefined, item: item.id, later: item.state === 'later',
      detail: item.kind === 'permission' ? j.permission?.detail : undefined,
    };
  }
  // failed or interrupted, not let go: it needs you even with no item (docs/runner-api.md, "What needs you")
  if ((j.status === 'failed' || j.status === 'interrupted') && !j.dismissed) {
    return { kind: 'failed', headline: j.status === 'failed' ? 'It failed' : 'It was interrupted', text: j.summary.split('\n')[0] || j.step, options: ['Dismiss'], later: false };
  }
  return undefined;
}

export function toTask(s: Live, j: Job, now = Date.now()): Task {
  const item = [...s.inbox].reverse().find((i) => i.job === j.id);
  const ask = askOf(j, item);
  const status: Status = ask ? 'needs' : j.status === 'queued' || j.status === 'running' ? 'running' : 'done';
  const view: JobView = {
    id: j.id, agent: j.agent, account: accountName(s, j), model: modelOf(s, j), repo: j.repo, branch: j.branch || '—',
    base: j.base ?? '—', check: j.check ?? undefined, status: j.status, step: j.step,
    round: j.rounds > 1 ? [j.round, j.rounds] : undefined, stages: j.pipeline?.stages ?? [], ask,
    summary: j.summary || undefined, commits: j.commits ?? undefined, published: j.published ?? undefined,
    request: j.request, notes: j.notes ?? [], created: minutesAgo(j.created, now)!, finished: minutesAgo(j.finished, now),
  };
  return {
    id: j.id, type: typeOf(j), title: j.title, brand: AGENTS[j.agent]?.brand ?? BRANDS.claude, status,
    fresh: !s.firstJobs.has(j.id) && !s.seen.has(j.id), job: view, answer: s.answering[j.id],
  };
}

// An inbox decision that belongs to no job (another Oby's request, a plug-in's event)
function itemTask(s: Live, i: InboxItem, now: number): Task {
  return {
    // (no agent's mark: it shows Oby's, TaskMark)
    id: `inbox:${i.id}`, type: 'inbox', title: i.headline ?? i.title, brand: BRANDS.github, status: 'needs',
    fresh: false, answer: s.answering[`inbox:${i.id}`],
    job: {
      id: i.id, agent: null, account: '', model: '', repo: '', branch: '—', base: '—', status: 'queued', step: '', stages: [],
      ask: { kind: i.kind, headline: i.headline ?? i.title, text: i.text, options: i.options, recommended: i.recommended ?? undefined, item: i.id, later: i.state === 'later' },
      request: i.text, notes: [], created: minutesAgo(i.created, now)!,
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

const archived = (s: Live, t: Task) => {
  if (t.status !== 'done') return false;
  const job = s.jobs[t.id];
  if (s.clearedAt && job?.finished && job.finished <= s.clearedAt) return true;
  return (t.job.finished ?? t.job.created) > (ARCHIVE_AFTER.find((a) => a.id === archiveAfter)?.min ?? Infinity);
};
const onHome = (s: Live) => derive(s).filter((t) => !archived(s, t));

// The archive: done tasks that have left Home, most recently done first
export type Archived = { id: string; type: string; title: string; agent: Agent | null; finished: number };
export const archivedTasks = (s: Live): Archived[] => derive(s).filter((t) => archived(s, t))
  .map((t) => ({ id: t.id, type: t.type, title: t.title, agent: t.job.agent, finished: t.job.finished ?? t.job.created }))
  .sort((a, b) => a.finished - b.finished);

// Top of each list: fresh tasks, then ones that need you, then ones waiting to start; the rest
// after, newest first.
const rank = (t: Task) => (t.fresh ? 0 : t.status === 'needs' ? 1 : t.job.status === 'queued' ? 2 : 3);
const ranked = (list: Task[]) => list.map((t, i) => [t, i] as const).sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1]).map(([t]) => t);
export const tasksWith = (s: Live, status: Status) => ranked(onHome(s).filter((t) => t.status === status));
export const tasksOf = (s: Live, type: string) => ranked(onHome(s).filter((t) => t.type === type));
export const countOf = (s: Live, status: Status, type?: string) => onHome(s).filter((t) => t.status === status && (!type || t.type === type)).length;
// a kind of work's count: its tasks not done yet, running or needing you
export const openOf = (s: Live, type: string) => countOf(s, 'running', type) + countOf(s, 'needs', type);
export const hasFresh = (s: Live, type: string) => tasksOf(s, type).some((t) => t.fresh);
// the kinds with anything on Home, in their order
export const typesOn = (s: Live) => ALL_TYPES.filter((t) => onHome(s).some((k) => k.type === t.id));
export const typeLabel = (id: string) => ALL_TYPES.find((t) => t.id === id)?.label ?? 'Tasks';
export const typeById = (id: string): TaskType => ALL_TYPES.find((t) => t.id === id) ?? ALL_TYPES[2];
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
  if (!j.agent) return ASK_LABEL[j.ask?.kind ?? ''] ?? 'Inbox';
  const repo = j.repo.includes('/') ? j.repo.split('/')[1] : j.repo;
  return [AGENTS[j.agent]?.name ?? j.agent, j.account, repo].filter(Boolean).join(' · ');
}

// how long ago: now, minutes under an hour, hours under a day, then days
export const ago = (min: number) => (min < 1 ? 'now' : min < 60 ? `${Math.round(min)}m` : min < 24 * 60 ? `${Math.floor(min / 60)}h` : `${Math.floor(min / 1440)}d`);
