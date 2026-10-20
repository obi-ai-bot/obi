import { useSyncExternalStore } from 'react';
import { BRANDS, type Brand } from './brands';
import { AGENTS, ARCHIVE, GITHUB_WORK, JOBS, hasAttachments, type Archived, type Attachments, type GitHubItem, type Job, type Message } from './mock';
import { streamWords } from './stream';

// Tasks are Oby's jobs (mock.ts) as Home shows them. Each belongs to a kind of
// work (the chips on Home, the groups in the side panel) and is running,
// needs you, or done. who: the person it's for (a PR review's author),
// shown before the title. fresh: just added and not opened yet, the only
// tasks with a blue dot (on the task, its tab and its kind of work's chip).
export type Status = 'running' | 'needs' | 'done';
export type TaskType = { id: string; label: string };
// said: the conversation since it opened (what you told the agent, from the
// card or the chat, and Oby's replies), oldest first; typing: Oby is writing
// one; answer: what you picked on its decision.
export type Task = { id: string; type: string; title: string; who?: string; brand: Brand; status: Status; fresh?: boolean; job: Job; said?: Message[]; typing?: boolean; answer?: string };

export const TYPES: TaskType[] = [
  { id: 'review', label: 'Review PR' },
  { id: 'issues', label: 'Issues' },
  { id: 'wellington', label: 'Wellington' },
  { id: 'tasks', label: 'Tasks' },
  { id: 'routines', label: 'Routines' },
];

// anything with a decision for you needs you, whatever the agent is doing.
// Queued counts as running: it starts by itself, with nothing for you to do.
const statusOf = (j: Job): Status =>
  j.ask ? 'needs' : j.status === 'queued' || j.status === 'running' ? 'running' : 'done';
const toTask = (j: Job, fresh = false): Task => ({
  id: j.id, type: j.type, title: j.title, who: j.who, status: statusOf(j), fresh, job: j,
  // where it came from; asked in Oby, the agent that took it
  brand: j.from ?? AGENTS[j.agent].brand,
});

// the mock's newest task starts out fresh, so there's a blue dot to see
let tasks: Task[] = JOBS.map((j) => toTask(j, j.id === 't1'));
const listeners = new Set<() => void>();
const set = (next: Task[]) => { tasks = next; listeners.forEach((l) => l()); };
const subscribe = (l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; };

// every task; components that call it re-render when one is added or opened
export const useTasks = () => useSyncExternalStore(subscribe, () => tasks);

// Asked in the message box: a new task in Tasks, queued, fresh, at the top.
// A follow-up asked in a done task's conversation goes with it instead: same
// kind of work, agent, account and repo. Returns the new task's id.
let added = 0;
export function addTask(text: string, after?: Task) {
  const request = text.trim();
  if (!request) return;
  // named after its first line (the rest stays in the request)
  const line = request.split('\n')[0].trim();
  const title = line.length > 60 ? `${line.slice(0, 57).trimEnd()}…` : line;
  const p = after?.job;
  const id = `n${++added}`;
  set([toTask({
    id, type: after?.type ?? 'tasks', title: title[0].toUpperCase() + title.slice(1), request,
    agent: p?.agent ?? 'claude', account: p?.account ?? 'Personal', model: p?.model ?? 'Opus 5.5',
    repo: p?.repo ?? '—', branch: '—', base: p?.base ?? '—',
    status: 'queued', step: 'Getting ready',
    stages: [{ id: 'prepare', title: 'Prepare', detail: 'Clone and worktree', state: 'current' }, { id: 'work', title: 'Work', state: 'upcoming' }],
    created: 0,
  }, true), ...tasks]);
  return id;
}
// opened: its blue dot goes
export function markSeen(id: string) {
  if (tasks.some((t) => t.id === id && t.fresh)) set(tasks.map((t) => (t.id === id ? { ...t, fresh: false } : t)));
}

// a task changed in place
const update = (id: string, fn: (t: Task) => Partial<Task>) => set(tasks.map((k) => (k.id === id ? { ...k, ...fn(k) } : k)));
const say = (id: string, m: Message) => update(id, (k) => ({ said: [...(k.said ?? []), m] }));
// Oby answers after a moment of typing, as it would while it reads the message
const REPLY_MS = 3000;
// Its words come in a word at a time (stream.ts); what it started (start: its
// cards) once they're all in, so the cards and the side panel's rows show together.
function reply(id: string, text: () => string, start?: () => string[] | undefined) {
  update(id, () => ({ typing: true }));
  setTimeout(async () => {
    let at = 0;
    update(id, (k) => { at = k.said?.length ?? 0; return { typing: false, said: [...(k.said ?? []), { who: 'oby', text: '', ago: 0, streaming: true }] }; });
    const edit = (fn: (m: Message) => Message) => update(id, (k) => ({ said: k.said?.map((x, i) => (i === at ? fn(x) : x)) }));
    await streamWords(text(), edit);
    const jobs = start?.();
    edit((x) => ({ ...x, streaming: undefined, jobs }));
  }, REPLY_MS);
}

// Told the agent something: it goes on the end of the task's conversation, and
// Oby says what it did with it. Running, it's passed on; still waiting on your
// decision, it's passed on with a nudge; done, it starts a follow-up task,
// whose card shows under Oby's reply.
export function tell(id: string, text: string, att?: Attachments) {
  const t = text.trim(), r = relay(id, t);
  if ((!t && !hasAttachments(att)) || !r) return;
  say(id, { who: 'you', text: t, ago: 0, ...att });
  reply(id, () => r.line, r.start);
}
// What Oby says to something you told it about a task, wherever you said it (its
// thread, or the conversation it was started in); start: the follow-up a done
// one gets, its card and its row showing together as Oby says so
export function relay(id: string, text: string): { line: string; start?: () => string[] | undefined } | undefined {
  const k = tasks.find((x) => x.id === id);
  if (!k) return;
  const agent = AGENTS[k.job.agent].name;
  if (k.status === 'done') {
    const repo = k.job.repo.includes('/') ? ` in ${k.job.repo.split('/')[1]}` : '';
    return {
      line: `This one’s finished, so I started a follow-up. ${agent} has it${repo} on ${k.job.account}.`,
      start: () => { const next = addTask(text, k); return next ? [next] : undefined; },
    };
  }
  if (k.status === 'needs' && !k.answer) return { line: `Passed to ${agent}. It’s still waiting on your call before it carries on.` };
  return { line: `Passed to ${agent}. It’ll pick that up after ${k.job.round ? 'this round' : 'its current step'}.` };
}
// Picked an answer to its decision: it shows as your reply, and Oby confirms.
// (Kept until the mock has somewhere to send it; the task stays as it was.)
export function answer(id: string, option: string) {
  const k = tasks.find((x) => x.id === id);
  if (!k) return;
  update(id, () => ({ answer: option }));
  say(id, { who: 'you', text: option, ago: 0 });
  const agent = AGENTS[k.job.agent].name;
  reply(id, () => (option === 'Later' ? 'Okay, it’ll wait. I’ll bring it back up in an hour.' : `Got it. ${agent} will go with that.`));
}

// Stopped by you: it ends where it was, with nothing left to decide, and moves to Done
export function stop(id: string) {
  update(id, (k) => ({
    status: 'done',
    job: { ...k.job, status: 'stopped', ask: undefined, step: 'Stopped', finished: 0, stages: k.job.stages.map((st) => (st.state === 'current' ? { ...st, state: 'skipped' } : st)) },
  }));
}

// the task renamed (its title on cards, rows and the trail)
export function renameTask(id: string, title: string) {
  const t = title.trim();
  if (t) update(id, () => ({ title: t }));
}
// out of Home: archived (it stays in Archive) or deleted (gone from Archive too)
export function remove(id: string) {
  set(tasks.filter((k) => k.id !== id));
}
const deleted = new Set<string>();
export function deleteTask(id: string) {
  deleted.add(id);
  remove(id);
}

// When done tasks leave Home for the archive: how long after they're done.
// Remembered; 3 days unless changed, so Friday's work is still on Home on Monday.
export const ARCHIVE_AFTER = [
  { id: '1d', label: 'After a day', min: 24 * 60 },
  { id: '3d', label: 'After 3 days', min: 3 * 24 * 60 },
  { id: '1w', label: 'After a week', min: 7 * 24 * 60 },
  { id: 'never', label: 'Never', min: Infinity },
];
let archiveAfter = (() => { try { return localStorage.getItem('oby.archiveAfter') || '3d'; } catch { return '3d'; } })();
export const getArchiveAfter = () => archiveAfter;
export function setArchiveAfter(id: string) {
  archiveAfter = id;
  try { localStorage.setItem('oby.archiveAfter', id); } catch { /* not remembered, that's all */ }
  set([...tasks]);
}
const isArchived = (t: Task) => t.status === 'done' && (t.job.finished ?? t.job.created) > (ARCHIVE_AFTER.find((a) => a.id === archiveAfter)?.min ?? Infinity);
// what's on Home: everything not archived
const onHome = () => tasks.filter((t) => !isArchived(t));
// The archive: tasks done longer ago than that, with the ones archived before
// (mock.ts), most recently done first; less any deleted
export const archivedTasks = (): Archived[] => [
  ...tasks.filter(isArchived).map((t) => ({ id: t.id, type: t.type, who: t.who, title: t.title, agent: t.job.agent, finished: t.job.finished ?? t.job.created })),
  ...ARCHIVE,
].filter((a) => !deleted.has(a.id)).sort((a, b) => a.finished - b.finished);

// Top of each list: fresh tasks, then ones that need you, then ones waiting to
// start; the rest after, in the order they came.
const rank = (t: Task) => (t.fresh ? 0 : t.status === 'needs' ? 1 : t.job.status === 'queued' ? 2 : 3);
// every task on Home in one state (the side panel grouped by status), in the same order
export const tasksWith = (status: Status) => onHome().filter((t) => t.status === status).sort((a, b) => rank(a) - rank(b));
export const tasksOf = (type: string) =>
  onHome().filter((t) => t.type === type).sort((a, b) => rank(a) - rank(b));
export const countOf = (status: Status, type?: string) =>
  onHome().filter((t) => t.status === status && (!type || t.type === type)).length;
// a kind of work's count: its tasks not done yet, running or needing you
export const openOf = (type: string) => countOf('running', type) + countOf('needs', type);
export const hasFresh = (type: string) => tasksOf(type).some((t) => t.fresh);
// A kind of work's tabs: Running holds everything not done, what needs you
// included (it's still running, only waiting on you); and Done. Review PR and
// Issues have To do first: GitHub's items no job works on yet, never counted
// as running.
export type Tab = 'todo' | 'running' | 'done';
const tabOf = (t: Task): Tab => (t.status === 'done' ? 'done' : 'running');
export const tasksIn = (type: string, tab: Tab) => (tab === 'todo' ? [] : tasksOf(type).filter((t) => tabOf(t) === tab));
export const hasToDo = (type: string) => type === 'review' || type === 'issues';
// the tab it opens on: where the new task is, else Running when anything's open,
// else To do when it holds something, else Done
export const firstTab = (type: string): Tab => {
  const f = tasksOf(type).find((t) => t.fresh);
  return f ? tabOf(f) : openOf(type) ? 'running' : toDoOf(type).length ? 'todo' : countOf('done', type) ? 'done' : 'running';
};

// GitHub's items waiting under To do, until started or put off (Later)
let waiting = GITHUB_WORK;
export const toDoOf = (type: string) => waiting.filter((g) => g.type === type).sort((a, b) => a.updated - b.updated);
// One group of To do: a project's board column, or the items on no board.
export type BoardColumn = { name?: string; project?: string; items: GitHubItem[] };
// work under way first, then what's next, the rest by name, no board last
const rankOf = (name?: string) => {
  if (!name) return 5;
  const at = ['in progress', 'in review', 'todo', 'backlog'].indexOf(name.toLowerCase());
  return at < 0 ? 4 : at;
};
export const columnsOf = (type: string): BoardColumn[] => {
  const columns: BoardColumn[] = [];
  for (const g of toDoOf(type)) {
    const c = columns.find((k) => k.name === g.board?.column && k.project === g.board?.project);
    if (c) c.items.push(g); else columns.push({ name: g.board?.column, project: g.board?.project, items: [g] });
  }
  return columns.sort((a, b) => rankOf(a.name) - rankOf(b.name) || (a.name ?? '').localeCompare(b.name ?? '') || (a.project ?? '').localeCompare(b.project ?? ''));
};
// Later takes it off the list for now; Review it / Fix it starts its job, queued
export function putOff(id: string) {
  waiting = waiting.filter((g) => g.id !== id);
  set([...tasks]);
}
export function startGitHub(id: string) {
  const g = waiting.find((k) => k.id === id);
  if (!g) return;
  waiting = waiting.filter((k) => k.id !== id);
  set([toTask({
    id: `s${id}`, type: g.type, who: g.who, title: g.title, from: BRANDS.github, request: g.request,
    agent: 'claude', account: 'Deskree', model: 'Opus 5.5', repo: `deskree-inc/${g.repo}`, branch: '—', base: 'dev',
    status: 'queued', step: 'Getting ready',
    stages: [{ id: 'prepare', title: 'Prepare', detail: 'Clone and worktree', state: 'current' }, { id: 'work', title: 'Work', state: 'upcoming' }],
    created: 0,
  }, true), ...tasks]);
}
