import { describe, expect, it } from 'vitest';
import { archivedTasks, countOf, metaOf, tasksFrom, toTask, typesOn } from '../tasks';
import { item, job, state } from './fixtures';

const NOW = Date.parse('2026-10-16T10:30:00Z');

describe('jobs as tasks', () => {
  it('a running job is running, with its round, stages and who has it', () => {
    const t = toTask(state(), job({ rounds: 4, round: 2 }), NOW);
    expect(t.status).toBe('running');
    expect(t.job.round).toEqual([2, 4]);
    expect(t.job.stages.map((s) => s.id)).toEqual(['prepare', 'work']);
    expect(t.job.created).toBe(30);
    expect(t.job.model).toBe('claude-opus-5-5');
    expect(metaOf(t)).toBe('Claude Code · Stub · fixture-app');
  });

  it('needs you while its inbox item is open, with the item’s options', () => {
    const t = toTask(state({ inbox: [item({ recommended: 0 })] }), job({ permission: { id: 'p', tool: 'Bash', title: 'Run rm', detail: 'rm -rf build', rule: null, always: null } }), NOW);
    expect(t.status).toBe('needs');
    expect(t.job.ask).toMatchObject({ kind: 'permission', item: 'i1', headline: 'Run rm -rf build', text: '', options: ['Allow', 'Deny'], recommended: 0, detail: 'rm -rf build' });
  });

  it('a failed job needs you until it is let go', () => {
    const failed = job({ status: 'failed', summary: 'Nothing committed: no change\nmore', finished: '2026-10-16T10:20:00Z' });
    const t = toTask(state(), failed, NOW);
    expect(t.status).toBe('needs');
    expect(t.job.ask).toMatchObject({ kind: 'failed', options: ['Dismiss'], text: 'Nothing committed: no change' });
    expect(toTask(state(), { ...failed, dismissed: '2026-10-16T10:25:00Z' }, NOW).status).toBe('done');
  });

  it('a job that arrived after the page opened is new until it is opened', () => {
    expect(toTask(state({ firstJobs: new Set(['j1']) }), job(), NOW).fresh).toBe(false);
    expect(toTask(state(), job(), NOW).fresh).toBe(true);
    expect(toTask(state({ seen: new Set(['j1']) }), job(), NOW).fresh).toBe(false);
  });

  it('a decision that belongs to no job is a task of the inbox, with Oby’s mark', () => {
    const tasks = tasksFrom(state({ inbox: [item({ id: 'o1', job: '', kind: 'obiRequest', title: 'Review a PR for Dima' })] }), NOW);
    expect(tasks).toHaveLength(1);
    expect(tasks[0]).toMatchObject({ id: 'inbox:o1', type: 'inbox', status: 'needs', title: 'Review a PR for Dima' });
    expect(tasks[0].job.agent).toBeNull();
    expect(metaOf(tasks[0])).toBe('Another Oby asks');
  });

  it('done jobs leave Home once Clear done was pressed after they finished', () => {
    const done = job({ status: 'done', finished: '2026-10-16T10:10:00Z' });
    const s = state({ jobs: { j1: done } });
    expect(countOf(s, 'done')).toBe(1);
    expect(archivedTasks(s)).toEqual([]);
    const cleared = { ...s, clearedAt: '2026-10-16T10:15:00Z' };
    expect(countOf(cleared, 'done')).toBe(0);
    expect(archivedTasks(cleared).map((a) => a.id)).toEqual(['j1']);
  });

  it('groups by kind of work: reviews, issues, the rest', () => {
    const s = state({ jobs: { a: job({ id: 'a', kind: 'review' }), b: job({ id: 'b', issue: 12 }), c: job({ id: 'c' }) } });
    expect(typesOn(s).map((t) => t.id)).toEqual(['review', 'issues', 'tasks']);
  });
});
