import { afterEach, expect, it, vi } from 'vitest';
import { ask, connect, live, load, signedIn, signedOut } from '../live';
import { job, state, storage, turn } from './fixtures';

const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
async function until(check: () => boolean, timeout = 3000) {
  const deadline = Date.now() + timeout;
  while (!check() && Date.now() < deadline) await settle();
  expect(check()).toBe(true);
}
function events(signal: AbortSignal) {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      signal.addEventListener('abort', () => controller.error(new DOMException('Aborted', 'AbortError')), { once: true });
    },
  });
  return new Response(stream);
}

afterEach(() => { signedOut(); vi.unstubAllGlobals(); });

it('retries the snapshot after a transient REST failure while SSE stays open', async () => {
  vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
  load(state({ status: null, connection: 'connecting' }));
  let snapshots = 0;
  vi.stubGlobal('fetch', vi.fn(async (path: string, init: RequestInit) => {
    if (path === '/v1/events') return events(init.signal!);
    if (path === '/v1/status') return json(state().status);
    if (path.startsWith('/v1/jobs')) return ++snapshots === 1
      ? json({ error: 'Temporarily unavailable' }, 503) : json([job({ id: 'after-retry' })]);
    return json([]);
  }));
  connect();
  await until(() => live().connection === 'live' && !!live().jobs['after-retry']);
  expect(snapshots).toBe(2);
});

it('ignores a snapshot that resolves after signout and a new connection', async () => {
  vi.stubGlobal('sessionStorage', storage({ 'oby.token': 'old' }));
  load(state({ status: null, connection: 'connecting' }));
  let resolveOld!: (response: Response) => void;
  const old = new Promise<Response>((resolve) => { resolveOld = resolve; });
  let startedOld = false;
  vi.stubGlobal('fetch', vi.fn(async (path: string, init: RequestInit) => {
    if (path === '/v1/events') return events(init.signal!);
    if (path === '/v1/status') return json(state().status);
    if (path.startsWith('/v1/jobs')) {
      if ((init.headers as Record<string, string>).Authorization === 'Bearer old') { startedOld = true; return old; }
      return json([job({ id: 'current' })]);
    }
    return json([]);
  }));
  connect();
  await until(() => startedOld);
  signedOut();
  signedIn('new');
  await until(() => live().connection === 'live' && !!live().jobs.current);
  resolveOld(json([job({ id: 'stale' })]));
  await settle(); await settle();
  expect(Object.keys(live().jobs)).toEqual(['current']);
});

it('ignores an old event-stream response after a new token has connected', async () => {
  vi.stubGlobal('sessionStorage', storage({ 'oby.token': 'old' }));
  load(state({ status: null, connection: 'connecting' }));
  let resolveOld!: (response: Response) => void;
  const old = new Promise<Response>((resolve) => { resolveOld = resolve; });
  let startedOld = false;
  vi.stubGlobal('fetch', vi.fn(async (path: string, init: RequestInit) => {
    if (path === '/v1/events') {
      if ((init.headers as Record<string, string>).Authorization === 'Bearer old') { startedOld = true; return old; }
      return events(init.signal!);
    }
    if (path === '/v1/status') return json(state().status);
    if (path.startsWith('/v1/jobs')) return json([job({ id: 'current' })]);
    return json([]);
  }));
  connect();
  await until(() => startedOld);
  signedOut();
  signedIn('new');
  await until(() => live().connection === 'live');
  resolveOld(json({ error: 'Old token refused' }, 401));
  await settle(); await settle();
  expect(live().signedIn).toBe(true);
  expect(live().connection).toBe('live');
});

it('fetches missing jobs again after reconnect and ignores the old answer', async () => {
  vi.stubGlobal('sessionStorage', storage({ 'oby.token': 'old' }));
  load(state({ status: null, connection: 'connecting' }));
  let resolveOld!: (response: Response) => void;
  const old = new Promise<Response>((resolve) => { resolveOld = resolve; });
  let startedOld = false;
  vi.stubGlobal('fetch', vi.fn(async (path: string, init: RequestInit) => {
    if (path === '/v1/events') return events(init.signal!);
    if (path === '/v1/status') return json(state().status);
    if (path === '/v1/jobs/missing') {
      if ((init.headers as Record<string, string>).Authorization === 'Bearer old') { startedOld = true; return old; }
      return json(job({ id: 'missing', title: 'Current answer' }));
    }
    if (path.startsWith('/v1/jobs')) return json([]);
    if (path.startsWith('/v1/conversation')) return json([turn({ jobs: ['missing'] })]);
    return json([]);
  }));
  connect();
  await until(() => startedOld);
  signedOut();
  signedIn('new');
  await until(() => live().jobs.missing?.title === 'Current answer');
  resolveOld(json(job({ id: 'missing', title: 'Stale answer' })));
  await settle(); await settle();
  expect(live().jobs.missing.title).toBe('Current answer');
});

for (const status of [200, 401]) {
  it(`ignores a stale plan's ${status} response and finally after a new session starts thinking`, async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 'old' }));
    load(state({ status: null, connection: 'connecting' }));
    let answerOld!: (response: Response) => void;
    let answerNew!: (response: Response) => void;
    const old = new Promise<Response>((resolve) => { answerOld = resolve; });
    const fresh = new Promise<Response>((resolve) => { answerNew = resolve; });
    vi.stubGlobal('fetch', vi.fn(async (path: string, init: RequestInit) => {
      if (path === '/v1/events') return events(init.signal!);
      if (path === '/v1/status') return json(state().status);
      if (path === '/v1/plans') return (init.headers as Record<string, string>).Authorization === 'Bearer old' ? old : fresh;
      return json([]);
    }));
    const first = ask('old request');
    signedOut();
    signedIn('new');
    await until(() => live().connection === 'live');
    const second = ask('new request');
    expect(live().thinking).toBe(true);
    answerOld(status === 401 ? json({ error: 'Old token refused' }, 401)
      : json({ kind: 'reply', text: 'Old reply', jobs: [job({ id: 'stale-plan' })], drafts: [] }));
    await first;
    expect(live().signedIn).toBe(true);
    expect(live().thinking).toBe(true);
    expect(live().jobs['stale-plan']).toBeUndefined();
    answerNew(json({ kind: 'reply', text: 'Current reply', jobs: [job({ id: 'current-plan' })], drafts: [] }));
    await second;
    expect(live().thinking).toBe(false);
    expect(live().jobs['current-plan']).toBeDefined();
  });
}

it('still accepts an action answer after the same auth session reconnects its stream', async () => {
  vi.stubGlobal('sessionStorage', storage({ 'oby.token': 'same' }));
  load(state({ status: null, connection: 'connecting' }));
  let answer!: (response: Response) => void;
  const plan = new Promise<Response>((resolve) => { answer = resolve; });
  let close!: () => void, streams = 0;
  vi.stubGlobal('fetch', vi.fn(async (path: string, init: RequestInit) => {
    if (path === '/v1/events') {
      if (++streams > 1) return events(init.signal!);
      return new Response(new ReadableStream<Uint8Array>({ start(controller) { close = () => controller.close(); } }));
    }
    if (path === '/v1/status') return json(state().status);
    if (path === '/v1/plans') return plan;
    return json([]);
  }));
  connect();
  await until(() => live().connection === 'live');
  const asking = ask('keep this result');
  close();
  await until(() => streams === 2 && live().connection === 'live');
  answer(json({ kind: 'reply', text: 'Still current', jobs: [job({ id: 'same-session' })], drafts: [] }));
  await asking;
  expect(live().jobs['same-session']).toBeDefined();
  expect(live().thinking).toBe(false);
});
