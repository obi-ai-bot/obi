import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

/// A job waiting its turn for a slot (#237) isn't stuck (#231): the sweep (Engine/Failures.swift)
/// starts its step clock when it really starts.
@MainActor
struct StuckTests {
    func queued(_ id: String, files: [String]) -> Job {
        FailureTests.job(id) {
            $0.status = .queued
            $0.finished = nil
            $0.files = files
        }
    }

    @Test func aJobWaitingItsTurnRecordsNothing() async throws {
        let test = try FailureTests(signedIn: false)
        let desk = test.desk
        let log = desk.failureLog
        desk.maxRunning = 1
        desk.enqueue(queued("first", files: ["Engine/Desk.swift"]))
        try await test.until("the first runs") { desk.job("first")?.status == .running }
        desk.enqueue(queued("second", files: ["Engine/Desk.swift", "Engine/Failures.swift"]))
        try await test.until("the second waits") { desk.job("second")?.step.hasPrefix("Waiting for ") == true }
        let waiting = try #require(desk.job("second"))
        #expect(waiting.status == .queued)
        #expect(waiting.step == "Waiting for a free slot: 1 of 1 jobs running")
        log.sweep()
        // Two hours in line.
        log.now = { .now.addingTimeInterval(7200) }
        log.sweep()
        #expect(test.triggers(of: "second").isEmpty)

        // Its turn: it catches up, and its clock starts now.
        var catchingUp = waiting
        catchingUp.step = "Catching up with dev"
        catchingUp.waiting = nil
        desk.replace(catchingUp)
        log.sweep()
        #expect(test.triggers(of: "second").isEmpty)
        log.now = { .now.addingTimeInterval(7200 + 31 * 60) }
        log.sweep()
        #expect(test.triggers(of: "second") == [.stuck])
    }

    @Test func aJobStuckPreparingIsRecorded() async throws {
        let test = try FailureTests(signedIn: false)
        let desk = test.desk
        let log = desk.failureLog
        // Cloning that never ends.
        desk.prepare = { job in
            try await Task.sleep(for: .seconds(3600))
            return job
        }
        desk.enqueue(queued("slow", files: ["Engine/Desk.swift"]))
        #expect(desk.job("slow")?.phase == .prepare)
        #expect(desk.job("slow")?.step == "Getting oby ready")
        log.sweep()
        log.now = { .now.addingTimeInterval(29 * 60) }
        log.sweep()
        #expect(test.triggers(of: "slow").isEmpty)
        log.now = { .now.addingTimeInterval(31 * 60) }
        log.sweep()
        #expect(test.triggers(of: "slow") == [.stuck])
        let record = try #require(log.store.failures().first { $0.job == "slow" })
        #expect(record.id == "slow-stuck-prepare-1-")
        #expect(record.what == "It stayed in its prepare step for over \(JobLimits.span(1800)).")
    }
}
