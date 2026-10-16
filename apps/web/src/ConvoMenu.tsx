import type { Conversation } from './api';
import { Menu } from './Menu';
import { deleteConversation, pinConversation } from './live';

// A conversation's menu, from its side panel row (⋮ or right-click): pin it to the top (or unpin),
// rename; last, set apart, delete it (its tasks stay, and their cards open their own thread).
export default function ConvoMenu({ convo, at, align = 'right', onClose, onRename }: {
  convo: Conversation;
  at: DOMRect;
  align?: 'left' | 'right';
  onClose: () => void;
  onRename: () => void;
}) {
  const pick = (fn: () => void) => () => { fn(); onClose(); };
  return (
    <Menu at={at} align={align} onClose={onClose} height={130} width={168}>
      <button role="menuitem" onClick={pick(() => void pinConversation(convo.id, !convo.pinned))}>{convo.pinned ? 'Unpin' : 'Pin'}</button>
      <button role="menuitem" onClick={pick(onRename)}>Rename</button>
      <hr />
      <button role="menuitem" className="is-danger" onClick={pick(() => void deleteConversation(convo.id))}>Delete conversation</button>
    </Menu>
  );
}
