#if DEBUG
import Foundation

/// The job page's six states from the canvas (working, planning, waiting for you, running checks,
/// failed, done) as obid would send them, for previews and tests: one job, "Give the scan's first
/// block a fix round", at each point, with every fact of #739 served. `bare` drops those facts, as
/// today's obid sends a job.
nonisolated enum JobPageFixture: String, CaseIterable, Sendable {
    case working, planning, needs, checks, failed, done

    /// The job's JSON, its times counted back from `now`.
    func json(now: Date = .now, bare: Bool = false) -> Data {
        func at(_ minutesAgo: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60)) }
        var job: [String: Any] = [
            "id": "fixture-\(rawValue)", "request": "When the secret scan blocks the first push, give the agent a round to fix it.",
            "agent": "claude", "account": "personal", "repo": "obi-ai-bot/obi", "branch": "oby/scan-fix-round", "base": "dev",
            "kind": "build", "task": "Give the scan's first block a fix round", "title": "Give the scan's first block a fix round",
            "status": "running", "step": "", "summary": "", "created": at(minutes + 1), "started": at(minutes),
            "rounds": 2, "round": self == .failed ? 2 : 1, "check": "cargo test -p obid", "model": "claude-opus-5-5", "effort": "high",
            "mode": self == .planning || self == .needs ? "plan" : "acceptEdits", "outgoing": [] as [Any], "notes": [] as [Any],
        ]
        var stages: [[String: Any]] = [
            ["id": "prepare", "title": "Prepare", "state": "done", "detail": "Clone and worktree", "started": at(minutes), "finished": at(minutes - 0.3)],
            ["id": "work", "title": "Work", "state": "upcoming", "detail": "Round 1 of 2", "estimate": ["low": 420, "high": 660]],
            ["id": "check", "title": "Check", "state": "upcoming", "detail": "cargo test -p obid", "estimate": ["low": 150, "high": 210]],
            ["id": "publish", "title": "Publish", "state": "upcoming", "detail": "Secret scan, push and pull request", "estimate": ["low": 20, "high": 40]],
            ["id": "review", "title": "Review", "state": "upcoming", "detail": "Waiting for review"],
        ]
        let tool = { (summary: String, state: String, ago: Double, seconds: Double?) -> [String: Any] in
            var line: [String: Any] = ["tool": "Bash", "kind": "command", "summary": summary, "state": state, "started": at(ago)]
            if let seconds { line["seconds"] = seconds }
            return line
        }
        func group(_ id: String, _ title: String, _ state: String, from: Double, to: Double?, counts: [String: Int], tools: [[String: Any]] = [],
                   files: [String] = [], diff: [String: Int]? = nil) -> [String: Any] {
            var group: [String: Any] = ["id": id, "title": title, "state": state, "started": at(from), "counts": counts, "files": files, "tools": tools]
            if let to { group["finished"] = at(to) }
            if let diff { group["diff"] = diff }
            return group
        }
        let workStart = minutes - 0.3
        switch self {
        case .working:
            job["phase"] = "work"
            job["step"] = "Running the publish tests after changing jobs.rs"
            stages[1]["state"] = "current"; stages[1]["started"] = at(workStart)
            stages[1]["detail"] = "Round 1 of 2 · Running the publish tests after changing jobs.rs"
            job["context"] = "It made a blocked first push start a fix round instead of ending the job, and is checking the old tests still pass."
            job["activity"] = ["counts": ["read": 23, "search": 9, "edit": 3, "command": 4, "test": 1, "tetrix": 3, "web": 1], "groups": [
                group("g1", "Found where a blocked scan ends the job", "done", from: 8.7, to: 5.7, counts: ["read": 14, "tetrix": 2]),
                group("g2", "Looked up what gitleaks' exit codes mean", "done", from: 5.7, to: 5.0, counts: ["web": 1]),
                group("g3", "Changed what a blocked first push does", "done", from: 5.0, to: 1.0, counts: ["edit": 3]),
                group("g4", "Testing the change", "running", from: 1.0, to: nil, counts: ["command": 2],
                      tools: [tool("Ran cargo build -p obid", "done", 1.0, 22), tool("Running cargo test -p obid --test publish_api", "running", 0.68, nil)],
                      files: ["core/crates/obid/src/jobs.rs", "core/crates/obid/tests/publish_api.rs"], diff: ["added": 34, "removed": 9]),
            ]]
        case .planning:
            job["phase"] = "work"
            job["step"] = "Reading how a blocked secret scan ends a job"
            stages[1]["state"] = "current"; stages[1]["started"] = at(workStart)
            stages[1]["detail"] = "Plan mode · Reading how a blocked secret scan ends a job"
            job["context"] = "It reads and asks Tetrix, changes nothing, and brings you a plan to approve."
            job["activity"] = ["counts": ["read": 6, "search": 3, "tetrix": 2], "groups": [
                group("g1", "Reading the publish step", "running", from: 1.7, to: nil, counts: ["read": 6, "search": 3, "tetrix": 2],
                      tools: [tool("Read core/crates/obid/src/publish.rs", "done", 1.5, 1), tool("Asking Tetrix what calls publish::scan_outgoing", "running", 0.05, nil)]),
            ]]
        case .needs:
            job["phase"] = "work"
            job["step"] = "Waiting for your OK on the plan"
            stages[1]["state"] = "current"; stages[1]["started"] = at(workStart); stages[1]["waited"] = 120
            stages[1]["detail"] = "Waiting for your OK on the plan"
            job["context"] = "It planned for 3m 40s: 11 files read, 3 questions to Tetrix. Once you approve, it works in the mode set above."
            job["question"] = ["text": "Approve the plan?", "options": ["Approve", "Keep planning"], "recommended": 0,
                               "plan": "1. When the secret scan blocks the first push, start a fix round instead of failing the job (`jobs.rs`).\n2. Tell the agent which file and line the scan flagged, never the secret itself.\n3. A second block still ends the job, with nothing pushed.\n4. Add two tests to `publish_api.rs` for the first and second block.\n5. Note the change in `docs/runner-api.md`."]
            job["activity"] = ["counts": ["read": 11, "search": 5, "tetrix": 3], "groups": [
                group("g1", "Read the publish step", "done", from: 5.7, to: 3.7, counts: ["read": 11]),
                group("g2", "Asked Tetrix what a change would touch", "done", from: 3.7, to: 2.8, counts: ["tetrix": 3]),
                group("g3", "Wrote the plan", "done", from: 2.8, to: 2.1, counts: [:]),
            ]]
        case .checks, .failed, .done:
            job["phase"] = self == .done ? "review" : "check"
            stages[1]["state"] = "done"; stages[1]["started"] = at(workStart); stages[1]["finished"] = at(self == .failed ? 8.5 : self == .done ? 15.6 : 1.9)
            stages[1].removeValue(forKey: "estimate")
            stages[1]["detail"] = self == .failed ? "2 rounds" : "Round 1 of 2"
            job["commits"] = self == .failed ? 3 : 2
            job["activity"] = ["counts": ["read": 26, "search": 9, "edit": 5, "command": 7, "test": 2, "tetrix": 3, "web": 1], "groups": [] as [Any]]
            job["diff"] = ["files": 3, "added": 41, "removed": 11]
            let fmt: [String: Any] = ["command": "cargo fmt --check", "passed": true, "seconds": 3]
            let clippy: [String: Any] = ["command": "cargo clippy -- -D warnings", "passed": true, "seconds": 38]
            switch self {
            case .checks:
                job["step"] = "Running the obid tests"
                stages[2]["state"] = "current"; stages[2]["started"] = at(1.9)
                stages[2]["detail"] = "Running the obid tests: 412 of 793 passed so far"
                stages[2].removeValue(forKey: "estimate")
                job["context"] = "Nothing goes out until every check passes and the secret scan is clean."
                job["checks"] = [["round": 1, "steps": [fmt, clippy, ["command": "cargo test -p obid", "running": true, "seconds": 72,
                                                                       "tests": ["passed": 412, "total": 793]]]]]
            case .failed:
                job["status"] = "failed"
                job["finished"] = at(3)
                job["summary"] = "Two publish tests still fail after 2 rounds\nThey expect a blocked first push to end the job, which is the old behaviour this task changes."
                stages[2]["state"] = "failed"; stages[2]["started"] = at(8.5); stages[2]["finished"] = at(3.5)
                stages[2]["detail"] = "2 of 793 tests failed in round 2, out of rounds"
                stages[3]["state"] = "skipped"; stages[4]["state"] = "skipped"
                job["checks"] = [["round": 2, "steps": [fmt, clippy, ["command": "cargo test -p obid", "passed": false, "seconds": 171,
                                                                       "tests": ["passed": 791, "failed": 2, "total": 793]]],
                                  "failing": [["test": "publish_api::scan_blocks_first_push", "message": "expected Failed, got FixRound"],
                                              ["test": "publish_api::second_block_ends_job", "message": "left: \"scan failed\"  right: \"scan blocked twice\""]]]]
                job["scan"] = ["ran": false, "reason": "checks come first"]
            default:
                job["status"] = "done"
                job["finished"] = at(12)
                job["summary"] = "A blocked first push now gets a fix round. The job only fails if the scan blocks again, and nothing is pushed until it's clean."
                stages[2]["state"] = "done"; stages[2]["started"] = at(15.6); stages[2]["finished"] = at(12.3); stages[2]["detail"] = "All passed"
                stages[3]["state"] = "done"; stages[3]["started"] = at(12.3); stages[3]["finished"] = at(12)
                stages[3]["detail"] = "Pushed and opened #722"
                stages[4]["state"] = "current"; stages[4]["started"] = at(12)
                job["published"] = "https://github.com/obi-ai-bot/obi/pull/722"
                job["pushed"] = 2
                job["pullRequest"] = ["state": "OPEN", "base": "dev", "checkedAt": at(1)]
                job["outgoing"] = [["action": "push", "repo": "obi-ai-bot/obi", "id": "3b59358aa1", "branch": "oby/scan-fix-round", "date": at(12)],
                                   ["action": "pullRequest", "repo": "obi-ai-bot/obi", "id": "#722", "date": at(12)]]
                job["checks"] = [["round": 1, "steps": [fmt, clippy, ["command": "cargo test -p obid", "passed": true, "seconds": 158,
                                                                       "tests": ["passed": 793, "failed": 0, "total": 793]]]]]
                job["scan"] = ["ran": true, "clean": true, "commits": 2, "files": 3, "seconds": 4, "findings": [] as [Any]]
            }
        }
        job["pipeline"] = ["stages": stages, "number": stages.firstIndex { ["current", "failed"].contains($0["state"] as? String) }.map { $0 + 1 } ?? 5,
                           "total": stages.count]
        if !bare {
            job["estimate"] = estimate
            job["usage"] = usage
            job["windowShare"] = share
        } else {
            for key in ["activity", "context", "checks", "scan", "diff", "estimate", "usage", "windowShare"] { job.removeValue(forKey: key) }
            job["pipeline"] = ["stages": stages.map { $0.filter { !["started", "finished", "waited", "estimate"].contains($0.key) } },
                               "number": 2, "total": stages.count]
        }
        return (try? JSONSerialization.data(withJSONObject: job)) ?? Data()
    }

    /// How long it has been going, in minutes.
    private var minutes: Double {
        switch self {
        case .working: 9
        case .planning: 2
        case .needs: 6
        case .checks: 14
        case .failed: 25
        case .done: 31
        }
    }

    private var estimate: [String: Any] {
        switch self {
        case .planning:
            ["low": 720, "high": 1200, "samples": 14,
             "basis": "Too early to be sure: the last 14 jobs like this in obi took 12–20m. Your time on the plan isn't counted; the range narrows once it's approved."]
        case .needs:
            ["low": 780, "high": 1020, "samples": 14, "basis": "Jobs in obi with a plan this size took 9–13m from approval to a pull request. Waiting on you isn't counted."]
        case .checks:
            ["low": 900, "high": 1020, "samples": 14,
             "basis": "The last full run of these tests in obi took 2m 40s, and this one is on the same pace. Publishing after it takes about 30s."]
        case .failed:
            ["low": 720, "high": 1200, "samples": 14, "basis": "It ran past the usual range because round 1 failed its checks and round 2 had to run them again."]
        default:
            ["low": 720, "high": 960, "samples": 14, "firstGiven": ["low": 720, "high": 1200],
             "basis": "From the last 14 jobs like this in obi on Claude Code (13m in the middle). Narrows once the first test run passes."]
        }
    }

    private var usage: [String: Any] {
        let tokens: [JobPageFixture: Int] = [.working: 1_900_000, .planning: 214_000, .needs: 388_000, .checks: 2_400_000, .failed: 3_600_000, .done: 2_600_000]
        let cost: [JobPageFixture: Double] = [.working: 2.7, .planning: 0.31, .needs: 0.55, .checks: 3.3, .failed: 4.9, .done: 3.6]
        let all = tokens[self] ?? 0
        return ["input": all / 20, "output": all / 25, "cacheRead": all - all / 20 - all / 25, "costUsd": cost[self] ?? 0, "priced": "plan"]
    }

    private var share: [String: Any] {
        let points: [JobPageFixture: (Double, Double)] = [.working: (11, 2), .planning: (1, 0.4), .needs: (2, 0.6), .checks: (13, 3), .failed: (19, 4), .done: (14, 3)]
        let (five, week) = points[self] ?? (0, 0)
        return ["fiveHour": five, "sevenDay": week, "estimate": true]
    }

    /// The account's windows on the canvas, 0...1.
    var windows: (fiveHour: Double, sevenDay: Double) {
        switch self {
        case .working: (0.46, 0.31)
        case .planning: (0.36, 0.29)
        case .needs: (0.37, 0.29)
        case .checks: (0.49, 0.32)
        case .failed: (0.58, 0.34)
        case .done: (0.51, 0.32)
        }
    }
}
/// Sangam's sample session (#786's "#251 Attention queue") as obid would send it (#755, #784):
/// two rounds, words, thinking, reads, a search, Tetrix, edits, a failed test run, your words, a
/// to-do list, a call still running and words still being written. For previews and pictures.
nonisolated enum SessionFixture {
    static func entries(now: Date = .now) -> [TranscriptEntry] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        let tool = { (n: Int, ago: Double, tool: String, activity: String, summary: String, state: String, seconds: Double?) in
            TranscriptEntry(n: n, at: at(ago), kind: "tool", tool: tool, summary: summary, state: state, seconds: seconds, activity: activity)
        }
        var edit1 = tool(7, 47, "Edit", "edit", "Edited Mac/App/LivePanel.swift", "done", 0.1); edit1.added = 4; edit1.removed = 2
        var run = tool(8, 46, "Bash", "test", "Ran xcodebuild test -scheme Oby -only-testing:MacTests/LivePanelTests", "failed", 192); run.exit = 65
        var edit2 = tool(14, 2, "Edit", "edit", "Edited Mac/App/LivePanel.swift", "done", 0.1); edit2.added = 12; edit2.removed = 5
        return [
            TranscriptEntry(n: 1, at: at(51), kind: "start", summary: "Round 1 on Cursor"),
            TranscriptEntry(n: 2, at: at(51), kind: "said", text: "I'll read how the attention queue is built before changing anything."),
            tool(3, 50, "Read", "read", "Read Engine/Inbox.swift", "done", 0.2),
            tool(4, 50, "Grep", "search", "Searched for attentionItems", "done", 0.1),
            tool(5, 49, "mcp__tetrix__impact", "tetrix", "Asked Tetrix what calls LivePanel.attentionItems", "done", 2.1),
            TranscriptEntry(n: 6, at: at(48), kind: "said", text: "The queue sorts by `created`, newest first. Issue #251 wants the oldest waiting item on top, so I'll flip the sort and run the panel's tests."),
            edit1, run,
            TranscriptEntry(n: 9, at: at(42), kind: "thought", text: "Two failures. testStableOrder wants items created at the same second to keep inbox order, and Swift's sort isn't stable. testNeedsYouFirst wants questions above info items, which I filtered instead of sorting.", seconds: 9),
            TranscriptEntry(n: 10, at: at(3), kind: "start", summary: "Round 2 on Cursor"),
            TranscriptEntry(n: 11, at: at(3.5), kind: "you", summary: "Also keep the items that need me above the rest."),
            TranscriptEntry(n: 12, at: at(3), kind: "said", text: "Round 1 sorted the queue by created date, but the tests want a stable order with the items that need you first. I'll sort by (needs you, created, index in the inbox) and run the tests again."),
            TranscriptEntry(n: 13, at: at(3), kind: "plan", summary: "1 of 3 done", todos: [.init(text: "Make the sort stable", state: "done"),
                                                                                                  .init(text: "Keep items that need you first", state: "running"),
                                                                                                  .init(text: "Run LivePanelTests", state: "pending")]),
            edit2,
            tool(15, 0.05, "Read", "read", "Reading Engine/Inbox.swift", "running", nil),
            TranscriptEntry(n: 16, at: at(0), kind: "said", text: "Checking how the inbox marks an item that needs you, so the sort reads the same flag the notch does"),
        ]
    }

    /// What the failed test run's row opens into.
    static let detail = TranscriptDetail(
        input: ["command": .string("xcodebuild test -scheme Oby -only-testing:MacTests/LivePanelTests")],
        output: .init(text: "Signing with team [vault: APPLE_TEAM_ID]\nTest Suite 'LivePanelTests' started\nTest Case '-[LivePanelTests testQueueOrder]' passed (0.012 seconds)\nTest Case '-[LivePanelTests testStableOrder]' failed (0.009 seconds)\n    XCTAssertEqual failed: (\"[b, a]\") is not equal to (\"[a, b]\")\nExecuted 9 tests, with 2 failures (0 unexpected) in 0.084 seconds\n** TEST FAILED **",
                      lines: 1284, truncated: true, exit: 65))
}
#endif
