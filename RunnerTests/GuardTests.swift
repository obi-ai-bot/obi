import Foundation
import Testing
@testable import ObyEngine

/// Limits in Swift, no-progress stops and test integrity (#64, cases 3.1 and 3.2). One test at a
/// time: each polls the main actor while it waits, and many side by side starve the timing tests
/// in other suites (HaltTests) on a busy machine.
@MainActor
@Suite(.serialized)
struct GuardTests {
    /// An agent whose events the test sends, noting what Oby told it.
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var sent: [String] = []
        var ended = 0
        var stopped = 0
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws { self.onEvent = onEvent }
        func send(_ text: String) { sent.append(text) }
        func end() { ended += 1 }
        func stop() { stopped += 1 }
        func kill() {}
    }

    final class Made { var agents: [Agent] = []; var published = 0; var checks: [TimeInterval] = [] }

    let folder: URL
    let desk: Desk
    let made = Made()

    init() throws {
        folder = try temporaryFolder()
        desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.makeAgent = { [made] _, _, _ in
            let agent = Agent()
            made.agents.append(agent)
            return agent
        }
        desk.prepare = { $0 }
        desk.countCommits = { _, _ in 1 }
        desk.publishOnItsOwn = { [made] _, _, _ in
            made.published += 1
            return URL(string: "https://github.com/deskree-inc/oby/pull/80")!
        }
        desk.integrity = { _ in Integrity.Report() }
        // Git can't read a worktree here: a round that runs out is held, unless a test says otherwise.
        desk.worktreeStatus = { _ in nil }
    }

    /// A fix job with a check and four rounds, started on the default account.
    func start(_ id: String, check: String? = "swift test", rounds: Int? = 4) async throws -> Agent {
        var fix = job
        fix.id = id
        fix.kind = .fix
        fix.pr = nil
        fix.base = "dev"
        fix.branch = "oby/fix-64"
        fix.check = check
        fix.rounds = rounds
        desk.dispatch(fix)
        try await until { desk.job(id)?.status == .running }
        let agent = try #require(made.agents.last)
        agent.onEvent(.session("s-\(id)"))
        return agent
    }

    /// Waits up to 5 seconds for `condition`.
    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    /// Checks that fail with each of `outputs` in turn, noting the timeout they were given.
    func failing(_ outputs: [String]) {
        var left = outputs
        desk.runCheck = { [made] _, command, timeout, _ in
            made.checks.append(timeout)
            guard !left.isEmpty else { return Rounds.Check(command: command, passed: true, output: "ok") }
            return Rounds.Check(command: command, passed: false, output: left.removeFirst())
        }
    }

    /// A job held at a limit: failed with it, its agent stopped, nothing published, and "one more round" offered.
    func expectHeld(_ id: String, _ limit: String, agent: Agent) throws {
        let held = try #require(desk.job(id))
        #expect(held.status == .failed && held.limit == limit)
        #expect(held.summary.hasPrefix("Stopped at a limit: \(limit). The branch is kept and nothing was pushed; one more round is possible."))
        #expect(held.doneLine == "Stopped at a limit: \(held.heading)")
        #expect(held.needsYou && !held.canPublish && held.published == nil && made.published == 0)
        #expect(held.branch == "oby/fix-64")
        #expect(agent.stopped == 1)
    }

    // MARK: Timers

    @Test func aRoundThatRunsPastItsTimerStopsTheJob() async throws {
        desk.limits.round = 0.2
        let agent = try await start("round")
        try await until { desk.job("round")?.isActive == false }
        try expectHeld("round", "the round ran past 0.2 seconds", agent: agent)

        // The inbox offers one more round, which picks the session up, and the limit is gone.
        let item = try #require(desk.inbox.first { $0.job == "round" && $0.isOpen })
        #expect(item.kind == .failed && item.options == [Inbox.oneMoreRound, Inbox.dismiss])
        _ = try desk.settle(item.id, .answer(Inbox.oneMoreRound))
        let again = try #require(desk.job("round"))
        #expect(again.status == .running && again.limit == nil && again.round == 2 && again.rounds == 5)
    }

    @Test func theRoundTimerCoversTheTurnNotTheCheck() async throws {
        desk.limits.round = 0.3
        var first = true
        desk.runCheck = { _, command, _, _ in
            // Longer than a round: the agent's turn has ended, so its timer doesn't count this.
            try? await Task.sleep(for: .milliseconds(500))
            defer { first = false }
            return Rounds.Check(command: command, passed: !first, output: first ? "✘ Test a() failed" : "ok")
        }
        let agent = try await start("turn")
        agent.onEvent(.turnEnded(summary: "Tried.", failed: false))
        try await until { agent.sent.count == 1 }
        #expect(desk.job("turn")?.status == .running && desk.job("turn")?.round == 2)
        // The next round has a timer of its own.
        try await until { desk.job("turn")?.isActive == false }
        try expectHeld("turn", "the round ran past 0.3 seconds", agent: agent)
    }

    // MARK: Apple checks and the round's end (#203)

    @Test func aRoundsClockStandsStillWhileTheAgentWaitsForAnAppleCheck() {
        let start = Date(timeIntervalSince1970: 0)
        let minute: TimeInterval = 60
        var clock = RoundClock(limit: 45 * minute, started: start)
        clock.pause(at: start.addingTimeInterval(10 * minute))
        // Still waiting at minute 15: 10 minutes of the agent's time.
        #expect(clock.used(at: start.addingTimeInterval(15 * minute)) == 10 * minute)
        clock.resume(at: start.addingTimeInterval(19 * minute))
        // A 9-minute wait: at minute 49, the agent's 40th, the round has 5 minutes left.
        let at = start.addingTimeInterval(49 * minute)
        #expect(clock.used(at: at) == 40 * minute)
        #expect(clock.left(at: at) == 5 * minute)
        // However long a wait takes, 40 minutes working and 65 waiting leave the round its 5 minutes.
        clock.pause(at: at)
        let late = at.addingTimeInterval(65 * minute)
        #expect(clock.standing && clock.left(at: late) == 5 * minute)
        clock.resume(at: late)
        #expect(!clock.standing && clock.used(at: late.addingTimeInterval(minute)) == 41 * minute)
    }

    /// Apple checks on: the job's worktree is on `head`.
    func appleChecks(head: String = String(repeating: "a", count: 40)) {
        desk.queuesMacChecks = true
        desk.worktreeHead = { _ in head }
    }

    /// What a Mac reports for an Apple check.
    func appleReport(passed: Bool) -> MacCheck.Report {
        MacCheck.Report(passed: passed, steps: MacCheck.appleSteps.map { MacCheck.Step(name: $0, passed: passed, seconds: 1) },
                        failures: passed ? [] : ["MacTests.JobViewTests/showsActions()"])
    }

    @Test func aRoundDoesntRunOutWhileTheAgentsAppleCheckIsQueuedOrRunning() async throws {
        desk.limits.round = 0.4
        appleChecks()
        let agent = try await start("apple")
        let check = try await desk.askAppleCheck("apple")
        // Queued for a Mac, then on one, for twice the round: the round hasn't run out.
        try await Task.sleep(for: .milliseconds(400))
        #expect(desk.nextAppleCheck(mac: "Mac")?.id == check.id)
        try await Task.sleep(for: .milliseconds(400))
        #expect(desk.job("apple")?.status == .running)
        // The check answers: the round runs on, and runs out.
        _ = try desk.appleCheckEnded(check.id, appleReport(passed: true))
        try await until { desk.job("apple")?.isActive == false }
        try expectHeld("apple", "the round ran past 0.4 seconds", agent: agent)
    }

    @Test func anAgentWaitingForTheAppleCheckItsFinalCheckAskedForStopsTheRoundClock() async throws {
        desk.limits.round = 0.4
        appleChecks()
        // The final check asks for an Apple check of the commit and waits for a Mac.
        desk.runCheck = { [desk] id, command, _, _ in
            _ = try? await desk.askAppleCheck(id, final: true)
            try? await Task.sleep(for: .seconds(10))
            return Rounds.Check(command: command, passed: true, output: "ok")
        }
        let agent = try await start("final")
        agent.onEvent(.turnEnded(summary: "Done.", failed: false))
        try await until { desk.job("final")?.appleCheck?.finalCheck != nil }
        // The user's words start a turn while it runs, and the agent asks for the same commit's check.
        try desk.message("final", "Check the Watch app too.")
        let check = try await desk.askAppleCheck("final")
        #expect(check.finalCheck != nil && check.agentAsked != nil && check.agentWaits)
        try await Task.sleep(for: .milliseconds(800))
        #expect(desk.job("final")?.status == .running)
        // The check answers: the round runs on, and runs out.
        #expect(desk.nextAppleCheck(mac: "Mac")?.id == check.id)
        _ = try desk.appleCheckEnded(check.id, appleReport(passed: true))
        try await until { desk.job("final")?.isActive == false }
        try expectHeld("final", "the round ran past 0.4 seconds", agent: agent)
    }

    @Test func aRoundThatRunsOutAfterItsWorkPassedPublishes() async throws {
        desk.limits.round = 0.2
        appleChecks()
        desk.worktreeStatus = { _ in "" }
        failing([])
        let agent = try await start("passed")
        // The agent's own Apple check passed on its last commit; then its turn runs past the round.
        let check = try await desk.askAppleCheck("passed")
        _ = desk.nextAppleCheck(mac: "Mac")
        _ = try desk.appleCheckEnded(check.id, appleReport(passed: true))
        try await until { desk.job("passed")?.isActive == false }
        let done = try #require(desk.job("passed"))
        #expect(done.status == .done && done.limit == nil)
        #expect(done.summary.hasPrefix("The round ran past 0.2 seconds before Claude Code finished its turn; its work was all committed and passed the check, so Oby publishes it for review."))
        #expect(done.summary.contains("Checked: `swift test` passed."))
        #expect(made.checks.count == 1 && made.published == 1 && agent.stopped == 1)
    }

    @Test func aRoundThatRunsOutWithAFailingCheckIsHeld() async throws {
        desk.limits.round = 0.2
        appleChecks()
        desk.worktreeStatus = { _ in "" }
        failing(["✘ Test a() failed"])
        let agent = try await start("failing")
        try await until { desk.job("failing")?.isActive == false }
        try expectHeld("failing", "the round ran past 0.2 seconds", agent: agent)
        #expect(made.checks.count == 1)
        #expect(desk.job("failing")?.summary.contains("`swift test` fails on its last commit") == true)
    }

    @Test func aRoundThatRunsOutWithWorkUncommittedIsHeldUnchecked() async throws {
        desk.limits.round = 0.2
        appleChecks()
        failing([])
        desk.worktreeStatus = { _ in " M Mac/JobView.swift" }
        let agent = try await start("uncommitted")
        try await until { desk.job("uncommitted")?.isActive == false }
        try expectHeld("uncommitted", "the round ran past 0.2 seconds", agent: agent)
        #expect(desk.job("uncommitted")?.summary.contains("It left work uncommitted.") == true)
        #expect(made.checks.isEmpty)
    }

    @Test func aRoundThatRunsOutAfterItsAppleCheckFailedIsHeldUnchecked() async throws {
        desk.limits.round = 0.2
        appleChecks()
        failing([])
        desk.worktreeStatus = { _ in "" }
        let agent = try await start("apple-failed")
        let check = try await desk.askAppleCheck("apple-failed")
        _ = desk.nextAppleCheck(mac: "Mac")
        _ = try desk.appleCheckEnded(check.id, appleReport(passed: false))
        try await until { desk.job("apple-failed")?.isActive == false }
        try expectHeld("apple-failed", "the round ran past 0.2 seconds", agent: agent)
        #expect(desk.job("apple-failed")?.summary.contains("Its Apple check of the last commit failed.") == true)
        #expect(made.checks.isEmpty)
    }

    @Test func aJobThatRunsPastItsCapStops() async throws {
        desk.limits.job = 0.5
        // A check slower than the cap: the cap covers checks too, unlike the round's timer.
        desk.runCheck = { _, command, _, _ in
            try? await Task.sleep(for: .seconds(10))
            return Rounds.Check(command: command, passed: false, output: "✘ Test a() failed")
        }
        let agent = try await start("cap", rounds: 10)
        agent.onEvent(.turnEnded(summary: "Round 1.", failed: false))
        try await until { desk.job("cap")?.isActive == false }
        try expectHeld("cap", "the job ran past 0.5 seconds", agent: agent)
        #expect(desk.job("cap")?.summary.hasSuffix("Round 1.") == true)
    }

    @Test func outOfRoundsIsALimitToo() async throws {
        failing(["✘ Test a() failed", "✘ Test b() failed"])
        let agent = try await start("rounds", rounds: 2)
        agent.onEvent(.turnEnded(summary: "One.", failed: false))
        try await until { agent.sent.count == 1 }
        agent.onEvent(.turnEnded(summary: "Two.", failed: false))
        try await until { desk.job("rounds")?.isActive == false }
        try expectHeld("rounds", "`swift test` still fails after 2 rounds", agent: agent)
    }

    // MARK: Test runs and turns

    @Test func theCheckGetsTheTestRunTimeout() async throws {
        desk.limits.testRun = 42
        failing([])
        let agent = try await start("timeout")
        agent.onEvent(.turnEnded(summary: "Done.", failed: false))
        try await until { made.checks.count == 1 }
        #expect(made.checks == [42])
    }

    @Test func aTestRunPastItsTimeoutIsEndedAndFails() async throws {
        let started = Date.now
        // Long enough for the shell to print before it's ended, even on a busy machine.
        let check = await Rounds.run("echo started; sleep 30", in: folder, timeout: 3, env: [:], boxed: false)
        #expect(Date.now.timeIntervalSince(started) < 15)
        #expect(!check.passed && !check.succeeded)
        #expect(check.output.hasPrefix("started\n"))
        #expect(check.output.hasSuffix("Oby stopped it after 3 seconds, the most a test run may take."))
        let quick = await Rounds.run("echo fine", in: folder, timeout: 5, env: [:], boxed: false)
        #expect(quick.passed && quick.output == "fine\n")
    }

    @Test func aTestRunStoppedAtItsLimitNamesTheLastTestThatStarted() async {
        let script = "echo '◇ Test quick() started.'; echo '◇ Test hangs() started.'; echo '✔ Test quick() passed after 0.001 seconds.'; sleep 30"
        let check = await Rounds.run(script, in: folder, timeout: 3, env: [:], boxed: false)
        #expect(!check.passed && check.output.hasPrefix("◇ Test quick() started.\n"))
        #expect(check.output.hasSuffix("Oby stopped it after 3 seconds, the most a test run may take. The last test that started: hangs()."))
    }

    @Test func claudeCodeGetsMaxTurns() throws {
        let launch = try ClaudeAgent.launch(worktree: folder, configDirectory: nil, model: "claude-opus-5-5", resume: "s1", maxTurns: JobLimits().maxTurns)
        let at = launch.arguments.firstIndex(of: "--max-turns")
        #expect(at.map { launch.arguments[$0 + 1] } == "200")
        #expect(try !ClaudeAgent.launch(worktree: folder, configDirectory: nil, model: nil, resume: nil).arguments.contains("--max-turns"))
        let result: [String: Any] = ["type": "result", "subtype": "error_max_turns", "is_error": false, "num_turns": 200]
        #expect(StreamJSON.events(result) == [.maxTurns])
    }

    @Test func usingEveryTurnStopsTheJob() async throws {
        let agent = try await start("turns")
        agent.onEvent(.maxTurns)
        try await until { desk.job("turns")?.isActive == false }
        try expectHeld("turns", "Claude Code used its 200 turns in one round", agent: agent)
    }

    // MARK: No progress

    @Test func theSameFailureTwiceInARowStops() async throws {
        failing([
            "[2026-10-10T12:00:01Z] Building\n✘ Test aTest() failed after 0.012 seconds with 1 issue.\nTest run with 40 tests failed after 3.2 seconds.",
            "[2026-10-10T12:04:09Z] Building\n✘ Test aTest() failed after 0.019 seconds with 1 issue.\nTest run with 40 tests failed after 2.9 seconds.",
        ])
        let agent = try await start("same")
        agent.onEvent(.turnEnded(summary: "Fixed it, I think.", failed: false))
        try await until { agent.sent.count == 1 }
        #expect(agent.sent[0].contains("Oby ran `swift test` and it failed:"))
        agent.onEvent(.turnEnded(summary: "Fixed it for real.", failed: false))
        try await until { desk.job("same")?.isActive == false }
        try expectHeld("same", "the same failure twice in a row", agent: agent)
        #expect(desk.job("same")?.round == 2 && desk.job("same")?.summary.hasSuffix("Fixed it for real.") == true)
    }

    @Test func fingerprintsIgnoreTimesButNotWhichTestsFail() {
        let check = { (output: String) in Rounds.Check(command: "swift test", passed: false, output: output) }
        let a = check("12:00:01.250 ✘ Test aTest() failed after 0.012 seconds\nat 0x7ffee4b1c8a0 in job 3f2a9c1e7b\nTest run with 40 tests failed after 3.2 seconds.")
        let b = check("12:07:44.031 ✘ Test aTest() failed after 0.4 seconds\nat 0x10003c2d0 in job 9e8d7c6b5a\nTest run with 40 tests failed after 31 ms.")
        let other = check("12:07:44.031 ✘ Test bTest() failed after 0.4 seconds\nat 0x10003c2d0 in job 9e8d7c6b5a\nTest run with 40 tests failed after 31 ms.")
        #expect(Fingerprint.of(a) == Fingerprint.of(b))
        #expect(Fingerprint.of(a) != Fingerprint.of(other))
        #expect(Fingerprint.failingTests("Test Case '-[RunnerTests.A testB]' failed (0.1 seconds)\nFAILED tests/test_x.py::test_y - assert 1\n--- FAIL: TestZ (0.00s)\ntest m::n ... FAILED\n  ✕ adds (3 ms)")
                == ["-[RunnerTests.A testB]", "TestZ", "adds", "m::n", "tests/test_x.py::test_y"])
        #expect(Fingerprint.normalized(String(repeating: "line\n", count: 30) + "last").count == Fingerprint.tail)
    }

    @Test func threeDeniedActionsInARowStop() async throws {
        let agent = try await start("denied")
        agent.onEvent(.permission(denied: "Stay inside this job's worktree."))
        agent.onEvent(.permission(denied: "Stay inside this job's worktree."))
        // An allowed action starts the count over.
        agent.onEvent(.permission(denied: nil))
        agent.onEvent(.permission(denied: "Oby publishes the job's branch itself."))
        agent.onEvent(.permission(denied: "Oby publishes the job's branch itself."))
        #expect(desk.job("denied")?.status == .running)
        agent.onEvent(.permission(denied: "Oby publishes the job's branch itself."))
        try expectHeld("denied", "3 actions in a row were denied", agent: agent)
        #expect(desk.job("denied")?.summary.hasSuffix("The last one: Oby publishes the job's branch itself.") == true)
    }

    @Test func stoppingAJobEndsItsCheck() async throws {
        var ended: Date?
        desk.runCheck = { [folder] _, command, _, _ in
            let check = await Rounds.run("sleep 30", in: folder, timeout: 60, env: [:], boxed: false)
            ended = .now
            return check
        }
        let agent = try await start("stopcheck")
        agent.onEvent(.turnEnded(summary: "Done.", failed: false))
        try await until { desk.job("stopcheck")?.phase == .check }
        try await Task.sleep(for: .milliseconds(200))
        let stopped = Date.now
        desk.stop("stopcheck")
        try await until { ended != nil }
        #expect(ended.map { $0.timeIntervalSince(stopped) < 5 } == true)
        #expect(desk.job("stopcheck")?.status == .stopped)
    }

    // MARK: Test integrity

    @Test func aRoundThatWeakensTheTestsFailsEvenWhenTheCheckPasses() async throws {
        failing([])
        var weakened = true
        desk.integrity = { _ in
            weakened ? Integrity.Report(problems: ["deletes the test file RunnerTests/StopTests.swift"])
                : Integrity.Report(notes: ["edits existing tests in RunnerTests/TitleTests.swift"])
        }
        let agent = try await start("weak", rounds: 3)
        agent.onEvent(.turnEnded(summary: "Green now.", failed: false))
        try await until { agent.sent.count == 1 }
        #expect(agent.sent[0].contains("this work weakens them:\n\n- deletes the test file RunnerTests/StopTests.swift"))
        #expect(!agent.sent[0].contains("it failed"))
        #expect(desk.job("weak")?.status == .running && desk.job("weak")?.round == 2)
        weakened = false
        agent.onEvent(.turnEnded(summary: "Put the tests back.", failed: false))
        try await until { desk.job("weak")?.isActive == false }
        let done = try #require(desk.job("weak"))
        #expect(done.status == .done && done.limit == nil && made.published == 1)
        // An edit that doesn't weaken the tests passes, and the summary says it for review.
        #expect(done.summary.hasSuffix("Checked: `swift test` passed.\n\nChanged in the existing tests, for review:\n- edits existing tests in RunnerTests/TitleTests.swift"))
    }

    @Test func weakenedTestsOnTheLastRoundHoldTheJob() async throws {
        failing([])
        desk.integrity = { _ in Integrity.Report(problems: ["adds a skip marker in RunnerTests/StopTests.swift: @Test(.disabled())"]) }
        let agent = try await start("weaklast", rounds: 1)
        agent.onEvent(.turnEnded(summary: "Green now.", failed: false))
        try await until { desk.job("weaklast")?.isActive == false }
        try expectHeld("weaklast", "the tests are still weakened after 1 round", agent: agent)
        let heldSummary = try #require(desk.job("weaklast")?.summary)
        #expect(heldSummary.contains("Test integrity findings:\n- adds a"))
        #expect(heldSummary.contains("RunnerTests/StopTests.swift") && heldSummary.contains("@Test("))
    }

    @Test func theDiffFindsWhatWeakensTheTests() {
        let diff = """
            diff --git a/RunnerTests/StopTests.swift b/RunnerTests/StopTests.swift
            deleted file mode 100644
            index 1111111..0000000
            --- a/RunnerTests/StopTests.swift
            +++ /dev/null
            @@ -1,3 +0,0 @@
            -struct StopTests {
            -    @Test func stops() {}
            -}
            diff --git a/RunnerTests/LeadTests.swift b/RunnerTests/LeadTests.swift
            index 2222222..3333333 100644
            --- a/RunnerTests/LeadTests.swift
            +++ b/RunnerTests/LeadTests.swift
            @@ -10 +10 @@
            -    @Test func leads() {
            +    @Test(.enabled(if: bubblewrapRuns)) func leads() {
            @@ -12,2 +12 @@
            -        #expect(lead.ok)
            -        #expect(lead.jobs.count == 2)
            +        #expect(lead.ok)
            diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
            index 4444444..5555555 100644
            --- a/.github/workflows/ci.yml
            +++ b/.github/workflows/ci.yml
            @@ -3 +3 @@
            -  run: swift test
            +  run: swift build
            diff --git a/Package.swift b/Package.swift
            index 8888888..9999999 100644
            --- a/Package.swift
            +++ b/Package.swift
            @@ -20 +19,0 @@
            -        .testTarget(name: "RunnerTests", dependencies: ["oby-runner"]),
            diff --git a/Engine/Desk.swift b/Engine/Desk.swift
            index 6666666..7777777 100644
            --- a/Engine/Desk.swift
            +++ b/Engine/Desk.swift
            @@ -1 +1 @@
            -let a = 1
            +let a = 2
            """
        let changes = Integrity.changes(diff)
        #expect(changes.map(\.old) == ["RunnerTests/StopTests.swift", "RunnerTests/LeadTests.swift", ".github/workflows/ci.yml", "Package.swift", "Engine/Desk.swift"])
        #expect(changes.map(\.new) == [nil, "RunnerTests/LeadTests.swift", ".github/workflows/ci.yml", "Package.swift", "Engine/Desk.swift"])
        #expect(Integrity.report(changes) == Integrity.Report(problems: [
            "deletes the test file RunnerTests/StopTests.swift",
            "removes 1 assertion from RunnerTests/LeadTests.swift",
            "adds a skip marker in RunnerTests/LeadTests.swift: @Test(.enabled(if: bubblewrapRuns)) func leads() {",
            "changes test or CI config: .github/workflows/ci.yml",
            "changes the test settings in Package.swift: .testTarget(name: \"RunnerTests\", dependencies: [\"oby-runner\"]),",
            "lowers the test count by 1",
        ]))
    }

    @Test func editsThatDontWeakenTheTestsAreOnlyFlagged() {
        // This pull request's own edit: an expectation changed, not removed.
        let edited = Integrity.Change(old: "RunnerTests/TitleTests.swift", new: "RunnerTests/TitleTests.swift",
                                      added: ["        #expect(decoded.count == 42)"], removed: ["        #expect(decoded.count == 41)"])
        let moved = Integrity.Change(old: "RunnerTests/StopTests.swift", new: "RunnerTests/Jobs/StopTests.swift")
        let away = Integrity.Change(old: "tests/test_cart.py", new: "scripts/cart_check.py")
        let script = Integrity.Change(old: "web/package.json", new: "web/package.json",
                                      added: [#"    "test": "echo ok","#], removed: [#"    "test": "vitest run","#])
        let target = Integrity.Change(old: "Package.swift", new: "Package.swift", added: [#"        .testTarget(name: "GuardTests"),"#])
        #expect(Integrity.report([edited, moved, away, script, target]) == Integrity.Report(
            problems: ["moves the test file tests/test_cart.py out of the tests, to scripts/cart_check.py",
                       #"changes the test settings in web/package.json: "test": "echo ok","#],
            notes: ["edits existing tests in RunnerTests/TitleTests.swift", "moves the test file RunnerTests/StopTests.swift to RunnerTests/Jobs/StopTests.swift"]))
    }

    @Test func newTestsAreFine() {
        let added = Integrity.Change(old: "RunnerTests/LeadTests.swift", new: "RunnerTests/LeadTests.swift",
                                     added: ["", "    @Test func aNewOne() {", "        #expect(true)", "    }"])
        let file = Integrity.Change(old: nil, new: "web/src/cart.test.ts", added: ["it('adds', () => {})", "test('removes', () => {})"])
        let code = Integrity.Change(old: "Engine/Desk.swift", new: "Engine/Desk.swift", added: ["it.skip"], removed: ["func test() {}"])
        #expect(Integrity.report([added, file, code]) == Integrity.Report())
        for path in ["RunnerTests/A.swift", "tests/test_cart.py", "pkg/cart_test.go", "src/__tests__/x.js", "Sources/CartTests.swift", "web/a.spec.tsx"] {
            #expect(Integrity.isTest(path), "\(path)")
        }
        for path in ["Engine/Desk.swift", "docs/testing.md", "Contest/A.swift", "src/latest.ts"] { #expect(!Integrity.isTest(path), "\(path)") }
        for line in ["it.skip('x', () => {})", "    @pytest.mark.skip(reason='flaky')", "t.Skip(\"later\")", "#[ignore]", "throw XCTSkip(\"no\")",
                     "describe.only('cart', () => {", "@Test(.disabled(\"flaky\"))", "withKnownIssue {"] {
            #expect(line.contains(Integrity.skip), "\(line)")
        }
        for line in ["#expect(a)", "try #require(b)", "XCTAssertEqual(a, b)", "expect(cart).toEqual([])", "assert total == 3", "t.Fatalf(\"no\")"] {
            #expect(line.contains(Integrity.assertion), "\(line)")
        }
    }

    @Test func integrityComparesWithTheCommitObyRecorded() {
        var work = job
        work.pr = nil
        work.base = "dev"
        #expect(Integrity.ref(work) == "refs/remotes/origin/dev")
        work.pr = 33
        #expect(Integrity.ref(work) == "refs/oby/pr-33")
        work.startCommit = "1eb426a0c3"
        #expect(Integrity.ref(work) == "1eb426a0c3")
    }

    // MARK: From the second review

    @Test func commentedOutOrAlwaysTrueAssertionsDontCount() {
        let removed = ["        #expect(cart.total == 3)", "        XCTAssertEqual(total, 3)", "    assert total == 3", "        expect(cart).toEqual([])"]
        for added in [["        // #expect(cart.total == 3)"], ["        #expect(true)"], ["        /* XCTAssertEqual(total, 3) */"], ["    # assert total == 3"],
                      ["        XCTAssertTrue(true)"], ["    assert True"], ["        expect(true).toBe(true)"]] {
            let change = Integrity.Change(old: "Tests/CartTests.swift", new: "Tests/CartTests.swift", added: added, removed: [removed[0]])
            #expect(Integrity.report([change]).problems == ["removes 1 assertion from Tests/CartTests.swift"], "\(added)")
        }
        for line in removed { #expect(Integrity.asserts(line), "\(line)") }
        // A changed expectation is an edit, not a weaker test.
        let edited = Integrity.Change(old: "Tests/CartTests.swift", new: "Tests/CartTests.swift", added: ["        #expect(cart.total == 4)"], removed: [removed[0]])
        #expect(Integrity.report([edited]) == Integrity.Report(notes: ["edits existing tests in Tests/CartTests.swift"]))
    }

    @Test func failingIdsComeFromAllOfTheOutput() async throws {
        let filler = String(repeating: "x", count: 5000)
        let first = await Rounds.run("echo '✘ Test aTest() failed'; echo \(filler); exit 1", in: folder, timeout: 10, env: [:], boxed: false)
        let second = await Rounds.run("echo '✘ Test bTest() failed'; echo \(filler); exit 1", in: folder, timeout: 10, env: [:], boxed: false)
        #expect(first.output.count == 4000 && !first.output.contains("aTest"))
        #expect(first.failing == ["aTest()"] && second.failing == ["bTest()"])
        #expect(Fingerprint.of(first) != Fingerprint.of(second))
    }

    /// #185: the end of `swift test`'s output was all passing tests, the summary and build warnings,
    /// so the next round never heard which tests failed and ran out of time looking.
    @Test func theNextRoundNamesTheFailingTestsTheOutputsEndLeftOut() async throws {
        let printed = ["✘ Test aRace() recorded an issue at RunnerTests.swift:12:9: Expectation failed: done",
                       "✘ Test aRace() failed after 0.3 seconds with 1 issue."]
            + (1...200).map { "✔ Test passing\($0)() passed after 0.001 seconds." }
            + ["✘ Test run with 457 tests in 57 suites failed after 49.639 seconds with 2 issues."]
        try printed.joined(separator: "\n").write(to: folder.appending(path: "printed.txt"), atomically: true, encoding: .utf8)
        let check = await Rounds.run("cat printed.txt; echo 'warning: found 1 file(s) which are unhandled' >&2; exit 1",
                                     in: folder, timeout: 10, env: [:], boxed: false)
        #expect(!check.output.contains("aRace") && check.failing == ["aRace()"])
        var fix = job
        fix.check = "swift test"
        fix.rounds = 4
        var message = ""
        if case let .again(said) = Rounds.next(fix, summary: "swift test passes.", failed: false, check: check) { message = said }
        #expect(message.contains("The tests that failed, from all of what it printed (its end above may not show them):\n\n```\n"
                                 + "aRace(): RunnerTests.swift:12:9: Expectation failed: done\n```"))
        #expect(MacCheck.failures(in: "✘ Test aRace() failed after 0.3 seconds with 1 issue.\n✘ Test run with 457 tests in 57 suites failed after 49.639 seconds with 2 issues.") == ["aRace()"])
    }

    @Test func wordsSentWhileTheCheckRunsStartATimedTurn() async throws {
        desk.limits.round = 0.3
        desk.runCheck = { _, command, _, _ in
            try? await Task.sleep(for: .seconds(3))
            return Rounds.Check(command: command, passed: true, output: "ok")
        }
        let agent = try await start("words")
        agent.onEvent(.turnEnded(summary: "Done.", failed: false))
        try await until { desk.job("words")?.phase == .check }
        try desk.message("words", "Also rename the test.")
        #expect(agent.sent == ["Also rename the test."])
        try await until { desk.job("words")?.isActive == false }
        try expectHeld("words", "the round ran past 0.3 seconds", agent: agent)
    }

    // MARK: From the third review

    @Test func linesThatTurnExistingTestsOffFail() {
        for line in ["        return", "    /* @Test func one() {", "#if false", "#if 0", "        if (false) {", "    if False:"] {
            let change = Integrity.Change(old: "Tests/CartTests.swift", new: "Tests/CartTests.swift", added: [line])
            #expect(Integrity.report([change]).problems == ["adds a line that turns tests off in Tests/CartTests.swift: \(line.trimmingCharacters(in: .whitespaces))"], "\(line)")
        }
        let fine = Integrity.Change(old: "Tests/CartTests.swift", new: "Tests/CartTests.swift",
                                    added: ["        guard let cart else { return }", "        /* a note */", "        return cart.total"])
        #expect(Integrity.report([fine]) == Integrity.Report())
    }

    @Test func xcodeAndPackageJSONTestSettingsCount() {
        let scheme = Integrity.Change(old: "Oby.xcodeproj/xcshareddata/xcschemes/Oby.xcscheme", new: "Oby.xcodeproj/xcshareddata/xcschemes/Oby.xcscheme",
                                      added: ["            <SkippedTests>", "               <Test Identifier = \"StopTests\">"])
        #expect(Integrity.report([scheme]).problems == ["changes the test settings in Oby.xcodeproj/xcshareddata/xcschemes/Oby.xcscheme: <SkippedTests>"])

        let before = "membershipExceptions = (\n\tInfo.plist,\n);\n", after = "membershipExceptions = (\n\tInfo.plist,\n\tStopTests.swift,\n);\n"
        let excluded = Integrity.Change(old: "Oby.xcodeproj/project.pbxproj", new: "Oby.xcodeproj/project.pbxproj",
                                        added: ["\tStopTests.swift,"], before: before, after: after)
        #expect(Integrity.report([excluded]).problems == ["excludes StopTests.swift from its target in Oby.xcodeproj/project.pbxproj"])
        let unlisted = Integrity.Change(old: "Oby.xcodeproj/project.pbxproj", new: "Oby.xcodeproj/project.pbxproj",
                                        removed: ["\t\tA1 /* StopTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1; };"], before: before, after: before)
        #expect(Integrity.report([unlisted]).problems == ["takes StopTests.swift out of a target's sources in Oby.xcodeproj/project.pbxproj"])

        // A test script's value on a line of its own, and a new script, which is fine.
        let script = Integrity.Change(old: "web/package.json", new: "web/package.json", added: ["    \"echo ok\""], removed: ["    \"vitest run\""],
                                      before: "{\"scripts\": {\"test\":\n    \"vitest run\"}}", after: "{\"scripts\": {\"test\":\n    \"echo ok\"}}")
        #expect(Integrity.report([script]).problems == ["changes the test script test in web/package.json"])
        let more = Integrity.Change(old: "web/package.json", new: "web/package.json", added: ["    \"test:e2e\": \"playwright test\","],
                                    before: "{\"scripts\": {\"test\": \"vitest run\"}}", after: "{\"scripts\": {\"test\": \"vitest run\", \"test:e2e\": \"playwright test\"}}")
        #expect(Integrity.report([more]) == Integrity.Report())
    }

    @Test func schemeWordsInEngineMessagesAreNotTestSettings() {
        let word = ["Skip", "ped"].joined()
        let source = "noteBuild(inRepo, \"\(word) Xcode Cloud build: "
            + #"\(candidate.reason ?? "no eligible changes").")"#
        let change = Integrity.Change(old: "Engine/Desk.swift", new: "Engine/Desk.swift",
                                      added: [source])
        #expect(Integrity.report([change]) == Integrity.Report())
    }

    @Test func aCheckForAnEarlierTurnEndsWhenTheNextTurnEnds() async throws {
        var ends: [Date] = []
        desk.runCheck = { [folder] _, command, _, _ in
            let check = await Rounds.run("sleep 30", in: folder, timeout: 60, env: [:], boxed: false)
            ends.append(.now)
            return check
        }
        let agent = try await start("earlier")
        agent.onEvent(.turnEnded(summary: "Done.", failed: false))
        try await until { desk.job("earlier")?.phase == .check }
        try desk.message("earlier", "Also rename the test.")
        try await Task.sleep(for: .milliseconds(200))
        let ended = Date.now
        agent.onEvent(.turnEnded(summary: "Renamed.", failed: false))
        try await until { ends.count == 1 }
        #expect(ends.first.map { $0.timeIntervalSince(ended) < 5 } == true)
        desk.stop("earlier")
        try await until { ends.count == 2 }
    }

    @Test func promptsDontStateTheRounds() {
        var loop = job
        loop.kind = .fix
        loop.pr = nil
        loop.rounds = 3
        let prompt = Prompts.agent(loop)
        #expect(prompt.contains("End your summary with a last line that is exactly `GOAL MET`"))
        #expect(!prompt.contains("3 rounds") && !prompt.contains("up to"))
    }
}

/// Test integrity on real git repositories, one at a time: each starts many git processes, and
/// running them side by side loads the machine enough to slow the timing tests in other suites.
@Suite(.serialized)
struct IntegrityRepositoryTests {
    let folder: URL

    init() throws { folder = try temporaryFolder() }

    /// A repository with a commit before the work's start, whose start has two tests and a test target.
    func repository() async throws -> (URL, (String...) async throws -> String, String) {
        let repo = folder.appending(path: "repo-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: repo.appending(path: "Tests"), withIntermediateDirectories: true)
        let git = { (arguments: String...) async throws -> String in
            let result = try await Shell.run(["git", "-C", repo.path, "-c", "user.name=Oby", "-c", "user.email=oby@example.com", "-c", "commit.gpgsign=false"] + arguments)
            #expect(result.status == 0, "\(arguments): \(result.err)")
            return result.text
        }
        try "let a = 1\n".write(to: repo.appending(path: "Cart.swift"), atomically: true, encoding: .utf8)
        _ = try await git("init", "-q", "-b", "dev")
        _ = try await git("add", ".")
        _ = try await git("commit", "-q", "-m", "before the tests")
        try "@Test func one() {\n    #expect(cart.total == 3)\n}\n@Test func two() {\n    #expect(cart.isEmpty)\n}\n"
            .write(to: repo.appending(path: "Tests/CartTests.swift"), atomically: true, encoding: .utf8)
        try """
            let package = Package(name: "Cart", targets: [
                .target(name: "Cart"),
                .testTarget(
                    name: "CartTests",
                    dependencies: ["Cart"]
                ),
            ])

            """.write(to: repo.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        _ = try await git("add", ".")
        _ = try await git("commit", "-q", "-m", "tests")
        _ = try await git("checkout", "-q", "-b", "oby/fix-64")
        return (repo, git, try await git("rev-parse", "HEAD"))
    }

    @Test func theIntegrityCheckReadsARealWorktree() async throws {
        let repo = folder.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo.appending(path: "Tests"), withIntermediateDirectories: true)
        @discardableResult func git(_ arguments: String...) async throws -> String {
            let result = try await Shell.run(["git", "-C", repo.path, "-c", "user.name=Oby", "-c", "user.email=oby@example.com", "-c", "commit.gpgsign=false"] + arguments)
            #expect(result.status == 0, "\(arguments): \(result.err)")
            return result.text
        }
        try "@Test func one() {\n    #expect(true)\n}\n@Test func two() {}\n".write(to: repo.appending(path: "Tests/CartTests.swift"), atomically: true, encoding: .utf8)
        try "let a = 1\n".write(to: repo.appending(path: "Cart.swift"), atomically: true, encoding: .utf8)
        try await git("init", "-q", "-b", "dev")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "base")
        try await git("checkout", "-q", "-b", "oby/fix-64")
        let start = try await git("rev-parse", "HEAD")
        #expect(await Integrity.check(worktree: repo, against: start) == Integrity.Report())

        // A committed new test and a code change are fine; an uncommitted deletion of a test isn't.
        try "let a = 2\n".write(to: repo.appending(path: "Cart.swift"), atomically: true, encoding: .utf8)
        try "@Test func three() {}\n".write(to: repo.appending(path: "Tests/NewTests.swift"), atomically: true, encoding: .utf8)
        try await git("add", ".")
        try await git("commit", "-q", "-m", "work")
        #expect(await Integrity.check(worktree: repo, against: start) == Integrity.Report())
        try "@Test func one() {\n    #expect(true)\n}\n".write(to: repo.appending(path: "Tests/CartTests.swift"), atomically: true, encoding: .utf8)
        try "@Test(.disabled()) func four() {}\n".write(to: repo.appending(path: "Tests/MoreTests.swift"), atomically: true, encoding: .utf8)
        let weakened = Integrity.Report(problems: ["adds a skip marker in Tests/MoreTests.swift: @Test(.disabled()) func four() {}"],
                                        notes: ["edits existing tests in Tests/CartTests.swift"])
        #expect(await Integrity.check(worktree: repo, against: start) == weakened)

        // The agent can move a ref to hide its work, but not the commit Oby recorded.
        try await git("add", ".")
        try await git("commit", "-q", "-m", "hide")
        try await git("update-ref", "refs/heads/dev", "HEAD")
        #expect(await Integrity.check(worktree: repo, against: "dev") == Integrity.Report())
        #expect(await Integrity.check(worktree: repo, against: start) == weakened)
        #expect(await Integrity.check(worktree: repo, against: "main") == Integrity.Report(problems: ["Oby couldn't compare the tests with main"]))
    }

    @Test func rebasingOntoDevDoesNotCountDevsTestChangesAsTheJobsWork() async throws {
        let (repo, git, start) = try await repository()

        // The job has its own commit, then dev deletes a test file before the job is rebased.
        try "let a = 2\n".write(to: repo.appending(path: "Cart.swift"), atomically: true, encoding: .utf8)
        _ = try await git("add", ".")
        _ = try await git("commit", "-q", "-m", "job work")
        _ = try await git("checkout", "-q", "dev")

        try FileManager.default.removeItem(at: repo.appending(path: "Tests/CartTests.swift"))
        try "@Test func devReplacement() {}\n".write(to: repo.appending(path: "Tests/DevTests.swift"), atomically: true, encoding: .utf8)
        _ = try await git("add", "-A")
        _ = try await git("commit", "-q", "-m", "dev updates tests")
        let trustedTip = try await git("rev-parse", "dev")
        _ = try await git("update-ref", "refs/remotes/origin/dev", "dev")
        _ = try await git("checkout", "-q", "oby/fix-64")
        _ = try await git("rebase", "dev")

        #expect(await Integrity.check(worktree: repo, against: start, trustedBaseTip: trustedTip) == Integrity.Report())

        // A job can rewrite its remote-tracking ref. Oby's pinned tip still exposes its deletion.
        try FileManager.default.removeItem(at: repo.appending(path: "Tests/DevTests.swift"))
        _ = try await git("add", "-A")
        _ = try await git("commit", "-q", "-m", "job weakens tests")
        _ = try await git("update-ref", "refs/remotes/origin/dev", "HEAD")
        let problems = await Integrity.check(worktree: repo, against: start, trustedBaseTip: trustedTip).problems
        #expect(problems.contains("deletes the test file Tests/DevTests.swift"))
    }

    @Test func agentAttributesCantHideTheDiff() async throws {
        let (repo, git, start) = try await repository()
        // A diff driver that shows nothing: git would print no change without --no-textconv.
        try "*.swift diff=hide\n".write(to: repo.appending(path: ".gitattributes"), atomically: true, encoding: .utf8)
        _ = try await git("config", "diff.hide.textconv", "true")
        try "@Test func one() {\n    #expect(cart.total == 3)\n}\n".write(to: repo.appending(path: "Tests/CartTests.swift"), atomically: true, encoding: .utf8)
        _ = try await git("add", ".")
        _ = try await git("commit", "-q", "-m", "hide")
        #expect(await Integrity.check(worktree: repo, against: start).problems == ["removes 1 assertion from Tests/CartTests.swift", "lowers the test count by 1"])
    }

    @Test func theCommitsCountEvenWhenTheWorktreeLooksClean() async throws {
        let (repo, git, start) = try await repository()
        try "@Test(.disabled()) func one() {\n    #expect(cart.total == 3)\n}\n@Test func two() {\n    #expect(cart.isEmpty)\n}\n"
            .write(to: repo.appending(path: "Tests/CartTests.swift"), atomically: true, encoding: .utf8)
        _ = try await git("commit", "-q", "-am", "skip one")
        // Put back in the worktree only: the check runs it, but Publish would send the commit.
        _ = try await git("checkout", start, "--", "Tests/CartTests.swift")
        #expect(await Integrity.check(worktree: repo, against: start).problems
                == ["adds a skip marker in Tests/CartTests.swift: @Test(.disabled()) func one() {"])
    }

    @Test func movingHEADBehindTheStartDoesntHideMissingTests() async throws {
        let (repo, git, start) = try await repository()
        _ = try await git("reset", "-q", "--hard", "HEAD~1")
        let problems = await Integrity.check(worktree: repo, against: start).problems
        #expect(problems.contains("deletes the test file Tests/CartTests.swift"))
        #expect(problems.contains("changes the test target CartTests in Package.swift"))
    }

    @Test func aMultilineTestTargetExclusionFails() async throws {
        let (repo, _, start) = try await repository()
        let package = try String(contentsOf: repo.appending(path: "Package.swift"), encoding: .utf8)
        try package.replacing("dependencies: [\"Cart\"]\n", with: "dependencies: [\"Cart\"],\n        exclude: [\"CartTests.swift\"]\n")
            .write(to: repo.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        #expect(await Integrity.check(worktree: repo, against: start).problems == ["changes the test target CartTests in Package.swift"])
        // A new test target is fine.
        try package.replacing("    ])", with: "        .testTarget(name: \"MoreTests\"),\n    ])")
            .write(to: repo.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        #expect(await Integrity.check(worktree: repo, against: start) == Integrity.Report())
    }

    @Test func replacementObjectsAndPrefixConfigDontHideTheDiff() async throws {
        let (repo, git, start) = try await repository()
        try FileManager.default.removeItem(at: repo.appending(path: "Tests/CartTests.swift"))
        _ = try await git("commit", "-q", "-am", "drop the tests")
        // The start commit redefined as the weakened one, and paths without a/ and b/.
        _ = try await git("replace", start, "HEAD")
        _ = try await git("config", "diff.noprefix", "true")
        _ = try await git("config", "diff.relative", "true")
        let problems = await Integrity.check(worktree: repo, against: start).problems
        #expect(problems.contains("deletes the test file Tests/CartTests.swift"))
    }
}
