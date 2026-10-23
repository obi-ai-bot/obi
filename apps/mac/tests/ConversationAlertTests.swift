import Foundation
import Testing
@testable import Oby

/// When the Mac alerts and when it doesn't (#862, #613, the owner's rule of 2026-10-23): what needs
/// the owner, a job they started that ends, Oby's answer away from the window, an outside item that
/// needs them. Never progress, an FYI or what the window shows; gone once it's settled anywhere.
struct ConversationAlertTests {
    let now = Date(timeIntervalSince1970: 1_792_800_000)

    func item(_ id: String, _ kind: InboxItem.Kind, job: String = "", title: String = "Run npm install",
              text: String = "It installs software or reaches the network.\n\nnpm install", options: [String] = ["Allow", "Always allow", "Deny"],
              created: Date? = nil) -> InboxItem {
        InboxItem(id: id, kind: kind, job: job, title: title, text: text, options: options, created: created ?? now.addingTimeInterval(-5))
    }

    /// The conversation's shell asks: one alert, titled as its card, opening that conversation, told once.
    @Test func aShellAskInAConversationAlertsOnce() {
        let ask = item("shell-5b0e2c4d-1111-2222-3333-444455556666-pa1b2c3", .permission)
        #expect(Alerts.alerts(ask, kind: "permission", jobAlerts: false, told: [], now: now))
        #expect(!Alerts.alerts(ask, kind: "permission", jobAlerts: false, told: [ask.id], now: now), "told already")
        let alert = Alerts.alert(for: ask, kind: "permission", conversation: nil)
        #expect(alert.id == ask.id && alert.title == "Run npm install")
        #expect(alert.body.contains("npm install"))
        #expect(alert.info[Alerts.conversationKey] == "5b0e2c4d-1111-2222-3333-444455556666")
        #expect(alert.info[Alerts.inboxKey] == ask.id)
        #expect(alert.thread == "conversation-5b0e2c4d-1111-2222-3333-444455556666")
        #expect(Alerts.place(of: ask, conversation: nil) == .conversation("5b0e2c4d-1111-2222-3333-444455556666"))
    }

    /// A Confirm and a Start alert with their own titles; a teammate's request reading as a Start doesn't.
    @Test func aConfirmAndAStartAlert() {
        let confirm = item("confirm-1", .start, title: "Remember: you like squash merges", text: "Oby will remember it.", options: ["Confirm", "Cancel"])
        #expect(Alerts.alerts(confirm, kind: RunnerConfirm.kind, jobAlerts: false, told: [], now: now))
        #expect(Alerts.alert(for: confirm, kind: RunnerConfirm.kind, conversation: nil).title == "Remember: you like squash merges")
        let start = item("start-1", .start, title: "Greeting fix", text: "Oby looked into it first. Start it?", options: ["Start", "Cancel"])
        #expect(Alerts.alerts(start, kind: "start", jobAlerts: false, told: [], now: now))
        #expect(Alerts.alert(for: start, kind: "start", conversation: "c1").title == "Greeting fix")
        let request = item("obi-1", .start, title: "Bob asks to run a job", text: "x", options: ["Allow", "Decline"])
        #expect(!Alerts.alerts(request, kind: "start", jobAlerts: false, told: [], now: now), "#864's")
        let question = item("supervisor-1", .question, job: "j1", title: "Vault tests stalled", text: "It stopped moving.", options: ["Done"])
        #expect(Alerts.alerts(question, kind: "question", jobAlerts: false, told: [], now: now))
        #expect(!Alerts.alerts(question, kind: "question", jobAlerts: true, told: [], now: now), "its job alerts for it")
    }

    /// A job's own permission alerts as the job, never twice.
    @Test func aJobsOwnPermissionAlertsOnlyAsTheJob() {
        let own = item("j1-permission-p1", .permission, job: "j1")
        #expect(!Alerts.alerts(own, kind: "permission", jobAlerts: false, told: [], now: now))
        for kind in ["failed", "review", "merge", "limit", "audit"] {
            #expect(!Alerts.alerts(item("x", .failed, job: "j1"), kind: kind, jobAlerts: false, told: [], now: now), "\(kind): the job's own alert")
        }
    }

    /// An item from more than an hour ago is a replay, and one put off waits.
    @Test func anItemFromAnHourAgoDoesntAlert() {
        let old = item("shell-c-p1", .permission, created: now.addingTimeInterval(-3700))
        #expect(!Alerts.alerts(old, kind: "permission", jobAlerts: false, told: [], now: now))
        var later = item("shell-c-p2", .permission)
        later.later = now.addingTimeInterval(600)
        #expect(!Alerts.alerts(later, kind: "permission", jobAlerts: false, told: [], now: now))
    }

    /// Answered, done or put off anywhere, an item's alert goes; on reconnecting, those settled meanwhile go.
    @Test func aSettledItemTakesItsAlertAway() {
        let a = item("shell-c-p1", .permission)
        var b = item("confirm-1", .start, options: ["Confirm", "Cancel"])
        var c = item("start-1", .start, options: ["Start", "Cancel"])
        #expect(Alerts.settled(before: [a, b, c], after: [a, b, c], now: now).isEmpty)
        b.done = now
        c.later = now.addingTimeInterval(600)
        #expect(Alerts.settled(before: [a, b, c], after: [a, b, c], now: now) == ["confirm-1", "start-1"])
        #expect(Alerts.settled(before: [a], after: [], now: now) == ["shell-c-p1"], "gone from the list")
        #expect(!Alerts.alerts(b, kind: RunnerConfirm.kind, jobAlerts: false, told: [], now: now))
    }

    /// Only obid's own words reach an alert: what was written is quoted on the item, never shown.
    @Test func aQuotedFieldNeverReachesTheAlert() throws {
        let key = "sk-ant-api03-" + String(repeating: "Q", count: 40)
        let json = #"{"id":"confirm-9","kind":"confirm","job":"","title":"Send an answer: Question from Bob","text":"Oby would answer Bob's question.","options":["Confirm","Cancel"],"created":"2026-10-23T10:00:00Z","done":null,"later":null,"confirm":{"action":"answer_obi","target":"q1","payload":{"words":"hi"}},"obi":{"quoted":{"text":"\#(key)"}},"plugin":{"quoted":{"text":"\#(key)"}},"watch":{"quoted":{"text":"\#(key)"}}}"#
        let parsed = try #require(InboxItem.runner(Data(json.utf8)))
        let alert = Alerts.alert(for: parsed, kind: RunnerConfirm.kind, conversation: nil)
        for shown in [alert.title, alert.subtitle, alert.body] + alert.info.values + alert.options {
            #expect(!shown.contains(key))
        }
        #expect(alert.category.buttons == [Alerts.openButton], "a Confirm only opens its card")
    }

    /// Oby's answer in a conversation the window doesn't show alerts once, with its first lines.
    @Test func anAnswerWhileTheWindowIsClosedAlertsOnce() {
        let turn = Turn(id: "t1", date: now, who: .oby, text: "The vault tests pass on dev.\nTwo were slow.", conversation: "c1")
        #expect(Alerts.answers(turn, extras: TurnExtras(), known: true, told: [], now: now))
        #expect(!Alerts.answers(turn, extras: TurnExtras(), known: true, told: ["t1"], now: now), "a job dispatched from it sends it again")
        let alert = Alerts.answer(turn.text, in: "c1", title: "Vault tests")
        #expect(alert.id == "turn-c1" && alert.title == "Oby answered" && alert.subtitle == "Vault tests")
        #expect(alert.body == "The vault tests pass on dev.\nTwo were slow.")
        #expect(Alerts.lines(String(repeating: "a", count: 500)).count == 200)
    }

    /// What isn't an answer to the owner doesn't alert: their own words, a job's end (its job alerts),
    /// a routine's run starting, a conversation obid doesn't list (the orchestrator's), an old turn.
    @Test func anAnswerTheWindowShowsDoesntAlert() {
        let turn = Turn(id: "t1", date: now, who: .oby, text: "Done.", conversation: "c1")
        #expect(!Alerts.answers(Turn(id: "u1", date: now, who: .user, text: "hi", conversation: "c1"), extras: TurnExtras(), known: true, told: [], now: now))
        #expect(!Alerts.answers(turn, extras: TurnExtras(ended: true), known: true, told: [], now: now))
        #expect(!Alerts.answers(turn, extras: TurnExtras(routine: true), known: true, told: [], now: now))
        #expect(!Alerts.answers(turn, extras: TurnExtras(), known: false, told: [], now: now))
        let old = Turn(id: "t0", date: now.addingTimeInterval(-3600), who: .oby, text: "Done.", conversation: "c1")
        #expect(!Alerts.answers(old, extras: TurnExtras(), known: true, told: [], now: now))
        // The window in front on that conversation shows it already; on another page, or a job's, it doesn't.
        #expect(AlertPlace.shown(.talk, conversation: "c1") == .conversation("c1"))
        #expect(AlertPlace.shown(.talk, conversation: "c2") != .conversation("c1"))
        #expect(AlertPlace.shown(.session(id: "j1"), conversation: "c1") == .job("j1"))
        #expect(AlertPlace.shown(nil, conversation: "c1") == nil)
        // The owner's words in it, from any device, settle its alert.
        #expect(Alerts.settled(by: Turn(id: "u2", date: now, who: .user, text: "thanks", conversation: "c1")) == "turn-c1")
        #expect(Alerts.settled(by: turn) == nil)
    }

    /// A routine's turn is marked as one when obid says so.
    @Test func aRoutinesTurnReadsAsOne() throws {
        let json = #"{"id":"t1","who":"oby","text":"Review PRs started its 09:00 run.","at":"2026-10-23T09:00:00Z","jobs":["j1"],"conversation":"c1","routine":{"id":"r1","name":"Review PRs","outcome":"started","scheduled":"2026-10-23T09:00:00Z","catchUp":false}}"#
        #expect(try Runner.decoder.decode(RunnerTurn.self, from: Data(json.utf8)).extras.routine)
        let plain = #"{"id":"t2","who":"oby","text":"Morning: 2 PRs wait for you.","at":"2026-10-23T09:00:00Z","conversation":"c1"}"#
        #expect(try Runner.decoder.decode(RunnerTurn.self, from: Data(plain.utf8)).extras.routine == false)
    }

    /// An outside item obid sorted as FYI or to ignore never alerts; one that needs you, or isn't sorted yet, does.
    @Test func onlyAnOutsideItemThatNeedsYouAlerts() throws {
        let fresh = WatchNotice(id: "w1", title: "Dmitry on Slack", text: "x", created: now.addingTimeInterval(-60))
        #expect(WatchNotice.shows(fresh, told: [], now: now), "not sorted yet: as before")
        for (triage, shows) in [("needs_you", true), ("fyi", false), ("ignore", false)] {
            var sorted = fresh
            sorted.triage = triage
            #expect(WatchNotice.shows(sorted, told: [], now: now) == shows, "\(triage)")
        }
        let json = #"{"id":"watch-1","kind":"watch","job":"","title":"t","text":"x","options":["Dismiss"],"created":"2026-10-21T15:00:00Z","done":null,"later":null,"triage":"fyi"}"#
        #expect(try Runner.decoder.decode(WatchNotice.self, from: Data(json.utf8)).needsYou == false)
    }

    /// A job the owner started that ends done alerts once with its one-line result (#613); Oby's own
    /// review and a routine's run don't, and a dismissed one's alert goes.
    @Test func aJobDoneWithAPullRequestAlertsOnce() {
        var job = Job(id: "j", request: "Fix the greeting", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-1", base: "dev", pr: nil, kind: .fix, task: "Fix the greeting")
        job.status = .running
        let (_, running) = RunnerFeed.notices([job], after: [:])
        job.status = .done
        job.summary = "Fixed the greeting.\nAlso tidied the tests."
        job.published = "https://github.com/deskree-inc/oby/pull/7"
        #expect(RunnerFeed.notice(for: job) == .done)
        let (changes, seen) = RunnerFeed.notices([job], after: running)
        #expect(changes.count == 1 && changes.first?.1 == .done)
        let alert = Alerts.alert(.done, for: job, conversation: "c1")
        #expect(alert.title == "Done: \(job.heading)" && alert.body == "Fixed the greeting.")
        #expect(alert.thread == "conversation-c1" && alert.category.reply == "Ask for a follow-up…")
        #expect(RunnerFeed.notice(for: job, routine: true) == nil)
        var review = job
        review.reviewOf = "j0"
        #expect(RunnerFeed.notice(for: review) == nil)
        job.dismissed = now
        #expect(RunnerFeed.notices([job], after: seen).changes.first.map { $0.1 == nil } == true)
    }

    /// Following the pull request changes the job again and again: the done alert doesn't come back.
    @Test func followingThePullRequestDoesntAlertAgain() {
        var job = Job(id: "j", request: "Fix", agent: "codex", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-2", base: "dev", pr: nil, kind: .fix, task: "Fix")
        job.status = .done
        job.published = "https://github.com/deskree-inc/oby/pull/8"
        let (_, seen) = RunnerFeed.notices([job], after: [:])
        for step in ["Checks running", "Checks passed", "Review approved", "Merged", "Branch deleted"] {
            job.step = step
            #expect(RunnerFeed.notices([job], after: seen).changes.isEmpty, "\(step)")
        }
    }
}
