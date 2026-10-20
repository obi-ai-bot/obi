import { BRANDS, type Brand } from './brands';

// Mock data until the app talks to Oby's engine. The shapes follow the Mac
// app on dev (Engine/Jobs.swift Job, Engine/Conversation.swift Turn,
// Engine/Inbox.swift InboxItem), trimmed to what this app shows. Times are
// minutes before now, so "ago" stays right.

export type Agent = 'claude' | 'codex' | 'cursor';
export const AGENTS: Record<Agent, { name: string; brand: Brand }> = {
  claude: { name: 'Claude Code', brand: BRANDS.claude },
  codex: { name: 'Codex', brand: BRANDS.openai },
  cursor: { name: 'Cursor', brand: BRANDS.cursor },
};

// Job.status on the Mac. queued and running show as running here; a job
// with an ask needs you whatever its status.
export type JobStatus = 'queued' | 'running' | 'done' | 'failed' | 'stopped' | 'interrupted';

// JobStage (Engine/Pipeline.swift): prepare → work → check → publish → review → merged
export type StageId = 'prepare' | 'work' | 'check' | 'publish' | 'review' | 'merged';
export type StageState = 'done' | 'current' | 'upcoming' | 'failed' | 'skipped';
// On the task's page, a stage also says how long it took ("3m 19s") or should
// take ("≈ 3m"), what it's doing in a plain sentence (sub), and what hangs
// under it on the timeline: the job's activity (under Work) or its checks.
export type Stage = {
  id: StageId; title: string; detail?: string; state: StageState;
  took?: string; sub?: string; activity?: boolean; checks?: CheckRow[];
};

// The job page's own data (obid's job fields, obi-ai-bot/obi#739); every part
// is optional, and a part with nothing to show isn't drawn.
// A tool call: the verb and what it touched ("Running" `xcodebuild test`).
export type ToolCall = { verb: string; path?: string; text?: string; took?: string; running?: boolean };
// A few plain groups of the agent's work; only the running one opens.
export type ToolGroup = { title: string; state: 'done' | 'running' | 'failed'; took?: string; meta?: string; tools?: ToolCall[] };
// A check (or the secret scan, or the push) under its stage.
export type CheckRow = {
  name: string; mono?: boolean; state: 'done' | 'running' | 'upcoming' | 'failed' | 'skipped';
  result?: string; took?: string; progress?: number;
};
export type Page = {
  mode?: string;  // Ask, Accept edits, Plan, Bypass
  // the time track: how far in (done), when it should be done (from–to), as
  // % of the track; paused while it waits on you; basis: what the range is from
  time?: { aside: string; done?: number; from?: number; to?: number; paused?: boolean; basis?: string };
  counts?: [number, string][];   // tools by kind: [23, 'read']
  groups?: ToolGroup[];
  // this job's tokens and value, and its share of the account's windows
  usage?: { tokens: string; cost: string; fiveHour: number; job5: string; week: number; jobWeek: string };
  outgoing?: { text: string; at: string }[];  // what went out, every outgoing action
};

// What the job needs from you (InboxItem + Question + Permission). Buttons
// per kind follow Inbox.swift; every ask also has Later.
// back: a job that was on someone else's Mac came back to yours (Sharing, a preview)
export type AskKind = 'question' | 'permission' | 'review' | 'failed' | 'limit' | 'start' | 'merge' | 'back';
export type Ask = {
  kind: AskKind;
  headline: string;   // Oby's plain-words rewrite, e.g. "Pick one vault"
  text: string;       // what happened, or the agent's question
  options: string[];
  recommended?: number;
  detail?: string;    // the command, the diff stat, the plan
};
export const ASK_LABEL: Record<AskKind, string> = {
  question: 'Question', permission: 'Permission', review: 'Out of reviews', failed: 'Failed',
  limit: 'Out of usage', start: 'Start it?', merge: 'Not merged', back: 'Came back',
};

// One line of the agent's session: a file it read, a command it ran, what it said.
export type LogLine = { tool: 'Read' | 'Edit' | 'Bash' | 'Grep' | 'Say'; text: string; ago: number };

export type Job = {
  id: string;
  type: string;        // which chip / side-panel group it's in (TYPES in tasks.ts)
  title: string;       // the brain's short title
  who?: string;        // the person it's for, shown before the title
  from?: Brand;        // where it came from (GitHub, Slack, Gmail…); none when you asked Oby
  request: string;     // your own words, or the message it came from
  agent: Agent;
  account: string;     // which of the accounts it runs on (Personal, Deskree, or someone's shared one)
  on?: string;         // whose Mac it runs on, when not this one ("Wellington’s Mac")
  model: string;
  repo: string;
  branch: string;
  base: string;
  check?: string;      // "Done when": the command that has to pass
  status: JobStatus;
  step: string;        // the live line, e.g. "Running swift test"
  round?: [number, number];
  stages: Stage[];
  ask?: Ask;
  summary?: string;    // the agent's report once it's done
  commits?: number;
  published?: string;  // the pull request it opened
  log?: LogLine[];
  page?: Page;         // the job page's extra data, once obid serves it
  created: number;     // minutes ago
  finished?: number;   // minutes ago
};

const TITLES: Record<StageId, string> = {
  prepare: 'Prepare', work: 'Work', check: 'Check', publish: 'Publish', review: 'Review', merged: 'Merged',
};
const DETAILS: Partial<Record<StageId, string>> = {
  prepare: 'Clone and worktree',
  publish: 'Secret scan, push and pull request',
  merged: 'Merged into dev',
};
// Stages up to `at` are done, `at` is current (or failed/done), the rest upcoming.
function stages(at: StageId, state: StageState = 'current', ids: StageId[] = ['prepare', 'work', 'check', 'publish', 'review'], check?: string): Stage[] {
  const n = ids.indexOf(at);
  return ids.map((id, i) => ({
    id,
    title: TITLES[id],
    detail: id === 'check' ? check : DETAILS[id],
    state: i < n ? 'done' : i === n ? state : 'upcoming',
  }));
}
// a stage it didn't need
const skip = (list: Stage[], id: StageId): Stage[] => list.map((s) => (s.id === id ? { ...s, state: 'skipped' } : s));
// the job page's extras on some of the stages
const more = (list: Stage[], add: Partial<Record<StageId, Partial<Stage>>>): Stage[] => list.map((s) => ({ ...s, ...add[s.id] }));
// a review of someone else's PR: read it, post it
const REVIEW: StageId[] = ['prepare', 'work', 'publish'];

const { github, slack, gmail, deskree } = BRANDS;

export const JOBS: Job[] = [
  // Sharing (a preview for Sangam, docs/research/sphere-sharing.md): what the
  // Obysphere's sharing puts in front of you. Someone asking for this Mac, or
  // for a part of your usage; and, as a member, your own jobs on another Mac.
  {
    id: 'x1', type: 'tasks', who: 'Sangam', title: 'Run a job on this Mac?', request: 'Sangam’s Oby asks to run “Fix the login retry” on this Mac.',
    agent: 'claude', account: 'Sangam’s own', model: 'Opus 5.5', repo: 'deskree-inc/tetrix-ee', branch: 'oby/fix-login-retry', base: 'dev',
    status: 'queued', step: 'Waiting for your OK', stages: stages('prepare', 'upcoming'), created: 3,
    ask: {
      kind: 'start', headline: 'Sangam asks to use this Mac while you’re away',
      text: 'Sangam’s Oby wants to run “Fix the login retry” here, on Sangam’s own Claude Code. It runs sealed off from your files, logins and network, with at most 4 cores, 8 GB of memory and 30 GB of disk, and stops when you’re back.',
      options: ['Allow', 'Allow Sangam from now on', 'Decline'], recommended: 0,
    },
  },
  {
    id: 'x2', type: 'tasks', title: 'Share sheet polish', request: 'polish the share sheet to Sangam’s design',
    agent: 'claude', account: 'Personal', model: 'Opus 5.5', repo: 'deskree-inc/oby', branch: 'oby/share-sheet', base: 'dev',
    status: 'queued', step: 'Waiting for usage', stages: stages('prepare', 'upcoming'), created: 6,
    ask: {
      kind: 'limit', headline: 'Your Claude is full until 4 PM',
      text: 'Wellington shares 30% of Deskree API’s month with you, and 18% is left. It would run on Wellington’s Mac, on that account, and you get the pull request. About 2% of the share.',
      options: ['Use Wellington’s share', 'Run it on Codex', 'Wait for the reset'], recommended: 0,
    },
  },
  {
    id: 'x4', type: 'tasks', who: 'Sangam', title: 'Share used up', request: 'Sangam has used the 30% of Deskree API you shared.',
    agent: 'claude', account: 'Deskree API', model: 'Opus 5.5', repo: '—', branch: '—', base: '—',
    status: 'done', step: 'Share used', stages: stages('prepare', 'upcoming'), created: 30,
    ask: {
      kind: 'limit', headline: 'Sangam used the share of Deskree API',
      text: 'All 30% of this month’s share is used ($120 of $400). The job that was running finished; Oby takes no more of Sangam’s jobs on it until the 1st.',
      options: ['Share 20% more this month', 'Leave it'], recommended: 1,
    },
  },
  {
    id: 'x3', type: 'tasks', title: 'Onboarding copy', request: 'update the onboarding copy to Sangam’s words',
    agent: 'claude', account: 'Personal', on: 'Wellington’s Mac', model: 'Opus 5.5', repo: 'deskree-inc/oby', branch: 'oby/onboarding-copy', base: 'dev',
    status: 'interrupted', step: 'Back from Wellington’s Mac', stages: stages('work', 'upcoming'), created: 52,
    ask: {
      kind: 'back', headline: 'Wellington is back at that Mac',
      text: 'Your job paused there after 18 minutes and came back with its notes and its 2 commits. Run the rest on this Mac, or wait until that Mac is free again?',
      options: ['Run it here', 'Wait for Wellington’s Mac'], recommended: 0,
    },
  },
  {
    id: 's5', type: 'tasks', title: 'Invite link expired', request: 'invite links die after an hour, should be 7 days',
    agent: 'claude', account: 'Personal', model: 'Haiku 5.5', repo: 'deskree-inc/tetrix-ee', branch: 'oby/fix-invite-ttl', base: 'dev', check: 'pnpm test invites',
    status: 'done', step: 'Done', stages: stages('review', 'current', undefined, 'pnpm test invites'), commits: 1, published: 'deskree-inc/tetrix-ee#486',
    summary: 'INVITE_TTL was in seconds but read as minutes. Now 7 days, with a test.', created: 420, finished: 390,
  },

  // Review PR
  {
    id: 'r1', type: 'review', who: 'Ernesto', title: '#412 retry jitter', from: github, request: 'Ernesto asked you to review tetrix-ee #412.',
    agent: 'claude', account: 'Deskree', model: 'Opus 5.5', repo: 'deskree-inc/tetrix-ee', branch: 'oby/review-412', base: 'dev',
    status: 'running', step: 'Reading src/queue/retry.ts', stages: stages('work', 'current', REVIEW), created: 18,
  },
  {
    id: 'r2', type: 'review', who: 'Dima', title: '#398 graph tests', from: github, request: 'Dima asked you to review tetrix-ee #398.',
    agent: 'codex', account: 'Deskree', model: 'GPT-6-Astra', repo: 'deskree-inc/tetrix-ee', branch: 'oby/review-398', base: 'dev',
    status: 'done', step: 'Posted', stages: stages('publish', 'done', REVIEW), created: 41, finished: 8,
    summary: 'Approved. The tests are solid; suggested one shared fixture for the graph setup.',
  },
  {
    id: 'r3', type: 'review', who: 'Wellington', title: '#251 settings layout', from: github, request: 'Wellington asked you to review oby #251.',
    agent: 'claude', account: 'Deskree', model: 'Opus 5.5', repo: 'deskree-inc/oby', branch: 'oby/review-251', base: 'dev',
    status: 'done', step: 'Review ready', stages: stages('publish', 'current', REVIEW), created: 95,
    ask: {
      kind: 'question', headline: 'Post this review as you?',
      text: 'Changes requested: the Accounts pane loses its scroll position when a usage meter refreshes. 2 comments, both small.',
      options: ['Post review', 'Read it first'], recommended: 0,
      detail: 'Mac/Settings.swift:212 — ScrollView rebuilds on every refresh\nMac/Settings.swift:468 — model picker default reads the wrong key',
    },
  },
  {
    id: 'r4', type: 'review', who: 'Daniel', title: '#405 usage meters', from: github, request: 'Daniel asked you to review tetrix-front-end #405.',
    agent: 'cursor', account: 'Deskree', model: 'Sonnet 5.5', repo: 'deskree-inc/tetrix-front-end', branch: 'oby/review-405', base: 'dev',
    status: 'done', step: 'Posted', stages: stages('publish', 'done', REVIEW), created: 130, finished: 60,
    summary: 'Approved with one nit: round down at 99.5%, to match the Mac app.',
  },
  {
    id: 'r5', type: 'review', who: 'Ernesto', title: '#389 webhook fix', from: github, request: 'Ernesto asked you to review tetrix-ee #389.',
    agent: 'claude', account: 'Deskree', model: 'Opus 5.5', repo: 'deskree-inc/tetrix-ee', branch: 'oby/review-389', base: 'dev',
    status: 'done', step: 'Posted', stages: skip(stages('publish', 'done', ['prepare', 'work', 'check', 'publish']), 'check'), summary: 'Approved with one comment on the retry header.', created: 260, finished: 200,
  },

  // Issues
  {
    id: 'i1', type: 'issues', title: '#251 Attention queue', from: github, request: 'fix oby #251',
    agent: 'cursor', account: 'Deskree', model: 'Sonnet 5.5', repo: 'deskree-inc/oby', branch: 'oby/fix-251', base: 'dev', check: 'xcodebuild test -scheme Oby',
    status: 'running', step: 'Editing Mac/App/LivePanel.swift', round: [2, 3], created: 64,
    stages: more(stages('work', 'current', undefined, 'xcodebuild test -scheme Oby'), {
      prepare: { took: '22s' },
      work: { took: '1h 1m so far', sub: 'Round 1 sorted the queue by created date, but the test wants the oldest first. It’s changing the sort, then runs the tests again.', activity: true },
      check: { took: '≈ 6m', checks: [{ name: 'xcodebuild test -scheme Oby', mono: true, state: 'upcoming', result: 'has to pass' }] },
      publish: { took: '≈ 40s' },
    }),
    page: {
      mode: 'Accept edits',
      time: { aside: '1h 4m in · done in about 8–16m', done: 78, from: 86, to: 97, basis: 'From the last 9 jobs like this in oby on Cursor (1h 10m in the middle). A third round usually needs one more test run.' },
      counts: [[31, 'read'], [12, 'searches'], [6, 'edits'], [5, 'commands'], [2, 'test runs'], [2, 'Tetrix']],
      groups: [
        { title: 'Read how the attention queue is built', state: 'done', took: '9m' },
        { title: 'Round 1: sorted the queue by created date', state: 'done', took: '14m' },
        { title: 'Ran the tests: 2 failed', state: 'failed', took: '6m' },
        { title: 'Changing the sort to oldest first', state: 'running', took: '2m', meta: 'LivePanel.swift · +12 −5', tools: [
          { verb: 'Edited', path: 'Mac/App/LivePanel.swift', took: '2m' },
          { verb: 'Reading', path: 'Engine/Inbox.swift', running: true },
        ] },
      ],
      usage: { tokens: '3.1M', cost: '$4.20', fiveHour: 52, job5: '14%', week: 38, jobWeek: '3%' },
    },
    log: [
      { tool: 'Read', text: 'Engine/Inbox.swift', ago: 60 },
      { tool: 'Read', text: 'Mac/App/LivePanel.swift', ago: 58 },
      { tool: 'Bash', text: 'xcodebuild test -scheme Oby — 2 failed', ago: 22 },
      { tool: 'Say', text: 'Round 1 sorted the queue by created date; the test wants oldest first. Fixing that.', ago: 21 },
      { tool: 'Edit', text: 'Mac/App/LivePanel.swift', ago: 2 },
    ],
  },
  {
    id: 'i2', type: 'issues', title: 'Flaky timezone test', from: github, request: 'fix tetrix-ee #377, the DST test fails twice a year',
    agent: 'claude', account: 'Personal', model: 'Opus 5.5', repo: 'deskree-inc/tetrix-ee', branch: 'oby/fix-377', base: 'dev', check: 'pnpm test schedule',
    status: 'done', step: 'Done', stages: stages('review', 'current', undefined, 'pnpm test schedule'), commits: 1, published: 'deskree-inc/tetrix-ee#493',
    summary: 'The test built its dates in local time; it now pins UTC. Passed 50 runs in a row.', created: 27, finished: 5,
  },
  {
    id: 'i3', type: 'issues', title: 'Memory spike on deploy', from: deskree, request: 'Deskree Ops: api-gateway memory hits 1.8 GB for 3 min after each deploy.',
    agent: 'claude', account: 'Deskree', model: 'Opus 5.5', repo: 'deskree-inc/api-gateway', branch: 'oby/investigate-deploy-memory', base: 'main',
    status: 'done', step: 'Done', stages: stages('work', 'done', ['prepare', 'work']), created: 45, finished: 12,
    summary: 'The route cache loads all 38k routes at boot. Warming it in batches of 1,000 keeps memory under 600 MB.',
  },
  {
    id: 'i4', type: 'issues', title: 'Search ignores accents', from: github, request: 'fix tetrix-front-end #402',
    agent: 'codex', account: 'Deskree', model: 'GPT-6-Astra', repo: 'deskree-inc/tetrix-front-end', branch: 'oby/fix-402', base: 'dev', check: 'pnpm test search',
    status: 'running', step: 'Asked which way to fold accents', round: [1, 3], stages: stages('work', 'current', undefined, 'pnpm test search'), created: 110,
    ask: {
      kind: 'question', headline: 'Fold accents in the index or in the query?',
      text: 'Folding in the index means a one-time reindex (about 20 min on prod). Folding only the query is instant but misses "José" when you type "jose".',
      options: ['Index (reindex once)', 'Query only', 'Both'], recommended: 0,
    },
  },
  {
    id: 'i5', type: 'issues', title: 'Dark mode flashes on load', from: github, request: 'fix tetrix-front-end #399',
    agent: 'cursor', account: 'Personal', model: 'Sonnet 5.5', repo: 'deskree-inc/tetrix-front-end', branch: 'oby/fix-399', base: 'dev', check: 'pnpm test',
    status: 'done', step: 'Done', stages: stages('review', 'current', undefined, 'pnpm test'), commits: 2, published: 'deskree-inc/tetrix-front-end#408',
    summary: 'Round 3 moved the theme script ahead of the stylesheet; the snapshot test renders dark now.', created: 180, finished: 40,
  },
  {
    id: 'i6', type: 'issues', title: 'Broken link in onboarding', from: github, request: 'fix tetrix-front-end #397',
    agent: 'claude', account: 'Personal', model: 'Haiku 5.5', repo: 'deskree-inc/tetrix-front-end', branch: 'oby/fix-397', base: 'dev', check: 'pnpm test',
    status: 'done', step: 'Done', stages: stages('review', 'current', undefined, 'pnpm test'), commits: 1, published: 'deskree-inc/tetrix-front-end#407',
    summary: 'The docs moved to /guides. Updated the link and added it to the link checker.', created: 360, finished: 330,
  },
  {
    id: 'i7', type: 'issues', title: 'Typo on the pricing page', from: github, request: 'fix tetrix-front-end #395',
    agent: 'codex', account: 'Deskree', model: 'GPT-6-Astra', repo: 'deskree-inc/tetrix-front-end', branch: 'oby/fix-395', base: 'dev', check: 'pnpm test',
    status: 'done', step: 'Merged', stages: stages('merged', 'done', ['prepare', 'work', 'check', 'publish', 'review', 'merged'], 'pnpm test'), commits: 1, published: 'deskree-inc/tetrix-front-end#406',
    summary: '"Anual" → "Annual" in two places.', created: 600, finished: 560,
  },

  // Wellington (things his Oby asked yours for)
  {
    id: 'w1', type: 'wellington', who: 'Wellington', title: 'Status bar mockups', from: slack, request: 'Wellington’s Oby: can Sangam send the status bar states for the island?',
    agent: 'claude', account: 'Personal', model: 'Opus 5.5', repo: 'deskree-inc/oby', branch: 'oby/status-bar-states', base: 'dev',
    status: 'done', step: 'Done', stages: stages('publish', 'done', ['prepare', 'work', 'publish']), commits: 1, published: 'deskree-inc/oby#376',
    summary: 'Exported the 5 states as PNGs and one HTML page, in Character/status-bar/.', created: 22, finished: 4,
  },
  {
    id: 'w2', type: 'wellington', who: 'Wellington', title: 'Inspection window', from: slack, request: 'Wellington’s Oby: the inspection window needs a resize handle.',
    agent: 'claude', account: 'Personal', model: 'Sonnet 5.5', repo: 'deskree-inc/oby', branch: 'oby/inspection-resize', base: 'dev', check: 'xcodebuild test -scheme Oby',
    status: 'done', step: 'Done', stages: stages('review', 'current', undefined, 'xcodebuild test -scheme Oby'), commits: 3, published: 'deskree-inc/oby#372',
    summary: 'Added a resize handle and remembered the size per display.', created: 500, finished: 430,
  },

  // Tasks (asked in Oby)
  {
    id: 's1', type: 'tasks', title: 'Give the scan’s first block a fix round', request: 'when the secret scan blocks the first push, give the job a round to fix it instead of failing',
    agent: 'claude', account: 'Personal', model: 'Opus 5.5', repo: 'obi-ai-bot/obi', branch: 'oby/scan-fix-round', base: 'dev', check: 'cargo test -p obid',
    status: 'running', step: 'Running the obid tests: 412 of 793 passed', round: [1, 2], created: 14,
    stages: more(stages('check', 'current', undefined, 'cargo test -p obid'), {
      prepare: { took: '18s' },
      work: { took: '11m', detail: '2 commits · 3 files +41 −11', activity: true },
      check: { took: '1m 53s so far', sub: 'Nothing goes out until every check passes and the secret scan is clean.', checks: [
        { name: 'cargo fmt --check', mono: true, state: 'done', result: 'passed', took: '3s' },
        { name: 'cargo clippy -- -D warnings', mono: true, state: 'done', result: 'no warnings', took: '38s' },
        { name: 'cargo test -p obid', mono: true, state: 'running', result: '412 of 793', took: '1m 12s', progress: 52 },
      ] },
      publish: { took: '≈ 30s', detail: undefined, checks: [
        { name: 'Secret scan', state: 'upcoming', result: 'on the commits, before the push', took: '≈ 5s' },
        { name: 'Push and pull request', state: 'upcoming' },
      ] },
    }),
    page: {
      mode: 'Accept edits',
      time: { aside: '14m in · done in about 1–3m', done: 78, from: 84, to: 95, basis: 'The last full run of these tests in obi took 2m 40s, and this one is on the same pace.' },
      counts: [[26, 'read'], [9, 'searches'], [5, 'edits'], [7, 'commands'], [2, 'test runs'], [3, 'Tetrix'], [1, 'web']],
      usage: { tokens: '2.4M', cost: '$3.30', fiveHour: 49, job5: '13%', week: 32, jobWeek: '3%' },
    },
  },
  {
    id: 's2', type: 'tasks', title: 'Codex keeps its sandbox roots on resume', request: 'codex jobs lose writable_roots after a resume, keep them',
    agent: 'codex', account: 'Deskree', model: 'GPT-6-Astra', repo: 'obi-ai-bot/obi', branch: 'oby/codex-roots', base: 'dev', check: 'cargo test -p obid',
    status: 'failed', step: 'Failed at Check', round: [2, 2], created: 25,
    stages: more(stages('check', 'failed', undefined, 'cargo test -p obid'), {
      prepare: { took: '20s' },
      work: { took: '16m', detail: '3 commits', activity: true },
      check: { took: '5m', detail: '2 of 793 tests failed in round 2, out of rounds', sub: 'Stopped here. Nothing went out: the 3 commits stay on this Mac.', checks: [
        { name: 'cargo fmt --check', mono: true, state: 'done', result: 'passed', took: '3s' },
        { name: 'cargo clippy -- -D warnings', mono: true, state: 'done', result: 'no warnings', took: '36s' },
        { name: 'cargo test -p obid', mono: true, state: 'failed', result: '791 passed, 2 failed', took: '2m 51s' },
      ] },
      publish: { state: 'skipped', detail: 'Nothing went out · the secret scan didn’t run, since checks come first' },
      review: { state: 'skipped', detail: 'No pull request to review' },
    }),
    ask: {
      kind: 'failed', headline: 'Two sandbox tests still fail after 2 rounds',
      text: 'They expect a resumed thread to start with no writable roots, the old behaviour this task changes. Codex rewrote one test in round 2, but not these two.',
      options: ['Give it another round', 'Open the session', 'Stop here'], recommended: 0,
      detail: 'codex::resume_keeps_writable_roots\n  expected ["/w/.git"], got []\ncodex::resume_after_reset\n  left: 0  right: 1',
    },
    page: {
      mode: 'Accept edits',
      time: { aside: 'Ran 22m · jobs like this: 12–20m', basis: 'It ran past the usual range because round 1 failed its checks and round 2 ran them again.' },
      counts: [[31, 'read'], [7, 'edits'], [9, 'commands'], [4, 'test runs'], [3, 'Tetrix']],
      usage: { tokens: '3.6M', cost: '$4.90', fiveHour: 58, job5: '19%', week: 34, jobWeek: '4%' },
    },
  },
  {
    id: 't1', type: 'tasks', title: 'Fix failing CI on oberon', request: 'CI on oberon is red since this morning, fix it',
    agent: 'claude', account: 'Deskree', model: 'Opus 5.5', repo: 'deskree-inc/oberon', branch: 'oby/fix-ci', base: 'main', check: 'pnpm test',
    status: 'running', step: 'Catching up with main', round: [1, 3], stages: stages('prepare'), created: 6,
  },
  {
    id: 't2', type: 'tasks', title: 'Settings in three groups', request: 'split settings into General, Agents and Privacy',
    agent: 'cursor', account: 'Deskree', model: 'Sonnet 5.5', repo: 'deskree-inc/oby', branch: 'oby/settings-groups', base: 'dev', check: 'xcodebuild test -scheme Oby',
    status: 'done', step: 'Done', commits: 2, published: 'deskree-inc/oby#375',
    stages: more(stages('review', 'current', undefined, 'xcodebuild test -scheme Oby'), {
      prepare: { took: '25s' },
      work: { took: '21m', detail: '2 commits · 9 files +184 −97', activity: true },
      check: { took: '6m 10s', detail: 'All passed on 4f1c2a9', checks: [{ name: 'xcodebuild test -scheme Oby', mono: true, state: 'done', result: '212 passed', took: '5m 48s' }] },
      publish: { took: '19s', detail: undefined, checks: [
        { name: 'Secret scan', state: 'done', result: 'clean · 2 commits, 9 files', took: '4s' },
        { name: 'Pushed and opened oby#375', state: 'done' },
      ] },
      review: { took: '10m so far' },
    }),
    page: {
      time: { aside: 'Took 29m · estimated 20–35m' },
      counts: [[40, 'read'], [14, 'edits'], [6, 'commands'], [2, 'test runs']],
      usage: { tokens: '2.9M', cost: '$3.90', fiveHour: 44, job5: '12%', week: 30, jobWeek: '3%' },
      outgoing: [
        { text: 'Pushed oby/settings-groups to deskree-inc/oby', at: '10:31 AM' },
        { text: 'Opened pull request oby#375, ready for review', at: '10:31 AM' },
      ],
    },
    summary: 'Settings has General, Agents and Privacy now, each its own pane.', created: 39, finished: 10,
  },
  {
    id: 't3', type: 'tasks', title: 'Blast radius of the jobs refactor', request: 'what breaks if we split Engine/Jobs.swift in three?',
    agent: 'codex', account: 'Deskree', model: 'GPT-6-Astra', repo: 'deskree-inc/oby', branch: 'oby/investigate-jobs-split', base: 'dev',
    status: 'running', step: 'Asking Tetrix for callers of Job.line', created: 15,
    stages: more(stages('work', 'current', ['prepare', 'work']), {
      prepare: { took: '31s' },
      work: { took: '14m so far', sub: 'It reads and asks Tetrix, changes nothing, and answers with what would break.', activity: true },
    }),
    page: {
      mode: 'Plan',
      time: { aside: '15m in · questions like this take 12–25m', done: 40, from: 48, to: 100, basis: 'Too early to be sure: the last 6 questions like this in oby took 12–25m.' },
      counts: [[18, 'read'], [7, 'searches'], [9, 'Tetrix']],
      groups: [
        { title: 'Found the three parts of Jobs.swift', state: 'done', took: '6m' },
        { title: 'Asking Tetrix what calls each part', state: 'running', took: '8m', meta: '9 Tetrix questions · 41 callers so far', tools: [
          { verb: 'Asked Tetrix for callers of', path: 'Job.round', took: '3s' },
          { verb: 'Asking Tetrix for callers of', path: 'Job.line', running: true },
        ] },
      ],
      usage: { tokens: '640k', cost: '$1.10', fiveHour: 31, job5: '3%', week: 27, jobWeek: '<1%' },
    },
  },
  {
    id: 't4', type: 'tasks', title: 'Inspection for Avenga', request: 'run the security inspection for Avenga before Thursday',
    agent: 'claude', account: 'Deskree', model: 'Opus 5.5', repo: 'deskree-inc/inspections', branch: 'oby/avenga-oct', base: 'main',
    status: 'queued', step: 'Starts when a slot opens', stages: stages('prepare', 'upcoming'), created: 12,
    ask: {
      kind: 'limit', headline: 'Deskree’s Claude is at 82% of the week',
      text: 'The inspection takes about 15% more. Run it on Personal instead, or on Deskree anyway?',
      options: ['Use Personal', 'Use Deskree anyway (82% of week)', 'Wait for the reset'], recommended: 0,
    },
  },
  {
    id: 't5', type: 'tasks', title: 'Draft the release notes', request: 'draft release notes for oby 0.9 from the merged PRs',
    agent: 'claude', account: 'Personal', model: 'Sonnet 5.5', repo: 'deskree-inc/oby', branch: 'oby/release-notes-0.9', base: 'dev',
    status: 'running', step: 'Plan ready', created: 70,
    stages: more(stages('work', 'current', ['prepare', 'work', 'publish']), {
      prepare: { took: '14s' },
      work: { took: '6m · paused', sub: 'It read the 23 merged PRs and wrote a plan for the notes.', activity: true },
      publish: { took: '≈ 20s' },
    }),
    page: {
      mode: 'Plan',
      time: { aside: '6m in · paused · then about 4–7m', done: 45, from: 75, to: 98, paused: true, basis: 'Release notes in oby took 4–7m after the plan. Waiting on you isn’t counted.' },
      counts: [[23, 'read'], [2, 'commands']],
      groups: [
        { title: 'Read the 23 merged PRs', state: 'done', took: '4m' },
        { title: 'Wrote the plan', state: 'done', took: '1m' },
      ],
      usage: { tokens: '420k', cost: '$0.70', fiveHour: 41, job5: '2%', week: 33, jobWeek: '<1%' },
    },
    ask: {
      kind: 'question', headline: 'Go with this plan?',
      text: 'Group the 23 merged PRs into New, Better and Fixed, one line each, and leave out the 6 CI-only ones.',
      options: ['Go ahead', 'Include CI too', 'Tell it something'], recommended: 0,
    },
  },
  {
    id: 't6', type: 'tasks', title: 'Webhook fix ready as a draft PR', request: 'make the webhook retry fix a draft PR',
    agent: 'claude', account: 'Deskree', model: 'Opus 5.5', repo: 'deskree-inc/tetrix-ee', branch: 'oby/fix-webhook-retry', base: 'dev', check: 'pnpm test webhooks',
    status: 'done', step: 'Done', stages: stages('review', 'current', undefined, 'pnpm test webhooks'), commits: 3, published: 'deskree-inc/tetrix-ee#490',
    summary: 'Retries now back off with jitter and stop after 5 tries. 3 commits on oby/fix-webhook-retry.', created: 210, finished: 150,
  },
  {
    id: 't7', type: 'tasks', title: 'Usage meters explain what’s left', request: 'make the usage meters say what’s left in plain words',
    agent: 'codex', account: 'Deskree', model: 'GPT-6-Astra', repo: 'deskree-inc/oby', branch: 'oby/usage-words', base: 'dev', check: 'xcodebuild test -scheme Oby',
    status: 'done', step: 'Done', stages: stages('review', 'current', undefined, 'xcodebuild test -scheme Oby'), commits: 2, published: 'deskree-inc/oby#369',
    summary: '"18% left · resets in 2h" under each meter.', created: 400, finished: 320,
  },

  // Routines
  {
    id: 'o1', type: 'routines', title: 'Morning briefing', from: slack, request: 'Every weekday at 9: what happened overnight in Slack, GitHub and Vercel.',
    agent: 'claude', account: 'Personal', model: 'Haiku 5.5', repo: '—', branch: '—', base: '—',
    status: 'done', step: 'Done', stages: stages('work', 'done', ['prepare', 'work']), created: 300, finished: 296,
    summary: 'Overnight: 2 PRs merged, 1 Vercel deploy failed and passed on retry, nothing urgent in Slack.',
  },
  {
    id: 'o2', type: 'routines', title: 'Dependency updates', from: github, request: 'Every Monday: bump patch versions in tetrix-ee and open one PR.',
    agent: 'codex', account: 'Deskree', model: 'GPT-6-Astra', repo: 'deskree-inc/tetrix-ee', branch: 'oby/deps-oct-13', base: 'dev', check: 'pnpm test',
    status: 'queued', step: 'Starts Monday at 9', stages: stages('prepare', 'upcoming'), created: 120,
  },
  {
    id: 'o3', type: 'routines', title: 'Weekly repo health', from: github, request: 'Every Friday: stale branches, flaky tests and open PRs older than a week.',
    agent: 'claude', account: 'Personal', model: 'Haiku 5.5', repo: 'deskree-inc/oby', branch: '—', base: '—',
    status: 'done', step: 'Done', stages: stages('work', 'done', ['prepare', 'work']),
    summary: '4 stale branches, 1 flaky test (WatchWireTests), 3 PRs open over a week.', created: 1500, finished: 1490,
  },
  {
    id: 'o4', type: 'routines', title: 'Inbox sweep', from: gmail, request: 'Every evening: label and archive newsletters, flag anything from customers.',
    agent: 'claude', account: 'Personal', model: 'Haiku 5.5', repo: '—', branch: '—', base: '—',
    status: 'done', step: 'Done', stages: stages('work', 'done', ['prepare', 'work']),
    summary: 'Archived 41, flagged 2 from customers.', created: 1000, finished: 995,
  },
];

// Done and out of Home: the archive (Home's Archived), most recent first.
export type Archived = { id: string; type: string; title: string; who?: string; agent: Agent; finished: number };
// archived (done over 3 days ago, so off Home under the default rule)
export const ARCHIVE: Archived[] = [
  { id: 'a1', type: 'review', who: 'Ernesto', title: '#401 queue metrics', agent: 'claude', finished: 3 * 24 * 60 + 26 * 60 },
  { id: 'a2', type: 'issues', title: '#388 Retry banner overlaps', agent: 'cursor', finished: 3 * 24 * 60 + 28 * 60 },
  { id: 'a3', type: 'tasks', title: 'Vault secrets', agent: 'codex', finished: 3 * 24 * 60 + 47 * 60 },
  { id: 'a4', type: 'review', who: 'Wellington', title: '#33 Notch three screens', agent: 'claude', finished: 3 * 24 * 60 + 50 * 60 },
  { id: 'a5', type: 'issues', title: 'Webhook signature mismatch', agent: 'claude', finished: 3 * 24 * 60 + 70 * 60 },
  { id: 'a6', type: 'routines', title: 'Weekly repo health', agent: 'claude', finished: 3 * 24 * 60 + 7 * 24 * 60 },
  { id: 'a7', type: 'tasks', title: 'Job progress screen', agent: 'claude', finished: 3 * 24 * 60 + 4 * 24 * 60 },
  { id: 'a8', type: 'issues', title: '#198 Runner/API.swift answers 500', agent: 'codex', finished: 3 * 24 * 60 + 5 * 24 * 60 },
  { id: 'a9', type: 'wellington', who: 'Wellington', title: 'Watch home', agent: 'cursor', finished: 3 * 24 * 60 + 6 * 24 * 60 },
  { id: 'a10', type: 'tasks', title: 'Daily issue audit', agent: 'claude', finished: 3 * 24 * 60 + 10 * 24 * 60 },
  { id: 'a11', type: 'chats', title: 'Onboarding Oby', agent: 'claude', finished: 3 * 24 * 60 + 12 * 24 * 60 },
];

// The conversation with Oby (Turn): your words and Oby's replies, a day at a
// time. jobs: what that message started, shown as job cards under it.
export type Turn = { id: string; who: 'user' | 'oby'; text: string; at: number; jobs?: string[] };
export const TURNS: Turn[] = [
  { id: 'u1', who: 'user', text: 'anything need me from yesterday?', at: 26 * 60 },
  { id: 'b1', who: 'oby', text: 'Two things: Ernesto’s #401 review is posted, and the retry banner fix (#388) passed its check and is open as a PR. Nothing needs you.', at: 26 * 60 - 1 },
  { id: 'u2', who: 'user', text: 'fix the invite links, they die after an hour', at: 420 },
  { id: 'b2', who: 'oby', text: 'On it. Claude Code is fixing invite links in tetrix-ee on Personal.', at: 420, jobs: ['s5'] },
  { id: 'u3', who: 'user', text: 'make the webhook retry fix a draft PR, and review Ernesto’s #389 while you’re there', at: 260 },
  { id: 'b3', who: 'oby', text: 'On it. Claude Code is finishing the webhook retry fix on Deskree, and Claude Code is reviewing tetrix-ee PR #389 on Deskree.', at: 260, jobs: ['t6', 'r5'] },
  { id: 'b4', who: 'oby', text: 'Done: the webhook fix is open as tetrix-ee #490, and I approved #389 with one comment on the retry header.', at: 150 },
  { id: 'u4', who: 'user', text: 'draft release notes for oby 0.9 from the merged PRs', at: 70 },
  { id: 'b5', who: 'oby', text: 'On it. Claude Code has a plan for the 0.9 notes and needs your OK on it.', at: 70, jobs: ['t5'] },
  { id: 'u5', who: 'user', text: 'what breaks if we split Engine/Jobs.swift in three?', at: 15 },
  { id: 'b6', who: 'oby', text: 'Codex is asking Tetrix for everything that calls into Jobs.swift. I’ll tell you what it finds.', at: 15, jobs: ['t3'] },
  { id: 'u6', who: 'user', text: 'run the security inspection for Avenga before Thursday', at: 12 },
  { id: 'b7', who: 'oby', text: 'Deskree’s Claude is at 82% of the week and this one is big. Want it on Personal instead?', at: 12, jobs: ['t4'] },
  { id: 'u7', who: 'user', text: 'CI on oberon is red since this morning, fix it', at: 6 },
  { id: 'b8', who: 'oby', text: 'On it. Claude Code is fixing CI in oberon on Deskree.', at: 6, jobs: ['t1'] },
];

// A task's own conversation, oldest first: what started it (your words, or the
// message it came in on), Oby's replies, and what you told the agent since.
// who: you, oby, the source it came in on (GitHub, Slack…), or peer: someone
// else's Oby joining in (by: whose). jobs: the tasks that message started (or
// tasks attached to it), shown as cards under it. steps: what Oby did on the
// way, folded over its words (looked: how many were lookups; asked: whose Obys
// it asked); streaming: its words still coming in. files: what went with yours
// (a photo with a preview of itself); obys: the Obys it @mentions
export type Message = { who: string; text: string; ago: number; jobs?: string[]; by?: string; steps?: string[]; looked?: number; asked?: string[]; streaming?: boolean } & Attachments;
// What went with a message from the message box besides its words
export type Attachments = { files?: { name: string; preview?: string }[]; obys?: string[]; jobs?: string[]; on?: string };
export const hasAttachments = (a?: Attachments) => !!(a?.files?.length || a?.obys?.length || a?.jobs?.length);
const SOURCE = new Map<Brand, string>([[github, 'GitHub'], [slack, 'Slack'], [gmail, 'Gmail'], [deskree, 'Deskree Ops']]);
// What was said after it started, in minutes ago (between when it started and now)
const you = (ago: number, text: string): Message => ({ who: 'you', text, ago });
const oby = (ago: number, text: string): Message => ({ who: 'oby', text, ago });
const FOLLOW_UPS: Record<string, Message[]> = {
  i1: [
    you(58, 'is this the queue in the live panel or the inbox one?'),
    oby(57, 'The live panel. The inbox already sorts oldest first; the panel was sorting by when a job last changed.'),
    oby(21, 'Round 1 failed 2 tests: the queue was sorted by date, the test wants oldest first. Cursor is on round 2.'),
    you(12, 'why did round 1 miss that?'),
    oby(11, 'The test only checked the first two items, and in round 1 both happened to be the oldest anyway. Cursor added a third item, so the test can’t pass by luck again.'),
  ],
  i5: [oby(75, 'Round 2 left 1 snapshot test rendering light. Cursor is on its last round.')],
  t1: [
    you(4, 'it’s probably the node 22 bump'),
    oby(3, 'Could be. Claude Code will check that first, once it’s caught up with main.'),
  ],
  t3: [
    oby(9, 'Tetrix found 14 callers of Job.line across 6 files. The ones that would break:\n\n• Mac/App/LivePanel.swift reads line and status together\n• Engine/Inbox.swift builds its asks from line\n• Runner/API.swift encodes the whole Job\n\nThe other 3 files only read id and title, so they’d be fine.'),
    you(7, 'how bad is Runner/API.swift?'),
    oby(6, 'Medium. It sends Job as one JSON object, so splitting it changes what the API returns. Two clients read it, the watch app and the CLI, and both would need a version bump.'),
    you(3, 'ok, keep going, I want the full list'),
    oby(3, 'Will do. Codex is going through the other 8 callers now.'),
  ],
  t5: [
    you(67, 'does that include the dependabot bumps?'),
    oby(66, 'No. Those 6 are CI-only, so the plan leaves them out. It’s below if you want to OK it.'),
  ],
  i4: [
    you(100, 'what does search use now?'),
    oby(99, 'Postgres full text search with the simple dictionary. No unaccent anywhere.'),
    you(98, 'how big is the index?'),
    oby(97, 'About 4.2 million rows. A reindex takes around 20 minutes on prod, and search keeps working while it runs.'),
  ],
  i3: [
    oby(30, 'Early read: the spike lines up with the route cache warming on boot. It loads all 38k routes at once. Comparing heap snapshots to confirm.'),
    you(28, 'can we stagger it?'),
    oby(27, 'Probably. Once it’s confirmed, I’ll have Claude Code try warming in batches of 1,000.'),
  ],
  r1: [
    you(15, 'focus on the jitter math, I trust the rest'),
    oby(15, 'Got it. Claude Code is starting with src/queue/retry.ts.'),
  ],
  s5: [
    you(380, 'did it touch invites already sent?'),
    oby(379, 'No. Those keep their old expiry; only new invites get 7 days.'),
    you(378, 'good'),
  ],
  t6: [
    you(140, 'mark it ready for review'),
    oby(139, 'Done. tetrix-ee #490 is out of draft, and Ernesto is on it as reviewer.'),
  ],
};
export function threadOf(j: Job): Message[] {
  const replies = TURNS.filter((t) => t.who === 'oby' && t.jobs?.includes(j.id)).map((t): Message => ({ who: 'oby', text: t.text, ago: t.at, jobs: t.jobs }));
  // asked in the chat: your words as you said them, just before Oby's first reply;
  // otherwise the request it came in with
  const asked = replies.length ? TURNS[TURNS.findIndex((t) => t.who === 'oby' && t.jobs?.includes(j.id)) - 1] : undefined;
  const first: Message = asked?.who === 'user'
    ? { who: 'you', text: asked.text, ago: asked.at }
    : { who: j.from ? SOURCE.get(j.from) ?? 'Oby' : 'you', text: j.request, ago: j.created };
  // nothing said in the chat about it (it came from elsewhere): Oby's word when it started it
  if (!replies.length) {
    const repo = j.repo.includes('/') ? ` in ${j.repo.split('/')[1]}` : '';
    replies.push({ who: 'oby', text: `On it. ${AGENTS[j.agent].name} has it${repo} on ${j.account}.`, ago: j.created, jobs: [j.id] });
  }
  // done: the agent's report, unless Oby already said it in the chat
  if (j.summary && j.finished != null && !replies.some((r) => r.ago <= j.finished!)) {
    replies.push({ who: 'oby', text: j.summary, ago: j.finished });
  }
  return [first, ...replies, ...followUpsOf(j.id)].sort((a, b) => b.ago - a.ago);
}
// what was said about a task since it started
export const followUpsOf = (id: string) => FOLLOW_UPS[id] ?? [];

// A conversation's name: what it's about, as Oby would title it from the
// opening message (not the task's title, which comes later). One for every
// mock task; a new one is named after your words.
const CONVO_TITLES: Record<string, string> = {
  s5: 'Invite links dying after an hour',
  r1: 'Review of Ernesto’s retry jitter PR', r2: 'Review of Dima’s graph tests PR',
  r3: 'Review of Wellington’s settings PR', r4: 'Review of Daniel’s usage meters PR',
  r5: 'Review of Ernesto’s webhook fix',
  i1: 'Attention queue order in oby', i2: 'Flaky DST test in schedule', i3: 'Memory spike after deploys',
  i4: 'Search not matching accents', i5: 'Dark mode flash on load', i6: 'Broken link in onboarding',
  i7: 'Typo on the pricing page',
  w1: 'Status bar states for the island', w2: 'Resizing the inspection window',
  t1: 'Red CI on oberon', t2: 'Splitting settings into groups', t3: 'Splitting up Engine/Jobs.swift',
  t4: 'Avenga security inspection', t5: 'Release notes for oby 0.9', t6: 'Webhook retry fix and #389',
  t7: 'Usage meters in plain words',
  o1: 'Morning briefing', o2: 'Weekly dependency updates', o3: 'Weekly repo health', o4: 'Evening inbox sweep',
};
export function convoTitle(j: Job) {
  if (CONVO_TITLES[j.id]) return CONVO_TITLES[j.id];
  const t = j.request.length > 48 ? `${j.request.slice(0, 45).trimEnd()}…` : j.request;
  return t[0].toUpperCase() + t.slice(1);
}

// The Obysphere: the other Obys in your workspace (whose they are), and your conversations with them, each about a task. who: 'you',
// or the owner of the Oby that said it; with: the Obys in it (more than one: a
// group); task: the task a message is about, shown as its card under it.
export type Peer = { name: string };
export const OBYS: Peer[] = [
  { name: 'Wellington' },
  { name: 'Ernesto' },
  { name: 'Dima' },
  { name: 'Daniel' },
  { name: 'Makar' },
  { name: 'Yury' },
  { name: 'Sangam' },
  // no conversations with yet
  { name: 'Lucas' },
];
// Where a job can run (the message box's Run on): this Mac, or the Mac of
// someone in your Obysphere who shares theirs. free: it would take a job now;
// about: why, or why not, in a few words (free or busy, never whether its
// owner is at it). A job there still runs on your own
// accounts: your login stays on this Mac, and their Mac reaches your AI
// account only through your Oby, while the job runs.
export type Place = { name: string; owner?: string; about: string; free: boolean };
export const PLACES: Place[] = [
  { name: 'This Mac', about: 'Room for 2 jobs', free: true },
  { name: 'Wellington’s Mac', owner: 'Wellington', about: 'Free now · room for 1 job', free: true },
  { name: 'Ernesto’s Mac', owner: 'Ernesto', about: 'Busy · free tonight from 10 PM', free: false },
];
// A part of someone's usage shared with you: an account their company pays by
// use (a personal plan or a Team seat can't be shared), how much of its month
// is yours (%), and how much of it you've used. Jobs on it run on their Mac:
// its key never leaves it.
export type Share = { owner: string; agent: Agent; account: string; share: number; used: number; resets: string };
export const SHARED_WITH_ME: Share[] = [
  { owner: 'Wellington', agent: 'claude', account: 'Deskree API', share: 30, used: 12, resets: 'Resets on the 1st' },
];

// who: 'you', 'oby' (your Oby, answering for you when another Oby asks it
// something it can answer itself), or the person whose Oby said it
export type PeerMessage = { who: string; text: string; ago: number; task?: string; streaming?: boolean } & Attachments;
// unread: something in it you haven't opened yet (a blue dot on it, and on its Obys)
export type PeerConvo = { id: string; title: string; with: string[]; messages: PeerMessage[]; unread?: boolean };
export const PEER_CONVOS: PeerConvo[] = [
  {
    id: 'p1', title: 'Status bar states for the island', with: ['Wellington'], unread: true,
    messages: [
      { who: 'Wellington', text: 'Wellington needs the 5 status bar states for the island. Can your Oby export them from Character/oby.html?', ago: 26 },
      { who: 'you', text: 'yes, take them from the latest oby.html', ago: 24 },
      { who: 'Wellington', text: 'Thanks. Claude Code is exporting them now; I’ll tell Wellington once they’re in a PR.', ago: 22, task: 'w1' },
    ],
  },
  {
    id: 'p2', title: 'Usage meters, Mac and web', with: ['Wellington', 'Daniel'],
    messages: [
      { who: 'Daniel', text: 'Daniel’s #405 rounds the usage meters down at 99.5%.', ago: 140, task: 'r4' },
      { who: 'Wellington', text: 'The Mac app shows the same numbers and rounds them up. Wellington wants the two to match.', ago: 138 },
      { who: 'you', text: 'round down everywhere', ago: 131 },
      { who: 'Daniel', text: 'Got it. Daniel will keep #405 as it is.', ago: 130 },
      { who: 'Wellington', text: 'I’ll ask Wellington to switch the Mac app to round down too.', ago: 129 },
    ],
  },
  {
    id: 'p3', title: 'Resize handle for the inspection window', with: ['Wellington'],
    messages: [
      { who: 'Wellington', text: 'The inspection window needs a resize handle. Wellington asked if your Oby can take it.', ago: 505 },
      { who: 'you', text: 'sure, go ahead', ago: 501 },
      { who: 'Wellington', text: 'Thanks. It’s done: a handle, and the size is remembered per display.', ago: 430, task: 'w2' },
    ],
  },
  {
    id: 'p4', title: 'Review of #412 retry jitter', with: ['Ernesto'], unread: true,
    messages: [
      { who: 'Ernesto', text: 'Ernesto would like a review of #412 today if you can.', ago: 20 },
      { who: 'you', text: 'on it, I’ll focus on the jitter math', ago: 18, task: 'r1' },
      { who: 'Ernesto', text: 'Thanks. He’s around until 6 if Claude Code has questions.', ago: 17 },
    ],
  },
  {
    id: 'p5', title: 'Last month’s Avenga findings', with: ['Dima', 'Ernesto'],
    messages: [
      { who: 'Dima', text: 'Dima starts the Avenga inspection Thursday. Can someone share what last month’s turned up?', ago: 300 },
      { who: 'Ernesto', text: 'Ernesto ran that one. 3 findings, all fixed; the report is in deskree-inc/inspections under avenga-sep.', ago: 296 },
      { who: 'you', text: 'my Oby is running this month’s, it can start from that report', ago: 290, task: 't4' },
      { who: 'Dima', text: 'Perfect, Dima will review it once yours is done.', ago: 288 },
    ],
  },
  {
    id: 'p7', title: 'What goes in oby 0.9', with: ['Wellington', 'Ernesto', 'Dima', 'Daniel'],
    messages: [
      { who: 'Wellington', text: 'Wellington is cutting oby 0.9 Friday. Anything that has to make it in?', ago: 75 },
      { who: 'Ernesto', text: 'The webhook retry fix, if it’s merged by Thursday.', ago: 74 },
      { who: 'Daniel', text: 'The usage meters (#405) are ready once they’re approved.', ago: 73 },
      { who: 'you', text: 'my Oby is drafting the release notes from the merged PRs', ago: 71, task: 't5' },
      { who: 'Dima', text: 'Graph tests (#398) can wait for 0.10.', ago: 69 },
      { who: 'Wellington', text: 'Thanks all. Wellington will check the notes before Friday. Is the draft ready to look at?', ago: 68 },
      { who: 'oby', text: 'Almost. Claude Code needs Sangam’s OK on its plan first; I’ll post the draft here once it’s in.', ago: 67 },
    ],
  },
  {
    id: 'p10', title: 'Job progress for the island', with: ['Wellington'], unread: true,
    messages: [
      { who: 'Wellington', text: 'Wellington is wiring the island to the runner. Which endpoint does your Oby’s runner give job progress on?', ago: 34 },
      { who: 'oby', text: 'GET /v1/jobs/{id}/events, as server-sent events. Sangam’s runner is on 0.9.2; it’s all in docs/runner-api.md.', ago: 33 },
      { who: 'Wellington', text: 'That’s what he needed, thanks.', ago: 32 },
    ],
  },
  {
    id: 'p11', title: 'Staging database password', with: ['Makar'],
    messages: [
      { who: 'Makar', text: 'Makar is rotating the staging database password tonight. Is anything of Sangam’s still using it?', ago: 95 },
      { who: 'oby', text: 'Nothing running now. Claude Code’s invite links fix used staging this morning, but it finished at 9:40.', ago: 94 },
      { who: 'Makar', text: 'Thanks, he’ll go ahead at 8.', ago: 93 },
    ],
  },
  {
    id: 'p12', title: 'Shared graph fixture', with: ['Dima'],
    messages: [
      { who: 'Dima', text: 'Dima wants to reuse your shared graph fixture for #398. Is it on main yet?', ago: 12 },
      { who: 'oby', text: 'Not yet. It’s on Claude Code’s branch oby/graph-fixture and should merge today; I’ll tell you when it does.', ago: 11 },
      { who: 'Dima', text: 'Great, he’ll wait for that.', ago: 10 },
    ],
  },
  {
    id: 'p9', title: 'Rounding in the usage docs', with: ['Daniel'], unread: true,
    messages: [
      { who: 'Daniel', text: 'Daniel is updating the usage docs. Is rounding down at 99.5% final, on the Mac too?', ago: 45 },
      { who: 'oby', text: 'Yes. Round down everywhere, Mac and web; Sangam settled it in “Usage meters, Mac and web”.', ago: 44 },
      { who: 'Daniel', text: 'Thanks, the docs will say so.', ago: 43 },
    ],
  },
  {
    id: 'p8', title: 'Staging deploy for tetrix-ee', with: ['Makar'],
    messages: [
      { who: 'Makar', text: 'Makar is deploying tetrix-ee to staging at 4. Anything of yours that should wait?', ago: 160 },
      { who: 'you', text: 'no, and the webhook retry fix can go in', ago: 156, task: 't6' },
      { who: 'Makar', text: 'Noted, it’s in the deploy.', ago: 155 },
    ],
  },
  {
    id: 'p13', title: 'Flaky DST test in schedule', with: ['Yury'],
    messages: [
      { who: 'Yury', text: 'Yury saw the schedule DST test fail on main again. Is anyone on it?', ago: 30 },
      { who: 'you', text: 'yes, my Oby has it', ago: 28, task: 'i2' },
      { who: 'Yury', text: 'Great, Yury will stop rerunning it then.', ago: 27 },
    ],
  },
  {
    id: 'p6', title: 'Review of #398 graph tests', with: ['Dima'],
    messages: [
      { who: 'Dima', text: 'Dima asked for a review of #398 when you have a moment. No rush.', ago: 45 },
      { who: 'you', text: 'Codex is on it', ago: 41, task: 'r2' },
    ],
  },
];

// how long ago: now, minutes under an hour, hours under a day, then days
export const ago = (min: number) => (min < 1 ? 'now' : min < 60 ? `${Math.round(min)}m` : min < 24 * 60 ? `${Math.floor(min / 60)}h` : `${Math.floor(min / 1440)}d`);
