import type { Conversation, Turn } from './api';
import { useLive, type Live } from './live';

// Conversations with Oby. obid keeps many (#493, "obid only: conversations" in runner-api.md):
// the side panel lists them, pinned ones first, then newest first, as Sangam's design does
// (design/app chats.ts, Sidebar.tsx). The page shows one at a time (live.ts): the latest when it
// opened, the one picked in the list, or the one its words start (Home's message box and New
// start one with "new": true). Its titles are obid's: the first line said in it, until renamed.
// What's decided in one conversation reaching the others (#378) isn't in obid yet; nothing here
// pretends it is.
//
// A message in a thread: who said it ('you', 'oby', or where a task came in from), what, and how
// many minutes ago (none: not known, as for what you told a job's agent). id: what it is in the
// thread for good (a turn's id), as earlier ones come in above it. jobs: the tasks it started,
// shown as cards under it. details: Oby's longer answer under its short one.
export type Message = { id: string; who: string; text: string; ago?: number; jobs?: string[]; details?: string };
export type Chat = { id: string | null; title: string; said: Message[]; typing: boolean; step?: string };
// the conversation step of a page that's starting one: none shown until its first words land.
// Each New is a step of its own (newStep), so a second New never reuses the first one's page.
export const NEW = 'new';
let news = 0;
export const newStep = () => `${NEW}:${++news}`;
export const isNew = (id: string) => id === NEW || id.startsWith(`${NEW}:`);

// Which conversation a conversation's page is for, as things change while it's on top: New
// becomes the one its words started; one deleted (off the list, no longer shown) becomes New, so
// the next words start one shown there; one the page shows but the list doesn't have yet (its
// event still on the way) stays what it is.
export function layerOf(own: string, shown: string | null, listed: boolean): string {
  if (isNew(own)) return shown ?? own;
  return !listed && own !== shown ? NEW : own;
}
export const NEW_TITLE = 'New conversation';

// The list's order: pinned first, then by their latest turn, newest first (obid's own order, which
// the `conversation` events keep up to date)
export function ordered(list: Conversation[]): Conversation[] {
  return [...list].sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.lastActivity.localeCompare(a.lastActivity));
}

// The side panel's list, matching a search (by title, any case): under Pinned, and under Recent
export function listOf(s: Live, query: string): { pinned: Conversation[]; recent: Conversation[] } {
  const q = query.trim().toLowerCase();
  const found = s.conversations.filter((c) => !q || c.title.toLowerCase().includes(q));
  return { pinned: found.filter((c) => c.pinned), recent: found.filter((c) => !c.pinned) };
}

// A row's line under its title: the tasks it started (the jobs that name it), if any. Only when
// the page has every job since it started (it fetches the latest page of jobs), so it never says
// fewer than there are.
export function aboutOf(s: Live, c: Conversation): string | undefined {
  if (s.jobsSince && c.created < s.jobsSince) return undefined;
  const n = Object.values(s.jobs).filter((j) => j.conversation === c.id).length;
  return n ? `Started ${n} task${n === 1 ? '' : 's'}` : undefined;
}

// The conversation a job was started in, while it's still there (deleted, the job keeps its id,
// and its card opens its own thread)
export function startedIn(s: Live, jobId: string): string | undefined {
  const id = s.jobs[jobId]?.conversation;
  return id && s.conversations.some((c) => c.id === id) ? id : undefined;
}

export const titleOf = (s: Live, id: string | null) => s.conversations.find((c) => c.id === id)?.title ?? (id ? 'Conversation with Oby' : NEW_TITLE);

const minutesAgo = (iso: string, now: number) => Math.max(0, (now - Date.parse(iso)) / 60_000);
export const toMessage = (t: Turn, now = Date.now()): Message => ({
  id: t.id, who: t.who === 'user' ? 'you' : 'oby', text: t.text, ago: minutesAgo(t.at, now), jobs: t.jobs.length ? t.jobs : undefined,
  details: t.details ?? undefined,
});

// The conversation the page shows. Oby is at work on it only when the plan under way is in it.
export function chatFrom(s: Live, now = Date.now()): Chat {
  const running = [...s.steps].reverse().find((x) => x.state === 'running');
  const typing = s.thinking && s.asking === s.shown;
  return {
    id: s.shown, title: titleOf(s, s.shown), said: s.turns.map((t) => toMessage(t, now)),
    typing, step: typing ? running?.text ?? 'Thinking' : undefined,
  };
}

let cache: { s: Live; chat: Chat } | null = null;
export const useChat = () => {
  const s = useLive();
  if (cache?.s !== s) cache = { s, chat: chatFrom(s) };
  return cache.chat;
};

// The turn in the conversation shown that started a job, if it was started there: Oby's answer
// that carries it, and your words just before
export function startOf(s: Live, jobId: string): { asked?: Turn; answer: Turn } | undefined {
  const at = s.turns.findIndex((t) => t.who === 'oby' && t.jobs.includes(jobId));
  if (at < 0) return undefined;
  const before = s.turns[at - 1];
  return { asked: before?.who === 'user' ? before : undefined, answer: s.turns[at] };
}
