import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// The conversation (#65, Engine/Conversation.swift): the thread kept in `oby.sqlite`, the
/// briefing the brain reads before the user's words, cancelling and replacing a turn under way,
/// a turn that takes too long, and the runner's `POST /v1/plans` taking the client's recent turns.
@MainActor
struct ConversationTests {
    /// A brain that answers from a list of plans, one per call (the last one again when they run
    /// out), noting the prompts it was given. `slow` says which prompts take a while.
    final class FakeBrain: BrainAdapter, @unchecked Sendable {
        let name = "fake"
        var plans: [String]
        var prompts: [String] = []
        var systems: [String] = []
        /// The quoted file each call came with (nil for none).
        var quoted: [String?] = []
        /// The plans given back so far, slow ones once their wait is over.
        var answered: [String] = []
        var slow: (String) -> Duration = { _ in .zero }
        init(_ plans: [String]) { self.plans = plans }
        func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
            prompts.append(user)
            systems.append(system)
            self.quoted.append(quoted)
            let plan = plans.count > 1 ? plans.removeFirst() : plans[0]
            let wait = slow(user)
            if wait > .zero { try await Task.sleep(for: wait) }
            answered.append(plan)
            return Data(plan.utf8)
        }
    }

    /// An agent that does nothing until it's stopped.
    final class IdleAgent: AgentRun {
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {}
        func send(_ text: String) {}
        func end() {}
        func stop() {}
        func kill() {}
    }

    let folder: URL
    let desk: Desk
    let brain: FakeBrain
    let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]

    static func reply(_ text: String) -> String {
        #"{"action":"reply_only","reply":"\#(text)","question":null,"dispatches":[],"jobs":[]}"#
    }

    /// A stop of the jobs named, or of everything when none are.
    static func stop(_ ids: [String]) -> String {
        #"{"action":"stop_agent","reply":"","question":null,"dispatches":[],"jobs":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))],"all":\#(ids.isEmpty)}"#
    }

    init() throws {
        folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max · well@example.com", for: "default")
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        desk.prepare = { $0 }
        desk.makeAgent = { _, _, _ in IdleAgent() }
        brain = FakeBrain([Self.reply("Fine.")])
        desk.makeBrain = { [brain] (_: String?, _: String?, _: Vault) in [brain] }
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    func store() -> JobStore { JobStore(url: folder.appending(path: "oby.sqlite")) }

    /// A job on the vault issue, running on this Mac.
    func vaultJob() -> Job {
        var job = Job(id: "ab12cd34", request: "work on oby #60", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/build-60", base: "dev", pr: nil, kind: .build, task: "Work on #60")
        job.issue = 60
        job.title = "Vault secrets"
        return job
    }

    // MARK: The briefing

    @Test func theBriefingTellsTheBrainAboutTheWork() throws {
        let now = Date(timeIntervalSince1970: 1_791_582_173)
        var running = vaultJob()
        running.status = .running
        running.phase = .work
        running.started = now - 720
        running.step = "Running swift test"
        var failed = job
        failed.id = "fa11ed00"
        failed.title = "Mac runner notifications"
        failed.status = .failed
        failed.phase = .work
        failed.started = now - 600
        failed.finished = now - 60
        failed.summary = "Nothing committed: the tests still fail.\nMore below."
        var reviewed = job
        reviewed.id = "1e5e1e00"
        reviewed.title = "Job progress screen"
        reviewed.status = .done
        reviewed.base = "dev"
        reviewed.commits = 2
        reviewed.finished = now - 3600
        reviewed.published = "https://github.com/deskree-inc/oby/pull/42"
        reviewed.pullRequest = PullRequestStatus(state: .open, reviewDecision: nil, base: "dev", mergedAt: nil, checkedAt: now)
        reviewed.review = Review(verdict: .approved, job: "r1", agent: "codex", account: "Work", round: 1)
        var merged = reviewed
        merged.id = "3e26ed00"
        merged.title = "Inbox first slice"
        merged.finished = now - 7200
        merged.pullRequest = PullRequestStatus(state: .merged, reviewDecision: .approved, base: "dev", mergedAt: now - 60, checkedAt: now)
        var old = job
        old.id = "01d00000"
        old.status = .done
        old.finished = now - 3 * 86_400
        let question = InboxItem(id: "ab12cd34-question-0", kind: .question, job: "ab12cd34", title: "Vault secrets",
                                 text: "Keep the secrets in the keychain, or in a file?", options: ["Keychain", "A file"], created: now - 180)
        var claude = AccountState(account: Account(id: "default", agent: "claude", name: "Personal", payer: "", home: nil), label: "Max · well@example.com")
        claude.fiveHour = 0.12
        claude.fiveHourResets = now + 2 * 3600 + 10 * 60
        claude.sevenDay = 0.4
        claude.sevenDayResets = now + 4 * 86_400
        claude.running = 1
        let codex = AccountState(account: Account(id: "work", agent: "codex", name: "Work", payer: "Deskree", home: nil))
        let briefing = Briefing(turns: [Turn(who: .user, text: "how is it going?"), Turn(who: .oby, text: "Fine.")],
                                places: [Briefing.Place(name: "this Mac", jobs: [old, merged, reviewed, failed, running], inbox: [question]),
                                         Briefing.Place(name: "tetrix-lab", jobs: [], inbox: [])],
                                accounts: [claude, codex], now: now)
        let text = briefing.text
        #expect(briefing.stoppable == ["ab12cd34"])
        // What needs you first, then working, in review, done; the old job is left out.
        #expect(briefing.jobs.map(\.job.id) == ["fa11ed00", "ab12cd34", "1e5e1e00", "3e26ed00"])
        #expect(!text.contains("01d00000"))
        let headings = ["### Needs you", "### Working", "### In review", "### Done"].compactMap { text.range(of: $0)?.lowerBound }
        #expect(headings == headings.sorted() && headings.count == 4)
        for part in ["User: how is it going?", "Oby: Fine.",
                     "ab12cd34 · Vault secrets · deskree-inc/oby, issue #60 · Claude Code · Personal · running on this Mac · Stage 2 of 5, Work: Round 1 of 1 · started 12 min ago · asked: work on oby #60",
                     "fa11ed00 · Mac runner notifications · deskree-inc/oby, PR #33 · Claude Code · Personal · failed · Stage 2 of 5, Work: Round 1 of 1 · ended 1 min ago · asked: Review oby PR #33",
                     "1e5e1e00 · Job progress screen", "Oby approved · PR https://github.com/deskree-inc/oby/pull/42 open · ended 1 h ago",
                     "3e26ed00 · Inbox first slice", "PR https://github.com/deskree-inc/oby/pull/42 merged · merged 1 min ago · ended 2 h ago",
                     "- Question for job ab12cd34 (Vault secrets, this Mac), waiting 3 min: the question and its options are quoted in work.md",
                     "- Claude Code · Personal (Max): 12% of the 5-hour limit used, resets in 2 h 10 min (at",
                     "; 40% of the 7-day limit used, resets ", "; 1 job running",
                     "- Codex · Work: signed out"] {
            #expect(text.contains(part), "\(part)")
        }
        // What agents wrote never reaches the prompt (AGENTS.md): it's quoted for a file instead.
        for theirs in ["Running swift test", "the tests still fail", "Keep the secrets", "Keychain"] { #expect(!text.contains(theirs), "\(theirs)") }
        let quoted = try #require(briefing.quoted)
        #expect(quoted.hasPrefix("# What the agents wrote, quoted\n"))
        for part in ["## Job ab12cd34 (Vault secrets)\nStep now: Running swift test",
                     "## Job fa11ed00 (Mac runner notifications)\nResult: Nothing committed: the tests still fail.",
                     "## Question for job ab12cd34 (Vault secrets)\nKeep the secrets in the keychain, or in a file?\nOptions: Keychain | A file"] {
            #expect(quoted.contains(part), "\(part)")
        }
        #expect(!quoted.contains("01d00000"))
        // Without anything, it still says so, and there's nothing to quote.
        let empty = Briefing(turns: [], places: [], accounts: [], now: now)
        #expect(empty.text.contains("(Nothing yet.)") && empty.text.contains("(No jobs running or finished lately.)") && empty.text.contains("(Empty.)") && empty.text.contains("(No accounts.)"))
        #expect(empty.quoted == nil)
    }

    /// A job whose coding ended days ago but whose pull request merged today is recent; a
    /// runner's accounts are told with their place.
    @Test func theBriefingKeepsWhatMergedLatelyAndTellsTheRunnersAccounts() throws {
        let now = Date(timeIntervalSince1970: 1_791_582_173)
        var merged = job
        merged.id = "3e26ed00"
        merged.status = .done
        merged.finished = now - 5 * 86_400
        merged.published = "https://github.com/deskree-inc/oby/pull/42"
        merged.pullRequest = PullRequestStatus(state: .merged, reviewDecision: .approved, base: "dev", mergedAt: now - 3600, checkedAt: now)
        var stale = merged
        stale.id = "57a1e000"
        stale.pullRequest?.mergedAt = now - 4 * 86_400
        var codex = AccountState(account: Account(id: "work", agent: "codex", name: "Deskree", payer: "", home: nil), label: "Plus · w@example.com")
        codex.fiveHour = 0.9
        codex.fiveHourResets = now + 45 * 60
        let briefing = Briefing(turns: [], places: [Briefing.Place(name: "tetrix-lab", jobs: [merged, stale], inbox: [], accounts: [codex])],
                                accounts: [], now: now)
        #expect(briefing.jobs.map(\.job.id) == ["3e26ed00"])
        #expect(briefing.text.contains("3e26ed00") && briefing.text.contains("merged 1 h ago · ended 5 days ago"))
        #expect(briefing.text.contains("- Codex · Deskree (Plus) on tetrix-lab: 90% of the 5-hour limit used, resets in 45 min (at"))
        #expect(!briefing.text.contains("(No accounts.)"))
    }

    @Test func plansNamingJobsAreChecked() throws {
        let context = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby"], briefing: "# What Oby knows", jobs: ["ab12cd34"])
        #expect(try Plan.decode(Data(Self.stop(["ab12cd34"]).utf8)).problems(in: context, canary: "zq9").isEmpty)
        #expect(try Plan.decode(Data(Self.stop(["zz"]).utf8)).problems(in: context, canary: "zq9") == ["zz isn't a job Oby can stop"])
        var dispatch = try Plan.decode(Data(Self.reply("ok").utf8))
        dispatch.jobs = ["ab12cd34"]
        #expect(dispatch.problems(in: context, canary: "zq9") == ["only stop_agent, move_job, answer_permission and set_mode name jobs"])
        // Stopping everything is said in so many words, never by naming no job.
        #expect(try Plan.decode(Data(Self.stop([]).utf8)).problems(in: context, canary: "zq9").isEmpty)
        var bare = try Plan.decode(Data(Self.stop([]).utf8))
        bare.all = false
        #expect(bare.problems(in: context, canary: "zq9") == ["stop_agent names the jobs to stop, or all is true for everything"])
        var both = try Plan.decode(Data(Self.stop(["ab12cd34"]).utf8))
        both.all = true
        #expect(both.problems(in: context, canary: "zq9") == ["stop_agent names jobs or stops all, not both"])
        dispatch.jobs = nil
        dispatch.all = true
        #expect(dispatch.problems(in: context, canary: "zq9") == ["only stop_agent stops all"])
        // Older plans have no jobs key; the schema offers only the briefing's running jobs.
        #expect(try Plan.decode(Data(#"{"action":"ignore","reply":"","question":null,"dispatches":[]}"#.utf8)).jobs == nil)
        let schema = try #require(JSONSerialization.jsonObject(with: Plan.schema(for: context)) as? [String: Any])
        let jobs = try #require((schema["properties"] as? [String: Any])?["jobs"] as? [String: Any])
        #expect((jobs["items"] as? [String: Any])?["enum"] as? [String] == ["ab12cd34"])
        #expect((schema["required"] as? [String])?.contains("jobs") == true && (schema["required"] as? [String])?.contains("all") == true)
        let none = try #require(JSONSerialization.jsonObject(with: Plan.schema(for: BrainContext(accounts: [:], repos: []))) as? [String: Any])
        #expect(((none["properties"] as? [String: Any])?["jobs"] as? [String: Any])?["maxItems"] as? Int == 0)
        let long = Plan(action: .replyOnly, reply: String(repeating: "x", count: Plan.replyLength + 1), dispatches: [], question: nil)
        #expect(long.problems(in: context, canary: "zq9") == ["reply is longer than \(Plan.replyLength) characters"])
    }

    @Test func wordsThatCancelAreKnown() {
        for words in ["never mind", "Never mind!", "nevermind", "stop", "STOP.", "cancel", "cancel that", "forget it", "wait", "no, wait"] {
            #expect(Conversation.cancels(words), "\(words)")
        }
        for words in ["stop everything", "stop the vault job", "cancel the review", "never mind that, review PR 12", "how is it going?"] {
            #expect(!Conversation.cancels(words), "\(words)")
        }
    }

    // MARK: The brain's memory

    @Test func theBrainReadsTheConversationAndMayStopOneJob() async throws {
        brain.plans = [Self.reply("Vault secrets is running its tests."), Self.stop(["ab12cd34"])]
        desk.enqueue(vaultJob())
        try await until("the job runs") { desk.jobs.first?.status == .running }

        let first = await desk.converse("how is the vault job going?")
        #expect(first == .reply("Vault secrets is running its tests."))
        let prompt = try #require(brain.prompts.first)
        #expect(prompt.hasPrefix("# What Oby knows right now"))
        #expect(prompt.contains("## The conversation so far\n\n(Nothing yet.)"))
        #expect(prompt.contains("ab12cd34 · Vault secrets") && prompt.contains("running on this Mac"))
        #expect(prompt.hasSuffix("The user says now:\nhow is the vault job going?"))
        // The agent's step is in the quoted file, which the system prompt tells the brain about; never in the prompt.
        #expect(!prompt.contains("Starting Claude Code"))
        #expect(brain.quoted.first??.contains("## Job ab12cd34 (Vault secrets)\nStep now: Starting Claude Code") == true)
        #expect(brain.systems.first?.contains("quoted in the file work.md") == true)
        #expect(desk.turns.map(\.text) == ["how is the vault job going?", "Vault secrets is running its tests."])

        let second = await desk.converse("cancel it")
        #expect(second == .reply("Stopped Vault secrets."))
        #expect(desk.jobs.first?.status == .stopped)
        let again = try #require(brain.prompts.last)
        #expect(again.contains("User: how is the vault job going?\nOby: Vault secrets is running its tests.\n"))
        #expect(desk.turns.count == 4 && desk.turns.last?.text == "Stopped Vault secrets.")
        // Kept across a restart.
        #expect(store().conversation().map(\.text) == desk.turns.map(\.text))
        #expect(Desk(accounts: AccountStore(root: folder), store: store()).turns.count == 4)
    }

    @Test func aStopNamesJobsElsewhereTooAndWaitsForThem() async throws {
        var away = vaultJob()
        away.id = "fa5a5a5a"
        away.title = "Watch home"
        away.status = .running
        desk.elsewhere = { [Briefing.Place(name: "tetrix-lab", jobs: [away], inbox: [])] }
        final class Stopped { var ids: [String] = []; var failing = false }
        let stopped = Stopped()
        desk.stopElsewhere = { ids in
            stopped.ids += ids
            return stopped.failing ? Dictionary(uniqueKeysWithValues: ids.map { ($0, "the runner hung up.") }) : [:]
        }
        brain.plans = [Self.stop(["fa5a5a5a"]), Self.stop(["fa5a5a5a"]), Self.stop(["fa5a5a5a"])]
        #expect(await desk.converse("stop the watch job") == .reply("Stopped Watch home."))
        #expect(stopped.ids == ["fa5a5a5a"])
        #expect(brain.prompts.first?.contains("fa5a5a5a · Watch home · deskree-inc/oby, issue #60 · Claude Code") == true && brain.prompts.first?.contains("running on tetrix-lab") == true)
        // The runner couldn't: Oby says so instead of "Stopped".
        stopped.failing = true
        #expect(await desk.converse("stop it") == .reply("Couldn't stop Watch home: the runner hung up."))
        // Gone between the briefing and the stop: nothing to stop. (The brain can't name a job the
        // briefing didn't list: Swift refuses that plan.)
        desk.elsewhere = { [] }
        let late = Planner.Result(plan: try Plan.decode(Data(Self.stop(["fa5a5a5a"]).utf8)), by: "fake")
        #expect(await desk.card(for: late, said: "stop it") == .reply("That job isn't running any more."))
        // A stop that names nothing and doesn't say everything stops nothing (Swift refuses it
        // from the brain; a plan from elsewhere gets the same answer).
        var bare = try Plan.decode(Data(Self.stop([]).utf8))
        bare.all = false
        #expect(await desk.card(for: Planner.Result(plan: bare, by: "fake"), said: "stop") == .reply("Say which job to stop, or “stop everything”."))
    }

    /// "Stop everything" stops the runner's jobs too, and counts only what did stop.
    @Test func stopEverythingReachesTheRunner() async throws {
        var away = vaultJob()
        away.id = "fa5a5a5a"
        away.title = "Watch home"
        away.status = .running
        var gone = away
        gone.id = "d0ned0ne"
        gone.status = .done
        desk.elsewhere = { [Briefing.Place(name: "tetrix-lab", jobs: [away, gone], inbox: [])] }
        final class Stopped { var ids: [String] = []; var failing = false }
        let stopped = Stopped()
        desk.stopElsewhere = { ids in
            stopped.ids += ids
            return stopped.failing ? Dictionary(uniqueKeysWithValues: ids.map { ($0, "the runner hung up.") }) : [:]
        }
        desk.enqueue(vaultJob())
        try await until("the job runs") { desk.jobs.first?.status == .running }
        brain.plans = [Self.stop([])]
        stopped.failing = true
        #expect(await desk.converse("stop everything") == .reply("Stopped 1 job. Couldn't stop Watch home: the runner hung up."))
        #expect(stopped.ids == ["fa5a5a5a"] && desk.jobs.first?.status == .stopped)
        stopped.failing = false
        #expect(await desk.converse("stop everything") == .reply("Stopped 1 job."))
        desk.elsewhere = { [] }
        #expect(await desk.converse("stop everything") == .reply("Nothing is running."))
    }

    // MARK: Nothing happens for a turn that's over

    /// Cancelled while the brain thought: its plan, a stop, does nothing when it comes.
    @Test func aCancelledTurnStopsNothing() async throws {
        desk.enqueue(vaultJob())
        try await until("the job runs") { desk.jobs.first?.status == .running }
        brain.plans = [Self.stop(["ab12cd34"])]
        brain.slow = { _ in .milliseconds(200) }
        desk.ask("cancel it")
        desk.cancel()
        try await until("the brain answers") { brain.answered.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(desk.jobs.first?.status == .running && desk.talk == .none && desk.turns.isEmpty)
        // The turn is logged with why nothing happened.
        #expect(store().turns().first?.refused.last == "the turn was cancelled before the plan came: nothing done")
    }

    /// Replaced by other words: the first plan does nothing, the second does its job.
    @Test func aReplacedTurnStopsNothing() async throws {
        desk.enqueue(vaultJob())
        try await until("the job runs") { desk.jobs.first?.status == .running }
        brain.plans = [Self.stop(["ab12cd34"]), Self.reply("Still running.")]
        brain.slow = { $0.contains("cancel it") ? .milliseconds(200) : .zero }
        desk.ask("cancel it")
        desk.ask("how is it going?")
        try await until("the brain answers twice") { brain.answered.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(desk.jobs.first?.status == .running && desk.talk == .reply("Still running."))
        #expect(desk.turns.map(\.text) == ["how is it going?", "Still running."])
    }

    /// Given up on: a plan that comes after the time limit does nothing either.
    @Test func aTurnGivenUpOnStopsNothing() async throws {
        desk.enqueue(vaultJob())
        try await until("the job runs") { desk.jobs.first?.status == .running }
        desk.patience = .milliseconds(100)
        brain.plans = [Self.stop(["ab12cd34"])]
        brain.slow = { _ in .milliseconds(400) }
        desk.ask("cancel it")
        try await until("the turn gives up") { desk.talk == .reply(Conversation.timedOut) }
        try await until("the brain answers") { brain.answered.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(desk.jobs.first?.status == .running && desk.talk == .reply(Conversation.timedOut))
    }

    /// A Lead goal cancelled while the Lead thought starts no job.
    @Test func aCancelledGoalStartsNothing() async throws {
        final class SlowLead: LeadAdapter, @unchecked Sendable {
            let name = "slow"
            var answered = 0
            func turn(system: String, user: String, schema: Data, in directory: URL, timeout: TimeInterval) async throws -> Data {
                try await Task.sleep(for: .milliseconds(200))
                answered += 1
                return Data(#"{"action":"start_jobs","reply":"","question":null,"jobs":[{"repo":"deskree-inc/oby","issue":7,"kind":"build","title":"Safe when nobody watches","goal":"Implement F3.","files":["Engine/Desk.swift"],"check":"swift test","out_of_scope":""}]}"#.utf8)
            }
        }
        let lead = SlowLead()
        desk.makeLead = { _ in [lead] }
        desk.leadRoot = folder.appending(path: "leads")
        desk.readBoard = { _ in
            Board(title: "Oby — Roadmap", number: 1, owner: "well-prado", items: [
                BoardItem(repo: "deskree-inc/oby", number: 7, title: "F3 Safe when nobody is watching", url: "https://github.com/deskree-inc/oby/issues/7", status: "Todo", labels: ["feature"]),
            ], user: "well-prado")
        }
        desk.ask("work on the roadmap")
        desk.cancel()
        try await until("the Lead answers") { lead.answered == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(desk.jobs.isEmpty && desk.talk == .none)
        #expect(store().leadTurns().first?.refused.last == "the turn was cancelled before the plan came: nothing started")
    }

    // MARK: Cancelling and replacing

    @Test func cancelDropsThePendingTurnAndALateAnswerIsIgnored() async throws {
        brain.slow = { _ in .milliseconds(300) }
        desk.ask("how are things?")
        #expect(desk.talk == .thinking("how are things?"))
        #expect(desk.turns.map(\.text) == ["how are things?"] && store().conversation().count == 1)
        desk.cancel()
        #expect(desk.talk == .none && desk.turns.isEmpty && store().conversation().isEmpty)
        // The brain's work goes on by itself; its answer, when it comes, changes nothing.
        try await until("the brain answers") { brain.answered.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(desk.talk == .none && desk.turns.isEmpty && store().conversation().isEmpty)
    }

    @Test func aNewMessageReplacesTheTurnUnderWay() async throws {
        brain.plans = [Self.reply("Slow."), Self.reply("Quick.")]
        brain.slow = { $0.contains("slow one") ? .milliseconds(300) : .zero }
        final class Heard { var replies: [(String, Bool)] = [] }
        let heard = Heard()
        desk.onReply = { heard.replies.append(($0, $1)) }
        desk.ask("slow one", spoken: true)
        desk.ask("quick one")
        #expect(desk.talk == .thinking("quick one"))
        try await until("the quick answer comes") { desk.talk == .reply("Quick.") }
        #expect(desk.turns.map(\.text) == ["quick one", "Quick."])
        try await until("the slow answer comes") { brain.answered.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        // The slow answer came and went: nothing changed, and nobody heard it.
        #expect(desk.talk == .reply("Quick.") && desk.turns.map(\.text) == ["quick one", "Quick."])
        #expect(heard.replies.count == 1 && heard.replies.first?.0 == "Quick." && heard.replies.first?.1 == false)
        #expect(store().conversation().map(\.text) == ["quick one", "Quick."])
    }

    @Test func replacingARunnerPlanCancelsTheRunnerBeforeTheOldRequest() async throws {
        final class Events {
            var values: [String] = []
            var finishFirst: (() -> Void)?
        }
        let events = Events()
        desk.plansElsewhere = { true }
        desk.cancelElsewhere = {
            events.values.append("cancel")
            events.finishFirst?()
        }
        desk.planElsewhere = { said, _ in
            if said == "first" {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    events.finishFirst = { continuation.resume() }
                    events.values.append("first started")
                }
                events.values.append("first finished")
            } else {
                events.values.append("second planned")
            }
            return .reply("done")
        }

        desk.ask("first")
        try await until("the first runner request starts") { desk.talk == .thinking("first") && !events.values.isEmpty }
        desk.ask("second")
        try await until("the replacement finishes") { events.values.contains("second planned") }

        #expect(events.values == ["first started", "cancel", "first finished", "second planned"])
    }

    @Test func neverMindAndStopEndTheTurnAndStopNoJob() async throws {
        brain.slow = { $0.contains("slow one") ? .milliseconds(300) : .zero }
        desk.ask("slow one")
        desk.ask("never mind")
        #expect(desk.talk == .none && desk.turns.isEmpty)
        try await until("the slow answer comes") { brain.answered.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        // "Never mind" never reached the brain, and the answer it was for changed nothing.
        #expect(desk.talk == .none && desk.turns.isEmpty && brain.prompts.count == 1)
        // Not thinking either: a bare "stop" never reaches the brain, and no job stops on it.
        desk.enqueue(vaultJob())
        try await until("the job runs") { desk.jobs.first?.status == .running }
        brain.plans = [Self.stop([])]
        for words in ["stop", "Cancel.", "never mind"] {
            desk.ask(words)
            #expect(desk.talk == .none && desk.turns.isEmpty, "\(words)")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(desk.jobs.first?.status == .running && brain.prompts.count == 1)
        #expect(await desk.converse("stop") == .none && desk.jobs.first?.status == .running && brain.prompts.count == 1)
    }

    @Test func aTurnThatTakesTooLongEndsWithAReply() async throws {
        desk.patience = .milliseconds(100)
        brain.slow = { _ in .seconds(2) }
        desk.ask("how are things?")
        try await until("the turn gives up") { desk.talk == .reply(Conversation.timedOut) }
        #expect(desk.turns.map(\.text) == ["how are things?", Conversation.timedOut])
    }

    @Test func theThreadShowsTheOptionPickedAndThePlansLine() async throws {
        brain.plans = [#"{"action":"ask_user","reply":"","question":{"text":"Which repository?","options":["deskree-inc/oby"]},"dispatches":[],"jobs":[]}"#,
                       #"{"action":"dispatch","reply":"Oby will review PR #12 in oby.","question":null,"jobs":[],"dispatches":[{"agent":"auto","account":"auto","repo":"deskree-inc/oby","base_branch":null,"pr":12,"issue":null,"epic":null,"kind":"review","task":"Review PR #12","inputs":[],"rounds":1,"check":null,"complexity":"routine"}]}"#]
        desk.ask("review PR 12")
        try await until("the question comes") { if case .question = desk.talk { true } else { false } }
        #expect(desk.turns.map(\.text) == ["review PR 12", "Which repository?"])
        desk.answer("deskree-inc/oby", said: "review PR 12", question: "Which repository?")
        try await until("the reply comes") { desk.talk == .reply("Oby will review PR #12 in oby.") }
        #expect(desk.turns.map(\.text) == ["review PR 12", "Which repository?", "deskree-inc/oby", "Oby will review PR #12 in oby."])
        #expect(brain.prompts.last?.hasSuffix("The user says now:\n" + Desk.answered("review PR 12", question: "Which repository?", option: "deskree-inc/oby")) == true)
        // The brain saw the thread without the words it was answering.
        #expect(brain.prompts.last?.contains("User: review PR 12\nOby: Which repository?\n\n## Jobs") == true)
    }

    @Test func reviewingAnObyAuthoredPullRequestAgainNamesItsAuthorJob() throws {
        let context = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby", "deskree-inc/another"],
                                  movable: ["author"], reviewAuthors: ["deskree-inc/oby#80": "author"])
        let again = Plan(action: .askReviewAgain, reply: "", dispatches: [], question: nil, jobs: ["author"])
        #expect(again.problems(in: context, canary: "zq9").isEmpty)

        let dispatch = Plan.Dispatch(agent: "claude", account: "default", repo: "deskree-inc/oby", baseBranch: nil,
                                     pr: 80, issue: nil, epic: nil, kind: .review, title: nil, task: "Review PR #80",
                                     inputs: [], rounds: 1, check: nil, complexity: .routine, startWhen: nil, mode: nil)
        let standalone = Plan(action: .dispatch, reply: "", dispatches: [dispatch], question: nil)
        #expect(standalone.problems(in: context, canary: "zq9") == ["PR #80 has Oby author job author; use ask_review_again"])

        var otherRepository = dispatch
        otherRepository.repo = "deskree-inc/another"
        let separatePR = Plan(action: .dispatch, reply: "", dispatches: [otherRepository], question: nil)
        #expect(separatePR.problems(in: context, canary: "zq9").isEmpty)
    }

    // MARK: The store

    @Test func theConversationIsKeptInTheDatabase() throws {
        let url = folder.appending(path: "thread.sqlite")
        do {
            let store = JobStore(url: url)
            for n in 0..<(Conversation.stored + 5) {
                store.save(Turn(id: "t\(n)", date: Date(timeIntervalSince1970: 1_791_582_173 + Double(n)), who: n % 2 == 0 ? .user : .oby, text: "turn \(n)",
                                jobs: n == 7 ? ["ab12cd34"] : nil))
            }
        }
        let store = JobStore(url: url)
        let turns = store.conversation()
        // The last 500, the oldest pruned (#11); the brain still reads only the last 50.
        #expect(Conversation.stored == 500 && Conversation.kept == 50)
        #expect(turns.count == Conversation.stored)
        #expect(turns.first?.text == "turn 5" && turns.last?.text == "turn \(Conversation.stored + 4)")
        #expect(turns.first?.who == .oby && turns.last?.who == .user)
        #expect(turns.first { $0.id == "t7" }?.jobs == ["ab12cd34"] && turns.first?.jobs == nil)
        store.delete(turn: "t5")
        #expect(JobStore(url: url).conversation().first?.text == "turn 6")
    }

    // MARK: One thread for every device (#11)

    /// `GET /v1/conversation` pages the runner's thread, oldest first, by a turn's id; a plan's job
    /// is in the turn that started it (#269); and a `turn` event follows every turn added or changed.
    @Test func theConversationEndpointPagesTheThreadAndItsEventFollowsIt() async throws {
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        final class Heard: @unchecked Sendable { var events: [String] = [] }
        let heard = Heard()
        let stream = api.follow()
        let listening = Task { for await event in stream { heard.events.append(event) } }
        defer { listening.cancel() }
        brain.plans = [Self.reply("One."), Self.reply("Two."), Self.reply("Three."),
                       #"{"action":"dispatch","reply":"Oby will review PR #12 in oby.","question":null,"jobs":[],"dispatches":[{"agent":"auto","account":"auto","repo":"deskree-inc/oby","base_branch":null,"pr":12,"issue":null,"epic":null,"kind":"review","task":"Review PR #12","inputs":[],"rounds":1,"check":null,"complexity":"routine"}]}"#]
        for words in ["first?", "second?", "third?"] { _ = await desk.converse(words) }
        let (talk, started) = await desk.exchange("review PR 12")
        guard case .reply = talk, let job = started.first else { return #expect(Bool(false), "no reply: \(talk)") }
        // Started as it was planned (#269): the job is in Oby's turn from the start, saved and sent with it.
        #expect(desk.turns.last?.who == .oby && desk.turns.last?.jobs == [job.id])
        #expect(desk.turns.count == 8 && desk.turns.dropLast().allSatisfy { $0.jobs == nil })
        #expect(store().conversation().last?.jobs == [job.id])
        try await until("the turn events come") { heard.events.filter { $0.hasPrefix("event: turn\n") }.count == 8 }
        let turnEvents = heard.events.filter { $0.hasPrefix("event: turn\n") }
        let first = object(Data(String(turnEvents[0].dropFirst("event: turn\ndata: ".count)).utf8))
        #expect(first["who"] as? String == "user" && first["text"] as? String == "first?" && first["jobs"] as? [String] == [] && first["at"] is String)
        let linked = object(Data(String(turnEvents[7].dropFirst("event: turn\ndata: ".count)).utf8))
        #expect(linked["id"] as? String == desk.turns.last?.id && linked["jobs"] as? [String] == [job.id] && linked["text"] as? String == "Oby will review PR #12 in oby.")

        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner, desk] client in
            func get(_ uri: String) async throws -> (HTTPResponse.Status, [[String: Any]]) {
                try await client.execute(uri: uri, method: .get, headers: owner) { response in
                    (response.status, (try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [[String: Any]]) ?? [])
                }
            }
            @MainActor func ids() -> [String] { desk.turns.map(\.id) }
            let all = await ids()
            // The whole thread, oldest first, each turn as the API promises it.
            let (status, turns) = try await get("/v1/conversation")
            #expect(status == .ok && turns.count == 8)
            #expect(turns.map { $0["id"] as? String } == all)
            #expect(turns.map { $0["text"] as? String } == ["first?", "One.", "second?", "Two.", "third?", "Three.", "review PR 12", "Oby will review PR #12 in oby."])
            #expect(turns.map { $0["who"] as? String } == ["user", "oby", "user", "oby", "user", "oby", "user", "oby"])
            #expect(turns.allSatisfy { Set($0.keys) == ["id", "who", "text", "at", "jobs"] && ($0["jobs"] as? [String]) != nil })
            #expect(turns.last?["jobs"] as? [String] == [job.id])
            #expect(try #require(turns.first?["at"] as? String).hasSuffix("Z"))
            // The latest 3, then the 3 before the oldest shown, then what's left.
            let (_, latest) = try await get("/v1/conversation?limit=3")
            #expect(latest.map { $0["id"] as? String } == Array(all.suffix(3)))
            let (_, older) = try await get("/v1/conversation?limit=3&before=\(all[5])")
            #expect(older.map { $0["id"] as? String } == Array(all[2..<5]))
            let (_, rest) = try await get("/v1/conversation?limit=3&before=\(all[2])")
            #expect(rest.map { $0["id"] as? String } == Array(all[0..<2]))
            #expect(try await get("/v1/conversation?before=\(all[0])").1.isEmpty)
            // A limit is 1 to 500; an id that isn't in the thread is 404.
            #expect(try await get("/v1/conversation?limit=0").1.count == 1)
            #expect(try await get("/v1/conversation?limit=9999").1.count == 8)
            let (missing, _) = try await get("/v1/conversation?before=nope")
            #expect(missing == .notFound)
        }
    }

    /// The Lead's reply carries the jobs it started, so the window shows them under it.
    @Test func theLeadsReplyLinksTheJobsItStarted() async throws {
        final class QuickLead: LeadAdapter, @unchecked Sendable {
            let name = "quick"
            func turn(system: String, user: String, schema: Data, in directory: URL, timeout: TimeInterval) async throws -> Data {
                Data(#"{"action":"start_jobs","reply":"","question":null,"jobs":[{"repo":"deskree-inc/oby","issue":7,"kind":"build","title":"Safe when nobody watches","goal":"Implement F3.","files":["Engine/Desk.swift"],"check":"swift test","out_of_scope":""}]}"#.utf8)
            }
        }
        desk.makeLead = { _ in [QuickLead()] }
        desk.leadRoot = folder.appending(path: "leads")
        desk.readBoard = { _ in
            Board(title: "Oby — Roadmap", number: 1, owner: "well-prado", items: [
                BoardItem(repo: "deskree-inc/oby", number: 7, title: "F3 Safe when nobody is watching", url: "https://github.com/deskree-inc/oby/issues/7", status: "Todo", labels: ["feature"]),
            ], user: "well-prado")
        }
        let talk = await desk.converse("work on the roadmap")
        guard case .reply(let text) = talk else { return #expect(Bool(false), "\(talk)") }
        #expect(text.hasPrefix("Started 1 job: Safe when nobody watches (#7)."))
        let started = try #require(desk.jobs.first?.id)
        #expect(desk.turns.last?.jobs == [started] && desk.turns.first?.jobs == nil)
        // The next reply doesn't carry them again.
        _ = await desk.converse("thanks")
        #expect(desk.turns.last?.jobs == nil)
    }

    /// The brain's reply never says nothing is running while the header counts agents working,
    /// here or on the runner: Oby answers with the count the header shows instead (#11).
    @Test func theReplyNeverContradictsTheHeaderAboutRunningJobs() async throws {
        var away = vaultJob()
        away.id = "fa5a5a5a"
        away.title = "Watch home"
        away.status = .running
        desk.elsewhere = { [Briefing.Place(name: "tetrix-lab", jobs: [away], inbox: [])] }
        desk.enqueue(vaultJob())
        try await until("the job runs") { desk.jobs.first?.status == .running }
        brain.plans = [Self.reply("No jobs are running right now.")]
        #expect(await desk.converse("anything running?") == .reply("2 agents are working: Vault secrets on this Mac, Watch home on tetrix-lab."))
        // The briefing said so first, in the same count as the header.
        let briefing = desk.briefing(turns: [])
        #expect(briefing.working == 2 && briefing.text.contains("Working now: 2 agents are working: Vault secrets on this Mac, Watch home on tetrix-lab."))
        #expect(brain.systems.last?.contains("never say that nothing is running") == true)
        // Other replies pass as they are, and so does this one once nothing runs.
        brain.plans = [Self.reply("Vault secrets is running its tests.")]
        #expect(await desk.converse("how is it going?") == .reply("Vault secrets is running its tests."))
        _ = desk.stopAll()
        desk.elsewhere = { [] }
        brain.plans = [Self.reply("No jobs are running right now.")]
        #expect(await desk.converse("anything running?") == .reply("No jobs are running right now."))
        #expect(desk.briefing(turns: []).text.contains("Working now: No agent is working right now."))
        for said in ["No jobs are running right now.", "Nothing is running.", "There are no agents working.", "Oby isn't running anything at the moment.",
                     "No running jobs.", "There's nothing in progress.", "Oby is not running any jobs."] {
            #expect(Briefing.contradicts(said), "\(said)")
        }
        // A reply about something else is Oby's own to give, whatever runs: only "no job is
        // running" is a contradiction, never "no jobs failed" or "no jobs waiting for review".
        for said in ["Vault secrets is running its tests.", "2 agents are working.", "No jobs failed this week.", "Nothing needs you.",
                     "There are no jobs that failed today.", "There are no jobs waiting for review.",
                     "No jobs failed; Vault secrets is still running.", "There isn't any work that needs you.",
                     "No jobs are waiting for your review, and nothing failed.", "There are no jobs in review."] {
            #expect(!Briefing.contradicts(said), "\(said)")
        }
        // And such a reply reaches the user as it is while agents work.
        var again = vaultJob()
        again.id = "a6a1a6a1"
        desk.enqueue(again)
        try await until("the job runs") { desk.jobs.first?.status == .running }
        brain.plans = [Self.reply("No jobs failed; Vault secrets is still running.")]
        #expect(await desk.converse("did anything fail?") == .reply("No jobs failed; Vault secrets is still running."))
    }

    // MARK: The runner's API

    @Test func thePlanEndpointTakesRecentTurns() async throws {
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner, brain, desk] client in
            func post(_ body: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                try await client.execute(uri: "/v1/plans", method: .post, headers: owner, body: ByteBuffer(string: body)) { response in
                    (response.status, object(Data(response.body.readableBytesView)))
                }
            }
            @MainActor func texts() -> [String] { desk.turns.map(\.text) }
            let sent = #"{"said": "and the vault one?", "turns": [{"who": "user", "text": "how is the inbox job going?"}, {"who": "oby", "text": "Inbox is at its check."}]}"#
            let (status, answer) = try await post(sent)
            #expect(status == .ok && answer["kind"] as? String == "reply" && answer["text"] as? String == "Fine.")
            let prompt = try #require(brain.prompts.last)
            #expect(prompt.contains("User: how is the inbox job going?\nOby: Inbox is at its check.\n"))
            #expect(prompt.hasSuffix("The user says now:\nand the vault one?"))
            // The exchange joins the runner's own conversation, which is what it reads when a client sends none.
            #expect(await texts() == ["and the vault one?", "Fine."])
            _ = try await post(#"{"said": "thanks"}"#)
            #expect(brain.prompts.last?.contains("User: and the vault one?\nOby: Fine.\n") == true)
            #expect(await texts().count == 4)
            // An answer to the brain's question shows as the option picked.
            _ = try await post(#"{"said": "Review PR 12", "answer": {"question": "Which repository is PR #12 in?", "option": "deskree-inc/oby"}}"#)
            #expect(await texts().suffix(2) == ["deskree-inc/oby", "Fine."])

            for bad in [#"{"said": "hi", "turns": [{"who": "robot", "text": "x"}]}"#,
                        #"{"said": "hi", "turns": [{"who": "user", "text": " "}]}"#,
                        #"{"said": "hi", "turns": [\#(Array(repeating: #"{"who": "user", "text": "x"}"#, count: 51).joined(separator: ","))]}"#] {
                let (status, refusal) = try await post(bad)
                #expect(status == .unprocessableContent && refusal["error"] is String, "\(bad.prefix(60))")
            }
            #expect(try await post(#"{"said": "hi", "turns": "no"}"#).0 == .badRequest)
        }
    }
}
