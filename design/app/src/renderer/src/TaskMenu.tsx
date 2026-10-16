import { Menu } from './Menu';
import { deleteTask, remove, stop, type Task } from './tasks';

// A task's menu, from its side panel row (⋮ or right-click) or its page's title
// bar: its page (where it isn't already showing), its conversation, rename;
// then stop it while it's going, or archive it once it's done (out of Home,
// into Archive); last, set apart, delete it.
export default function TaskMenu({ task, at, align = 'right', onClose, onViewDetails, onOpenChat, onRename }: {
  task: Task;
  at: DOMRect;
  align?: 'left' | 'right';
  onClose: () => void;
  onViewDetails?: () => void;  // left out on the task's own page
  onOpenChat: () => void;
  onRename: () => void;
}) {
  const pick = (fn: () => void) => () => { fn(); onClose(); };
  return (
    <Menu at={at} align={align} onClose={onClose} height={180} width={168}>
      {onViewDetails && <button role="menuitem" onClick={pick(onViewDetails)}>View details</button>}
      <button role="menuitem" onClick={pick(onOpenChat)}>Open conversation</button>
      <button role="menuitem" onClick={pick(onRename)}>Rename</button>
      {task.status === 'done'
        ? <button role="menuitem" onClick={pick(() => remove(task.id))}>Archive task</button>
        : <button role="menuitem" onClick={pick(() => stop(task.id))}>Stop task</button>}
      <hr />
      <button role="menuitem" className="is-danger" onClick={pick(() => deleteTask(task.id))}>Delete task</button>
    </Menu>
  );
}
