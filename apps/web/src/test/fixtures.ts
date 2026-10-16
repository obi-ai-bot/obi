import type { InboxItem, Job, Turn } from '../api';
import type { Live } from '../live';

// A job as obid sends it (core/crates/obid/src/job.rs, to_json), trimmed to the keys the app reads.
export function job(over: Partial<Job> = {}): Job {
  return {
    id: 'j1', request: 'Fix the empty list', agent: 'claude', account: 'stub', repo: 'obi-e2e/fixture-app', branch: 'oby/fix-1',
    base: 'main', pr: null, issue: null, kind: 'fix', task: 'Fix the empty list', status: 'running', step: 'Running node --test',
    summary: '', created: '2026-10-16T10:00:00Z', started: '2026-10-16T10:00:02Z', finished: null, commits: null, published: null,
    publishError: null, rounds: 1, round: 1, check: 'node --test', model: null, notes: null, dismissed: null, question: null,
    permission: null, title: 'Empty list', pipeline: { number: 2, total: 6, stages: [
      { id: 'prepare', title: 'Prepare', state: 'done', detail: 'Clone and worktree' },
      { id: 'work', title: 'Work', state: 'current', detail: 'Round 1 of 1' },
    ] },
    ...over,
  };
}

export function item(over: Partial<InboxItem> = {}): InboxItem {
  return {
    id: 'i1', kind: 'permission', job: 'j1', title: 'Empty list', text: 'Run rm -rf build', options: ['Allow', 'Deny'], details: null,
    created: '2026-10-16T10:01:00Z', done: null, later: null, answer: null, state: 'open', headline: null, happened: null,
    recommended: null, why: null, ...over,
  };
}

export const turn = (over: Partial<Turn> = {}): Turn => ({ id: 't1', who: 'user', text: 'Fix it', at: '2026-10-16T10:00:00Z', jobs: [], ...over });

export function state(over: Partial<Live> = {}): Live {
  return {
    signedIn: true, connection: 'live', problem: null, status: {
      runner: { version: '0.2.0', host: 'lab', engine: 'obid' }, maxRunning: 6, running: 1, clearedAt: null, permissions: { mode: 'bypass' },
      models: { claude: { model: 'claude-opus-5-5' } },
      accounts: [{ id: 'stub', agent: 'claude', name: 'Stub', label: null, signedIn: true, fiveHour: null, sevenDay: null, fiveHourResets: null, sevenDayResets: null, running: 1 }],
    },
    jobs: {}, firstJobs: new Set(), seen: new Set(), inbox: [], conversations: [], turns: [], shown: null, older: false, thinking: false,
    asking: null, saying: null, picked: false, jobsSince: null, steps: [], waiting: null,
    answering: {}, clearedAt: null, ...over,
  };
}

// The page's session storage, in memory
export function storage(entries: Record<string, string> = {}): Storage {
  const map = new Map(Object.entries(entries));
  return {
    get length() { return map.size; },
    clear: () => map.clear(),
    getItem: (k) => map.get(k) ?? null,
    key: (i) => [...map.keys()][i] ?? null,
    removeItem: (k) => { map.delete(k); },
    setItem: (k, v) => { map.set(k, String(v)); },
  };
}
