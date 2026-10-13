import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import ObyShared
@testable import oby_runner

/// Clear done, synced through the runner: `POST /v1/clear` records when, `GET /v1/status` says
/// it, every app following events hears it, and the apps hide the jobs that finished by then
/// (Shared/JobList.swift), so clearing on the iPhone clears the Mac's island too.
@MainActor
final class ClearTests {
    let folder: URL
    let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
    /// 2026-10-09T21:42:53Z, as the docs' job was created.
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    init() throws {
        folder = try temporaryFolder()
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func api(_ cleared: Cleared? = nil) -> API {
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        return API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")), cleared: cleared)
    }

    @Test func statusSaysNullUntilTheFirstClearThenTheTime() async throws {
        let app = Application(router: api().router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            try await client.execute(uri: "/v1/status", method: .get, headers: owner) { response in
                let status = object(Data(response.body.readableBytesView))
                #expect(status.keys.contains("clearedAt") && status["clearedAt"] is NSNull)
            }
            let before = Date.now
            let answered: String? = try await client.execute(uri: "/v1/clear", method: .post, headers: owner) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                return object(Data(response.body.readableBytesView))["clearedAt"] as? String
            }
            // ISO 8601, on the runner's clock, to the second.
            let time = try #require(answered)
            let cleared = try Date(time, strategy: .iso8601)
            #expect(cleared >= before - 1 && cleared <= Date.now)
            try await client.execute(uri: "/v1/status", method: .get, headers: owner) { response in
                #expect(object(Data(response.body.readableBytesView))["clearedAt"] as? String == time)
            }
        }
    }

    @Test func theClearSurvivesARestartAndNeverGoesBack() throws {
        let file = folder.appending(path: "cleared.json")
        let first = Cleared(file: file)
        #expect(first.at == nil)
        #expect(try first.clear(now: now) == now)
        #expect(Cleared(file: file).at == now)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(#""clearedAt" : "2026-10-09T21:42:53Z""#))
        // A later clear moves it; an earlier one (a clock put right) keeps the later time.
        #expect(try first.clear(now: now + 60) == now + 60)
        #expect(try first.clear(now: now - 60) == now + 60)
        #expect(Cleared(file: file).at == now + 60)
        // Garbage in the file: nothing is cleared, and the next clear writes it afresh.
        try Data("{".utf8).write(to: file)
        let broken = Cleared(file: file)
        #expect(broken.at == nil)
        #expect(try broken.clear(now: now) == now)
        #expect(Cleared(file: file).at == now)
    }

    /// Everyone following `GET /v1/events` hears the clear, so the Mac's island clears with the iPhone's Home.
    @Test func everyAppFollowingEventsHearsAClear() async throws {
        let api = api()
        var events = api.follow().makeAsyncIterator()
        #expect(await events.next() == ": ping\n\n")
        let response = try api.clear()
        #expect(response.status == .ok)
        // The same time the answer carries, as /v1/status says it from now on.
        let time = try #require(api.cleared.at).formatted(.iso8601)
        #expect(await events.next() == "event: clear\ndata: {\"clearedAt\":\"\(time)\"}\n\n")
    }

    /// Both apps keep a job that's still running, one that finished after the clear, and every job
    /// while nothing was ever cleared; one that finished at the clear's second or before goes.
    @Test func theAppsHideWhatFinishedByTheClear() {
        #expect(!JobList.shows(finished: now - 1, clearedAt: now))
        #expect(!JobList.shows(finished: now, clearedAt: now))
        #expect(JobList.shows(finished: now + 1, clearedAt: now))
        #expect(JobList.shows(finished: nil, clearedAt: now))
        #expect(JobList.shows(finished: now - 3600, clearedAt: nil))
    }

    /// Clear done never hides a job that still needs the user: ready to publish, failed,
    /// interrupted, or out of review rounds. Only Dismiss lets those go.
    @Test func clearDoneKeepsWhatNeedsYou() {
        let cleared = now
        var done = Job(id: "a", request: "fix oby", agent: "claude", account: "default", repo: "deskree-inc/oby",
                       branch: "oby/fix-a", base: "dev", kind: .fix, task: "fix oby")
        done.status = .done
        done.finished = now - 60
        let lists = { (job: Job) in JobList.lists(settled: Self.settled(job), finished: job.finished, clearedAt: cleared) }

        var ready = done
        ready.commits = 2
        ready.publishError = "git push failed"
        var failed = done
        failed.status = .failed
        var interrupted = done
        interrupted.status = .interrupted
        var outOfRounds = done
        outOfRounds.published = "https://github.com/deskree-inc/oby/pull/80"
        outOfRounds.review = Review(verdict: .changesRequested, job: "rev4", agent: "codex", account: "Work", round: Review.maxRounds)
        var stranded = ready
        stranded.published = "https://github.com/deskree-inc/oby/pull/80"
        stranded.pushed = 1
        stranded.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: now - 120, checkedAt: now - 90)
        #expect(stranded.stranded)
        for job in [ready, failed, interrupted, outOfRounds, stranded] {
            #expect(job.needsYou && lists(job), Comment(rawValue: "\(job.status) \(job.dismissed == nil)"))
        }
        // Dismissed, they go with the rest of what finished by the clear.
        for var job in [ready, failed, interrupted, outOfRounds, stranded] {
            job.dismissed = now - 30
            #expect(!job.needsYou && !lists(job), Comment(rawValue: "\(job.status) \(job.dismissed == nil)"))
        }
        #expect(!lists(done))
        var running = done
        running.status = .running
        running.finished = nil
        #expect(lists(running))
        // Finished after the clear: listed, needing you or not.
        done.finished = now + 1
        #expect(lists(done))
        #expect(JobList.lists(settled: false, finished: now - 1, clearedAt: now))
        #expect(!JobList.lists(settled: true, finished: now - 1, clearedAt: now))
        #expect(JobList.lists(settled: false, finished: nil, clearedAt: now))
        // Clear done is offered only for what it would take: settled jobs.
        #expect(JobList.clears(settled: true))
        #expect(!JobList.clears(settled: false))
    }

    /// `Job.settled` (Shared/Runner.swift) over Engine's Job, as the Mac's island has it; the apps
    /// build that one, so the rule is tested here through `JobList.settled`.
    private static func settled(_ job: Job, among jobs: [Job] = []) -> Bool {
        let author = job.reviewOf.flatMap { id in jobs.first { $0.id == id } }
        return JobList.settled(active: job.isActive || job.waiting != nil, needsYou: job.needsYou,
                               letGo: job.dismissed != nil || job.status == .stopped,
                               openPullRequest: job.published != nil && (job.pullRequest?.state ?? .open) == .open,
                               author: author.map { settled($0) })
    }

    /// Clear done takes settled jobs (#280): everything not working, waiting or needing you. Since
    /// 2026-10-13 that includes a published job whose pull request is still open, and its review. A dismissed or stopped job goes, and so does one that ended with nothing to publish.
    @Test func clearDoneKeepsWhatIsStillInFlight() {
        var done = Job(id: "a", request: "fix oby", agent: "claude", account: "default", repo: "deskree-inc/oby",
                       branch: "oby/fix-a", base: "dev", kind: .fix, task: "fix oby")
        done.status = .done
        done.finished = now - 60
        done.commits = 1
        let cleared = now
        let lists = { (job: Job, jobs: [Job]) in JobList.lists(settled: Self.settled(job, among: jobs), finished: job.finished, clearedAt: cleared) }

        var inReview = done
        inReview.published = "https://github.com/deskree-inc/oby/pull/281"
        inReview.reviewing = "rev1"
        var review = done
        review.id = "rev1"
        review.reviewOf = inReview.id
        review.commits = 0
        // Since 2026-10-13 an open pull request clears too, with its review: Oby takes it to the
        // merge, and once it needs you it isn't settled and comes back.
        #expect(!inReview.needsYou && Self.settled(inReview) && !lists(inReview, []))
        #expect(Self.settled(review, among: [inReview]) && !lists(review, [inReview]))
        var checking = inReview
        checking.pullRequest = PullRequestStatus(state: .open, reviewDecision: .approved, base: "dev", checkedAt: now - 30)
        #expect(!checking.needsYou && !lists(checking, []))
        var waiting = done
        waiting.status = .queued
        waiting.finished = now - 60
        waiting.waiting = Job.Waiting(kind: .cap, text: "a slot opens")
        #expect(lists(waiting, []))

        // Merged or closed, it's settled: it goes, and its review with it.
        var merged = inReview
        merged.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: now - 10, checkedAt: now - 5)
        #expect(Self.settled(merged) && !lists(merged, []))
        #expect(Self.settled(review, among: [merged]) && !lists(review, [merged]))
        var closed = inReview
        closed.pullRequest = PullRequestStatus(state: .closed, base: "dev", checkedAt: now - 5)
        #expect(!lists(closed, []))
        // A review whose author isn't listed goes by its own state.
        #expect(!lists(review, []))

        // Dismissed or stopped, it goes, open pull request or not.
        var dismissed = inReview
        dismissed.dismissed = now - 30
        #expect(Self.settled(dismissed) && !lists(dismissed, []))
        var failed = done
        failed.status = .failed
        #expect(lists(failed, []))
        var letGo = failed
        letGo.dismissed = now - 30
        #expect(!lists(letGo, []))
        var stopped = inReview
        stopped.status = .stopped
        #expect(!lists(stopped, []))

        // Done with nothing to publish: no pull request and no commits left to push.
        var nothing = done
        nothing.commits = 0
        #expect(Self.settled(nothing) && !lists(nothing, []))

        // Clear done isn't offered while nothing listed is settled.
        let listed = [waiting, failed]
        #expect(!listed.contains { JobList.clears(settled: Self.settled($0, among: listed)) })
        #expect([inReview, waiting].contains { JobList.clears(settled: Self.settled($0, among: [inReview, waiting])) })
        #expect(([merged] + listed).contains { JobList.clears(settled: Self.settled($0, among: [merged] + listed)) })
    }

    /// The one line the iPhone's Home, the closed notch and the island's header all say.
    @Test func theSummaryLineIsTheSameEverywhere() {
        #expect(Summary.line(working: 0, needs: nil) == "All quiet.")
        #expect(Summary.line(working: 0, needs: "1 job failed") == "1 job failed.")
        #expect(Summary.line(working: 1, needs: nil) == "1 agent is working. Nothing needs you.")
        #expect(Summary.line(working: 2, needs: "1 job is ready to publish, 1 job failed")
                == "2 agents are working. 1 job is ready to publish, 1 job failed.")
    }

    /// The list's groups, in the order both apps show them, each keeping the order the jobs came in.
    @Test func jobsAreGroupedInTheAppsOrder() {
        struct Row: Identifiable {
            var id: String
            var group: JobGroup
        }
        let rows = [Row(id: "a", group: .done), Row(id: "b", group: .working), Row(id: "c", group: .needsYou),
                    Row(id: "d", group: .done), Row(id: "e", group: .inReview), Row(id: "f", group: .waiting)]
        let groups = JobList.groups(rows, by: \.group)
        // Working, then Waiting (#238), then Needs you.
        #expect(groups.map(\.group) == [.working, .waiting, .needsYou, .inReview, .done])
        #expect(groups.map { $0.jobs.map(\.id) } == [["b"], ["f"], ["c"], ["e"], ["a", "d"]])
        #expect(groups.map(\.id) == groups.map(\.group))
        #expect(JobList.groups([Row](), by: \.group).isEmpty)
        #expect(JobGroup.allCases.map(\.rawValue) == ["Working", "Waiting", "Needs you", "In review", "Done"])
    }
}
