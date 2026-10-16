import { Menu } from './Menu';
import { dismissJob, stopJob } from './live';
import type { Task } from './tasks';

// A task's menu, from its side panel row (⋮ or right-click) or its page's title bar: its page
// (where it isn't already showing), its conversation; then stop it while it's going, or let it go
// once it needs you after failing (POST /v1/jobs/{id}/stop, /dismiss). Renaming, archiving and
// deleting a task come when the API has them.
export default function TaskMenu({ task, at, align = 'right', onClose, onViewDetails, onOpenChat }: {
  task: Task;
  at: DOMRect;
  align?: 'left' | 'right';
  onClose: () => void;
  onViewDetails?: () => void;  // left out on the task's own page
  onOpenChat: () => void;
}) {
  const pick = (fn: () => void) => () => { fn(); onClose(); };
  const j = task.job;
  const going = j.agent && (j.status === 'queued' || j.status === 'running');
  const failed = j.agent && j.ask?.kind === 'failed';
  return (
    <Menu at={at} align={align} onClose={onClose} height={140} width={168}>
      {onViewDetails && <button role="menuitem" onClick={pick(onViewDetails)}>View details</button>}
      {j.agent && <button role="menuitem" onClick={pick(onOpenChat)}>Open conversation</button>}
      {(going || failed) && <hr />}
      {going && <button role="menuitem" className="is-danger" onClick={pick(() => void stopJob(task.id))}>Stop task</button>}
      {failed && <button role="menuitem" onClick={pick(() => void dismissJob(task.id))}>Dismiss</button>}
    </Menu>
  );
}
