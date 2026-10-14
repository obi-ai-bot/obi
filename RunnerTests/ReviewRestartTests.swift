import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

/// A review that ends while the runner restarts keeps its verdict (#212): the update waits for the
/// verdict to reach the author, and a restart that cut it short anyway applies it when the runner
/// starts again (Engine/Review.swift, Runner/Updates.swift).
@MainActor
struct ReviewRestartTests {
    final class Made {
        var agents: [(job: Job, agent: ReviewTests.Agent, resume: String?)] = []
        var posted: [(author: Job, run: CheckRun)] = []
        var quoted: [(author: Job, file: String, text: String)] = []
        /// The check run waits while this is set: the runner is posting it.
        var holdPost = false
        var restarts = 0
    }

    let folder: URL
    let accounts: AccountStore
    let work: Account
    let desk: Desk
    let made = Made()
    let url = URL(string: "https://github.com/deskree-inc/oby/pull/80")!
    let head = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"

    init() throws {
        folder = try temporaryFolder()
        accounts = AccountStore(root: folder)
        let personal = try accounts.add(agent: "claude", name: "Personal", payer: "")
        work = try accounts.add(agent: "codex", name: "Work", payer: "Deskree")
        accounts.setLabel("Max · well@example.com", for: "default")
        accounts.setLabel("Max · personal@example.com", for: personal.id)
        accounts.setLabel("Plus · work@example.com", for: work.id)
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")),
                    restarts: Restarts(file: folder.appending(path: "restarts.json")))
        configure(desk)
    }

    /// The fakes a desk gets, this one or the one the runner starts again with.
    func configure(_ desk: Desk) {
        desk.prepare = { $0 }
        desk.makeAgent = { [made] job, _, resume in
            let agent = ReviewTests.Agent()
            made.agents.append((job, agent, resume))
            return agent
        }
        desk.countCommits = { _, since in since.hasPrefix("refs/oby/pr-") ? 0 : 2 }
        desk.publishOnItsOwn = { [url, head] job, _, hooks in
            hooks.sent(Outgoing(action: .push, repo: job.repo, id: head, branch: job.branch))
            return url
        }
        desk.postReview = { [made] author, run in
            while made.holdPost { try await Task.sleep(for: .milliseconds(10)) }
            made.posted.append((author, run))
            return URL(string: "https://github.com/deskree-inc/oby/runs/1")!
        }
        desk.quoteReview = { [made] author, file, text in made.quoted.append((author, file, text)) }
        desk.reviewedHead = { [head] _ in head }
    }

    var author: Job {
        var job = job
        job.id = "author"
        job.kind = .fix
        job.pr = nil
        job.issue = 75
        job.base = "dev"
        job.branch = "oby/fix-75"
        job.task = "Open the pull request by itself when the check passes."
        return job
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    /// The runner's update, with a commit built and tested by fakes, restarting into `made.restarts`.
    func updates() throws -> Updates {
        let root = folder.appending(path: "updates")
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appending(path: ".build/release"), withIntermediateDirectories: true)
        try Data("new binary".utf8).write(to: source.appending(path: ".build/release/oby-runner"))
        let binary = folder.appending(path: "oby-runner")
        try Data("old binary".utf8).write(to: binary)
        let updates = Updates(desk: desk, root: root, binary: binary)
        updates.command = { args, _, _ in args.prefix(2) == ["git", "rev-parse"] ? String(repeating: "a", count: 40) : "" }
        updates.testCommand = { _, _, _ in Shell.Output(status: 0, out: Data(), err: "") }
        updates.restart = { [made] in made.restarts += 1 }
        return updates
    }

    /// The runner as it starts again on the same folder, after its first refresh.
    func restarted() -> Desk {
        let restored = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")),
                            restarts: Restarts(file: folder.appending(path: "restarts.json")))
        configure(restored)
        return restored
    }

    /// The author published, done, with the review `id` of its pull request ended done with `summary`,
    /// saved as a restart left them.
    func saveEnded(review id: String, summary: String, applied: Bool) {
        let summary = summary
            .replacingOccurrences(of: "Blocking:\n- It crashes", with: "Blocking:\n- It crashes. Evidence: the fixture probe traps on empty input")
            .replacingOccurrences(of: "Blocking:\n- Fix the off-by-one", with: "Blocking:\n- Fix the off-by-one. Evidence: fixture test reports an off-by-one")
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        var published = author
        published.status = .done
        published.session = "e6a24229"
        published.commits = 2
        published.pushed = 2
        published.published = url.absoluteString
        published.outgoing = [Outgoing(action: .push, repo: published.repo, id: head, branch: published.branch)]
        var review = Review.make(for: published, pr: 80, account: work)
        review.id = id
        review.status = .done
        review.summary = summary
        if applied {
            // Its verdict is on the author; its check run and hand-off never happened.
            var result = Review(verdict: Review.decide(summary) ?? .changesRequested, job: id, agent: "codex", account: "Work", round: 1)
            result.applying = true
            published.review = result
        } else {
            published.reviewing = id
        }
        store.save(published)
        store.save(review)
    }

    // MARK: Draining

    @Test func aReviewThatEndsDuringADrainIsAppliedBeforeTheRestart() async throws {
        desk.dispatch(author)
        try await until("the author runs") { desk.job("author")?.status == .running }
        let first = try #require(made.agents.last?.agent)
        first.onEvent(.session("e6a24229"))
        first.onEvent(.turnEnded(summary: "fix(engine): open the PR by itself", failed: false))
        first.onEvent(.finished(summary: "fix(engine): open the PR by itself", failed: false))
        try await until("a review job runs") { made.agents.last?.job.reviewOf == "author" && made.agents.last?.job.status == .running }
        let reviewer = try #require(made.agents.last)

        let date = Date()
        let updates = try updates()
        updates.now = { date }
        await updates.poll()
        #expect(updates.status.phase == "draining" && made.restarts == 0)

        // The review ends as the runner drains, and its check run takes a while to post.
        made.holdPost = true
        let text = "Two things to fix.\n\nBlocking:\n- Fix the off-by-one. Evidence: fixture test reports an off-by-one\n\nVERDICT: CHANGES REQUESTED"
        reviewer.agent.onEvent(.turnEnded(summary: text, failed: false))
        reviewer.agent.onEvent(.finished(summary: text, failed: false))
        try await until("the verdict is on the author") { desk.job("author")?.review?.verdict == .changesRequested }
        #expect(desk.job("author")?.review?.applying == true)
        // Every agent is idle, but the verdict is on its way: no restart, not even past the drain limit.
        #expect(!desk.updateIsBetweenSteps)
        updates.deployIfReady()
        updates.now = { date.addingTimeInterval(Updates.drainLimit) }
        updates.deployIfReady()
        #expect(made.restarts == 0 && made.posted.isEmpty)

        made.holdPost = false
        try await until("the hand-off waits for the update") { desk.job("author")?.status == .running && desk.updateIsIdle }
        updates.deployIfReady()
        #expect(made.restarts == 1)
        let applied = try #require(desk.job("author")?.review)
        #expect(applied.applying == nil && applied.checkRun == "https://github.com/deskree-inc/oby/runs/1")
        #expect(made.posted.count == 1 && made.quoted.map(\.file) == ["review-1.md"])
        // The round was held for the update: no agent took it before the restart.
        #expect(made.agents.count == 2)

        // The runner starts again: the author's agent takes the review up in its own session.
        let restored = restarted()
        restored.resumeAfterRestart()
        try await until("the author runs again") { made.agents.count == 3 }
        let round = try #require(made.agents.last)
        #expect(round.job.id == "author" && round.resume == "e6a24229")
        #expect(round.agent.prompt.hasPrefix(Restarts.noticeWithMessage) && round.agent.prompt.contains(".oby/inputs/review-1.md"))
        #expect(made.posted.count == 1 && restored.job("author")?.round == 2)
        restored.quit()
    }

    // MARK: Recovering on start

    @Test func aReviewThatEndedBeforeItsVerdictReachedTheAuthorIsAppliedOnStart() async throws {
        saveEnded(review: "rev1", summary: "One thing.\n\nBlocking:\n- It crashes\n\nVERDICT: CHANGES REQUESTED", applied: false)
        let restored = restarted()
        #expect(restored.job("author")?.reviewing == "rev1")
        restored.resumeAfterRestart()
        try await until("the author runs again") { restored.job("author")?.status == .running && made.agents.count == 1 }
        let author = try #require(restored.job("author"))
        #expect(author.reviewing == nil && author.review?.verdict == .changesRequested && author.review?.round == 1)
        #expect(author.review?.checkRun == "https://github.com/deskree-inc/oby/runs/1" && author.review?.applying == nil)
        #expect(made.posted.count == 1 && made.posted.first?.run.head == head)
        #expect(made.quoted.map(\.file) == ["review-1.md"] && made.agents.first?.resume == "e6a24229")
        restored.quit()
    }

    @Test func aVerdictWhoseCheckRunAndRoundARestartCutShortGetsThemOnStart() async throws {
        saveEnded(review: "rev1", summary: "One thing.\n\nBlocking:\n- It crashes\n\nVERDICT: CHANGES REQUESTED", applied: true)
        let restored = restarted()
        restored.resumeAfterRestart()
        try await until("the author runs again") { restored.job("author")?.status == .running && made.agents.count == 1 }
        #expect(restored.job("author")?.review?.round == 1 && restored.job("author")?.review?.applying == nil)
        #expect(made.posted.count == 1 && made.quoted.map(\.file) == ["review-1.md"])
        // Applied once: starting again changes nothing.
        restored.resumeAfterRestart()
        try await Task.sleep(for: .milliseconds(50))
        #expect(made.posted.count == 1 && made.agents.count == 1)
        restored.quit()
    }

    @Test func anApprovalARestartCutShortQueuesItsMacCheckOnStart() async throws {
        saveEnded(review: "rev1", summary: "Looks right.\n\nVERDICT: APPROVED", applied: true)
        let restored = restarted()
        restored.queuesMacChecks = true
        restored.resumeAfterRestart()
        try await until("the Mac check is queued and the check run posted") {
            restored.job("author")?.macCheck != nil && restored.job("author")?.review?.applying == nil
        }
        let author = try #require(restored.job("author"))
        #expect(author.macCheck?.state == .queued && author.macCheck?.head == head)
        #expect(author.review?.checkRun != nil && made.posted.count == 1 && made.agents.isEmpty)
    }

    // MARK: Where a crash can land

    /// Every state of the author saved while its verdict is applied is one the runner finishes when a
    /// crash leaves it there: still `applying`, or its Mac check or its round (with its message in
    /// the restart journal) saved with the marker gone (#212).
    @Test(arguments: ["One thing.\n\nBlocking:\n- It crashes\n\nVERDICT: CHANGES REQUESTED", "Looks right.\n\nVERDICT: APPROVED"])
    func everyStateACrashCanLeaveFinishesTheVerdict(summary: String) async throws {
        saveEnded(review: "rev1", summary: summary, applied: false)
        let restored = restarted()
        restored.queuesMacChecks = true
        var lost: [String] = []
        restored.onJobChange = { [weak restored] job in
            let ended = job.id == "author" && job.review?.job == "rev1" && job.review?.applying == nil
            if ended && job.review?.verdict == .approved && job.macCheck?.state != .queued {
                lost.append("an approval saved without its Mac check")
            }
            if ended && job.review?.verdict == .changesRequested
                && (job.status != .running || restored?.restarts?.message("author")?.contains("review-1.md") != true) {
                lost.append("changes requested saved without the round and its message")
            }
        }
        restored.resumeAfterRestart()
        try await until("the verdict is applied") { restored.job("author")?.review?.applying == nil && restored.wrappingUp.isEmpty }
        #expect(lost.isEmpty)
        let expected = summary.contains("Blocking:") ? Review.Verdict.changesRequested : .approved
        #expect(restored.job("author")?.review?.verdict == expected)
        #expect(made.posted.count == 1)
        restored.quit()
    }

    @Test func aCrashAfterTheRoundsMessageWasSavedStartsTheRoundOnce() async throws {
        saveEnded(review: "rev1", summary: "One thing.\n\nBlocking:\n- It crashes\n\nVERDICT: CHANGES REQUESTED", applied: true)
        // The round's message reached the journal; the round itself was never saved.
        Restarts(file: folder.appending(path: "restarts.json")).give("author", "The round's message, as it was saved")
        let restored = restarted()
        restored.resumeAfterRestart()
        try await until("the author runs again") { restored.job("author")?.status == .running && made.agents.count == 1 }
        let round = try #require(made.agents.first)
        #expect(round.resume == "e6a24229" && round.agent.prompt.contains(".oby/inputs/review-1.md"))
        #expect(!round.agent.prompt.contains("as it was saved") && !round.agent.prompt.hasPrefix(Restarts.notice))
        #expect(restored.job("author")?.round == 2 && made.quoted.map(\.file) == ["review-1.md"])
        restored.quit()
    }
}
