import { afterEach, describe, expect, it, vi } from 'vitest';
import { parseEvent, type Conversation } from '../api';
import { aboutOf, listOf, ordered, startedIn } from '../chats';
import { apply, ask, deleteConversation, live, load, newConversation, openConversation, pinConversation, renameConversation, signedOut, synced } from '../live';
import { job, state, storage, turn } from './fixtures';

// The side panel's Conversations (#493): obid's conversations, newest first, Pinned above Recent;
// search, rename, pin and delete; New starts one; opening one shows its turns.

const A = 'aaaaaaaa-0000-4000-8000-000000000001', B = 'bbbbbbbb-0000-4000-8000-000000000002', C = 'cccccccc-0000-4000-8000-000000000003';
const convo = (over: Partial<Conversation> = {}): Conversation => ({
  id: A, title: 'Vault questions', pinned: false, created: '2026-10-16T09:00:00Z', lastActivity: '2026-10-16T09:00:00Z', cursor: '0-1', ...over,
});
const json = (value: unknown, status = 200) => new Response(value === null ? null : JSON.stringify(value), { status });
const body = (call: unknown) => JSON.parse((call as [string, RequestInit])[1].body as string);

afterEach(() => {
  signedOut();
  vi.unstubAllGlobals();
});

describe('the list', () => {
  it('is newest first, pinned ones above the rest', () => {
    const list = ordered([
      convo({ id: A, lastActivity: '2026-10-16T09:00:00Z' }),
      convo({ id: B, lastActivity: '2026-10-16T11:00:00Z' }),
      convo({ id: C, lastActivity: '2026-10-16T08:00:00Z', pinned: true }),
    ]);
    expect(list.map((c) => c.id)).toEqual([C, B, A]);
    const s = state({ conversations: list });
    expect(listOf(s, '').pinned.map((c) => c.id)).toEqual([C]);
    expect(listOf(s, '').recent.map((c) => c.id)).toEqual([B, A]);
  });

  it('is fetched with the rest when the page opens, and kept in order by conversation events', () => {
    let s = synced(state({ status: null }), { status: state().status!, jobs: [], inbox: [], turns: [], conversations: [convo({ id: A }), convo({ id: B, lastActivity: '2026-10-16T08:00:00Z' })] }, []);
    expect(s.conversations.map((c) => c.id)).toEqual([A, B]);
    // B gets a turn: it moves to the top
    const e = parseEvent('conversation', JSON.stringify(convo({ id: B, lastActivity: '2026-10-16T10:00:00Z', cursor: '0-9' })));
    expect(e).toMatchObject({ kind: 'conversation' });
    s = apply(s, e!);
    expect(s.conversations.map((c) => c.id)).toEqual([B, A]);
    // a new one starts
    s = apply(s, { kind: 'conversation', conversation: convo({ id: C, title: 'New one', lastActivity: '2026-10-16T12:00:00Z' }) });
    expect(s.conversations.map((c) => c.id)).toEqual([C, B, A]);
    // one is deleted elsewhere
    s = apply(s, parseEvent('conversation', JSON.stringify({ id: B, deleted: true }))!);
    expect(s.conversations.map((c) => c.id)).toEqual([C, A]);
  });

  it('search keeps the ones whose title matches, whatever the case', () => {
    const s = state({ conversations: [convo({ id: A, title: 'Vault questions' }), convo({ id: B, title: 'Review oby PR #33', pinned: true })] });
    expect(listOf(s, 'VAULT').recent.map((c) => c.id)).toEqual([A]);
    expect(listOf(s, 'vault').pinned).toEqual([]);
    expect(listOf(s, '#33').pinned.map((c) => c.id)).toEqual([B]);
    expect(listOf(s, 'nothing like it')).toEqual({ pinned: [], recent: [] });
  });

  it('says what a conversation started, from the jobs that name it', () => {
    const s = state({ conversations: [convo()], jobs: { j1: job({ conversation: A }), j2: job({ id: 'j2', conversation: A }), j3: job({ id: 'j3', conversation: B }) } });
    expect(aboutOf(s, convo())).toBe('Started 2 tasks');
    expect(aboutOf(s, convo({ id: C }))).toBeUndefined();
  });
});

describe('acting on one', () => {
  it('rename sends the new title and shows it at once', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo()] }));
    const fetch = vi.fn(async (_path: string) => json(convo({ title: 'Secrets' })));
    vi.stubGlobal('fetch', fetch);
    const done = renameConversation(A, '  Secrets  ');
    expect(live().conversations[0].title).toBe('Secrets');
    await done;
    expect(fetch.mock.calls[0][0]).toBe(`/v1/conversations/${A}`);
    expect((fetch.mock.calls[0] as unknown as [string, RequestInit])[1].method).toBe('PATCH');
    expect(body(fetch.mock.calls[0])).toEqual({ title: 'Secrets' });
  });

  it('a rename to nothing, or to the same title, sends nothing; a refused one goes back', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo()] }));
    const fetch = vi.fn(async (_path: string) => json({ error: 'A title is one line.' }, 422));
    vi.stubGlobal('fetch', fetch);
    await renameConversation(A, '   ');
    await renameConversation(A, 'Vault questions');
    expect(fetch).not.toHaveBeenCalled();
    await renameConversation(A, 'Other');
    expect(live().conversations[0].title).toBe('Vault questions');
    expect(live().problem).toBe('A title is one line.');
  });

  it('pin moves it under Pinned', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo({ id: B, lastActivity: '2026-10-16T11:00:00Z' }), convo()] }));
    const fetch = vi.fn(async (_path: string) => json(convo({ pinned: true })));
    vi.stubGlobal('fetch', fetch);
    await pinConversation(A, true);
    expect(body(fetch.mock.calls[0])).toEqual({ pinned: true });
    expect(listOf(live(), '').pinned.map((c) => c.id)).toEqual([A]);
    expect(live().conversations.map((c) => c.id)).toEqual([A, B]);
  });

  it('delete takes it off the list and keeps its tasks, whose cards then open their own thread', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo()], shown: A, turns: [turn({ conversation: A, who: 'oby', jobs: ['j1'] })], jobs: { j1: job({ conversation: A }) } }));
    expect(startedIn(live(), 'j1')).toBe(A);
    const fetch = vi.fn(async (_path: string) => json(null, 204));
    vi.stubGlobal('fetch', fetch);
    await deleteConversation(A);
    expect(fetch.mock.calls[0][0]).toBe(`/v1/conversations/${A}`);
    expect((fetch.mock.calls[0] as unknown as [string, RequestInit])[1].method).toBe('DELETE');
    expect(live().conversations).toEqual([]);
    expect(live().shown).toBeNull();
    expect(live().jobs.j1).toBeDefined();
    expect(startedIn(live(), 'j1')).toBeUndefined();
  });

  it('opening one shows its turns', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo(), convo({ id: B })], shown: A, turns: [turn({ id: 'a1', conversation: A })] }));
    const fetch = vi.fn(async (_path: string) => json([turn({ id: 'b1', conversation: B }), turn({ id: 'b2', who: 'oby', conversation: B, at: '2026-10-16T10:01:00Z' })]));
    vi.stubGlobal('fetch', fetch);
    await openConversation(B);
    expect(fetch.mock.calls[0][0]).toBe(`/v1/conversation?id=${B}&limit=100`);
    expect(live().shown).toBe(B);
    expect(live().turns.map((t) => t.id)).toEqual(['b1', 'b2']);
    // and its turns come in live; A's stay out now
    load(apply(live(), { kind: 'turn', turn: turn({ id: 'a2', conversation: A }) }));
    expect(live().turns.map((t) => t.id)).toEqual(['b1', 'b2']);
  });

  it('New sends "new": true, and the conversation it starts is the one shown', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo()], shown: A, turns: [turn({ id: 'a1', conversation: A })] }));
    newConversation();
    expect(live().shown).toBeNull();
    expect(live().turns).toEqual([]);
    const fetch = vi.fn(async (path: string) => (path === '/v1/plans'
      ? json({ kind: 'reply', text: 'Fine.', jobs: [], drafts: [], conversation: C })
      : json([turn({ id: 'c1', conversation: C })])));
    vi.stubGlobal('fetch', fetch);
    await ask('how are the jobs?');
    expect(body(fetch.mock.calls[0])).toEqual({ said: 'how are the jobs?', new: true });
    expect(live().shown).toBe(C);
  });

  it('Home’s box always starts a new one, even while another is shown', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo()], shown: A }));
    const fetch = vi.fn(async (path: string) => (path === '/v1/plans'
      ? json({ kind: 'none', jobs: [], drafts: [], conversation: C })
      : json([])));
    vi.stubGlobal('fetch', fetch);
    await ask('review oby PR 12', undefined, { new: true });
    expect(body(fetch.mock.calls[0])).toEqual({ said: 'review oby PR 12', new: true });
    expect(live().shown).toBe(C);
  });

  it('a new one’s first turn is taken in while Oby thinks; another device’s new one is not', () => {
    let s = state({ shown: null, thinking: true, asking: null });
    s = apply(s, { kind: 'turn', turn: turn({ id: 'c1', conversation: C }) });
    expect(s.shown).toBe(C);
    expect(s.asking).toBe(C);
    s = apply(s, { kind: 'turn', turn: turn({ id: 'b1', conversation: B }) });
    expect(s.turns.map((t) => t.id)).toEqual(['c1']);
  });

  it('switching away while Oby answers keeps the answer’s conversation out of the one now shown', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo(), convo({ id: B })], shown: A }));
    let answer!: () => void;
    const answered = new Promise<void>((r) => { answer = r; });
    const fetch = vi.fn(async (path: string) => {
      if (path === '/v1/plans') { await answered; return json({ kind: 'reply', text: 'Done.', jobs: [], drafts: [], conversation: A }); }
      return json([turn({ id: 'b1', conversation: B })]);
    });
    vi.stubGlobal('fetch', fetch);
    const asking = ask('and the vault one?');
    await openConversation(B);
    answer();
    await asking;
    expect(live().shown).toBe(B);
    expect(live().turns.map((t) => t.id)).toEqual(['b1']);
  });
});
