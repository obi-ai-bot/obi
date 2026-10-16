import { useSyncExternalStore } from 'react';
import { PEER_CONVOS, hasAttachments, type Attachments, type PeerConvo, type PeerMessage } from './mock';
import { streamWords, wait } from './stream';

// Your conversations with the other Obys in the Obysphere (mock.ts), as a small
// store: started from an Oby's page, added to in a conversation, answered by
// the Oby you're talking to. typing: the Oby writing its reply (its words then
// come in a word at a time, as your own Oby's do).
export type Convo = PeerConvo & { typing?: boolean };

let convos: Convo[] = PEER_CONVOS;
const listeners = new Set<() => void>();
const set = (next: Convo[]) => { convos = next; listeners.forEach((l) => l()); };
const subscribe = (l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; };
export const useConvos = () => useSyncExternalStore(subscribe, () => convos);

// an Oby's conversations, the latest first
const last = (c: Convo) => c.messages.at(-1)?.ago ?? 0;
export const convosWith = (all: Convo[], name: string) =>
  all.filter((c) => c.with.includes(name)).sort((a, b) => last(a) - last(b));

const update = (id: string, fn: (c: Convo) => Partial<Convo>) => set(convos.map((c) => (c.id === id ? { ...c, ...fn(c) } : c)));

// opened: its blue dot goes (and its Obys', unless another of theirs is unread)
export function markRead(id: string) {
  if (convos.some((c) => c.id === id && c.unread)) update(id, () => ({ unread: false }));
}
// an Oby has something unread: any of its conversations does
export const hasUnread = (all: Convo[], name: string) => all.some((c) => c.unread && c.with.includes(name));

// Its Oby answers after a moment of writing, as it would while it reads the message
const REPLY_MS = 1500;
async function reply(id: string, who: string, text: string) {
  update(id, () => ({ typing: true }));
  await wait(REPLY_MS);
  let at = 0;
  update(id, (c) => { at = c.messages.length; return { typing: false, messages: [...c.messages, { who, text: '', ago: 0, streaming: true }] }; });
  const edit = (fn: (m: PeerMessage) => PeerMessage) => update(id, (c) => ({ messages: c.messages.map((m, i) => (i === at ? fn(m) : m)) }));
  await streamWords(text, edit as Parameters<typeof streamWords>[1]);
  edit((m) => ({ ...m, streaming: undefined }));
}

// Said in a conversation: it goes on the end, and the Oby it's with (the first,
// in a group) says it'll pass it on.
export function say(id: string, text: string, att?: Attachments) {
  const t = text.trim(), c = convos.find((x) => x.id === id);
  if ((!t && !hasAttachments(att)) || !c) return;
  update(id, (k) => ({ messages: [...k.messages, { who: 'you', text: t, ago: 0, ...att }] }));
  void reply(id, c.with[0], `Got it. I’ll pass that to ${c.with[0]}.`);
}

// A new conversation with an Oby, named after your first words; returns its id.
let started = 0;
export function start(name: string, text: string, att?: Attachments) {
  const t = text.trim() || att?.files?.[0]?.name || '';
  if (!t && !hasAttachments(att)) return;
  const id = `pn${++started}`;
  const named = t || 'New conversation';
  const title = named.length > 48 ? `${named.slice(0, 45).trimEnd()}…` : named;
  set([{ id, title: title[0].toUpperCase() + title.slice(1), with: [name], messages: [{ who: 'you', text: text.trim(), ago: 0, ...att }] }, ...convos]);
  void reply(id, name, `Got it. I’ll check with ${name} and get back to you.`);
  return id;
}
