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

    /// Answered, done or put off anywhere, an item's alert goes: by its event, and on every full list
    /// (a reconnect, a launch) for the alerts still delivered, from before Oby last quit too.
    @Test func aSettledItemTakesItsAlertAway() {
        var b = item("confirm-1", .start, options: ["Confirm", "Cancel"])
        b.done = now
        #expect(!Alerts.alerts(b, kind: RunnerConfirm.kind, jobAlerts: false, told: [], now: now))
        let delivered = [(id: "shell-c-p1", item: "shell-c-p1"), (id: "confirm-1", item: "confirm-1"), (id: "start-1", item: "start-1")]
        #expect(Alerts.stale(delivered, waiting: ["shell-c-p1"]) == ["confirm-1", "start-1"])
        #expect(Alerts.stale(delivered, waiting: ["shell-c-p1", "confirm-1", "start-1"]).isEmpty)
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
        #expect(Alerts.answers(turn, extras: TurnExtras(), known: true, told: [], asked: nil, now: now))
        #expect(!Alerts.answers(turn, extras: TurnExtras(), known: true, told: ["t1"], asked: nil, now: now), "a job dispatched from it sends it again")
        let alert = Alerts.answer(turn.text, in: "c1", title: "Vault tests")
        #expect(alert.id == "turn-c1" && alert.title == "Oby answered" && alert.subtitle == "Vault tests")
        #expect(alert.body == "The vault tests pass on dev.\nTwo were slow.")
        #expect(Alerts.lines(String(repeating: "a", count: 500)).count == 200)
    }

    /// What isn't an answer to the owner doesn't alert: their own words, a job's end (its job alerts),
    /// a routine's run starting, a conversation obid doesn't list (the orchestrator's), an old turn,
    /// the words beside an ask of the conversation that just alerted.
    @Test func anAnswerTheWindowShowsDoesntAlert() {
        let turn = Turn(id: "t1", date: now, who: .oby, text: "Done.", conversation: "c1")
        #expect(!Alerts.answers(Turn(id: "u1", date: now, who: .user, text: "hi", conversation: "c1"), extras: TurnExtras(), known: true, told: [], asked: nil, now: now))
        #expect(!Alerts.answers(turn, extras: TurnExtras(ended: true), known: true, told: [], asked: nil, now: now))
        #expect(!Alerts.answers(turn, extras: TurnExtras(routine: true), known: true, told: [], asked: nil, now: now))
        #expect(!Alerts.answers(turn, extras: TurnExtras(), known: false, told: [], asked: nil, now: now))
        #expect(!Alerts.answers(turn, extras: TurnExtras(), known: true, told: [], asked: now.addingTimeInterval(-20), now: now), "its Start it? says it")
        #expect(Alerts.answers(turn, extras: TurnExtras(), known: true, told: [], asked: now.addingTimeInterval(-120), now: now))
        let old = Turn(id: "t0", date: now.addingTimeInterval(-3600), who: .oby, text: "Done.", conversation: "c1")
        #expect(!Alerts.answers(old, extras: TurnExtras(), known: true, told: [], asked: nil, now: now))
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

    /// An outside item alerts when obid sorted it as needing you, or doesn't sort (an older obid); never
    /// as FYI, to ignore, while its sort is pending, or for a sort this app doesn't know.
    @Test func onlyAnOutsideItemThatNeedsYouAlerts() throws {
        let fresh = WatchNotice(id: "w1", title: "Dmitry on Slack", text: "x", created: now.addingTimeInterval(-60))
        #expect(WatchNotice.shows(fresh, told: [], now: now), "a runner that doesn't sort: as before")
        for (triage, shows) in [("needs_you", true), ("fyi", false), ("ignore", false), ("pending", false), ("later", false)] {
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

    /// Following the pull request changes the job again and again, and Oby's own rounds after it (a
    /// review, a rebase, a Mac check) put it back to running: Done alerts once. A job that leaves Ready
    /// to publish for done (published elsewhere) only loses that alert.
    @Test func followingThePullRequestDoesntAlertAgain() {
        #expect(RunnerFeed.step(.done, before: nil, active: false, toldDone: false) == .post)
        #expect(RunnerFeed.step(nil, before: "done", active: true, toldDone: true) == .keep, "a round of Oby's own: Done stays")
        #expect(RunnerFeed.step(.done, before: nil, active: false, toldDone: true) == .keep, "ending again says nothing")
        #expect(RunnerFeed.step(.done, before: "ready", active: false, toldDone: false) == .clear, "published elsewhere")
        #expect(RunnerFeed.step(.done, before: "failed", active: false, toldDone: true) == .clear, "its Failed is stale")
        #expect(RunnerFeed.step(nil, before: "done", active: false, toldDone: true) == .clear, "dismissed or archived")
        #expect(RunnerFeed.step(nil, before: "permission:p1", active: true, toldDone: false) == .clear, "answered elsewhere")
        #expect(RunnerFeed.step(.failed, before: "done", active: false, toldDone: true) == .post)

        let (feed, shown, withdrawn) = Self.following()
        var job = Job(id: "j-\(UUID().uuidString)", request: "Fix", agent: "codex", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-2", base: "dev", pr: nil, kind: .fix, task: "Fix")
        job.status = .running
        feed.apply(job)
        job.status = .done
        job.summary = "Fixed it."
        job.published = "https://github.com/deskree-inc/oby/pull/8"
        feed.apply(job)
        #expect(shown.list.map(\.title) == ["Done: \(job.heading)"])
        for status in [Job.Status.running, .done, .running, .done] {
            job.status = status
            job.step = "Oby's review, round 2"
            feed.apply(job)
        }
        #expect(shown.list.count == 1 && !withdrawn.list.contains(job.id))

        var ready = job
        ready.id = "r-\(UUID().uuidString)"
        ready.commits = 2
        ready.published = nil
        feed.apply(ready)
        #expect(shown.list.last?.title.hasPrefix("Ready to publish") == true)
        ready.published = "https://github.com/deskree-inc/oby/pull/9"
        feed.apply(ready)
        #expect(shown.list.count == 2 && withdrawn.list.contains(ready.id), "published on the iPhone: its alert goes, no Done")
    }

    // MARK: The feed

    /// A feed past its first lists, with what it shows and takes away kept here, not in Notification Center.
    static func following(answer: @escaping @Sendable (RunnerStub.Request) -> (Int, String))
        -> (RunnerFeed, Box<Alert>, Box<String>, RunnerStub) {
        let feed = RunnerFeed()
        let stub = RunnerStub(answer: answer)
        let shown = Box<Alert>(), withdrawn = Box<String>()
        feed.show = { shown.list.append($0) }
        feed.withdraw = { withdrawn.list += $0 }
        feed.deliveredInbox = { [] }
        feed.doneDefaults = stub.defaults
        feed.stageAlerts(following: stub.runner)
        return (feed, shown, withdrawn, stub)
    }

    static func following() -> (RunnerFeed, Box<Alert>, Box<String>) {
        let (feed, shown, withdrawn, _) = following(answer: { _ in (500, "{}") })
        return (feed, shown, withdrawn)
    }

    final class Box<T> { var list: [T] = [] }

    /// An ask the window shows waits, untold, and alerts once the window goes; once.
    @Test func whatTheWindowShowsAlertsWhenItGoes() {
        let (feed, shown, withdrawn) = Self.following()
        var showing = true
        feed.windowShows = { showing && $0 == .conversation("c1") }
        feed.apply(item("shell-c1-p1", .permission, created: .now), words: nil)
        #expect(shown.list.isEmpty)
        showing = false
        feed.windowLeft()
        feed.windowLeft()
        #expect(shown.list.map(\.id) == ["shell-c1-p1"])
        // Answered on the iPhone: its alert goes.
        var done = item("shell-c1-p1", .permission, created: .now)
        done.done = .now
        feed.apply(done, words: nil)
        #expect(withdrawn.list == ["shell-c1-p1"])
    }

    /// Oby's answer alerts once; the owner's words anywhere take it away; beside an ask, the ask says it.
    @Test func oneThingOneAlert() {
        let (feed, shown, withdrawn) = Self.following()
        feed.conversations.take([RunnerConversation(id: "c1", title: "Vault tests")])
        let answer = Turn(id: "t-\(UUID().uuidString)", date: .now, who: .oby, text: "The tests pass.", conversation: "c1")
        feed.heard(answer, TurnExtras())
        feed.heard(answer, TurnExtras())
        #expect(shown.list.map(\.id) == ["turn-c1"] && shown.list.first?.subtitle == "Vault tests")
        feed.heard(Turn(date: .now, who: .user, text: "thanks", conversation: "c1"), TurnExtras())
        #expect(withdrawn.list == ["turn-c1"])
        // "It waits for your Start" then its Start it?: the ask takes the answer's place.
        feed.heard(Turn(date: .now, who: .oby, text: "Oby looked into it: it waits for your Start.", conversation: "c1"), TurnExtras())
        feed.apply(item("start-1", .start, title: "Greeting fix", text: "Start it?", options: ["Start", "Cancel"], created: .now),
                   words: InboxWords(conversation: "c1"))
        #expect(shown.list.map(\.id) == ["turn-c1", "turn-c1", "start-1"] && withdrawn.list == ["turn-c1", "turn-c1"])
        // And the other way round: the ask first, Oby's words beside it say nothing more.
        feed.heard(Turn(date: .now, who: .oby, text: "It waits for your Start.", conversation: "c1"), TurnExtras())
        #expect(shown.list.count == 3)
    }

    /// The talk key's words, with the pill up: Oby's answer in their conversation shows in the pill
    /// (workstream V), so it doesn't alert as well; another conversation's does, and so does theirs
    /// once the pill is gone.
    @Test func anAnswerThePillShowsDoesntAlert() {
        let (feed, shown, _) = Self.following()
        feed.conversations.take([RunnerConversation(id: "c1", title: "Vault tests"), RunnerConversation(id: "c2", title: "Deploy")])
        var pill = true
        feed.pillShowsTalk = { pill }
        feed.talking("how are the vault tests ")
        feed.heard(Turn(date: .now, who: .user, text: "how are the vault tests", conversation: "c1"), TurnExtras())
        feed.heard(Turn(id: "t-\(UUID().uuidString)", date: .now, who: .oby, text: "They pass on dev.", conversation: "c1"), TurnExtras())
        #expect(shown.list.isEmpty, "the pill shows it")
        feed.heard(Turn(id: "t-\(UUID().uuidString)", date: .now, who: .oby, text: "Deployed.", conversation: "c2"), TurnExtras())
        #expect(shown.list.map(\.id) == ["turn-c2"], "not the pill's conversation")
        pill = false
        feed.heard(Turn(id: "t-\(UUID().uuidString)", date: .now, who: .oby, text: "Two were slow.", conversation: "c1"), TurnExtras())
        #expect(shown.list.map(\.id) == ["turn-c2", "turn-c1"], "the pill is gone")
    }

    /// Words from an alert go to its conversation; the window's own new conversation isn't touched.
    @Test func wordsFromAnAlertGoToTheirConversation() async throws {
        let (feed, shown, _, stub) = Self.following { request in
            request.path.hasSuffix("/plans")
                ? (200, #"{"kind":"question","said":"Which one?","question":{"text":"Which one?","options":["A","B"]},"conversation":"c2"}"#)
                : (404, "{}")
        }
        feed.conversations.take([RunnerConversation(id: "c1", title: "One"), RunnerConversation(id: "c2", title: "Two")])
        feed.conversations.startNew()
        _ = feed.conversations.target("words typed in the window")
        try await feed.say("the web one", in: "c2")
        let sent = try #require(stub.requests.first { $0.path.hasSuffix("/plans") }?.json)
        #expect(sent["conversation"] as? String == "c2" && sent["said"] as? String == "the web one")
        #expect(feed.conversations.creating && feed.conversations.shown == nil, "the window's new conversation is still its own")
        // Oby asked back: its turn's alert carries the options.
        feed.heard(Turn(date: .now, who: .oby, text: "Which one?", conversation: "c2"), TurnExtras())
        #expect(shown.list.last?.options == ["A", "B"] && shown.list.last?.title == "Oby asks")
    }
}
