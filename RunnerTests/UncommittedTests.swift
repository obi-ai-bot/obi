import Foundation
import Testing
@testable import ObyEngine

/// A job that's done with its work left uncommitted gets one round to commit it (#220). One test
/// at a time, as GuardTests: each polls the main actor while it waits.
@MainActor
@Suite(.serialized)
struct UncommittedTests {
    /// An agent whose events the test sends, noting what Oby told it.
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var sent: [String] = []
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws { self.onEvent = onEvent }
        func send(_ text: String) { sent.append(text) }
        func end() {}
        func stop() {}
        func kill() {}
    }

    /// The agents made, what was published, and the worktree as git would see it.
    final class Made {
        var agents: [Agent] = []
        var published = 0
        var commits = 0
        var changed: [String] = []
    }

    let desk: Desk
    let made = Made()
    let files = ["Engine/Jobs.swift", "Engine/TetrixUse.swift", "RunnerTests/TetrixTests.swift"]

    init() throws {
        let folder = try temporaryFolder()
        desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.makeAgent = { [made] _, _, _ in
            let agent = Agent()
            made.agents.append(agent)
            return agent
        }
        desk.prepare = { $0 }
        desk.countCommits = { [made] _, _ in made.commits }
        desk.changedFiles = { [made] _ in made.changed }
        desk.publishOnItsOwn = { [made] _, _, _ in
            made.published += 1
            return URL(string: "https://github.com/deskree-inc/oby/pull/80")!
        }
        desk.integrity = { _ in Integrity.Report() }
        desk.runCheck = { _, command, _, _ in Rounds.Check(command: command, passed: true, output: "ok") }
    }

    /// A fix job with a passing check and `rounds` rounds, started on the default account.
    func start(_ id: String, rounds: Int? = 4) async throws -> Agent {
        var fix = job
        fix.id = id
        fix.kind = .fix
        fix.pr = nil
        fix.base = "dev"
        fix.branch = "oby/fix-214"
        fix.check = "swift test"
        fix.rounds = rounds
        desk.dispatch(Desk.Draft(said: "fix oby #214", reply: "", job: fix, guessed: false))
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

    @Test func aDoneRoundWithNoCommitsAndADirtyWorktreeGetsARoundToCommit() async throws {
        made.changed = files
        let agent = try await start("dirty")
        agent.onEvent(.turnEnded(summary: "Done.", failed: false))
        try await until { agent.sent.count == 1 }
        let running = try #require(desk.job("dirty"))
        #expect(running.status == .running && running.round == 2)
        let said = try #require(agent.sent.first)
        #expect(said.hasPrefix("Your changes to `Engine/Jobs.swift`, `Engine/TetrixUse.swift` and `RunnerTests/TetrixTests.swift` are uncommitted"))
        #expect(said.contains("Run `swift test` in the foreground, commit when they pass, and don't end your turn before the commit exists."))

        // It commits: the job is done and publishes.
        made.commits = 1
        made.changed = []
        agent.onEvent(.turnEnded(summary: "Committed the fix.", failed: false))
        try await until { desk.job("dirty")?.isActive == false }
        let done = try #require(desk.job("dirty"))
        #expect(done.status == .done && done.summary.hasPrefix("Committed the fix.") && made.published == 1)
        #expect(agent.sent.count == 1)
    }

    @Test func aCommitRoundThatCommitsNothingFailsNamingTheFiles() async throws {
        made.changed = files
        let agent = try await start("again")
        agent.onEvent(.turnEnded(summary: "Done.", failed: false))
        try await until { agent.sent.count == 1 }
        agent.onEvent(.turnEnded(summary: "Done.", failed: false))
        try await until { desk.job("again")?.isActive == false }
        let failed = try #require(desk.job("again"))
        #expect(failed.status == .failed && made.published == 0 && agent.sent.count == 1)
        #expect(failed.summary.hasPrefix("Nothing committed: `Engine/Jobs.swift`, `Engine/TetrixUse.swift` and `RunnerTests/TetrixTests.swift` are changed in the worktree but not committed.\n\nDone."))
        #expect(failed.doneLine == "Nothing committed: \(failed.heading)")
    }

    @Test func aDoneRoundWithNoCommitsAndACleanWorktreeStillFails() async throws {
        let agent = try await start("clean")
        agent.onEvent(.turnEnded(summary: "Done.", failed: false))
        try await until { desk.job("clean")?.isActive == false }
        let failed = try #require(desk.job("clean"))
        #expect(failed.status == .failed && failed.summary.hasPrefix("Nothing committed: Done.") && agent.sent.isEmpty)
    }

    @Test func onItsLastRoundADirtyWorktreeFailsNamingTheFiles() async throws {
        made.changed = ["Engine/Desk.swift"]
        let agent = try await start("last", rounds: nil)
        agent.onEvent(.turnEnded(summary: "Done.", failed: false))
        try await until { desk.job("last")?.isActive == false }
        let failed = try #require(desk.job("last"))
        #expect(failed.status == .failed && agent.sent.isEmpty)
        #expect(failed.summary.hasPrefix("Nothing committed: `Engine/Desk.swift` is changed in the worktree but not committed."))
    }

    @Test func theFailureReasonListsTheDirtyFiles() {
        var fix = job
        fix.kind = .fix
        let (status, summary) = Job.ending(fix, .done, "It failed", made: 0, dirty: ["A.swift", "B.swift"])
        #expect(status == .failed && summary == "Nothing committed: `A.swift` and `B.swift` are changed in the worktree but not committed.\n\nIt failed")
        #expect(Job.ending(fix, .done, "It failed", made: 0).1 == "Nothing committed: It failed")
        #expect(Job.listed((1...12).map { "\($0).swift" }).hasSuffix("`10.swift` and 2 more"))
    }

    @Test func gitStatusNamesTheChangedFiles() {
        let porcelain = " M Engine/Jobs.swift\n?? RunnerTests/New.swift\nR  Old.swift -> Engine/Desk.swift\n"
        #expect(Job.changedFiles(porcelain: porcelain) == ["Engine/Jobs.swift", "RunnerTests/New.swift", "Engine/Desk.swift"])
        #expect(Job.changedFiles(porcelain: "").isEmpty)
    }

    @Test func agentsRunChecksInTheForeground() {
        var fix = job
        fix.kind = .fix
        #expect(Prompts.agent(fix).contains("Run checks in the foreground, and never end a turn waiting on a background command"))
    }
}
