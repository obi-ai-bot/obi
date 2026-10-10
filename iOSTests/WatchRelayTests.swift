import Foundation
import Testing
@testable import Oby

/// What the phone keeps on the watch: the jobs it shows, within what WatchConnectivity carries.
struct WatchRelayTests {
    private func job(_ id: String, status: Job.Status, finished: Date? = nil, summary: String = "") -> Job {
        Job(id: id, request: "Review oby PR #33", agent: "claude", account: "default", repo: "deskree-inc/oby", branch: "oby/review-33",
            base: "dev", pr: 33, kind: "review", task: "Review pull request #33", status: status, step: "", summary: summary,
            created: .now, finished: finished, notes: ["Also test the empty case."])
    }

    @Test func keepsWhatTheWatchShowsAndDropsTheLongTexts() throws {
        let long = String(repeating: "x", count: 5_000)
        let context = WatchContext(jobs: [
            job("running", status: .running, summary: long),
            job("old", status: .done, finished: .now.addingTimeInterval(-10 * 86400)),
            job("recent", status: .done, finished: .now.addingTimeInterval(-3600)),
        ], accounts: [], host: "tetrix-lab", sentAt: .now)
        let data = try WatchRelay.fit(context)
        let kept = try Runner.decoder.decode(WatchContext.self, from: data)
        #expect(kept.jobs.map(\.id) == ["running", "recent"])
        #expect(kept.jobs[0].summary.count == 600)
        #expect(kept.jobs[0].notes == nil)
        #expect(kept.host == "tetrix-lab")
    }

    @Test func dropsTheOldestUntilItFits() throws {
        let jobs = (0..<20).map { job("j\($0)", status: .running, summary: String(repeating: "y", count: 600)) }
        let context = WatchContext(jobs: jobs, accounts: [], host: "tetrix-lab", sentAt: .now)
        let data = try WatchRelay.fit(context, limit: 4_000)
        #expect(data.count <= 4_000)
        let kept = try Runner.decoder.decode(WatchContext.self, from: data)
        #expect(!kept.jobs.isEmpty)
        #expect(kept.jobs.first?.id == "j0")
    }

    @Test func relayedPlanMirrorsEveryAnswer() throws {
        let question = Question(text: "Which repository?", options: ["deskree-inc/oby"])
        let asked = RelayedPlan(.question(said: "Review PR 12", question))
        let again = try Runner.decoder.decode(RelayedPlan.self, from: Runner.encoder.encode(asked))
        #expect(again.question == question)
        #expect(again.questionSaid == "Review PR 12")
        #expect(RelayedPlan(.reply("Oby can't merge.")).reply == "Oby can't merge.")
        #expect(RelayedPlan(.none) == RelayedPlan(.none))
    }
}
