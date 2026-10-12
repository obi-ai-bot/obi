import Foundation
import AppKit
import Testing
@testable import Oby

@MainActor
struct ChatWindowTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    @Test func composerGrowsByLineAndCapsAtHalfTheWindow() {
        #expect(ComposerMetrics.height(lines: 1, maximum: 300) == 22)
        #expect(ComposerMetrics.height(lines: 2, maximum: 300) == 44)
        #expect(ComposerMetrics.height(lines: 100, maximum: 300) == 300)
        #expect(ComposerMetrics.height(lines: 1, maximum: 300) < ComposerMetrics.height(lines: 3, maximum: 300))
        #expect(ComposerMetrics.lines("one\ntwo\nthree", width: 500) == 3)
        #expect(ComposerMetrics.lines("one\n", width: 500) == 2)
        #expect(ComposerMetrics.lines("", width: 500) == 1)
    }

    @Test func composerPreservesPastedLinesAndHandlesReturn() throws {
        let editor = ComposerEditor.Editor(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        editor.isRichText = false
        editor.string = "first\nsecond"
        var sends = 0
        editor.send = { sends += 1; editor.string = "" }
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                isARepeat: false, keyCode: 36))
        #expect(editor.string == "first\nsecond")
        editor.keyDown(with: enter)
        #expect(sends == 1 && editor.string.isEmpty)
        #expect(ComposerMetrics.lines(editor.string, width: 500) == 1)
        #expect(ComposerMetrics.lines(String(repeating: "long text ", count: 50), width: 100) > 1)
    }

    @Test func numberReturnAndEscapeUseTheSameDecisionKeyboardPath() {
        let options = CardOption.of(["A", "B", "C", "D"], recommended: 2)
        for index in 0..<4 {
            #expect(DecisionKey.action("\(index + 1)", options: options) == .option(options[index]))
        }
        #expect(DecisionKey.action("return", options: options) == .option(options[0]))
        #expect(DecisionKey.action("return", options: options, words: "  My answer\n") == .words("My answer"))
        #expect(DecisionKey.action("escape", options: options) == .later)
        #expect(DecisionKey.action("1", options: options, busy: true) == .none)
        #expect(DecisionKey.action("return", options: [CardOption(label: "Deny", answer: "deny", recommended: true)]) == .none)
    }

    @Test func decisionsAttachToTheirJobEvenAfterOtherTurns() {
        let turns = [Turn(id: "start", date: now, who: .oby, text: "Starting", jobs: ["job"]),
                     Turn(id: "later", date: now + 60, who: .user, text: "Another question")]
        #expect(ConversationModel.decisionAnchor(job: "job", created: now + 120, turns: turns) == "start")
        #expect(ConversationModel.decisionAnchor(job: "older", created: now + 120, turns: turns) == "later")
        #expect(ConversationModel.decisionAnchor(job: "older", created: now - 60, turns: turns) == nil)
    }

    @Test func confirmedAnswersLeaveTheInboxButStayInTheTranscript() {
        let desk = Desk()
        let feed = RunnerFeed()
        var item = InboxItem(id: "decision", kind: .question, job: "j", title: "Job", text: "Which?",
                             options: ["A", "B"], created: now)
        feed.apply(item)
        #expect(feed.inbox.count == 1 && feed.inboxHistory.isEmpty)
        item.done = now + 10
        item.answer = "B"
        feed.apply(item)
        #expect(feed.inbox.isEmpty && feed.inboxHistory.first?.answer == "B")
        #expect(!IslandInbox.waits(desk: desk, feed: feed, now: now + 20))
        feed.apply(item)
        #expect(feed.inboxHistory.count == 1)
        feed.forget()
        #expect(feed.inboxHistory.isEmpty)
    }

    @Test func receiptsExistOnlyAfterConfirmation() {
        var item = InboxItem(id: "d", kind: .question, job: "j", title: "Job", text: "Which?", options: ["A"], created: now)
        #expect(InlineDecision.receipt(item) == nil)
        item.answer = "A"
        #expect(InlineDecision.receipt(item) == nil)
        item.done = now + 10
        #expect(InlineDecision.receipt(item)?.hasPrefix("You chose: A · ") == true)
    }

    @Test func waitingDecisionsCountAndChooseTheOldestTarget() {
        let desk = Desk()
        let feed = RunnerFeed()
        let first = InboxItem(id: "first", kind: .question, job: "j", title: "Job", text: "Which?", options: ["A"], created: now)
        var second = first
        second.id = "second"
        second.created = now + 60
        feed.apply(second)
        feed.apply(first)
        #expect(IslandInbox.entries(desk: desk, feed: feed, now: now + 120).map(\.id) == ["runner/first", "runner/second"])
        second.later = now + 3600
        feed.apply(second)
        #expect(IslandInbox.entries(desk: desk, feed: feed, now: now + 120).count == 1)
    }

    @Test func returnNeverTakesADestructiveRecommendation() {
        for answer in ["Deny", "Dismiss", "Stop", "Stop job"] {
            #expect(CardOption.defaultOption([CardOption(label: answer, answer: answer, recommended: true)]) == nil)
        }
        let safe = CardOption(label: "Allow once", answer: "allow", recommended: true)
        #expect(CardOption.defaultOption([safe]) == safe)
        #expect(CardOption.defaultOption([CardOption(label: "Remove", answer: "remove", recommended: true, role: .destructive)]) == nil)
        #expect(CardOption.defaultOption([CardOption(label: "Allow", answer: "allow")]) == nil)
    }

    @Test func alwaysAllowRequiresAnExactRule() {
        let missing = RunnerPermission(id: "p", title: "Command", always: "Don't ask again")
        #expect(CardOption.permission(missing).map(\.answer) == ["allow", "deny"])
        let exact = RunnerPermission(id: "p", title: "Command", rule: "Bash(swift test:*)")
        let options = CardOption.permission(exact)
        #expect(options.map(\.answer) == ["allow", "always", "deny"])
        #expect(options[1].detail?.contains("Bash(swift test:*)") == true)
        #expect(options.first?.recommended == true && options.last?.role == .destructive)
    }

    @Test func fourNumberedOptionsKeepTheRecommendationFirst() {
        let options = CardOption.of(["A", "B", "C", "D", "E"], recommended: 3)
        #expect(options.map(\.answer) == ["D", "A", "B", "C"])
        #expect(CardOption.defaultOption(options)?.answer == "D")
    }

    @Test func statusVocabularyIsShared() {
        var job = Job(id: "j", request: "Work", agent: "codex", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-270", base: "dev", pr: nil, kind: .fix, task: "Work")
        let expected: [(Job.Status, String)] = [(.queued, "Waiting"), (.running, "Running"), (.done, "Ready"),
                                              (.failed, "Blocked"), (.stopped, "Stopped"), (.interrupted, "Blocked")]
        for (status, text) in expected { job.status = status; #expect(job.badge.text == text) }
        job.status = .running
        job.step = "Waiting for your OK"
        #expect(job.badge.text == "Awaiting approval")
        job.question = Plan.Question(text: "Which?", options: ["A", "B"])
        #expect(job.badge.text == "Needs input")
    }
}
