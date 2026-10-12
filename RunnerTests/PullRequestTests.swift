import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

@MainActor
struct PullRequestTests {
    let folder: URL
    let store: JobStore
    let desk: Desk
    let follower: PullRequests
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    init() throws {
        folder = try temporaryFolder()
        store = JobStore(url: folder.appending(path: "oby.sqlite"))
        var published = job
        published.id = "published"
        published.status = .done
        published.base = "dev"
        published.commits = 2
        published.session = "session"
        // The input PR is 33; the published PR is 99. Follow the latter.
        published.published = "https://github.com/deskree-inc/oby/pull/99"
        store.save(published)
        desk = Desk(accounts: AccountStore(root: folder), store: store)
        follower = PullRequests(desk: desk)
    }

    func response(_ state: String = "OPEN", review: String = "", merged: Bool = false) -> Data {
        Data("""
            {"state":"\(state)","reviewDecision":"\(review)","baseRefName":"dev",
             "mergedAt":\(merged ? "\"2026-10-09T21:42:53Z\"" : "null")}
            """.utf8)
    }

    @Test func pollsThePublishedPRAndPersistsReviewAndMerge() async throws {
        var arguments: [[String]] = []
        var changes: [Job] = []
        desk.onJobChange = { changes.append($0) }
        follower.read = { args in arguments.append(args); return response(review: "REVIEW_REQUIRED") }
        await follower.poll(at: now)
        #expect(arguments == [["gh", "pr", "view", "99", "--repo", "deskree-inc/oby", "--json", "state,reviewDecision,mergedAt,baseRefName,headRefOid"]])
        #expect(desk.job("published")?.pullRequest?.state == .open)
        #expect(changes.count == 1)
        await follower.poll(at: now + 179)
        #expect(arguments.count == 1)
        follower.read = { _ in response(review: "CHANGES_REQUESTED") }
        await follower.poll(at: now + 180)
        #expect(desk.job("published")?.pullRequest?.reviewDecision == .changesRequested)
        follower.read = { _ in response(review: "APPROVED") }
        await follower.poll(at: now + 360)
        #expect(desk.job("published")?.pipeline.stages.last?.state == .current)
        follower.read = { _ in response("MERGED", review: "APPROVED", merged: true) }
        await follower.poll(at: now + 540)
        let saved = try #require(store.recent().first)
        #expect(saved.pullRequest?.state == .merged && saved.pullRequest?.mergedAt != nil)
        #expect(saved.pullRequest?.checkedAt == now + 540)
        #expect(saved.pipeline.stages.last?.state == .done)
        #expect(changes.count == 4)
        follower.read = { _ in Issue.record("Merged PR must not be polled again"); return Data() }
        await follower.poll(at: now + 720)
        let restarted = Desk(accounts: AccountStore(root: folder), store: store)
        #expect(restarted.job("published")?.pullRequest == saved.pullRequest)
        #expect(restarted.pullRequestsToFollow.isEmpty)
    }

    @Test func failuresKeepLastKnownStatusAndRetryWithoutLeakingToolOutput() async throws {
        follower.read = { _ in response(review: "APPROVED") }
        await follower.poll(at: now)
        let previous = desk.job("published")?.pullRequest
        var attempts = 0
        follower.read = { _ in attempts += 1; throw Shell.Failure(message: "Private tool output") }
        await follower.poll(at: now + 180)
        #expect(desk.job("published")?.pullRequest == previous)
        #expect(desk.job("published")?.pullRequestError == "Couldn't refresh the pull request. Will try again shortly.")
        await follower.poll(at: now + 200)
        #expect(attempts == 1)
        follower.read = { _ in Data("not JSON".utf8) }
        await follower.poll(at: now + 360)
        #expect(desk.job("published")?.pullRequest == previous)
        follower.read = { _ in response(review: "CHANGES_REQUESTED") }
        await follower.poll(at: now + 540)
        #expect(desk.job("published")?.pullRequestError == nil)
        #expect(store.recent().first?.pullRequest?.reviewDecision == .changesRequested)
    }

    @Test func aClosedPRStopsPollingAndSkipsTheMergeStage() async {
        follower.read = { _ in response("CLOSED") }
        await follower.poll(at: now)
        #expect(desk.pullRequestsToFollow.isEmpty)
        #expect(desk.job("published")?.pipeline.stages.last?.state == .skipped)
    }

    @Test func restartFollowsOldJobsBeyondTheRecentList() async throws {
        for index in 0..<55 {
            var newer = job
            newer.id = "new-\(index)"
            newer.created = now + Double(index + 1)
            newer.status = .done
            store.save(newer)
        }
        let restarted = Desk(accounts: AccountStore(root: folder), store: store)
        // Older than the newest 50, and kept on the list: its pull request is open (#223).
        #expect(restarted.jobs.prefix(Desk.listed).allSatisfy { $0.id != "published" })
        #expect(restarted.jobs.last?.id == "published")
        let follower = PullRequests(desk: restarted)
        var calls = 0
        follower.read = { _ in calls += 1; return response(review: "APPROVED") }
        await follower.poll(at: now)
        #expect(calls == 1)
        #expect(store.recent(-1).first { $0.id == "published" }?.pullRequest?.reviewDecision == .approved)
        let again = PullRequests(desk: restarted)
        again.read = { _ in Issue.record("Fresh persisted observation should wait"); return Data() }
        await again.poll(at: now + 10)
    }

    @Test func aJobResumingDuringTheReadKeepsItsNewState() async throws {
        desk.makeAgent = { _, _, _ in PublishOnItsOwnTests.Agent() }
        follower.read = { _ in
            try desk.message("published", "Fix the review comments")
            return response(review: "CHANGES_REQUESTED")
        }
        await follower.poll(at: now)
        let latest = try #require(desk.job("published"))
        #expect(latest.status == .running && latest.round == 2)
        #expect(latest.notes == ["Fix the review comments"])
        #expect(latest.pullRequest?.reviewDecision == .changesRequested)
        #expect(latest.pipeline.number == 2)
    }

    @Test func staleObservationsForAnotherPRDontReplaceTheJob() {
        desk.followed("published", published: "https://github.com/deskree-inc/oby/pull/100",
                      pushed: 2, status: PullRequestStatus(state: .closed, base: "dev", checkedAt: now), error: nil)
        #expect(desk.job("published")?.pullRequest == nil)
    }

    @Test func observationsFromBeforeNewCommitsWerePublishedAreIgnored() {
        desk.followed("published", published: "https://github.com/deskree-inc/oby/pull/99", pushed: 1,
                      status: PullRequestStatus(state: .open, reviewDecision: .approved, base: "dev", checkedAt: now), error: nil)
        #expect(desk.job("published")?.pullRequest == nil)
    }

    @Test func overlappingPollsReadOnlyOnce() async {
        var calls = 0
        follower.read = { _ in
            calls += 1
            await follower.poll(at: now + 180)
            return response()
        }
        await follower.poll(at: now)
        #expect(calls == 1)
    }

    @Test func invalidOrForeignURLsNeverReachGh() throws {
        for url in ["--help", "https://example.com/deskree-inc/oby/pull/1", "https://github.com/other/repo/pull/1",
                    "https://github.com/deskree-inc/oby/pull/0", "https://github.com/deskree-inc/oby/issues/1",
                    "https://github.com/deskree-inc/oby/pull/1?x=2", "https://user@github.com/deskree-inc/oby/pull/1"] {
            var value = job
            value.published = url
            #expect(throws: Shell.Failure.self) { try PullRequests.arguments(for: value) }
        }
    }

    @Test func emptyReviewIsWaitingAndIncompleteResponsesAreRejected() throws {
        #expect(try PullRequests.decode(response(), at: now).reviewDecision == nil)
        #expect(throws: (any Error).self) { try PullRequests.decode(response("MERGED"), at: now) }
        #expect(throws: (any Error).self) { try PullRequests.decode(response("UNKNOWN"), at: now) }
        #expect(throws: (any Error).self) { try PullRequests.decode(Data("{}".utf8), at: now) }
    }
}
