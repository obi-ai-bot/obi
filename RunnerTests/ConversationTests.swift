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
        /// The plans given back so far, slow ones once their wait is over.
        var answered: [String] = []
        var slow: (String) -> Duration = { _ in .zero }
        init(_ plans: [String]) { self.plans = plans }
        func complete(system: String, user: String, schema: Data, timeout: TimeInterval) async throws -> Data {
            prompts.append(user)
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

    static func stop(_ ids: [String]) -> String {
        #"{"action":"stop_agent","reply":"","question":null,"dispatches":[],"jobs":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))]}"#
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
        desk.makeBrain = { [brain] _, _ in [brain] }
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
                     "ab12cd34 · Vault secrets · deskree-inc/oby, issue #60 · Claude Code · running on this Mac · Stage 2 of 5, Work: Round 1 of 1 · Running swift test · started 12 min ago · asked: work on oby #60",
                     "fa11ed00 · Mac runner notifications · deskree-inc/oby, PR #33 · Claude Code · failed · Stage 2 of 5, Work: Round 1 of 1 · Nothing committed: the tests still fail. More below. · ended 1 min ago · result: Nothing committed: the tests still fail.",
                     "1e5e1e00 · Job progress screen", "Oby approved · PR https://github.com/deskree-inc/oby/pull/42 open · ended 1 h ago",
                     "3e26ed00 · Inbox first slice", "PR https://github.com/deskree-inc/oby/pull/42 merged · ended 2 h ago",
                     "- Question for job ab12cd34 (Vault secrets, this Mac), waiting 3 min: Keep the secrets in the keychain, or in a file? Options: Keychain | A file.",
                     "- Claude Code · Personal (Max): 12% of the 5-hour limit used, resets in 2 h 10 min (at",
                     "; 40% of the 7-day limit used, resets ", "; 1 job running",
                     "- Codex · Work: signed out"] {
            #expect(text.contains(part), "\(part)")
        }
        // Without anything, it still says so.
        let empty = Briefing(turns: [], places: [], accounts: [], now: now).text
        #expect(empty.contains("(Nothing yet.)") && empty.contains("(No jobs running or finished lately.)") && empty.contains("(Empty.)") && empty.contains("(No accounts.)"))
    }

    @Test func plansNamingJobsAreChecked() throws {
        let context = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby"], briefing: "# What Oby knows", jobs: ["ab12cd34"])
        #expect(try Plan.decode(Data(Self.stop(["ab12cd34"]).utf8)).problems(in: context, canary: "zq9").isEmpty)
        #expect(try Plan.decode(Data(Self.stop(["zz"]).utf8)).problems(in: context, canary: "zq9") == ["zz isn't a job Oby can stop"])
        var dispatch = try Plan.decode(Data(Self.reply("ok").utf8))
        dispatch.jobs = ["ab12cd34"]
        #expect(dispatch.problems(in: context, canary: "zq9") == ["only stop_agent names jobs"])
        // Older plans have no jobs key; the schema offers only the briefing's running jobs.
        #expect(try Plan.decode(Data(#"{"action":"ignore","reply":"","question":null,"dispatches":[]}"#.utf8)).jobs == nil)
        let schema = try #require(JSONSerialization.jsonObject(with: Plan.schema(for: context)) as? [String: Any])
        let jobs = try #require((schema["properties"] as? [String: Any])?["jobs"] as? [String: Any])
        #expect((jobs["items"] as? [String: Any])?["enum"] as? [String] == ["ab12cd34"])
        #expect((schema["required"] as? [String])?.contains("jobs") == true)
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

    @Test func aStopNamesJobsElsewhereToo() async throws {
        var away = vaultJob()
        away.id = "fa5a5a5a"
        away.title = "Watch home"
        away.status = .running
        desk.elsewhere = { [Briefing.Place(name: "tetrix-lab", jobs: [away], inbox: [])] }
        final class Stopped { var ids: [String] = [] }
        let stopped = Stopped()
        desk.stopElsewhere = { stopped.ids += $0 }
        brain.plans = [Self.stop(["fa5a5a5a"]), Self.stop(["fa5a5a5a"])]
        #expect(await desk.converse("stop the watch job") == .reply("Stopped Watch home."))
        #expect(stopped.ids == ["fa5a5a5a"])
        #expect(brain.prompts.first?.contains("fa5a5a5a · Watch home · deskree-inc/oby, issue #60 · Claude Code · running on tetrix-lab") == true)
        // Gone meanwhile: nothing to stop, and the brain is told so.
        desk.elsewhere = { [] }
        brain.plans = [Self.reply("Nothing runs.")]
        #expect(await desk.converse("stop it") == .reply("Nothing runs."))
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

    @Test func neverMindCancelsOnlyWhileThinking() async throws {
        brain.slow = { $0.contains("slow one") ? .milliseconds(300) : .zero }
        desk.ask("slow one")
        desk.ask("never mind")
        #expect(desk.talk == .none && desk.turns.isEmpty)
        try await until("the slow answer comes") { brain.answered.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        // "Never mind" never reached the brain, and the answer it was for changed nothing.
        #expect(desk.talk == .none && desk.turns.isEmpty && brain.prompts.count == 1)
        // Not thinking: "stop" is for the brain.
        brain.plans = [Self.stop([])]
        desk.ask("stop")
        try await until("the brain answers") { desk.talk == .reply("Nothing is running.") }
        #expect(desk.turns.map(\.text) == ["stop", "Nothing is running."])
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
        try await until("the plan comes") { if case .plan = desk.talk { true } else { false } }
        #expect(desk.turns.map(\.text) == ["review PR 12", "Which repository?", "deskree-inc/oby", "Oby will review PR #12 in oby."])
        #expect(brain.prompts.last?.hasSuffix("The user says now:\n" + Desk.answered("review PR 12", question: "Which repository?", option: "deskree-inc/oby")) == true)
        // The brain saw the thread without the words it was answering.
        #expect(brain.prompts.last?.contains("User: review PR 12\nOby: Which repository?\n\n## Jobs") == true)
    }

    // MARK: The store

    @Test func theConversationIsKeptInTheDatabase() throws {
        let url = folder.appending(path: "thread.sqlite")
        do {
            let store = JobStore(url: url)
            for n in 0..<(Conversation.kept + 5) {
                store.save(Turn(id: "t\(n)", date: Date(timeIntervalSince1970: 1_791_582_173 + Double(n)), who: n % 2 == 0 ? .user : .oby, text: "turn \(n)"))
            }
        }
        let store = JobStore(url: url)
        let turns = store.conversation()
        #expect(turns.count == Conversation.kept)
        #expect(turns.first?.text == "turn 5" && turns.last?.text == "turn \(Conversation.kept + 4)")
        #expect(turns.first?.who == .oby && turns.last?.who == .user)
        store.delete(turn: "t5")
        #expect(JobStore(url: url).conversation().first?.text == "turn 6")
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
            let sent = #"{"said": "and the vault one?", "turns": [{"who": "user", "text": "how is the inbox job going?"}, {"who": "oby", "text": "Inbox is at its check."}]}"#
            let (status, answer) = try await post(sent)
            #expect(status == .ok && answer["kind"] as? String == "reply" && answer["text"] as? String == "Fine.")
            let prompt = try #require(brain.prompts.last)
            #expect(prompt.contains("User: how is the inbox job going?\nOby: Inbox is at its check.\n"))
            #expect(prompt.hasSuffix("The user says now:\nand the vault one?"))
            // The exchange joins the runner's own conversation, which is what it reads when a client sends none.
            #expect(desk.turns.map(\.text) == ["and the vault one?", "Fine."])
            _ = try await post(#"{"said": "thanks"}"#)
            #expect(brain.prompts.last?.contains("User: and the vault one?\nOby: Fine.\n") == true)
            #expect(desk.turns.count == 4)
            // An answer to the brain's question shows as the option picked.
            _ = try await post(#"{"said": "Review PR 12", "answer": {"question": "Which repository is PR #12 in?", "option": "deskree-inc/oby"}}"#)
            #expect(desk.turns.map(\.text).suffix(2) == ["deskree-inc/oby", "Fine."])

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
