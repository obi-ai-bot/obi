// A typed client of the runner API (docs/runner-api.md), limited to what obid serves and this app
// shows: the status, jobs, the conversations, plans, the inbox, the event stream, and the plug-ins
// and connections Settings › Connectors reads. Every call
// goes to the page's own origin (obid serves this page at /app/; in dev, Vite's proxy passes /v1
// on) with `Authorization: Bearer <token>`: the API takes nothing else. The token is in the page's
// session storage, which only this origin (this port on 127.0.0.1) reads, put there by obid's
// sign-in form or the page's own (SignIn.tsx); no cookie ever reaches /v1.

export type Agent = 'claude' | 'codex' | 'cursor';
export type JobStatus = 'queued' | 'running' | 'done' | 'failed' | 'stopped' | 'interrupted';
export type StageState = 'done' | 'current' | 'upcoming' | 'failed' | 'skipped';
export type Stage = { id: string; title: string; state: StageState; detail?: string | null };

// docs/runner-api.md, "Job": the keys this app reads. Any other key the runner sends is kept as it
// came, unread.
export type Job = {
  id: string;
  request: string;
  agent: Agent;
  account: string;
  repo: string;
  branch: string;
  base: string | null;
  pr: number | null;
  issue: number | null;
  kind: string;
  task: string;
  status: JobStatus;
  step: string;
  summary: string;
  created: string;
  started: string | null;
  finished: string | null;
  commits: number | null;
  published: string | null;
  publishError: string | null;
  rounds: number;
  round: number;
  check: string | null;
  model: string | null;
  notes: string[] | null;
  dismissed: string | null;
  limit?: string | null;
  question: { text: string; options: string[]; details?: string[] | null; recommended?: number | null } | null;
  permission: { id: string; tool: string; title: string; detail: string; rule: string | null; always: string | null } | null;
  pipeline: { number: number; total: number; stages: Stage[] } | null;
  title: string;
  // obid only: the conversation whose words started it, kept when that one is deleted (#493)
  conversation?: string | null;
  // obid only: on a review another Obi asked for, who asked ("obid only: Obi-to-Obi review jobs")
  obi?: { correlationId: string; from: string; fromOwner: string; requestId: string } | null;
};

// "Inbox item"
export type InboxItem = {
  id: string;
  kind: string;
  job: string;
  title: string;
  text: string;
  options: string[];
  details: string[] | null;
  created: string;
  done: string | null;
  later: string | null;
  answer: string | null;
  state: 'open' | 'later' | 'done';
  headline: string | null;
  happened: string | null;
  recommended: number | null;
  why: string | null;
  // obid only: on an `obiRequest`, the request's typed fields; this app reads who asked
  obi?: { fromOwner?: string } | null;
  // obid only (#546): on a `confirm` item, what its Confirm carries out: a typed action, what it
  // acts on and what else it needs (docs/runner-api.md, "Inbox item")
  confirm?: { action: string; target: string; payload: unknown } | null;
  // obid only (#1124): on a `pluginEvent`, where it came from: a plug-in's id, or obid's own
  // source (sentry, alertmanager, grafana, pagerduty)
  plugin?: { id?: string } | null;
};

// "GET /v1/conversation"
// conversation: the one it's in (obid keeps many since #493, "obid only: conversations"); runners
// from before send none
export type Turn = { id: string; who: 'user' | 'oby'; text: string; at: string; jobs: string[]; details?: string | null; conversation?: string };

// obid only: conversations, "A conversation", as GET /v1/conversations lists it and the
// `conversation` event sends it
export type Conversation = { id: string; title: string; pinned: boolean; created: string; lastActivity: string; cursor: string };

// "Account" and "GET /v1/status", the keys this app reads
export type Account = {
  id: string;
  agent: Agent;
  name: string;
  label: string | null;
  signedIn: boolean;
  fiveHour: number | null;
  sevenDay: number | null;
  fiveHourResets: string | null;
  sevenDayResets: string | null;
  running: number;
  // whether the account's agents have Tetrix's MCP server, or null before the runner knows;
  // older runners don't send it
  tetrix?: boolean | null;
};
export type Status = {
  runner: { version: string; host: string; engine?: string };
  accounts: Account[];
  models: Record<string, { model: string; effort?: string; complexEffort?: string }>;
  maxRunning: number;
  running: number;
  clearedAt: string | null;
  permissions: { mode: string };
  // who the runner's own GitHub calls act as ('app' or 'owner'), and whether its check runs reach
  // pull requests ('ok', 'missing permission', 'no app'); older runners send neither
  github?: string;
  checks?: string;
};

// "obid only: plug-ins": one plug-in obid found, enabled or not
export type Plugin = { id: string; name: string; version: string | null; kinds: string[]; enabled: boolean; state: string; lastError: string | null };

// "Connection": an app or API the runner's agents use through its broker; the secret only by name
export type ConnectedApp = {
  name: string;
  mcp: string | null;
  api: string | null;
  secret: string;
  header: string | null;
  created: string;
  secretSaved: boolean;
  lastUsed: string | null;
};

// "POST /v1/plans"
export type Question = { text: string; options: string[]; recommended: number | null };
// conversation: the one the words joined
export type PlanAnswer = (
  | { kind: 'reply'; text: string; details?: string | null; jobs: Job[] }
  | { kind: 'question'; said: string; question: Question; jobs: Job[] }
  | { kind: 'none'; jobs: Job[] }
) & { conversation?: string };

// "GET /v1/events": a step of the turn under way
export type Step = { turn: string; index: number; action: string; text: string; state: 'running' | 'done' | 'failed'; at: string };

// The events this app follows; any other is ignored.
export type Event =
  | { kind: 'job'; job: Job }
  | { kind: 'inbox'; item: InboxItem }
  | { kind: 'turn'; turn: Turn }
  | { kind: 'step'; step: Step }
  | { kind: 'accounts'; accounts: Account[] }
  | { kind: 'clear'; clearedAt: string }
  | { kind: 'conversation'; conversation: Conversation }
  | { kind: 'conversationGone'; id: string };

// {"error": "One line a person can read."} with its status
export class ApiError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

// Where the page keeps the token: the session storage obid's sign-in form writes too
// (core/crates/obid/src/web.rs, SIGN_IN_SCRIPT)
export const TOKEN_KEY = 'oby.token';
export function token(): string | null {
  try { return sessionStorage.getItem(TOKEN_KEY); } catch { return null; }
}
export function keepToken(value: string | null) {
  try {
    if (value) sessionStorage.setItem(TOKEN_KEY, value);
    else sessionStorage.removeItem(TOKEN_KEY);
  } catch { /* nowhere to keep it: the page asks again */ }
}
const authorization = (t = token()): Record<string, string> => (t ? { Authorization: `Bearer ${t}` } : {});

async function call<T>(method: string, path: string, body?: unknown, with_ = token()): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, {
      method,
      // the token, never a cookie: obid's page cookie is for its files under /app only
      credentials: 'omit',
      cache: 'no-store',
      headers: {
        Accept: 'application/json',
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        ...authorization(with_),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError(0, 'Oby isn’t answering. Is obid running?');
  }
  const text = await response.text();
  let value: unknown = null;
  try { value = text ? JSON.parse(text) : null; } catch { /* not JSON: said below */ }
  if (!response.ok) {
    const said = (value as { error?: unknown } | null)?.error;
    throw new ApiError(response.status, typeof said === 'string' ? said : `Oby answered ${response.status}.`);
  }
  return value as T;
}

const q = (params: Record<string, string | number | undefined>) => {
  const s = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined) s.set(k, String(v));
  const text = s.toString();
  return text ? `?${text}` : '';
};

export const api = {
  status: () => call<Status>('GET', '/v1/status'),
  // whether `candidate` is obid's token: its status answers with it
  check: (candidate: string) => call<Status>('GET', '/v1/status', undefined, candidate),
  jobs: (limit = 50) => call<Job[]>('GET', `/v1/jobs${q({ limit })}`),
  job: (id: string) => call<Job>('GET', `/v1/jobs/${encodeURIComponent(id)}`),
  stop: (id: string) => call<Job>('POST', `/v1/jobs/${encodeURIComponent(id)}/stop`),
  dismiss: (id: string) => call<Job>('POST', `/v1/jobs/${encodeURIComponent(id)}/dismiss`),
  message: (id: string, text: string) => call<Job>('POST', `/v1/jobs/${encodeURIComponent(id)}/messages`, { text }),
  inbox: () => call<InboxItem[]>('GET', '/v1/inbox'),
  answer: (id: string, body: { answer: string } | { done: true } | { later: string }) =>
    call<InboxItem>('POST', `/v1/inbox/${encodeURIComponent(id)}/answer`, body),
  // one conversation's turns: `id`'s, or the one `before` is in, or with neither the latest
  conversation: (opts: { id?: string; before?: string; limit?: number } = {}) => call<Turn[]>('GET', `/v1/conversation${q(opts)}`),
  // words to Oby: in a conversation, or starting a new one (neither: the latest)
  plan: (said: string, answer?: { question: string; option: string }, where: { conversation: string } | { new: true } | Record<string, never> = {}) =>
    call<PlanAnswer>('POST', '/v1/plans', { said, ...(answer ? { answer } : {}), ...where }),
  // the conversations, a page from `after` (a conversation's cursor)
  conversations: (opts: { after?: string; limit?: number } = {}) => call<Conversation[]>('GET', `/v1/conversations${q(opts)}`),
  // renamed or pinned
  editConversation: (id: string, change: { title?: string; pinned?: boolean }) =>
    call<Conversation>('PATCH', `/v1/conversations/${encodeURIComponent(id)}`, change),
  // forgotten, with its turns; the jobs it started stay
  deleteConversation: (id: string) => call<null>('DELETE', `/v1/conversations/${encodeURIComponent(id)}`),
  // Settings › Connectors (#518), read only: obid's plug-ins, and the runner's connections
  plugins: () => call<Plugin[]>('GET', '/v1/obid/plugins'),
  connections: () => call<ConnectedApp[]>('GET', '/v1/connections'),
};

// The event stream (GET /v1/events), with the token in its header, which EventSource can't send:
// its response, to read with readEvents.
export function openEvents(signal: AbortSignal): Promise<Response> {
  return fetch('/v1/events', {
    credentials: 'omit', cache: 'no-store', signal,
    headers: { Accept: 'text/event-stream', ...authorization() },
  });
}

// Server-Sent Events, as the stream's text comes in a piece at a time: each event's name (`event:`)
// and data (its `data:` lines, joined), to `onEvent`; comments (`: ping`) and other fields are
// skipped. Lines end in \n, \r\n or \r; an event ends at an empty line.
export function sseReader(onEvent: (name: string, data: string) => void) {
  let buffer = '', name = '', data: string[] = [];
  const line = (text: string) => {
    if (text === '') {
      if (data.length) onEvent(name || 'message', data.join('\n'));
      name = ''; data = [];
      return;
    }
    if (text.startsWith(':')) return;
    const at = text.indexOf(':');
    const field = at < 0 ? text : text.slice(0, at);
    let value = at < 0 ? '' : text.slice(at + 1);
    if (value.startsWith(' ')) value = value.slice(1);
    if (field === 'event') name = value;
    else if (field === 'data') data.push(value);
  };
  return (chunk: string) => {
    buffer += chunk;
    // a \r at the very end may be the first half of \r\n: wait for the next piece
    const lines = buffer.split(/\r\n|\r(?!$)|\n/);
    buffer = lines.pop() ?? '';
    lines.forEach(line);
  };
}

// One event from the stream, by its name and data, or null for one this app doesn't follow
// (or that isn't the shape the API says).
export function parseEvent(name: string, data: string): Event | null {
  let value: unknown;
  try { value = JSON.parse(data); } catch { return null; }
  if (!value || typeof value !== 'object') return null;
  const v = value as Record<string, unknown>;
  switch (name) {
    case 'job': return typeof v.id === 'string' ? { kind: 'job', job: value as Job } : null;
    case 'inbox': return typeof v.id === 'string' ? { kind: 'inbox', item: value as InboxItem } : null;
    case 'turn': return typeof v.id === 'string' ? { kind: 'turn', turn: value as Turn } : null;
    case 'step': return typeof v.text === 'string' ? { kind: 'step', step: value as Step } : null;
    case 'accounts': return Array.isArray(value) ? { kind: 'accounts', accounts: value as Account[] } : null;
    case 'clear': return typeof v.clearedAt === 'string' ? { kind: 'clear', clearedAt: v.clearedAt } : null;
    // one that started, moved, was renamed or pinned; or one deleted or forgotten
    case 'conversation':
      if (typeof v.id !== 'string') return null;
      if (v.deleted === true) return { kind: 'conversationGone', id: v.id };
      return typeof v.title === 'string' && typeof v.lastActivity === 'string' ? { kind: 'conversation', conversation: value as Conversation } : null;
    default: return null;
  }
}

export const EVENT_NAMES = ['job', 'inbox', 'turn', 'step', 'accounts', 'clear', 'conversation'] as const;
