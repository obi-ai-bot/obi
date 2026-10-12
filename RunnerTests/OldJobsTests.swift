import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import ObyShared
@testable import oby_runner

/// The runner keeps every job that still needs something across restarts, however old, and finds
/// any job by id (#223): the newest 50 aren't all it knows.
@MainActor
struct OldJobsTests {
    let folder: URL
    let store: JobStore
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    init() throws {
        folder = try temporaryFolder()
        store = JobStore(url: folder.appending(path: "oby.sqlite"))
    }

    /// Job #`number` of 60, the 1st the newest: done, published, its pull request open.
    func old(_ id: String, _ number: Int) -> Job {
        var old = job
        old.id = id
        old.kind = .fix
        old.pr = nil
        old.base = "dev"
        old.status = .done
        old.commits = 1
        old.created = now - Double(number) * 60
        let finished = old.created + 30
        old.finished = finished
        old.published = "https://github.com/deskree-inc/oby/pull/\(100 + number)"
        old.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: finished, checkedAt: finished)
        return old
    }

    /// 60 jobs whose pull requests were merged, but for the ones `changed` gives in their place.
    func sixty(_ changed: [Int: Job]) {
        for number in 1...60 { store.save(changed[number] ?? old("job-\(number)", number)) }
    }

    func restarted() -> Desk {
        Desk(accounts: AccountStore(root: folder), store: store, restarts: Restarts(file: folder.appending(path: "restarts.json")))
    }

    @Test func theOldestJobWithAnOpenApprovedPullRequestIsStillFollowedAfterARestart() async throws {
        var approved = old("approved", 60)
        approved.pullRequest = PullRequestStatus(state: .open, reviewDecision: .waiting, base: "dev", checkedAt: now - 3600)
        approved.review = Review(verdict: .approved, job: "its-review", agent: "claude", account: "default", round: 1)
        sixty([60: approved])
        let desk = restarted()
        #expect(desk.jobs.count == Desk.listed + 1)
        #expect(desk.jobs.last?.id == "approved")
        #expect(desk.pullRequestsToFollow.map(\.id) == ["approved"])

        var changes: [Job] = []
        desk.onJobChange = { changes.append($0) }
        let follower = PullRequests(desk: desk)
        follower.read = { _ in
            Data(#"{"state":"OPEN","reviewDecision":"APPROVED","baseRefName":"dev","mergedAt":null}"#.utf8)
        }
        await follower.poll(at: now)
        // Followed on the desk itself: what follows an approval (the Mac check, the merge) sees it.
        let followed = try #require(desk.jobs.first { $0.id == "approved" })
        #expect(followed.pullRequest?.reviewDecision == .approved)
        #expect(followed.pipeline.stages.last?.state == .current)
        #expect(changes.map(\.id) == ["approved"])
        #expect(store.job("approved")?.pullRequest?.reviewDecision == .approved)
        // And after the next restart too.
        #expect(restarted().jobs.contains { $0.id == "approved" })
    }

    @Test func everyJobThatStillNeedsSomethingIsKeptAndTheRestAreNot() {
        var interrupted = old("interrupted", 51)
        interrupted.status = .interrupted
        var running = old("running", 52)
        running.status = .running
        running.published = nil
        running.pullRequest = nil
        var failed = old("failed", 53)
        failed.status = .failed
        var dismissed = old("dismissed", 54)
        dismissed.status = .failed
        dismissed.dismissed = now
        var open = old("open", 55)
        open.pullRequest = nil
        var closed = old("closed", 56)
        closed.pullRequest?.state = .closed
        closed.pullRequest?.mergedAt = nil
        sixty([51: interrupted, 52: running, 53: failed, 54: dismissed, 55: open, 56: closed])
        let desk = Desk(accounts: AccountStore(root: folder), store: store)
        #expect(desk.jobs.prefix(Desk.listed).map(\.id) == (1...50).map { "job-\($0)" })
        #expect(desk.jobs.dropFirst(Desk.listed).map(\.id) == ["interrupted", "running", "failed", "open"])
        // On the Mac, the one that was running when Oby quit didn't finish.
        #expect(desk.job("running")?.status == .interrupted)
        #expect(store.job("running")?.status == .interrupted)
    }

    @Test func theAPIFindsAndDismissesJob60() async throws {
        var failed = old("failed", 60)
        failed.status = .failed
        failed.summary = "Couldn't finish: the check failed."
        sixty([60: failed])
        let desk = restarted()
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
        // Job #59, merged long ago and needing nothing, isn't on the list, and is found too: by id, from the store.
        #expect(!desk.jobs.contains { $0.id == "job-59" })
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/jobs/job-59", method: .get, headers: owner) { response in
                #expect(response.status == .ok)
                #expect(object(Data(response.body.readableBytesView))["id"] as? String == "job-59")
            }
            try await client.execute(uri: "/v1/jobs/failed", method: .get, headers: owner) { response in
                #expect(response.status == .ok)
                #expect(object(Data(response.body.readableBytesView))["status"] as? String == "failed")
            }
            try await client.execute(uri: "/v1/jobs/failed/dismiss", method: .post, headers: owner) { response in
                #expect(response.status == .ok)
                #expect((object(Data(response.body.readableBytesView))["dismissed"] as? String)?.hasSuffix("Z") == true)
            }
            try await client.execute(uri: "/v1/jobs/nowhere", method: .get, headers: owner) { response in
                #expect(response.status == .notFound)
            }
        }
        #expect(store.job("failed")?.dismissed != nil)
        // Dismissed, it needs nothing: the next restart leaves it with the others.
        #expect(!restarted().jobs.contains { $0.id == "failed" })
    }

    @Test func aJobFoundByIdIsKeptLikeAnyOther() throws {
        var failed = old("failed", 60)
        failed.status = .failed
        sixty([:])
        let desk = Desk(accounts: AccountStore(root: folder), store: store)
        // Saved behind the desk's back (another process, an old runner), it's still found and dismissed.
        store.save(failed)
        try desk.dismiss("failed")
        #expect(desk.jobs.filter { $0.id == "failed" }.count == 1)
        #expect(store.job("failed")?.dismissed != nil)
        #expect(desk.job("nowhere") == nil)
    }

    @Test func aJobTheRunnerAnswers404ForLeavesTheMacsNeedsYou() {
        var gone = old("gone", 60)
        gone.status = .failed
        let list = [old("job-1", 1), gone]
        #expect(list.filter(\.needsYou).map(\.id) == ["gone"])
        let after = JobList.answered(404, about: "gone", in: list, id: \.id)
        #expect(after.map(\.id) == ["job-1"])
        #expect(after.filter(\.needsYou).isEmpty)
        // Any other answer (the runner down, a conflict) keeps it.
        for status in [nil, 409, 500] {
            #expect(JobList.answered(status, about: "gone", in: list, id: \.id).map(\.id) == ["job-1", "gone"])
        }
    }
}
