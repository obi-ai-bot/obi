import { afterEach, describe, expect, it, vi } from 'vitest';
import { ask, connect, live, load, signedOut, stopJob, synced, tellJob, withNew } from '../live';
import { job, state, storage, turn } from './fixtures';

// What the page does with obid's answers and its event stream, with fetch standing in for obid.

const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });
const settle = () => new Promise((r) => setTimeout(r, 0));
async function until(check: () => boolean) {
  for (let i = 0; i < 100 && !check(); i++) await settle();
  expect(check()).toBe(true);
}

afterEach(() => {
  signedOut();
  vi.unstubAllGlobals();
});

describe('events own a job’s state', () => {
  it('an answer adds the jobs the page doesn’t know, and leaves the ones it does', () => {
    const s = withNew(state({ jobs: { j1: job({ status: 'failed' }) } }), [job({ status: 'queued' }), job({ id: 'j2' })]);
    expect(s.jobs.j1.status).toBe('failed');
    expect(s.jobs.j2.status).toBe('running');
  });

  it('a plan’s answer doesn’t take a job back to queued after its event said it failed', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ jobs: { j1: job({ status: 'failed', step: '' }) } }));
    vi.stubGlobal('fetch', vi.fn(async () => json({ kind: 'reply', text: 'On it.', jobs: [job({ status: 'queued' })], drafts: [] })));
    await ask('fix it');
    expect(live().jobs.j1.status).toBe('failed');
  });

  it('nor does a message’s, or a stop’s, once the job moved on', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ jobs: { j1: job({ status: 'done', step: '' }) } }));
    vi.stubGlobal('fetch', vi.fn(async () => json(job({ status: 'running' }))));
    await tellJob('j1', 'one more thing');
    await stopJob('j1');
    expect(live().jobs.j1.status).toBe('done');
  });
});

describe('following obid', () => {
  it('applies the events that came during the first fetch over what it fetched', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ status: null, connection: 'connecting', jobs: {} }));
    let push!: (text: string) => void;
    const stream = new ReadableStream<Uint8Array>({ start(c) { push = (t) => c.enqueue(new TextEncoder().encode(t)); } });
    let answerJobs!: () => void;
    const jobsAnswered = new Promise<void>((r) => { answerJobs = r; });
    const fetch = vi.fn(async (path: string) => {
      if (path === '/v1/events') return new Response(stream, { status: 200 });
      if (path === '/v1/status') return json(state().status);
      if (path.startsWith('/v1/jobs')) { await jobsAnswered; return json([job({ status: 'queued' })]); }
      if (path === '/v1/inbox') return json([]);
      return json([turn()]);
    });
    vi.stubGlobal('fetch', fetch);
    connect();
    await until(() => fetch.mock.calls.some((c) => c[0] === '/v1/jobs?limit=100'));
    // the job moved on while its list was on the way
    push(`event: job\ndata: ${JSON.stringify(job({ status: 'done', step: '' }))}\n\n`);
    await settle();
    answerJobs();
    await until(() => live().connection === 'live');
    expect(live().jobs.j1.status).toBe('done');
    // and from then on, each event as it comes
    push(`event: job\ndata: ${JSON.stringify(job({ status: 'running', step: 'Again' }))}\n\n`);
    await until(() => live().jobs.j1.step === 'Again');
    // every call carried the token
    for (const [, init] of fetch.mock.calls as unknown as [string, RequestInit][]) {
      expect((init.headers as Record<string, string>).Authorization).toBe('Bearer t');
    }
  });

  it('a token obid refuses signs the page out and is forgotten', async () => {
    const kept = storage({ 'oby.token': 'old' });
    vi.stubGlobal('sessionStorage', kept);
    load(state({ status: null, connection: 'connecting' }));
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'This runner answers only requests with its API token.' }, 401)));
    connect();
    await until(() => !live().signedIn);
    expect(kept.getItem('oby.token')).toBeNull();
  });

  it('what came meanwhile wins over the snapshot, in the order it came', () => {
    const s = synced(state({ status: null }), { status: state().status!, jobs: [job({ status: 'queued' })], inbox: [], turns: [], conversations: [] }, [
      { kind: 'job', job: job({ status: 'running' }) },
      { kind: 'job', job: job({ status: 'done' }) },
    ]);
    expect(s.jobs.j1.status).toBe('done');
    expect(s.connection).toBe('live');
    expect(s.firstJobs.has('j1')).toBe(true);
  });
});
