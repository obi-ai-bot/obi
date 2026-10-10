import Foundation
import Testing
@testable import ObyEngine

/// An intentionally slow setup that returns even after cancellation, like a tool finishing late.
private actor PreparationGate {
    private var waiting: [String: CheckedContinuation<Job, Never>] = [:]
    private(set) var started: [String] = []
    private(set) var cancelled: Set<String> = []

    func prepare(_ job: Job) async -> Job {
        started.append(job.id)
        let prepared = await withCheckedContinuation { waiting[job.id] = $0 }
        if Task.isCancelled { cancelled.insert(job.id) }
        return prepared
    }

    func release(_ job: Job) { waiting.removeValue(forKey: job.id)?.resume(returning: job) }
}

@MainActor
final class JobLifecycleTests {
    let folder: URL
    let store: JobStore
    private let gate = PreparationGate()
    let desk: Desk

    init() throws {
        folder = try temporaryFolder()
        store = JobStore(url: folder.appending(path: "oby.sqlite"))
        let gate = gate
        desk = Desk(accounts: AccountStore(root: folder), store: store, prepare: { await gate.prepare($0) })
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func draft(_ id: String, repo: String = "deskree-inc/oby") -> Desk.Draft {
        // An unsupported agent exposes an accidental start without launching a real CLI.
        let job = Job(id: id, request: "Build oby", agent: "test", account: "default", repo: repo,
                      branch: "oby/build-\(id)", kind: .build, task: "Build oby")
        return Desk.Draft(said: job.request, reply: "Build oby", job: job, guessed: false)
    }

    func until(_ condition: () async -> Bool) async throws {
        let deadline = Date.now + 3
        while !(await condition()) {
            guard Date.now < deadline else { throw Shell.Failure(message: "Timed out waiting for preparation.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func quittingInterruptsEveryQueuedJobAndPersistsIt() async throws {
        let first = desk.dispatch(draft("first"))
        try await until { await self.gate.started == [first.id] }
        let second = desk.dispatch(draft("second"))
        let other = desk.dispatch(draft("other", repo: "deskree-inc/other"))
        try await until { await self.gate.started.contains(other.id) }
        var finished: [Job] = []
        desk.onFinish = { finished.append($0) }

        desk.quit()
        #expect(desk.active.isEmpty)
        #expect(finished.count == 3)
        #expect(store.recent().allSatisfy { $0.status == .interrupted && $0.finished != nil && $0.step.isEmpty })

        await gate.release(first)
        await gate.release(other)
        try await until { await self.gate.cancelled == [first.id, other.id] }
        // A subsequent setup waits for all the preceding ones: the cancelled second never ran.
        let sentinel = desk.dispatch(draft("sentinel"))
        try await until { await self.gate.started.contains(sentinel.id) }
        #expect(!(await gate.started.contains(second.id)))
        #expect(desk.job(first.id)?.status == .interrupted)
        #expect(desk.job(other.id)?.status == .interrupted)
        #expect(finished.count == 3)
        await gate.release(sentinel)
        try await until { self.desk.job(sentinel.id)?.status == .failed }

        let restarted = Desk(accounts: AccountStore(root: folder), store: store)
        for id in [first.id, second.id, other.id] {
            #expect(restarted.job(id)?.status == .interrupted)
        }
    }

    @Test func stoppingAWaitingJobSkipsItsSetupAndKeepsTheCloneSerialized() async throws {
        let first = desk.dispatch(draft("first"))
        try await until { await self.gate.started == [first.id] }
        let second = desk.dispatch(draft("second"))
        let third = desk.dispatch(draft("third"))
        desk.stop(second.id)
        #expect(desk.job(second.id)?.status == .stopped)
        #expect(await gate.started == [first.id])

        await gate.release(first)
        try await until { await self.gate.started.contains(third.id) }
        #expect(await gate.started == [first.id, third.id])
        #expect(desk.job(second.id)?.status == .stopped)
        await gate.release(third)
        try await until { self.desk.active.isEmpty }
    }

    @Test func stoppingAnOngoingSetupCancelsItWithoutAFailureNotice() async throws {
        let job = desk.dispatch(draft("stopped"))
        try await until { await self.gate.started == [job.id] }
        var finished: [Job.Status] = []
        desk.onFinish = { finished.append($0.status) }
        desk.stop(job.id)
        await gate.release(job)
        try await until { await self.gate.cancelled.contains(job.id) }
        #expect(desk.job(job.id)?.status == .stopped)
        #expect(finished == [.stopped])
    }

    @Test func relaunchInterruptsQueuedAndRunningJobsButKeepsFinishedJobs() {
        for (id, status) in [("queued", Job.Status.queued), ("running", .running), ("done", .done), ("stopped", .stopped)] {
            var job = draft(id).job
            job.status = status
            store.save(job)
        }
        let restarted = Desk(accounts: AccountStore(root: folder), store: store)
        #expect(restarted.active.isEmpty)
        #expect(restarted.job("queued")?.status == .interrupted)
        #expect(restarted.job("running")?.status == .interrupted)
        #expect(restarted.job("done")?.status == .done)
        #expect(restarted.job("stopped")?.status == .stopped)
        #expect(store.recent().filter { $0.status == .interrupted }.allSatisfy { $0.finished != nil })
    }
}

struct ShellCancellationTests {
    @Test(arguments: ["exec sleep 30", "sleep 30 & wait"])
    func cancellationStopsARunningToolAndItsChildren(command: String) async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appending(path: "started")
        let task = Task {
            try await Shell.run(["sh", "-c", "echo ready > started; \(command)"], in: folder)
        }
        defer { task.cancel() }
        let deadline = Date.now + 3
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard Date.now < deadline else { throw Shell.Failure(message: "The tool never started.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelledAt = Date.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled tool returned output instead of CancellationError.")
        } catch is CancellationError {
            #expect(Date.now.timeIntervalSince(cancelledAt) < 3)
        }
    }

    @Test func cancellationBeforeLaunchNeverRunsTheTool() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Shell.run(["sh", "-c", "echo late > started"], in: folder)
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled task launched a tool.")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "started").path))
        }
    }
}
