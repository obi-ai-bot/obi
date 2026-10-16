import { Menu } from './Menu';
import { deleteChat, pinChat, type Chat } from './chats';

// A conversation's menu, from its side panel row (⋮ or right-click) or its
// page's title bar: pin it to the top (or unpin), rename; last, set apart, delete it.
export default function ConvoMenu({ chat, at, align = 'right', onClose, onRename }: {
  chat: Chat;
  at: DOMRect;
  align?: 'left' | 'right';
  onClose: () => void;
  onRename: () => void;
}) {
  const pick = (fn: () => void) => () => { fn(); onClose(); };
  return (
    <Menu at={at} align={align} onClose={onClose} height={130} width={168}>
      <button role="menuitem" onClick={pick(() => pinChat(chat.id, !chat.pinned))}>{chat.pinned ? 'Unpin' : 'Pin'}</button>
      <button role="menuitem" onClick={pick(onRename)}>Rename</button>
      <hr />
      <button role="menuitem" className="is-danger" onClick={pick(() => deleteChat(chat.id))}>Delete conversation</button>
    </Menu>
  );
}
