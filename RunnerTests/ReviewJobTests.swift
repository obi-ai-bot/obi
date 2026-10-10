import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

/// Oby's own review never publishes: its worktree holds the pull request's commits, not its own.
@MainActor
struct ReviewJobTests {
    private func review(reviewOf: String?) -> Job {
        var job = Job(id: "re12cd34", request: "Review oby #90", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/review-90", base: "dev", kind: .review, task: "Review #90")
        job.status = .done
        job.commits = 4
        job.reviewOf = reviewOf
        return job
    }

    @Test func reviewsNeverPublishOrNeedYou() {
        let job = review(reviewOf: "bed8add6")
        #expect(!job.canPublish && !job.needsYou && Push.notice(for: job) == nil)
    }

    @Test func theRunnerSaysAReviewMadeNoCommits() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JobJSON(job: review(reviewOf: "bed8add6")))) as? [String: Any]
        #expect(json?["commits"] as? Int == 0)
    }
}
