import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiError, api, openEvents, parseEvent, sseReader } from '../api';
import { job, storage } from './fixtures';

describe('the event stream', () => {
  it('reads the events the app follows', () => {
    expect(parseEvent('job', JSON.stringify(job()))).toEqual({ kind: 'job', job: job() });
    expect(parseEvent('clear', '{"clearedAt":"2026-10-16T10:00:00Z"}')).toEqual({ kind: 'clear', clearedAt: '2026-10-16T10:00:00Z' });
    expect(parseEvent('accounts', '[]')).toEqual({ kind: 'accounts', accounts: [] });
    expect(parseEvent('turn', '{"id":"t","who":"oby","text":"Hi","at":"2026-10-16T10:00:00Z","jobs":[]}')?.kind).toBe('turn');
  });
  it('ignores what it doesn’t follow, and what isn’t the shape the API says', () => {
    expect(parseEvent('check', '{"id":"c"}')).toBeNull();
    expect(parseEvent('job', 'not json')).toBeNull();
    expect(parseEvent('job', '{"status":"running"}')).toBeNull();
    expect(parseEvent('accounts', '{}')).toBeNull();
    expect(parseEvent('inbox', 'null')).toBeNull();
  });
});

describe('calls', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('sends the token the tab holds as a bearer, never a cookie', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 'tok-123' }));
    const fetch = vi.fn(async () => new Response(JSON.stringify({ kind: 'none', jobs: [], drafts: [] }), { status: 200 }));
    vi.stubGlobal('fetch', fetch);
    await api.plan('Fix #12', { question: 'Which repository?', option: 'obi-e2e/fixture-app' });
    const [path, init] = fetch.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe('/v1/plans');
    expect(init.method).toBe('POST');
    expect(init.credentials).toBe('omit');
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer tok-123');
    expect(JSON.parse(init.body as string)).toEqual({ said: 'Fix #12', answer: { question: 'Which repository?', option: 'obi-e2e/fixture-app' } });
    // the event stream too, which is why it's a fetch and not an EventSource
    fetch.mockClear();
    await openEvents(new AbortController().signal);
    const [eventsPath, eventsInit] = fetch.mock.calls[0] as unknown as [string, RequestInit];
    expect(eventsPath).toBe('/v1/events');
    expect(eventsInit.credentials).toBe('omit');
    expect((eventsInit.headers as Record<string, string>).Authorization).toBe('Bearer tok-123');
    // checking a token sends that one
    fetch.mockClear();
    await api.check('other-456');
    expect(((fetch.mock.calls[0] as unknown as [string, RequestInit])[1].headers as Record<string, string>).Authorization).toBe('Bearer other-456');
  });

  it('sends no Authorization at all when the tab holds no token', async () => {
    vi.stubGlobal('sessionStorage', storage());
    const fetch = vi.fn(async () => new Response('{"error":"no"}', { status: 401 }));
    vi.stubGlobal('fetch', fetch);
    await expect(api.status()).rejects.toMatchObject({ status: 401 });
    expect((fetch.mock.calls[0] as unknown as [string, RequestInit])[1].headers).not.toHaveProperty('Authorization');
  });

  it('says what the runner said when it refuses', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{"error":"The job can’t take it."}', { status: 422 })));
    await expect(api.message('j1', 'more')).rejects.toEqual(new ApiError(422, 'The job can’t take it.'));
    vi.stubGlobal('fetch', vi.fn(async () => new Response('<html>', { status: 502 })));
    await expect(api.jobs()).rejects.toMatchObject({ status: 502, message: 'Oby answered 502.' });
    vi.stubGlobal('fetch', vi.fn(async () => { throw new TypeError('Failed to fetch'); }));
    await expect(api.status()).rejects.toMatchObject({ status: 0 });
  });

  it('names its paths as the API does', async () => {
    const fetch = vi.fn(async () => new Response('[]', { status: 200 }));
    vi.stubGlobal('fetch', fetch);
    await api.conversation({ before: 'a b', limit: 100 });
    await api.answer('ab12-question-0', { later: '2026-10-16T11:00:00Z' });
    await api.jobs(100);
    const paths = fetch.mock.calls.map((c) => (c as unknown as [string])[0]);
    expect(paths).toEqual(['/v1/conversation?before=a+b&limit=100', '/v1/inbox/ab12-question-0/answer', '/v1/jobs?limit=100']);
  });
});

describe('the stream as it comes in', () => {
  it('reads events split anywhere, with comments, CRLF and data on several lines', () => {
    const got: [string, string][] = [];
    const read = sseReader((name, data) => got.push([name, data]));
    for (const piece of ['event: jo', 'b\ndata: {"id":', '"j1"}\n', '\n: ping\n\nevent: turn\r', '\ndata: a\r\ndata: b\r\n\r\n', 'data: plain\n\n']) read(piece);
    expect(got).toEqual([['job', '{"id":"j1"}'], ['turn', 'a\nb'], ['message', 'plain']]);
  });
  it('holds an event until its empty line comes', () => {
    const got: string[] = [];
    const read = sseReader((name) => got.push(name));
    read('event: job\ndata: {}\n');
    expect(got).toEqual([]);
    read('\n');
    expect(got).toEqual(['job']);
  });
});
