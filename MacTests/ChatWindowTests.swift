import Foundation
import Testing
@testable import Oby

@MainActor
struct ChatWindowTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

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
