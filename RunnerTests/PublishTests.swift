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
        var onStart: (String) -> Void = { _ in }
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            self.onEvent = onEvent
            self.onStart(prompt)
        }
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
    func run(_ id: String, commits: Int?, rounds: Int? = nil, failed: Bool = false, summary: String = "fix(engine): open the PR by itself",
             publish: @escaping (Job) async throws -> URL) async throws -> Job {
        desk.countCommits = { _, _ in commits }
        desk.publishOnItsOwn = { [published] job, _, _ in
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
        job.rounds = rounds
        desk.dispatch(job)
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
        #expect(ended.phase == .publish)
        #expect(ended.pipeline.stages.first { $0.id == .publish }?.state == .failed)
    }

    @Test func aPossibleSecretGetsAnAgentFixRound() async throws {
        var prompts: [String] = []
        var resumes: [String?] = []
        desk.makeAgent = { [agent] _, _, resume in
            resumes.append(resume)
            return agent
        }
        agent.onStart = { [agent] prompt in
            prompts.append(prompt)
            guard prompts.count == 2 else { return }
            agent.onEvent(.session("e6a24229-fix"))
            agent.onEvent(.turnEnded(summary: "fix(test): remove the secret-like fixture", failed: false))
            agent.onEvent(.finished(summary: "fix(test): remove the secret-like fixture", failed: false))
        }
        var publishes = 0
        let ended = try await run("secret-fix", commits: 2, rounds: 2) { _ in
            publishes += 1
            if publishes == 1 {
                throw Publish.Blocked(findings: [Publish.Finding(file: "RunnerTests/GatewayTests.swift", line: 129, rule: "password or secret")])
            }
            return URL(string: "https://github.com/deskree-inc/oby/pull/82")!
        }
        #expect(prompts.count == 2 && prompts.last?.contains("RunnerTests/GatewayTests.swift:129") == true)
        #expect(resumes == [nil, "e6a24229"])
        #expect(publishes == 2)
        #expect(ended.status == .done && ended.published == "https://github.com/deskree-inc/oby/pull/82")
        #expect(ended.summaries == ["fix(engine): open the PR by itself", "fix(test): remove the secret-like fixture"])
    }

    @Test func anyOtherFailureLeavesPublishByHand() async throws {
        let ended = try await run("nopush", commits: 1) { _ in throw Shell.Failure(message: "Couldn't push oby/fix-75: the remote hung up.") }
        #expect(ended.status == .done && ended.published == nil && ended.canPublish && ended.needsYou)
        #expect(ended.publishError == "Couldn't push oby/fix-75: the remote hung up.")
        #expect(Push.notice(for: ended) == .ready)
        #expect(ended.pipeline.stages.first { $0.id == .publish }?.reason == ended.publishError)
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
        desk.followed("again", published: url.absoluteString, pushed: 1,
                      status: PullRequestStatus(state: .open, reviewDecision: .approved, base: "dev", checkedAt: .now), error: nil)
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
        #expect(again.pullRequest == nil)
        #expect(again.pipeline.stages.first { $0.id == .review }?.state == .current)
    }

    /// The runner restarts: jobs that ended before it started, published or not, stay as they
    /// are, and only a job that finishes in this run publishes.
    @Test func onlyAJobThatFinishesInThisRunPublishes() async throws {
        let store = JobStore(url: folder.appending(path: "restart.sqlite"))
        var earlier = job
        earlier.id = "earlier"
        earlier.kind = .fix
        earlier.pr = nil
        earlier.base = "dev"
        earlier.branch = "oby/fix-77"
        earlier.status = .done
        earlier.commits = 2
        earlier.finished = .now.addingTimeInterval(-3 * 3600)
        var failedBefore = earlier
        failedBefore.id = "failedbefore"
        failedBefore.publishError = "Couldn't push oby/fix-75: the remote hung up."
        var running = earlier
        running.id = "running"
        running.status = .running
        running.finished = nil
        for job in [earlier, failedBefore, running] { store.save(job) }

        let restarted = Desk(accounts: AccountStore(root: folder), store: store)
        restarted.makeAgent = { [agent] _, _, _ in agent }
        restarted.prepare = { $0 }
        restarted.countCommits = { _, _ in 1 }
        restarted.publishOnItsOwn = { [published] job, _, _ in
            published.jobs.append(job)
            return URL(string: "https://github.com/deskree-inc/oby/pull/81")!
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(published.jobs.isEmpty)
        #expect(restarted.job("earlier")?.canPublish == true && restarted.job("earlier")?.published == nil)
        #expect(restarted.job("failedbefore")?.publishError == "Couldn't push oby/fix-75: the remote hung up.")
        #expect(restarted.job("running")?.status == .interrupted)

        // A job dispatched after the restart finishes now, and publishes.
        var new = job
        new.id = "new"
        new.kind = .fix
        new.pr = nil
        new.base = "dev"
        new.branch = "oby/fix-80"
        restarted.dispatch(new)
        for _ in 0..<500 where restarted.job("new")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        agent.onEvent(.turnEnded(summary: "fix(engine): publish only what ends now", failed: false))
        agent.onEvent(.finished(summary: "fix(engine): publish only what ends now", failed: false))
        for _ in 0..<500 where restarted.job("new")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(published.jobs.map(\.id) == ["new"])
        #expect(restarted.job("new")?.published == "https://github.com/deskree-inc/oby/pull/81")
        #expect(restarted.job("earlier")?.published == nil)
    }

    /// Its commits reached the base by a squash merge: nothing is published and nothing waits for Publish.
    @Test func workAlreadyOnTheBaseIsntPublished() async throws {
        let ended = try await run("merged", commits: 2) { _ in throw Publish.AlreadyOnBase(base: "dev") }
        #expect(published.jobs.count == 1)
        #expect(ended.status == .done && ended.published == nil && ended.commits == 0)
        #expect(!ended.canPublish && !ended.needsYou && ended.publishError == nil && Push.notice(for: ended) == nil)
        #expect(ended.summary.hasPrefix("Not published: its commits are already on dev.\n\nfix(engine): open the PR by itself"))
    }

    /// Its own publish failed, then its commits reached the base: Publish by hand finds nothing to
    /// publish, and the job stops waiting for it, as when it publishes by itself. Its alert clears.
    @Test func publishByHandFindsTheWorkAlreadyOnTheBase() async throws {
        let failed = try await run("byhand", commits: 2) { _ in throw Shell.Failure(message: "Couldn't push oby/fix-75: the remote hung up.") }
        #expect(failed.canPublish && Push.notice(for: failed) == .ready)
        let alerted = Push.notices([failed], after: [:]).notified
        desk.publishByHand = { _, base, _, _ in throw Publish.AlreadyOnBase(base: base) }
        await #expect(throws: Publish.AlreadyOnBase.self) { try await desk.publish("byhand") { _ in } }
        let ended = try #require(desk.job("byhand"))
        #expect(ended.status == .done && ended.published == nil && ended.commits == 0)
        #expect(!ended.canPublish && !ended.needsYou && ended.publishError == nil && Push.notice(for: ended) == nil)
        #expect(ended.summary.hasPrefix("Not published: its commits are already on dev.\n\nfix(engine): open the PR by itself"))
        let cleared = Push.notices([ended], after: alerted).changes
        #expect(cleared.count == 1 && cleared.first?.0.id == "byhand" && cleared.first?.1 == nil)
        // Nothing is left to publish.
        await #expect(throws: Shell.Failure.self) { try await desk.publish("byhand") { _ in } }
    }

    /// Its own publish failed: Oby doesn't try again by itself, not when the agent's process ends
    /// after its last turn, nor when the user talks to it and it makes no new commits. Publish by hand is offered.
    @Test func aJobsOwnPublishIsntRetried() async throws {
        let first = try await run("retry", commits: 2) { _ in throw Shell.Failure(message: "Couldn't push oby/fix-75: the remote hung up.") }
        #expect(first.publishError == "Couldn't push oby/fix-75: the remote hung up.")
        agent.onEvent(.finished(summary: "fix(engine): open the PR by itself", failed: false))
        try desk.message("retry", "is it on GitHub yet?")
        for _ in 0..<500 where desk.job("retry")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        agent.onEvent(.turnEnded(summary: "No: Oby publishes it.", failed: false))
        agent.onEvent(.finished(summary: "No: Oby publishes it.", failed: false))
        for _ in 0..<500 where desk.job("retry")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        let again = try #require(desk.job("retry"))
        #expect(published.jobs.count == 1)
        #expect(again.status == .done && again.canPublish && again.needsYou && again.published == nil)
        #expect(again.publishError == "Couldn't push oby/fix-75: the remote hung up." && Push.notice(for: again) == .ready)
    }
}

/// Publish compares the job's commits with its base by patch: a squash merge or a cherry-pick
/// changes their hashes, not what they change.
struct AlreadyOnBaseTests {
    let repo: URL

    init() async throws {
        repo = try temporaryFolder()
        try await Shell.ok(["git", "-C", repo.path, "init", "--quiet", "-b", "dev"])
        try await Self.commit("README.md", in: repo)
        try await Self.git(["switch", "--quiet", "-c", "oby/fix-1"], in: repo)
        try await Self.commit("a.txt", in: repo)
        try await Self.commit("b.txt", in: repo)
        try await Self.git(["switch", "--quiet", "dev"], in: repo)
    }

    @discardableResult
    static func git(_ arguments: [String], in repo: URL) async throws -> String {
        try await Shell.ok(["git", "-C", repo.path, "-c", "user.name=Oby", "-c", "user.email=oby@example.com",
                            "-c", "commit.gpgsign=false"] + arguments)
    }

    @discardableResult
    static func commit(_ file: String, in repo: URL) async throws -> String {
        try "\(file)\n".write(to: repo.appending(path: file), atomically: true, encoding: .utf8)
        try await git(["add", file], in: repo)
        try await git(["commit", "--quiet", "-m", "add \(file)"], in: repo)
        return try await git(["rev-parse", "HEAD"], in: repo)
    }

    /// GitHub's dev, as Publish reads it.
    func origin() async throws { try await Self.git(["update-ref", "refs/remotes/origin/dev", "dev"], in: repo) }

    @Test func newWorkIsLeftToPublish() async throws {
        try await origin()
        #expect(await Publish.unmerged(repo, base: "dev", head: "oby/fix-1") == 2)
    }

    @Test func aSquashMergeCountsAsOnTheBase() async throws {
        try await Self.git(["merge", "--quiet", "--squash", "oby/fix-1"], in: repo)
        try await Self.git(["commit", "--quiet", "-m", "fix: both files (#77)"], in: repo)
        try await Self.commit("later.txt", in: repo)
        try await origin()
        #expect(await Publish.unmerged(repo, base: "dev", head: "oby/fix-1") == 0)
    }

    @Test func aCherryPickedCommitCountsAsOnTheBase() async throws {
        try await Self.git(["cherry-pick", "oby/fix-1~1"], in: repo)
        try await origin()
        #expect(await Publish.unmerged(repo, base: "dev", head: "oby/fix-1") == 1)
        try await Self.git(["cherry-pick", "oby/fix-1"], in: repo)
        try await origin()
        #expect(await Publish.unmerged(repo, base: "dev", head: "oby/fix-1") == 0)
    }

    @Test func noBaseToCompareWithSaysSo() async throws {
        #expect(await Publish.unmerged(repo, base: "dev", head: "oby/fix-1") == nil)
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
        #expect(!body.contains("Part of #75"))
        #expect(body.hasSuffix("by Oby: Oby opened this pull request after the check passed and the secret scan was clean. Oby merges it into dev once its review approves and the checks on the user's Mac pass on the same commit."))
        job.check = nil
        job.issue = nil
        job.summaries = nil
        let plain = Publish.body(for: job)
        #expect(plain.hasPrefix("The agent's summary:\n\n```\nOby opens the PR by itself.\n\nMore detail.\n```"))
        #expect(plain.contains("- Check: none, the job had no check.") && !plain.contains("Closes"))
    }

    @Test func aPullRequestDoesntCloseAnIssueWithAChecklist() {
        // Like #116: an epic whose Build items merge one slice at a time.
        let epic = "> **What you get.** Oby does it all.\n\n## Build\n\n- [x] **Landing**\n- [ ] **The runner deploys itself.**"
        #expect(!Publish.closes(issue: epic))
        #expect(!Publish.closes(issue: "## Build\n\n  - [X] Done already"))
        #expect(Publish.closes(issue: "The Watch shows the wrong time.\n\n- It's an hour off.\n- [link](https://example.com)"))
        var job = work
        job.summaries = ["Fixed it."]
        let body = Publish.body(for: job, closes: false)
        #expect(body.contains("\n\nPart of #75\n\n") && !body.contains("Closes"))
        // The secret scan checks that very description.
        let scanned = Publish.outgoing(job, messages: "fix: it", title: "fix: it", closes: false).first { $0.name == "pull request description" }
        #expect(scanned?.text == body)
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

@MainActor
struct PublishCommitFindingTests {
    let repo: URL
    let key = "AKIA" + "ABCDEFGHIJKLMNOP"

    init() async throws {
        repo = try temporaryFolder()
        try await AlreadyOnBaseTests.git(["init", "--quiet", "-b", "dev"], in: repo)
        try "baseline\n".write(to: repo.appending(path: "sample.swift"), atomically: true, encoding: .utf8)
        try await AlreadyOnBaseTests.git(["add", "sample.swift"], in: repo)
        try await AlreadyOnBaseTests.git(["commit", "--quiet", "-m", "baseline"], in: repo)
        try await AlreadyOnBaseTests.git(["switch", "--quiet", "-c", "oby/fix-404"], in: repo)
        try await AlreadyOnBaseTests.git(["update-ref", "refs/remotes/origin/dev", "dev"], in: repo)
    }

    func addKeyCommit() async throws -> String {
        try "let key = \"\(key)\"\n".write(to: repo.appending(path: "sample.swift"), atomically: true, encoding: .utf8)
        try await AlreadyOnBaseTests.git(["add", "sample.swift"], in: repo)
        try await AlreadyOnBaseTests.git(["commit", "--quiet", "-m", "add example key"], in: repo)
        return try await AlreadyOnBaseTests.git(["rev-parse", "HEAD"], in: repo)
    }

    @Test func removedFindingStillNamesItsIntroducingCommitAndRebasePrompt() async throws {
        let introducing = try await addKeyCommit()
        try "safe\n".write(to: repo.appending(path: "sample.swift"), atomically: true, encoding: .utf8)
        try await AlreadyOnBaseTests.git(["add", "sample.swift"], in: repo)
        try await AlreadyOnBaseTests.git(["commit", "--quiet", "-m", "remove example key"], in: repo)

        let findings = try await Publish.scan(repo, base: "dev")
        let finding = try #require(findings.first { $0.rule == "AWS access key" })
        #expect(finding.commit == introducing)
        #expect(finding.historyOnly)
        let prompt = Prompts.publishFix(findings, base: "dev")
        #expect(prompt.contains(introducing))
        #expect(prompt.contains("git commit --fixup=<commit>"))
        #expect(prompt.contains("GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash origin/dev"))
        #expect(prompt.contains("already gone from the branch tip"))
    }

    @Test func autosquashRemovesTheFindingFromEveryCommit() async throws {
        let introducing = try await addKeyCommit()
        try "let key = \"safe-example\"\n".write(to: repo.appending(path: "sample.swift"), atomically: true, encoding: .utf8)
        try await AlreadyOnBaseTests.git(["add", "sample.swift"], in: repo)
        try await AlreadyOnBaseTests.git(["commit", "--quiet", "--fixup=\(introducing)"], in: repo)
        try await AlreadyOnBaseTests.git(["-c", "sequence.editor=:", "rebase", "-i", "--autosquash", "origin/dev"], in: repo)

        #expect(try await Publish.scan(repo, base: "dev").isEmpty)
    }

    @Test func delimiterTextInAPatchDoesntHideLaterFindings() async throws {
        try "let marker = \"__OBY_COMMIT__\"\nlet other = \"\(key)\"\n"
            .write(to: repo.appending(path: "sample.swift"), atomically: true, encoding: .utf8)
        try await AlreadyOnBaseTests.git(["add", "sample.swift"], in: repo)
        try await AlreadyOnBaseTests.git(["commit", "--quiet", "-m", "include delimiter text"], in: repo)
        let introducing = try await AlreadyOnBaseTests.git(["rev-parse", "HEAD"], in: repo)

        let findings = try await Publish.scan(repo, base: "dev")
        #expect(findings.contains { $0.commit == introducing && $0.rule == "AWS access key" })
    }

    @Test func commitMessageFindingNamesCommitAndGetsARewordFixupPrompt() async throws {
        let key = "AKIA" + "ABCDEFGHIJKLMNOP"
        try "benign change\n".write(to: repo.appending(path: "message.txt"), atomically: true, encoding: .utf8)
        try await AlreadyOnBaseTests.git(["add", "message.txt"], in: repo)
        try await AlreadyOnBaseTests.git(["commit", "--quiet", "-m", "example \(key)"], in: repo)
        let introducing = try await AlreadyOnBaseTests.git(["rev-parse", "HEAD"], in: repo)

        let findings = try await Publish.scanCommitMessages(repo, base: "dev")
        let finding = try #require(findings.first { $0.rule == "AWS access key" })
        #expect(finding.file == "commit message" && finding.commit == introducing)
        let prompt = Prompts.publishFix(findings, base: "dev")
        #expect(prompt.contains("git commit --fixup=reword:<commit>"))
        #expect(prompt.contains("GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash origin/dev"))
        #expect(prompt.contains("must be removed by rewriting that message"))
        #expect(!prompt.contains("removed from that commit's patch"))
    }
}
