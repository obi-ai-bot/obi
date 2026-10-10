import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

/// A job that ends done with commits publishes by itself: no tap, the secret scan still gates it (#75).
@MainActor
struct PublishOnItsOwnTests {
    /// An agent whose events the test sends.
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws { self.onEvent = onEvent }
        func send(_ text: String) {}
        func end() {}
        func stop() {}
        func kill() {}
    }

    let folder: URL
    let desk: Desk
    let agent = Agent()
    /// What the desk asked to publish.
    final class Published { var jobs: [Job] = [] }
    let published = Published()

    init() throws {
        folder = try temporaryFolder()
        desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.makeAgent = { [agent] _, _, _ in agent }
        desk.prepare = { $0 }
    }

    /// Runs a fix job on issue 75 to its end: the agent says `summary`, the worktree has `commits`,
    /// and publishing does `publish`.
    func run(_ id: String, commits: Int?, failed: Bool = false, summary: String = "fix(engine): open the PR by itself",
             publish: @escaping (Job) async throws -> URL) async throws -> Job {
        desk.countCommits = { _, _ in commits }
        desk.publishOnItsOwn = { [published] job, _ in
            published.jobs.append(job)
            return try await publish(job)
        }
        var job = job
        job.id = id
        job.kind = .fix
        job.pr = nil
        job.issue = 75
        job.base = "dev"
        job.branch = "oby/fix-75"
        desk.dispatch(Desk.Draft(said: "work on oby #75", reply: "", job: job, guessed: false))
        for _ in 0..<500 where desk.job(id)?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        agent.onEvent(.session("e6a24229"))
        agent.onEvent(.turnEnded(summary: summary, failed: failed))
        agent.onEvent(.finished(summary: summary, failed: failed))
        for _ in 0..<500 where desk.job(id)?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(desk.job(id))
    }

    @Test func aDoneJobWithCommitsOpensItsPullRequest() async throws {
        let ended = try await run("opens", commits: 2) { _ in URL(string: "https://github.com/deskree-inc/oby/pull/80")! }
        #expect(published.jobs.count == 1 && published.jobs.first?.commits == 2 && published.jobs.first?.status == .done)
        #expect(ended.status == .done && ended.published == "https://github.com/deskree-inc/oby/pull/80")
        #expect(ended.pushed == 2 && !ended.canPublish && !ended.needsYou && ended.publishError == nil)
        #expect(ended.summaries == ["fix(engine): open the PR by itself"])
        #expect(Push.notice(for: ended) == nil)
    }

    @Test func aPossibleSecretFailsTheJobNamingWhere() async throws {
        let ended = try await run("secret", commits: 1) { _ in
            throw Publish.Blocked(findings: [Publish.Finding(file: "Engine/Keys.swift", line: 12, rule: "AWS access key")])
        }
        #expect(ended.status == .failed && ended.published == nil)
        #expect(ended.summary.hasPrefix("Not published: possible secret in Engine/Keys.swift:12 (AWS access key)."))
        #expect(Push.notice(for: ended) == .failed)
    }

    @Test func anyOtherFailureLeavesPublishByHand() async throws {
        let ended = try await run("nopush", commits: 1) { _ in throw Shell.Failure(message: "Couldn't push oby/fix-75: the remote hung up.") }
        #expect(ended.status == .done && ended.published == nil && ended.canPublish && ended.needsYou)
        #expect(ended.publishError == "Couldn't push oby/fix-75: the remote hung up.")
        #expect(Push.notice(for: ended) == .ready)
    }

    @Test func noCommitsOrAFailureOpenNothing() async throws {
        let nothing = try await run("nothing", commits: 0) { _ in URL(string: "https://github.com/deskree-inc/oby/pull/81")! }
        #expect(nothing.status == .failed && nothing.summary.hasPrefix("Nothing committed:"))
        let failed = try await run("failed", commits: 3, failed: true) { _ in URL(string: "https://github.com/deskree-inc/oby/pull/82")! }
        #expect(failed.status == .failed && failed.published == nil)
        #expect(published.jobs.isEmpty)
    }

    /// Talking to a published job made a new commit: it goes to the same pull request by itself.
    @Test func newCommitsFollowToTheSamePullRequest() async throws {
        let url = URL(string: "https://github.com/deskree-inc/oby/pull/80")!
        let first = try await run("again", commits: 1) { _ in url }
        #expect(first.pushed == 1)
        desk.countCommits = { _, _ in 2 }
        try desk.message("again", "also update the docs")
        for _ in 0..<500 where desk.job("again")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        agent.onEvent(.turnEnded(summary: "docs: say so in runner-api.md", failed: false))
        agent.onEvent(.finished(summary: "docs: say so in runner-api.md", failed: false))
        for _ in 0..<500 where desk.job("again")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        let again = try #require(desk.job("again"))
        #expect(published.jobs.count == 2 && published.jobs.last?.published == url.absoluteString)
        #expect(published.jobs.last?.summaries == ["fix(engine): open the PR by itself", "docs: say so in runner-api.md"])
        #expect(again.status == .done && again.pushed == 2 && !again.canPublish)
    }
}

struct PullRequestTextTests {
    var work: Job {
        var job = job
        job.kind = .fix
        job.pr = nil
        job.issue = 75
        job.check = "swift test"
        job.summary = "Oby opens the PR by itself.\n\nMore detail."
        return job
    }

    @Test func theTitleIsConventionalAndEndsWithTheIssue() {
        #expect(Publish.title(for: work, subjects: ["fix(engine): publish on its own (#75)", "test: cover it"])
                == "fix(engine): publish on its own (#75)")
        #expect(Publish.title(for: work, subjects: ["WIP", "feat!: ready for review"]) == "feat!: ready for review (#75)")
        // No subject in that form: the kind and the agent's first line.
        #expect(Publish.title(for: work, subjects: ["Update Desk.swift"]) == "fix: oby opens the PR by itself (#75)")
        var api = work
        api.issue = nil
        api.kind = .build
        api.summary = "API answers with the job."
        #expect(Publish.title(for: api, subjects: []) == "feat: API answers with the job")
        api.summary = String(repeating: "x", count: 300)
        #expect(Publish.title(for: api, subjects: []).count == 100)
    }

    @Test func theBodyHasEveryRoundTheCheckAndClosesTheIssue() {
        var job = work
        job.summaries = ["First try.", "Fixed the failing test with ```code```."]
        let body = Publish.body(for: job)
        #expect(body.contains("Round 1, the agent's summary:\n\n```\nFirst try.\n```"))
        #expect(body.contains("Round 2, the agent's summary:\n\n````\nFixed the failing test with ```code```.\n````"))
        #expect(body.contains("- Check: ` swift test ` passed.\n- Secret scan: clean."))
        #expect(body.contains("\n\nCloses #75\n\n"))
        #expect(body.hasSuffix("by Oby: Oby opened this pull request after the check passed and the secret scan was clean. A person reviews it before it merges."))
        job.check = nil
        job.issue = nil
        job.summaries = nil
        let plain = Publish.body(for: job)
        #expect(plain.hasPrefix("The agent's summary:\n\n```\nOby opens the PR by itself.\n\nMore detail.\n```"))
        #expect(plain.contains("- Check: none, the job had no check.") && !plain.contains("Closes"))
    }

    @Test func aPlantedKeyIsFoundWithItsFileAndLine() {
        // Built at runtime so this file holds no line the scan would flag.
        let key = "AKIA" + "ABCDEFGHIJKLMNOP"
        let diff = """
            diff --git a/Engine/Keys.swift b/Engine/Keys.swift
            --- a/Engine/Keys.swift
            +++ b/Engine/Keys.swift
            @@ -10,2 +10,3 @@
             let a = 1
             let b = 2
            +let key = "\(key)"
            """
        let findings = Publish.findings(inDiff: diff)
        #expect(findings == [Publish.Finding(file: "Engine/Keys.swift", line: 12, rule: "AWS access key")])
        #expect(Publish.Blocked(findings: findings).localizedDescription
                == "Not published: possible secret in Engine/Keys.swift:12 (AWS access key).")
    }
}
