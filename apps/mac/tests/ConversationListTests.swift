import Foundation
import Testing
@testable import Oby

/// The side panel's conversations (#493, apps/mac/app/ConversationList.swift): obid's list as the
/// runner sends it, its order, search and rows, the one shown, and what happens on a runner that
/// keeps one thread (the Swift runner answers 404): nothing changes.
@MainActor
struct ConversationListTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func convo(_ id: String, _ title: String = "Title", pinned: Bool = false, ago: TimeInterval = 0) -> RunnerConversation {
        RunnerConversation(id: id, title: title, pinned: pinned, created: now - 1000, lastActivity: now - ago, cursor: nil)
    }

    func make(_ conversations: [RunnerConversation]? = nil) -> (ConversationList, ConversationModel) {
        let thread = ConversationModel()
        let list = ConversationList(thread: thread)
        if let conversations { list.take(conversations) }
        return (list, thread)
    }

    // MARK: Decoding

    @Test func aConversationReadsAsTheRunnerSendsIt() throws {
        let wire = #"{"id":"5b0e2c4d-1111-4222-8333-944455556666","title":"Review oby PR #33","pinned":true,"created":"2026-10-16T09:12:00Z","lastActivity":"2026-10-16T09:14:07Z","cursor":"0-42"}"#
        let read = try Runner.decoder.decode(RunnerConversation.self, from: Data(wire.utf8))
        #expect(read.id == "5b0e2c4d-1111-4222-8333-944455556666" && read.title == "Review oby PR #33" && read.pinned && read.cursor == "0-42")
        #expect(read.created == ISO8601DateFormatter().date(from: "2026-10-16T09:12:00Z"))
        #expect(read.lastActivity == ISO8601DateFormatter().date(from: "2026-10-16T09:14:07Z"))
        #expect(read.lastActivity > read.created)
    }

    /// obid orders turns exactly: a time with fractions of a second reads too, and a cursor may be missing.
    @Test func aTimeWithFractionsReads() throws {
        let wire = #"{"id":"a","title":"T","pinned":false,"created":"2026-10-16T09:12:00.250Z","lastActivity":"2026-10-16T09:14:07.5Z"}"#
        let read = try Runner.decoder.decode(RunnerConversation.self, from: Data(wire.utf8))
        #expect(read.lastActivity.timeIntervalSince(read.created) == 127.25 && read.cursor == nil)
        #expect(throws: (any Error).self) {
            try Runner.decoder.decode(RunnerConversation.self, from: Data(#"{"id":"a","title":"T","pinned":false,"created":"yesterday","lastActivity":"today"}"#.utf8))
        }
    }

    @Test func theConversationEventSaysChangedOrGone() throws {
        let changed = #"{"id":"a","title":"T","pinned":false,"created":"2026-10-16T09:12:00Z","lastActivity":"2026-10-16T09:12:00Z","cursor":"1-1"}"#
        var parser = EventParser()
        for line in ["event: conversation", "data: \(changed)"] { #expect(parser.feed(line) == nil) }
        guard case .conversation(.changed(let read))? = parser.feed("") else { Issue.record("not a changed conversation"); return }
        #expect(read.id == "a" && read.title == "T")
        for line in ["event: conversation", #"data: {"id":"a","deleted":true}"#] { #expect(parser.feed(line) == nil) }
        #expect(parser.feed("") == .conversation(.gone("a")))
    }

    /// A turn that names its conversation says which; one from a runner with one thread is as before.
    @Test func aTurnNamesItsConversation() throws {
        var parser = EventParser()
        for line in ["event: turn", #"data: {"id":"t1","who":"user","text":"hi","at":"2026-10-11T09:12:04Z","jobs":[],"conversation":"abc"}"#] { #expect(parser.feed(line) == nil) }
        guard case .turnIn(let turn, let id)? = parser.feed("") else { Issue.record("not a turn in a conversation"); return }
        #expect(turn.id == "t1" && id == "abc")
        for line in ["event: turn", #"data: {"id":"t2","who":"user","text":"hi","at":"2026-10-11T09:12:04Z","jobs":[]}"#] { #expect(parser.feed(line) == nil) }
        guard case .turn(let plain)? = parser.feed("") else { Issue.record("not a turn"); return }
        #expect(plain.id == "t2")
    }

    @Test func aJobNamesTheConversationThatStartedIt() throws {
        let wire = #"[{"id":"j1","conversation":"abc"},{"id":"j2","conversation":null},{"id":"j3"}]"#
        let extras = RunnerJobExtras.of(Data(wire.utf8))
        #expect(extras["j1"]?.conversation == "abc" && extras["j2"]?.conversation == nil && extras["j3"]?.conversation == nil)
    }

    // MARK: The list

    /// Pinned above Recent, each newest first.
    @Test func pinnedComesFirstThenNewestFirst() {
        let all = [convo("old", ago: 900), convo("pin-old", pinned: true, ago: 800), convo("new", ago: 10), convo("pin-new", pinned: true, ago: 20)]
        #expect(ConversationList.ordered(all).map(\.id) == ["pin-new", "pin-old", "new", "old"])
        let sections = ConversationList.sections(all, matching: "")
        #expect(sections.pinned.map(\.id) == ["pin-new", "pin-old"] && sections.recent.map(\.id) == ["new", "old"])
        // Pinning isn't activity: the latest conversation is the one with the latest turn.
        #expect(ConversationList.latest(all)?.id == "new")
        #expect(ConversationList.latest([]) == nil)
    }

    @Test func searchMatchesTitlesInAnyCase() {
        let all = [convo("a", "Vault secrets"), convo("b", "Review PR #33", pinned: true), convo("c", "Watch home")]
        let found = ConversationList.sections(all, matching: " VAULT ")
        #expect(found.pinned.isEmpty && found.recent.map(\.id) == ["a"])
        #expect(ConversationList.sections(all, matching: "pr #").pinned.map(\.id) == ["b"])
        let none = ConversationList.sections(all, matching: "zzz")
        #expect(none.pinned.isEmpty && none.recent.isEmpty)
    }

    @Test func aRowSaysWhenItLastMoved() {
        #expect(ConversationList.ago(now - 5, now: now) == "now" && ConversationList.ago(now + 30, now: now) == "now")
        #expect(ConversationList.ago(now - 5 * 60, now: now) == "5m" && ConversationList.ago(now - 2 * 3600, now: now) == "2h")
        #expect(ConversationList.ago(now - 3 * 86400, now: now) == "3d")
    }

    // MARK: The one shown

    @Test func theLatestConversationIsShownFirst() {
        let (list, _) = make([convo("old", ago: 500), convo("new", ago: 5), convo("pinned", pinned: true, ago: 900)])
        #expect(list.served && list.shown == "new" && !list.starting)
        #expect(list.items.map(\.id) == ["pinned", "new", "old"])
        #expect(list.shownTitle == "Title")
    }

    /// A runner with one thread (the Swift runner answers 404): no list, no ids sent, every turn shown.
    @Test func aRunnerWithOneThreadKeepsTheSingleThread() {
        let (list, thread) = make()
        list.take(nil)
        #expect(!list.served && list.items.isEmpty && list.shown == nil)
        #expect(list.target() == .latest && !list.creating)
        #expect(list.shows("any") && list.shows("other"))
        list.startNew()
        #expect(list.shown == nil && !list.starting && thread.runnerTurns.isEmpty)
        // A list that goes away (another runner) leaves one thread again.
        list.take([convo("a")])
        #expect(list.served)
        list.reset()
        #expect(!list.served && list.target() == .latest)
    }

    @Test func wordsGoToTheConversationShownOrStartOne() {
        let (list, _) = make([convo("a", ago: 10), convo("b", ago: 5)])
        #expect(list.target() == .conversation("b") && !list.creating)
        list.startNew()
        #expect(list.starting && list.shown == nil)
        #expect(list.target() == .new && list.creating)
        // Not a thing yet: the list from a reconnect leaves the new one open.
        list.take([convo("a", ago: 10), convo("b", ago: 5)])
        #expect(list.starting && list.shown == nil)
        list.failed()
        #expect(!list.creating)
    }

    @Test func noConversationsYetStartsTheFirstOne() {
        let (list, _) = make([])
        #expect(list.served && list.shown == nil && list.target() == .new)
    }

    @Test func onlyTheShownConversationsTurnsJoinTheThread() {
        let (list, _) = make([convo("a", ago: 10), convo("b", ago: 5)])
        #expect(list.shows("b") && !list.shows("a"))
        list.startNew()
        #expect(!list.shows("a") && !list.shows("b"))
    }

    @Test func openingOneReadsItsHistory() async {
        final class Reads: @unchecked Sendable { var ids: [String?] = [] }
        let reads = Reads()
        let thread = ConversationModel()
        let list = ConversationList(thread: thread)
        list.take([convo("a", ago: 10), convo("b", ago: 5)])
        thread.page = { _, _ in
            reads.ids.append(list.shown)
            return [Turn(id: "t-\(list.shown ?? "none")", date: .now, who: .user, text: "hi")]
        }
        await list.open("a")
        #expect(list.shown == "a" && !list.starting)
        #expect(reads.ids == ["a"] && thread.runnerTurns.map(\.id) == ["t-a"])
        // The one already shown isn't read again.
        await list.open("a")
        #expect(reads.ids == ["a"])
        // A new one is empty until its first words.
        list.startNew()
        #expect(thread.runnerTurns.isEmpty && list.shownTitle == ConversationList.newTitle)
        // The answer says which conversation the words started: it opens.
        await list.joined("c")
        #expect(list.shown == "c" && !list.starting && !list.creating && thread.runnerTurns.map(\.id) == ["t-c"])
    }

    // MARK: The runner's events

    @Test func eventsKeepTheListCurrent() {
        let (list, thread) = make([convo("a", "First", ago: 10), convo("b", "Second", ago: 5)])
        // Renamed and pinned elsewhere: replaced, and ordered again.
        list.apply(.changed(convo("a", "Renamed", pinned: true, ago: 10)))
        #expect(list.items.map(\.id) == ["a", "b"] && list.items.first?.title == "Renamed")
        // A turn moves a conversation up.
        list.apply(.changed(convo("b", "Second", ago: 0)))
        #expect(list.items.count == 2)
        // A new one from another device is listed, not shown.
        list.apply(.changed(convo("c", "Third", ago: 1)))
        #expect(list.items.count == 3 && list.shown == "b")
        // Gone, but not the one shown.
        list.apply(.gone("c"))
        #expect(list.items.map(\.id) == ["a", "b"] && list.shown == "b")
        // The one shown deleted: a new one is open, and the thread is empty.
        list.apply(.gone("b"))
        #expect(list.shown == nil && list.starting && thread.runnerTurns.isEmpty && list.target() == .new)
    }

    /// The first conversation announced while this window's words start one is theirs: shown at once.
    /// One announced when no words of this window are on their way is only listed.
    @Test func theNewConversationItStartedOpensWithoutWaitingForTheAnswer() async {
        let (list, _) = make([convo("a", ago: 10)])
        list.startNew()
        list.apply(.changed(convo("elsewhere", ago: 1)))
        #expect(list.shown == nil && list.starting && list.items.count == 2)
        #expect(list.target() == .new)
        list.apply(.changed(convo("mine", ago: 0)))
        #expect(list.shown == "mine" && !list.starting && list.shows("mine"))
        // The answer names the same one: nothing more to do. Words to it now join it.
        await list.joined("mine")
        #expect(list.shown == "mine" && !list.creating && list.target() == .conversation("mine"))
    }

    /// The answer comes after the window went to another conversation: it stays where it is.
    @Test func anAnswerDoesNotPullTheWindowAwayFromWhereItWent() async {
        let (list, _) = make([convo("a", ago: 10)])
        list.startNew()
        _ = list.target()
        await list.open("a")
        await list.joined("late")
        #expect(list.shown == "a" && !list.creating)
    }

    @Test func aRunnerWithOneThreadIgnoresConversationEvents() {
        let (list, _) = make()
        list.apply(.changed(convo("a")))
        list.apply(.gone("a"))
        #expect(!list.served && list.items.isEmpty)
    }
}
