import Foundation
import Testing
@testable import ObyEngine

@MainActor
struct CleanupTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func candidate(_ id: String, finished: TimeInterval = -25 * 60 * 60) -> Job {
        var job = Job(id: id, request: "cleanup", agent: "claude", account: "default", repo: "deskree-inc/oby", branch: "oby/\(id)", kind: .fix, task: "cleanup")
        job.status = .done
        let ended = now.addingTimeInterval(finished)
        job.finished = ended
        job.pullRequest = PullRequestStatus(state: .merged, base: "dev", checkedAt: ended)
        return job
    }

    @Test func oldSettledWorktreesGoButRecentOpenAndNeededStay() async {
        let cleanup = WorktreeCleanup(root: URL(filePath: "/tmp/oby-cleanup-test"), clock: { self.now })
        var removed: [String] = []
        cleanup.remove = { removed.append($0.id); return true }
        var recent = candidate("recent", finished: -23 * 60 * 60)
        recent.pullRequest?.state = .open
        var open = candidate("open")
        open.pullRequest?.state = .open
        var needsYou = candidate("needs-you")
        needsYou.status = .failed
        needsYou.pullRequest = nil
        let stopped = { () -> Job in var job = candidate("stopped"); job.status = .stopped; job.pullRequest = nil; return job }()
        await cleanup.run(jobs: [candidate("merged"), recent, open, needsYou, stopped]) { $0 == "stopped" }
        #expect(removed == ["merged"])
    }

    @Test func reviewWorktreeGoesWhenVerdictArrivesAndInUseWins() async {
        let cleanup = WorktreeCleanup(root: URL(filePath: "/tmp/oby-cleanup-test"), clock: { self.now })
        var removed: [String] = []
        cleanup.remove = { removed.append($0.id); return true }
        var review = candidate("review")
        review.reviewOf = "author"
        review.review = Review(verdict: .approved, job: review.id, agent: "codex", account: "default", round: 1)
        await cleanup.run(jobs: [review, candidate("busy")]) { $0 == "busy" }
        #expect(removed == ["review"])
    }
}
