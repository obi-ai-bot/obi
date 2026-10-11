import Foundation
import Testing
@testable import ObyEngine

/// Limits in Swift, no-progress stops and test integrity (#64, cases 3.1 and 3.2).
@MainActor
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
        desk.integrity = { _ in [] }
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
        desk.dispatch(Desk.Draft(said: "work on oby #64", reply: "", job: fix, guessed: false))
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
        desk.runCheck = { [made] _, command, timeout in
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

        // One more round: telling it something runs one, and the limit is gone.
        try desk.message("round", "One more round, please.")
        let again = try #require(desk.job("round"))
        #expect(again.status == .running && again.limit == nil && again.round == 2 && again.rounds == 5)
    }

    @Test func theRoundTimerCoversTheTurnNotTheCheck() async throws {
        desk.limits.round = 0.3
        var first = true
        desk.runCheck = { _, command, _ in
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

    @Test func aJobThatRunsPastItsCapStops() async throws {
        desk.limits.job = 1
        failing((0..<9).map { "✘ Test t\($0)() failed" })
        let agent = try await start("cap", rounds: 10)
        // Every round fails differently, so only the cap ends it.
        for round in 1...3 {
            agent.onEvent(.turnEnded(summary: "Round \(round).", failed: false))
            try await until { agent.sent.count == round }
        }
        try await until { desk.job("cap")?.isActive == false }
        try expectHeld("cap", "the job ran past 1 second", agent: agent)
        #expect(desk.job("cap")?.summary.hasSuffix("Round 3.") == true)
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
        let check = await Rounds.run("echo started; sleep 30", in: folder, timeout: 0.5, boxed: false)
        #expect(Date.now.timeIntervalSince(started) < 10)
        #expect(!check.passed && !check.succeeded)
        #expect(check.output.hasPrefix("started\n"))
        #expect(check.output.hasSuffix("Oby stopped it after 0.5 seconds, the most a test run may take."))
        let quick = await Rounds.run("echo fine", in: folder, timeout: 5, boxed: false)
        #expect(quick.passed && quick.output == "fine\n")
    }

    @Test func claudeCodeGetsMaxTurns() {
        let launch = ClaudeAgent.launch(worktree: folder, configDirectory: nil, model: "claude-opus-5-5", resume: "s1", maxTurns: JobLimits().maxTurns)
        let at = launch.arguments.firstIndex(of: "--max-turns")
        #expect(at.map { launch.arguments[$0 + 1] } == "200")
        #expect(!ClaudeAgent.launch(worktree: folder, configDirectory: nil, model: nil, resume: nil).arguments.contains("--max-turns"))
        let result: [String: Any] = ["type": "result", "subtype": "error_max_turns", "is_error": false, "num_turns": 200]
        #expect(StreamJSON.events(result) == [.maxTurns(200)])
    }

    @Test func usingEveryTurnStopsTheJob() async throws {
        let agent = try await start("turns")
        agent.onEvent(.maxTurns(200))
        try await until { desk.job("turns")?.isActive == false }
        try expectHeld("turns", "Claude Code took its 200 turns in one round", agent: agent)
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

    // MARK: Test integrity

    @Test func aRoundThatWeakensTheTestsFailsEvenWhenTheCheckPasses() async throws {
        failing([])
        var weakened = true
        desk.integrity = { _ in weakened ? ["deletes the test file RunnerTests/StopTests.swift"] : [] }
        let agent = try await start("weak", rounds: 3)
        agent.onEvent(.turnEnded(summary: "Green now.", failed: false))
        try await until { agent.sent.count == 1 }
        #expect(agent.sent[0].contains("this work weakens them:\n\n- deletes the test file RunnerTests/StopTests.swift"))
        #expect(!agent.sent[0].contains("it failed"))
        #expect(desk.job("weak")?.status == .running && desk.job("weak")?.round == 2)
        weakened = false
        agent.onEvent(.turnEnded(summary: "Put the tests back.", failed: false))
        try await until { desk.job("weak")?.isActive == false }
        #expect(desk.job("weak")?.status == .done && desk.job("weak")?.limit == nil && made.published == 1)
    }

    @Test func weakenedTestsOnTheLastRoundHoldTheJob() async throws {
        failing([])
        desk.integrity = { _ in ["adds a skip marker in RunnerTests/StopTests.swift: @Test(.disabled())"] }
        let agent = try await start("weaklast", rounds: 1)
        agent.onEvent(.turnEnded(summary: "Green now.", failed: false))
        try await until { desk.job("weaklast")?.isActive == false }
        try expectHeld("weaklast", "the tests are still weakened after 1 round", agent: agent)
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
            diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
            index 4444444..5555555 100644
            --- a/.github/workflows/ci.yml
            +++ b/.github/workflows/ci.yml
            @@ -3 +3 @@
            -  run: swift test
            +  run: swift build
            diff --git a/Engine/Desk.swift b/Engine/Desk.swift
            index 6666666..7777777 100644
            --- a/Engine/Desk.swift
            +++ b/Engine/Desk.swift
            @@ -1 +1 @@
            -let a = 1
            +let a = 2
            """
        let changes = Integrity.changes(diff)
        #expect(changes.map(\.old) == ["RunnerTests/StopTests.swift", "RunnerTests/LeadTests.swift", ".github/workflows/ci.yml", "Engine/Desk.swift"])
        #expect(changes.map(\.new) == [nil, "RunnerTests/LeadTests.swift", ".github/workflows/ci.yml", "Engine/Desk.swift"])
        #expect(Integrity.problems(changes) == [
            "deletes the test file RunnerTests/StopTests.swift",
            "edits existing tests in RunnerTests/LeadTests.swift",
            "adds a skip marker in RunnerTests/LeadTests.swift: @Test(.enabled(if: bubblewrapRuns)) func leads() {",
            "changes test or CI config: .github/workflows/ci.yml",
            "lowers the test count by 1",
        ])
    }

    @Test func newTestsAreFine() {
        let added = Integrity.Change(old: "RunnerTests/LeadTests.swift", new: "RunnerTests/LeadTests.swift",
                                     added: ["", "    @Test func aNewOne() {", "        #expect(true)", "    }"])
        let file = Integrity.Change(old: nil, new: "web/src/cart.test.ts", added: ["it('adds', () => {})", "test('removes', () => {})"])
        let code = Integrity.Change(old: "Engine/Desk.swift", new: "Engine/Desk.swift", added: ["it.skip"], removed: ["func test() {}"])
        #expect(Integrity.problems([added, file, code]) == [])
        for path in ["RunnerTests/A.swift", "tests/test_cart.py", "pkg/cart_test.go", "src/__tests__/x.js", "Sources/CartTests.swift", "web/a.spec.tsx"] {
            #expect(Integrity.isTest(path), "\(path)")
        }
        for path in ["Engine/Desk.swift", "docs/testing.md", "Contest/A.swift", "src/latest.ts"] { #expect(!Integrity.isTest(path), "\(path)") }
        for line in ["it.skip('x', () => {})", "    @pytest.mark.skip(reason='flaky')", "t.Skip(\"later\")", "#[ignore]", "throw XCTSkip(\"no\")",
                     "describe.only('cart', () => {", "@Test(.disabled(\"flaky\"))", "withKnownIssue {"] {
            #expect(line.contains(Integrity.skip), "\(line)")
        }
    }

    @Test func theIntegrityCheckReadsARealWorktree() async throws {
        let repo = folder.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo.appending(path: "Tests"), withIntermediateDirectories: true)
        func git(_ arguments: String...) async throws {
            let result = try await Shell.run(["git", "-C", repo.path, "-c", "user.name=Oby", "-c", "user.email=oby@example.com", "-c", "commit.gpgsign=false"] + arguments)
            #expect(result.status == 0, "\(arguments): \(result.err)")
        }
        try "@Test func one() {}\n@Test func two() {}\n".write(to: repo.appending(path: "Tests/CartTests.swift"), atomically: true, encoding: .utf8)
        try "let a = 1\n".write(to: repo.appending(path: "Cart.swift"), atomically: true, encoding: .utf8)
        try await git("init", "-q", "-b", "dev")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "base")
        try await git("checkout", "-q", "-b", "oby/fix-64")
        #expect(await Integrity.check(worktree: repo, against: "dev") == [])

        // A committed new test and a code change are fine; an uncommitted edit to an existing test isn't.
        try "let a = 2\n".write(to: repo.appending(path: "Cart.swift"), atomically: true, encoding: .utf8)
        try "@Test func three() {}\n".write(to: repo.appending(path: "Tests/NewTests.swift"), atomically: true, encoding: .utf8)
        try await git("add", ".")
        try await git("commit", "-q", "-m", "work")
        #expect(await Integrity.check(worktree: repo, against: "dev") == [])
        try "@Test func one() {}\n".write(to: repo.appending(path: "Tests/CartTests.swift"), atomically: true, encoding: .utf8)
        try "@Test(.disabled()) func four() {}\n".write(to: repo.appending(path: "Tests/MoreTests.swift"), atomically: true, encoding: .utf8)
        #expect(await Integrity.check(worktree: repo, against: "dev") == [
            "edits existing tests in Tests/CartTests.swift",
            "adds a skip marker in Tests/MoreTests.swift: @Test(.disabled()) func four() {}",
        ])
        #expect(await Integrity.check(worktree: repo, against: "main") == ["Oby couldn't compare the tests with main"])
    }
}
