import Foundation
import Testing
@testable import ObyEngine

/// The chat acts on jobs and the inbox (#300, Engine/JobActions.swift): try again, dismiss, answer
/// an inbox item and start now, each in a turn of the brain's loop, several in one message.
@MainActor
struct JobActionTests {
    typealias FakeBrain = ConversationTests.FakeBrain

    /// An agent that notes what it's started with and sent, and does nothing else.
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var prompts: [String] = []
        var sent: [String] = []
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            prompts.append(prompt)
            self.onEvent = onEvent
        }
        func send(_ text: String) { sent.append(text) }
        func end() {}
        func stop() {}
        func kill() {}
    }

    /// Every agent the desk made, in order.
    final class Made { var agents: [Agent] = [] }

    let folder: URL
    let accounts: AccountStore
    let brain: FakeBrain
    let made = Made()

    init() throws {
        folder = try temporaryFolder()
        accounts = AccountStore(root: folder)
        accounts.setLabel("Max · well@example.com", for: "default")
        accounts.record(.usage(fiveHour: 0.1, sevenDay: 0.2), for: "default")
        brain = FakeBrain([ConversationTests.reply("")])
    }

    /// A desk that starts with `jobs` as they were saved, as after a restart: their inbox items come with them.
    func makeDesk(_ jobs: [Job] = []) -> Desk {
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        for job in jobs { store.save(job) }
        let desk = Desk(accounts: accounts, store: store)
        desk.repos = ["deskree-inc/oby"]
        desk.prepare = { $0 }
        desk.fetchBase = { _, _ in String(repeating: "a", count: 40) }
        desk.countCommits = { _, _ in 0 }
        desk.makeAgent = { [made] _, _, _ in
            let agent = Agent()
            made.agents.append(agent)
            return agent
        }
        desk.makeBrain = { [brain] _, _, _ in [brain] }
        return desk
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    /// A job that ended as `status` on its own session, so it can run again.
    func ended(_ id: String, _ title: String, issue: Int, status: Job.Status = .failed) -> Job {
        var job = Job(id: id, request: "fix oby #\(issue)", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-\(issue)", base: "dev", pr: nil, kind: .fix, task: "Fix #\(issue)")
        job.issue = issue
        job.title = title
        job.status = status
        job.phase = .work
        job.session = "e6a24229"
        job.summary = "`swift test` still fails after 4 rounds."
        job.finished = .now
        return job
    }

    /// A plan of `action` for these jobs.
    static func plan(_ action: String, _ ids: [String]) -> String {
        #"{"action":"\#(action)","reply":"","question":null,"dispatches":[],"jobs":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))]}"#
    }

    static func answer(_ item: String, option: Int? = nil, words: String? = nil) -> String {
        #"{"action":"answer_inbox","reply":"","question":null,"dispatches":[],"jobs":[],"item":"\#(item)","option":\#(option.map(String.init) ?? "null"),"answer":\#(words.map { "\"\($0)\"" } ?? "null")}"#
    }

    /// What Oby said, or a failure when it said nothing.
    static func words(_ talk: Desk.Talk) throws -> String {
        guard case .reply(let text) = talk else { throw Shell.Failure(message: "expected a reply, got \(talk)") }
        return text
    }

    // MARK: Try again

    @Test func tryAgainRestartsAFailedJob() async throws {
        let desk = makeDesk([ended("fa11ed00", "Notch three screens", issue: 281)])
        #expect(desk.inbox.first { $0.job == "fa11ed00" }?.options == [Inbox.tryAgain, Inbox.dismiss])
        brain.plans = [Self.plan("retry_job", ["fa11ed00"]), ConversationTests.reply("")]
        let talk = await desk.converse("try the notch job again")
        let text = try Self.words(talk)
        #expect(text.hasPrefix("Started Notch three screens again on "))
        try await until("the agent starts again") { made.agents.first?.prompts.isEmpty == false }
        #expect(made.agents.first?.prompts.first?.contains(Inbox.tryAgainMessage) == true)
        #expect(desk.job("fa11ed00")?.status == .running)
        // The item is settled with it.
        #expect(desk.inbox.first { $0.job == "fa11ed00" }?.isOpen == false)
    }

    @Test func aJobThatIsStillRunningCantBeTriedAgain() async throws {
        let desk = makeDesk()
        var running = ended("ba5ed000", "Vault secrets", issue: 60)
        (running.status, running.session, running.finished, running.summary) = (.queued, nil, nil, "")
        desk.enqueue(running)
        try await until("it runs") { desk.job(running.id)?.status == .running }
        brain.plans = [Self.plan("retry_job", [running.id])]
        let talk = await desk.converse("try the vault job again")
        #expect(talk == .reply("Couldn't try Vault secrets again: it's still running."))
    }

    // MARK: Dismiss

    @Test func dismissLetsAJobGo() async throws {
        let desk = makeDesk([ended("01d55000", "Old PR job", issue: 55)])
        brain.plans = [Self.plan("dismiss_job", ["01d55000"]), ConversationTests.reply("")]
        #expect(await desk.converse("let the old PR #55 job go") == .reply("Let Old PR job go."))
        #expect(desk.job("01d55000")?.dismissed != nil)
        #expect(desk.inbox.first { $0.job == "01d55000" }?.isOpen == false)
    }

    @Test func aJobThatNeedsNothingSaysWhyItStays() async throws {
        let done = ended("d0ned000", "Finished work", issue: 12, status: .done)
        let desk = makeDesk([done])
        brain.plans = [Self.plan("dismiss_job", [done.id])]
        let talk = await desk.converse("dismiss the finished one")
        #expect(talk == .reply("Couldn't let Finished work go: Nothing to dismiss: this job doesn't need you."))
    }

    // MARK: Answer the inbox

    @Test func answeringAnInboxItemSettlesIt() async throws {
        let desk = makeDesk()
        var vault = ended("a5c3d000", "Vault secrets", issue: 60)
        (vault.status, vault.session, vault.finished, vault.summary) = (.queued, nil, nil, "")
        desk.enqueue(vault)
        try await until("it runs") { desk.job(vault.id)?.status == .running }
        let agent = try #require(made.agents.first)
        agent.onEvent(.turnEnded(summary: "Read the code.\nQUESTION: Failed, or a new status?\nOPTIONS: Failed | A new status", failed: false))
        let item = try #require(desk.inbox.first { $0.job == vault.id })
        // The brain names the item by its id from the briefing and an option by its number.
        brain.plans = [Self.answer(item.id, option: 2), ConversationTests.reply("")]
        let talk = await desk.converse("answer the vault question with the second option")
        #expect(talk == .reply("Answered Vault secrets's question, with the option you picked."))
        #expect(agent.sent == ["A new status"])
        #expect(brain.prompts.first?.contains("Item id \(item.id).") == true)
        // The agent's words aren't repeated; the item is done with the option's words.
        let settled = try #require(desk.item(item.id))
        #expect(settled.done != nil && settled.answer == "A new status")
    }

    @Test func anItemTakesTheUsersOwnWordsAndRefusesWhatIsntOpen() async throws {
        let desk = makeDesk([ended("fa11ed00", "Notch three screens", issue: 281)])
        let item = try #require(desk.inbox.first { $0.job == "fa11ed00" })
        brain.plans = [Self.answer(item.id, words: "try again"), ConversationTests.reply("")]
        // "try again" is the item's own option, whatever its case.
        let talk = await desk.converse("answer the notch item: try again")
        #expect(talk == .reply("Answered Notch three screens's item: Try again."))
        #expect(desk.item(item.id)?.answer == Inbox.tryAgain)
        // Done already: the brain can't name it any more, and the desk says so when it's asked anyway.
        let late = Planner.Result(plan: try Plan.decode(Data(Self.answer(item.id, option: 1).utf8)), by: "fake")
        #expect(await desk.card(for: late, said: "again") == .reply("Couldn't answer Notch three screens: it's done already."))
    }

    /// A brain that repeats an answer already given gets nothing more done: the item isn't in the
    /// briefing any more, Swift refuses the repeat, and the rules that stand in for the brain never
    /// start work on a later step of a turn.
    @Test func aRepeatedAnswerDoesNothingMore() async throws {
        let desk = makeDesk([ended("fa11ed00", "Notch three screens", issue: 281)])
        let item = try #require(desk.inbox.first { $0.job == "fa11ed00" })
        brain.plans = [Self.answer(item.id, words: "try again")]
        let talk = await desk.converse("answer the notch item: try again")
        #expect(talk == .reply("Answered Notch three screens's item: Try again."))
        #expect(desk.jobs.map(\.id) == ["fa11ed00"])
        #expect(desk.item(item.id)?.answer == Inbox.tryAgain)
        #expect(brain.prompts.count >= 2 && brain.prompts.dropFirst().allSatisfy { $0.contains("Answered Notch three screens's item") })
        // The repeat was refused and nothing guessed in its place: every plan of the turn is
        // answer_inbox or the empty stop, and none is a dispatch.
        let turns = JobStore(url: folder.appending(path: "oby.sqlite")).turns()
        #expect(turns.count >= 2 && turns.allSatisfy { $0.plan.dispatches.isEmpty && [.answerInbox, .ignore].contains($0.plan.action) })
    }

    /// The runner's step events (#303) say what each of these actions is doing.
    @Test func eachActionReportsItsSteps() async throws {
        let desk = makeDesk([ended("fa11ed00", "Notch three screens", issue: 281), ended("01d55000", "Old PR job", issue: 55, status: .interrupted)])
        var steps: [DeskStep] = []
        desk.onStepChange = { steps.append($0) }
        brain.plans = [Self.plan("retry_job", ["fa11ed00"]), Self.plan("dismiss_job", ["01d55000"]), ConversationTests.reply("")]
        _ = await desk.converse("try the notch job again and dismiss the old one")
        #expect(steps.map(\.text) == ["Trying Notch three screens again", "Trying Notch three screens again",
                                      "Letting Old PR job go", "Letting Old PR job go"])
        #expect(steps.map(\.state) == [.running, .done, .running, .done])
    }

    // MARK: Start now

    @Test func startNowStartsAJobWaitingForItsStartWhen() async throws {
        let desk = makeDesk()
        var job = Job(id: "e0c00000", request: "build encryption", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/build-9", base: "dev", pr: nil, kind: .build, task: "Encrypt")
        job.title = "Encryption"
        job.startWhen = [.at(.now.addingTimeInterval(3600))]
        desk.dispatch(job)
        try await until("it waits") { desk.scheduled.contains(job.id) }
        #expect(made.agents.isEmpty)
        brain.plans = [Self.plan("start_now", [job.id]), ConversationTests.reply("")]
        let talk = await desk.converse("start the encryption job anyway")
        let text = try Self.words(talk)
        #expect(text.hasPrefix("Started Encryption on ") && text.contains("without waiting for its Start when"))
        try await until("it runs") { desk.job(job.id)?.status == .running }
        #expect(desk.job(job.id)?.startWhen == nil)
        // Nothing left to start now.
        brain.plans = [Self.plan("start_now", [job.id])]
        #expect(await desk.converse("start it") == .reply("Couldn't start Encryption: it isn't waiting for a Start when."))
    }

    @Test func startNowLiftsTheReserveThatHoldsAJob() async throws {
        accounts.record(.usage(fiveHour: 0.1, sevenDay: 0.82, sevenDayResets: Date.now.addingTimeInterval(2 * 86_400)), for: "default")
        let desk = makeDesk()
        var job = Job(id: "e0c00001", request: "build encryption", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/build-9", base: "dev", pr: nil, kind: .build, task: "Encrypt")
        job.title = "Encryption"
        job.startWhen = [.room(agent: "claude")]
        desk.dispatch(job)
        try await until("it waits for room") { desk.job(job.id)?.waiting?.reserved == ["default"] }
        brain.plans = [Self.plan("start_now", [job.id]), ConversationTests.reply("")]
        let talk = await desk.converse("start the encryption job anyway")
        let text = try Self.words(talk)
        #expect(text.hasPrefix("Lifted Default's weekly reserve until its week resets, and started Encryption on "))
        #expect(accounts.state("default")?.reserveLiftedUntil() != nil)
        try await until("it runs") { desk.job(job.id)?.status == .running }
    }

    // MARK: Several in one message

    @Test func oneMessageTriesTheFailedJobAgainAndDismissesTheOldOne() async throws {
        let desk = makeDesk([ended("fa11ed00", "Notch three screens", issue: 281), ended("01d55000", "Old PR job", issue: 55, status: .interrupted)])
        brain.plans = [Self.plan("retry_job", ["fa11ed00"]), Self.plan("dismiss_job", ["01d55000"]), ConversationTests.reply("")]
        let talk = await desk.converse("try the failed jobs again and dismiss the old PR #55 job")
        let text = try Self.words(talk)
        #expect(text.hasPrefix("Started Notch three screens again on ") && text.hasSuffix("Let Old PR job go."))
        #expect(desk.job("fa11ed00")?.status == .running && desk.job("01d55000")?.dismissed != nil)
        // The brain was asked three times: before, between and after, each time with what was done.
        #expect(brain.prompts.count == 3 && brain.prompts[1].contains("Started Notch three screens again"))
    }

    // MARK: What Swift checks

    @Test func swiftChecksWhatTheBrainNames() throws {
        let context = BrainContext(accounts: [:], repos: [], movable: ["fa11ed00"], inbox: ["fa11ed00-failed-1"])
        func problems(_ json: String) throws -> [String] { try Plan.decode(Data(json.utf8)).problems(in: context, canary: "c4n4ry") }
        #expect(try problems(Self.plan("retry_job", ["fa11ed00"])).isEmpty)
        #expect(try problems(Self.plan("dismiss_job", ["fa11ed00"])).isEmpty && problems(Self.plan("start_now", ["fa11ed00"])).isEmpty)
        #expect(try problems(Self.plan("retry_job", ["nobody"])) == ["nobody isn't a job in the briefing"])
        #expect(try problems(Self.plan("start_now", [])) == ["start_now names 1 to 10 jobs"])
        #expect(try problems(Self.answer("fa11ed00-failed-1", option: 1)).isEmpty)
        #expect(try problems(Self.answer("fa11ed00-failed-1", words: "try again")).isEmpty)
        #expect(try problems(Self.answer("nothing-1", option: 1)) == ["answer_inbox names an item waiting in the inbox"])
        #expect(try problems(Self.answer("fa11ed00-failed-1")) == ["answer_inbox gives an option or the user's words"])
        #expect(try problems(Self.answer("fa11ed00-failed-1", option: 1, words: "x")) == ["answer_inbox gives an option or the user's words, not both"])
        // The fields belong to answer_inbox alone.
        var stray = try Plan.decode(Data(Self.plan("retry_job", ["fa11ed00"]).utf8))
        stray.item = "fa11ed00-failed-1"
        #expect(stray.problems(in: context, canary: "c4n4ry") == ["only answer_inbox has an item, an option or an answer"])
        // The schema offers the items, and the actions.
        let schema = String(decoding: Plan.schema(for: context), as: UTF8.self)
        for part in ["\"retry_job\"", "\"dismiss_job\"", "\"answer_inbox\"", "\"start_now\"", "\"fa11ed00-failed-1\""] { #expect(schema.contains(part), "\(part)") }
    }

    @Test func theBriefingListsEachItemsIdAndOptions() throws {
        let item = InboxItem(id: "fa11ed00-failed-1", kind: .failed, job: "fa11ed00", title: "Notch three screens", text: "It failed.",
                             options: [Inbox.tryAgain, Inbox.dismiss], created: .now)
        let briefing = Briefing(turns: [], places: [Briefing.Place(name: "tetrix-lab", jobs: [ended("fa11ed00", "Notch three screens", issue: 281)], inbox: [item])], accounts: [])
        #expect(briefing.text.contains("Options: Try again | Dismiss. Item id fa11ed00-failed-1."))
        #expect(Desk.systemPromptMentionsJobActions)
    }
}

extension Desk {
    /// Whether the brain's prompt has its section on these actions.
    nonisolated static var systemPromptMentionsJobActions: Bool {
        let prompt = Planner.system(canary: "c4n4ry")
        return ["retry_job", "dismiss_job", "answer_inbox", "start_now"].allSatisfy(prompt.contains)
    }
}
