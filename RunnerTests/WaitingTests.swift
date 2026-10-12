import Foundation
import Testing
@testable import ObyEngine
@testable import ObyShared
@testable import oby_runner

/// A queued job says what it waits for (#238): a free slot (#237), or a runner update. It's cleared
/// when the job starts.
@MainActor
struct WaitingTests {
    func queued(_ id: String, files: [String]) -> Job {
        FailureTests.job(id) {
            $0.status = .queued
            $0.finished = nil
            $0.title = "Job \(id)"
            $0.files = files
        }
    }

    @Test func aJobHeldForASlotSaysSoAndStartsWithoutIt() async throws {
        let test = try FailureTests(signedIn: false)
        let desk = test.desk
        desk.maxRunning = 1
        desk.enqueue(queued("first", files: ["Engine/Desk.swift"]))
        try await test.until("the first runs") { desk.job("first")?.status == .running }
        #expect(desk.job("first")?.waiting == nil && desk.job("first")?.isWorking == true)
        desk.enqueue(queued("second", files: ["Engine/Jobs.swift"]))
        try await test.until("the second waits") { desk.job("second")?.waiting != nil }
        let waiting = try #require(desk.job("second"))
        #expect(waiting.status == .queued && waiting.isWaiting && !waiting.isWorking)
        #expect(waiting.waiting == Job.Waiting(kind: .cap, text: "a slot opens", job: nil))

        // Its turn: it starts, and waits for nothing.
        desk.stop("first")
        try await test.until("the second runs") { desk.job("second")?.status == .running }
        #expect(desk.job("second")?.waiting == nil)
    }

    @Test func aJobHeldBehindAnUpdateSaysSoAndStartsAfterIt() async throws {
        let test = try FailureTests(signedIn: false)
        let desk = test.desk
        desk.drainingForUpdate = true
        desk.enqueue(queued("held", files: ["Engine/Desk.swift"]))
        try await test.until("it waits for the update") { desk.job("held")?.waiting != nil }
        let held = try #require(desk.job("held"))
        #expect(held.status == .queued && held.waiting == Job.Waiting(kind: .update, text: "runner update", job: nil))
        #expect(held.step == "Waiting for runner update")
        #expect(test.made.agents.isEmpty)

        desk.cancelUpdateDrain()
        try await test.until("it runs") { desk.job("held")?.status == .running }
        #expect(desk.job("held")?.waiting == nil)
    }

    /// The API sends `waiting`, null when nothing holds the job.
    @Test func theAPISendsWhatItWaitsFor() throws {
        var job = queued("second", files: ["Engine/Desk.swift"])
        job.waiting = .slot
        let sent = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(JobJSON(job: job))) as? [String: Any])
        let waiting = try #require(sent["waiting"] as? [String: Any])
        #expect(waiting["kind"] as? String == "cap" && waiting["text"] as? String == "a slot opens" && waiting["job"] == nil)
        job.waiting = nil
        #expect(String(decoding: try JSONEncoder().encode(JobJSON(job: job)), as: UTF8.self).contains(#""waiting":null"#))
    }

    /// Only working jobs count as agents working; the ones waiting are counted apart (#238).
    @Test func theHeadlineCountsWorkingAndWaitingApart() {
        #expect(Summary.line(working: 1, waiting: 14, needs: nil) == "1 agent is working, 14 waiting. Nothing needs you.")
        #expect(Summary.line(working: 2, waiting: 1, needs: "1 job failed") == "2 agents are working, 1 waiting. 1 job failed.")
        #expect(Summary.line(working: 0, waiting: 3, needs: nil) == "3 jobs are waiting. Nothing needs you.")
        #expect(Summary.line(working: 0, waiting: 1, needs: nil) == "1 job is waiting. Nothing needs you.")
        #expect(Summary.waitingLine(14) == "14 waiting" && Summary.waitingLine(0) == nil)

        // 1 running and 14 waiting, as the briefing counts them: the brain hears the same.
        var jobs = [queued("running", files: [])]
        jobs[0].status = .running
        for index in 0..<14 {
            var job = queued("w\(index)", files: [])
            job.waiting = .update
            jobs.append(job)
        }
        let working = jobs.count(where: \.isWorking)
        let waiting = jobs.count(where: \.isWaiting)
        #expect(Summary.line(working: working, waiting: waiting, needs: nil).hasPrefix("1 agent is working, 14 waiting."))
        let briefing = Briefing(turns: [], places: [Briefing.Place(name: "tetrix-lab", jobs: jobs, inbox: [])], accounts: [])
        #expect(briefing.working == 1)
        #expect(briefing.text.contains("Working now: 1 agent is working: Job running on tetrix-lab. 14 jobs are waiting."))
        #expect(briefing.text.contains("waiting on tetrix-lab: runner update"))
    }
}
