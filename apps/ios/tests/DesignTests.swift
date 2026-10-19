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

    /// One "needs you" (docs/oby-ux.md rows 5 and 10): the tasks with an open decision, its own or
    /// an inbox item, plus the decisions with no task on Home; the line leads to the longest-waiting.
    @Test func needsYouIsCountedOnceAndLeadsToTheTask() throws {
        let queued = try job("q", "queued")
        let running = try job("r", "running")
        let failed = try job("f", "failed", finished: "2026-10-09T22:00:00Z")
        let since = ISO8601DateFormatter().date(from: "2026-10-09T21:00:00Z")!
        func item(_ id: String, _ kind: String, job: String, created: TimeInterval, later: Date? = nil) -> InboxItem {
            InboxItem(kind: kind, id: id, job: job, title: kind, text: "", options: [], created: Date(timeIntervalSince1970: created), later: later)
        }
        let start = item("i1", "start", job: "q", created: 200)
        let audit = item("i2", "audit", job: "", created: 100)
        let putOff = item("i3", "question", job: "r", created: 50, later: .now.addingTimeInterval(3600))
        let elsewhere = item("i4", "question", job: "older-than-the-list", created: 300)
        let inbox = InboxItem.waiting([start, audit, putOff, elsewhere])
        let items = PhoneWork.items([queued, running, failed], inbox: inbox, since: since, seen: [])
        // A Start it? on a queued task makes it need you; a decision put off doesn't, until it's back.
        #expect(items.first { $0.id == "q" }?.status == .needs)
        #expect(items.first { $0.id == "r" }?.status == .running)
        // The Inbox holds only what has no task on Home.
        let loose = PhoneWork.loose(inbox, among: items)
        #expect(loose.map(\.id) == ["i2", "i4"])
        #expect(WorkList.needsYou(items, loose: loose.count) == 4)
        // The longest-waiting decision first: here the one with no task, so the Inbox.
        #expect(PhoneWork.firstNeeding(items, inbox: inbox) == .inbox)
        #expect(PhoneWork.firstNeeding(items, inbox: [start, elsewhere]) == .task("q"))
        // No inbox item (an older runner): the first task that needs you.
        #expect(PhoneWork.firstNeeding(items, inbox: []) == .task("f"))
        #expect(PhoneWork.firstNeeding(items.filter { $0.status != .needs }, inbox: []) == nil)
    }

    /// Home as Sangam has it (docs/oby-ux.md row 3, docs/ios-design.md "Home"): every kind is a chip
    /// whatever's in it; under them the running tasks with what each is on, and the latest talk.
    @Test func homeShowsEveryKindAndWhatsRunning() throws {
        let needs = try job("n", "running", extra: #", "question": {"text": "Which branch?", "options": ["dev"]}"#)
        var running = try job("r", "running")
        running.step = "Running swift test"
        let queued = try job("q", "queued")
        let done = try job("d", "done", finished: "2026-10-09T22:00:00Z")
        let since = ISO8601DateFormatter().date(from: "2026-10-09T23:00:00Z")!
        let items = PhoneWork.items([needs, running, queued, done], since: since, seen: [])
        // Only Tasks hold anything, yet Review PR and Issues are chips too, in Home's order.
        #expect(WorkList.kinds(items).map(\.label) == ["Review PR", "Issues", "Tasks", "Routines"])
        #expect(WorkList.kinds(items).map(\.needs) == [0, 0, 1, 0])
        #expect(WorkList.kinds([] as [WorkList.Item<Job>]).map(\.label) == ["Review PR", "Issues", "Tasks", "Routines"])
        // Running: up to three open tasks, what needs you before the rest; each says what it's on.
        let rows = PhoneWork.running(items)
        #expect(rows.map(\.id) == ["n", "q", "r"])
        let question = InboxItem(kind: "question", id: "i", job: "n", title: "", text: "", options: [], created: now)
        #expect(PhoneWork.step(rows[0], decision: question) == "Needs you · Question")
        #expect(PhoneWork.step(rows[0], decision: nil) == "Needs you · Question")
        #expect(PhoneWork.step(rows[1], decision: nil) == "Queued")
        #expect(PhoneWork.step(rows[2], decision: nil) == "Running swift test")
        // Recent: the three latest conversations.
        let talk = (1...4).map { RunnerConversation(id: "c\($0)", title: "", lastActivity: now.addingTimeInterval(Double($0))) }
        #expect(PhoneWork.recent(talk).map(\.id) == ["c4", "c3", "c2"])
    }

    /// A task's ⋮ (Sangam's TaskMenu.tsx, docs/oby-ux.md row 21): its conversation; Stop task while
    /// it goes, Archive task once it's done; Move to… and Mode under them; Dismiss when it needs you.
    @Test func aTaskMenuHasSangamsItems() throws {
        let running = try job("r", "running", extra: #", "mode": "ask""#)
        let done = try job("d", "done", finished: "2026-10-09T22:00:00Z")
        let failed = try job("f", "failed", finished: "2026-10-09T22:00:00Z")
        #expect(TaskMenu.items(running, conversation: true) == [.openConversation, .stop, .move, .mode])
        #expect(TaskMenu.items(done, conversation: false) == [.archive, .move])
        #expect(TaskMenu.items(failed, conversation: true) == [.openConversation, .dismiss, .move])
        // Archived on this iPhone: off Home, into Archived; told something, it runs again and comes back.
        #expect(PhoneWork.archived([done, running], clearedAt: nil, here: ["d"]).map(\.id) == ["d"])
        #expect(PhoneWork.archived([running], clearedAt: nil, here: ["r"]).isEmpty)
    }

    /// Oby's live face (Sangam's ObyFaceLive.tsx): while it works the face melts into three
    /// bouncing dots and holds there; its words in, they run back together into the still face.
    @Test func obysFaceMeltsIntoDotsAndBack() {
        var motion = ObyLiveMotion()
        for _ in 0..<120 { motion.step(1.0 / 60, live: true) }
        #expect(abs(motion[.dSpread] - 1) < 0.15 && abs(motion[.dR] - 1) < 0.1 && motion[.scale] < 0.15)
        // Still at work long after: it holds the dots, never coming together on its own.
        for _ in 0..<600 { motion.step(1.0 / 60, live: true) }
        #expect(abs(motion[.dSpread] - 1) < 0.15 && !motion.settled)
        // The words land: back into the face, and done.
        for _ in 0..<300 { motion.step(1.0 / 60, live: false) }
        #expect(motion.settled)
        #expect(abs(motion[.scale] - 1) < 0.01 && motion[.dR] < 0.01 && abs(motion[.inflate] - 0.17) < 0.01)
        // A face that takes over from one at work starts with the dots out.
        #expect(abs(ObyLiveMotion(working: true)[.dSpread] - 1) < 0.15)
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
        #expect(ConversationOrder.shows(step, in: "c1", startingNew: false))
        #expect(!ConversationOrder.shows(step, in: "c2", startingNew: false))
        #expect(!ConversationOrder.shows(step, in: nil, startingNew: true))
        #expect(ConversationOrder.shows(TurnStep(turn: "t", index: 1, text: "Reading", state: .running), in: nil, startingNew: false))

        // A turn names its conversation on obid.
        let turn = try Runner.decoder.decode(RunnerTurn.self, from: Data(#"{"id":"x","who":"user","text":"hi","at":"2026-10-11T09:12:04Z","jobs":[],"conversation":"c1"}"#.utf8)).turn
        #expect(turn.conversation == "c1")
    }

    @Test func conversationsListPinnedThenRecent() {
        let at = { (minutes: Double) in now.addingTimeInterval(-minutes * 60) }
        let a = RunnerConversation(id: "a", title: "A", lastActivity: at(30))
        let b = RunnerConversation(id: "b", title: "B", pinned: true, lastActivity: at(300))
        let c = RunnerConversation(id: "c", title: "C", lastActivity: at(5))
        let sections = ConversationOrder.sections([a, b, c])
        #expect(sections.pinned.map(\.id) == ["b"])
        #expect(sections.recent.map(\.id) == ["c", "a"])
        // An event puts it in place, or takes it out.
        let renamed = ConversationOrder.placed(RunnerConversation(id: "a", title: "A2", lastActivity: at(1)), in: [a, b, c])
        #expect(renamed.map(\.title) == ["B", "A2", "C"])
        #expect(ConversationOrder.placed(RunnerConversation(id: "c", title: "", deleted: true), in: [a, b, c]).map(\.id) == ["b", "a"])
        // Times as the design says them.
        #expect(ConversationOrder.ago(at(0.5), now: now) == "now")
        #expect(ConversationOrder.ago(at(5), now: now) == "5m")
        #expect(ConversationOrder.ago(at(130), now: now) == "2h")
        #expect(ConversationOrder.ago(at(3 * 1440 + 10), now: now) == "3d")
    }

    /// Home's words start a conversation: obid names it in a `conversation` event as the turn
    /// begins, titled from the words, so the phone knows its id before the answer (Stop needs it).
    @Test func aNewConversationIsKnownByItsTitle() {
        let said = "review oby PR #33 and tell me what it changes in the gateway, please"
        #expect(ConversationOrder.started(by: said, RunnerConversation(id: "c", title: "Review oby PR #33 and tell me what it changes…")))
        #expect(ConversationOrder.started(by: "hihi", RunnerConversation(id: "c", title: "Hihi")))
        #expect(!ConversationOrder.started(by: "hihi", RunnerConversation(id: "c", title: "Hi")))
        #expect(!ConversationOrder.started(by: "hihi", RunnerConversation(id: "c", title: "Hihi", deleted: true)))
    }

    /// Words queued offline keep the conversation they were for, across a relaunch.
    @Test func queuedWordsKeepTheirConversation() throws {
        let queued = OfflineMessage(id: "m", said: "and the vault one?", question: nil, option: nil, voice: false, conversation: "c1")
        let read = try JSONDecoder().decode(OfflineMessage.self, from: JSONEncoder().encode(queued))
        #expect(read.conversation == "c1" && read.new == nil)
        let old = try JSONDecoder().decode(OfflineMessage.self, from: Data(#"{"id":"m","said":"hi","voice":false}"#.utf8))
        #expect(old.conversation == nil && old.new == nil)
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
