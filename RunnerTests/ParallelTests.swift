import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// Jobs run in parallel like Claude Code's worktrees (#237): a claim on the same files holds no job
/// back, at most `maxRunning` jobs run at once, overlapping pull requests merge oldest first, and a
/// rebase that keeps the same patch goes straight to its Mac check.
@MainActor
struct ParallelTests {
    final class Made {
        var agents: [(job: Job, agent: CheckTests.Agent)] = []
    }

    nonisolated static let dev = String(repeating: "a", count: 40)

    let folder: URL
    let desk: Desk
    let made = Made()
    let now = Date.now

    init() throws {
        folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max · well@example.com", for: "default")
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.prepare = { job in
            var job = job
            job.startCommit = ParallelTests.dev
            return job
        }
        desk.fetchBase = { _, _ in ParallelTests.dev }
        desk.makeAgent = { [made] job, _, _ in
            let agent = CheckTests.Agent()
            made.agents.append((job, agent))
            return agent
        }
        desk.maxRunning = 6
    }

    /// A fix job in deskree-inc/oby claiming `files`, made `age` seconds after the test began.
    func job(_ id: String, files: [String]? = ["Engine/Desk.swift"], age: TimeInterval = 0) -> Job {
        var job = Job(id: id, request: "fix \(id)", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-\(id)", base: "dev", pr: nil, kind: .fix, task: "Fix \(id)")
        job.files = files
        job.created = now.addingTimeInterval(age)
        return job
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    // MARK: Parallel by default

    @Test func twoJobsClaimingDeskSwiftBothStart() async throws {
        desk.maxRunning = 2
        desk.enqueue(job("a"))
        desk.enqueue(job("b", files: ["Engine/Desk.swift", "Engine/Jobs.swift"], age: 1))
        try await until("both run") { desk.job("a")?.status == .running && desk.job("b")?.status == .running }
        #expect(made.agents.count == 2 && desk.runningCount == 2)
        #expect(Desk.overlap(try #require(desk.job("b")), try #require(desk.job("a"))) == ["Engine/Desk.swift"])
    }

    // MARK: A cap instead of a line

    /// A 7th job waits while 6 run, and starts when one ends: the oldest waiting first. Raising the
    /// cap starts the rest at once.
    @Test func aSeventhJobWaitsWhileSixRunAndStartsWhenOneEnds() async throws {
        for index in 1...8 { desk.enqueue(job("j\(index)", files: nil, age: Double(index))) }
        try await until("six run, two wait") { desk.runningCount == 6 && desk.job("j8")?.step.hasPrefix("Waiting for") == true }
        for id in ["j7", "j8"] {
            let waiting = try #require(desk.job(id))
            #expect(waiting.status == .queued && waiting.step == "Waiting for a free slot: 6 of 6 jobs running")
        }
        #expect(made.agents.map(\.job.id) == (1...6).map { "j\($0)" })

        desk.stop("j3")
        try await until("the 7th runs") { desk.job("j7")?.status == .running }
        #expect(desk.job("j8")?.status == .queued && made.agents.count == 7 && desk.runningCount == 6)

        desk.maxRunning = 7
        try await until("the 8th runs") { desk.job("j8")?.status == .running }
        #expect(made.agents.count == 8 && desk.runningCount == 7)
    }

    /// A job that caught up gives its slot to an older job that started waiting meanwhile, and that
    /// older job starts: a free slot never sits unused while jobs wait (review of #246).
    @Test func aSlotGivenBackToAnOlderJobIsTaken() async throws {
        desk.maxRunning = 1
        let older = MoveJobTests.Gate()
        let fetched = MoveJobTests.Gate()
        desk.prepare = { job in
            if job.id == "older" { await older.wait() }
            var job = job
            job.startCommit = ParallelTests.dev
            return job
        }
        desk.fetchBase = { job, _ in
            if job.id == "newer" { await fetched.wait() }
            return ParallelTests.dev
        }
        desk.enqueue(job("first"))
        try await until("the first runs") { desk.job("first")?.status == .running }
        desk.enqueue(job("newer", age: 2))
        try await until("the newer one waits") { desk.job("newer")?.step.hasPrefix("Waiting for a free slot") == true }
        // Made earlier, in another repository, so its setup runs on its own and ends later.
        var made = job("older", age: 1)
        made.repo = "deskree-inc/other"
        desk.enqueue(made)

        // The first ends: the newer one takes the slot and catches up, and the older one gets ready meanwhile.
        desk.stop("first")
        try await until("the newer one catches up") { desk.job("newer")?.step.hasPrefix("Bringing") == true }
        older.release()
        try await until("the older one waits") { desk.job("older")?.step.hasPrefix("Waiting for a free slot") == true }
        fetched.release()
        try await until("the older one runs") { desk.job("older")?.status == .running }
        #expect(desk.job("newer")?.status == .queued && desk.runningCount == 1)

        // Its turn comes when the older one ends.
        desk.stop("older")
        try await until("the newer one runs") { desk.job("newer")?.status == .running }
    }

    /// Reviews and rebase rounds take a slot like any running job; a job waiting for the user's
    /// answer takes none.
    /// Oby's reviews take the next free slot before new jobs that waited longer (2026-10-13): they
    /// finish work that's nearly done and unblock its merge.
    @Test func reviewsTakeTheNextSlotBeforeOlderNewJobs() {
        var older = Job(id: "older", request: "fix oby", agent: "claude", account: "default", repo: "deskree-inc/oby",
                        branch: "oby/fix-1", base: "dev", kind: .fix, task: "fix oby")
        older.created = Date(timeIntervalSince1970: 100)
        var review = older
        review.id = "review"
        review.reviewOf = "author"
        review.created = Date(timeIntervalSince1970: 200)
        var newer = older
        newer.id = "newer"
        newer.created = Date(timeIntervalSince1970: 300)
        #expect(Desk.goesFirst(review, older) && !Desk.goesFirst(older, review))
        #expect([newer, older, review].sorted(by: Desk.goesFirst).map(\.id) == ["review", "older", "newer"])
    }

    @Test func whatTakesASlot() {
        var running = job("r")
        running.status = .running
        #expect(running.takesSlot)
        var review = running
        review.reviewOf = "author"
        #expect(review.takesSlot)
        running.question = Plan.Question(text: "Which one?", options: [])
        #expect(!running.takesSlot)
        #expect(!job("q").takesSlot)
    }

    // MARK: Claims tell the agent

    @Test func anOverlappingJobsPromptNamesTheOtherJobsBranch() async throws {
        desk.enqueue(job("a"))
        try await until("a runs") { desk.job("a")?.status == .running }
        desk.enqueue(job("c", files: ["Mac/"], age: 1))
        desk.enqueue(job("b", files: ["Engine/"], age: 2))
        try await until("b runs") { desk.job("b")?.status == .running }
        let prompt = { (id: String) in made.agents.first { $0.job.id == id }?.agent.prompt ?? "" }
        #expect(prompt("b").contains("Other jobs are changing the same files right now, each on its own branch:\n\n- fix a (job a) on the branch oby/fix-a: both touch Engine/\n\n"))
        #expect(prompt("b").contains("expect a rebase") && !prompt("b").contains("oby/fix-c"))
        // Nothing overlapped c, nor a when it started.
        #expect(!prompt("a").contains("Other jobs") && !prompt("c").contains("Other jobs"))

        // A job in review still claims its files: its pull request is named too.
        var published = job("p", files: ["Engine/Desk.swift"])
        published.status = .done
        published.published = "https://github.com/deskree-inc/oby/pull/240"
        let line = try #require(Prompts.alongsideLine(job("n"), [published, job("n")]))
        #expect(line.contains("- fix p (job p) on the branch oby/fix-p, pull request https://github.com/deskree-inc/oby/pull/240: both touch Engine/Desk.swift"))
        published.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now)
        #expect(!published.holdsClaim)
        #expect(Prompts.alongsideLine(job("n"), []) == nil)
    }

    // MARK: Merge order

    /// Two approved pull requests touch the same file: the older job's Mac check is taken first,
    /// even when the newer one's was queued earlier, and the newer one's waits until it merged. One
    /// on other files isn't held.
    @Test func whenTwoApprovedPullRequestsOverlapTheOlderMergesFirst() throws {
        let store = JobStore(url: folder.appending(path: "merges.sqlite"))
        func approved(_ id: String, pr: Int, files: [String], age: TimeInterval, queued: TimeInterval) -> Job {
            var author = job(id, files: files, age: age)
            author.status = .done
            author.published = "https://github.com/deskree-inc/oby/pull/\(pr)"
            author.outgoing = [Outgoing(action: .push, repo: author.repo, id: "\(id)000", branch: author.branch)]
            author.review = Review(verdict: .approved, job: "review-\(id)", agent: "codex", account: "Work", round: 1)
            author.macCheck = MacCheck.make(for: author, pr: pr, head: "\(id)000")
            author.macCheck?.created = now.addingTimeInterval(queued)
            return author
        }
        store.save(approved("older", pr: 1, files: ["Engine/Desk.swift"], age: -300, queued: -10))
        store.save(approved("newer", pr: 2, files: ["Engine/Desk.swift", "Engine/Jobs.swift"], age: -200, queued: -60))
        store.save(approved("other", pr: 3, files: ["Mac/"], age: -100, queued: -5))
        let desk = Desk(accounts: AccountStore(root: folder), store: store)
        desk.queuesMacChecks = true
        #expect(desk.mergesAfter(try #require(desk.job("newer")))?.id == "older")

        #expect(desk.nextMacCheck(mac: "Studio")?.job == "older")
        // The older one is being checked: the newer one still waits, the other goes. Other Macs ask:
        // Studio asking again would get back the check it holds (#227).
        #expect(desk.nextMacCheck(mac: "Laptop")?.job == "other")
        #expect(desk.nextMacCheck(mac: "Mini") == nil)

        // Merged: the newer one's turn (a conflict with what merged is rebased then).
        var older = try #require(desk.job("older"))
        older.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now)
        desk.replace(older)
        #expect(desk.nextMacCheck(mac: "Mini")?.job == "newer")
    }

    /// The older one's merge stopped (it needs a person): the newer one isn't held behind it.
    @Test func aStoppedMergeHoldsNoOneBack() throws {
        var older = job("older", age: -300)
        older.status = .done
        older.published = "https://github.com/deskree-inc/oby/pull/1"
        older.outgoing = [Outgoing(action: .push, repo: older.repo, id: "head", branch: older.branch)]
        older.macCheck = MacCheck.make(for: older, pr: 1, head: "head")
        #expect(older.awaitsMerge)
        older.mergeError = "Not merged: the secret scan couldn't run."
        #expect(!older.awaitsMerge)
        older.mergeError = nil
        older.macCheck?.state = .failed
        #expect(!older.awaitsMerge)
    }

    // MARK: Rebases that cost less

    /// A rebase whose `git range-diff` shows the same patch isn't reviewed again: the approval
    /// carries over to the new head, its Mac check is queued at once, and it merges.
    @Test func aRebaseWithAnUnchangedRangeDiffSkipsTheReReview() async throws {
        let checks = try CheckTests()
        let (desk, made) = (checks.desk, checks.made)
        final class Asked { var calls: [[String]] = [] }
        let asked = Asked()
        desk.samePatch = { id, from, onto, to in
            asked.calls.append([id, from, onto, to])
            return true
        }
        desk.fetchBase = { _, _ in CheckTests.onto }
        try await rebase(checks)
        try await checks.until("its Mac check is queued") { desk.job("author")?.macCheck?.head == CheckTests.next }
        let author = try #require(desk.job("author"))
        #expect(asked.calls == [["author", CheckTests.head, CheckTests.onto, CheckTests.next]])
        #expect(author.macCheck?.state == .queued && author.reviewing == nil && author.review?.verdict == .approved && author.rebasedFrom == nil)
        #expect(author.summary.contains("Rebased onto dev with the same patch: Oby's approval carries over to aaaabbbbcccc, and its Mac check is next."))
        // No review job: the author, its review, and its rebase round.
        #expect(made.agents.count == 3 && made.events.last?.head == CheckTests.next)

        let check = try #require(desk.nextMacCheck(mac: "Studio"))
        try desk.macCheckEnded(check.id, MacCheck.Report(passed: true, steps: checks.steps, failures: []))
        try await checks.until("it merges") { made.merged.count == 1 }
        #expect(made.merged.first?.head == CheckTests.next)
    }

    /// A rebase that changed the patch is reviewed as before.
    @Test func aRebaseThatChangedThePatchIsReviewedAgain() async throws {
        let checks = try CheckTests()
        let (desk, made) = (checks.desk, checks.made)
        desk.fetchBase = { _, _ in CheckTests.onto }
        try await rebase(checks)
        try await checks.until("a review runs") { made.agents.last?.job.reviewOf == "author" }
        #expect(made.agents.count == 4 && desk.job("author")?.reviewing == made.agents.last?.job.id)
    }

    /// The author is approved, its merge conflicts, and its rebase round publishes the new head.
    func rebase(_ checks: CheckTests) async throws {
        let (desk, made) = (checks.desk, checks.made)
        let check = try await checks.approved()
        _ = desk.nextMacCheck(mac: "Studio")
        made.mergeError = MacCheck.Conflict(base: "dev")
        try desk.macCheckEnded(check.id, MacCheck.Report(passed: true, steps: checks.steps, failures: []))
        try await checks.until("the author rebases") { desk.job("author")?.status == .running && made.agents.count == 3 }
        #expect(desk.job("author")?.rebasedFrom == CheckTests.head)
        made.mergeError = nil
        desk.countUnpushed = { _, _, pushed in pushed == CheckTests.head ? 2 : 0 }
        made.pushes = [CheckTests.next]
        try await checks.endRound(try #require(made.agents.last?.agent), "refactor: rebase onto dev")
    }

    /// What counts as the same patch in `git range-diff`'s output.
    @Test func theSamePatchIsReadFromTheRangeDiff() {
        // A clean rebase: the hunk's context moved, in the file it touched.
        let moved = """
        1:  94a89c8 ! 1:  13e422a fix(engine): run jobs in parallel
            @@ Commit message
                 fix(engine): run jobs in parallel

              ## Engine/Desk.swift ##
            -@@
            +@@ Engine/Desk.swift: final class Desk {
              12
        2:  5d6e7f8 = 2:  9a8b7c6 test: parallel jobs
        """
        #expect(Rebase.same(moved, touched: ["Engine/Desk.swift", "RunnerTests/ParallelTests.swift"]))
        #expect(Rebase.same("1:  94a89c8 = 1:  13e422a fix\n", touched: []))
        // A file the pull request didn't touch, new or not, is a change to review.
        #expect(!Rebase.same(moved, touched: ["RunnerTests/ParallelTests.swift"]))
        let added = moved + "\n    +## Engine/Jobs.swift (new) ##\n    ++hello"
        #expect(!Rebase.same(added, touched: ["Engine/Desk.swift"]))
        #expect(Rebase.same(added, touched: ["Engine/Desk.swift", "Engine/Jobs.swift"]))
        // A commit dropped or added.
        #expect(!Rebase.same("1:  94a89c8 < -:  ------- fix\n-:  ------- > 1:  13e422a fix\n", touched: ["Engine/Desk.swift"]))
        #expect(!Rebase.same("1:  94a89c8 = 1:  13e422a fix\n-:  ------- > 2:  af7af97 more\n", touched: []))
        // Nothing to compare: git said nothing.
        #expect(!Rebase.same("", touched: []))
    }

    /// The real `git range-diff` of a rebase that only resolved a conflict's context, and of one that changed the patch.
    @Test func gitsRangeDiffOfARealRebase() async throws {
        let repo = folder.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        @discardableResult func git(_ arguments: String...) async throws -> String {
            try await Shell.ok(["git", "-C", repo.path, "-c", "user.email=oby@example.com", "-c", "user.name=Oby", "-c", "commit.gpgsign=false"] + arguments)
        }
        func write(_ text: String, _ file: String) throws { try text.write(to: repo.appending(path: file), atomically: true, encoding: .utf8) }
        let lines = (1...20).map(String.init)
        try await git("init", "-q", "-b", "dev")
        try write(lines.joined(separator: "\n") + "\n", "f")
        try await git("add", ".")
        try await git("commit", "-qm", "base")
        try await git("checkout", "-qb", "pr")
        try write(lines.map { $0 == "15" ? "fifteen" : $0 }.joined(separator: "\n") + "\n", "f")
        try await git("commit", "-qam", "fix: fifteen")
        let from = try await git("rev-parse", "HEAD")
        try await git("checkout", "-q", "dev")
        try write(lines.map { $0 == "12" ? "twelve" : $0 }.joined(separator: "\n") + "\n", "f")
        try write("other\n", "g")
        try await git("add", ".")
        try await git("commit", "-qm", "dev moved")
        let onto = try await git("rev-parse", "HEAD")
        try await git("checkout", "-q", "pr")
        try await git("rebase", "-q", "dev")
        let to = try await git("rev-parse", "HEAD")
        #expect(await Rebase.samePatch(worktree: repo, from: from, onto: onto, to: to))
        // The rebase also touched a file the pull request didn't.
        try write("more\n", "g")
        try await git("commit", "-qa", "--amend", "--no-edit")
        #expect(!(await Rebase.samePatch(worktree: repo, from: from, onto: onto, to: try await git("rev-parse", "HEAD"))))
        // Git can't say (no such commit): reviewed again.
        #expect(!(await Rebase.samePatch(worktree: repo, from: String(repeating: "0", count: 40), onto: onto, to: to)))
    }

    @Test func aDayAllowsSixRebases() {
        #expect(Job.rebasesPerDay == 6)
    }

    // MARK: The runner's API

    /// `GET /v1/status` says the cap and the slots taken; `PUT /v1/settings/jobs` changes the cap, 1 to 20.
    @Test func theCapIsInStatusAndSettings() async throws {
        final class Saved { var values: [Int] = [] }
        let saved = Saved()
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        api.saveMaxRunning = { saved.values.append($0) }
        let app = Application(router: api.router(owner: "well@example.com"))
        let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/status", method: .get, headers: owner) { response in
                let status = object(Data(response.body.readableBytesView))
                #expect(status["maxRunning"] as? Int == 6 && status["running"] as? Int == 0)
            }
            for refused in [0, 21] {
                try await client.execute(uri: "/v1/settings/jobs", method: .put, headers: owner, body: ByteBuffer(string: #"{"maxRunning": \#(refused)}"#)) { response in
                    #expect(response.status == .unprocessableContent)
                }
            }
            try await client.execute(uri: "/v1/settings/jobs", method: .put, headers: owner, body: ByteBuffer(string: #"{"maxRunning": 3}"#)) { response in
                #expect(response.status == .ok && object(Data(response.body.readableBytesView))["maxRunning"] as? Int == 3)
            }
            try await client.execute(uri: "/v1/settings/jobs", method: .get, headers: owner) { response in
                #expect(object(Data(response.body.readableBytesView))["maxRunning"] as? Int == 3)
            }
        }
        #expect(saved.values == [3] && desk.maxRunning == 3)
    }
}
