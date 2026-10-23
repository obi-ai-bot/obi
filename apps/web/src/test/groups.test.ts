import { afterEach, describe, expect, it, vi } from 'vitest';
import { askLabel, chipOf, getGroupBy, groupsOf, markOf, readGroupBy, setGroupBy, shownOf, tasksFrom, typeById, typesOn } from '../tasks';
import { item, job, state, storage } from './fixtures';

// Work grouped by kind (#496), as Sangam's design has it: Review PR, Issues, one group per teammate
// whose Oby asked you for something, Tasks; or by status. These are the rules the Mac's SwiftUI
// side panel follows too.

const NOW = Date.parse('2026-10-16T10:30:00Z');
const fromOby = (owner: string) => ({ correlationId: 'c', from: `obi-${owner}`, fromOwner: owner, requestId: 'r' });

afterEach(() => {
  setGroupBy('type');
  vi.unstubAllGlobals();
});

describe('by type', () => {
  it('a review request, an issue fix and a typed task land in three groups, in the design’s order', () => {
    const s = state({ jobs: {
      t: job({ id: 't', created: '2026-10-16T10:03:00Z' }),
      i: job({ id: 'i', issue: 12, created: '2026-10-16T10:02:00Z' }),
      r: job({ id: 'r', kind: 'review', pr: 33, created: '2026-10-16T10:01:00Z' }),
    } });
    expect(typesOn(s).map((t) => [t.id, t.label])).toEqual([['review', 'Review PR'], ['issues', 'Issues'], ['tasks', 'Tasks']]);
    expect(groupsOf(s, 'type').map((g) => [g.id, g.tasks.map((t) => t.id)])).toEqual([['review', ['r']], ['issues', ['i']], ['tasks', ['t']]]);
  });

  it('switching to Status regroups the same tasks: Needs you, Running, Completed', () => {
    const s = state({
      jobs: {
        r: job({ id: 'r', kind: 'review' }),
        i: job({ id: 'i', issue: 12, status: 'done', finished: '2026-10-16T10:20:00Z' }),
        t: job({ id: 't' }),
      },
      inbox: [item({ id: 'q', job: 't', kind: 'question' })],
    });
    expect(groupsOf(s, 'status').map((g) => [g.id, g.label, g.tasks.map((t) => t.id)])).toEqual([
      ['status:needs', 'Needs you', ['t']], ['status:running', 'Running', ['r']], ['status:done', 'Completed', ['i']],
    ]);
  });

  it('a request from Wellington’s Oby shows under Wellington, as its job and while it waits for you', () => {
    const s = state({
      jobs: { w: job({ id: 'w', kind: 'review', obi: fromOby('Wellington'), title: 'Review for Wellington: oby' }) },
      inbox: [item({ id: 'o1', job: '', kind: 'obiRequest', title: 'Review request from Dima', obi: { fromOwner: 'Dima' } })],
    });
    const groups = groupsOf(s, 'type');
    expect(groups.map((g) => [g.id, g.label])).toEqual([['from:Dima', 'Dima'], ['from:Wellington', 'Wellington']]);
    expect(groups[1].tasks[0]).toMatchObject({ id: 'w', who: 'Wellington' });
    expect(groups[0].tasks[0]).toMatchObject({ id: 'inbox:o1', status: 'needs' });
    expect(typeById('from:Wellington').label).toBe('Wellington');
  });

  it('a teammate group needs a field obid sends: no teammate group from a title alone', () => {
    const s = state({ jobs: { r: job({ id: 'r', kind: 'review', title: 'Review for Wellington: oby' }) } });
    expect(typesOn(s).map((t) => t.id)).toEqual(['review']);
  });

  it('there is no Routines group: obid has no routines yet (#395)', () => {
    expect(typeById('routines').id).not.toBe('routines');
  });

  it('a decision from neither a job nor a teammate goes to Inbox, last', () => {
    const s = state({ jobs: { t: job({ id: 't' }) }, inbox: [item({ id: 'p', job: '', kind: 'pluginEvent', title: 'A plug-in event' })] });
    expect(typesOn(s).map((t) => t.id)).toEqual(['tasks', 'inbox']);
    // An alert to look into is Issues' work, labelled by its tool (#1127, #1311, #1312); a plug-in's by its id.
    const alerts = state({ inbox: [
      item({ id: 'a', job: '', kind: 'pluginEvent', title: 'Sentry: API-7', options: ['Look into it', 'Dismiss'], plugin: { id: 'sentry' } }),
      item({ id: 'b', job: '', kind: 'pluginEvent', title: 'Alert: api (critical)', options: ['Look into it', 'Dismiss'], plugin: { id: 'alertmanager' } }),
      item({ id: 'c', job: '', kind: 'pluginEvent', title: 'Alert: x (critical)', options: ['Dismiss'], plugin: { id: 'alerts' } }),
    ] });
    expect(typesOn(alerts).map((t) => t.id)).toEqual(['issues', 'inbox']);
    expect(askLabel({ kind: 'pluginEvent', source: 'sentry' })).toBe('Sentry');
    expect(askLabel({ kind: 'pluginEvent', source: 'alertmanager' })).toBe('Prometheus');
    expect(askLabel({ kind: 'pluginEvent', source: 'alerts' })).toBe('From the alerts plug-in');
    expect(askLabel({ kind: 'pluginEvent' })).toBe('From a plug-in');
    // Put off, an offer is the inbox's, as on the Mac.
    const later = state({ inbox: [
      item({ id: 'd', job: '', kind: 'pluginEvent', title: 'Sentry: API-8', options: ['Look into it', 'Dismiss'], plugin: { id: 'sentry' }, state: 'later' }),
    ] });
    expect(typesOn(later).map((t) => t.id)).toEqual(['inbox']);
  });

  it('a group’s count is its open tasks; its orange dot counts what needs you', () => {
    const s = state({ jobs: {
      a: job({ id: 'a' }), b: job({ id: 'b', status: 'failed', finished: '2026-10-16T10:20:00Z' }),
      c: job({ id: 'c', status: 'done', finished: '2026-10-16T10:20:00Z' }),
    } });
    expect(groupsOf(s, 'type')[0]).toMatchObject({ id: 'tasks', count: 2, needs: 1 });
  });
});

describe('a group’s rows', () => {
  const doneAt = (id: string, min: number) => job({ id, status: 'done', finished: new Date(NOW - min * 60_000).toISOString() });

  it('everything open, then the latest 3 done, then Show more for the rest', () => {
    const s = state({ jobs: { o: job({ id: 'o' }), d1: doneAt('d1', 50), d2: doneAt('d2', 10), d3: doneAt('d3', 30), d4: doneAt('d4', 20), d5: doneAt('d5', 40) } });
    const g = groupsOf(s, 'type', NOW)[0];
    expect(shownOf(g, false)).toEqual({ rows: [g.tasks.find((t) => t.id === 'o'), ...['d2', 'd4', 'd3'].map((id) => g.tasks.find((t) => t.id === id))], hidden: 2 });
    expect(shownOf(g, true).rows.map((t) => t.id)).toEqual(['o', 'd2', 'd4', 'd3', 'd5', 'd1']);
  });

  it('by status, Completed keeps 5 before Show more', () => {
    const jobs = Object.fromEntries(Array.from({ length: 7 }, (_, i) => [`d${i}`, doneAt(`d${i}`, i + 1)]));
    const g = groupsOf(state({ jobs }), 'status', NOW).find((x) => x.id === 'status:done')!;
    expect(shownOf(g, false).rows.map((t) => t.id)).toEqual(['d0', 'd1', 'd2', 'd3', 'd4']);
    expect(shownOf(g, false).hidden).toBe(2);
  });
});

describe('marks', () => {
  it('one mark per row: new, needs you, working, queued, done', () => {
    const t = (over: Parameters<typeof job>[0], s = state({ firstJobs: new Set(['j1']) })) => markOf(tasksFrom({ ...s, jobs: { j1: job(over) } }, NOW)[0]);
    expect(markOf(tasksFrom(state({ jobs: { j1: job() } }), NOW)[0])).toBe('new');
    expect(t({ status: 'failed' })).toBe('needs');
    expect(t({})).toBe('working');
    expect(t({ status: 'queued' })).toBe('queued');
    expect(t({ status: 'done', finished: '2026-10-16T10:20:00Z' })).toBe('done');
    // where you're already looking at it, new isn't said
    expect(markOf(tasksFrom(state({ jobs: { j1: job() } }), NOW)[0], true)).toBe('working');
  });

  it('a chip has a blue dot for a new task and an orange dot when something in it needs you', () => {
    const s = state({ firstJobs: new Set(['old']), jobs: { old: job({ id: 'old', issue: 3, status: 'failed' }), fresh: job({ id: 'fresh' }) } });
    expect(chipOf(s, 'tasks')).toEqual({ fresh: true, needs: false });
    expect(chipOf(s, 'issues')).toEqual({ fresh: false, needs: true });
    expect(chipOf({ ...s, seen: new Set(['fresh']) }, 'tasks')).toEqual({ fresh: false, needs: false });
  });
});

describe('Group by, in Home’s ⋮', () => {
  it('is Type unless Status was picked, and remembered in this browser', () => {
    vi.stubGlobal('localStorage', storage());
    expect(getGroupBy()).toBe('type');
    setGroupBy('status');
    expect(getGroupBy()).toBe('status');
    expect(localStorage.getItem('oby.groupBy')).toBe('status');
    // the page opened again reads it back
    expect(readGroupBy()).toBe('status');
  });
});
