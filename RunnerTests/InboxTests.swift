import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import ObyShared
@testable import oby_runner

/// The inbox (docs/pipeline-cases.md, I.1): what only the user can answer waits there, with its
/// job, a short line and the answers it offers. A job's question lands there instead of in its
/// report, the job waits, and the answer reaches it as its next message.
@MainActor
final class InboxTests {
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var sent: [String] = []
        var ended = false
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws { self.onEvent = onEvent }
        func send(_ text: String) { sent.append(text) }
        func end() { ended = true }
        func stop() {}
        func kill() {}
    }

    let folder: URL
    let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]

    init() throws {
        folder = try temporaryFolder()
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// A fix job that has started and has a session.
    var fix: Job {
        var fix = job
        fix.id = "ask62"
        fix.kind = .fix
        fix.pr = nil
        fix.base = "dev"
        fix.branch = "oby/fix-62"
        fix.title = "Nothing committed status"
        return fix
    }

    var failed: Job {
        var failed = fix
        failed.id = "failed"
        failed.status = .failed
        failed.session = "e6a24229"
        failed.summary = "`swift test` still fails after 4 rounds.\n\nDetails."
        failed.finished = Date(timeIntervalSince1970: 1_791_582_200)
        return failed
    }

    func makeDesk(_ jobs: [Job] = []) -> Desk {
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        for job in jobs { store.save(job) }
        return Desk(accounts: AccountStore(root: folder), store: store)
    }

    /// A desk running `fix` on a fake agent, once it's running.
    func running(_ agent: Agent) async throws -> Desk {
        let desk = makeDesk()
        desk.makeAgent = { _, _, _ in agent }
        desk.prepare = { $0 }
        desk.countCommits = { _, _ in 0 }
        desk.dispatch(fix)
        for _ in 0..<500 where desk.job("ask62")?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        agent.onEvent(.session("e6a24229"))
        return desk
    }

    @Test func questionsAreReadFromTheSummarysEnd() {
        let asked = "Nothing committed yet.\n\n**QUESTION:** Should a job that commits nothing end as `failed`, or get a new status?\nOPTIONS: Failed | A new status | "
        #expect(Inbox.question(in: asked) == Plan.Question(text: "Should a job that commits nothing end as `failed`, or get a new status?",
                                                          options: ["Failed", "A new status"]))
        // Only the Markdown around the label goes: globs and code stay as the agent wrote them.
        #expect(Inbox.question(in: "Done.\n`QUESTION: Which files?`\n**OPTIONS:** *.swift | `Engine/*` | all") ==
                Plan.Question(text: "Which files?", options: ["*.swift", "`Engine/*`", "all"]))
        #expect(Inbox.question(in: "**QUESTION: Keep _drafts_?**")?.text == "Keep _drafts_?")
        #expect(Inbox.question(in: "Done.\nquestion: Which branch?\n") == Plan.Question(text: "Which branch?", options: []))
        // A question mid-report, or an empty one, isn't asked.
        #expect(Inbox.question(in: "QUESTION: Which branch?\nThen I picked dev and committed.") == nil)
        #expect(Inbox.question(in: "Done.\nQUESTION:") == nil)
        #expect(Inbox.question(in: "Fixed it.\nGOAL MET") == nil)
        #expect(Prompts.agent(fix).contains("QUESTION: <one question>"))
    }

    /// Options as Claude Code asks them (#215): a short label, then what choosing it does after
    /// ` — `, and `(Recommended)` after the one the agent recommends.
    @Test func questionsSayWhatEachOptionDoes() throws {
        let asked = "Done.\nQUESTION: Should Oby offer Add the column?\nOPTIONS: Offer it now (Recommended) — Oby adds the missing column itself | Keep two buttons — only Use … instead and Ignore"
        let question = try #require(Inbox.question(in: asked))
        #expect(question.options == ["Offer it now", "Keep two buttons"] && question.recommended == 0)
        #expect(question.details == ["Oby adds the missing column itself", "only Use … instead and Ignore"])
        // Without a description for every option, none are kept; a dash in a label stays.
        let some = try #require(Inbox.question(in: "QUESTION: Which?\nOPTIONS: A — does a | B-side | C (recommended)"))
        #expect(some.options == ["A", "B-side", "C"] && some.details == nil && some.recommended == 2)
        // The inbox item carries them, and asks the rewriter to keep the recommendation.
        var job = fix
        job.question = question
        let item = try #require(Inbox.need(of: job))
        #expect(item.details == question.details && item.recommended == 0 && item.isDecision)
        #expect(InboxRewriter.quoted(item).contains("0. Offer it now — Oby adds the missing column itself"))
        #expect(Prompts.agent(fix).contains("(Recommended)") && Prompts.agent(fix).contains("what choosing it does"))
    }

    @Test func aQuestionWaitsInTheInboxAndTheAnswerGoesBackToTheJob() async throws {
        let agent = Agent()
        let desk = try await running(agent)
        var told: [InboxItem] = []
        desk.onInboxChange = { told.append($0) }
        agent.onEvent(.turnEnded(summary: "Read the code.\nQUESTION: Failed, or a new status?\nOPTIONS: Failed | A new status", failed: false))

        // The job waits, running, its agent idle: nothing ended, nothing failed.
        let waiting = try #require(desk.job("ask62"))
        #expect(waiting.status == .running && waiting.step == "Waiting for your answer" && !agent.ended)
        #expect(waiting.question == Plan.Question(text: "Failed, or a new status?", options: ["Failed", "A new status"]))
        #expect(Push.notice(for: waiting) == .question)
        let item = try #require(desk.inbox.first)
        #expect(desk.inbox.count == 1 && told == [item])
        #expect(item.kind == .question && item.job == "ask62" && item.title == "Nothing committed status")
        #expect(item.text == "Failed, or a new status?" && item.options == ["Failed", "A new status"] && item.waiting())

        // The answer is the agent's next message, and the item is done with it.
        let settled = try desk.settle(item.id, .answer("A new status"))
        #expect(agent.sent == ["A new status"])
        #expect(settled.done != nil && settled.answer == "A new status" && desk.item(item.id) == settled)
        #expect(told.last == settled)
        let answered = try #require(desk.job("ask62"))
        #expect(answered.question == nil && answered.notes == ["A new status"] && Push.notice(for: answered) == nil)
        #expect(throws: Shell.Failure.self) { try desk.settle(item.id, .answer("Failed")) }

        // It goes on and ends as usual; a second question would be a new item.
        agent.onEvent(.turnEnded(summary: "Added the status.\nQUESTION: Name it `empty`?", failed: false))
        #expect(desk.inbox.count == 2 && desk.inbox[1].id != item.id && desk.inbox[1].options.isEmpty)
        try desk.settle(desk.inbox[1].id, .answer("Yes"))
        agent.onEvent(.turnEnded(summary: "Named it empty.", failed: false))
        #expect(agent.ended)
        desk.countCommits = { _, _ in 1 }
        desk.publishOnItsOwn = { _, _, _ in URL(string: "https://github.com/deskree-inc/oby/pull/80")! }
        agent.onEvent(.finished(summary: "Named it empty.", failed: false))
        for _ in 0..<500 where desk.job("ask62")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(desk.job("ask62")?.status == .done)
        #expect(desk.inbox.allSatisfy { !$0.isOpen })
    }

    /// Stopping a job that waits takes its question from the inbox, without an answer.
    @Test func stoppingAWaitingJobSettlesItsQuestion() async throws {
        let agent = Agent()
        let desk = try await running(agent)
        agent.onEvent(.turnEnded(summary: "QUESTION: Which repository?", failed: false))
        #expect(desk.inbox.first?.isOpen == true)
        desk.stop("ask62")
        #expect(desk.inbox.first?.isOpen == false && desk.inbox.first?.answer == nil)
    }

    /// The agent's process ending while its question waits isn't "nothing committed": the question
    /// stays, and answering picks the session up again.
    @Test func aQuestionOutlivesItsAgent() async throws {
        let agent = Agent()
        let desk = try await running(agent)
        // It committed something, but nothing is checked or published while its question waits.
        var published = 0
        desk.countCommits = { _, _ in 1 }
        desk.publishOnItsOwn = { _, _, _ in published += 1; return URL(string: "https://github.com/deskree-inc/oby/pull/80")! }
        agent.onEvent(.turnEnded(summary: "QUESTION: Which repository?", failed: false))
        agent.onEvent(.finished(summary: "QUESTION: Which repository?", failed: false))
        for _ in 0..<500 where desk.job("ask62")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        let ended = try #require(desk.job("ask62"))
        #expect(ended.status == .interrupted && ended.question?.text == "Which repository?")
        #expect(published == 0 && ended.published == nil && !ended.canPublish)
        #expect(Push.notice(for: ended) == .question)
        #expect(desk.inbox.count == 1 && desk.inbox[0].kind == .question && desk.inbox[0].isOpen)

        // A restart keeps both.
        let restarted = makeDesk()
        #expect(restarted.job("ask62")?.question?.text == "Which repository?")
        #expect(restarted.inbox.map(\.id) == desk.inbox.map(\.id))

        try desk.settle(desk.inbox[0].id, .answer("deskree-inc/oby"))
        let resumed = try #require(desk.job("ask62"))
        #expect(resumed.status == .running && resumed.question == nil && resumed.notes == ["deskree-inc/oby"])
    }

    /// A question older than the 50 jobs a restart loads can still be answered: its job comes back too.
    @Test func oldQuestionsKeepTheirJobs() throws {
        var asking = fix
        asking.id = "asking"
        asking.status = .interrupted
        asking.session = "e6a24229"
        asking.created = Date(timeIntervalSince1970: 1_700_000_000)
        asking.finished = asking.created
        asking.question = Plan.Question(text: "Which repository?", options: [])
        var newer: [Job] = []
        for index in 0..<55 {
            var job = fix
            job.id = "newer\(index)"
            job.status = .done
            job.created = Date(timeIntervalSince1970: 1_791_582_173 + Double(index))
            newer.append(job)
        }
        // The question lands, then 55 newer jobs come.
        let first = makeDesk([asking])
        #expect(first.inbox.count == 1)
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        for job in newer { store.save(job) }
        #expect(!store.recent().contains { $0.id == "asking" })
        let restarted = makeDesk()
        #expect(restarted.job("asking")?.question != nil)
        try #require(restarted.inbox.count == 1)
        // No agent: the job takes the answer, then fails at once without starting a process.
        restarted.makeAgent = { _, _, _ in nil }
        let settled = try restarted.settle(restarted.inbox[0].id, .answer("deskree-inc/oby"))
        #expect(settled.answer == "deskree-inc/oby" && restarted.job("asking")?.notes == ["deskree-inc/oby"])
    }

    /// A review item's One more round still quotes the review after a restart, however old its review job is.
    @Test func oldReviewItemsKeepTheirReview() throws {
        var reviewed = fix
        reviewed.id = "reviewed"
        reviewed.status = .done
        reviewed.session = "e6a24229"
        reviewed.published = "https://github.com/deskree-inc/oby/pull/80"
        reviewed.review = Review(verdict: .changesRequested, job: "rev4", agent: "codex", account: "Work", round: 4)
        reviewed.created = Date(timeIntervalSince1970: 1_700_000_100)
        var review = fix
        review.id = "rev4"
        review.status = .done
        review.reviewOf = "reviewed"
        review.summary = "Rename the status.\nVERDICT: CHANGES REQUESTED"
        review.created = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(makeDesk([reviewed, review]).inbox.first?.kind == .review)
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        for index in 0..<55 {
            var job = fix
            job.id = "newer\(index)"
            job.status = .done
            job.created = Date(timeIntervalSince1970: 1_791_582_173 + Double(index))
            store.save(job)
        }
        let restarted = makeDesk()
        #expect(restarted.job("rev4")?.summary == review.summary)
        var quoted: [(String, String)] = []
        restarted.quoteReview = { _, file, text in quoted.append((file, text)) }
        restarted.makeAgent = { _, _, _ in nil }
        try restarted.settle(try #require(restarted.inbox.first { $0.kind == .review }).id, .answer("One more round"))
        #expect(quoted.first?.0 == "review-4.md" && quoted.first?.1.contains("Rename the status.") == true)
        #expect(restarted.job("reviewed")?.notes?.first?.contains(".oby/inputs/review-4.md") == true)
    }

    /// Try again on a review that failed makes it its author's review again: its verdict counts.
    @Test func aRetriedReviewCountsForItsAuthor() async throws {
        var author = fix
        author.id = "author"
        author.status = .done
        author.session = "e6a24229"
        author.commits = 1
        author.published = "https://github.com/deskree-inc/oby/pull/80"
        author.reviewError = "Oby's review failed: Codex hit an error."
        author.finished = Date(timeIntervalSince1970: 1_791_582_200)
        var review = fix
        review.id = "rev1"
        review.kind = .review
        review.reviewOf = "author"
        review.status = .failed
        review.session = "5c1e"
        review.summary = "Codex hit an error."
        review.created = author.created + 60
        review.finished = review.created + 30
        let desk = makeDesk([author, review])
        let agent = Agent()
        desk.makeAgent = { _, _, _ in agent }
        desk.countCommits = { _, _ in 0 }
        desk.postReview = { _, _ in URL(string: "https://github.com/deskree-inc/oby/runs/1")! }
        let item = try #require(desk.inbox.first { $0.job == "rev1" })
        try desk.settle(item.id, .answer("Try again"))
        #expect(desk.job("author")?.reviewing == "rev1" && desk.job("author")?.reviewError == nil)

        agent.onEvent(.turnEnded(summary: "It does what was asked.\n\nVERDICT: APPROVED", failed: false))
        agent.onEvent(.finished(summary: "It does what was asked.\n\nVERDICT: APPROVED", failed: false))
        for _ in 0..<500 where desk.job("rev1")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        let reviewed = try #require(desk.job("author"))
        #expect(reviewed.reviewing == nil && reviewed.review?.verdict == .approved && reviewed.review?.job == "rev1")

        // An older review run again doesn't take the place of the newer one.
        var newer = review
        newer.id = "rev2"
        newer.created = review.created + 600
        var older = review
        older.id = "rev0"
        older.created = review.created - 600
        var waiting = author
        waiting.review = nil
        let again = makeDesk([waiting, older, newer])
        again.makeAgent = { _, _, _ in agent }
        try again.message("rev0", "Try again.")
        #expect(again.job("author")?.reviewing == nil)
    }

    /// The iPhone's job list reloads with the latest 50 (Shared/JobList.swift): a job whose screen
    /// is open stays even when it's older, in age order, and is fetched again.
    @Test func anOpenScreenKeepsItsOlderJob() {
        struct Row: Equatable { var id: String; var created: Date }
        let now = Date(timeIntervalSince1970: 1_791_582_173)
        let fresh = [Row(id: "new2", created: now), Row(id: "new1", created: now - 10)]
        let old = [Row(id: "new1", created: now - 10), Row(id: "asking", created: now - 1000), Row(id: "gone", created: now - 2000)]
        let kept = JobList.keeping(fresh, old: old, onScreen: ["asking"], id: \.id, created: \.created)
        #expect(kept.jobs.map(\.id) == ["new2", "new1", "asking"] && kept.refetch == ["asking"])
        // Nothing open: just the new list.
        #expect(JobList.keeping(fresh, old: old, onScreen: [], id: \.id, created: \.created).jobs == fresh)
        // A screen whose job is in the new list needs nothing fetched.
        #expect(JobList.keeping(fresh, old: old, onScreen: ["new1"], id: \.id, created: \.created).refetch.isEmpty)
        // Fetched again, it takes its own place: replaced where it is, else by age.
        let current = Row(id: "asking", created: now - 1000)
        #expect(JobList.placed(current, in: kept.jobs, id: \.id, created: \.created) == kept.jobs)
        #expect(JobList.placed(current, in: fresh, id: \.id, created: \.created).map(\.id) == ["new2", "new1", "asking"])
        #expect(JobList.placed(Row(id: "mid", created: now - 5), in: fresh, id: \.id, created: \.created).map(\.id) == ["new2", "mid", "new1"])
    }

    /// A retry that fails again, even within the same second, is a new item: the settled one doesn't hide it.
    @Test func aRetryThatFailsAgainIsANewItem() {
        var again = failed
        again.round = 2
        again.finished = failed.finished! + 0.2
        #expect(Inbox.need(of: failed)?.id != Inbox.need(of: again)?.id)
        // The same failure is the same item.
        #expect(Inbox.need(of: failed)?.id == Inbox.need(of: failed)?.id)
    }

    /// A failure lands once, with Try again and Dismiss; Dismiss lets the job go, and an item that's
    /// done never comes back for the same failure.
    @Test func failuresLandOnceAndDismissLetsTheJobGo() throws {
        let desk = makeDesk([failed])
        let item = try #require(desk.inbox.first)
        #expect(desk.inbox.count == 1)
        #expect(item.kind == .failed && item.text == "`swift test` still fails after 4 rounds." && item.options == ["Try again", "Dismiss"])

        // Done without an answer: the job still needs the user, but the item stays done.
        try desk.settle(item.id, .done)
        desk.replace(try #require(desk.job("failed")))
        #expect(desk.inbox.count == 1 && desk.inbox[0].done != nil && desk.inbox[0].answer == nil)
        #expect(makeDesk().inbox.count == 1)

        // Another failed job, let go from its item.
        var other = failed
        other.id = "other"
        let second = makeDesk([other])
        let open = try #require(second.inbox.first { $0.job == "other" })
        let dismissed = try second.settle(open.id, .answer("Dismiss"))
        #expect(second.job("other")?.dismissed != nil && dismissed.answer == "Dismiss" && dismissed.done != nil)

        // A job that never started has no session to try again.
        var never = failed
        never.session = nil
        #expect(Inbox.need(of: never)?.options == ["Dismiss"])
    }

    /// Dismissing the job elsewhere (its screen, a swipe) settles its item by itself.
    @Test func itemsSettleThemselvesWhenTheJobNeedsNothing() throws {
        let desk = makeDesk([failed])
        #expect(desk.inbox.first?.isOpen == true)
        try desk.dismiss("failed")
        #expect(desk.inbox.first?.isOpen == false && desk.inbox.first?.answer == nil)
    }

    @Test func limitsReviewsAndStopsHaveTheirOwnKinds() {
        // All accounts full: the same item, said as a limit.
        let limit = Inbox.need(of: failed, limited: true)
        #expect(limit?.kind == .limit && limit?.id == Inbox.need(of: failed)?.id)
        var interrupted = failed
        interrupted.status = .interrupted
        #expect(Inbox.need(of: interrupted)?.kind == .failed)
        // Oby's review found a blocker it asked to fix before: one more round, or let it go.
        var reviewed = fix
        reviewed.status = .done
        reviewed.published = "https://github.com/deskree-inc/oby/pull/80"
        let firstHead = String(repeating: "a", count: 40)
        reviewed.outgoing = [Outgoing(action: .push, repo: reviewed.repo, id: firstHead, branch: reviewed.branch)]
        reviewed.review = Review(verdict: .changesRequested, job: "rev4", agent: "codex", account: "Work", round: 4)
        reviewed.review?.repeated = true
        let review = Inbox.need(of: reviewed)
        #expect(review?.kind == .review && review?.text == "Oby's reviews are done: review #80 yourself"
                && review?.options == [Inbox.openPR, "One more round", "Dismiss"])
        #expect(review?.id.hasSuffix("review-\(firstHead)") == true)
        reviewed.outgoing?[0].id = String(repeating: "b", count: 40)
        #expect(Inbox.need(of: reviewed)?.id != review?.id)
        // Nothing for what needs nothing.
        var stopped = failed
        stopped.status = .stopped
        var running = fix
        running.status = .running
        #expect(Inbox.need(of: stopped) == nil && Inbox.need(of: running) == nil)
        stopped.question = Plan.Question(text: "Which?", options: [])
        #expect(Inbox.need(of: stopped) == nil)
    }

    /// The inbox is for decisions (#215): every kind declares the answers that change something,
    /// every item Oby makes offers one, and one that offers none arrives done, with the reports.
    @Test func everyKindHasAnActionAndOnlyDecisionsWait() throws {
        for kind in InboxItem.Kind.allCases {
            #expect(kind.takesWords || !kind.actions.isEmpty, "\(kind) declares no action")
        }
        var reviewed = fix
        reviewed.status = .done
        reviewed.published = "https://github.com/deskree-inc/oby/pull/80"
        reviewed.review = Review(verdict: .changesRequested, job: "rev4", agent: "codex", account: "Work", round: 4)
        var never = failed
        never.session = nil
        var asked = fix
        asked.question = Plan.Question(text: "Which?", options: [])
        let made = [Inbox.need(of: failed), Inbox.need(of: failed, limited: true), Inbox.need(of: reviewed), Inbox.need(of: never), Inbox.need(of: asked)].compactMap { $0 }
        #expect(made.count == 5)
        for item in made { #expect(item.isDecision && item.options.allSatisfy(item.kind.acts), "\(item.id)") }
        #expect(InboxItem.Kind.audit.acts(on: "Use In review instead") && !InboxItem.Kind.failed.acts(on: "Use In review instead"))
        #expect(Inbox.instead("Use In review instead") == "In review" && Inbox.instead("In review") == nil)

        let desk = makeDesk()
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        desk.addIssueAudit(InboxItem(id: "report", kind: .audit, job: "", title: "Daily issue audit", text: "Fixed 7.", options: [], created: day))
        desk.addIssueAudit(InboxItem(id: "nothing", kind: .failure, job: "", title: "Oby failure: x", text: "Bug.", options: ["Later"], created: day))
        #expect(desk.item("report")?.done == day && desk.item("nothing")?.done == day)
        #expect(desk.inbox.filter(\.isOpen).isEmpty && makeDesk().inbox.count == 2)
    }

    /// Items saved before #215 that offer nothing to decide (the 2026-10-12 audit report) are done
    /// once the inbox loads, and stay done; a question with no options still waits.
    @Test func savedItemsWithNothingToDecideAreDoneOnLoad() throws {
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        let day = Date(timeIntervalSince1970: 1_791_763_200)
        store.save(InboxItem(id: "issue-audit-20738", kind: .audit, job: "", title: "Daily issue audit",
                             text: "Issue audit: fixed drift on 7 issue(s). Issue sync: roadmap has no Status option Needs test.", options: [], created: day))
        var asked = fix
        asked.question = Plan.Question(text: "Which?", options: [])
        let desk = makeDesk([asked])
        let report = try #require(desk.item("issue-audit-20738"))
        #expect(report.done != nil && report.answer == nil)
        #expect(desk.inbox.filter(\.isOpen).map(\.kind) == [.question])
        // Saved done: the next load keeps it so, and it's in the history.
        #expect(makeDesk().item("issue-audit-20738")?.done != nil)
    }

    /// A failed runner update offers Try again, which tries that commit again.
    @Test func aFailedUpdateCanBeTriedAgain() throws {
        let desk = makeDesk()
        var retried = 0
        desk.retryUpdate = { retried += 1 }
        desk.updateFailed(InboxItem(id: "runner-update-abc", kind: .failed, job: Desk.updateJob, title: "Runner update failed",
                                    text: "Runner update failed at swift test (abc).", options: [Inbox.tryAgain], created: .now))
        #expect(desk.item("runner-update-abc")?.isOpen == true)
        #expect(throws: (any Error).self) { try desk.settle("runner-update-abc", .answer(Inbox.dismiss)) }
        let item = try desk.settle("runner-update-abc", .answer(Inbox.tryAgain))
        #expect(retried == 1 && item.done != nil && item.answer == Inbox.tryAgain)
    }

    /// How long an item has waited, as both apps say it next to it.
    @Test func itemsSayHowLongTheyWaited() {
        let now = Date(timeIntervalSince1970: 1_791_582_173)
        #expect(Elapsed.waiting(since: now - 20, now: now) == "just now")
        #expect(Elapsed.waiting(since: now - 190, now: now) == "waiting 3m")
        #expect(Elapsed.waiting(since: now - 7300, now: now) == "waiting 2h")
        #expect(Elapsed.waiting(since: now - 3 * 86400, now: now) == "waiting 3d")
        // Put off until later: it waits again once that time has come.
        var item = Inbox.need(of: failed)!
        item.later = now + 60
        #expect(!item.waiting(at: now) && item.waiting(at: now + 60))
    }

    @Test func theAPIListsAnswersAndTellsEveryApp() async throws {
        var done = failed
        done.id = "fine"
        done.status = .done
        let desk = makeDesk([failed, done])
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        var events = api.follow().makeAsyncIterator()
        #expect(await events.next() == ": ping\n\n")
        let id = try #require(desk.inbox.first?.id)
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            func answer(_ id: String, _ body: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                try await client.execute(uri: "/v1/inbox/\(id)/answer", method: .post, headers: owner, body: ByteBuffer(string: body)) { response in
                    (response.status, object(Data(response.body.readableBytesView)))
                }
            }
            let listed: [[String: Any]] = try await client.execute(uri: "/v1/inbox", method: .get, headers: owner) { response in
                #expect(response.status == .ok)
                return (try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [[String: Any]]) ?? []
            }
            #expect(listed.count == 1)
            let item = try #require(listed.first)
            #expect(item["id"] as? String == id && item["kind"] as? String == "failed" && item["job"] as? String == "failed")
            #expect(item["state"] as? String == "open" && item["options"] as? [String] == ["Try again", "Dismiss"])
            for key in ["done", "later", "answer", "headline", "happened", "recommended", "why"] { #expect(item[key] is NSNull, "\(key)") }
            #expect(Set(item.keys) == ["id", "kind", "job", "title", "text", "options", "details", "created", "done", "later", "answer", "state",
                                       "headline", "happened", "recommended", "why"])
            // What each answer does, under its button (#215).
            #expect(item["details"] as? [String] == ["Runs it again: the job picks up in its session, or the merge or the Mac check goes again.",
                                                     "Lets the job go. Its branch stays; nothing more happens."])

            #expect(try await answer("nowhere", #"{"done": true}"#).0 == .notFound)
            #expect(try await answer(id, #"{"answer": "x", "done": true}"#).0 == .unprocessableContent)
            #expect(try await answer(id, #"{"later": "tomorrow"}"#).0 == .unprocessableContent)
            #expect(try await answer(id, #"{"answer": " "}"#).0 == .unprocessableContent)
            #expect(try await answer(id, "{").0 == .badRequest)

            let (status, later) = try await answer(id, #"{"later": "2099-01-01T09:00:00Z"}"#)
            #expect(status == .ok && later["state"] as? String == "later" && later["later"] as? String == "2099-01-01T09:00:00Z")
            let (dismissed, settled) = try await answer(id, #"{"answer": "Dismiss"}"#)
            #expect(dismissed == .ok && settled["state"] as? String == "done" && settled["answer"] as? String == "Dismiss")
            #expect(try await answer(id, #"{"done": true}"#).0 == .conflict)
            try await client.execute(uri: "/v1/inbox", method: .get, headers: owner) { response in
                #expect(String(decoding: response.body.readableBytesView, as: UTF8.self) == "[]")
            }
            // The history (#215): done items, the latest settled first, with what settled them.
            let history: [[String: Any]] = try await client.execute(uri: "/v1/inbox?state=done", method: .get, headers: owner) { response in
                #expect(response.status == .ok)
                return (try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [[String: Any]]) ?? []
            }
            #expect(history.first?["id"] as? String == id && history.first?["state"] as? String == "done" && history.first?["answer"] as? String == "Dismiss")
            try await client.execute(uri: "/v1/inbox?state=done&limit=0", method: .get, headers: owner) { response in
                #expect(String(decoding: response.body.readableBytesView, as: UTF8.self) == "[]")
            }
            try await client.execute(uri: "/v1/inbox?state=later", method: .get, headers: owner) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
        // Every app heard each change as an `inbox` event (and the job's, dismissed).
        var heard: [String] = []
        while heard.count < 3, let event = await events.next() {
            if event.hasPrefix("event: inbox\n") { heard.append(event) }
        }
        #expect(heard.first?.contains(#""state":"later""#) == true)
        #expect(heard.last?.contains(#""answer":"Dismiss""#) == true && heard.last?.contains(#""state":"done""#) == true)
    }
}
