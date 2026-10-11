import Foundation
import Testing
@testable import ObyEngine

/// "Stop everything": the brain's stop_agent stops every job, running or queued, and says how many.
@MainActor
struct StopEverythingTests {
    /// An agent that runs until it's told to stop.
    final class Agent: AgentRun {
        var started = 0
        var stopped = 0
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws { started += 1 }
        func send(_ text: String) {}
        func end() {}
        func stop() { stopped += 1 }
        func kill() {}
    }

    let stop = Planner.Result(plan: Plan(action: .stopAgent, reply: "Oby will stop all running work.", dispatches: [], question: nil), by: "claude")

    func draft(_ id: String) -> Desk.Draft {
        var job = job
        job.id = id
        return Desk.Draft(said: "Review oby PR #33", reply: "Oby will review PR #33 in oby.", job: job, guessed: false)
    }

    @Test func stopAgentStopsRunningAndQueuedJobs() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let agent = Agent()
        desk.makeAgent = { _, _, _ in agent }
        // The queued job's repository stays "getting ready" until the test lets it go.
        let (held, release) = AsyncStream<Void>.makeStream()
        desk.prepare = { job in
            if job.id == "queued" { for await _ in held {} }
            return job
        }

        desk.dispatch(draft("running"))
        for _ in 0..<500 where desk.job("running")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        desk.dispatch(draft("queued"))
        #expect(desk.job("running")?.status == .running && agent.started == 1)
        #expect(desk.job("queued")?.status == .queued)

        #expect(await desk.card(for: stop, said: "stop everything") == .reply("Stopped 2 jobs."))
        #expect(desk.job("running")?.status == .stopped && desk.job("queued")?.status == .stopped)
        #expect(desk.active.isEmpty && agent.stopped == 1)

        // Its repository gets ready after all: the stopped job still doesn't start.
        release.finish()
        try await Task.sleep(for: .milliseconds(100))
        #expect(desk.job("queued")?.status == .stopped && agent.started == 1)

        #expect(await desk.card(for: stop, said: "stop everything") == .reply("Nothing is running."))
    }

    @Test func oneJobIsOneJob() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let (held, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        desk.prepare = { job in
            for await _ in held {}
            return job
        }
        desk.dispatch(draft("queued"))
        #expect(await desk.card(for: stop, said: "stop it") == .reply("Stopped 1 job."))
    }
}
