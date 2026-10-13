import Foundation
import Testing
@testable import ObyEngine

/// Claude Code dies mid-turn with nothing on stderr: Oby says how it ended, and picks the job's
/// session up once before the job fails.
@MainActor
struct CutOffTests {
    /// An agent whose events the test sends, noting how it was started.
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var prompt = ""
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            self.prompt = prompt
            self.onEvent = onEvent
        }
        func send(_ text: String) {}
        func end() {}
        func stop() {}
        func kill() {}
    }

    /// Every agent the desk made, with the session it picks up.
    final class Made { var agents: [(agent: Agent, resume: String?)] = [] }

    let desk: Desk
    let made = Made()

    init() throws {
        let folder = try temporaryFolder()
        desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.makeAgent = { [made] _, _, resume in
            let agent = Agent()
            made.agents.append((agent, resume))
            return agent
        }
        desk.prepare = { $0 }
    }

    /// Starts a review job and lets its first agent be cut off.
    func cutOff(_ id: String) async throws -> Agent {
        var job = job
        job.id = id
        desk.dispatch(job)
        for _ in 0..<500 where desk.job(id)?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        let first = try #require(made.agents.first?.agent)
        first.onEvent(.session("e6a24229"))
        first.onEvent(.cutOff(summary: "Claude Code stopped without finishing (killed by signal 9 (SIGKILL))."))
        return first
    }

    @Test func aCutOffAgentPicksItsSessionUpOnce() async throws {
        let first = try await cutOff("resumed")
        #expect(made.agents.count == 2 && made.agents.last?.resume == "e6a24229")
        let second = try #require(made.agents.last?.agent)
        #expect(second.prompt == Desk.cutOff)
        #expect(desk.job("resumed")?.status == .running)
        #expect(desk.job("resumed")?.step == "Picking up where Claude Code was cut off")
        // The first agent no longer speaks for the job.
        first.onEvent(.finished(summary: "late", failed: true))
        #expect(desk.job("resumed")?.status == .running)

        second.onEvent(.turnEnded(summary: "Reviewed: looks good.", failed: false))
        second.onEvent(.finished(summary: "Reviewed: looks good.", failed: false))
        for _ in 0..<500 where desk.job("resumed")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        let ended = try #require(desk.job("resumed"))
        #expect(ended.status == .done && ended.summary == "Reviewed: looks good.")
    }

    @Test func cutOffAgainFailsTheJobSayingHowItEnded() async throws {
        _ = try await cutOff("twice")
        let second = try #require(made.agents.last?.agent)
        second.onEvent(.cutOff(summary: "Claude Code stopped without finishing (exit status 137)."))
        #expect(made.agents.count == 2)
        let ended = try #require(desk.job("twice"))
        #expect(ended.status == .failed)
        #expect(ended.summary == "Claude Code stopped without finishing (exit status 137).\n\nOby picked its session up once, and it was cut off again.")
    }

    @Test func noSessionToPickUpFailsTheJob() async throws {
        var job = job
        job.id = "nosession"
        desk.dispatch(job)
        for _ in 0..<500 where desk.job("nosession")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        made.agents.first?.agent.onEvent(.cutOff(summary: "Claude Code stopped without finishing (exit status 1)."))
        #expect(made.agents.count == 1)
        #expect(desk.job("nosession")?.status == .failed && desk.job("nosession")?.summary == "Claude Code stopped without finishing (exit status 1).")
    }

    /// A job the user talks to again after it ended gets its own pick-up.
    @Test func eachRunOfTheJobPicksUpOnce() async throws {
        _ = try await cutOff("again")
        try #require(made.agents.last?.agent).onEvent(.turnEnded(summary: "Done.", failed: false))
        try #require(made.agents.last?.agent).onEvent(.finished(summary: "Done.", failed: false))
        for _ in 0..<500 where desk.job("again")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        try desk.message("again", "check the tests too")
        #expect(made.agents.count == 3)
        try #require(made.agents.last?.agent).onEvent(.cutOff(summary: "Claude Code stopped without finishing (exit status 1)."))
        #expect(made.agents.count == 4 && made.agents.last?.agent.prompt == Desk.cutOff)
    }
}

/// What the log and the summary say about how Claude Code's process ended.
struct ProcessEndTests {
    func run(_ script: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        return await ClaudeAgent.exit(of: process)
    }

    @Test func anExitStatus() async throws {
        #expect(try await run("exit 3") == "exit status 3")
        #expect(try await run("true") == "exit status 0")
    }

    @Test func aSignal() async throws {
        #expect(try await run("kill -9 $$") == "killed by signal 9 (SIGKILL)")
        // Not sent for real: the test runner may block SIGTERM, and its children inherit that.
        #expect(ClaudeAgent.ended(.uncaughtSignal, 15) == "killed by signal 15 (SIGTERM)")
        #expect(ClaudeAgent.ended(.uncaughtSignal, 64) == "killed by signal 64")
    }
}
