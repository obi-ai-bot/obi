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

    let stop = Planner.Result(plan: Plan(action: .stopAgent, reply: "Oby will stop all running work.", dispatches: [], question: nil, all: true), by: "claude")

    func review(_ id: String) -> Job {
        var job = job
        job.id = id
        return job
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

        desk.dispatch(review("running"))
        for _ in 0..<500 where desk.job("running")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        desk.dispatch(review("queued"))
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

    /// An agent that's a real process, stopped and killed as ClaudeAgent does it.
    final class Sleeper: AgentRun {
        let process = Process()
        var group: ProcessGroup?
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            process.executableURL = URL(filePath: "/bin/sleep")
            process.arguments = ["30"]
            group = try ProcessGroup.run(process)
        }
        func send(_ text: String) {}
        func end() {}
        /// Oby's quit killed it.
        var killed = false
        func stop() {
            let group = group
            // Past the grace, as ClaudeAgent does; once Oby quit, it has exited and this never runs.
            DispatchQueue.main.asyncAfter(deadline: .now() + Halt.grace) { [weak self] in
                guard self?.killed != true else { return }
                group?.end(after: Halt.stopping)
            }
        }
        func kill() {
            killed = true
            group?.end(after: Halt.dropping)
        }
    }

    /// Quitting during a stopped agent's grace still ends it before Oby exits: its own stop never would.
    @Test(.timeLimit(.minutes(1)))
    func quittingRightAfterStopEndsTheAgent() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let agent = Sleeper()
        defer { _ = kill(agent.process.processIdentifier, SIGKILL) }
        desk.makeAgent = { _, _, _ in agent }
        desk.prepare = { $0 }
        desk.dispatch(review("stopped"))
        for _ in 0..<500 where desk.job("stopped")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        #expect(agent.process.isRunning)

        desk.stop("stopped")
        desk.quit()
        // Quit itself ended it: its stop's own end never comes once Oby quit, so the process's end
        // is quit's kill, however long a busy machine takes to show it.
        #expect(agent.killed)
        for _ in 0..<1000 where agent.process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!agent.process.isRunning)
        #expect(agent.process.terminationReason == .uncaughtSignal)
        #expect(desk.job("stopped")?.status == .stopped)
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
        desk.dispatch(review("queued"))
        #expect(await desk.card(for: stop, said: "stop it") == .reply("Stopped 1 job."))
    }
}
