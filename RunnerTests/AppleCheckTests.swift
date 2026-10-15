import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// Apple builds for agents mid-round (#118, Engine/AppleChecks.swift): `oby-check apple`, the
/// runner's queue, the Mac's checkout of commits that aren't on GitHub, and the reviewer's view.
@MainActor
struct AppleCheckTests {
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var prompt = ""
        var sent: [String] = []
        var endCount = 0
        var killCount = 0
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            self.prompt = prompt
            self.onEvent = onEvent
        }
        func send(_ text: String) { sent.append(text) }
        func end() { endCount += 1 }
        func stop() {}
        func kill() { killCount += 1 }
    }

    /// What the desk did, and the commit the job's worktree is on.
    @MainActor
    final class Made {
        var agents: [(job: Job, agent: Agent)] = []
        var head: String? = AppleCheckTests.head
        var events: [MacCheck] = []
        var reviews: [CheckRun] = []
        var quoted: [(file: String, text: String)] = []
        var published: [Job] = []
        /// What the job's final check was given to run with.
        var env: [String: String?] = [:]
    }

    nonisolated static let head = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"
    nonisolated static let next = "aaaabbbbccccddddeeeeffff0000111122223333"
    let folder: URL
    let desk: Desk
    let made = Made()
    let url = URL(string: "https://github.com/deskree-inc/oby/pull/81")!
    let steps = [MacCheck.Step(name: "Mac app and MacTests", passed: false, seconds: 125),
                 MacCheck.Step(name: "iPhone app with Watch, and iOSTests", passed: true, seconds: 412)]

    init() throws {
        folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        let work = try accounts.add(agent: "codex", name: "Work", payer: "Deskree")
        accounts.setLabel("Max · well@example.com", for: "default")
        accounts.setLabel("Plus · work@example.com", for: work.id)
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.prepare = { $0 }
        desk.makeAgent = { [made] job, _, _ in
            let agent = Agent()
            made.agents.append((job, agent))
            return agent
        }
        desk.countCommits = { _, _ in 1 }
        desk.worktreeHead = { [made] _ in made.head }
        desk.publishOnItsOwn = { [url, made] job, _, hooks in
            made.published.append(job)
            hooks.sent(Outgoing(action: .push, repo: job.repo, id: AppleCheckTests.head, branch: job.branch))
            return url
        }
        desk.postReview = { [made] _, run in
            made.reviews.append(run)
            return URL(string: "https://github.com/deskree-inc/oby/runs/1")!
        }
        desk.quoteReview = { [made] _, file, text in made.quoted.append((file, text)) }
        desk.reviewedHead = { _ in AppleCheckTests.head }
        desk.onCheckChange = { [made] in made.events.append($0) }
        desk.queuesMacChecks = true
    }

    /// The build job on issue 118 that touches the iPhone app.
    var author: Job {
        var author = job
        author.id = "apple118"
        author.kind = .build
        author.pr = nil
        author.issue = 118
        author.base = "dev"
        author.branch = "oby/build-118"
        author.files = ["apps/ios/app/HomeView.swift"]
        author.task = "Show the job's actions on the iPhone."
        return author
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    /// The author, running, with `check` as its final check, and `rounds`.
    func running(check: String? = nil, rounds: Int? = nil) async throws {
        var author = author
        author.check = check
        author.rounds = rounds
        desk.dispatch(author)
        try await until("the author runs") { desk.job("apple118")?.status == .running }
    }

    let log = "Mac app and MacTests:\nMac/JobView.swift:12:5: error: cannot find 'OSLog' in scope"
    var failing: MacCheck.Report {
        MacCheck.Report(passed: false, steps: steps, failures: ["MacTests.JobViewTests/showsActions()"], log: log)
    }

    // MARK: The queue

    @Test func aPublishAppleCheckKeepsTheStoredJobActiveWhileItWaits() async throws {
        try await running()
        var ended = try #require(desk.job("apple118"))
        ended.status = .done
        ended.summary = "Finished."

        let check = desk.queuePublishAppleCheck(ended, head: Self.head)

        #expect(check.isApple && check.finalCheck != nil && check.head == Self.head)
        #expect(desk.job("apple118")?.status == .running)
        #expect(desk.job("apple118")?.appleCheck?.id == check.id)
    }

    @Test func aPassingPrePublishAppleCheckKeepsTheJobActiveAndThenPublishesItsResult() async throws {
        desk.appleTool = { [tool] in tool }
        try await running()

        desk.finish("apple118", .done, "Finished.")
        try await until("the pre-publish Apple check is queued") { desk.job("apple118")?.appleCheck?.finalCheck != nil }
        let queued = try #require(desk.job("apple118")?.appleCheck)
        #expect(queued.state == .queued && desk.job("apple118")?.status == .running)

        let taken = try #require(desk.nextMacCheck(mac: "Studio", kinds: [.apple]))
        _ = try desk.macCheckEnded(taken.id, MacCheck.Report(passed: true,
            steps: steps.map { MacCheck.Step(name: $0.name, passed: true, seconds: 1) }, failures: []))
        try await until("the published job ends") { desk.job("apple118")?.status == .done && desk.job("apple118")?.published != nil }
        let ended = try #require(desk.job("apple118"))
        #expect(ended.appleCheck?.state == .passed && ended.appleRan?.state == .passed)
        #expect(made.published.count == 1 && made.published[0].appleCheck?.state == .passed)
    }

    @Test func anUnclaimedPrePublishAppleCheckPublishesAndSaysTheAppsWereNotBuilt() async throws {
        desk.appleTool = { [tool] in tool }
        try await running()

        desk.finish("apple118", .done, "Finished.")
        try await until("the pre-publish Apple check is queued") { desk.job("apple118")?.appleCheck?.finalCheck != nil }
        let queued = try #require(desk.job("apple118")?.appleCheck)
        #expect(desk.appleCheck("apple118", now: queued.created + AppleCheck.finalWait(desk.limits.testRun) + 1)?.state == .error)

        try await until("the no-Mac job publishes") { desk.job("apple118")?.status == .done && desk.job("apple118")?.published != nil }
        let ended = try #require(desk.job("apple118"))
        #expect(ended.summary.contains(AppleCheck.unbuiltLine))
        #expect(made.published.count == 1 && made.published[0].appleCheck?.state == .error)
    }

    @Test func aFailedPrePublishAppleCheckStartsAnAuthorRoundWithQuotedDiagnostics() async throws {
        desk.appleTool = { [tool] in tool }
        try await running()
        var author = try #require(desk.job("apple118"))
        author.session = "agent-session"
        desk.replace(author)

        desk.finish("apple118", .done, "Finished.")
        try await until("the pre-publish Apple check is queued") { desk.job("apple118")?.appleCheck?.finalCheck != nil }
        let taken = try #require(desk.nextMacCheck(mac: "Studio", kinds: [.apple]))
        var buildStep = steps[0]
        buildStep.passed = false
        buildStep.buildErrors = ["Mac/Thing.swift:8: error: invalid actor isolation"]
        _ = try desk.macCheckEnded(taken.id, MacCheck.Report(passed: false, steps: [buildStep, steps[1]], failures: [],
                                                              log: "Mac/Thing.swift:8: error: invalid actor isolation"))

        try await until("the failed build returns to its author") {
            desk.job("apple118")?.isActive == true && desk.job("apple118")?.step == "Working on the Apple check" && !desk.isEnding("apple118")
        }
        let round = try #require(desk.job("apple118"))
        #expect(round.appleCheck?.handedOff == true && round.status == .running)
        #expect(made.published.isEmpty && made.agents.count == 2)
        #expect(made.agents[0].agent.endCount == 1 && desk.isEnding("apple118") == false)
        #expect(made.quoted.last?.file == "apple-check-1.md")
        #expect(made.quoted.last?.text.contains("> Mac/Thing.swift:8: error: invalid actor isolation") == true)
        #expect(made.agents.last?.agent.prompt.contains("apple-check-1.md") == true)
    }

    @Test func aFailedPrePublishAppleCheckWithoutASessionEndsTheJobWithBuildErrors() async throws {
        desk.appleTool = { [tool] in tool }
        try await running()

        desk.finish("apple118", .done, "Finished.")
        try await until("the pre-publish Apple check is queued") { desk.job("apple118")?.appleCheck?.finalCheck != nil }
        let taken = try #require(desk.nextMacCheck(mac: "Studio", kinds: [.apple]))
        var buildStep = steps[0]
        buildStep.passed = false
        buildStep.buildErrors = ["Mac/Thing.swift:8: error: invalid actor isolation"]
        _ = try desk.macCheckEnded(taken.id, MacCheck.Report(passed: false, steps: [buildStep, steps[1]], failures: [],
                                                              log: "Mac/Thing.swift:8: error: invalid actor isolation"))

        try await until("the job ends after its failed Apple check") {
            desk.job("apple118")?.status == .failed && !desk.isEnding("apple118")
        }
        let failed = try #require(desk.job("apple118"))
        #expect(failed.summary.contains("The Apple check failed, but the job has no session to pick up."))
        #expect(failed.summary.contains("Mac/Thing.swift:8: error: invalid actor isolation"))
        #expect(made.agents.count == 1 && made.agents[0].agent.killCount == 1)
        #expect(made.published.isEmpty)
    }

    @Test func aReplacedPrePublishCheckEndsTheJobAndClearsItsEndingState() async throws {
        desk.appleTool = { [tool] in tool }
        try await running()

        desk.finish("apple118", .done, "Finished.")
        try await until("the pre-publish Apple check is queued") { desk.job("apple118")?.appleCheck?.finalCheck != nil }
        var replaced = try #require(desk.job("apple118"))
        replaced.appleCheck?.id = "replacement"
        desk.replace(replaced)

        try await until("the missing result ends the job") { desk.job("apple118")?.status == .failed && !desk.isEnding("apple118") }
        #expect(desk.job("apple118")?.summary.contains("The Apple check ended before Oby received a result.") == true)
        #expect(made.published.isEmpty)
    }

    @Test func everyAppleCompiledPathIsRecognizedAndRunnerOnlyPathsAreNot() {
        for folder in AppleCheck.folders {
            var changed = author
            changed.files = [folder + "Example.swift"]
            #expect(AppleCheck.touchesApple(changed, worktree: URL(filePath: "/tmp")))
        }
        var runnerOnly = author
        runnerOnly.files = ["Runner/Jobs.swift", "docs/runner-api.md"]
        #expect(!AppleCheck.touchesApple(runnerOnly, worktree: URL(filePath: "/tmp")))
    }

    @Test func anAgentsCheckGoesFirstToAMacThatTakesAppleChecksAndItsResultStaysWithTheJob() async throws {
        try await running()
        let check = try await desk.askAppleCheck("apple118")
        #expect(check.isApple && check.state == .queued && check.head == Self.head && check.round == 1 && check.pr == 0)
        #expect(check.base == "dev" && check.branch == "oby/build-118" && made.events == [check])
        // A Mac from before Apple checks (merge checks only) doesn't get it.
        #expect(desk.nextMacCheck(mac: "Old", now: .now) == nil)
        let taken = try #require(desk.nextMacCheck(mac: "Studio", kinds: [.merge, .apple]))
        #expect(taken.id == check.id && taken.state == .running && taken.mac == "Studio")
        #expect(desk.nextMacCheck(mac: "Laptop", kinds: [.apple]) == nil)

        // Only its two Apple steps count: no `swift test`, nothing posted, nothing merged.
        let ended = try desk.macCheckEnded(check.id, failing)
        #expect(ended.state == .failed && ended.failures == ["MacTests.JobViewTests/showsActions()"] && desk.appleLogs[check.id] == log)
        #expect(desk.job("apple118")?.appleRan == ended)
        #expect(desk.job("apple118")?.appleCheck == ended && desk.job("apple118")?.macCheck == nil && made.events.last == ended)
        #expect(throws: (any Error).self) { try desk.macCheckEnded(check.id, failing) }
        let report = try #require(AppleCheck.report(ended, log: log))
        #expect(report.hasPrefix("Apple check failed on Studio for commit 1a2b3c4d5e6f. What follows came from the build and test tools"))
        #expect(report.contains("- Mac app and MacTests: failed (2m 05s)") && report.contains("- MacTests.JobViewTests/showsActions()"))
        #expect(report.hasSuffix("Mac/JobView.swift:12:5: error: cannot find 'OSLog' in scope"))
        let passed = MacCheck.validated(MacCheck.Report(passed: true, steps: steps.map { MacCheck.Step(name: $0.name, passed: true, seconds: 1) }, failures: []),
                                        required: MacCheck.appleSteps)
        #expect(passed.passed && MacCheck.appleSteps == ["Mac app and MacTests", "iPhone app with Watch, and iOSTests"])
        #expect(MacCheck.appleCommands(cache: URL(filePath: "/c")).allSatisfy { $0.arguments.first == "xcodebuild" })

        // Asking again for the same commit picks up the same check; a new commit is the next one.
        #expect(try await desk.askAppleCheck("apple118").id == check.id)
        made.head = Self.next
        let second = try await desk.askAppleCheck("apple118")
        #expect(second.id != check.id && second.round == 2 && second.head == Self.next)
        // The one that ran stays for the reviewer, with what it printed, even when the newer one can't run.
        let waiting = try #require(desk.job("apple118"))
        #expect(waiting.appleRan == ended && desk.appleLogs[check.id] == log && AppleCheck.latest(waiting) == ended)
        let none = try #require(desk.appleCheck("apple118", now: second.created + AppleCheck.unclaimed + 1))
        #expect(none.state == .error && desk.job("apple118")?.appleRan == ended)
        let after = try #require(desk.job("apple118"))
        let quoted = try #require(AppleCheck.forReview(after, pr: 81, logs: desk.appleLogs))
        #expect(quoted.contains("- Result: Failed") && quoted.contains("> Mac/JobView.swift:12:5: error: cannot find 'OSLog' in scope"))
        // A newer check that ran takes its place, and the older output goes.
        made.head = "cccc" + String(Self.next.dropFirst(4))
        let third = try await desk.askAppleCheck("apple118")
        _ = desk.nextMacCheck(mac: "Studio", kinds: [.apple])
        let passed3 = try desk.macCheckEnded(third.id, MacCheck.Report(passed: true, steps: steps.map { MacCheck.Step(name: $0.name, passed: true, seconds: 1) }, failures: []))
        #expect(desk.job("apple118")?.appleRan == passed3 && desk.appleLogs[check.id] == nil)
        // The old check's result has no one waiting.
        #expect(throws: MacCheck.Unknown.self) { try desk.macCheckEnded(check.id, failing) }

        // Only a running job asks, with a commit Oby can read.
        made.head = nil
        await #expect(throws: (any Error).self) { try await desk.askAppleCheck("apple118") }
        await #expect(throws: (any Error).self) { try await desk.askAppleCheck("nowhere") }
        desk.queuesMacChecks = false
        made.head = Self.head
        await #expect(throws: (any Error).self) { try await desk.askAppleCheck("apple118") }
    }

    @Test func aStepTheMacCouldNotRunDoesNotHideWhatTheOtherFound() async throws {
        try await running()
        let check = try await desk.askAppleCheck("apple118")
        _ = desk.nextMacCheck(mac: "Studio", kinds: [.apple])
        let simulator = "iPhone app with Watch, and iOSTests couldn't run on this Mac (exit 70): xcodebuild: error: Unable to find a destination"
        let partial = MacCheck.Report(passed: false, steps: [steps[0], MacCheck.Step(name: steps[1].name, passed: false, seconds: 3)],
                                      failures: ["MacTests.JobViewTests/showsActions()"], log: log, problem: simulator)
        let ended = try desk.macCheckEnded(check.id, partial)
        #expect(ended.state == .error && ended.problem == simulator && desk.appleLogs[check.id] == log)
        // It didn't run whole, so it isn't what the reviewer reads.
        #expect(desk.job("apple118")?.appleRan == nil)
        let report = try #require(AppleCheck.report(ended, log: desk.appleLogs[check.id]))
        #expect(report.hasPrefix("The Apple check of commit 1a2b3c4d5e6f couldn't run: \(simulator)\nWhat it could run on Studio follows."))
        #expect(report.contains("- Mac app and MacTests: failed (2m 05s)") && report.contains("- MacTests.JobViewTests/showsActions()"))
        #expect(report.hasSuffix("Mac/JobView.swift:12:5: error: cannot find 'OSLog' in scope"))
        // Nothing found at all (the checkout failed): the problem alone.
        var nothing = ended
        nothing.steps = [MacCheck.Step(name: "Check out the commit", passed: false, seconds: 0)]
        nothing.failures = []
        #expect(AppleCheck.report(nothing, log: nil) == "The Apple check of commit 1a2b3c4d5e6f couldn't run: \(simulator)")
    }

    @Test func aMacThatTookAnAgentsCheckAndWentQuietLosesItAfterItsOwnShortLease() async throws {
        try await running()
        let check = try await desk.askAppleCheck("apple118")
        let taken = try #require(desk.nextMacCheck(mac: "Studio", kinds: [.apple]))
        let started = try #require(taken.started)
        #expect(AppleCheck.lease < MacCheck.lease && taken.leaseLimit == AppleCheck.lease)
        // Within the lease the Mac is busy, and the agent keeps waiting.
        #expect(desk.appleCheck("apple118", now: started + AppleCheck.lease)?.state == .running)
        #expect(desk.busyMac(now: started + AppleCheck.lease)?.id == check.id)
        // Past it another Mac takes the check from the silent one.
        #expect(desk.busyMac(now: started + AppleCheck.lease + 1) == nil)
        let again = try #require(desk.nextMacCheck(mac: "Laptop", kinds: [.apple], now: started + AppleCheck.lease + 1))
        #expect(again.id == check.id && again.mac == "Laptop" && again.state == .running)

        // No other Mac asks: the agent's next look ends it, and the agent carries on without it.
        let quiet = try #require(desk.appleCheck("apple118", now: again.started! + AppleCheck.lease + 1))
        #expect(quiet.state == .error && quiet.problem == AppleCheck.quietLine && quiet.finished != nil && !quiet.agentWaits)
        #expect(made.events.last == quiet)
        // What the quiet Mac reports late has no one waiting.
        #expect(throws: (any Error).self) { try desk.macCheckEnded(check.id, failing) }
    }

    @Test func noMacTakingItSaysSoButABusyMacKeepsItWaiting() async throws {
        try await running()
        let check = try await desk.askAppleCheck("apple118")
        #expect(desk.appleCheck("apple118", now: check.created + 30)?.state == .queued)
        #expect(AppleCheck.line(check, busy: nil) == "Apple check \(check.id) of commit 1a2b3c4d5e6f is queued, waiting for a Mac.")

        // A Mac busy with a merge check: it's next, however long that takes, up to an hour.
        var other = try #require(desk.job("apple118"))
        var merge = MacCheck(id: "ab12cd34", job: "apple118", repo: other.repo, pr: 80, branch: "oby/fix-75", base: "dev", head: Self.next, round: 1)
        merge.state = .running
        merge.started = check.created
        merge.mac = "Studio"
        other.macCheck = merge
        desk.replace(other)
        #expect(desk.appleCheck("apple118", now: check.created + 600)?.state == .queued)
        let busy = try #require(desk.busyMac(now: check.created + 600))
        #expect(AppleCheck.line(check, busy: busy) == "Apple check \(check.id) of commit 1a2b3c4d5e6f is queued: Studio is running another check first.")
        // Once the Mac is free, its minute to take the check counts from then.
        other = try #require(desk.job("apple118"))
        other.macCheck?.state = .passed
        other.macCheck?.finished = check.created + 600
        desk.replace(other)
        #expect(desk.appleCheck("apple118", now: check.created + 630)?.state == .queued)
        other.macCheck = merge
        desk.replace(other)
        let stale = try #require(desk.appleCheck("apple118", now: check.created + AppleCheck.stale + 1))
        #expect(stale.state == .error && stale.problem == AppleCheck.staleLine)

        // With no Mac busy, a minute without one taking it means none follows the runner.
        made.head = Self.next
        other = try #require(desk.job("apple118"))
        other.macCheck = nil
        desk.replace(other)
        let again = try await desk.askAppleCheck("apple118")
        #expect(again.id != check.id && again.round == 2)
        let none = try #require(desk.appleCheck("apple118", now: again.created + AppleCheck.unclaimed + 1))
        #expect(none.state == .error && none.problem == AppleCheck.noMacLine && made.events.last == none)
        #expect(AppleCheck.report(none, log: nil) == "The Apple check of commit aaaabbbbcccc couldn't run: " + AppleCheck.noMacLine)
        #expect(none.unclaimed)

        // A Mac that comes back (#157), after the runner restarted or the Mac app opened, takes it
        // late, within an hour: not one that takes only merge checks, and not past the hour.
        #expect(desk.nextMacCheck(mac: "Studio", now: again.created + 120) == nil)
        #expect(desk.nextMacCheck(mac: "Studio", kinds: [.apple], now: again.created + AppleCheck.stale + 1) == nil)
        let late = try #require(desk.nextMacCheck(mac: "Studio", kinds: [.merge, .apple], now: again.created + 120))
        #expect(late.id == again.id && late.state == .running && late.mac == "Studio" && late.problem == nil && late.finished == nil)
        // The agent asking again for the same commit waits for it, and gets its result.
        let asked = try await desk.askAppleCheck("apple118")
        #expect(asked.id == again.id && asked.state == .running)
        let passed = try desk.macCheckEnded(again.id, MacCheck.Report(passed: true, steps: steps.map { MacCheck.Step(name: $0.name, passed: true, seconds: 1) }, failures: []))
        #expect(passed.state == .passed && desk.job("apple118")?.appleRan == passed)
        #expect(desk.nextMacCheck(mac: "Studio", kinds: [.apple]) == nil)
    }

    // MARK: A job's final check (#68)

    let tool = AppleCheck.Tool(folder: URL(filePath: "/oby/bin"), executable: URL(filePath: "/oby/oby-runner"), url: "http://127.0.0.1:7777")

    @Test func theFinalCheckRunsObyCheckAppleWithTheAgentsEnvironmentAndWaitsForTheMac() async throws {
        desk.appleTool = { [tool] in tool }
        desk.integrity = { _ in Integrity.Report() }
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let (desk, made, steps) = (desk, made, steps)
        desk.runCheck = { id, command, timeout, env in
            made.env = env
            // `oby-check apple` asks with the token it was given: the final check's, which waits for a Mac past a minute.
            let token = (env["OBY_CHECK_TOKEN"] ?? nil) ?? ""
            _ = try? await api.appleCheck("Bearer " + token, ask: true)
            guard let check = desk.job(id)?.appleCheck, check.finalCheck != nil,
                  desk.appleCheck(id, now: check.created + AppleCheck.unclaimed + 1)?.state == .queued,
                  desk.nextMacCheck(mac: "Studio", kinds: [.merge, .apple])?.id == check.id,
                  (try? desk.macCheckEnded(check.id, MacCheck.Report(passed: true, steps: steps.map { MacCheck.Step(name: $0.name, passed: true, seconds: 1) },
                                                                    failures: []))) != nil
            else { return Rounds.Check(command: command, passed: false, output: "oby-check: not found") }
            return Rounds.Check(command: command, passed: true, output: "Apple check passed on Studio.")
        }
        try await running(check: "oby-check apple")
        let agent = try #require(made.agents.last?.agent)
        agent.onEvent(.turnEnded(summary: "Shown on the iPhone.", failed: false))
        try await until("the job ends") { desk.job("apple118")?.isActive == false }

        // PATH with the command's folder first, the runner's API, and the job's final-check token.
        let path = try #require(made.env["PATH"] ?? nil)
        #expect(path.hasPrefix("/oby/bin:") && made.env["OBY_CHECK_URL"] == "http://127.0.0.1:7777")
        let token = try #require(made.env["OBY_CHECK_TOKEN"] ?? nil)
        #expect(AppleCheck.asker(forToken: token) == AppleCheck.Asker(job: "apple118", final: true) && token != AppleCheck.token(for: "apple118"))
        // oby-check waits up to the check's time limit, less the time to say how it went.
        #expect(made.env["OBY_CHECK_WAIT"] == String(Int(desk.limits.testRun - AppleCheck.margin)))
        #expect(CheckCommand.wait(["apple"], default: 1170) == 1170 && CheckCommand.wait(["apple", "--wait", "60"], default: 1170) == 60)
        let ended = try #require(desk.job("apple118"))
        #expect(ended.status == .done && ended.summary.contains("Checked: `oby-check apple` passed.") && ended.appleRan?.state == .passed)
        #expect(agent.sent.isEmpty)
    }

    @Test func aQueuedAppleCheckIsTakenBeforeAWaitingMergeCheck() async throws {
        // Another job's pull request, approved, its merge check waiting for the Mac.
        var other = author
        other.id = "merge80"
        other.issue = 80
        other.branch = "oby/fix-80"
        desk.dispatch(other)
        try await until("the other job runs") { desk.job("merge80")?.status == .running }
        desk.stop("merge80")
        try await until("the other job ended") { desk.job("merge80")?.isActive == false }
        other = try #require(desk.job("merge80"))
        other.outgoing = [Outgoing(action: .push, repo: other.repo, id: Self.next, branch: other.branch)]
        var merge = MacCheck(id: "ab12cd34", job: "merge80", repo: other.repo, pr: 80, branch: other.branch, base: "dev", head: Self.next, round: 1)
        merge.created = .now - 300
        other.macCheck = merge
        desk.replace(other)

        // The Mac is busy with a third pull request's merge check when the author's final check asks.
        try await running(check: "oby-check apple")
        var busy = try #require(desk.job("apple118"))
        var running = MacCheck(id: "ef56ab78", job: "apple118", repo: busy.repo, pr: 79, branch: "oby/fix-79", base: "dev", head: Self.head, round: 1)
        running.state = .running
        running.started = .now
        running.mac = "Studio"
        busy.macCheck = running
        desk.replace(busy)
        let check = try await desk.askAppleCheck("apple118", final: true)
        #expect(check.finalCheck == check.created && desk.busyMac()?.id == running.id)
        // It waits for the Mac, past a minute, and with the Mac free too, up to the check's time limit.
        #expect(desk.appleCheck("apple118", now: check.created + AppleCheck.unclaimed + 1)?.state == .queued)
        busy = try #require(desk.job("apple118"))
        busy.macCheck = nil
        desk.replace(busy)
        #expect(desk.appleCheck("apple118", now: check.created + AppleCheck.finalWait(desk.limits.testRun) - 1)?.state == .queued)

        // Free again, the Mac takes the Apple check first, though the merge check waited longer; then the merge check.
        let first = try #require(desk.nextMacCheck(mac: "Studio", kinds: [.merge, .apple]))
        #expect(first.id == check.id && first.isApple)
        // Oby on the Mac relaunched mid-check (#227): it gets the Apple check back, not the merge check.
        #expect(desk.nextMacCheck(mac: "Studio", kinds: [.merge, .apple])?.id == check.id)
        try desk.macCheckEnded(check.id, MacCheck.Report(passed: true, steps: steps.map { MacCheck.Step(name: $0.name, passed: true, seconds: 1) }, failures: []))
        let second = try #require(desk.nextMacCheck(mac: "Studio", kinds: [.merge, .apple]))
        #expect(second.id == merge.id && !second.isApple)
    }

    /// A final check of `oby-check apple && swift test` that no Mac takes: it runs again with
    /// `oby-check` passing over the build, and then `swift test` passes (`passes`) or fails. Notes each run's environment.
    func noMac(passes: Bool, runs: Made) {
        desk.appleTool = { [tool] in tool }
        desk.integrity = { _ in Integrity.Report() }
        let desk = desk
        desk.runCheck = { id, command, _, env in
            runs.events.append(MacCheck(id: env[AppleCheck.skipVariable] == "1" ? "without" : "asked", job: id, repo: "", pr: 0, branch: "", base: "",
                                        head: "", round: 1))
            guard env[AppleCheck.skipVariable] == "1" else {
                // No Mac takes it: it's still queued when oby-check gives up.
                _ = try? await desk.askAppleCheck(id, final: true)
                return Rounds.Check(command: command, passed: false, output: "Still queued after 1170 seconds.")
            }
            return passes ? Rounds.Check(command: command, passed: true, output: CheckCommand.skipLine + "\nTest run with 446 tests passed.")
                : Rounds.Check(command: command, passed: false, output: CheckCommand.skipLine + "\n✘ Test sync() failed after 0.2 seconds.")
        }
    }

    @Test func aFinalCheckWithNoMacRunsTheRestOfTheCheckAndEndsDoneSayingTheAppsWereNotBuilt() async throws {
        let runs = Made()
        noMac(passes: true, runs: runs)
        try await running(check: "oby-check apple && swift test")
        let agent = try #require(made.agents.last?.agent)
        agent.onEvent(.turnEnded(summary: "Shown on the iPhone.", failed: false))
        try await until("the job ends") { desk.job("apple118")?.isActive == false }
        let ended = try #require(desk.job("apple118"))
        // Run again without oby-check's build, the rest passed: done, with no round asked for and no limit.
        #expect(runs.events.map(\.id) == ["asked", "without"])
        #expect(ended.status == .done && ended.limit == nil && agent.sent.isEmpty)
        #expect(ended.summary.contains("Checked: `oby-check apple && swift test` passed without its Apple build. " + AppleCheck.unbuiltLine))
        // The check nobody waits for any more is withdrawn, so no Mac takes it.
        #expect(ended.appleUnbuilt && ended.appleCheck?.problem == AppleCheck.unbuiltLine)
        #expect(desk.nextMacCheck(mac: "Studio", kinds: [.apple]) == nil)
        // Its pull request says the Apple apps weren't built, not that the check passed.
        let body = Publish.body(for: ended)
        #expect(body.contains("- Check: ` oby-check apple && swift test ` passed without its Apple build. " + AppleCheck.unbuiltLine))
        #expect(body.contains("Oby opened this pull request after the check passed without its Apple build and the secret scan was clean."))

        // The same output as the round before isn't the same failure twice: it passed without the Apple build.
        var check = Rounds.Check(command: "oby-check apple", passed: true, output: CheckCommand.skipLine)
        check.appleUnbuilt = true
        #expect(Rounds.next(author, summary: "Again.", failed: false, check: check, previous: Fingerprint.of(check))
                == .finish(.done, "Again.\n\nChecked: `oby-check apple` passed without its Apple build. " + AppleCheck.unbuiltLine))
        // oby-check run again without the Apple build says so and lets the rest decide.
        var printed: [String] = []
        #expect(await CheckCommand.run(["apple"], environment: [AppleCheck.skipVariable: "1"], print: { printed.append($0) }) == 0)
        #expect(printed == [CheckCommand.skipLine])
    }

    @Test func aFinalCheckWithNoMacStillFailsOnTheRestOfTheCheck() async throws {
        let runs = Made()
        noMac(passes: false, runs: runs)
        try await running(check: "oby-check apple && swift test", rounds: 4)
        let agent = try #require(made.agents.last?.agent)
        agent.onEvent(.turnEnded(summary: "Shown on the iPhone.", failed: false))
        // Failing Swift tests aren't hidden behind the missing Mac: the agent gets them as its next round.
        try await until("the agent gets another round") { agent.sent.count == 1 }
        #expect(runs.events.map(\.id) == ["asked", "without"])
        #expect(desk.job("apple118")?.status == .running && desk.job("apple118")?.round == 2)
        #expect(agent.sent.first?.contains("✘ Test sync() failed after 0.2 seconds.") == true)
    }

    // MARK: oby-check apple and the API

    @Test func ObyCheckAppleWaitsForTheMacAndPrintsTheCompilersErrorsAndFailingTests() async throws {
        try await running()
        desk.bundleCommits = { _ in Data("bundle".utf8) }
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        let token = AppleCheck.token(for: "apple118")
        #expect(AppleCheck.job(forToken: token) == "apple118" && AppleCheck.job(forToken: "") == nil && AppleCheck.token(for: "apple118") == token)
        let environment = ["OBY_CHECK_URL": "http://127.0.0.1:7777", "OBY_CHECK_TOKEN": token]
        let (desk, made, failing) = (desk, made, failing)
        try await app.test(.router) { client in
            func sender(_ token: String) -> CheckCommand.Send {
                { method, path in
                    try await client.execute(uri: path, method: method == "POST" ? .post : .get, headers: [.authorization: "Bearer \(token)"]) { response in
                        (Int(response.status.code), Data(response.body.readableBytesView))
                    }
                }
            }
            var printed: [String] = []
            var sleeps = 0
            let status = await CheckCommand.run(["apple"], environment: environment, send: sender(token), sleep: { _ in
                sleeps += 1
                // The Mac takes it while oby-check waits, then reports.
                if sleeps == 1 {
                    let check = try #require(await MainActor.run { desk.nextMacCheck(mac: "Studio", kinds: [.apple]) })
                    try await client.execute(uri: "/v1/checks/\(check.id)/bundle", method: .get, headers: [.tailscaleUserLogin: "well@example.com"]) { response in
                        #expect(response.status == .ok && String(decoding: response.body.readableBytesView, as: UTF8.self) == "bundle")
                    }
                }
                if sleeps == 3 {
                    try await MainActor.run { if let check = desk.job("apple118")?.appleCheck { try desk.macCheckEnded(check.id, failing) } }
                }
            }, uncommitted: { true }, print: { printed.append($0) })
            #expect(status == 1 && sleeps == 3)
            let id = try #require(await MainActor.run { desk.job("apple118")?.appleCheck?.id })
            #expect(printed.first?.hasPrefix("Your uncommitted changes aren't in the check") == true)
            #expect(printed[1] == "Apple check \(id) of commit 1a2b3c4d5e6f is queued, waiting for a Mac.")
            #expect(printed[2] == "Apple check \(id) of commit 1a2b3c4d5e6f is building and testing on Studio.")
            #expect(printed[3] == "Apple check \(id) of commit 1a2b3c4d5e6f failed on Studio.")
            #expect(printed.last?.contains("Mac/JobView.swift:12:5: error: cannot find 'OSLog' in scope") == true)
            #expect(printed.last?.contains("- MacTests.JobViewTests/showsActions()") == true)

            // Run again for the same commit: the same result at once.
            printed = []
            #expect(await CheckCommand.run(["apple"], environment: environment, send: sender(token), sleep: { _ in }, uncommitted: { false },
                                           print: { printed.append($0) }) == 1)
            #expect(printed.count == 2 && printed.last?.hasPrefix("Apple check failed on Studio") == true)

            // A new commit no Mac takes yet: it says how to keep waiting. Its requests get all the
            // time they need, so a slow one on a busy machine doesn't end the wait early by the test's clock.
            await MainActor.run { made.head = AppleCheckTests.next }
            printed = []
            var clock = Date(timeIntervalSince1970: 0)
            #expect(await CheckCommand.run(["apple", "--wait", "12"], environment: environment, send: sender(token), now: { clock },
                                           sleep: { clock += $0 }, timer: { _ in try await Task.sleep(for: .seconds(3600)) }, uncommitted: { false },
                                           print: { printed.append($0) }) == 3)
            #expect(printed.last == "Still queued after 12 seconds. Run oby-check apple again to keep waiting: it picks up the same check.")

            // Someone else's token, or none, gets nothing; the owner's endpoints still want the owner.
            printed = []
            #expect(await CheckCommand.run(["apple"], environment: environment, send: sender("made-up"), sleep: { _ in }, uncommitted: { false },
                                           print: { printed.append($0) }) == 2)
            #expect(printed == ["oby-check works only inside an Oby job on the runner."])
            try await client.execute(uri: "/v1/status", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/v1/checks/next?kinds=apple", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/v1/agent/apple-check", method: .get) { #expect($0.status == .unauthorized) }
            // The bundle only for a check a Mac took.
            let queued = try #require(await MainActor.run { desk.job("apple118")?.appleCheck?.id })
            try await client.execute(uri: "/v1/checks/\(queued)/bundle", method: .get, headers: [.tailscaleUserLogin: "well@example.com"]) {
                #expect($0.status == .conflict)
            }
            try await client.execute(uri: "/v1/checks/nowhere/bundle", method: .get, headers: [.tailscaleUserLogin: "well@example.com"]) {
                #expect($0.status == .notFound)
            }
            // The job carries it, with its kind.
            try await client.execute(uri: "/v1/jobs/apple118", method: .get, headers: [.tailscaleUserLogin: "well@example.com"]) { response in
                let job = object(Data(response.body.readableBytesView))
                let check = job["appleCheck"] as? [String: Any] ?? [:]
                #expect(check["kind"] as? String == "apple" && check["state"] as? String == "queued" && job["macCheck"] is NSNull)
            }
            // A Mac asking for Apple checks gets it.
            try await client.execute(uri: "/v1/checks/next?mac=Studio&kinds=merge,apple", method: .get, headers: [.tailscaleUserLogin: "well@example.com"]) { response in
                let check = object(Data(response.body.readableBytesView))["check"] as? [String: Any] ?? [:]
                #expect(check["id"] as? String == queued && check["state"] as? String == "running")
            }

            // A job that ended asks no more.
            await MainActor.run { desk.stop("apple118") }
            for _ in 0..<500 where await MainActor.run(body: { desk.job("apple118")?.isActive == true }) { try await Task.sleep(for: .milliseconds(10)) }
            printed = []
            #expect(await CheckCommand.run(["apple"], environment: environment, send: sender(token), sleep: { _ in }, uncommitted: { false },
                                           print: { printed.append($0) }) == 2)
            #expect(printed == ["Oby checks only a job that's running."])
        }
        // A merge check from before kinds reads as one.
        let old = MacCheck(id: "ab12cd34", job: "j", repo: "deskree-inc/oby", pr: 80, branch: "oby/fix-75", base: "dev", head: Self.head, round: 1)
        #expect(object(try API.encode(MacCheckJSON(check: old)))["kind"] as? String == "merge")
    }

    @Test func theCommandLineAndWhereItRuns() async throws {
        var printed: [String] = []
        #expect(await CheckCommand.run(["mac"], environment: [:], print: { printed.append($0) }) == 64)
        #expect(await CheckCommand.run(["apple", "--wait", "9000"], environment: [:], print: { printed.append($0) }) == 64)
        #expect(await CheckCommand.run(["apple"], environment: [:], uncommitted: { false }, print: { printed.append($0) }) == 2)
        #expect(printed == [CheckCommand.usage, CheckCommand.usage, "oby-check works only inside an Oby job on the runner: there's no runner to ask here."])
        #expect(CheckCommand.wait(["apple"]) == 110 && CheckCommand.wait(["apple", "--wait", "540"]) == 540 && CheckCommand.wait(["apple", "540"]) == nil)
        #expect(CheckCommand.wait(["apple", "--wait", "0"]) == nil)

        // --wait is the whole wait, requests included: a runner slow to answer doesn't stretch it.
        let queued = #"{"check":{"id":"ab12cd34","state":"queued"},"line":"Apple check ab12cd34 is queued, waiting for a Mac.","report":null}"#
        let slow: CheckCommand.Send = { method, _ in
            if method == "GET" { try await Task.sleep(for: .seconds(30)) }
            return (200, Data(queued.utf8))
        }
        printed = []
        let start = ContinuousClock.now
        #expect(await CheckCommand.run(["apple", "--wait", "1"], environment: ["OBY_CHECK_URL": "http://x", "OBY_CHECK_TOKEN": "t"], send: slow,
                                       uncommitted: { false }, print: { printed.append($0) }) == 3)
        // Well under the slow runner's 30 seconds, with room for a loaded runner's parallel tests.
        #expect(ContinuousClock.now - start < .seconds(20))
        #expect(printed.last?.hasPrefix("Still queued after ") == true)

        // The runner installs a script that runs its own executable, `check` first.
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = try AppleCheck.install(executable: URL(filePath: "/bin/echo"), port: 7777, root: root)
        #expect(tool.folder == root.appending(path: "bin") && tool.url == "http://127.0.0.1:7777")
        let ran = await MacCheck.execute([tool.folder.appending(path: "oby-check").path, "apple", "--wait", "5"], in: root, env: [:], timeout: 30)
        #expect(ran.status == 0 && ran.output == "check apple --wait 5\n")

        // Agents see it read-only, find it first on PATH, and get their own job's token.
        let worktree = Workspace.worktree("ab12cd34")
        let boxed = Agents.sandboxed(["claude"], in: worktree, own: nil, bubblewrap: true, apple: tool)
        #expect(boxed.joined(separator: " ").contains("--ro-bind \(tool.folder.path) \(tool.folder.path) --ro-bind-try /bin/echo /bin/echo"))
        #expect(!Agents.sandboxed(["claude"], in: nil, own: nil, bubblewrap: true, apple: tool).contains(tool.folder.path))
        #expect(Agents.sandboxed(["claude"], in: worktree, own: nil, bubblewrap: false, apple: tool) == ["claude"])
        let env = AppleCheck.environment(worktree: worktree, tool: tool, path: "/usr/bin")
        #expect(env["PATH"] == "\(tool.folder.path):/usr/bin" && env["OBY_CHECK_URL"] == "http://127.0.0.1:7777")
        #expect(env["OBY_CHECK_TOKEN"] == AppleCheck.token(for: "ab12cd34"))
        #expect(AppleCheck.environment(worktree: root, tool: tool).isEmpty && AppleCheck.environment(worktree: worktree, tool: nil).isEmpty)
    }

    // MARK: The agent's prompt

    @Test func theAgentHearsAboutItWhenItsJobTouchesTheAppleApps() throws {
        let line = try #require(AppleCheck.agentLine(author))
        #expect(line.contains("run `oby-check apple` before you finish") && line.contains("apps/ios/app/, apps/watch/, apps/mac/app/ or apps/shared/") && line.contains("--wait 540"))
        #expect(Prompts.agent(author, apple: true).contains(line) && !Prompts.agent(author).contains("oby-check"))
        var engine = author
        engine.files = ["Engine/Desk.swift", "docs/"]
        #expect(AppleCheck.agentLine(engine) == nil)
        engine.files = ["apps/watch"]
        #expect(AppleCheck.agentLine(engine) != nil)
        // The brain's jobs have no brief: a repository with the apps' folders gets it.
        var brain = author
        brain.files = nil
        let repo = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(AppleCheck.agentLine(brain, worktree: repo) == nil)
        try FileManager.default.createDirectory(at: repo.appending(path: "apps/shared"), withIntermediateDirectories: true)
        #expect(AppleCheck.agentLine(brain, worktree: repo) != nil)
        var reviewer = author
        reviewer.reviewOf = "x"
        #expect(AppleCheck.agentLine(reviewer) == nil)
        #expect(Prompts.takeover(author, from: "Codex · Work", round: nil, apple: true).contains("oby-check apple"))
        #expect(MacCheck.roundPrompt(author, file: "mac-check-1.md", apple: true).contains("`oby-check apple` builds and tests"))
        #expect(!MacCheck.roundPrompt(author, file: "mac-check-1.md").contains("oby-check"))
    }

    // MARK: Commits that aren't on GitHub, from the runner to the Mac

    @Test func theMacGetsTheJobsCommitsFromTheRunnersBundle() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        @discardableResult func git(_ arguments: [String], in folder: URL) async throws -> String {
            try await Shell.ok(["git", "-C", folder.path, "-c", "user.name=Oby", "-c", "user.email=oby@example.com", "-c", "commit.gpgsign=false"] + arguments)
        }
        // GitHub, with dev; the runner's clone, where the job commits; the Mac's clone.
        let origin = root.appending(path: "origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try await git(["init", "--quiet", "-b", "dev"], in: origin)
        try "one\n".write(to: origin.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "README.md"], in: origin)
        try await git(["commit", "--quiet", "-m", "one"], in: origin)
        let onDev = try await git(["rev-parse", "HEAD"], in: origin)
        let runner = root.appending(path: "runner"), mac = root.appending(path: "mac")
        try await Shell.ok(["git", "clone", "--quiet", origin.path, runner.path])
        try await Shell.ok(["git", "clone", "--quiet", origin.path, mac.path])
        try await git(["checkout", "--quiet", "-b", "oby/build-118"], in: runner)
        try "two\n".write(to: runner.appending(path: "iOS.swift"), atomically: true, encoding: .utf8)
        try await git(["add", "iOS.swift"], in: runner)
        try await git(["commit", "--quiet", "-m", "two"], in: runner)
        let head = try await git(["rev-parse", "HEAD"], in: runner)

        var check = MacCheck(id: "ab12cd34", job: "j", repo: "deskree-inc/oby", pr: 0, branch: "oby/build-118", base: "dev", head: head, round: 1)
        check.kind = .apple
        #expect(MacCheck.runnable(check))
        let bundle = try await AppleCheck.bundle(check, clone: runner)
        #expect(!bundle.isEmpty)
        #expect((try? await git(["show-ref", AppleCheck.ref(check)], in: runner)) == nil)
        #expect((try? await git(["cat-file", "-e", "\(head)^{commit}"], in: mac)) == nil)
        try await AppleCheck.fetch(check, bundle: bundle, into: mac)
        #expect((try? await git(["cat-file", "-e", "\(head)^{commit}"], in: mac)) != nil)
        // A commit on dev already needs no bundle; no bundle at all is the runner's problem.
        check.head = onDev
        #expect(try await AppleCheck.bundle(check, clone: runner).isEmpty)
        try await AppleCheck.fetch(check, bundle: Data(), into: mac)
        await #expect(throws: (any Error).self) { try await AppleCheck.fetch(check, bundle: nil, into: mac) }
        // A base that could be an option never reaches git.
        check.base = "--upload-pack=x"
        #expect(!MacCheck.runnable(check))
        await #expect(throws: (any Error).self) { try await AppleCheck.bundle(check, clone: runner) }
        let report = await MacCheck.run(check, commands: [])
        #expect(report.steps.map(\.name) == ["Check out the commit"] && report.problem == "Couldn't check out the commit: That isn't a check Oby can run.")
    }

    // MARK: The reviewer

    @Test func theReviewerGetsTheLatestAppleResultAndIsToldNotToAskForACompile() async throws {
        try await running()
        let check = try await desk.askAppleCheck("apple118")
        _ = desk.nextMacCheck(mac: "Studio", kinds: [.apple])
        try desk.macCheckEnded(check.id, MacCheck.Report(passed: true, steps: steps.map { MacCheck.Step(name: $0.name, passed: true, seconds: 60) }, failures: []))
        let agent = try #require(made.agents.last?.agent)
        agent.onEvent(.session("e6a24229"))
        agent.onEvent(.turnEnded(summary: "feat(ios): job actions", failed: false))
        agent.onEvent(.finished(summary: "feat(ios): job actions", failed: false))
        try await until("a review job runs") { made.agents.last?.job.reviewOf == "apple118" }
        let reviewer = try #require(made.agents.last)
        let file = try #require(reviewer.job.attachments?.first { $0.hasSuffix("/" + AppleCheck.reviewFile) })
        let quoted = try String(contentsOfFile: file, encoding: .utf8)
        #expect(quoted.hasPrefix("# Oby's latest Apple build and test of pull request #81, quoted"))
        #expect(quoted.contains("- Commit: \(Self.head) (the pull request's head)") && quoted.contains("- Result: Passed"))
        #expect(quoted.contains("Asked for by the author's agent mid-round, on Studio") && quoted.contains("- Mac app and MacTests: passed (1m 00s)"))
        #expect(reviewer.agent.prompt.contains("Don't request changes because the code wasn't compiled or built in Xcode: it was."))
        #expect(reviewer.agent.prompt.contains(".oby/inputs/apple-check.md"))

        // The latest that ran counts, Apple or merge; one that couldn't run doesn't.
        var later = author
        later.appleCheck = desk.job("apple118")?.appleCheck
        var merge = MacCheck(id: "ab12cd34", job: "apple118", repo: later.repo, pr: 81, branch: later.branch, base: "dev", head: Self.next, round: 1)
        merge.state = .failed
        merge.failures = ["MacTests.A/b()"]
        merge.finished = (later.appleCheck?.finished ?? .now) + 60
        later.macCheck = merge
        later.outgoing = [Outgoing(action: .push, repo: later.repo, id: Self.next, branch: later.branch)]
        #expect(AppleCheck.latest(later)?.id == "ab12cd34")
        let text = try #require(AppleCheck.forReview(later, pr: 81, logs: ["ab12cd34": "should not show for a merge check's id"]))
        #expect(text.contains("Oby's check before merging") && text.contains("> MacTests.A/b()") && text.contains("(the pull request's head)") && !text.contains("should not show"))
        later.macCheck?.state = .error
        #expect(AppleCheck.latest(later)?.isApple == true)
        #expect(AppleCheck.forReview(later, pr: 81, logs: [:])?.contains("an earlier commit than the pull request's head, aaaabbbbcccc") == true)
        later.appleCheck = nil
        #expect(AppleCheck.forReview(later, pr: 81, logs: [:]) == nil)
        // Without the file, no line about it.
        var review = Review.make(for: later, pr: 81, account: Account(id: "w", agent: "codex", name: "Work", payer: "Deskree"))
        #expect(!Review.prompt(review).contains("apple-check.md"))
        review.attachments = ["/tmp/x/apple-check.md"]
        #expect(Review.prompt(review).contains("apple-check.md"))
    }
}
