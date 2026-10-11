import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

@MainActor
struct UpdateTests {
    final class Fake {
        var head = String(repeating: "a", count: 40)
        var failed: [String]?
        var calls: [([String], URL)] = []
        var installs = 0
        var restarts = 0
        var resumes: [String?] = []
        var agents: [CutOffTests.Agent] = []
    }

    let folder: URL
    let desk: Desk
    let updates: Updates
    let fake = Fake()

    init() throws {
        folder = try temporaryFolder()
        desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let root = folder.appending(path: "updates")
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appending(path: ".build/release"), withIntermediateDirectories: true)
        try Data("new binary".utf8).write(to: source.appending(path: ".build/release/oby-runner"))
        let binary = folder.appending(path: "oby-runner")
        try Data("old binary".utf8).write(to: binary)
        updates = Updates(desk: desk, root: root, binary: binary)
        updates.command = { [fake] args, directory in
            fake.calls.append((args, directory))
            if args == fake.failed { throw Shell.Failure(message: "fake failure") }
            return args.prefix(2) == ["git", "rev-parse"] ? fake.head : ""
        }
        updates.install = { [fake] source, target in
            fake.installs += 1
            try Updates.install(source, target)
        }
        updates.restart = { [fake] in fake.restarts += 1 }
        desk.prepare = { $0 }
        desk.makeAgent = { [fake] _, _, resume in
            fake.resumes.append(resume)
            let agent = CutOffTests.Agent()
            fake.agents.append(agent)
            return agent
        }
    }

    @Test func buildsThenTestsInOwnCheckoutAndInstallsAtomically() async throws {
        await updates.poll()
        #expect(fake.calls.map { $0.0 }.suffix(2) == [["swift", "build", "-c", "release"], ["swift", "test"]])
        #expect(fake.calls.allSatisfy { $0.1 == updates.root.appending(path: "source") })
        #expect(fake.installs == 1 && fake.restarts == 1)
        #expect(try String(contentsOf: updates.binary, encoding: .utf8) == "new binary")
        let restarted = Updates(desk: desk, root: updates.root, binary: updates.binary)
        #expect(restarted.status.commit == fake.head)
        #expect(restarted.state.resume.isEmpty)
        await updates.poll()
        #expect(fake.installs == 1)
    }

    @Test(arguments: [["swift", "build", "-c", "release"], ["swift", "test"]])
    func failureKeepsOldBinaryAndOneInboxItemThenNextCommitRetries(step: [String]) async throws {
        fake.failed = step
        await updates.poll()
        await updates.poll()
        #expect(fake.installs == 0 && fake.restarts == 0)
        #expect(try String(contentsOf: updates.binary, encoding: .utf8) == "old binary")
        #expect(desk.inbox.count == 1)
        #expect(desk.inbox.first?.text.contains(step.joined(separator: " ")) == true)
        #expect(!desk.drainingForUpdate && updates.status.waiting == nil)
        let buildCalls = fake.calls.filter { $0.0 == step }.count
        let restarted = Updates(desk: desk, root: updates.root, binary: updates.binary)
        restarted.command = updates.command
        await restarted.poll()
        #expect(fake.calls.filter { $0.0 == step }.count == buildCalls)
        fake.head = String(repeating: "b", count: 40)
        fake.failed = nil
        await updates.poll()
        #expect(fake.installs == 1 && fake.restarts == 1)
    }

    func startJob(_ id: String = "updating", rounds: Int? = nil) async throws {
        var work = job
        work.id = id
        work.rounds = rounds
        desk.dispatch(Desk.Draft(said: "review", reply: "", job: work, guessed: false))
        for _ in 0..<500 where fake.agents.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let agent = try #require(fake.agents.first)
        agent.onEvent(.session("own-session"))
    }

    @Test func drainsRunningWorkAndDefersNewReviews() async throws {
        try await startJob()
        await updates.poll()
        #expect(updates.status.phase == "draining" && updates.status.waiting == fake.head)
        #expect(fake.installs == 0 && desk.drainingForUpdate)
        var review = job
        review.id = "queued-review"
        desk.dispatch(Desk.Draft(said: "review", reply: "", job: review, guessed: false))
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.agents.count == 1 && desk.job(review.id)?.status == .queued)
        fake.agents[0].onEvent(.finished(summary: "Reviewed", failed: false))
        for _ in 0..<500 where desk.job("updating")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        updates.deployIfReady()
        #expect(fake.installs == 1 && fake.restarts == 1)
        #expect(updates.state.resume == ["queued-review"])
    }

    @Test func nextRoundWaitsDuringDrain() async throws {
        try await startJob(rounds: 3)
        await updates.poll()
        fake.agents[0].onEvent(.turnEnded(summary: "GOAL NOT MET: more work", failed: false))
        for _ in 0..<500 where !desk.updateIsIdle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(desk.updateIsIdle)
        #expect(desk.job("updating")?.currentRound == 2)
        #expect(fake.agents.count == 1)
        updates.deployIfReady()
        #expect(fake.restarts == 1 && updates.state.resume == ["updating"])
    }

    @Test func drainCapRestartsAndRecoversTheSameSessionWithoutAnotherRound() async throws {
        try await startJob()
        let date = Date()
        updates.now = { date }
        await updates.poll()
        updates.now = { date.addingTimeInterval(Updates.drainLimit - 1) }
        updates.deployIfReady()
        #expect(fake.restarts == 0)
        updates.now = { date.addingTimeInterval(Updates.drainLimit) }
        updates.deployIfReady()
        #expect(fake.restarts == 1 && updates.state.resume == ["updating"])
        let restored = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")),
                            updateRecovery: Updates.recoveryIDs(root: updates.root))
        restored.makeAgent = desk.makeAgent
        let newer = Updates(desk: restored, root: updates.root, binary: updates.binary)
        try newer.recover()
        #expect(fake.resumes.last == "own-session")
        #expect(fake.agents.last?.prompt == "the runner restarted for an update: pick up where you left off")
        #expect(restored.job("updating")?.currentRound == 1)
        #expect(restored.job("updating")?.status == .running)
        #expect(restored.inbox.filter(\.isOpen).isEmpty)
        try newer.recover()
        #expect(fake.agents.count == 2)
        restored.quit()
    }

    @Test func installFailureReleasesDrainAndRetainsProvenance() async throws {
        updates.install = { _, _ in throw Shell.Failure(message: "read only") }
        await updates.poll()
        #expect(fake.restarts == 0 && !desk.drainingForUpdate)
        #expect(updates.state.installed == nil && updates.state.resume.isEmpty)
        #expect(desk.inbox.first?.text.contains("install") == true)
        #expect(try String(contentsOf: updates.binary, encoding: .utf8) == "old binary")
    }

    @Test func statusExposesVersionCommitAndPendingUpdate() async throws {
        try await startJob()
        await updates.poll()
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        api.updates = updates
        let expectedVersion = API.version
        let expectedHead = fake.head
        let app = Application(router: api.router(owner: "owner"))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/status", method: .get, headers: [.tailscaleUserLogin: "owner"]) { response in
                #expect(response.status == .ok)
                let runner = try #require(object(Data(response.body.readableBytesView))["runner"] as? [String: Any])
                #expect(runner["version"] as? String == expectedVersion)
                let update = try #require(runner["update"] as? [String: Any])
                #expect(update["commit"] is NSNull)
                #expect(update["waiting"] as? String == expectedHead)
                #expect(update["phase"] as? String == "draining")
            }
        }
        desk.quit()
    }

    @Test func failedInstallResumesDeferredRounds() async throws {
        try await startJob(rounds: 3)
        updates.install = { _, _ in throw Shell.Failure(message: "read only") }
        await updates.poll()
        fake.agents[0].onEvent(.turnEnded(summary: "GOAL NOT MET: more work", failed: false))
        for _ in 0..<500 where !desk.updateIsIdle { try await Task.sleep(for: .milliseconds(10)) }
        updates.deployIfReady()
        #expect(!desk.drainingForUpdate && fake.agents.count == 2)
        #expect(fake.resumes.last == "own-session")
        #expect(fake.agents.last?.prompt == "Keep going: more work")
        desk.quit()
    }

    @Test func questionsWaitForTheUserAfterUpdate() async throws {
        try await startJob()
        fake.agents[0].onEvent(.turnEnded(summary: "QUESTION: Which option?\nOPTIONS: One | Two", failed: false))
        await updates.poll()
        #expect(fake.restarts == 1)
        let restored = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")),
                            updateRecovery: Updates.recoveryIDs(root: updates.root))
        restored.makeAgent = desk.makeAgent
        let newer = Updates(desk: restored, root: updates.root, binary: updates.binary)
        try newer.recover()
        #expect(fake.agents.count == 1)
        #expect(restored.job("updating")?.question?.text == "Which option?")
        #expect(restored.inbox.contains { $0.kind == .question && $0.isOpen })
        try restored.message("updating", "One")
        #expect(fake.resumes.last == "own-session" && fake.agents.count == 2)
        restored.quit()
    }

    @Test func preparedQueuedJobsReuseTheirWorktreeAfterRestart() throws {
        let store = JobStore(url: folder.appending(path: "queued.sqlite"))
        var queued = job
        queued.id = "prepared"
        queued.status = .queued
        queued.startCommit = fake.head
        store.save(queued)
        let restored = Desk(accounts: AccountStore(root: folder), store: store, updateRecovery: [queued.id])
        restored.makeAgent = desk.makeAgent
        restored.prepare = { _ in throw Shell.Failure(message: "must reuse the existing worktree") }
        restored.resumeAfterUpdate([queued.id])
        #expect(restored.job(queued.id)?.status == .running)
        #expect(fake.agents.count == 1 && fake.resumes.count == 1 && fake.resumes[0] == nil)
        restored.quit()
    }

    @Test func recoveryPreservesQueuesForOverlappingFiles() throws {
        let store = JobStore(url: folder.appending(path: "overlap.sqlite"))
        var older = job
        older.id = "blocker"
        older.status = .running
        older.session = "blocker-session"
        older.files = ["Engine/Desk.swift"]
        store.save(older)
        var queued = older
        queued.id = "waiting"
        queued.status = .queued
        queued.session = nil
        queued.startCommit = fake.head
        queued.created = older.created.addingTimeInterval(1)
        store.save(queued)
        let restored = Desk(accounts: AccountStore(root: folder), store: store, updateRecovery: [older.id, queued.id])
        restored.makeAgent = desk.makeAgent
        restored.resumeAfterUpdate([queued.id, older.id])
        #expect(fake.agents.count == 1 && fake.resumes[0] == "blocker-session")
        #expect(restored.job(queued.id)?.status == .queued)
        #expect(restored.job(queued.id)?.step.contains("Waiting for") == true)
        restored.drainingForUpdate = true
        restored.quit()
    }

    @Test func recoveringAnOldReviewKeepsItsAuthorLinked() throws {
        let store = JobStore(url: folder.appending(path: "review.sqlite"))
        var author = job
        author.id = "old-author"
        author.status = .done
        author.created = .distantPast
        author.reviewing = "live-review"
        store.save(author)
        for number in 0..<60 {
            var filler = job
            filler.id = "filler-\(number)"
            filler.status = .done
            store.save(filler)
        }
        var review = job
        review.id = "live-review"
        review.status = .running
        review.reviewOf = author.id
        review.session = "review-session"
        review.created = .now
        store.save(review)
        let restored = Desk(accounts: AccountStore(root: folder), store: store, updateRecovery: [review.id])
        restored.makeAgent = desk.makeAgent
        #expect(restored.job(author.id)?.reviewing == review.id)
        #expect(restored.job(author.id)?.reviewError == nil)
        restored.resumeAfterUpdate([review.id])
        #expect(fake.resumes.last == "review-session")
        #expect(restored.job(author.id)?.reviewing == review.id)
        restored.drainingForUpdate = true
        restored.quit()
        #expect(restored.job(author.id)?.reviewing == review.id)
    }

    @Test func normalInterruptedJobsAreNotResumed() throws {
        var stopped = job
        stopped.id = "ordinary"
        stopped.status = .interrupted
        stopped.session = "normal-session"
        let store = JobStore(url: folder.appending(path: "normal.sqlite"))
        store.save(stopped)
        let restored = Desk(accounts: AccountStore(root: folder), store: store)
        restored.makeAgent = desk.makeAgent
        let newer = Updates(desk: restored, root: updates.root, binary: updates.binary)
        try newer.recover()
        #expect(fake.agents.isEmpty && restored.job(stopped.id)?.status == .interrupted)
    }
}
