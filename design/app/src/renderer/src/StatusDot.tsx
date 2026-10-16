import { Check } from 'lucide-react';
import type { Task } from './tasks';

// A task's state as one mark in one spot, wherever the task is listed:
// new (blue, until you've opened it), needs you (orange), working (a grey dot
// pulsing slowly), done (a small grey check). Queued has no mark: being in the
// list unstarted says it (the spot stays, so rows line up).
// live: the state alone, leaving out new (where you're already looking at it).
type DotState = 'new' | 'needs' | 'working' | 'queued' | 'done';
const dotState = (t: Task, live = false): DotState =>
  !live && t.fresh ? 'new'
    : t.status === 'needs' ? 'needs'
      : t.status === 'done' ? 'done'
        : t.job.status === 'queued' ? 'queued' : 'working';
const LABEL: Record<DotState, string> = { new: 'New', needs: 'Needs you', working: 'Working', queued: 'Queued', done: 'Done' };

export default function StatusDot({ task, live = false }: { task: Task; live?: boolean }) {
  const state = dotState(task, live);
  return (
    <span className="status" role="img" aria-label={LABEL[state]}>
      {state === 'done' ? <Check size={12} strokeWidth={2} /> : state !== 'queued' && <span className={`status-dot is-${state}`} />}
    </span>
  );
}
