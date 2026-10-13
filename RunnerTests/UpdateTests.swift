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
        var testResults: [Shell.Output] = []
        var calls: [(args: [String], directory: URL, env: [String: String?])] = []
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
        desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")),
                    restarts: Restarts(file: folder.appending(path: "restarts.json")))
        let root = folder.appending(path: "updates")
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appending(path: ".build/release"), withIntermediateDirectories: true)
        try Data("new binary".utf8).write(to: source.appending(path: ".build/release/oby-runner"))
        let binary = folder.appending(path: "oby-runner")
        try Data("old binary".utf8).write(to: binary)
        updates = Updates(desk: desk, root: root, binary: binary)
        updates.command = fakeCommand
        updates.testCommand = { [fake] args, directory, env in
            fake.calls.append((args, directory, env))
            if !fake.testResults.isEmpty { return fake.testResults.removeFirst() }
            if args == ["swift", "test"], args == fake.failed {
                return Shell.Output(status: 1, out: Data("test failed".utf8), err: "")
            }
            return Shell.Output(status: 0, out: Data(), err: "")
        }
        updates.loadAverage = { 0 }
        updates.wait = { _ in }
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

    var fakeCommand: ([String], URL, [String: String?]) async throws -> String {
        { [fake] args, directory, env in
            fake.calls.append((args, directory, env))
            if args == fake.failed { throw Shell.Failure(message: "fake failure") }
            return args.prefix(2) == ["git", "rev-parse"] ? fake.head : ""
        }
    }

    /// The runner as it starts again on the same folder.
    func restarted(store: String = "oby.sqlite") -> Desk {
        let restored = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: store)),
                            restarts: Restarts(file: folder.appending(path: "restarts.json")))
        restored.makeAgent = desk.makeAgent
        restored.prepare = { $0 }
        // dev hasn't moved since: a queued job catching up stays where it is.
        restored.fetchBase = { [fake] _, _ in fake.head }
        return restored
    }

    @Test func buildsThenTestsInOwnCheckoutAndInstallsAtomically() async throws {
        await updates.poll()
        #expect(fake.calls.map(\.args).suffix(2) == [["swift", "build", "-c", "release"], ["swift", "test"]])
        #expect(fake.calls.allSatisfy { $0.directory == updates.root.appending(path: "source") })
        #expect(try String(contentsOf: updates.root.appending(path: "cache-commit"), encoding: .utf8) == fake.head)
        // The tests' Obys get a throwaway home, like a Mac check's, and it's gone afterwards.
        let test = try #require(fake.calls.last)
        let home = try #require(test.env["OBY_HOME"] ?? nil)
        #expect(home != Workspace.root.path && home.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(test.env["TEST_RUNNER_OBY_HOME"] == home)
        #expect(!FileManager.default.fileExists(atPath: home))
        #expect(fake.installs == 1 && fake.restarts == 1)
        #expect(try String(contentsOf: updates.binary, encoding: .utf8) == "new binary")
        let restarted = Updates(desk: desk, root: updates.root, binary: updates.binary)
        #expect(restarted.status.commit == fake.head)
        await updates.poll()
        #expect(fake.installs == 1)
    }

    @Test func oneFailingTestThatPassesOnRerunInstallsAndRecordsFlakiness() async throws {
        fake.testResults = [
            Shell.Output(status: 1, out: Data("✘ Test UpdateTests.example() recorded an issue\n↳ Expectation failed: value == 1".utf8), err: ""),
            Shell.Output(status: 0, out: Data("✔ Test UpdateTests.example() passed".utf8), err: "")
        ]
        await updates.poll()
        #expect(fake.calls.filter { $0.args.first == "swift" && $0.args.dropFirst().first == "test" }.map(\.args) == [
            ["swift", "test"], ["swift", "test", "--filter", #"UpdateTests\.example\(\)"#]
        ])
        #expect(fake.installs == 1 && fake.restarts == 1 && desk.inbox.isEmpty)
        let failure = try #require(desk.failureLog.store.failures().first)
        #expect(failure.trigger == .flakyTest && failure.what.contains("UpdateTests.example()"))
        #expect(failure.evidence.check?.contains("Expectation failed") == true)
    }

    @Test func failingRerunKeepsOldBinaryAndNamesTheTestInTheInbox() async throws {
        fake.testResults = [
            Shell.Output(status: 1, out: Data("✘ Test UpdateTests.example() recorded an issue".utf8), err: ""),
            Shell.Output(status: 1, out: Data("✘ Test UpdateTests.example() recorded an issue\n↳ Expected true".utf8), err: "")
        ]
        await updates.poll()
        #expect(fake.installs == 0 && fake.restarts == 0)
        #expect(desk.inbox.count == 1 && desk.inbox[0].text.contains("UpdateTests.example()"))
        #expect(desk.inbox[0].text.contains("Expected true"))
        #expect(try String(contentsOf: updates.binary, encoding: .utf8) == "old binary")
    }

    @Test(arguments: [true, false])
    func timedOutOrSignaledTestRunDoesNotRerunNamedFailures(timedOut: Bool) async throws {
        fake.testResults = [Shell.Output(status: 1,
                                         out: Data("✘ Test UpdateTests.example() recorded an issue".utf8), err: "",
                                         timedOut: timedOut, terminatedBySignal: !timedOut)]
        await updates.poll()
        #expect(fake.calls.filter { $0.args.first == "swift" && $0.args.dropFirst().first == "test" }.map(\.args) == [["swift", "test"]])
        #expect(fake.installs == 0 && fake.restarts == 0)
        #expect(desk.inbox.count == 1)
        #expect(desk.inbox[0].text.contains(timedOut ? "timed out" : "terminated by signal"))
    }

    @Test func buildFailureReportsCompilerDiagnosticsWithoutRerunningTests() async throws {
        updates.command = { [fake] args, directory, env in
            fake.calls.append((args, directory, env))
            if args == ["swift", "build", "-c", "release"] {
                throw Shell.Failure(message: "Sources/main.swift:8:2: error: cannot find type 'Missing'")
            }
            return args.prefix(2) == ["git", "rev-parse"] ? fake.head : ""
        }
        await updates.poll()
        #expect(fake.calls.filter { $0.args.first == "swift" }.map(\.args) == [["swift", "build", "-c", "release"]])
        #expect(desk.inbox.count == 1 && desk.inbox[0].text.contains("Sources/main.swift:8:2: error: cannot find type 'Missing'"))
        #expect(fake.installs == 0 && fake.restarts == 0)
    }

    /// Each try that fails is its own item (#215): a retry that fails on the same commit offers Try
    /// again again, and while one is open the commit adds no other.
    @Test func aRetryThatFailsAgainOffersTryAgainAgain() async throws {
        fake.failed = ["swift", "test"]
        await updates.poll()
        let first = try #require(desk.inbox.first)
        #expect(first.id == "runner-update-\(fake.head)" && first.isOpen && first.options == [Inbox.tryAgain])
        try desk.settle(first.id, .answer(Inbox.tryAgain))
        for _ in 0..<500 where desk.inbox.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let second = try #require(desk.inbox.last)
        #expect(desk.inbox.count == 2 && second.id == "runner-update-\(fake.head)-try-2" && second.isOpen && second.options == [Inbox.tryAgain])
        #expect(updates.state.failed == fake.head)
        // Still open: the same commit failing again adds nothing.
        await updates.retry().value
        #expect(desk.inbox.count == 2)
        // Read and done: the next failure is the third try's.
        try desk.settle(second.id, .done)
        await updates.retry().value
        #expect(desk.inbox.count == 3 && desk.inbox.last?.id == "runner-update-\(fake.head)-try-3" && desk.inbox.last?.isOpen == true)
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
        let buildCalls = fake.calls.filter { $0.args == step }.count
        let restarted = Updates(desk: desk, root: updates.root, binary: updates.binary)
        restarted.command = updates.command
        restarted.testCommand = updates.testCommand
        await restarted.poll()
        #expect(fake.calls.filter { $0.args == step }.count == buildCalls)
        fake.head = String(repeating: "b", count: 40)
        fake.failed = nil
        await updates.poll()
        #expect(fake.installs == 1 && fake.restarts == 1)
    }

    @Test func aRestartMidBuildTriesTheSameCommitAgain() async throws {
        // The runner goes down while `swift build` runs: the runner that starts next reads the journal as it was then.
        var midBuild: Updates?
        let build = ["swift", "build", "-c", "release"]
        updates.command = { [fake, desk, updates] args, directory, env in
            fake.calls.append((args, directory, env))
            if args == build, midBuild == nil {
                midBuild = Updates(desk: desk, root: updates.root, binary: updates.binary)
                midBuild?.testCommand = updates.testCommand
                throw CancellationError()
            }
            return args.prefix(2) == ["git", "rev-parse"] ? fake.head : ""
        }
        await updates.poll()
        let restarted = try #require(midBuild)
        restarted.command = fakeCommand
        restarted.testCommand = updates.testCommand
        restarted.install = updates.install
        restarted.restart = updates.restart
        await restarted.poll()
        #expect(fake.calls.filter { $0.args == build }.count == 2)
        #expect(fake.installs == 1 && fake.restarts == 1)
    }

    @Test func fetchFailuresReportOncePerOutage() async throws {
        let fetch = ["git", "fetch", "origin", "dev"]
        var date = Date(timeIntervalSince1970: 1_791_582_173)
        updates.now = { date }
        fake.failed = fetch
        await updates.poll()
        date += 180
        await updates.poll()
        // A restart mid-outage doesn't report it again.
        let restarted = Updates(desk: desk, root: updates.root, binary: updates.binary)
        restarted.command = fakeCommand
        restarted.testCommand = updates.testCommand
        restarted.now = { date }
        await restarted.poll()
        #expect(desk.inbox.count == 1 && desk.inbox[0].text.contains("fetch dev"))
        // It clears (dev's head fails to build: another item), then comes back: the inbox hears about it again.
        fake.failed = ["swift", "build", "-c", "release"]
        date += 180
        await updates.poll()
        fake.failed = fetch
        date += 180
        await updates.poll()
        date += 180
        await updates.poll()
        #expect(desk.inbox.filter { $0.text.contains("fetch dev") }.count == 2)
    }

    /// Dispatches a job, and waits for its agent, which gets its session.
    @discardableResult
    func startJob(_ id: String = "updating", rounds: Int? = nil) async throws -> CutOffTests.Agent {
        var work = job
        work.id = id
        work.rounds = rounds
        let before = fake.agents.count
        desk.dispatch(work)
        for _ in 0..<500 where fake.agents.count == before { try await Task.sleep(for: .milliseconds(10)) }
        let agent = try #require(fake.agents.last)
        agent.onEvent(.session("\(id)-session"))
        return agent
    }

    @Test func drainsRunningWorkAndDefersNewReviews() async throws {
        try await startJob()
        await updates.poll()
        #expect(updates.status.phase == "draining" && updates.status.waiting == fake.head)
        #expect(fake.installs == 0 && desk.drainingForUpdate)
        var review = job
        review.id = "queued-review"
        desk.dispatch(review)
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.agents.count == 1 && desk.job(review.id)?.status == .queued)
        fake.agents[0].onEvent(.finished(summary: "Reviewed", failed: false))
        for _ in 0..<500 where desk.job("updating")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        updates.deployIfReady()
        #expect(fake.installs == 1 && fake.restarts == 1)
        // The review that waited starts when the new runner does, in a session of its own.
        let restored = restarted()
        restored.resumeAfterRestart()
        for _ in 0..<500 where fake.agents.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fake.agents.count == 2 && fake.resumes.last == .some(nil))
        #expect(restored.job(review.id)?.status == .running && restored.job("updating")?.status == .done)
        restored.quit()
    }

    @Test func theNextRoundAndTheUsersWordsWaitDuringDrainThenFollowTheNotice() async throws {
        try await startJob(rounds: 3)
        await updates.poll()
        fake.agents[0].onEvent(.turnEnded(summary: "GOAL NOT MET: more work", failed: false))
        for _ in 0..<500 where !desk.updateIsIdle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(desk.updateIsIdle)
        #expect(desk.job("updating")?.currentRound == 2)
        // The user's words join the round's message: neither replaces the other.
        try desk.message("updating", "Also fix the docs")
        #expect(fake.agents.count == 1)
        updates.deployIfReady()
        #expect(fake.restarts == 1)
        let restored = restarted()
        restored.resumeAfterRestart()
        #expect(fake.resumes.last == "updating-session")
        #expect(fake.agents.last?.prompt == Restarts.noticeWithMessage + "\n\nKeep going: more work\n\nAlso fix the docs")
        #expect(restored.job("updating")?.currentRound == 2)
        restored.quit()
    }

    @Test func aHandOffToAFinishedJobDuringDrainIsSentAfterTheRestart() async throws {
        let finished = try await startJob("finished")
        finished.onEvent(.finished(summary: "Done", failed: false))
        for _ in 0..<500 where desk.job("finished")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        try await startJob()
        await updates.poll()
        // Like Oby's review or a failed Mac check handing its findings over: the job runs again, in its session.
        try desk.message("finished", "Fix what the review found")
        #expect(fake.agents.count == 2 && desk.job("finished")?.status == .running)
        fake.agents[1].onEvent(.finished(summary: "Reviewed", failed: false))
        for _ in 0..<500 where !desk.updateIsIdle { try await Task.sleep(for: .milliseconds(10)) }
        updates.deployIfReady()
        #expect(fake.restarts == 1)
        let restored = restarted()
        restored.resumeAfterRestart()
        #expect(fake.agents.count == 3 && fake.resumes.last == "finished-session")
        #expect(fake.agents.last?.prompt == Restarts.noticeWithMessage + "\n\nFix what the review found")
        restored.quit()
    }

    @Test func twoDevCommitsInQuickSuccessionRestartOnce() async throws {
        try await startJob()
        await updates.poll()
        #expect(updates.status.phase == "draining" && updates.status.waiting == fake.head)
        // dev moves again while the first commit waits for the drain: the newer one replaces it.
        fake.head = String(repeating: "b", count: 40)
        await updates.poll()
        #expect(updates.status.phase == "draining" && updates.status.waiting == fake.head && desk.drainingForUpdate)
        #expect(fake.calls.filter { $0.args == ["swift", "test"] }.count == 2 && fake.restarts == 0)
        fake.agents[0].onEvent(.finished(summary: "Done", failed: false))
        for _ in 0..<500 where desk.job("updating")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        updates.deployIfReady()
        #expect(fake.installs == 1 && fake.restarts == 1 && updates.state.installed == fake.head)
        // The runner that starts has the newest commit: nothing more to install.
        let restarted = Updates(desk: desk, root: updates.root, binary: updates.binary)
        restarted.command = fakeCommand
        restarted.install = updates.install
        restarted.restart = updates.restart
        await restarted.poll()
        #expect(fake.installs == 1 && fake.restarts == 1 && restarted.status.commit == fake.head)
    }

    @Test func aNewerCommitThatFailsLeavesTheTestedOneToInstall() async throws {
        try await startJob()
        await updates.poll()
        let tested = fake.head
        fake.head = String(repeating: "b", count: 40)
        fake.failed = ["swift", "test"]
        await updates.poll()
        #expect(updates.status.phase == "draining" && updates.status.waiting == tested && desk.drainingForUpdate)
        #expect(updates.state.failed == fake.head && desk.inbox.count == 1)
        fake.agents[0].onEvent(.finished(summary: "Done", failed: false))
        for _ in 0..<500 where desk.job("updating")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        updates.deployIfReady()
        #expect(fake.installs == 1 && fake.restarts == 1 && updates.state.installed == tested)
    }

    @Test func updatesRestartAtMostOnceEveryFifteenMinutes() async throws {
        var date = Date(timeIntervalSince1970: 1_791_582_173)
        updates.now = { date }
        await updates.poll()
        #expect(fake.restarts == 1)
        // The runner is back, and dev moves a minute later.
        let fresh = restarted()
        let next = Updates(desk: fresh, root: updates.root, binary: updates.binary)
        next.command = fakeCommand
        next.testCommand = updates.testCommand
        next.install = updates.install
        next.restart = updates.restart
        next.now = { date }
        next.fixesFailure = { _ in false }
        fake.head = String(repeating: "b", count: 40)
        date += 60
        await next.poll()
        #expect(next.status.phase == "ready" && next.status.waiting == fake.head)
        // Waiting its turn doesn't hold any agent back.
        #expect(!fresh.drainingForUpdate && fake.restarts == 1)
        date += Updates.spacing - 61
        next.deployIfReady()
        #expect(fake.restarts == 1)
        date += 1
        next.deployIfReady()
        #expect(fake.restarts == 2 && next.state.installed == fake.head)
    }

    @Test func anUpdateThatFixesOneOfObysFailuresDoesntWait() async throws {
        var date = Date(timeIntervalSince1970: 1_791_582_173)
        updates.now = { date }
        await updates.poll()
        #expect(fake.restarts == 1)
        // The runner is back, and dev moves a minute later.
        let fresh = restarted()
        let next = Updates(desk: fresh, root: updates.root, binary: updates.binary)
        next.command = fakeCommand
        next.testCommand = updates.testCommand
        next.install = updates.install
        next.restart = updates.restart
        next.now = { date }
        next.fixesFailure = { _ in true }
        fake.head = String(repeating: "b", count: 40)
        date += 60
        await next.poll()
        // It brings the fix of one of Oby's own failures: no waiting.
        #expect(fake.restarts == 2 && next.state.installed == fake.head)
        #expect(next.status.phase == "restarting" && fresh.drainingForUpdate)
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
        #expect(fake.restarts == 1)
        let restored = restarted()
        restored.resumeAfterRestart()
        #expect(fake.resumes.last == "updating-session")
        // Cut off mid-turn: it hears the notice, then the task it was on.
        let prompt = try #require(fake.agents.last?.prompt)
        #expect(prompt.hasPrefix(Restarts.noticeWithMessage + "\n\n") && prompt.contains(job.task))
        #expect(restored.job("updating")?.currentRound == 1)
        #expect(restored.job("updating")?.status == .running)
        #expect(restored.inbox.filter(\.isOpen).isEmpty)
        restored.resumeAfterRestart()
        #expect(fake.agents.count == 2)
        restored.quit()
    }

    @Test func installFailureReleasesDrainAndRetainsProvenance() async throws {
        updates.install = { _, _ in throw Shell.Failure(message: "read only") }
        await updates.poll()
        #expect(fake.restarts == 0 && !desk.drainingForUpdate)
        #expect(updates.state.installed == nil && updates.state.failed == fake.head)
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
        #expect(fake.resumes.last == "updating-session")
        #expect(fake.agents.last?.prompt == "Keep going: more work")
        desk.quit()
    }

    @Test func questionsWaitForTheUserAfterUpdate() async throws {
        try await startJob()
        fake.agents[0].onEvent(.turnEnded(summary: "QUESTION: Which option?\nOPTIONS: One | Two", failed: false))
        await updates.poll()
        #expect(fake.restarts == 1)
        let restored = restarted()
        restored.resumeAfterRestart()
        #expect(fake.agents.count == 1)
        // It keeps waiting, not interrupted (#206).
        #expect(restored.job("updating")?.status == .running && restored.job("updating")?.step == "Waiting for your answer")
        #expect(restored.job("updating")?.question?.text == "Which option?")
        #expect(restored.inbox.contains { $0.kind == .question && $0.isOpen })
        try restored.message("updating", "One")
        #expect(fake.resumes.last == "updating-session" && fake.agents.count == 2)
        #expect(fake.agents.last?.prompt == "One")
        restored.quit()
    }

    @Test func preparedQueuedJobsReuseTheirWorktreeAfterRestart() async throws {
        let store = JobStore(url: folder.appending(path: "queued.sqlite"))
        var queued = job
        queued.id = "prepared"
        queued.status = .queued
        queued.startCommit = fake.head
        store.save(queued)
        let restored = restarted(store: "queued.sqlite")
        restored.prepare = { _ in throw Shell.Failure(message: "must reuse the existing worktree") }
        restored.resumeAfterRestart()
        // It's brought up to date with dev first, then starts.
        for _ in 0..<500 where restored.job(queued.id)?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        #expect(restored.job(queued.id)?.status == .running)
        #expect(fake.agents.count == 1 && fake.resumes.count == 1 && fake.resumes[0] == nil)
        restored.quit()
    }

    /// After a restart, a queued job still waits for a slot while the cap's jobs run (#237).
    @Test func recoveryKeepsQueuedJobsUnderTheCap() throws {
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
        let restored = restarted(store: "overlap.sqlite")
        restored.maxRunning = 1
        restored.resumeAfterRestart()
        #expect(fake.agents.count == 1 && fake.resumes[0] == "blocker-session")
        #expect(restored.job(queued.id)?.status == .queued)
        #expect(restored.job(queued.id)?.step == "Waiting for a free slot: 1 of 1 jobs running")
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
        var review = job
        review.id = "live-review"
        review.status = .running
        review.reviewOf = author.id
        review.session = "review-session"
        review.created = Date(timeIntervalSince1970: 1_000_000)
        store.save(review)
        // Newer than both: the review and its author aren't among the latest 50.
        for number in 0..<60 {
            var filler = job
            filler.id = "filler-\(number)"
            filler.status = .done
            store.save(filler)
        }
        let restored = restarted(store: "review.sqlite")
        #expect(restored.job(author.id)?.reviewing == review.id)
        #expect(restored.job(author.id)?.reviewError == nil)
        restored.resumeAfterRestart()
        #expect(fake.resumes.last == "review-session")
        #expect(restored.job(author.id)?.reviewing == review.id)
        restored.quit()
        #expect(restored.job(author.id)?.reviewing == review.id)
    }

    @Test func interruptedJobsAreNotResumed() throws {
        var interrupted = job
        interrupted.id = "ordinary"
        interrupted.status = .interrupted
        interrupted.session = "normal-session"
        let store = JobStore(url: folder.appending(path: "normal.sqlite"))
        store.save(interrupted)
        let restored = restarted(store: "normal.sqlite")
        restored.resumeAfterRestart()
        #expect(fake.agents.isEmpty && restored.job(interrupted.id)?.status == .interrupted)
    }
}
