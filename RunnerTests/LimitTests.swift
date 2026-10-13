import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

/// An agent stops on its account's usage limit: the account is full until the reset it named, and
/// the job does the round over on the next account with room (case 2.4).
struct LimitMessageTests {
    /// 2026-10-09 21:42:53 UTC.
    let now = Date(timeIntervalSince1970: 1_791_582_173)
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func at(_ hour: Int, _ minute: Int, day: Int = 9) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func limitMessagesAreKnown() {
        for text in ["You've hit your usage limit. Try again at 10:45 PM.", "Claude usage limit reached. Your limit will reset at 3pm (America/Sao_Paulo).",
                     "Rate limit exceeded", "You've hit your limit · resets 10pm"] {
            #expect(Limits.isLimit(text), "\(text)")
        }
        for text in ["Done.", "The limit on rounds is 10.", "Claude Code hit an error."] { #expect(!Limits.isLimit(text), "\(text)") }
    }

    @Test func theResetTimeIsTheNextOneNamed() {
        let reset = { (text: String) in Limits.reset(in: text, now: now, calendar: utc) }
        #expect(reset("You've hit your usage limit. Try again at 10:45 PM.") == at(22, 45))
        #expect(reset("Your limit will reset at 3pm.") == at(15, 0, day: 10))
        #expect(reset("resets 10pm") == at(22, 0))
        #expect(reset("until 22:30") == at(22, 30))
        #expect(reset("Try again at 12:15 AM.") == at(0, 15, day: 10))
        // In the zone it names: 7pm in São Paulo (UTC-3) is 22:00 UTC.
        #expect(reset("Claude usage limit reached. Your limit will reset at 7pm (America/Sao_Paulo).") == at(22, 0))
        #expect(reset("Try again in 2 hours 15 minutes.") == now.addingTimeInterval(2 * 3600 + 15 * 60))
        #expect(reset("try again in 45 min") == now.addingTimeInterval(45 * 60))
        #expect(reset("You've hit your usage limit.") == nil)
        #expect(reset("at 3") == nil)
    }

    @Test func claudeCodeSaysSoInRateLimitEventsAndResults() throws {
        let rejected = try #require(JSONSerialization.jsonObject(with: Data(#"""
            {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1791586200,"rateLimitType":"five_hour",
             "unifiedWindows":{"five_hour":{"utilization":1,"resetsAt":1791586200,"status":"rejected"},"seven_day":{"utilization":0.62,"resetsAt":1792000000}}}}
            """#.utf8)) as? [String: Any])
        #expect(StreamJSON.events(rejected) == [.usage(fiveHour: 1, sevenDay: 0.62, fiveHourResets: Date(timeIntervalSince1970: 1_791_586_200),
                                                     sevenDayResets: Date(timeIntervalSince1970: 1_792_000_000)), .limit(resets: Date(timeIntervalSince1970: 1_791_586_200))])
        let warning = try #require(JSONSerialization.jsonObject(with: Data(#"""
            {"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","unifiedWindows":{"five_hour":{"utilization":0.9},"seven_day":{"utilization":0.3}}}}
            """#.utf8)) as? [String: Any])
        #expect(StreamJSON.events(warning) == [.usage(fiveHour: 0.9, sevenDay: 0.3)])
        let result = try #require(JSONSerialization.jsonObject(with: Data(#"""
            {"type":"result","subtype":"error_during_execution","is_error":true,"result":"Claude usage limit reached. Your limit will reset at 3pm (America/Sao_Paulo)."}
            """#.utf8)) as? [String: Any])
        let events = StreamJSON.events(result)
        #expect(events.count == 1)
        if case let .limit(resets) = events[0] { #expect(resets != nil) } else { Issue.record("not a limit: \(events)") }
        let error = try #require(JSONSerialization.jsonObject(with: Data(#"{"type":"result","subtype":"error","is_error":true,"result":"Something else broke."}"#.utf8)) as? [String: Any])
        #expect(StreamJSON.events(error) == [.finished(summary: "Something else broke.", failed: true)])
    }

    @Test func codexSaysSoWhenItsTurnFails() throws {
        let failed = try #require(JSONSerialization.jsonObject(with: Data(#"""
            {"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"u1","status":"failed","items":[],
             "error":{"message":"You've hit your usage limit. Try again at 10:45 PM."}}}}
            """#.utf8)) as? [String: Any])
        let events = CodexRPC.events(failed)
        #expect(events.count == 1)
        if case let .limit(resets) = events[0] { #expect(resets != nil) } else { Issue.record("not a limit: \(events)") }
        // Said in its last message instead.
        let said = try #require(JSONSerialization.jsonObject(with: Data(#"""
            {"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"u1","status":"failed",
             "items":[{"type":"agentMessage","text":"You've hit your usage limit. Try again at 10:45 PM."}]}}}
            """#.utf8)) as? [String: Any])
        if case .limit = CodexRPC.events(said)[0] {} else { Issue.record("not a limit") }
        // A finished turn that mentions limits is just a turn.
        let done = try #require(JSONSerialization.jsonObject(with: Data(#"""
            {"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"u1","status":"completed",
             "items":[{"type":"agentMessage","text":"Raised the rate limit in the API to 100."}]}}}
            """#.utf8)) as? [String: Any])
        #expect(CodexRPC.events(done) == [.finished(summary: "Raised the rate limit in the API to 100.", failed: false)])
    }

    /// The picker skips a full account until its reset, the same tool first, then another.
    @Test func fullAccountsArentPickedBeforeTheirReset() {
        func state(_ id: String, _ agent: String = "claude", fullUntil: Date? = nil) -> AccountState {
            AccountState(account: Account(id: id, agent: agent, name: id, payer: "", home: nil), label: "Max", fullUntil: fullUntil)
        }
        let reset = now.addingTimeInterval(3600)
        let accounts = [state("a", fullUntil: reset), state("b"), state("c", "codex")]
        #expect(AccountStore.route(accounts, agent: "claude", now: now)?.id == "b")
        #expect(AccountStore.route(accounts, agent: "claude", now: reset)?.id == "a")
        #expect(AccountStore.route([state("a", fullUntil: reset)], agent: "claude", now: now) == nil)
        #expect(AccountStore.next([state("a", fullUntil: reset), state("c", "codex")], agent: "claude", now: now)?.id == "c")
        #expect(AccountStore.next(accounts, agent: "claude", now: now)?.id == "b")
        #expect(AccountStore.next([state("a", fullUntil: reset)], agent: "claude", now: now) == nil)
        #expect(Account(id: "x", agent: "codex", name: "Deskree", payer: "Deskree", home: nil).heading == "Codex · Deskree")
    }
}

@MainActor
struct LimitRetryTests {
    /// An agent whose events the test sends, noting how it was started.
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var prompt = ""
        var killed = 0
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            self.prompt = prompt
            self.onEvent = onEvent
        }
        func send(_ text: String) {}
        func end() {}
        func stop() {}
        func kill() { killed += 1 }
    }

    final class Made { var agents: [(agent: Agent, job: Job, home: URL?, resume: String?)] = [] }

    let folder: URL
    let desk: Desk
    let made = Made()
    let codex: Account
    let resets = Date.now.addingTimeInterval(2 * 3600)

    init() throws {
        folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        codex = try accounts.add(agent: "codex", name: "Deskree", payer: "Deskree")
        accounts.setLabel("Plus · w@example.com", for: codex.id)
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.makeAgent = { [made] job, home, resume in
            let agent = Agent()
            made.agents.append((agent, job, home, resume))
            return agent
        }
        desk.prepare = { $0 }
        desk.countCommits = { _, _ in 1 }
        desk.publishOnItsOwn = { _, _, _ in URL(string: "https://github.com/deskree-inc/oby/pull/80")! }
    }

    /// Signs the default Claude account in as "Personal".
    func personal() {
        desk.accounts.setLabel("Max · well@example.com", for: "default")
    }

    /// Starts a fix job on the Codex account and lets its agent hit the limit.
    func hitLimit(_ id: String, rounds: Int? = nil, resets resets: Date? = nil) async throws -> Agent {
        let resets = resets ?? self.resets
        var fix = job
        fix.id = id
        fix.kind = .fix
        fix.pr = nil
        fix.base = "dev"
        fix.branch = "oby/fix-75"
        fix.account = codex.id
        fix.agent = "codex"
        fix.rounds = rounds
        desk.dispatch(fix)
        for _ in 0..<500 where desk.job(id)?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        let first = try #require(made.agents.first?.agent)
        first.onEvent(.session("thread-1"))
        first.onEvent(.step("Running swift test"))
        first.onEvent(.limit(resets: resets))
        return first
    }

    @Test func theJobGoesOnOnTheNextAccountWithRoom() async throws {
        personal()
        let first = try await hitLimit("moved")
        #expect(first.killed == 1)
        #expect(made.agents.count == 2)
        let (second, moved, home, resume) = try #require(made.agents.last)
        // The same worktree and branch, a new session on Claude Code's default account.
        #expect(moved.id == "moved" && moved.branch == "oby/fix-75" && moved.account == "default" && moved.agent == "claude")
        #expect(moved.session == nil && resume == nil && home == nil)
        #expect(desk.job("moved")?.status == .running)
        #expect(desk.job("moved")?.step == "Codex · Deskree hit its limit; continuing on Claude Code · Default")
        #expect(desk.accounts.state(codex.id)?.fullUntil == resets && desk.accounts.state(codex.id)?.isFull() == true)
        // The new agent gets the task and knows it's taking over.
        #expect(second.prompt.hasPrefix(Prompts.agent(moved)))
        #expect(second.prompt.contains("Codex · Deskree was working on this job and hit its account's usage limit mid-round."))
        // The first agent no longer speaks for the job.
        first.onEvent(.finished(summary: "late", failed: true))
        #expect(desk.job("moved")?.status == .running)

        second.onEvent(.session("e6a24229"))
        second.onEvent(.turnEnded(summary: "fix(engine): dismiss", failed: false))
        second.onEvent(.finished(summary: "fix(engine): dismiss", failed: false))
        for _ in 0..<500 where desk.job("moved")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        let ended = try #require(desk.job("moved"))
        #expect(ended.status == .done && ended.published != nil && ended.session == "e6a24229")
        #expect(ended.summary == "fix(engine): dismiss\n\nCodex · Deskree hit its limit (resets \(Limits.clock(resets))); continued on Claude Code · Default: its usage isn't known yet.")
        #expect(ended.doneLine == "fix(engine): dismiss")
    }

    /// With only one account, a reset a few hours off (#306): the job waits for it, in its worktree.
    @Test func withNoRoomAnywhereANearResetMakesTheJobWaitThenGoOn() async throws {
        let first = try await hitLimit("waits")
        #expect(first.killed == 1 && made.agents.count == 1)
        let parked = try #require(desk.job("waits"))
        #expect(parked.status == .queued && parked.isWaiting && parked.waiting?.kind == .limit)
        #expect(parked.step.hasPrefix("Waiting for an account with room"))
        #expect(!parked.needsYou)
        // The account is back: the job goes on, told it's taking over.
        desk.accounts.markFull(codex.id, until: .now.addingTimeInterval(-1))
        await desk.checkStartWhen()
        for _ in 0..<500 where made.agents.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(made.agents.count == 2)
        let (second, moved, _, _) = try #require(made.agents.last)
        #expect(moved.id == "waits" && moved.branch == "oby/fix-75" && moved.account == codex.id)
        #expect(second.prompt.contains("Codex · Deskree was working on this job and hit its account's usage limit mid-round."))
        #expect(desk.job("waits")?.status == .running && desk.job("waits")?.startWhen == nil)
    }

    /// No reset named and no other account: the assumed hour isn't a reset to wait for.
    @Test func withNoRoomAnywhereAndNoResetNamedTheJobFails() async throws {
        var fix = job
        fix.id = "unnamed"
        fix.account = codex.id
        fix.agent = "codex"
        desk.dispatch(fix)
        for _ in 0..<500 where desk.job("unnamed")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        made.agents.first?.agent.onEvent(.limit(resets: nil))
        let ended = try #require(desk.job("unnamed"))
        #expect(ended.status == .failed && ended.needsYou && made.agents.count == 1)
    }

    @Test func withNoRoomAnywhereAFarResetFailsTheJobSayingWhenTheFirstResets() async throws {
        // Only the Codex account is signed in; its weekly limit is days away.
        let resets = Date.now.addingTimeInterval(3 * 24 * 3600)
        let first = try await hitLimit("stuck", resets: resets)
        #expect(first.killed == 1 && made.agents.count == 1)
        let ended = try #require(desk.job("stuck"))
        #expect(ended.status == .failed && ended.needsYou)
        let clock = Limits.clock(resets)
        #expect(ended.summary == "Codex · Deskree hit its usage limit (resets \(clock)), and no other account has room. The first resets at \(clock).")
        #expect(ended.account == codex.id && ended.agent == "codex")
        #expect(desk.accounts.state(codex.id)?.fullUntil == resets)
        // The picker won't send a new job there before the reset.
        #expect(AccountStore.route(desk.accounts.accounts, agent: nil) == nil)
    }

    /// No reset time named: the account is full for an hour.
    @Test func noTimeNamedMeansAnHour() async throws {
        personal()
        var fix = job
        fix.id = "hour"
        fix.account = codex.id
        fix.agent = "codex"
        desk.dispatch(fix)
        for _ in 0..<500 where desk.job("hour")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        let before = Date.now
        made.agents.first?.agent.onEvent(.limit(resets: nil))
        let until = try #require(desk.accounts.state(codex.id)?.fullUntil)
        #expect(until.timeIntervalSince(before) > 3590 && until.timeIntervalSince(before) < 3700)
        #expect(desk.job("hour")?.agent == "claude")
        // Said without a time.
        made.agents.last?.agent.onEvent(.turnEnded(summary: "Looks good.", failed: false))
        made.agents.last?.agent.onEvent(.finished(summary: "Looks good.", failed: false))
        for _ in 0..<500 where desk.job("hour")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(desk.job("hour")?.summary == "Looks good.\n\nCodex · Deskree hit its limit; continued on Claude Code · Default: its usage isn't known yet.")
    }

    /// A looping job does its round over: the new agent hears the check's output that started it.
    @Test func aLoopingJobDoesItsRoundOver() async throws {
        personal()
        var fix = job
        fix.id = "loop"
        fix.kind = .fix
        fix.pr = nil
        fix.base = "dev"
        fix.account = codex.id
        fix.agent = "codex"
        fix.rounds = 3
        desk.dispatch(fix)
        for _ in 0..<500 where desk.job("loop")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        let first = try #require(made.agents.first?.agent)
        first.onEvent(.turnEnded(summary: "Half done.\n\nGOAL NOT MET: the tests", failed: false))
        for _ in 0..<500 where desk.job("loop")?.currentRound != 2 { try await Task.sleep(for: .milliseconds(10)) }
        first.onEvent(.limit(resets: resets))
        let second = try #require(made.agents.last?.agent)
        #expect(made.agents.count == 2 && desk.job("loop")?.currentRound == 2)
        #expect(second.prompt.contains("What earlier rounds reported, oldest first:\n\n> Half done."))
        #expect(second.prompt.contains("The message that started this round:\n\n> Keep going: the tests"))
    }
}
