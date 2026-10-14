import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// A job scheduled to start when something happens (#216, Engine/StartWhen.swift): another job or
/// a pull request finishing, an account's window resetting or its week back on pace, or a time.
/// It waits queued, saying what for, starts by itself once every condition holds, can be started
/// now, moved or cancelled, keeps waiting across a restart, and asks the inbox when a condition
/// can never hold.
@MainActor
struct StartWhenTests {
    /// The time the desk checks conditions at, moved by the tests: 9 AM on Oct 2, 2026 (Gregorian,
    /// whatever calendar the Mac's region uses) in the time zone the tests run in, so a wait an hour
    /// or two later ends that same day and reads as a time ("11:00 AM"), never the next day's weekday
    /// and date, wherever the Mac is.
    final class Clock {
        var now: Date = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9))!
        }()
    }
    /// Pull requests' states as GitHub would answer, by `repo#number`.
    final class GitHub { var states: [String: PullRequestStatus.State] = [:] }
    final class Made { var agents: [(job: Job, prompt: String)] = [] }

    /// An agent that notes its job and prompt, and does nothing until it's stopped.
    final class Agent: AgentRun {
        let job: Job
        let made: Made
        init(_ job: Job, _ made: Made) { (self.job, self.made) = (job, made) }
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws { made.agents.append((job, prompt)) }
        func send(_ text: String) {}
        func end() {}
        func stop() {}
        func kill() {}
    }

    nonisolated static let dev = String(repeating: "a", count: 40)

    let folder: URL
    let clock = Clock()
    let github = GitHub()
    let made = Made()
    let accounts: AccountStore
    let desk: Desk
    /// Codex · Deskree, at 97% of its 5-hour window until it resets in 30 minutes, and 30% into a
    /// week that began half a day ago: 2.1× ahead of pace.
    let codex: Account

    init() throws {
        folder = try temporaryFolder()
        accounts = AccountStore(root: folder)
        accounts.setLabel("Max · well@example.com", for: "default")
        codex = try accounts.add(agent: "codex", name: "Deskree", payer: "Deskree")
        accounts.setLabel("Plus", for: codex.id)
        accounts.record(.usage(fiveHour: 0.97, sevenDay: 0.3, fiveHourResets: clock.now.addingTimeInterval(1800),
                               sevenDayResets: clock.now.addingTimeInterval(6.5 * 86_400)), for: codex.id)
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")),
                    restarts: Restarts(file: folder.appending(path: "restarts.json")))
        set(desk)
    }

    func set(_ desk: Desk) {
        desk.repos = ["deskree-inc/oby"]
        desk.prepare = { job in
            var job = job
            job.startCommit = StartWhenTests.dev
            return job
        }
        desk.fetchBase = { _, _ in StartWhenTests.dev }
        desk.makeAgent = { [made] job, _, _ in Agent(job, made) }
        desk.clock = { [clock] in clock.now }
        desk.pullRequestState = { [github] repo, number in github.states["\(repo)#\(number)"] }
    }

    /// A fix job, on Codex · Deskree when it waits for that account.
    func job(_ id: String, _ startWhen: [StartCondition]? = nil, files: [String]? = nil) -> Job {
        let onCodex = startWhen?.contains { $0.account != nil } == true
        var job = Job(id: id, request: "fix \(id)", agent: onCodex ? "codex" : "claude", account: onCodex ? codex.id : "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-\(id)", base: "dev", pr: nil, kind: .fix, task: "Fix \(id)")
        job.startWhen = startWhen
        job.files = files
        job.created = clock.now
        return job
    }

    /// Dispatches `job` and waits until it's ready: waiting for what it waits for, or running.
    @discardableResult
    func dispatch(_ job: Job, on desk: Desk? = nil) async throws -> Job {
        let desk = desk ?? self.desk
        desk.dispatch(job)
        try await until("\(job.id) is ready") { desk.job(job.id)?.status == .running || desk.scheduled.contains(job.id) }
        return try #require(desk.job(job.id))
    }

    /// A job that ended as `status`, published as pull request `published`, saved where the desk reads it.
    func ended(_ id: String, _ status: Job.Status, published: Int? = nil, title: String) -> Job {
        var other = job(id)
        other.title = title
        other.status = status
        other.finished = clock.now
        other.published = published.map { "https://github.com/deskree-inc/oby/pull/\($0)" }
        other.commits = published == nil ? 0 : 2
        other.pushed = other.commits
        JobStore(url: folder.appending(path: "oby.sqlite")).save(other)
        // On the desk's list, as a job that just ended is: the brain's briefing has it.
        desk.replace(other)
        return other
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    // MARK: Each kind, on its own

    /// Each kind checks itself against what Oby knows: it holds, waits saying what for, or can never hold.
    @Test func eachKindChecksItself() {
        let now = clock.now
        var others: [String: Job] = [:]
        var running = job("running")
        running.title = "Cards screen"
        running.status = .running
        others["running"] = running
        var failed = running
        failed.status = .failed
        others["failed"] = failed
        var published = running
        published.status = .done
        published.published = "https://github.com/deskree-inc/oby/pull/250"
        others["published"] = published
        var states: [String: PullRequestStatus.State] = ["deskree-inc/oby#205": .open, "deskree-inc/oby#206": .closed, "deskree-inc/oby#207": .merged]
        let lookup = StartWhen.Lookup(job: { others[$0] }, account: { self.accounts.state($0) }, pullRequest: { states["\($0)#\($1)"] })
        let mine = job("mine")
        func verdict(_ condition: StartCondition) -> StartWhen.Verdict { StartWhen.verdict(condition, of: mine, now: now, lookup: lookup) }

        #expect(verdict(.job("running", is: .done)) == .waits("for Cards screen to be done"))
        #expect(verdict(.job("running", is: .ended)) == .waits("for Cards screen to end"))
        #expect(verdict(.job("failed", is: .ended)) == .holds)
        #expect(verdict(.job("failed", is: .done)) == .never("Cards screen failed, so it won't be done"))
        #expect(verdict(.job("failed", is: .merged)) == .never("Cards screen failed with nothing published"))
        #expect(verdict(.job("published", is: .published)) == .holds)
        #expect(verdict(.job("published", is: .merged)) == .waits("for Cards screen (#250) to merge"))
        states["deskree-inc/oby#250"] = .merged
        #expect(verdict(.job("published", is: .merged)) == .holds)
        #expect(verdict(.job("gone", is: .done)) == .never("there's no job gone any more"))

        #expect(verdict(.pullRequest(205, is: .merged)) == .waits("for #205 to merge"))
        #expect(verdict(.pullRequest(206, is: .merged)) == .never("#206 was closed without merging"))
        #expect(verdict(.pullRequest(206, is: .closed)) == .holds)
        #expect(verdict(.pullRequest(207, is: .closed)) == .holds)
        #expect(verdict(.pullRequest(208, is: .merged)) == .waits("for #208 to merge"))

        let resets = Limits.clock(now.addingTimeInterval(1800))
        #expect(verdict(.window(account: codex.id, .fiveHour, under: nil)) == .waits("for Codex · Deskree: 5-hour window resets at \(resets)"))
        #expect(verdict(.window(account: codex.id, .fiveHour, under: 0.5)) == .waits("for Codex · Deskree: 5-hour window under 50% (resets at \(resets))"))
        #expect(verdict(.window(account: codex.id, .sevenDay, under: 0.5)) == .holds)
        #expect(verdict(.window(account: "nobody", .fiveHour, under: nil)) == .never("the account it waits on is gone"))
        // 30% used with less than a seventh of the week gone is ahead of pace; the sooner window under 50% holds.
        #expect(verdict(.onPace(account: codex.id)) == .waits("for Codex · Deskree to be back on its weekly pace (2.1× ahead)"))

        #expect(verdict(.at(now.addingTimeInterval(-1))) == .holds)
        #expect(verdict(.at(now.addingTimeInterval(600))) == .waits("until \(Limits.clock(now.addingTimeInterval(600)))"))
    }

    /// A window's usage counts as gone once its reset time passed: usage is reported only during a
    /// job, so the last share would stay. A full account waits for its limit to lift, whatever its usage.
    @Test func aWindowHoldsOnceItResetsOrUnderItsShare() {
        let mine = job("mine")
        let lookup = StartWhen.Lookup(job: { _ in nil }, account: { self.accounts.state($0) }, pullRequest: { _, _ in nil })
        let condition = StartCondition.window(account: codex.id, .fiveHour, under: nil)
        #expect(StartWhen.verdict(condition, of: mine, now: clock.now.addingTimeInterval(1801), lookup: lookup) == .holds)
        accounts.record(.usage(fiveHour: 0.4, sevenDay: nil), for: codex.id)
        #expect(StartWhen.verdict(condition, of: mine, now: clock.now, lookup: lookup) == .holds)
        #expect(StartWhen.verdict(.window(account: codex.id, .fiveHour, under: 0.3), of: mine, now: clock.now, lookup: lookup) != .holds)
        accounts.markFull(codex.id, until: clock.now.addingTimeInterval(600))
        #expect(StartWhen.verdict(condition, of: mine, now: clock.now, lookup: lookup)
                == .waits("for Codex · Deskree: it hit its limit, back at \(Limits.clock(clock.now.addingTimeInterval(600)))"))
        // The week back on pace: once it reset, nothing is used of it.
        #expect(StartWhen.verdict(.onPace(account: codex.id), of: mine, now: clock.now.addingTimeInterval(6.5 * 86_400 + 1), lookup: lookup) == .holds)
    }

    /// The JSON every client sends and reads (docs/runner-api.md): each kind, both ways.
    @Test func conditionsAsJSON() throws {
        let sent = #"""
        [{"job": "ab12cd34", "is": "merged"}, {"pr": 205, "is": "closed"}, {"account": "Deskree", "window": "fiveHour", "under": 0.5},
         {"account": "Deskree", "window": "sevenDay"}, {"account": "Deskree", "onPace": true}, {"at": "2026-10-13T09:00:00-03:00"}, {"job": "ef56"}]
        """#
        let conditions = try JSONDecoder().decode([StartCondition].self, from: Data(sent.utf8))
        #expect(conditions == [.job("ab12cd34", is: .merged), .pullRequest(205, is: .closed), .window(account: "Deskree", .fiveHour, under: 0.5),
                               .window(account: "Deskree", .sevenDay, under: nil), .onPace(account: "Deskree"),
                               .at(Date(timeIntervalSince1970: 1_791_892_800)), .job("ef56", is: .done)])
        let written = String(decoding: try API.encode(conditions), as: UTF8.self)
        #expect(written.contains(#"{"at":"2026-10-13T12:00:00Z"}"#))
        #expect(written.contains(#"{"account":"Deskree","onPace":true}"#))
        #expect(try JSONDecoder().decode([StartCondition].self, from: Data(written.utf8)) == conditions)
        for wrong in [#"[{"account": "Deskree"}]"#, #"[{"at": "tomorrow"}]"#, #"[{"nothing": 1}]"#, #"[{"job": "a", "is": "maybe"}]"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode([StartCondition].self, from: Data(wrong.utf8)) }
        }
    }

    // MARK: Waiting, then starting by itself

    /// "Run #N on Codex when its 5-hour window resets": queued with a visible wait, on Codex, not
    /// counted as running there, and it starts within a check of the reset.
    @Test func onCodexWhenItsFiveHourWindowResets() async throws {
        let waiting = try await dispatch(job("reset", [.window(account: codex.id, .fiveHour, under: nil)]))
        let resets = Limits.clock(clock.now.addingTimeInterval(1800))
        #expect(waiting.status == .queued && waiting.step == "Waiting for Codex · Deskree: 5-hour window resets at \(resets)")
        #expect(accounts.state(codex.id)?.running == 0 && made.agents.isEmpty)
        let json = try JSONSerialization.jsonObject(with: API.encode(JobJSON(job: waiting))) as? [String: Any]
        #expect((json?["waiting"] as? [String: Any])?["text"] as? String == "for Codex · Deskree: 5-hour window resets at \(resets)")
        // As #238 defines `waiting`: an account's room is a `limit`.
        #expect((json?["waiting"] as? [String: Any])?["kind"] as? String == "limit")
        #expect(waiting.waiting == Job.Waiting(kind: .limit, text: "for Codex · Deskree: 5-hour window resets at \(resets)"))
        #expect((json?["startWhen"] as? [[String: Any]])?.first?["window"] as? String == "fiveHour")
        #expect(!Failures.stuckCandidate(waiting))

        await desk.checkStartWhen()
        #expect(desk.job("reset")?.status == .queued)
        clock.now = clock.now.addingTimeInterval(1801)
        await desk.checkStartWhen()
        try await until("it runs") { desk.job("reset")?.status == .running }
        let started = try #require(desk.job("reset"))
        #expect(started.startWhen == nil && started.question == nil && started.waiting == nil)
        #expect(made.agents.map(\.job.id) == ["reset"])
        desk.finish("reset", .stopped, "Stopped by you.")
        #expect(desk.job("reset")?.summary.contains("Started when what it waited for came: Codex · Deskree 5-hour window under 80%.") == true)
    }

    /// "Start #M after job X merges": it waits for X's pull request, read from GitHub every check,
    /// and starts once it's merged.
    @Test func afterAnotherJobMerges() async throws {
        _ = ended("cards", .done, published: 250, title: "Cards screen")
        github.states["deskree-inc/oby#250"] = .open
        let waiting = try await dispatch(job("after", [.job("cards", is: .merged)]))
        await desk.checkStartWhen()
        #expect(desk.job("after")?.step == "Waiting for Cards screen (#250) to merge")
        #expect(desk.job("after")?.status == .queued)
        let json = try JSONSerialization.jsonObject(with: API.encode(JobJSON(job: try #require(desk.job("after"))))) as? [String: Any]
        #expect((json?["waiting"] as? [String: Any])?["job"] as? String == "cards")
        #expect(waiting.status == .queued)

        github.states["deskree-inc/oby#250"] = .merged
        await desk.checkStartWhen()
        try await until("it runs") { desk.job("after")?.status == .running }
    }

    /// A job ending wakes the jobs waiting for it at once, not at their next minute.
    @Test func afterAnotherJobEnds() async throws {
        desk.dispatch(job("first"))
        try await until("the first runs") { desk.job("first")?.status == .running }
        try await dispatch(job("second", [.job("first", is: .ended)]))
        #expect(desk.job("second")?.step == "Waiting for fix first to end")
        desk.stop("first")
        try await until("the second runs") { desk.job("second")?.status == .running }
    }

    /// A pull request and a time together: it starts only once both hold.
    @Test func combinedConditionsWaitForAll() async throws {
        let nine = clock.now.addingTimeInterval(3600)
        try await dispatch(job("both", [.pullRequest(205, is: .merged), .at(nine)]))
        await desk.checkStartWhen()
        #expect(desk.job("both")?.step == "Waiting for #205 to merge, and until \(Limits.clock(nine))")
        #expect(desk.job("both")?.waiting == Job.Waiting(kind: .schedule, text: "for #205 to merge, and until \(Limits.clock(nine))"))
        github.states["deskree-inc/oby#205"] = .merged
        await desk.checkStartWhen()
        #expect(desk.job("both")?.step == "Waiting until \(Limits.clock(nine))" && desk.job("both")?.status == .queued)
        clock.now = nine
        await desk.checkStartWhen()
        try await until("it runs") { desk.job("both")?.status == .running }
    }

    /// A condition that held already when the job got ready doesn't hold it at all.
    @Test func aConditionThatHoldsStartsAtOnce() async throws {
        let started = try await dispatch(job("now", [.at(clock.now.addingTimeInterval(-60))]))
        try await until("it runs") { desk.job("now")?.status == .running }
        #expect(started.id == "now" && desk.job("now")?.startWhen == nil && desk.scheduled.isEmpty)
    }

    // MARK: A condition that can never hold

    /// The job it waits on failed: the inbox asks, Start anyway / Cancel / Wait for something else.
    @Test func aConditionThatCantHoldBecomesAnInboxDecision() async throws {
        _ = ended("broken", .failed, title: "Broken build")
        try await dispatch(job("blocked", [.job("broken", is: .done)]))
        let item = try #require(desk.inbox.first { $0.job == "blocked" && $0.isOpen })
        #expect(item.kind == .question && item.options == [StartWhen.startAnyway, StartWhen.cancel, StartWhen.somethingElse])
        #expect(item.text.contains("Broken build failed, so it won't be done"))
        #expect(desk.job("blocked")?.status == .queued && desk.job("blocked")?.step == "Waiting for you: Broken build failed, so it won't be done.")
        #expect(desk.job("blocked")?.waiting == Job.Waiting(kind: .schedule, text: "for you: Broken build failed, so it won't be done", job: "broken"))

        // Words that aren't a choice are refused; Wait for something else keeps it waiting, unasked.
        #expect(throws: (any Error).self) { try desk.settle(item.id, .answer("maybe later")) }
        try desk.settle(item.id, .answer(StartWhen.somethingElse))
        #expect(desk.inbox.filter { $0.job == "blocked" && $0.isOpen }.isEmpty)
        await desk.checkStartWhen()
        #expect(desk.inbox.filter { $0.job == "blocked" && $0.isOpen }.isEmpty && desk.job("blocked")?.status == .queued)

        // Start anyway, on another job.
        try await dispatch(job("anyway", [.job("broken", is: .done)]))
        let ask = try #require(desk.inbox.first { $0.job == "anyway" && $0.isOpen })
        try desk.settle(ask.id, .answer(StartWhen.startAnyway))
        try await until("it runs") { desk.job("anyway")?.status == .running }

        // Cancel.
        try await dispatch(job("cancelled", [.pullRequest(206, is: .merged)]))
        github.states["deskree-inc/oby#206"] = .closed
        await desk.checkStartWhen()
        let closed = try #require(desk.inbox.first { $0.job == "cancelled" && $0.isOpen })
        #expect(closed.text.contains("#206 was closed without merging"))
        try desk.settle(closed.id, .answer(StartWhen.cancel))
        #expect(desk.job("cancelled")?.status == .stopped)
    }

    // MARK: Start now, move, cancel

    @Test func startNowMoveAndCancel() async throws {
        let later = clock.now.addingTimeInterval(7200)
        try await dispatch(job("early", [.at(later)]))
        try desk.startNow("early")
        try await until("it runs") { desk.job("early")?.status == .running }
        #expect(throws: (any Error).self) { try desk.startNow("early") }

        // Waiting on Codex's room, moved to Claude Code: it runs there now.
        try await dispatch(job("moved", [.window(account: codex.id, .fiveHour, under: nil)]))
        #expect(desk.job("moved")?.account == codex.id)
        let moved = try desk.move("moved", to: MoveTarget(agent: "claude", account: "Default", model: nil))
        #expect(moved.account == "default")
        try await until("it runs") { desk.job("moved")?.status == .running }

        // Moved, still waiting for its time.
        try await dispatch(job("still", [.window(account: codex.id, .fiveHour, under: nil), .at(later)]))
        try desk.move("still", to: MoveTarget(agent: "claude", account: nil, model: nil))
        #expect(desk.job("still")?.startWhen == [.at(later)] && desk.job("still")?.step == "Waiting until \(Limits.clock(later))")

        desk.stop("still")
        #expect(desk.job("still")?.status == .stopped)
        await desk.checkStartWhen()
        #expect(desk.scheduled.isEmpty)
    }

    /// What a waiting job waits for can change; none starts it. An account condition moves it.
    @Test func changingWhatItWaitsFor() async throws {
        try await dispatch(job("change", [.at(clock.now.addingTimeInterval(7200))]))
        let changed = try desk.setStartWhen("change", [.onPace(account: "Deskree")])
        #expect(changed.account == codex.id && changed.agent == "codex" && changed.startWhen == [.onPace(account: codex.id)])
        #expect(changed.step.hasPrefix("Waiting for Codex · Deskree to be back on its weekly pace"))
        #expect(throws: (any Error).self) { try desk.setStartWhen("change", [.job("change", is: .done)]) }
        #expect(throws: (any Error).self) { try desk.setStartWhen("change", [.job("nobody", is: .done)]) }
        #expect(throws: (any Error).self) { try desk.setStartWhen("change", [.onPace(account: "Deskree"), .onPace(account: "default")]) }
        try desk.setStartWhen("change", [])
        try await until("it runs") { desk.job("change")?.status == .running }
        #expect(throws: (any Error).self) { try desk.setStartWhen("change", [.at(clock.now)]) }
    }

    // MARK: Restarts

    /// The runner restarts: the job keeps its wait (and its question), and starts once it comes.
    @Test func aRestartKeepsTheWait() async throws {
        let nine = clock.now.addingTimeInterval(3600)
        try await dispatch(job("kept", [.at(nine)]))
        _ = ended("broken", .failed, title: "Broken build")
        try await dispatch(job("asked", [.job("broken", is: .done)]))
        desk.quit()

        let restarted = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")),
                             restarts: Restarts(file: folder.appending(path: "restarts.json")))
        set(restarted)
        restarted.resumeAfterRestart()
        try await until("both wait again") { restarted.scheduled == ["kept", "asked"] }
        #expect(restarted.job("kept")?.status == .queued && restarted.job("kept")?.step == "Waiting until \(Limits.clock(nine))")
        #expect(restarted.job("asked")?.status == .queued && restarted.job("asked")?.question != nil)
        #expect(restarted.inbox.filter { $0.job == "asked" && $0.isOpen }.count == 1)
        clock.now = nine
        await restarted.checkStartWhen()
        try await until("it runs") { restarted.job("kept")?.status == .running }
    }

    /// What it waits for keeps after a restart that forgot nothing of the account's usage: the
    /// account store keeps it, as Claude Code reports usage only during a job (review of #262).
    @Test func aRestartRemembersTheAccountsUsage() async throws {
        try await dispatch(job("limited", [.window(account: codex.id, .fiveHour, under: nil)]))
        desk.quit()
        let fresh = AccountStore(root: folder)
        #expect(fresh.state(codex.id)?.fiveHour == 0.97)
        fresh.setLabel("Max · well@example.com", for: "default")
        fresh.setLabel("Plus", for: codex.id)
        let restarted = Desk(accounts: fresh, store: JobStore(url: folder.appending(path: "oby.sqlite")),
                             restarts: Restarts(file: folder.appending(path: "restarts.json")))
        set(restarted)
        restarted.resumeAfterRestart()
        try await until("it waits again") { restarted.scheduled.contains("limited") }
        #expect(restarted.job("limited")?.step == "Waiting for Codex · Deskree: 5-hour window resets at \(Limits.clock(clock.now.addingTimeInterval(1800)))")
    }

    /// A job that never ran isn't counted as crashing: any number of restarts leaves it waiting.
    @Test func restartsDontStrandAWaitingJob() async throws {
        try await dispatch(job("patient", [.at(clock.now.addingTimeInterval(3600))]))
        var current = desk
        for _ in 0..<(Restarts.most + 2) {
            current.quit()
            current = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")),
                           restarts: Restarts(file: folder.appending(path: "restarts.json")))
            set(current)
            current.resumeAfterRestart()
            let desk = current
            try await until("it waits again") { desk.scheduled.contains("patient") }
        }
        #expect(current.job("patient")?.status == .queued)
    }

    // MARK: Changes while it gets ready, and moves

    /// Started now, or told to wait, while its worktree gets ready: that holds once it's ready.
    @Test func changesWhileItGetsReadyHold() async throws {
        let ready = MoveJobTests.Gate()
        desk.prepare = { job in
            await ready.wait()
            var job = job
            job.startCommit = StartWhenTests.dev
            return job
        }
        let later = clock.now.addingTimeInterval(3600)
        desk.dispatch(job("early", [.at(later)]))
        desk.dispatch(job("told"))
        try desk.startNow("early")
        try desk.setStartWhen("told", [.at(later)])
        ready.release()
        try await until("the first runs, the second waits") { desk.job("early")?.status == .running && desk.scheduled.contains("told") }
        #expect(desk.job("told")?.status == .queued && desk.job("told")?.step == "Waiting until \(Limits.clock(later))")
    }

    /// A new model on the same account keeps the wait for that account's room.
    @Test func aModelChangeKeepsTheWait() async throws {
        try await dispatch(job("model", [.window(account: codex.id, .fiveHour, under: nil)]))
        let model = try #require(Moves.models["codex"]?.last)
        let moved = try desk.move("model", to: MoveTarget(model: model))
        #expect(moved.account == codex.id && moved.model == model)
        #expect(moved.startWhen == [.window(account: codex.id, .fiveHour, under: nil)])
        #expect(desk.job("model")?.status == .queued && desk.scheduled.contains("model") && made.agents.isEmpty)
    }

    // MARK: File claims

    /// A waiting job keeps its claim from when it was queued: a later job on the same files hears of it.
    @Test func aWaitingJobReservesItsFilesInOrder() async throws {
        try await dispatch(job("first", [.at(clock.now.addingTimeInterval(3600))], files: ["Engine/Desk.swift"]))
        #expect(desk.job("first")?.holdsClaim == true)
        var later = job("later", files: ["Engine/Desk.swift"])
        later.created = clock.now.addingTimeInterval(5)
        desk.dispatch(later)
        try await until("the later one runs") { desk.job("later")?.status == .running }
        let prompt = try #require(made.agents.first { $0.job.id == "later" }?.prompt)
        #expect(prompt.contains("(job first) on the branch oby/fix-first: both touch Engine/Desk.swift"))
    }

    // MARK: The API

    @Test func theAPITakesStartWhen() async throws {
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
        try await app.test(.router) { client in
            func post(_ path: String, _ body: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                try await client.execute(uri: path, method: .post, headers: owner, body: ByteBuffer(string: body)) { response in
                    (response.status, (try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]) ?? [:])
                }
            }
            // A whole job (#269) waiting on an account by name: it runs on it, whatever account it
            // names, and says what it waits for.
            let (status, created) = try await post("/v1/jobs", #"{"job": {"repo": "deskree-inc/oby", "kind": "fix", "task": "Fix #14", "issue": 14, "title": "Login screen", "branch": "oby/fix-14", "account": "default", "startWhen": [{"account": "Deskree", "window": "fiveHour"}]}}"#)
            #expect(status == .created, "\(created)")
            let id = try #require(created["id"] as? String)
            #expect(created["account"] as? String == codex.id && created["agent"] as? String == "codex" && created["branch"] as? String == "oby/fix-14")
            #expect((created["startWhen"] as? [[String: Any]])?.first?["account"] as? String == codex.id)
            try await until("it waits") { desk.scheduled.contains(id) }
            #expect(try await post("/v1/jobs/\(id)/start-when", #"{"startWhen": [{"job": "nobody"}]}"#).0 == .unprocessableContent)
            let (changed, waits) = try await post("/v1/jobs/\(id)/start-when", #"{"startWhen": [{"pr": 205}]}"#)
            #expect(changed == .ok && (waits["waiting"] as? [String: Any])?["text"] as? String == "for #205 to merge")
            #expect(try await post("/v1/jobs/\(id)/start", "").0 == .ok)
            try await until("it runs") { desk.job(id)?.status == .running }
            #expect(try await post("/v1/jobs/\(id)/start", "").0 == .conflict)
            #expect(try await post("/v1/jobs/\(id)/start-when", #"{"startWhen": []}"#).0 == .unprocessableContent)
        }
    }

    // MARK: The brain

    /// "Do this on Codex when it resets", "after the cards job merges": the brain fills start_when,
    /// Swift checks it, and the draft waits for it on the account it names.
    @Test func theBrainFillsStartWhen() async throws {
        _ = ended("cards", .done, published: 250, title: "Cards screen")
        let brain = ConversationTests.FakeBrain([
            #"{"action":"dispatch","reply":"Oby will fix #12 on Codex once it resets.","question":null,"jobs":[],"all":false,"move":null,"dispatches":[{"agent":"auto","account":"auto","repo":"deskree-inc/oby","base_branch":null,"pr":null,"issue":12,"epic":null,"kind":"fix","title":"Login screen","task":"Fix #12","inputs":[],"rounds":1,"check":null,"complexity":"routine","start_when":[{"account":"Deskree","window":"fiveHour","under":null}]}]}"#,
        ])
        desk.makeBrain = { (_: String?, _: String?, _: Vault) in [brain] }
        // The job starts waiting as the plan is made (#269), and the reply says what it waits for.
        guard case .reply(let text) = await desk.plan("fix oby #12 on Codex when it resets") else { Issue.record("no plan"); return }
        #expect(text == "Oby will fix #12 on Codex once it resets.")
        let draft = try #require(desk.jobs.first { $0.issue == 12 })
        #expect(draft.account == codex.id && draft.agent == "codex")
        #expect(draft.startWhen == [.window(account: codex.id, .fiveHour, under: nil)])
        #expect(brain.prompts.last?.contains("Now is ") == true)
        #expect(brain.systems.last?.contains("`start_when`") == true)

        // A job from the briefing, merged; and one the briefing doesn't have, refused.
        let context = desk.brainContext(turns: [])
        #expect(context.movable.contains("cards"))
        let schema = String(decoding: Plan.schema(for: context), as: UTF8.self)
        #expect(schema.contains(#""start_when""#) && schema.contains(#""on_pace""#))
        let merged = try Plan.decode(Data(#"{"action":"dispatch","reply":"","question":null,"jobs":[],"all":false,"move":null,"dispatches":[{"agent":"auto","account":"auto","repo":"deskree-inc/oby","base_branch":null,"pr":null,"issue":13,"epic":null,"kind":"fix","title":"After cards","task":"Fix #13","inputs":[],"rounds":1,"check":null,"complexity":"routine","start_when":[{"job":"cards","is":"merged"},{"at":"2026-10-13T09:00:00Z"},{"account":"Deskree","on_pace":true}]}]}"#.utf8))
        #expect(merged.dispatches.first?.startWhen == [.job("cards", is: .merged), .at(Date(timeIntervalSince1970: 1_791_882_000)), .onPace(account: "Deskree")])
        #expect(merged.problems(in: context, canary: "zz").isEmpty)
        var unknown = merged
        unknown.dispatches[0].startWhen = [.job("nobody", is: .done), .onPace(account: "Nobody")]
        #expect(unknown.problems(in: context, canary: "zz") == ["start_when's job nobody isn't a job in the briefing", "start_when's account Nobody isn't an account"])
    }
}

extension Failures {
    /// Whether the sweep would time the job's step: a job waiting its turn isn't timed.
    nonisolated static func stuckCandidate(_ job: Job) -> Bool { job.isActive && !job.waitsForAnswer && !waitsItsTurn(job) }
}
