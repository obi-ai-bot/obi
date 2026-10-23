import { describe, expect, it } from 'vitest';
import { apply, CONFIRM_IN_APP, confirmsInBrowser } from '../live';
import { item, job, state, turn } from './fixtures';

describe('events over what the page shows', () => {
  it('replaces a job by its id', () => {
    const s = apply(state({ jobs: { j1: job() } }), { kind: 'job', job: job({ status: 'done', step: '' }) });
    expect(s.jobs.j1.status).toBe('done');
  });

  it('keeps open and put-off inbox items, drops settled ones, and the answer given here with them', () => {
    let s = apply(state(), { kind: 'inbox', item: item() });
    expect(s.inbox.map((i) => i.id)).toEqual(['i1']);
    s = apply({ ...s, answering: { i1: 'Allow' } }, { kind: 'inbox', item: item({ state: 'later', later: '2026-10-16T12:00:00Z' }) });
    expect(s.inbox).toHaveLength(1);
    expect(s.answering).toEqual({ i1: 'Allow' });
    s = apply(s, { kind: 'inbox', item: item({ state: 'done', answer: 'Allow' }) });
    expect(s.inbox).toEqual([]);
    expect(s.answering).toEqual({});
  });

  it('adds a turn in time order, and replaces one that changed', () => {
    let s = state({ turns: [turn({ id: 'a', at: '2026-10-16T10:00:00Z' }), turn({ id: 'c', at: '2026-10-16T10:02:00Z' })] });
    s = apply(s, { kind: 'turn', turn: turn({ id: 'b', who: 'oby', at: '2026-10-16T10:01:00Z' }) });
    expect(s.turns.map((t) => t.id)).toEqual(['a', 'b', 'c']);
    s = apply(s, { kind: 'turn', turn: turn({ id: 'b', who: 'oby', at: '2026-10-16T10:01:00Z', jobs: ['j1'] }) });
    expect(s.turns.map((t) => t.id)).toEqual(['a', 'b', 'c']);
    expect(s.turns[1].jobs).toEqual(['j1']);
  });

  it('follows the steps only of a plan this page is waiting on', () => {
    const step = { turn: 't', index: 1, action: 'research', text: 'Searching', state: 'running' as const, at: '2026-10-16T10:00:00Z' };
    expect(apply(state(), { kind: 'step', step }).steps).toEqual([]);
    const s = apply(state({ thinking: true }), { kind: 'step', step });
    expect(apply(s, { kind: 'step', step: { ...step, state: 'done' } }).steps).toEqual([{ ...step, state: 'done' }]);
  });

  it('takes accounts and Clear done as they come', () => {
    const s = apply(state(), { kind: 'accounts', accounts: [] });
    expect(s.status?.accounts).toEqual([]);
    expect(apply(s, { kind: 'clear', clearedAt: '2026-10-16T10:00:00Z' }).clearedAt).toBe('2026-10-16T10:00:00Z');
  });
});

describe('Confirm in a browser (#776)', () => {
  it('sends nothing and says where to confirm; Cancel and other items go as before', () => {
    expect(confirmsInBrowser(item({ kind: 'confirm' }), 'Confirm')).toBe(CONFIRM_IN_APP);
    expect(confirmsInBrowser(item({ kind: 'confirm' }), 'Cancel')).toBeNull();
    expect(confirmsInBrowser(item({ kind: 'question' }), 'Confirm')).toBeNull();
    expect(confirmsInBrowser(undefined, 'Confirm')).toBeNull();
  });
});
