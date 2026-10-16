// A typed client of the runner API (docs/runner-api.md), limited to what obid serves and this app
// shows: the status, jobs, the conversation, plans, the inbox and the event stream. Every call
// goes to the page's own origin: obid serves this page (/app/) and signs it in with its session
// cookie, so the page never holds the API token (in dev, Vite's proxy adds it; vite.config.ts).

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
};

// "GET /v1/conversation"
export type Turn = { id: string; who: 'user' | 'oby'; text: string; at: string; jobs: string[]; details?: string | null };

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
};
export type Status = {
  runner: { version: string; host: string; engine?: string };
  accounts: Account[];
  models: Record<string, { model: string; effort?: string; complexEffort?: string }>;
  maxRunning: number;
  running: number;
  clearedAt: string | null;
  permissions: { mode: string };
};

// "POST /v1/plans"
export type Question = { text: string; options: string[]; recommended: number | null };
export type PlanAnswer =
  | { kind: 'reply'; text: string; details?: string | null; jobs: Job[] }
  | { kind: 'question'; said: string; question: Question; jobs: Job[] }
  | { kind: 'none'; jobs: Job[] };

// "GET /v1/events": a step of the turn under way
export type Step = { turn: string; index: number; action: string; text: string; state: 'running' | 'done' | 'failed'; at: string };

// The events this app follows; any other is ignored.
export type Event =
  | { kind: 'job'; job: Job }
  | { kind: 'inbox'; item: InboxItem }
  | { kind: 'turn'; turn: Turn }
  | { kind: 'step'; step: Step }
  | { kind: 'accounts'; accounts: Account[] }
  | { kind: 'clear'; clearedAt: string };

// {"error": "One line a person can read."} with its status
export class ApiError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, {
      method,
      credentials: 'same-origin',
      headers: body === undefined ? { Accept: 'application/json' } : { Accept: 'application/json', 'Content-Type': 'application/json' },
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
  jobs: (limit = 50) => call<Job[]>('GET', `/v1/jobs${q({ limit })}`),
  job: (id: string) => call<Job>('GET', `/v1/jobs/${encodeURIComponent(id)}`),
  stop: (id: string) => call<Job>('POST', `/v1/jobs/${encodeURIComponent(id)}/stop`),
  dismiss: (id: string) => call<Job>('POST', `/v1/jobs/${encodeURIComponent(id)}/dismiss`),
  message: (id: string, text: string) => call<Job>('POST', `/v1/jobs/${encodeURIComponent(id)}/messages`, { text }),
  inbox: () => call<InboxItem[]>('GET', '/v1/inbox'),
  answer: (id: string, body: { answer: string } | { done: true } | { later: string }) =>
    call<InboxItem>('POST', `/v1/inbox/${encodeURIComponent(id)}/answer`, body),
  conversation: (opts: { before?: string; limit?: number } = {}) => call<Turn[]>('GET', `/v1/conversation${q(opts)}`),
  plan: (said: string, answer?: { question: string; option: string }) =>
    call<PlanAnswer>('POST', '/v1/plans', answer ? { said, answer } : { said }),
};

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
    default: return null;
  }
}

export const EVENT_NAMES = ['job', 'inbox', 'turn', 'step', 'accounts', 'clear'] as const;
