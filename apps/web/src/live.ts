import { useSyncExternalStore } from 'react';
import { ApiError, EVENT_NAMES, api, parseEvent, type Event, type InboxItem, type Job, type Question, type Status, type Step, type Turn } from './api';

// What obid has, as this page knows it, kept live by its event stream (docs/runner-api.md,
// "GET /v1/events"): the status, the jobs, the open inbox, the conversation, and the plan this
// page is waiting on. One snapshot, replaced on every change; components read it with useLive().
export type Connection = 'connecting' | 'live' | 'down';
export type Live = {
  connection: Connection;
  problem: string | null;      // why it's down, or what last went wrong (a line to show)
  status: Status | null;
  jobs: Record<string, Job>;
  firstJobs: Set<string>;      // the jobs the page found on opening: never "new"
  seen: Set<string>;           // jobs opened since
  inbox: InboxItem[];          // open and put-off items
  turns: Turn[];               // the conversation, oldest first
  older: boolean;              // turns before the first one shown
  thinking: boolean;           // a plan from this page is under way
  steps: Step[];               // what the turn under way is doing
  waiting: { said: string; question: Question } | null;  // Oby's question back, until answered
  answering: Record<string, string>;  // a decision answered from this page, by task id, until it's settled
  clearedAt: string | null;
};

const PAGE = 100;
let state: Live = {
  connection: 'connecting', problem: null, status: null, jobs: {}, firstJobs: new Set(), seen: new Set(),
  inbox: [], turns: [], older: false, thinking: false, steps: [], waiting: null, answering: {}, clearedAt: null,
};
const listeners = new Set<() => void>();
const set = (patch: Partial<Live>) => { state = { ...state, ...patch }; listeners.forEach((l) => l()); };
const subscribe = (l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; };
export const useLive = () => useSyncExternalStore(subscribe, () => state);
export const live = () => state;

// "how long ago" labels move on while nothing changes
setInterval(() => set({}), 30_000);

const byAt = (a: Turn, b: Turn) => a.at.localeCompare(b.at);
const isOpen = (i: InboxItem) => i.state !== 'done';

// One event over a snapshot
export function apply(s: Live, e: Event): Live {
  switch (e.kind) {
    case 'job':
      return { ...s, jobs: { ...s.jobs, [e.job.id]: e.job } };
    case 'inbox': {
      const rest = s.inbox.filter((i) => i.id !== e.item.id);
      const settled = !isOpen(e.item);
      const answering = settled && e.item.job ? omit(s.answering, e.item.job) : s.answering;
      return { ...s, inbox: settled ? rest : [...rest, e.item].sort((a, b) => a.created.localeCompare(b.created)), answering };
    }
    case 'turn': {
      const rest = s.turns.filter((t) => t.id !== e.turn.id);
      return { ...s, turns: [...rest, e.turn].sort(byAt) };
    }
    case 'step':
      if (!s.thinking) return s;
      return { ...s, steps: [...s.steps.filter((x) => !(x.turn === e.step.turn && x.index === e.step.index)), e.step] };
    case 'accounts':
      return s.status ? { ...s, status: { ...s.status, accounts: e.accounts } } : s;
    case 'clear':
      return { ...s, clearedAt: e.clearedAt };
  }
}
const omit = <T,>(r: Record<string, T>, key: string) => { const { [key]: _, ...rest } = r; return rest; };

// The stream first, then what to show once its response has arrived, with the events that came
// meanwhile applied over it: the runner follows a connection before it answers, so nothing that
// changes in between is lost.
let source: EventSource | null = null;
let pending: Event[] | null = null;
let retry = 0;

export function connect() {
  if (source) return;
  set({ connection: 'connecting' });
  const es = new EventSource('/v1/events');
  source = es;
  for (const name of EVENT_NAMES) {
    es.addEventListener(name, (m) => {
      const e = parseEvent(name, (m as MessageEvent<string>).data);
      if (!e) return;
      if (pending) pending.push(e);
      else set(apply(state, e));
    });
  }
  es.onopen = () => { void sync(); };
  es.onerror = () => {
    // closed for good (an HTTP error, like a session that ended): start again after a moment;
    // otherwise the browser is reconnecting by itself
    if (es.readyState === EventSource.CLOSED) {
      source = null;
      set({ connection: 'down' });
      void signedIn().then(() => setTimeout(connect, Math.min(30_000, 1000 * 2 ** retry++)));
    } else set({ connection: 'connecting' });
  };
}

async function sync() {
  pending = [];
  try {
    const [status, jobs, inbox, turns] = await Promise.all([api.status(), api.jobs(PAGE), api.inbox(), api.conversation({ limit: PAGE })]);
    const first = state.status ? state.firstJobs : new Set(jobs.map((j) => j.id));
    let next: Live = {
      ...state, connection: 'live', problem: null, status, firstJobs: first, clearedAt: status.clearedAt,
      jobs: { ...state.jobs, ...Object.fromEntries(jobs.map((j) => [j.id, j])) },
      inbox: inbox.filter(isOpen), turns: [...turns].sort(byAt), older: turns.length >= PAGE,
    };
    for (const e of pending) next = apply(next, e);
    pending = null;
    retry = 0;
    set(next);
    void fetchMissing();
  } catch (e) {
    pending = null;
    lost(e);
  }
}

// The page's session ended (obid's token changed, or it signed out elsewhere): open the page
// again, which is then obid's sign-in form. Not more than once a minute, should something else
// answer 401.
async function signedIn() {
  try { await api.status(); } catch (e) { lost(e); }
}
function lost(e: unknown) {
  if (e instanceof ApiError && e.status === 401) {
    const last = Number(sessionStorage.getItem('oby.reloaded') || 0);
    if (Date.now() - last > 60_000) {
      sessionStorage.setItem('oby.reloaded', String(Date.now()));
      location.reload();
      return;
    }
  }
  set({ connection: 'down', problem: e instanceof Error ? e.message : String(e) });
}

// Jobs the inbox or the conversation names that aren't among the latest: fetched one by one
// (GET /v1/jobs/{id} answers any job the runner ever had).
const asked = new Set<string>();
async function fetchMissing() {
  const ids = new Set([...state.inbox.map((i) => i.job), ...state.turns.flatMap((t) => t.jobs)]);
  for (const id of ids) {
    if (!id || state.jobs[id] || asked.has(id)) continue;
    asked.add(id);
    try {
      const job = await api.job(id);
      set({ jobs: { ...state.jobs, [job.id]: job } });
    } catch { /* gone: nothing to show for it */ }
  }
}

// What a call that went wrong says, for a moment
let clearing = 0;
export function say(problem: string) {
  set({ problem });
  clearTimeout(clearing);
  clearing = window.setTimeout(() => { if (state.connection === 'live') set({ problem: null }); }, 6000);
}
const failed = (e: unknown) => say(e instanceof Error ? e.message : String(e));

// --- What the page does

// Words to Oby (POST /v1/plans): a reply, a question back, or work that starts. Your words and
// its answer come into the conversation as `turn` events; jobs it started, as `job` events.
export async function ask(said: string, answer?: { question: string; option: string }) {
  const words = said.trim();
  if (!words || state.thinking) return;
  set({ thinking: true, steps: [], waiting: null });
  try {
    const a = await api.plan(words, answer);
    if (a.jobs.length) set({ jobs: { ...state.jobs, ...Object.fromEntries(a.jobs.map((j) => [j.id, j])) } });
    if (a.kind === 'question') set({ waiting: { said: a.said, question: a.question } });
    // the stream down meanwhile: the conversation as it is now
    if (state.connection !== 'live') set({ turns: (await api.conversation({ limit: PAGE })).sort(byAt) });
  } catch (e) {
    failed(e);
  } finally {
    set({ thinking: false, steps: [] });
  }
}
// Oby's question answered: with one of its options, or in your own words
export function answerQuestion(option: string) {
  const w = state.waiting;
  if (!w || !option.trim()) return;
  void ask(w.said, { question: w.question.text, option: option.trim() });
}

// The turns before the first one shown
export async function loadOlder() {
  const first = state.turns[0];
  if (!first) return;
  try {
    const turns = await api.conversation({ before: first.id, limit: PAGE });
    set({ turns: [...turns, ...state.turns].sort(byAt), older: turns.length >= PAGE });
    void fetchMissing();
  } catch (e) { failed(e); }
}

// Told the job's agent something (POST /v1/jobs/{id}/messages)
export async function tellJob(id: string, text: string) {
  const t = text.trim();
  if (!t) return;
  try {
    const job = await api.message(id, t);
    set({ jobs: { ...state.jobs, [job.id]: job } });
  } catch (e) { failed(e); }
}

export async function stopJob(id: string) {
  try {
    const job = await api.stop(id);
    set({ jobs: { ...state.jobs, [job.id]: job } });
  } catch (e) { failed(e); }
}

export async function dismissJob(id: string) {
  try {
    const job = await api.dismiss(id);
    set({ jobs: { ...state.jobs, [job.id]: job } });
  } catch (e) { failed(e); }
}

// A decision answered (POST /v1/inbox/{id}/answer): Later puts it off an hour
export async function answerItem(taskId: string, itemId: string, option: string) {
  set({ answering: { ...state.answering, [taskId]: option } });
  try {
    const body = option === 'Later' ? { later: new Date(Date.now() + 3600_000).toISOString().replace(/\.\d+Z$/, 'Z') } : { answer: option };
    const item = await api.answer(itemId, body);
    set(apply(state, { kind: 'inbox', item }));
    if (option === 'Later') set({ answering: omit(state.answering, taskId) });
  } catch (e) {
    set({ answering: omit(state.answering, taskId) });
    failed(e);
  }
}

export function markSeen(id: string) {
  if (state.seen.has(id)) return;
  set({ seen: new Set([...state.seen, id]) });
}
