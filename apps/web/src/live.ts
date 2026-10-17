import { useSyncExternalStore } from 'react';
import { ApiError, api, keepToken, openEvents, parseEvent, sseReader, token, type Conversation, type Event, type InboxItem, type Job, type Question, type Status, type Step, type Turn } from './api';
import { ordered } from './chats';

// What obid has, as this page knows it, kept live by its event stream (docs/runner-api.md,
// "GET /v1/events"): the status, the jobs, the open inbox, the conversations and the one it shows,
// and the plan this page is waiting on. One snapshot, replaced on every change; components read it with useLive().
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
  conversations: Conversation[];  // obid's conversations (#493), pinned first, then newest first
  turns: Turn[];               // the conversation it shows, oldest first
  shown: string | null;        // which conversation that is: the latest when the page opened, the
                               // one picked in the side panel, or the one its words started; null
                               // for none yet (New, or none at all): its next words start one
  picked: boolean;             // shown was picked (opened, New, or started by its words), not the
                               // latest the page found: a reconnect keeps it
  older: boolean;              // turns before the first one shown
  jobsSince: string | null;    // the page has every job created since then (the latest page of
                               // them it fetched); null: every job there is
  thinking: boolean;           // a plan from this page is under way
  asking: string | null;       // the conversation that plan is in; null: one it's starting
  saying: string | null;       // the words of that plan, to know its first turn by
  steps: Step[];               // what the turn under way is doing
  // Oby's question back, in the conversation it asked in, until answered
  waiting: { said: string; question: Question; conversation: string | null } | null;
  answering: Record<string, string>;  // a decision answered from this page, by inbox item id, until it's settled
  clearedAt: string | null;
};

const PAGE = 100;
let state: Live = {
  signedIn: !!token(), connection: 'connecting', problem: null, status: null, jobs: {}, firstJobs: new Set(), seen: new Set(),
  inbox: [], conversations: [], turns: [], shown: null, picked: false, older: false, jobsSince: null, thinking: false, asking: null,
  saying: null, steps: [], waiting: null, answering: {}, clearedAt: null,
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
// turns fetched, with those an event brought meanwhile, once each
const merged = (fetched: Turn[], had: Turn[]) => [...had.filter((t) => !fetched.some((f) => f.id === t.id)), ...fetched].sort(byAt);
const isOpen = (i: InboxItem) => i.state !== 'done';

// One event over a snapshot
export function apply(s: Live, e: Event): Live {
  switch (e.kind) {
    case 'job':
      return { ...s, jobs: { ...s.jobs, [e.job.id]: e.job } };
    case 'inbox': {
      const rest = s.inbox.filter((i) => i.id !== e.item.id);
      const settled = !isOpen(e.item);
      const answering = settled ? omit(s.answering, e.item.id) : s.answering;
      return { ...s, inbox: settled ? rest : [...rest, e.item].sort((a, b) => a.created.localeCompare(b.created)), answering };
    }
    case 'turn': {
      // obid keeps many conversations (#493) and this page shows one: a turn of another
      // (someone else started it, or it's in the side panel's list) stays out of it. With none
      // shown, a conversation is taken in only by the turn of this page's own words starting it.
      const from = e.turn.conversation;
      if (from && s.shown && from !== s.shown) return s;
      const starting = !!from && !s.shown;
      if (starting && !(s.thinking && s.asking === null && e.turn.who === 'user' && e.turn.text.trim() === s.saying)) return s;
      const rest = s.turns.filter((t) => t.id !== e.turn.id);
      return { ...s, shown: starting ? from! : s.shown, asking: starting ? from! : s.asking, turns: [...rest, e.turn].sort(byAt) };
    }
    case 'conversation':
      return { ...s, conversations: ordered([...s.conversations.filter((c) => c.id !== e.conversation.id), e.conversation]) };
    case 'conversationGone': {
      // deleted (here or elsewhere) or forgotten: off the list; the one shown empties, and the
      // next words there start a new one
      const conversations = s.conversations.filter((c) => c.id !== e.id);
      return e.id === s.shown ? { ...s, conversations, shown: null, picked: true, turns: [], older: false } : { ...s, conversations };
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

// Jobs an answer named (a plan's, a message's, a stop's), added only when the page doesn't know
// them yet: the event stream owns a job's state, and an answer's copy can be older than an event
// that came first (a plan's "queued" after the job's own event said it failed).
export function withNew(s: Live, jobs: Job[]): Live {
  const added = jobs.filter((j) => !s.jobs[j.id]);
  return added.length ? { ...s, jobs: { ...s.jobs, ...Object.fromEntries(added.map((j) => [j.id, j])) } } : s;
}

// What to show, fetched once the stream answered, with the events that came meanwhile applied
// over it in the order they came.
// turnsOf: the conversation `turns` are of (left out: the latest, when the page picked none)
export type Snapshot = { status: Status; jobs: Job[]; inbox: InboxItem[]; turns: Turn[]; conversations: Conversation[]; turnsOf?: string | null };
export function synced(s: Live, snap: Snapshot, meanwhile: Event[]): Live {
  let next: Live = {
    ...s, connection: 'live', problem: null, status: snap.status, clearedAt: snap.status.clearedAt,
    firstJobs: s.status ? s.firstJobs : new Set(snap.jobs.map((j) => j.id)),
    jobs: { ...s.jobs, ...Object.fromEntries(snap.jobs.map((j) => [j.id, j])) },
    inbox: snap.inbox.filter(isOpen), conversations: ordered(snap.conversations),
    jobsSince: snap.jobs.length < PAGE ? null : snap.jobs.reduce((o, j) => (j.created < o ? j.created : o), snap.jobs[0].created),
    // the one it picked stays, and so do its turns when the snapshot is of another (it moved
    // meanwhile); otherwise the latest
    ...(s.picked
      ? (snap.turnsOf === s.shown ? { turns: merged(snap.turns, s.turns), older: snap.turns.length >= PAGE } : {})
      : { shown: snap.turns[0]?.conversation ?? s.shown, turns: [...snap.turns].sort(byAt), older: snap.turns.length >= PAGE }),
  };
  for (const e of meanwhile) next = apply(next, e);
  return next;
}

// The stream first, then what to show once its response has arrived, with the events that came
// meanwhile applied over it: the runner follows a connection before it answers, so nothing that
// changes in between is lost. The stream is a fetch, not an EventSource, so it can carry the
// token; when it ends or fails, it starts again after a moment.
let following: AbortController | null = null;
let authSession = 0;
let reconnecting: ReturnType<typeof setTimeout> | null = null;
const current = (control: AbortController) => following === control && !control.signal.aborted;
let retry = 0;
const asked = new Set<string>();

export function connect() {
  if (following || !token()) {
    if (!token()) set({ signedIn: false });
    return;
  }
  if (reconnecting !== null) clearTimeout(reconnecting);
  reconnecting = null;
  asked.clear();
  const control = new AbortController();
  following = control;
  void follow(control);
}

async function follow(control: AbortController) {
  set({ connection: 'connecting' });
  try {
    const response = await openEvents(control.signal);
    if (!current(control)) { void response.body?.cancel().catch(() => {}); return; }
    if (response.status === 401) { signedOut(); return; }
    if (!response.ok || !response.body) throw new ApiError(response.status, `Oby answered ${response.status}.`);
    const pending: Event[] = [];
    let syncing = true;
    const read = sseReader((name, data) => {
      const e = parseEvent(name, data);
      if (!e || !current(control)) return;
      if (syncing) pending.push(e);
      else set(apply(state, e));
    });
    void sync(control, pending, () => { syncing = false; });
    const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      read(value);
    }
    throw new ApiError(0, 'Oby isn’t answering. Trying again…');
  } catch (e) {
    reconnect(control, e);
  }
}

// A snapshot failure needs the same recovery as a broken stream. Ending this
// generation also prevents its late HTTP responses from replacing a newer one.
function reconnect(control: AbortController, e: unknown) {
  if (!current(control)) return;
  if (e instanceof ApiError && e.status === 401) { signedOut(); return; }
  following = null;
  control.abort();
  set({ connection: 'down', problem: e instanceof Error ? e.message : 'Oby isn’t answering. Trying again…' });
  reconnecting = setTimeout(() => { reconnecting = null; connect(); }, Math.min(30_000, 1000 * 2 ** retry++));
}

async function sync(control: AbortController, pending: Event[], onSynced: () => void) {
  try {
    const turnsOf = state.picked ? state.shown : undefined;
    const [status, jobs, inbox, turns, conversations] = await Promise.all([api.status(), api.jobs(PAGE), api.inbox(), shownTurns(control), allConversations()]);
    if (!current(control)) return;
    retry = 0;
    set(synced(state, { status, jobs, inbox, turns, conversations, turnsOf }, pending));
    pending.length = 0;
    onSynced();
    void fetchMissing(control);
  } catch (e) {
    reconnect(control, e);
  }
}

// The token obid refused (it changed, or the page signed out): forget it, stop following, and
// ask for it again (SignIn.tsx)
export function signedOut() {
  authSession++;
  keepToken(null);
  following?.abort();
  following = null;
  if (reconnecting !== null) clearTimeout(reconnecting);
  reconnecting = null;
  retry = 0;
  set({ signedIn: false, connection: 'connecting', problem: null, status: null,
    jobs: {}, firstJobs: new Set(), seen: new Set(), inbox: [], conversations: [], turns: [], shown: null, picked: false, older: false,
    jobsSince: null, thinking: false, asking: null, saying: null, steps: [], waiting: null, answering: {}, clearedAt: null });
}
// The token the page was given, once obid has taken it: kept for this tab, and the page follows obid
export function signedIn(value: string) {
  signedOut();
  keepToken(value);
  set({ signedIn: true, problem: null });
  connect();
}

// Jobs the inbox or the conversation names that aren't among the latest: fetched one by one
// (GET /v1/jobs/{id} answers any job the runner ever had).
async function fetchMissing(control = following) {
  const ids = new Set([...state.inbox.map((i) => i.job), ...state.turns.flatMap((t) => t.jobs)]);
  for (const id of ids) {
    if (following !== control || control?.signal.aborted) return;
    if (!id || state.jobs[id] || asked.has(id)) continue;
    asked.add(id);
    try {
      const job = await api.job(id);
      if (following !== control || control?.signal.aborted) return;
      set({ jobs: { ...state.jobs, [job.id]: job } });
    } catch { /* gone: nothing to show for it */ }
  }
}

// What a call that went wrong says, for a moment
let clearing: ReturnType<typeof setTimeout> | undefined;
export function say(problem: string) {
  set({ problem });
  clearTimeout(clearing);
  clearing = setTimeout(() => { if (state.connection === 'live') set({ problem: null }); }, 6000);
}
const failed = (e: unknown) => {
  if (e instanceof ApiError && e.status === 401) signedOut();
  else say(e instanceof Error ? e.message : String(e));
};

// The turns of the conversation the page shows; with none picked, of the latest; with none on
// purpose (New, or it was deleted), none
async function shownTurns(control = following, session = authSession) {
  if (state.shown) {
    const id = state.shown;
    try { return await api.conversation({ id, limit: PAGE }); } catch (e) {
      if (!(e instanceof ApiError && e.status === 404)) throw e;
      if (session !== authSession || following !== control || control?.signal.aborted) return [];
      if (state.shown === id) set({ shown: null, picked: true, turns: [], older: false });
      return [];
    }
  }
  return state.picked ? [] : api.conversation({ limit: PAGE });
}

// Every conversation, a page at a time (obid keeps 200, more only when pinned); one per id, as a
// conversation that moved while paging can come twice
async function allConversations() {
  const all = new Map<string, Conversation>();
  for (let after: string | undefined, page = 0; page < 10; page++) {
    const list = await api.conversations({ after, limit: 200 });
    for (const c of list) if (!all.has(c.id)) all.set(c.id, c);
    if (list.length < 200) break;
    after = list.at(-1)!.cursor;
  }
  return [...all.values()];
}

// --- What the page does

// Words to Oby (POST /v1/plans): a reply, a question back, or work that starts. Your words and
// its answer come into the conversation as `turn` events; jobs it started, as `job` events.
// They go to the conversation the page shows, so they never land in another; with none shown, or
// `new` (Home's message box), they start a new one ("new": true, #493), which the page then shows.
export async function ask(said: string, answer?: { question: string; option: string }, opts: { new?: boolean; conversation?: string | null } = {}) {
  const words = said.trim();
  if (!words || state.thinking) return;
  const session = authSession;
  if (opts.new && state.shown) newConversation();
  const target = opts.new ? null : opts.conversation !== undefined ? opts.conversation : state.shown;
  set({ thinking: true, asking: target, saying: words, picked: true, steps: [], waiting: null });
  try {
    const a = await api.plan(words, answer, target ? { conversation: target } : { new: true });
    if (session !== authSession) return;
    set(withNew(state, a.jobs));
    // the page still on the conversation the words went to (or that they started): it shows it
    const here = state.shown === target || (!!a.conversation && state.shown === a.conversation);
    if (a.kind === 'question') set({ waiting: { said: a.said, question: a.question, conversation: a.conversation ?? target } });
    if (here && a.conversation && (state.shown !== a.conversation || state.connection !== 'live')) {
      set({ shown: a.conversation });
      const turns = await shownTurns();
      if (session !== authSession || state.shown !== a.conversation) return;
      set({ turns: merged(turns, state.turns) });
    } else if (here && state.connection !== 'live') {
      const turns = await shownTurns();
      if (session !== authSession || state.shown !== target) return;
      set({ turns: merged(turns, state.turns) });
    }
  } catch (e) {
    if (session !== authSession) return;
    // the conversation it was in was deleted before the page heard of it: obid kept none of the
    // words. It's off the list, the page says so, and the next words start a new one.
    if (e instanceof ApiError && e.status === 404 && target) {
      set(apply(state, { kind: 'conversationGone', id: target }));
      say('That conversation was deleted, so your words weren’t sent. Send them again to start a new one.');
    } else failed(e);
  } finally {
    if (session === authSession) set({ thinking: false, asking: null, saying: null, steps: [] });
  }
}
// Oby's question answered: with one of its options, or in your own words, in the conversation
// it asked in
export function answerQuestion(option: string) {
  const w = state.waiting;
  if (!w || !option.trim()) return;
  void ask(w.said, { question: w.question.text, option: option.trim() }, { conversation: w.conversation });
}

// --- The conversations (#493): opened from the side panel, started anew, renamed, pinned, deleted

// One conversation's turns, shown instead of the one before. Already shown with its turns (every
// conversation has one), or on its way: nothing to do; one that failed to load loads again.
let opening: string | null = null;
export async function openConversation(id: string) {
  if (state.shown === id && (state.turns.length || opening === id)) { if (!state.picked) set({ picked: true }); return; }
  const session = authSession;
  opening = id;
  set({ shown: id, picked: true, turns: state.shown === id ? state.turns : [], older: false });
  try {
    const turns = await api.conversation({ id, limit: PAGE });
    if (session !== authSession || state.shown !== id) return;
    set({ turns: merged(turns, state.turns), older: turns.length >= PAGE });
    void fetchMissing();
  } catch (e) {
    if (session !== authSession) return;
    // gone meanwhile: off the list, nothing shown
    if (e instanceof ApiError && e.status === 404) set(apply(state, { kind: 'conversationGone', id }));
    failed(e);
  } finally {
    if (opening === id) opening = null;
  }
}
// New: none shown, so the next words start one
export function newConversation() {
  set({ shown: null, picked: true, turns: [], older: false });
}

const edited = (id: string, change: Partial<Conversation>) =>
  set({ conversations: ordered(state.conversations.map((c) => (c.id === id ? { ...c, ...change } : c))) });
// Its title, one line of 1 to 100 characters (PATCH /v1/conversations/{id}); shown at once, put
// back if obid refuses it
export async function renameConversation(id: string, title: string) {
  const was = state.conversations.find((c) => c.id === id);
  // obid's rules: one line, no control character, at most 100 characters (code points, so never
  // half an emoji)
  const line = title.replace(/[\p{Cc}\u2028\u2029]+/gu, ' ').replace(/ {2,}/g, ' ').trim();
  const t = Array.from(line).slice(0, 100).join('').trim();
  if (!was || !t || t === was.title) return;
  await change(id, { title: t }, { title: was.title });
}
// Pinned to the top, or not
export async function pinConversation(id: string, pinned: boolean) {
  const was = state.conversations.find((c) => c.id === id);
  if (!was || was.pinned === pinned) return;
  await change(id, { pinned }, { pinned: was.pinned });
}
// Only what it changed is taken from obid's answer, and put back on a refusal only while nothing
// changed it since: a rename and a pin in quick succession don't undo each other (the
// `conversation` events bring the rest)
async function change(id: string, to: { title?: string; pinned?: boolean }, back: Partial<Conversation>) {
  const session = authSession;
  edited(id, to);
  const keys = Object.keys(to) as ('title' | 'pinned')[];
  const still = () => { const c = state.conversations.find((x) => x.id === id); return !!c && keys.every((k) => c[k] === to[k]); };
  try {
    const c = await api.editConversation(id, to);
    if (session === authSession && still()) edited(id, Object.fromEntries(keys.map((k) => [k, c[k]])));
  } catch (e) {
    if (session !== authSession) return;
    if (e instanceof ApiError && e.status === 404) set(apply(state, { kind: 'conversationGone', id }));
    else if (still()) edited(id, back);
    failed(e);
  }
}
// Deleted (DELETE /v1/conversations/{id}): off the list at once; the tasks it started stay, and
// their cards then open their own thread
export async function deleteConversation(id: string) {
  const session = authSession;
  const was = state.conversations;
  set(apply(state, { kind: 'conversationGone', id }));
  try {
    await api.deleteConversation(id);
  } catch (e) {
    if (session !== authSession) return;
    // already gone is what was asked; otherwise it's back on the list
    if (!(e instanceof ApiError && e.status === 404)) set({ conversations: ordered([...state.conversations, ...was.filter((c) => c.id === id)]) });
    failed(e);
  }
}

// The turns before the first one shown
export async function loadOlder() {
  const session = authSession;
  const first = state.turns[0], of = state.shown;
  if (!first) return;
  try {
    const turns = await api.conversation({ before: first.id, limit: PAGE });
    // signed out, or another conversation shown meanwhile: not for this one
    if (session !== authSession || state.shown !== of) return;
    set({ turns: [...turns, ...state.turns].sort(byAt), older: turns.length >= PAGE });
    void fetchMissing();
  } catch (e) { if (session === authSession) failed(e); }
}

// Told the job's agent something (POST /v1/jobs/{id}/messages)
export async function tellJob(id: string, text: string) {
  const t = text.trim();
  if (!t) return;
  const session = authSession;
  try {
    const job = await api.message(id, t);
    if (session === authSession) set(withNew(state, [job]));
  } catch (e) { if (session === authSession) failed(e); }
}

export async function stopJob(id: string) {
  const session = authSession;
  try {
    const job = await api.stop(id);
    if (session === authSession) set(withNew(state, [job]));
  } catch (e) { if (session === authSession) failed(e); }
}

export async function dismissJob(id: string) {
  const session = authSession;
  try {
    const job = await api.dismiss(id);
    if (session === authSession) set(withNew(state, [job]));
  } catch (e) { if (session === authSession) failed(e); }
}

// A decision answered (POST /v1/inbox/{id}/answer): Later puts it off an hour
export async function answerItem(itemId: string, option: string) {
  const session = authSession;
  set({ answering: { ...state.answering, [itemId]: option } });
  try {
    const body = option === 'Later' ? { later: new Date(Date.now() + 3600_000).toISOString().replace(/\.\d+Z$/, 'Z') } : { answer: option };
    const item = await api.answer(itemId, body);
    if (session !== authSession) return;
    // settled, it leaves the inbox; put off, it's updated, unless an event settled it meanwhile
    if (item.state === 'done' || state.inbox.some((i) => i.id === item.id)) set(apply(state, { kind: 'inbox', item }));
    if (option === 'Later') set({ answering: omit(state.answering, itemId) });
  } catch (e) {
    if (session !== authSession) return;
    set({ answering: omit(state.answering, itemId) });
    failed(e);
  }
}

export function markSeen(id: string) {
  if (state.seen.has(id)) return;
  set({ seen: new Set([...state.seen, id]) });
}
