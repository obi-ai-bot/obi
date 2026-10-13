import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// A job that needs the user can be let go: Dismiss keeps it, and it stops needing them (Home's
/// header, the alert, the Mac notification, Publish) until they tell it something.
@MainActor
struct DismissTests {
    /// A ready-to-publish fix job, a failed one and an interrupted one, as the desk lists them.
    var ready: Job {
        var job = job
        job.id = "ready"
        job.kind = .fix
        job.pr = nil
        job.base = "dev"
        job.status = .done
        job.commits = 2
        job.publishError = "Couldn't push oby/fix-75: the remote hung up."
        job.finished = .now
        return job
    }
    var failed: Job {
        var job = job
        job.id = "failed"
        job.kind = .fix
        job.pr = nil
        job.base = "dev"
        job.status = .failed
        job.phase = .work
        job.summary = "Nothing committed: the branch was reset."
        job.finished = .now
        return job
    }
    var interrupted: Job {
        var job = job
        job.id = "interrupted"
        job.status = .interrupted
        job.phase = .work
        job.summary = "Oby quit while this was running."
        job.finished = .now
        return job
    }

    func makeDesk(_ jobs: [Job]) throws -> (Desk, URL) {
        let folder = try temporaryFolder()
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        for job in jobs { store.save(job) }
        return (Desk(accounts: AccountStore(root: folder), store: store), folder)
    }

    @Test func aDismissedJobNeedsNothing() {
        for var job in [ready, failed, interrupted] {
            #expect(job.needsYou && Push.notice(for: job) != nil)
            job.dismissed = .now
            #expect(!job.needsYou && !job.canPublish)
            #expect(Push.notice(for: job) == nil, "\(job.id)")
            // Still how it ended.
            #expect(job.status == [ready, failed, interrupted].first { $0.id == job.id }?.status)
        }
        // Dismissed ones don't count among the others (NeedsYou.line, in the apps, counts `needsYou`).
        var gone = failed
        gone.dismissed = .now
        #expect([ready, gone, interrupted].filter(\.needsYou).map(\.id) == ["ready", "interrupted"])
    }

    @Test func thePipelineShowsPublishAsDismissed() {
        func stage(_ id: JobStage.ID, in job: Job) -> JobStage? { job.pipeline.stages.first { $0.id == id } }
        var ready = ready
        #expect(stage(.publish, in: ready)?.state == .failed && stage(.publish, in: ready)?.reason == ready.publishError)
        ready.dismissed = .now
        #expect(stage(.publish, in: ready)?.state == .skipped && stage(.publish, in: ready)?.detail == "Dismissed")
        #expect(stage(.publish, in: ready)?.reason == nil)
        #expect(stage(.review, in: ready)?.state == .skipped && stage(.merged, in: ready)?.state == .skipped)
        #expect(ready.pipeline.label == "Stage 5 of 5")

        var failed = failed
        failed.dismissed = .now
        // The failure stays where it was, with its reason.
        #expect(stage(.work, in: failed)?.state == .failed && stage(.work, in: failed)?.reason == failed.summary)
        #expect(stage(.publish, in: failed)?.state == .skipped && stage(.publish, in: failed)?.detail == "Dismissed")
        #expect(failed.pipeline.label == "Stage 2 of 5")

        // A failed publish (a possible secret) keeps why, and still says Dismissed.
        var secret = failed
        secret.phase = .publish
        secret.summary = "Not published: possible secret in Engine/Keys.swift:12 (AWS access key)."
        #expect(stage(.publish, in: secret)?.state == .skipped && stage(.publish, in: secret)?.detail == "Dismissed")
        #expect(stage(.publish, in: secret)?.reason == secret.summary)

        // A published job with later commits let go keeps its pull request's progress.
        var published = self.ready
        published.published = "https://github.com/deskree-inc/oby/pull/42"
        published.pushed = 1
        published.publishError = nil
        #expect(published.canPublish)
        published.dismissed = .now
        #expect(!published.canPublish && stage(.publish, in: published)?.state == .done && stage(.review, in: published)?.state == .current)
    }

    @Test func onlyAJobThatNeedsYouIsDismissed() throws {
        var quiet = job
        quiet.id = "quiet"
        quiet.status = .done
        quiet.base = "dev"
        quiet.commits = 0
        quiet.finished = .now
        var stopped = job
        stopped.id = "stopped"
        stopped.status = .stopped
        stopped.finished = .now
        let (desk, folder) = try makeDesk([ready, failed, interrupted, quiet, stopped])
        defer { try? FileManager.default.removeItem(at: folder) }
        let alerted = Push.notices(desk.jobs, after: [:]).notified
        #expect(alerted.count == 3)

        for id in ["ready", "failed", "interrupted"] {
            try desk.dismiss(id)
            let job = try #require(desk.job(id))
            #expect(job.dismissed != nil && !job.needsYou, "\(id)")
        }
        // Their alerts clear, and nothing else changes.
        let cleared = Push.notices(desk.jobs, after: alerted)
        #expect(cleared.changes.count == 3 && cleared.changes.allSatisfy { $0.1 == nil } && cleared.notified.isEmpty)
        // Again is fine, and keeps the first time.
        let when = desk.job("ready")?.dismissed
        try desk.dismiss("ready")
        #expect(desk.job("ready")?.dismissed == when)
        for id in ["quiet", "stopped", "nowhere"] {
            #expect(throws: Shell.Failure.self, "\(id)") { try desk.dismiss(id) }
        }
        // Kept, as it ended.
        #expect(desk.job("failed")?.status == .failed && desk.job("failed")?.summary == failed.summary)
        // Saved: a restart still knows.
        let again = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        #expect(again.job("ready")?.dismissed == when && again.job("interrupted")?.needsYou == false)
    }

    @Test func aRunningJobIsntDismissedButStopped() async throws {
        let (desk, folder) = try makeDesk([])
        defer { try? FileManager.default.removeItem(at: folder) }
        let (held, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        desk.prepare = { job in
            for await _ in held {}
            return job
        }
        desk.dispatch(job)
        let error = #expect(throws: Shell.Failure.self) { try desk.dismiss(job.id) }
        #expect(error?.message == "It's still running: stop it instead.")
    }

    /// Telling a dismissed job something picks it up again, and it's the user's again.
    @Test func aMessageUndismisses() throws {
        var gemini = failed
        gemini.id = "gemini"
        gemini.agent = "gemini"
        gemini.session = "e6a24229"
        let (desk, folder) = try makeDesk([gemini])
        defer { try? FileManager.default.removeItem(at: folder) }
        try desk.dismiss("gemini")
        #expect(desk.job("gemini")?.dismissed != nil)
        // Gemini can't run jobs yet, so it fails at once: but it isn't dismissed any more.
        try desk.message("gemini", "try again")
        let again = try #require(desk.job("gemini"))
        #expect(again.dismissed == nil && again.status == .failed && again.needsYou)
        #expect(Desk.resumed({ var job = failed; job.dismissed = .now; return job }(), "go").dismissed == nil)
    }

    @Test func theAPIDismissesAndSaysWhenItCant() async throws {
        var quiet = job
        quiet.id = "quiet"
        quiet.status = .done
        quiet.base = "dev"
        quiet.commits = 0
        quiet.finished = .now
        let (desk, folder) = try makeDesk([ready, quiet])
        defer { try? FileManager.default.removeItem(at: folder) }
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
        try await app.test(.router) { client in
            func post(_ id: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                try await client.execute(uri: "/v1/jobs/\(id)/dismiss", method: .post, headers: owner) { response in
                    (response.status, object(Data(response.body.readableBytesView)))
                }
            }
            let (status, dismissed) = try await post("ready")
            #expect(status == .ok && dismissed["id"] as? String == "ready")
            #expect((dismissed["dismissed"] as? String)?.hasSuffix("Z") == true)
            #expect(((dismissed["pipeline"] as? [String: Any])?["stages"] as? [[String: Any]])?.first { $0["id"] as? String == "publish" }?["detail"] as? String == "Dismissed")
            #expect(try await post("nowhere").0 == .notFound)
            let (refused, why) = try await post("quiet")
            #expect(refused == .conflict && (why["error"] as? String)?.contains("doesn't need you") == true)
            // Publish by hand is off a dismissed job.
            try await client.execute(uri: "/v1/jobs/ready/publish", method: .get, headers: owner) { response in
                #expect(response.status == .conflict)
            }
        }
    }
}

/// A round the user started with a message is theirs: one that only resets or drops the work, on
/// their request, ends done, not "nothing committed".
@MainActor
struct UsersRoundTests {
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws { self.onEvent = onEvent }
        func send(_ text: String) {}
        func end() {}
        func stop() {}
        func kill() {}
    }

    @Test func theRuleItself() {
        let fix = Job(id: "ab12cd34", request: "work on oby #62", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-62", base: "dev", kind: .fix, task: "Work on #62")
        #expect(Job.ending(fix, .done, "Reset the branch to dev: the work is in #85.", made: 0).0 == .failed)
        #expect(Job.ending(fix, .done, "Reset the branch to dev: the work is in #85.", made: 0, asked: true)
                == (.done, "Reset the branch to dev: the work is in #85."))
        // Failures and other kinds are what they are.
        #expect(Job.ending(fix, .failed, "Tests fail.", made: 0, asked: true) == (.failed, "Tests fail."))
    }

    @Test func aResetOnRequestEndsDone() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let agent = Agent()
        desk.makeAgent = { _, _, _ in agent }
        desk.prepare = { $0 }
        desk.countCommits = { _, _ in 1 }
        desk.publishOnItsOwn = { _, _, _ in URL(string: "https://github.com/deskree-inc/oby/pull/80")! }
        var fix = job
        fix.id = "reset"
        fix.kind = .fix
        fix.pr = nil
        fix.base = "dev"
        fix.branch = "oby/fix-75"
        desk.dispatch(fix)
        for _ in 0..<500 where desk.job("reset")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        agent.onEvent(.session("e6a24229"))
        agent.onEvent(.turnEnded(summary: "fix(engine): dismiss", failed: false))
        agent.onEvent(.finished(summary: "fix(engine): dismiss", failed: false))
        for _ in 0..<500 where desk.job("reset")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(desk.job("reset")?.status == .done && desk.job("reset")?.commits == 1)

        // The work landed in another pull request: the user has the branch reset.
        desk.countCommits = { _, _ in 0 }
        try desk.message("reset", "The work is in #85 already. Reset this branch to dev and drop the commit.")
        for _ in 0..<500 where desk.job("reset")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        agent.onEvent(.turnEnded(summary: "Reset oby/fix-75 to origin/dev; nothing left to publish.", failed: false))
        agent.onEvent(.finished(summary: "Reset oby/fix-75 to origin/dev; nothing left to publish.", failed: false))
        for _ in 0..<500 where desk.job("reset")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        let ended = try #require(desk.job("reset"))
        #expect(ended.status == .done && ended.commits == 0)
        #expect(ended.summary == "Reset oby/fix-75 to origin/dev; nothing left to publish.")
        #expect(!ended.needsYou && !ended.canPublish && Push.notice(for: ended) == nil)

        // A fresh job that commits nothing is still nothing committed.
        var empty = fix
        empty.id = "empty"
        desk.dispatch(empty)
        for _ in 0..<500 where desk.job("empty")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        agent.onEvent(.turnEnded(summary: "Couldn't commit.", failed: false))
        agent.onEvent(.finished(summary: "Couldn't commit.", failed: false))
        for _ in 0..<500 where desk.job("empty")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(desk.job("empty")?.status == .failed && desk.job("empty")?.summary.hasPrefix("Nothing committed:") == true)
    }
}
