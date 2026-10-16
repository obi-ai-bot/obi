import { useSyncExternalStore } from 'react';
import { JOBS, TURNS as LOG, convoTitle, followUpsOf, hasAttachments, type Attachments, type Message } from './mock';
import { addTask, relay } from './tasks';
import { streamWords, wait } from './stream';

// A conversation with Oby: what you asked, its answers, and the tasks they
// started (a card under the answer that started each). Asking Oby (Home's
// message box) starts one; a reply in it carries it on. A conversation is
// never a task itself: a task exists only once Oby starts one. Conversations lists
// them, newest first. typing: Oby at work on an answer (step: what it's on).
// waiting: Oby asking you something it needs before it can go on, held over the
// message box until you answer (a pick, or anything you type). pinned: kept
// at the top of Conversations, under Pinned
type Ask = { question: string; options: string[] };
export type Chat = { id: string; title: string; said: Message[]; typing?: boolean; step?: string; waiting?: Ask; pinned?: boolean };

// named after its first line, as Oby would title it
const titled = (text: string) => {
  const line = text.trim().split('\n')[0];
  const t = line.length > 48 ? `${line.slice(0, 45).trimEnd()}…` : line;
  return t[0].toUpperCase() + t.slice(1);
};

// The mock's past conversations: your log with Oby (mock.ts), a new one each
// time you asked something, each with what's been said since about the tasks
// it started (so a task's conversation is the whole of it, not just its part)
const seeded: Chat[] = LOG.flatMap((t, i) => {
  if (t.who !== 'user') return [];
  const said: Message[] = [{ who: 'you', text: t.text, ago: t.at }];
  for (let k = i + 1; k < LOG.length && LOG[k].who === 'oby'; k++) said.push({ who: 'oby', text: LOG[k].text, ago: LOG[k].at, jobs: LOG[k].jobs });
  const jobs = said.flatMap((m) => m.jobs ?? []);
  said.push(...jobs.flatMap(followUpsOf));
  said.sort((a, b) => b.ago - a.ago);
  const first = JOBS.find((j) => j.id === jobs[0]);
  return [{ id: `c-${t.id}`, title: first ? convoTitle(first) : titled(t.text), said }];
});
// Older ones, over the last five weeks: questions Oby answered on the spot,
// nothing started (most of what you ask it is like this; a task is the exception)
const H = 60, D = 24 * H;
const PAST: [title: string, asked: string, answer: string, ago: number][] = [
  ['Who owns the Vault migration?', 'who owns the vault migration now that Ernesto moved teams?', 'Dima took it over on Monday. Ernesto is still the reviewer for anything touching Engine/Vault.swift.', 2 * D + 3 * H],
  ['Why is oberon’s build slow', 'why did oberon’s build go from 4 to 11 minutes?', 'The Swift package cache stopped hitting after the runner image update on the 3rd. Daniel has a fix in review (#412); it brings the build back to about 5 minutes.', 2 * D + 6 * H],
  ['Standup notes for Wellington', 'what did I tell Wellington I’d do this week?', 'Three things: review the notch PR (#33, done), send the 0.9 release checklist (not yet), and pair on the settings layout Thursday.', 3 * D + 2 * H],
  ['Avenga contract renewal date', 'when does the Avenga contract renew?', 'March 31. The notice period is 60 days, so anything you want changed needs to reach them by January 30.', 3 * D + 9 * H],
  ['Rate limits on the Tetrix API', 'what are our rate limits on the tetrix api?', '600 requests a minute per org, 60 per connector. The graph queries count double. You hit 70% of it last Tuesday during the backfill.', 4 * D + 1 * H],
  ['Summarize #398 discussion', 'summarize the discussion on #398', 'Dima wants the graph tests split per collector; Ernesto prefers one suite with fixtures. They agreed on fixtures first, split later. Nothing’s blocking it except the shared fixture.', 4 * D + 5 * H],
  ['Is Codex cheaper for reviews?', 'is codex cheaper than claude for PR reviews?', 'For us, yes: about 40% less per review last month, but its reviews got 2x more “not useful” reactions. Claude is still the default for anything over 300 lines.', 5 * D + 4 * H],
  ['Draft reply to Avenga security', 'help me reply to Avenga’s security questionnaire, section 4', 'Here’s a draft for section 4: encryption at rest (AES-256 via the Vault), in transit (TLS 1.3), keys rotated every 90 days. I left 4.3 for you, it asks about subprocessors.', 6 * D + 2 * H],
  ['What changed in Lexical 0.52', 'anything in lexical 0.52 that affects us?', 'One thing: selection is kept after blur now, which is why the message box re-focused itself. The rest is fixes. MessageEditor already handles it.', 7 * D + 3 * H],
  ['Daniel’s PTO next week', 'is Daniel out next week?', 'Wednesday to Friday. His Oby will hand #405 to Ernesto if it isn’t merged by Tuesday.', 8 * D + 1 * H],
  ['Explain the queue order bug', 'explain the live panel queue order bug like I’m new', 'The live panel sorts by when a task started, the inbox by when it last changed. A task that’s been waiting on you for a day shows at the bottom of one and the top of the other.', 9 * D + 6 * H],
  ['Onboarding checklist for Ana', 'what does Ana need on her first day?', 'GitHub and Slack invites (sent), a Personal account for Claude Code, Vault access for staging only, and the Obysphere invite. I’ve kept production out until her second week.', 11 * D],
  ['Compare notch PR approaches', 'compare Wellington’s two notch approaches', 'The first tracks the mouse every frame (smooth, 3% CPU idle); the second listens for screen-edge events (0% idle, a slight delay). He’s leaning to the second.', 12 * D + 4 * H],
  ['Last month’s agent spend', 'how much did we spend on agents last month?', '$2,140 across both accounts: $1,610 on Deskree, $530 on Personal. Up 18% from the month before, mostly the security inspections.', 14 * D + 2 * H],
  ['Who reviewed #380?', 'who reviewed #380 and did they approve?', 'Ernesto approved it with two nits; Wellington left a comment but no approval. It merged on the 2nd.', 16 * D + 5 * H],
  ['Postmortem for the DST outage', 'write up what happened with the DST outage', 'Draft’s ready: schedules ran an hour early for 2 days after the clock change because nextRun used local time. Fixed in #377, test added. I left the “what we’ll change” section for you.', 19 * D],
  ['Status bar spacing values', 'what spacing does the status bar use?', '8px between items, 12px from the edges, 22px tall. Wellington changed it from 6px last week; docs/status-bar.md still says 6.', 22 * D + 3 * H],
  ['Plan for 0.8 release', 'what’s left for 0.8?', 'Two PRs: the vault picker (#352, in review) and the crash on wake (#361, needs a repro). Everything else is merged.', 27 * D],
  ['Ideas for the Obysphere name', 'any better names than Obysphere?', 'A few: Oby Space, the Den, the Pack. Obysphere tested best with the five people you asked, mostly because it says it’s a place.', 31 * D + 6 * H],
  ['Set up Oby on the Mac mini', 'how do I set up oby on the office mac mini?', 'Install from the 0.7 dmg, sign in with the Deskree account, and turn on Remote access in Settings so you can reach it from your laptop. It needs Full Disk Access for the repos.', 35 * D],
];
const past: Chat[] = PAST.map(([title, asked, answer, at], i) => ({
  id: `p${i + 1}`, title, said: [{ who: 'you', text: asked, ago: at }, { who: 'oby', text: answer, ago: at - 1 }],
}));

// when it last moved (minutes ago): its latest message
export const lastAgo = (c: Chat) => Math.min(...c.said.map((m) => m.ago));

let chats: Chat[] = [...seeded, ...past].sort((a, b) => lastAgo(a) - lastAgo(b));
const listeners = new Set<() => void>();
const set = (next: Chat[]) => { chats = next; listeners.forEach((l) => l()); };
const subscribe = (l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; };
export const useChats = () => useSyncExternalStore(subscribe, () => chats);
// the conversation a task was started in, if it was started in one
export const chatOfTask = (taskId: string) => chats.find((c) => c.said.some((m) => m.jobs?.includes(taskId)));

const update = (id: string, fn: (c: Chat) => Partial<Chat>) => set(chats.map((c) => (c.id === id ? { ...c, ...fn(c) } : c)));

// from its menu (ConvoMenu): renamed, pinned to the top or not, deleted (the
// tasks it started stay; their conversation is then their own thread)
export function renameChat(id: string, title: string) {
  const t = title.trim();
  if (t) update(id, () => ({ title: t }));
}
export const pinChat = (id: string, pinned: boolean) => update(id, () => ({ pinned }));
export const deleteChat = (id: string) => { queued.delete(id); set(chats.filter((c) => c.id !== id)); };

// Asked in Home's message box: a new conversation, at the top, Oby at work on it
let made = 0;
export function askOby(text: string, att?: Attachments) {
  const t = text.trim();
  if (!t && !hasAttachments(att)) return;
  const id = `c${++made}`;
  set([{ id, title: titled(t || att?.files?.[0]?.name || 'New conversation'), said: [{ who: 'you', text: t, ago: 0, ...att }] }, ...chats]);
  answer(id);
  return id;
}
// a reply in a conversation: Oby takes its next turn on it. Oby was waiting on
// you: its question goes into the conversation, your words under it as the answer
export function tellChat(id: string, text: string, att?: Attachments) {
  const t = text.trim();
  if (!t && !hasAttachments(att)) return;
  update(id, (c) => ({
    waiting: undefined,
    said: [...c.said, ...(c.waiting ? [{ who: 'oby', text: c.waiting.question, ago: 0 }] : []), { who: 'you', text: t, ago: 0, ...att }],
  }));
  answer(id);
}
// Told Oby something about a task started in this conversation (from the task's
// page): it goes on the end of the conversation, and Oby passes it on (relay)
export function tellAbout(id: string, taskId: string, text: string, att?: Attachments) {
  const t = text.trim(), r = relay(taskId, t);
  if ((!t && !hasAttachments(att)) || !r) return;
  update(id, (c) => ({ said: [...c.said, { who: 'you', text: t, ago: 0, ...att }] }));
  answer(id, async () => {
    update(id, () => ({ typing: true, step: 'Thinking' }));
    await wait(THINK_MS);
    await land(id, { text: r.line }, false, r.start);
  });
}
// One answer at a time in a conversation: said while Oby is still at work, it
// waits its turn, so two answers never mix
const queued = new Map<string, Promise<void>>();
const answer = (id: string, run = () => work(id)) => queued.set(id, (queued.get(id) ?? Promise.resolve()).then(run));

// Oby works through what you asked in steps, its face live and one line under
// it saying what it's on (Thinking, then each step in turn), as Wellington's
// app does with its brain's lookups. Asking someone else's Oby is one of those
// steps (other Obys speak here only when asked), waiting on its answer; when
// the answer comes in, what Oby did so far folds up over it, and Oby carries on
// under it (its line always last, as Claude Code's is). Its answer comes last,
// with the steps it took folded over it and a card for any task it started.
// Several Obys can be asked at once (one line, waiting on all of them; each
// answer comes in when it comes, the line then waiting on the rest), or one
// after another. A different turn each time, taking turns between finding
// something out and starting a task (most questions end in one): asking
// another Oby then a line; asking two at once, then a task; asking another
// then a list; asking two in turn, then a task; a question back, then a task;
// a paragraph, then a task.
type Beat = { step: string } | { ask: string[]; about: string; answers: string[] };
// "Wellington’s Oby", "Wellington’s and Dima’s Obys"
export const obys = (names: string[]) => {
  const owners = names.map((n) => `${n}’s`);
  return `${owners.length > 1 ? `${owners.slice(0, -1).join(', ')} and ${owners.at(-1)}` : owners[0]} Oby${names.length > 1 ? 's' : ''}`;
};
// ack: Oby's first words, at once, when the turn takes work (an answer it has
// at once needs none); ask: instead of answering, a question back, waiting on you
type Script = { ack?: string; beats: Beat[]; reply?: string; ask?: Ask; start?: string };
const SCRIPTS: Script[] = [
  {
    ack: 'Let me check.',
    beats: [
      { step: 'Reading the 0.9 release notes' },
      { ask: ['Wellington'], about: 'if the status bar changed since', answers: ['It did: Wellington changed the spacing last week, so the docs are behind. I’ll send his notes over.'] },
    ],
    reply: 'Yes, it went out with 0.9 on Tuesday (https://github.com/deskree-inc/oby/releases/tag/v0.9). Wellington has changed the spacing since, so docs/status-bar.md is behind; his Oby is sending his notes.',
  },
  {
    ack: 'Let me ask around.',
    beats: [
      { step: 'Reading milestone 0.10' },
      {
        ask: ['Wellington', 'Dima'], about: 'what they’re planning for 0.10',
        answers: ['Wellington wants the settings redesign in 0.10. He’s sketching it this week.', 'Dima is moving the graph tests (#398) into 0.10, but they need a shared fixture first.'],
      },
      { step: 'Reading open issues for 0.10' },
    ],
    reply: 'So far 0.10 is Wellington’s settings redesign and Dima’s graph tests. The tests are waiting on a shared fixture, so I’ve started one; Dima won’t be blocked.',
    start: 'Add a shared graph fixture',
  },
  {
    ack: 'Checking where 0.9 is.',
    beats: [
      { step: 'Reading milestone 0.9' }, { step: 'Reading pull request #251' },
      { ask: ['Wellington'], about: 'when #251 lands', answers: ['Wellington’s on it today. He expects #251 merged by Thursday evening.'] },
      { step: 'Reading the release checklist' },
    ],
    reply: 'Here’s where 0.9 stands:\n\n- Usage meters (#405): approved, merging after CI.\n- Graph tests (#398): moved to 0.10.\n- Settings layout (#251): Thursday evening, says Wellington’s Oby.\n\nIf #251 lands Thursday, Friday works.',
  },
  {
    ack: 'Checking with Daniel and Ernesto.',
    beats: [
      { step: 'Reading pull request #405' },
      { ask: ['Daniel'], about: 'if #405 is ready', answers: ['It’s ready. Daniel only wants the copy on the meter labels checked.'] },
      { ask: ['Ernesto'], about: 'if he can review #405 today', answers: ['After 3pm. He’d like a first pass from an agent before he looks.'] },
    ],
    reply: 'Daniel says #405 is ready, and Ernesto can review it after 3pm. I’ve started a first pass so his review is quick.',
    start: 'First-pass review of #405',
  },
  { beats: [], ask: { question: 'Which queue do you mean? They sort differently.', options: ['The inbox', 'The live panel'] } },
  {
    ack: 'Got it, the live panel.',
    beats: [{ step: 'Searching oby for “queue order”' }, { step: 'Reading Engine/Inbox.swift' }],
    reply: 'On it. Claude Code is fixing the queue order in oby on Personal.', start: 'Fix the live panel’s queue order',
  },
  {
    ack: 'Let me look.',
    beats: [{ step: 'Reading pull request #405' }, { step: 'Reading checks on oberon' }],
    reply: 'Not yet. Daniel’s usage meters (#405) are approved but waiting on CI, which has been red on oberon since this morning: `testNextRunAcrossDST` fails in Tests/ScheduleTests.swift. Once it’s fixed they should merge within the hour.',
  },
  {
    ack: 'Sure, I’ll find the test.',
    beats: [{ step: 'Reading checks on oberon' }, { step: 'Reading Tests/ScheduleTests.swift' }],
    reply: 'On it. Claude Code is fixing the flaky DST test in oberon on Deskree.', start: 'Fix the flaky DST test',
  },
];
const ACK_MS = 600;          // reading what you said, before its first words
const THINK_MS = 900;        // Thinking, before the first step (and again after another Oby answers)
const STEP_MS = 1500;        // each step
const ASK_MS = 3500;         // waiting on another Oby's answer
const NEXT_ANSWER_MS = 1800; // asked several at once: each answer after the one before

// Oby's words in: its live line goes, the steps it took fold over them, and the
// words come in a word at a time (stream.ts). working: it carries on after (its
// first words), so it's still at work meanwhile. start: what it starts, once
// they're all in, so its cards and its rows in the side panel show together.
async function land(id: string, m: Omit<Message, 'who' | 'ago' | 'jobs'>, working = false, start?: () => string[] | undefined) {
  let at = 0;
  update(id, (c) => {
    at = c.said.length;
    return { typing: working, step: undefined, said: [...c.said, { who: 'oby', ago: 0, ...m, text: '', streaming: true }] };
  });
  const edit = (fn: (m: Message) => Message) => update(id, (c) => ({ said: c.said.map((x, i) => (i === at ? fn(x) : x)) }));
  await streamWords(m.text, edit);
  // deleted meanwhile: its answer starts nothing (a task with no conversation behind it)
  const jobs = chats.some((c) => c.id === id) ? start?.() : undefined;
  edit((x) => ({ ...x, streaming: undefined, jobs }));
}
let turns = 0;
async function work(id: string) {
  const t = SCRIPTS[turns++ % SCRIPTS.length];
  // what it's done since its last words: the steps, and whose Obys it asked
  let steps: string[] = [], asked: string[] = [], looked = 0;
  update(id, () => ({ typing: true, step: 'Thinking' }));
  await wait(t.ack ? ACK_MS : THINK_MS);
  // a question back: it waits on you, over the message box
  if (t.ask) {
    update(id, () => ({ typing: false, step: undefined, waiting: t.ask }));
    return;
  }
  // its first words, then straight on with the work under them
  if (t.ack) {
    await land(id, { text: t.ack }, true);
    update(id, () => ({ typing: true, step: 'Thinking' }));
    await wait(THINK_MS);
  }
  for (const b of t.beats) {
    if ('step' in b) {
      update(id, () => ({ step: b.step }));
      steps.push(b.step);
      looked++;
      await wait(STEP_MS);
      continue;
    }
    update(id, () => ({ step: `Asking ${obys(b.ask)} ${b.about}` }));
    await wait(ASK_MS);
    steps.push(`Asked ${obys(b.ask)} ${b.about}`);
    asked.push(...b.ask);
    // each answer comes in when it comes: with the first, what Oby did so far
    // folds up over it (no words of its own yet); while others are still out,
    // the line waits on them, under the answers in so far
    for (let k = 0; k < b.ask.length; k++) {
      if (k) {
        update(id, () => ({ typing: true, step: `Waiting on ${obys(b.ask.slice(k))}` }));
        await wait(NEXT_ANSWER_MS);
      }
      const answer: Message = { who: 'peer', by: b.ask[k], text: b.answers[k], ago: 0 };
      update(id, (c) => ({
        typing: false, step: undefined,
        said: [...c.said, ...(k ? [] : [{ who: 'oby', text: '', ago: 0, steps, looked, asked }]), answer],
      }));
    }
    steps = []; asked = []; looked = 0;
    update(id, () => ({ typing: true, step: 'Thinking' }));
    await wait(THINK_MS);
  }
  await land(id, { text: t.reply ?? '', steps, looked, asked }, false, () => {
    const started = t.start && addTask(t.start);
    return started ? [started] : undefined;
  });
}
