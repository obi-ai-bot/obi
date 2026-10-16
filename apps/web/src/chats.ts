import type { Turn } from './api';
import { useLive, type Live } from './live';

// The conversation with Oby: obid keeps one thread for every device (GET /v1/conversation),
// which every message from Home's box joins (POST /v1/plans). Many conversations sharing one
// memory come with #493; until then this is the one, and the side panel's list of conversations
// stays behind Settings › General › "Show screens still being built".
//
// A message in a thread: who said it ('you', 'oby', or where a task came in from), what, and how
// many minutes ago (none: not known, as for what you told a job's agent). jobs: the tasks it
// started, shown as cards under it. details: Oby's longer answer under its short one.
export type Message = { who: string; text: string; ago?: number; jobs?: string[]; details?: string };
export type Chat = { id: string; title: string; said: Message[]; typing: boolean; step?: string };
export const CONVERSATION = 'oby';

const minutesAgo = (iso: string, now: number) => Math.max(0, (now - Date.parse(iso)) / 60_000);
export const toMessage = (t: Turn, now = Date.now()): Message => ({
  who: t.who === 'user' ? 'you' : 'oby', text: t.text, ago: minutesAgo(t.at, now), jobs: t.jobs.length ? t.jobs : undefined,
  details: t.details ?? undefined,
});

export function chatFrom(s: Live, now = Date.now()): Chat {
  const running = [...s.steps].reverse().find((x) => x.state === 'running');
  return {
    id: CONVERSATION, title: 'Conversation with Oby', said: s.turns.map((t) => toMessage(t, now)),
    typing: s.thinking, step: s.thinking ? running?.text ?? 'Thinking' : undefined,
  };
}

let cache: { s: Live; chat: Chat } | null = null;
export const useChat = () => {
  const s = useLive();
  if (cache?.s !== s) cache = { s, chat: chatFrom(s) };
  return cache.chat;
};

// The turn in the conversation that started a job, if it was started there: Oby's answer that
// carries it, and your words just before
export function startOf(s: Live, jobId: string): { asked?: Turn; answer: Turn } | undefined {
  const at = s.turns.findIndex((t) => t.who === 'oby' && t.jobs.includes(jobId));
  if (at < 0) return undefined;
  const before = s.turns[at - 1];
  return { asked: before?.who === 'user' ? before : undefined, answer: s.turns[at] };
}
