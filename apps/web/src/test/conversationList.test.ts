import { afterEach, describe, expect, it, vi } from 'vitest';
import { parseEvent, type Conversation } from '../api';
import { NEW, aboutOf, isNew, layerOf, listOf, newStep, ordered, startedIn } from '../chats';
import { apply, ask, connect, deleteConversation, live, load, loadOlder, newConversation, openConversation, pinConversation, renameConversation, signedOut, synced } from '../live';
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
    let s = state({ shown: null, thinking: true, asking: null, saying: 'Fix it' });
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

  it('another device’s turn that comes first while this page starts one is not taken for it', () => {
    let s = state({ shown: null, thinking: true, asking: null, saying: 'how are the jobs?' });
    s = apply(s, { kind: 'turn', turn: turn({ id: 'b1', conversation: B, text: 'from the notch' }) });
    expect(s.shown).toBeNull();
    s = apply(s, { kind: 'turn', turn: turn({ id: 'c1', conversation: C, text: 'how are the jobs?' }) });
    expect(s.shown).toBe(C);
    expect(s.turns.map((t) => t.id)).toEqual(['c1']);
  });

  it('a turn of the conversation it moved to doesn’t make the one being started look like it', () => {
    const s = apply(state({ shown: B, thinking: true, asking: null }), { kind: 'turn', turn: turn({ id: 'b1', conversation: B }) });
    expect(s.asking).toBeNull();
  });

  it('deleted while open, its next words start a new conversation, shown there', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo()], shown: A, picked: true, turns: [turn({ conversation: A })] }));
    load(apply(live(), { kind: 'conversationGone', id: A }));
    const fetch = vi.fn(async (path: string) => (path === '/v1/plans'
      ? json({ kind: 'reply', text: 'Fine.', jobs: [], drafts: [], conversation: C })
      : json([turn({ id: 'c1', conversation: C, text: 'and now?' })])));
    vi.stubGlobal('fetch', fetch);
    await ask('and now?');
    expect(body(fetch.mock.calls[0])).toEqual({ said: 'and now?', new: true });
    expect(live().shown).toBe(C);
    expect(live().turns.map((t) => t.id)).toEqual(['c1']);
  });

  it('a delete obid refuses puts it back', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo(), convo({ id: B, lastActivity: '2026-10-16T08:00:00Z' })] }));
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'Couldn’t write it.' }, 500)));
    await deleteConversation(A);
    expect(live().conversations.map((c) => c.id)).toEqual([A, B]);
    expect(live().problem).toBe('Couldn’t write it.');
  });

  it('one gone when opened comes off the list', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo(), convo({ id: B })], shown: A }));
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'No such conversation.' }, 404)));
    await openConversation(B);
    expect(live().conversations.map((c) => c.id)).toEqual([A]);
    expect(live().shown).toBeNull();
  });

  it('one that failed to open opens again when picked again', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo(), convo({ id: B })], shown: A }));
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'Oby answered 500.' }, 500)));
    await openConversation(B);
    vi.stubGlobal('fetch', vi.fn(async () => json([turn({ id: 'b1', conversation: B })])));
    await openConversation(B);
    expect(live().turns.map((t) => t.id)).toEqual(['b1']);
  });

  it('a turn that comes while it opens isn’t lost', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo(), convo({ id: B })], shown: A }));
    let reply!: () => void;
    const replied = new Promise<void>((r) => { reply = r; });
    vi.stubGlobal('fetch', vi.fn(async () => { await replied; return json([turn({ id: 'b1', conversation: B })]); }));
    const opening = openConversation(B);
    load(apply(live(), { kind: 'turn', turn: turn({ id: 'b2', conversation: B, at: '2026-10-16T10:05:00Z' }) }));
    reply();
    await opening;
    expect(live().turns.map((t) => t.id)).toEqual(['b1', 'b2']);
  });

  it('earlier messages of one it left don’t come into the one it moved to', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo(), convo({ id: B })], shown: A, turns: [turn({ id: 'a2', conversation: A })], older: true }));
    let reply!: () => void;
    const replied = new Promise<void>((r) => { reply = r; });
    vi.stubGlobal('fetch', vi.fn(async (path: string) => {
      if (path.includes('before=')) { await replied; return json([turn({ id: 'a1', conversation: A, at: '2026-10-16T09:00:00Z' })]); }
      return json([turn({ id: 'b1', conversation: B })]);
    }));
    const older = loadOlder();
    await openConversation(B);
    reply();
    await older;
    expect(live().turns.map((t) => t.id)).toEqual(['b1']);
  });

  it('on New, a reconnect doesn’t put the latest conversation in its place', () => {
    const s = synced(state({ shown: null, picked: true }), { status: state().status!, jobs: [], inbox: [], turns: [turn({ id: 'a1', conversation: A })], conversations: [convo()] }, []);
    expect(s.shown).toBeNull();
    expect(s.turns).toEqual([]);
  });

  it('a snapshot of the conversation it left doesn’t replace the one it opened meanwhile', () => {
    const s = synced(state({ shown: B, picked: true, turns: [turn({ id: 'b1', conversation: B })] }), { status: state().status!, jobs: [], inbox: [], turns: [turn({ id: 'a1', conversation: A })], conversations: [convo()] }, []);
    expect(s.shown).toBe(B);
    expect(s.turns.map((t) => t.id)).toEqual(['b1']);
  });

  it('pages through every conversation by cursor, one per id', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ status: null, connection: 'connecting' }));
    const first = Array.from({ length: 200 }, (_, i) => convo({ id: `c${i}`, cursor: `0-${1000 - i}`, lastActivity: `2026-10-16T09:${String(i % 60).padStart(2, '0')}:00Z` }));
    const fetch = vi.fn(async (path: string) => {
      if (path === '/v1/events') return new Response(new ReadableStream(), { status: 200 });
      if (path === '/v1/status') return json(state().status);
      if (path === '/v1/conversations?limit=200') return json(first);
      if (path === '/v1/conversations?after=0-801&limit=200') return json([convo({ id: 'c199', cursor: '0-801' }), convo({ id: 'last', cursor: '0-1' })]);
      return json([]);
    });
    vi.stubGlobal('fetch', fetch);
    connect();
    for (let i = 0; i < 100 && live().connection !== 'live'; i++) await new Promise((r) => setTimeout(r, 0));
    expect(live().conversations).toHaveLength(201);
    expect(fetch.mock.calls.map((c) => c[0])).toContain('/v1/conversations?after=0-801&limit=200');
  });
});

describe('New', () => {
  it('is a page of its own each time, never the one a first New started (which is a conversation by now)', () => {
    const a = newStep(), b = newStep();
    expect(a).not.toBe(b);
    expect(isNew(a) && isNew(b)).toBe(true);
    expect(isNew(A)).toBe(false);
  });
});

describe('words to a conversation deleted before the page heard of it', () => {
  it('obid keeps none of them (404): it comes off the list, the page says so, and the next words start a new one', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo(), convo({ id: B, lastActivity: '2026-10-16T08:00:00Z' })], shown: A, picked: true, turns: [turn({ conversation: A })] }));
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'There’s no conversation with that id.' }, 404)));
    await ask('and the vault one?');
    expect(live().shown).toBeNull();
    expect(live().turns).toEqual([]);
    expect(live().conversations.map((c) => c.id)).toEqual([B]);
    expect(live().problem).toBe('That conversation was deleted, so your words weren’t sent. Send them again to start a new one.');
    const fetch = vi.fn(async (path: string) => (path === '/v1/plans' ? json({ kind: 'none', jobs: [], drafts: [], conversation: C }) : json([])));
    vi.stubGlobal('fetch', fetch);
    await ask('and the vault one?');
    expect(body(fetch.mock.calls[0])).toEqual({ said: 'and the vault one?', new: true });
  });
});

describe('the page a conversation is on', () => {
  it('New becomes the conversation its words started; a deleted one becomes New; one not yet listed stays itself', () => {
    expect(layerOf(NEW, null, false)).toBe(NEW);
    expect(layerOf(newStep(), C, false)).toBe(C);
    // obid answered with C before its conversation event came (the stream down): no flip back to New
    expect(layerOf(C, C, false)).toBe(C);
    // deleted: off the list, nothing shown
    expect(layerOf(A, null, false)).toBe(NEW);
    expect(layerOf(A, A, true)).toBe(A);
  });
});

describe('after a reconnect', () => {
  const settle = () => new Promise((r) => setTimeout(r, 0));
  it('a conversation deleted while it was away leaves none of its turns behind', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ status: null, connection: 'connecting', conversations: [convo()], shown: A, picked: true, turns: [turn({ id: 'a1', conversation: A })] }));
    vi.stubGlobal('fetch', vi.fn(async (path: string) => {
      if (path === '/v1/events') return new Response(new ReadableStream(), { status: 200 });
      if (path === '/v1/status') return json(state().status);
      if (path.startsWith(`/v1/conversation?id=${A}`)) return json({ error: 'No such conversation.' }, 404);
      return json([]);
    }));
    connect();
    for (let i = 0; i < 100 && live().connection !== 'live'; i++) await settle();
    expect(live().shown).toBeNull();
    expect(live().turns).toEqual([]);
  });

  it('the latest doesn’t replace one opened while it was already the one shown, once that one is deleted', () => {
    let s = state({ shown: A, picked: false, turns: [turn({ conversation: A })], conversations: [convo()] });
    s = apply(s, { kind: 'conversationGone', id: A });
    expect(s.picked).toBe(true);
    const after = synced(s, { status: state().status!, jobs: [], inbox: [], turns: [turn({ id: 'b1', conversation: B })], conversations: [convo({ id: B })] }, []);
    expect(after.shown).toBeNull();
  });

  it('opening the one already shown counts as picking it', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ shown: A, picked: false, turns: [turn({ conversation: A })], conversations: [convo()] }));
    await openConversation(A);
    expect(live().picked).toBe(true);
  });

  it('opened, left for New, and opened again before it loaded: it shows', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ shown: A, conversations: [convo(), convo({ id: B })] }));
    let reply!: () => void;
    const replied = new Promise<void>((r) => { reply = r; });
    vi.stubGlobal('fetch', vi.fn(async () => { await replied; return json([turn({ id: 'b1', conversation: B })]); }));
    const first = openConversation(B);
    newConversation();
    const second = openConversation(B);
    reply();
    await Promise.all([first, second]);
    expect(live().shown).toBe(B);
    expect(live().turns.map((t) => t.id)).toEqual(['b1']);
  });
});

describe('a conversation’s line in the list', () => {
  it('counts its tasks only when the page has every job since it started', () => {
    // the page fetched the latest page of jobs, from 08:00 on; an older one (j0) came in on its own
    const jobs = { j0: job({ id: 'j0', created: '2026-10-10T08:00:00Z' }), j1: job({ conversation: A, created: '2026-10-16T10:00:00Z' }) };
    expect(aboutOf(state({ jobs, jobsSince: '2026-10-16T08:00:00Z' }), convo({ created: '2026-10-16T09:00:00Z' }))).toBe('Started 1 task');
    expect(aboutOf(state({ jobs, jobsSince: '2026-10-16T08:00:00Z' }), convo({ created: '2026-10-15T09:00:00Z' }))).toBeUndefined();
    expect(aboutOf(state({ jobs, jobsSince: null }), convo({ created: '2026-10-15T09:00:00Z' }))).toBe('Started 1 task');
  });

  it('a rename keeps to obid’s rules: one line, control characters out, 100 characters, never half an emoji', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ conversations: [convo()] }));
    const fetch = vi.fn(async (_path: string) => json(convo()));
    vi.stubGlobal('fetch', fetch);
    await renameConversation(A, 'Vault\u0085 keys\nand more');
    expect(body(fetch.mock.calls[0]).title).toBe('Vault keys and more');
    await renameConversation(A, `${'a'.repeat(99)}😀😀`);
    expect(Array.from(body(fetch.mock.calls[1]).title as string)).toHaveLength(100);
    expect(body(fetch.mock.calls[1]).title).toBe(`${'a'.repeat(99)}😀`);
  });
});
