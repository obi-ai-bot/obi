import type { Message } from './mock';

// Oby's words come in a word at a time, as a model's do: its message goes in
// empty, then each word is added 35ms after the last (edit: the message, as it
// is now, changed). Shared by a task's conversation, a conversation with Oby
// and conversations with other Obys (peers.ts).
const WORD_MS = 35;
export const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
export async function streamWords(text: string, edit: (fn: (m: Message) => Message) => void) {
  const words = text.match(/\S+\s*/g) ?? [];
  for (let n = 1; n <= words.length; n++) {
    await wait(WORD_MS);
    edit((m) => ({ ...m, text: words.slice(0, n).join('') }));
  }
}
