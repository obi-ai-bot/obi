import { useSyncExternalStore } from 'react';
import { ApiError, api, keepToken, openEvents, parseEvent, sseReader, token, type Event, type InboxItem, type Job, type Question, type Status, type Step, type Turn } from './api';

// What obid has, as this page knows it, kept live by its event stream (docs/runner-api.md,
// "GET /v1/events"): the status, the jobs, the open inbox, the conversation, and the plan this
// page is waiting on. One snapshot, replaced on every change; components read it with useLive().
export type Connection = 'connecting' | 'live' | 'down';
export type Live = {
  signedIn: boolean;           // the page holds a token obid hasn't refused (SignIn.tsx asks otherwise)
  connection: Connection;
  problem: string | null;      // why it's down, or what last went wrong (a line to show)
  status: Status | null;
  jobs: Record<string, Job>;
  firstJobs: Set<string>;      // the jobs the page found on opening: never "new"
  seen: Set<string>;           // jobs opened since
  inbox: InboxItem[];          // open and put-off items
  turns: Turn[];               // the conversation it shows, oldest first
  shown: string | null;        // which conversation that is: the latest when the page opened, or
                               // the first it starts; null before there is one
  older: boolean;              // turns before the first one shown
  thinking: boolean;           // a plan from this page is under way
  steps: Step[];               // what the turn under way is doing
  waiting: { said: string; question: Question } | null;  // Oby's question back, until answered
  answering: Record<string, string>;  // a decision answered from this page, by task id, until it's settled
  clearedAt: string | null;
};

const PAGE = 100;
let state: Live = {
  signedIn: !!token(), connection: 'connecting', problem: null, status: null, jobs: {}, firstJobs: new Set(), seen: new Set(),
  inbox: [], turns: [], shown: null, older: false, thinking: false, steps: [], waiting: null, answering: {}, clearedAt: null,
};
const listeners = new Set<() => void>();
const set = (patch: Partial<Live>) => { state = { ...state, ...patch }; listeners.forEach((l) => l()); };
const subscribe = (l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; };
export const useLive = () => useSyncExternalStore(subscribe, () => state);
export const live = () => state;
// What the page knows, replaced whole (tests start from a state of their own)
export const load = (next: Live) => set(next);

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
      // obid keeps many conversations (#493) and this page shows one: a turn of another
      // (someone else started it) stays out of it. With none shown yet, the first one is it.
      const from = e.turn.conversation;
      if (from && s.shown && from !== s.shown) return s;
      const rest = s.turns.filter((t) => t.id !== e.turn.id);
      return { ...s, shown: s.shown ?? from ?? null, turns: [...rest, e.turn].sort(byAt) };
    }
    case 'conversationGone':
      // the conversation it shows was deleted elsewhere: nothing to show, and the next words start
      // or join the latest
      return e.id === s.shown ? { ...s, shown: null, turns: [], older: false } : s;
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

// Jobs an answer named (a plan's, a message's, a stop's), added only when the page doesn't know
// them yet: the event stream owns a job's state, and an answer's copy can be older than an event
// that came first (a plan's "queued" after the job's own event said it failed).
export function withNew(s: Live, jobs: Job[]): Live {
  const added = jobs.filter((j) => !s.jobs[j.id]);
  return added.length ? { ...s, jobs: { ...s.jobs, ...Object.fromEntries(added.map((j) => [j.id, j])) } } : s;
}

// What to show, fetched once the stream answered, with the events that came meanwhile applied
// over it in the order they came.
export type Snapshot = { status: Status; jobs: Job[]; inbox: InboxItem[]; turns: Turn[] };
export function synced(s: Live, snap: Snapshot, meanwhile: Event[]): Live {
  let next: Live = {
    ...s, connection: 'live', problem: null, status: snap.status, clearedAt: snap.status.clearedAt,
    firstJobs: s.status ? s.firstJobs : new Set(snap.jobs.map((j) => j.id)),
    jobs: { ...s.jobs, ...Object.fromEntries(snap.jobs.map((j) => [j.id, j])) },
    inbox: snap.inbox.filter(isOpen), turns: [...snap.turns].sort(byAt), older: snap.turns.length >= PAGE,
    shown: snap.turns[0]?.conversation ?? s.shown,
  };
  for (const e of meanwhile) next = apply(next, e);
  return next;
}

// The stream first, then what to show once its response has arrived, with the events that came
// meanwhile applied over it: the runner follows a connection before it answers, so nothing that
// changes in between is lost. The stream is a fetch, not an EventSource, so it can carry the
// token; when it ends or fails, it starts again after a moment.
let following: AbortController | null = null;
let pending: Event[] | null = null;
let retry = 0;

export function connect() {
  if (following || !token()) {
    if (!token()) set({ signedIn: false });
    return;
  }
  const control = new AbortController();
  following = control;
  void follow(control);
}

async function follow(control: AbortController) {
  set({ connection: 'connecting' });
  try {
    const response = await openEvents(control.signal);
    if (response.status === 401) { signedOut(); return; }
    if (!response.ok || !response.body) throw new ApiError(response.status, `Oby answered ${response.status}.`);
    pending = [];
    const read = sseReader((name, data) => {
      const e = parseEvent(name, data);
      if (!e) return;
      if (pending) pending.push(e);
      else set(apply(state, e));
    });
    void sync();
    const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      read(value);
    }
    throw new ApiError(0, 'Oby isn’t answering. Trying again…');
  } catch (e) {
    if (control.signal.aborted) return;
    if (following === control) following = null;
    set({ connection: 'down', problem: e instanceof ApiError ? e.message : 'Oby isn’t answering. Trying again…' });
    setTimeout(connect, Math.min(30_000, 1000 * 2 ** retry++));
  }
}

async function sync() {
  try {
    const [status, jobs, inbox, turns] = await Promise.all([api.status(), api.jobs(PAGE), api.inbox(), shownTurns()]);
    const meanwhile = pending ?? [];
    pending = null;
    retry = 0;
    set(synced(state, { status, jobs, inbox, turns }, meanwhile));
    void fetchMissing();
  } catch (e) {
    pending = null;
    lost(e);
  }
}

// The token obid refused (it changed, or the page signed out): forget it, stop following, and
// ask for it again (SignIn.tsx)
export function signedOut() {
  keepToken(null);
  following?.abort();
  following = null;
  pending = null;
  set({ signedIn: false, connection: 'connecting', problem: null });
}
function lost(e: unknown) {
  if (e instanceof ApiError && e.status === 401) { signedOut(); return; }
  set({ connection: 'down', problem: e instanceof Error ? e.message : String(e) });
}

// The token the page was given, once obid has taken it: kept for this tab, and the page follows obid
export function signedIn(value: string) {
  keepToken(value);
  set({ signedIn: true, problem: null });
  connect();
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
const failed = (e: unknown) => {
  if (e instanceof ApiError && e.status === 401) signedOut();
  else say(e instanceof Error ? e.message : String(e));
};

// The turns of the conversation the page shows, or, with none (or it's gone), of the latest
async function shownTurns() {
  if (state.shown) {
    try { return await api.conversation({ id: state.shown, limit: PAGE }); } catch (e) {
      if (!(e instanceof ApiError && e.status === 404)) throw e;
      set({ shown: null });
    }
  }
  return api.conversation({ limit: PAGE });
}

// --- What the page does

// Words to Oby (POST /v1/plans): a reply, a question back, or work that starts. Your words and
// its answer come into the conversation as `turn` events; jobs it started, as `job` events.
export async function ask(said: string, answer?: { question: string; option: string }) {
  const words = said.trim();
  if (!words || state.thinking) return;
  set({ thinking: true, steps: [], waiting: null });
  try {
    // in the conversation the page shows, so its words never land in another
    const a = await api.plan(words, answer, state.shown ?? undefined);
    set(withNew(state, a.jobs));
    if (a.kind === 'question') set({ waiting: { said: a.said, question: a.question } });
    // the first conversation, which the page now shows; or the stream down meanwhile: the
    // conversation as it is now
    if ((!state.shown && a.conversation) || state.connection !== 'live') {
      if (!state.shown && a.conversation) set({ shown: a.conversation });
      set({ turns: (await shownTurns()).sort(byAt) });
    }
  } catch (e) {
    // the conversation it showed is gone: the latest from now on
    if (e instanceof ApiError && e.status === 404 && state.shown) set({ shown: null, turns: [], older: false });
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
    set(withNew(state, [await api.message(id, t)]));
  } catch (e) { failed(e); }
}

export async function stopJob(id: string) {
  try {
    set(withNew(state, [await api.stop(id)]));
  } catch (e) { failed(e); }
}

export async function dismissJob(id: string) {
  try {
    set(withNew(state, [await api.dismiss(id)]));
  } catch (e) { failed(e); }
}

// A decision answered (POST /v1/inbox/{id}/answer): Later puts it off an hour
export async function answerItem(taskId: string, itemId: string, option: string) {
  set({ answering: { ...state.answering, [taskId]: option } });
  try {
    const body = option === 'Later' ? { later: new Date(Date.now() + 3600_000).toISOString().replace(/\.\d+Z$/, 'Z') } : { answer: option };
    const item = await api.answer(itemId, body);
    // settled, it leaves the inbox; put off, it's updated, unless an event settled it meanwhile
    if (item.state === 'done' || state.inbox.some((i) => i.id === item.id)) set(apply(state, { kind: 'inbox', item }));
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
