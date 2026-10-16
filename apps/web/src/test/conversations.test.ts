import { afterEach, describe, expect, it, vi } from 'vitest';
import { parseEvent } from '../api';
import { apply, ask, live, load, signedOut, synced } from '../live';
import { state, storage, turn } from './fixtures';

// obid keeps many conversations (#493); this page shows one. Turns of the others never mix in.

const A = 'aaaaaaaa-0000-4000-8000-000000000001', B = 'bbbbbbbb-0000-4000-8000-000000000002';

afterEach(() => {
  signedOut();
  vi.unstubAllGlobals();
});

describe('the conversation the page shows', () => {
  it('takes turns of its own conversation, and none of another’s', () => {
    let s = state({ shown: A, turns: [turn({ id: 'a1', conversation: A })] });
    s = apply(s, { kind: 'turn', turn: turn({ id: 'b1', conversation: B, text: 'started on the Mac', at: '2026-10-16T10:05:00Z' }) });
    expect(s.turns.map((t) => t.id)).toEqual(['a1']);
    s = apply(s, { kind: 'turn', turn: turn({ id: 'a2', who: 'oby', conversation: A, at: '2026-10-16T10:06:00Z' }) });
    expect(s.turns.map((t) => t.id)).toEqual(['a1', 'a2']);
    expect(s.shown).toBe(A);
  });

  it('a runner from before #493 names no conversation: its turns are the one thread', () => {
    const s = apply(state({ shown: null }), { kind: 'turn', turn: turn({ id: 'x' }) });
    expect(s.turns.map((t) => t.id)).toEqual(['x']);
    expect(s.shown).toBeNull();
  });

  it('with none shown, the conversation its own words start is the one it shows; another device’s stays in the list', () => {
    expect(apply(state({ shown: null }), { kind: 'turn', turn: turn({ id: 'b0', conversation: B }) }).turns).toEqual([]);
    let s = apply(state({ shown: null, thinking: true, asking: null, saying: 'Fix it' }), { kind: 'turn', turn: turn({ id: 'a1', conversation: A }) });
    expect(s.shown).toBe(A);
    s = apply(s, { kind: 'turn', turn: turn({ id: 'b1', conversation: B }) });
    expect(s.turns.map((t) => t.id)).toEqual(['a1']);
  });

  it('is the latest when the page opens, and events that came meanwhile from another stay out', () => {
    const s = synced(state({ status: null, shown: null }), { status: state().status!, jobs: [], inbox: [], turns: [turn({ id: 'a1', conversation: A })], conversations: [] }, [
      { kind: 'turn', turn: turn({ id: 'b1', conversation: B }) },
      { kind: 'turn', turn: turn({ id: 'a2', conversation: A, at: '2026-10-16T10:01:00Z' }) },
    ]);
    expect(s.shown).toBe(A);
    expect(s.turns.map((t) => t.id)).toEqual(['a1', 'a2']);
  });

  it('deleted elsewhere, it empties; another’s deletion changes nothing', () => {
    const s = state({ shown: A, turns: [turn({ id: 'a1', conversation: A })] });
    expect(parseEvent('conversation', JSON.stringify({ id: A, deleted: true }))).toEqual({ kind: 'conversationGone', id: A });
    // a conversation event that isn't the shape the API says is ignored
    expect(parseEvent('conversation', JSON.stringify({ id: A, title: 'Renamed' }))).toBeNull();
    expect(apply(s, { kind: 'conversationGone', id: B }).turns).toHaveLength(1);
    const gone = apply(s, { kind: 'conversationGone', id: A });
    expect(gone.shown).toBeNull();
    expect(gone.turns).toEqual([]);
  });

  it('the page’s words go to the conversation it shows, not to whichever is latest', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ shown: A }));
    const fetch = vi.fn(async () => new Response(JSON.stringify({ kind: 'none', jobs: [], drafts: [], conversation: A }), { status: 200 }));
    vi.stubGlobal('fetch', fetch);
    await ask('how is it going?');
    const body = JSON.parse((fetch.mock.calls[0] as unknown as [string, RequestInit])[1].body as string);
    expect(body).toEqual({ said: 'how is it going?', conversation: A });
  });

  it('with none yet, its first words start one ("new": true), which it then shows', async () => {
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 't' }));
    load(state({ shown: null }));
    const fetch = vi.fn(async (path: string) => (path === '/v1/plans'
      ? new Response(JSON.stringify({ kind: 'reply', text: 'Fine.', jobs: [], drafts: [], conversation: A }), { status: 200 })
      : new Response(JSON.stringify([turn({ id: 'a1', conversation: A }), turn({ id: 'a2', who: 'oby', conversation: A })]), { status: 200 })));
    vi.stubGlobal('fetch', fetch);
    await ask('hello');
    expect(JSON.parse((fetch.mock.calls[0] as unknown as [string, RequestInit])[1].body as string)).toEqual({ said: 'hello', new: true });
    expect(fetch.mock.calls[1][0]).toBe(`/v1/conversation?id=${A}&limit=100`);
    expect(live().shown).toBe(A);
    expect(live().turns.map((t) => t.id)).toEqual(['a1', 'a2']);
  });
});
