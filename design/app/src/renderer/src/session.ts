// A job's session, the way obid serves it (GET /v1/jobs/{id}/transcript, and
// each entry's detail from GET /v1/jobs/{id}/transcript/{n}; obi-ai-bot/obi#784):
// the agent's words in full, its thinking, every tool call with its input and
// output, what you told it, its to-do list, and the permissions it asked for.
// Values from the vault arrive masked as [vault: NAME]. Mock data until the
// app talks to obid; times are clock times.

export type ToolKind = 'Read' | 'Grep' | 'Edit' | 'Bash' | 'Tetrix' | 'Web';
export type Detail = {
  input?: string;    // the command, the pattern, the question, the query
  range?: string;    // a read's lines
  output?: string;   // the end of what it printed (the last 200 lines at most)
  lines?: number;    // how many lines it printed in all
  exit?: number;
  diff?: string;     // an edit, as a unified diff
};
export type Entry =
  | { kind: 'start'; text: string; at: string }
  | { kind: 'said'; text: string; at: string; live?: boolean }   // live: still being written
  | { kind: 'thought'; text: string; seconds: number }
  | { kind: 'you'; text: string; at: string }
  | { kind: 'plan'; todos: { text: string; state: 'done' | 'running' | 'pending' }[] }
  | { kind: 'asked'; text: string; answer: string }
  | { kind: 'tool'; tool: ToolKind; verb: string; target: string; state: 'done' | 'running' | 'failed'; seconds: number; meta?: string; detail?: Detail };

export const SESSIONS: Record<string, Entry[]> = {
  i1: [
    { kind: 'start', text: 'Round 1 · Cursor · Sonnet 5.5', at: '10:02 AM' },
    { kind: 'said', at: '10:02 AM', text: 'I’ll read how the attention queue is built before changing anything.' },
    { kind: 'tool', tool: 'Read', verb: 'Read', target: 'Engine/Inbox.swift', state: 'done', seconds: 0.2, meta: '412 lines', detail: {
      range: 'Lines 1–240 of 412',
      output: 'struct InboxItem: Identifiable, Codable {\n    let id: String\n    let job: String?\n    let kind: Kind\n    let created: Date\n    var needsYou: Bool { kind != .info }\n…',
    } },
    { kind: 'tool', tool: 'Grep', verb: 'Searched for', target: 'attentionItems', state: 'done', seconds: 0.1, meta: '6 matches', detail: {
      input: 'attentionItems  in Mac/',
      output: 'Mac/App/LivePanel.swift:64:    var attentionItems: [InboxItem] {\nMac/App/LivePanel.swift:71:        attentionItems.prefix(3)\nMac/App/IslandModel.swift:118:    let items = panel.attentionItems\nMac/App/NotchView.swift:201:    ForEach(model.attentionItems) { item in\n…',
    } },
    { kind: 'tool', tool: 'Tetrix', verb: 'Asked Tetrix what calls', target: 'LivePanel.attentionItems', state: 'done', seconds: 2.1, meta: '3 callers', detail: {
      input: 'What calls LivePanel.attentionItems, and which tests cover it?',
      output: '3 callers: IslandModel.swift:118, LivePanel.swift:71, NotchView.swift:201.\nCovered by LivePanelTests.testQueueOrder and LivePanelTests.testNeedsYouFirst.',
    } },
    { kind: 'said', at: '10:06 AM', text: 'The queue sorts by `created`, newest first. Issue #251 wants the oldest waiting item on top, so I’ll flip the sort and run the panel’s tests.' },
    { kind: 'tool', tool: 'Edit', verb: 'Edited', target: 'Mac/App/LivePanel.swift', state: 'done', seconds: 0.1, meta: '+4 −2', detail: {
      diff: '@@ -64,8 +64,10 @@ final class LivePanel {\n     var attentionItems: [InboxItem] {\n-        inbox.items.filter(\\.needsYou)\n-            .sorted { $0.created > $1.created }\n+        // oldest waiting first (#251)\n+        inbox.items.filter(\\.needsYou)\n+            .sorted { $0.created < $1.created }\n     }',
    } },
    { kind: 'asked', text: 'Asked to run xcodebuild test -scheme Oby', answer: 'Allowed by your rule Bash(xcodebuild test:*)' },
    { kind: 'tool', tool: 'Bash', verb: 'Ran', target: 'xcodebuild test -scheme Oby -only-testing:MacTests/LivePanelTests', state: 'failed', seconds: 192, meta: 'exit 65', detail: {
      input: 'xcodebuild test -scheme Oby -only-testing:MacTests/LivePanelTests',
      lines: 1284, exit: 65,
      output: 'Signing with team [vault: APPLE_TEAM_ID]\nTest Suite \'LivePanelTests\' started\nTest Case \'-[LivePanelTests testQueueOrder]\' passed (0.012 seconds)\nTest Case \'-[LivePanelTests testStableOrder]\' failed (0.009 seconds)\n    XCTAssertEqual failed: ("[b, a]") is not equal to ("[a, b]")\nTest Case \'-[LivePanelTests testNeedsYouFirst]\' failed (0.011 seconds)\n    XCTAssertEqual failed: ("info") is not equal to ("question")\nExecuted 9 tests, with 2 failures (0 unexpected) in 0.084 seconds\n** TEST FAILED **',
    } },
    { kind: 'thought', seconds: 9, text: 'Two failures. testStableOrder wants items created at the same second to keep inbox order, and Swift’s sort isn’t stable. testNeedsYouFirst wants questions above info items, which I filtered instead of sorting. Sort by (needs you, created, index in the inbox).' },
    { kind: 'you', at: '10:50 AM', text: 'Also keep the items that need me above the rest.' },
    { kind: 'start', text: 'Round 2 · Cursor · Sonnet 5.5', at: '10:51 AM' },
    { kind: 'said', at: '10:51 AM', text: 'Round 1 sorted the queue by created date, but the tests want a stable order with the items that need you first. I’ll sort by (needs you, created, index in the inbox) and run the tests again.' },
    { kind: 'plan', todos: [
      { text: 'Make the sort stable', state: 'done' },
      { text: 'Keep items that need you first', state: 'running' },
      { text: 'Run LivePanelTests', state: 'pending' },
    ] },
    { kind: 'tool', tool: 'Edit', verb: 'Edited', target: 'Mac/App/LivePanel.swift', state: 'done', seconds: 0.1, meta: '+12 −5', detail: {
      diff: '@@ -64,10 +64,17 @@ final class LivePanel {\n     var attentionItems: [InboxItem] {\n-        // oldest waiting first (#251)\n-        inbox.items.filter(\\.needsYou)\n-            .sorted { $0.created < $1.created }\n+        // needs you first, then oldest first; ties keep inbox order (#251)\n+        inbox.items.enumerated()\n+            .sorted { a, b in\n+                if a.element.needsYou != b.element.needsYou { return a.element.needsYou }\n+                if a.element.created != b.element.created { return a.element.created < b.element.created }\n+                return a.offset < b.offset\n+            }\n+            .map(\\.element)\n     }',
    } },
    { kind: 'tool', tool: 'Read', verb: 'Reading', target: 'Engine/Inbox.swift', state: 'running', seconds: 3 },
    { kind: 'said', at: '10:53 AM', live: true, text: 'Checking how the inbox marks an item that needs you, so the sort reads the same flag the notch does, then I’ll run LivePanelTests again.' },
  ],
};
