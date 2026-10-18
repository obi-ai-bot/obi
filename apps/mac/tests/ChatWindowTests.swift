import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Oby

@Suite(.serialized)
@MainActor
struct ChatWindowTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    private func offscreenWindow<Content: View>(size: NSSize, root: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: root)
        window.orderFront(nil)
        return window
    }

    /// The + button, the microphone and the text share a middle on one line (#322).
    @Test func composerButtonsAreCenteredOnTheFirstLine() {
        let row = ComposerMetrics.rowHeight
        // A button sits `buttonInset` above the row's bottom, the text's line `textInset` above and below.
        let button = row - ComposerMetrics.buttonInset - ComposerMetrics.button / 2
        let text = ComposerMetrics.textInset + ComposerMetrics.lineHeight / 2
        #expect(button == row / 2 && text == row / 2)
        #expect(ComposerMetrics.buttonInset * 2 + ComposerMetrics.button == row)
        #expect(ComposerMetrics.textInset * 2 + ComposerMetrics.lineHeight == row)
    }

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

    @Test func timeLinesIgnoreSenderChangesUntilFifteenMinutesOrMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = Turn(id: "u", date: now, who: .user, text: "Hello")
        let reply = Turn(id: "o", date: now + 5, who: .oby, text: "Hi")
        #expect(ConversationModel.showsTime(first, after: nil, calendar: calendar))
        #expect(!ConversationModel.showsTime(reply, after: first, calendar: calendar))
        var later = reply
        later.date = first.date + 900
        #expect(!ConversationModel.showsTime(later, after: first, calendar: calendar))
        later.date = first.date + 901
        #expect(ConversationModel.showsTime(later, after: first, calendar: calendar))
        var beforeMidnight = first
        beforeMidnight.date = calendar.startOfDay(for: now) + 86_399
        later.date = beforeMidnight.date + 2
        #expect(ConversationModel.showsTime(later, after: beforeMidnight, calendar: calendar))
    }

    @Test func escapeInTheComposerCallsItsStop() throws {
        let editor = ComposerEditor.Editor(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        var exits = 0
        editor.stop = { exits += 1; return true }
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                 isARepeat: false, keyCode: 53))
        editor.keyDown(with: escape)
        #expect(exits == 1)
    }

    @Test func composerEscapeUsesTheSameExitHandlerAsTheWindow() async throws {
        var exits = 0
        let root = ChatComposer(text: .constant(""), focused: .constant(true), tray: Tray(),
                                onSend: {}, onScreenshot: {}, onStop: { exits += 1; return true })
            .onExitCommand { exits += 1 }
        let window = offscreenWindow(size: NSSize(width: 500, height: 100), root: root)
        window.makeKey()
        defer { window.close() }
        for _ in 0..<40 {
            if window.firstResponder is ComposerEditor.Editor { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let editor = try #require(window.firstResponder as? ComposerEditor.Editor)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        // Dispatch through AppKit with this window key, as a real Escape key arrives.
        // The suite is serialized because key-window/input-context state is global.
        window.makeKey()
        NSApp.sendEvent(escape)
        #expect(exits == 1)
    }

    @Test func openingChatFocusesTheComposerAndNewDecisionsLeaveTypingAlone() async throws {
        let feed = RunnerFeed()
        let model = IslandModel(desk: Desk(), feed: feed, availability: MacAvailability())
        let state = ChatState()
        state.open()
        let window = offscreenWindow(size: NSSize(width: 900, height: 600),
                                     root: ChatView(model: model, state: state))
        window.makeKey()
        defer { window.close() }
        for _ in 0..<40 {
            if window.firstResponder is ComposerEditor.Editor { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let editor = try #require(window.firstResponder as? ComposerEditor.Editor)
        editor.string = "fix 2 bugs"
        feed.apply(InboxItem(id: "new", kind: .question, job: "j", title: "Job", text: "Which?", options: ["One", "Two"], created: now))
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder === editor)
        #expect(editor.string == "fix 2 bugs")
        #expect(feed.inbox.first?.done == nil)
        // Every open request includes returning from a search/other control in an existing window.
        let other = NSTextView()
        window.contentView?.addSubview(other)
        window.makeFirstResponder(other)
        state.open()
        for _ in 0..<40 {
            if window.firstResponder === editor { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(window.firstResponder === editor)
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

    @Test func receiptsRequireAnAnswerAndNameThePermissionSubject() {
        var item = InboxItem(id: "d", kind: .question, job: "j", title: "Job", text: "Which?", options: ["A"], created: now)
        item.done = now
        #expect(InlineDecision.receipt(item) == nil)
        item.answer = "   "
        #expect(InlineDecision.receipt(item) == nil)
        var record = RunnerFeed.PermissionRecord(job: "j", permission: RunnerPermission(id: "p", title: "Run tests", detail: "swift test"), created: now)
        record.done = now
        #expect(InlinePermission.receipt(record) == nil)
        record.answer = "Allowed once"
        #expect(InlinePermission.receipt(record)?.hasPrefix("Allowed once: swift test · ") == true)
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

    /// A job waiting for an OK alerts, with Allow and Deny in it, again for each new ask; once
    /// answered, its alert goes (found running two jobs at once on 2026-10-18: nothing said so).
    @Test func aJobWaitingForAnOKAlertsEachTimeItAsks() {
        var job = Job(id: "j", request: "Work", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-1", base: "dev", pr: nil, kind: .fix, task: "Work")
        job.status = .running
        job.permission = Permission(id: "p1", tool: "Bash", title: "Run cargo test", detail: "cargo test")
        #expect(RunnerFeed.notice(for: job) == .permission)
        #expect(RunnerFeed.title(.permission, for: job) == "Needs your OK: \(job.heading)")
        #expect(RunnerFeed.body(.permission, for: job) == "Run cargo test")
        let (first, seen) = RunnerFeed.notices([job], after: [:])
        #expect(first.count == 1)
        #expect(RunnerFeed.notices([job], after: seen).changes.isEmpty)
        job.permission?.id = "p2"
        #expect(RunnerFeed.notices([job], after: seen).changes.count == 1)
        job.permission = nil
        #expect(RunnerFeed.notices([job], after: seen).changes.first.map { $0.1 == nil } == true)
    }

    @Test func publishReviewAndFailedStatusesKeepTheirMeaning() {
        var job = Job(id: "j", request: "Work", agent: "codex", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-270", base: "dev", pr: nil, kind: .fix, task: "Work")
        job.status = .done
        job.commits = 1
        #expect(job.badge == JobBadge(text: "Ready to publish", tone: .orange))
        job.published = "https://github.com/deskree-inc/oby/pull/274"
        job.pullRequest = PullRequestStatus(state: .open, reviewDecision: .waiting, base: "dev", checkedAt: now)
        #expect(job.badge == JobBadge(text: "In review", tone: .blue))
        job.pullRequest?.reviewDecision = .approved
        #expect(job.badge.text == "In review")
        job.pullRequest?.reviewDecision = .changesRequested
        #expect(job.badge == JobBadge(text: "Needs input", tone: .orange))
        job.pullRequest?.state = .merged
        #expect(job.badge.text == "Merged")
        job.status = .failed
        #expect(job.badge == JobBadge(text: "Failed", tone: .red))
    }

    @Test func nativePermissionsNameTheirSubjectAndUseApprovalStatus() {
        let permission = Permission(id: "p", tool: "Bash", title: "Run tests", detail: "swift test")
        var job = Job(id: "j", request: "Work", agent: "codex", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-270", base: "dev", pr: nil, kind: .fix, task: "Work")
        job.status = .running
        job.permission = permission
        #expect(job.badge.text == "Awaiting approval")
        var item = InboxItem(id: "j-permission-p", kind: .permission, job: "j", title: "Job", text: "Run tests", options: ["Allow", "Deny"], created: now)
        item.done = now
        item.answer = "Allow"
        let rendered = RunnerPermission(id: "p", tool: "Bash", title: "Run tests", detail: "swift test")
        #expect(InlineDecision.receipt(item, permission: rendered)?.hasPrefix("Allowed once: swift test · ") == true)
    }

    @Test func statusVocabularyIsShared() {
        var job = Job(id: "j", request: "Work", agent: "codex", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-270", base: "dev", pr: nil, kind: .fix, task: "Work")
        let expected: [(Job.Status, String)] = [(.queued, "Starting"), (.running, "Working"), (.done, "Ready"),
                                              (.failed, "Failed"), (.stopped, "Stopped"), (.interrupted, "Blocked")]
        for (status, text) in expected { job.status = status; #expect(job.badge.text == text) }
        job.status = .running
        job.step = "Waiting for your OK"
        #expect(job.badge.text == "Awaiting approval")
        job.question = Plan.Question(text: "Which?", options: ["A", "B"])
        #expect(job.badge.text == "Needs input")
    }
}
