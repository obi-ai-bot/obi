import Foundation
import Testing
@testable import Oby

/// Sangam's design on the iPhone (design/app): what Home says, the work in its kinds, the
/// conversations list obid keeps (#493), and what a task's card says, with no view in the way.
@MainActor
struct DesignTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func job(_ id: String, _ status: String, kind: String = "fix", issue: Int? = nil, created: String = "2026-10-09T21:42:53Z",
             finished: String? = nil, extra: String = "") throws -> Job {
        let json = #"{"id": "\#(id)", "request": "Fix it", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/fix-1", "base": "dev", "kind": "\#(kind)", "task": "Fix it", "status": "\#(status)", "step": "", "summary": "", "session": null, "created": "\#(created)", "started": "\#(created)", "finished": \#(finished.map { "\"\($0)\"" } ?? "null")\#(issue.map { ", \"issue\": \($0)" } ?? "")\#(extra)}"#
        return try Runner.decoder.decode(Job.self, from: Data(json.utf8))
    }

    // MARK: Home

    @Test func homeSaysWhatsRunningAndWhatNeedsYou() {
        #expect(HomeLine.attention(running: 2, needs: 1) == "2 running tasks · 1 needs you")
        #expect(HomeLine.attention(running: 1, needs: 0) == "1 running task · nothing needs you")
        #expect(HomeLine.attention(running: 0, needs: 3) == "3 need you")
        #expect(HomeLine.attention(running: 0, needs: 0) == "All quiet. Give me something to work on")
        // The owner's first name, from the Mac's own name, when it says whose it is.
        #expect(HomeLine.owner(ofMac: "Wellington's MacBook Pro") == "Wellington")
        #expect(HomeLine.owner(ofMac: "Sangam’s Mac mini") == "Sangam")
        #expect(HomeLine.owner(ofMac: "Studio") == nil)
        #expect(HomeLine.owner(ofMac: nil) == nil)
        #expect(HomeLine.placeholder(fullName: "Wellington") == "What do you want me to work on, Wellington?")
        #expect(HomeLine.placeholder(fullName: "") == "What do you want me to work on?")
    }

    @Test func jobsBecomeWorkInTheirKinds() throws {
        let review = try job("r", "running", kind: "review")
        let issue = try job("i", "failed", issue: 12, finished: "2026-10-09T22:00:00Z")
        let task = try job("t", "done", finished: "2026-10-09T22:30:00Z")
        let since = ISO8601DateFormatter().date(from: "2026-10-09T21:00:00Z")!
        let items = PhoneWork.items([review, issue, task], since: since, seen: ["t"])
        // Latest first: by when it finished, else when it began.
        #expect(items.map(\.type) == [.tasks, .issues, .review])
        #expect(items.map(\.status) == [.done, .needs, .running])
        // New until it's opened.
        #expect(items.map(\.fresh) == [false, true, true])
        let groups = WorkList.groups(items, by: .type)
        #expect(groups.map(\.label) == ["Review PR", "Issues", "Tasks"])
        #expect(groups[1].needs == 1)
        // A kind's page: Running holds what needs you too; Completed the rest.
        #expect(WorkList.items(items, in: .running).map(\.id) == ["i", "r"])
        #expect(WorkList.items(items, in: .done).map(\.id) == ["t"])
    }

    @Test func archivedHoldsWhatLeftHome() throws {
        let cleared = try job("c", "done", finished: "2026-10-09T22:00:00Z")
        let dismissed = try job("d", "failed", finished: "2026-10-09T22:00:00Z", extra: #", "dismissed": "2026-10-09T23:00:00Z""#)
        let fresh = try job("f", "done", finished: "2026-10-10T09:00:00Z")
        let running = try job("r", "running")
        let clearedAt = ISO8601DateFormatter().date(from: "2026-10-10T08:00:00Z")!
        #expect(PhoneWork.archived([cleared, dismissed, fresh, running], clearedAt: clearedAt).map(\.id) == ["c", "d"])
        #expect(PhoneWork.archived([fresh, running], clearedAt: nil).isEmpty)
    }

    // MARK: Conversations

    @Test func conversationsDecodeTolerantly() throws {
        let wire = #"[{"id":"5b0e","title":"Review oby PR #33","pinned":true,"created":"2026-10-16T09:12:00Z","lastActivity":"2026-10-16T09:14:07Z","cursor":"0-42"},{"id":"7c1e","lastActivity":"not a date","newKey":1},{"id":"9a4b","title":"Watch target","turn":{"id":"t1","who":"user","at":"2026-10-16T09:12:00Z","text":"never touch the watch target"}}]"#
        let list = try Runner.decoder.decode([RunnerConversation].self, from: Data(wire.utf8))
        #expect(list.map(\.id) == ["5b0e", "7c1e", "9a4b"])
        #expect(list[0].pinned && list[0].title == "Review oby PR #33" && list[0].latest == ISO8601DateFormatter().date(from: "2026-10-16T09:14:07Z"))
        #expect(!list[1].pinned && list[1].title.isEmpty && list[1].lastActivity == nil && !list[1].deleted)
        #expect(list[2].turn?.text == "never touch the watch target")

        // The event: a conversation changed, or went.
        var parser = EventParser()
        for line in ["event: conversation", #"data: {"id":"5b0e","deleted":true}"#] { #expect(parser.feed(line) == nil) }
        guard case .conversation(let gone)? = parser.feed("") else { Issue.record("no conversation event"); return }
        #expect(gone.id == "5b0e" && gone.deleted)

        // What POST /v1/plans answers says which conversation the words joined.
        let planned = try Runner.decoder.decode(PlannedTurn.self, from: Data(#"{"kind":"reply","text":"Hi.","jobs":[],"drafts":[],"conversation":"c1"}"#.utf8))
        #expect(planned.conversation == "c1" && planned.result == .reply("Hi.", started: []))
        let old = try Runner.decoder.decode(PlannedTurn.self, from: Data(#"{"kind":"none","jobs":[]}"#.utf8))
        #expect(old.conversation == nil && old.result == .none)

        // A step names its conversation on obid: the thread shows only its own.
        let step = try Runner.decoder.decode(TurnStep.self, from: Data(#"{"turn":"8d","conversation":"c1","index":1,"text":"Thinking","state":"running"}"#.utf8))
        #expect(step.conversation == "c1")
        #expect(ConversationList.shows(step, in: "c1", startingNew: false))
        #expect(!ConversationList.shows(step, in: "c2", startingNew: false))
        #expect(!ConversationList.shows(step, in: nil, startingNew: true))
        #expect(ConversationList.shows(TurnStep(turn: "t", index: 1, text: "Reading", state: .running), in: nil, startingNew: false))

        // A turn names its conversation on obid.
        let turn = try Runner.decoder.decode(RunnerTurn.self, from: Data(#"{"id":"x","who":"user","text":"hi","at":"2026-10-11T09:12:04Z","jobs":[],"conversation":"c1"}"#.utf8)).turn
        #expect(turn.conversation == "c1")
    }

    @Test func conversationsListPinnedThenRecent() {
        let at = { (minutes: Double) in now.addingTimeInterval(-minutes * 60) }
        let a = RunnerConversation(id: "a", title: "A", lastActivity: at(30))
        let b = RunnerConversation(id: "b", title: "B", pinned: true, lastActivity: at(300))
        let c = RunnerConversation(id: "c", title: "C", lastActivity: at(5))
        let sections = ConversationList.sections([a, b, c])
        #expect(sections.pinned.map(\.id) == ["b"])
        #expect(sections.recent.map(\.id) == ["c", "a"])
        // An event puts it in place, or takes it out.
        let renamed = ConversationList.placed(RunnerConversation(id: "a", title: "A2", lastActivity: at(1)), in: [a, b, c])
        #expect(renamed.map(\.title) == ["B", "A2", "C"])
        #expect(ConversationList.placed(RunnerConversation(id: "c", title: "", deleted: true), in: [a, b, c]).map(\.id) == ["b", "a"])
        // Times as the design says them.
        #expect(ConversationList.ago(at(0.5), now: now) == "now")
        #expect(ConversationList.ago(at(5), now: now) == "5m")
        #expect(ConversationList.ago(at(130), now: now) == "2h")
        #expect(ConversationList.ago(at(3 * 1440 + 10), now: now) == "3d")
    }

    // MARK: A task's card

    #if DEBUG
    @Test func theSampleTasksRead() {
        #expect(SampleTasks.jobs.map(\.id) == ["sample-run", "sample-needs", "sample-done"])
    }
    #endif

    @Test func aDoneTaskSaysWhatItLeftBehind() throws {
        let done = try job("d", "done", finished: "2026-10-09T22:16:53Z", extra: #", "commits": 2, "published": "https://github.com/deskree-inc/oby/pull/412""#)
        #expect(TaskFacts.resultLine(done) == "2 commits on oby/fix-1 · oby#412 · Took 34m")
        #expect(TaskFacts.facts(done).map(\.name) == ["Repository", "Branch", "Base", "Model"])
        let running = try job("r", "running", extra: #", "rounds": 4, "round": 2"#)
        #expect(running.maxRounds == 4 && running.currentRound == 2)
        #expect(TaskFacts.box(running) == "Tell Claude Code…")
    }
}
