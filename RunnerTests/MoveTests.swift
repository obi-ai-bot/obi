import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// Where a job can move (issue #118): Swift picks the account, never one past 80% of a window
/// unless the user names it, and checks the tool and the model go together.
struct MoveChoiceTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func state(_ id: String, _ agent: String, fiveHour: Double? = nil, sevenDay: Double? = nil, signedIn: Bool = true,
               fullUntil: Date? = nil) -> AccountState {
        AccountState(account: Account(id: id, agent: agent, name: id.capitalized, payer: "", home: nil), label: signedIn ? "Max" : nil,
                     fiveHour: fiveHour, sevenDay: sevenDay, sevenDayResets: now.addingTimeInterval(86_400), fullUntil: fullUntil)
    }

    var codexJob: Job {
        var job = job
        job.agent = "codex"
        job.account = "deskree"
        return job
    }

    func choose(_ target: MoveTarget, _ accounts: [AccountState], job: Job? = nil) throws -> (account: String, model: String?) {
        let (account, model) = try Moves.choose(job ?? codexJob, to: target, accounts: accounts, now: now)
        return (account.id, model)
    }

    func refusal(_ target: MoveTarget, _ accounts: [AccountState], job: Job? = nil) -> String? {
        do {
            _ = try Moves.choose(job ?? codexJob, to: target, accounts: accounts, now: now)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func aToolGoesToItsLeastBusyAccountWithRoom() throws {
        let accounts = [state("deskree", "codex"), state("work", "claude", fiveHour: 0.85), state("weekly", "claude", sevenDay: 0.81),
                        state("personal", "claude", fiveHour: 0.5, sevenDay: 0.6), state("spare", "claude", fiveHour: 0.2, sevenDay: 0.2)]
        #expect(try choose(MoveTarget(agent: "claude"), accounts).account == "spare")
        // Past 80% of either window, only by name.
        #expect(refusal(MoveTarget(agent: "claude"), Array(accounts.prefix(3)))?.contains("Name one to use it anyway") == true)
        #expect(try choose(MoveTarget(account: "Work"), accounts).account == "work")
        #expect(try choose(MoveTarget(agent: "claude", account: "weekly"), accounts).account == "weekly")
        // Named, but signed out or stopped at its limit.
        #expect(refusal(MoveTarget(account: "out"), accounts + [state("out", "claude", signedIn: false)]) == "Claude Code · Out isn't signed in. Sign in from Settings › Accounts.")
        #expect(refusal(MoveTarget(account: "full"), accounts + [state("full", "claude", fullUntil: now + 3600)])?.hasPrefix("Claude Code · Full hit its usage limit") == true)
        #expect(refusal(MoveTarget(account: "nobody"), accounts) == "There's no account called nobody.")
        #expect(refusal(MoveTarget(agent: "codex", account: "personal"), accounts) == "Personal is a Claude Code account, not Codex's.")
        #expect(refusal(MoveTarget(agent: "gemini"), accounts) == "gemini can't run jobs.")
        #expect(refusal(MoveTarget(agent: "auto", account: " ", model: nil), accounts) == "Say where to move it: a tool, an account or a model.")
    }

    @Test func aModelNamesItsToolAndStaysOnTheJobsAccountWhenItCan() throws {
        var claudeJob = job
        claudeJob.account = "personal"
        let accounts = [state("deskree", "codex"), state("personal", "claude", fiveHour: 0.9), state("spare", "claude")]
        // "Use Fable for that one": the same busy account, a new model.
        let fable = try choose(MoveTarget(model: "claude-fable-5-1"), accounts, job: claudeJob)
        #expect(fable.account == "personal" && fable.model == "claude-fable-5-1")
        // From Codex, Fable means Claude Code: an account with room.
        #expect(try choose(MoveTarget(model: "claude-fable-5-1"), accounts) == ("spare", "claude-fable-5-1"))
        #expect(refusal(MoveTarget(agent: "codex", model: "claude-fable-5-1"), accounts) == "Fable 5.1 is a Claude Code model, not Codex's.")
        #expect(refusal(MoveTarget(model: "claude-opus-9"), accounts) == "Claude Code has no model claude-opus-9.")
        #expect(refusal(MoveTarget(model: "gpt 6; rm -rf"), accounts) == "That isn't a model.")
        // The strongest stays the strongest on another tool; another model becomes the tool's own.
        var strong = codexJob
        strong.model = "gpt-6-astra"
        #expect(try choose(MoveTarget(agent: "claude"), accounts, job: strong) == ("spare", "claude-fable-5-1"))
        strong.model = "gpt-6.1-sol"
        #expect(try choose(MoveTarget(agent: "claude"), accounts, job: strong) == ("spare", nil))
        // "default" drops the job's own model.
        var own = claudeJob
        own.model = "claude-fable-5-1"
        #expect(try choose(MoveTarget(model: Moves.toolDefault), accounts, job: own) == ("personal", nil))
        // Nowhere new to go.
        #expect(refusal(MoveTarget(agent: "claude"), accounts, job: claudeJob) == "It's on Claude Code · Personal already.")
        #expect(refusal(MoveTarget(model: "claude-fable-5-1"), accounts, job: own) == "It's on Claude Code · Personal · Fable 5.1 already.")
    }
}

@MainActor
struct MoveJobTests {
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var prompt = ""
        var stopped = 0
        var sent: [String] = []
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            self.prompt = prompt
            self.onEvent = onEvent
        }
        func send(_ text: String) { sent.append(text) }
        func end() {}
        func stop() { stopped += 1 }
        func kill() {}
    }

    final class Made { var agents: [(agent: Agent, job: Job, home: URL?, resume: String?)] = [] }

    let folder: URL
    let desk: Desk
    let made = Made()
    let codex: Account
    let personal: Account

    init() throws {
        folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        codex = try accounts.add(agent: "codex", name: "Deskree", payer: "Deskree")
        personal = try accounts.add(agent: "claude", name: "Personal", payer: "Wellington")
        accounts.setLabel("Plus · w@example.com", for: codex.id)
        accounts.setLabel("Max · w@example.com", for: personal.id)
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.makeAgent = { [made] job, home, resume in
            let agent = Agent()
            made.agents.append((agent, job, home, resume))
            return agent
        }
        desk.prepare = { $0 }
        desk.countCommits = { _, _ in 1 }
        desk.publishOnItsOwn = { _, _, _ in URL(string: "https://github.com/deskree-inc/oby/pull/80")! }
    }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// A fix job on the Codex account, running.
    func running(_ id: String, rounds: Int? = nil, check: String? = nil) async throws -> Agent {
        var fix = job
        fix.id = id
        fix.kind = .fix
        fix.pr = nil
        fix.base = "dev"
        fix.branch = "oby/fix-75"
        fix.title = "Vault secrets"
        fix.account = codex.id
        fix.agent = "codex"
        fix.rounds = rounds
        fix.check = check
        desk.dispatch(Desk.Draft(said: "work on oby #75", reply: "", job: fix, guessed: false))
        try await until { desk.job(id)?.status == .running }
        return try #require(made.agents.last?.agent)
    }

    @Test func aRunningJobStopsAndGoesOnWhereItWasMoved() async throws {
        let first = try await running("moving", rounds: 3)
        first.onEvent(.session("thread-1"))
        first.onEvent(.turnEnded(summary: "Half the vault is done.\n\nGOAL NOT MET: the other half", failed: false))
        try await until { desk.job("moving")?.currentRound == 2 }
        let moved = try desk.move("moving", to: MoveTarget(agent: "claude"), why: "Codex keeps looping")
        #expect(first.stopped == 1 && made.agents.count == 2)
        let (second, started, home, resume) = try #require(made.agents.last)
        // The same job, worktree and branch, a new session on Claude Code's account.
        #expect(started.id == "moving" && started.branch == "oby/fix-75" && started.agent == "claude" && started.account == personal.id)
        #expect(resume == nil && home?.path == personal.home && moved.session == nil)
        #expect(moved.status == .running && moved.movedLine == "Moved from Codex · Deskree to Claude Code · Personal")
        #expect(moved.moves?.first?.why == "Codex keeps looping")
        // It hears the task, the work so far, and why it moved.
        #expect(second.prompt.hasPrefix(Prompts.agent(started)))
        #expect(second.prompt.contains("The user moved this job to you from Codex · Deskree."))
        #expect(second.prompt.contains("What the user said when they moved it:\n\n> Codex keeps looping"))
        #expect(second.prompt.contains("What earlier rounds reported, oldest first:\n\n> Half the vault is done."))
        #expect(second.prompt.contains("The message that started this round:\n\n> Keep going: the other half"))
        // The first agent no longer speaks for the job.
        first.onEvent(.finished(summary: "late", failed: true))
        #expect(desk.job("moving")?.status == .running)
        second.onEvent(.turnEnded(summary: "fix(vault): done\n\nGOAL MET", failed: false))
        second.onEvent(.finished(summary: "fix(vault): done", failed: false))
        try await until { desk.job("moving")?.isActive == false }
        let ended = try #require(desk.job("moving"))
        #expect(ended.status == .done, "\(ended.summary)")
        #expect(ended.summary.hasPrefix("fix(vault): done") && ended.summary.hasSuffix("\n\nMoved from Codex · Deskree to Claude Code · Personal by you."))
        // The history lasts.
        #expect(JobStore(url: folder.appending(path: "oby.sqlite")).recent().first { $0.id == "moving" }?.moves?.count == 1)
    }

    /// Moved while its check runs: the check is over, its failure counts for nothing, and the job
    /// goes on where it was moved, on its last round and on an earlier one alike.
    @Test(arguments: [nil, 3])
    func aMoveDuringTheCheckLeavesTheMovedJobRunning(rounds: Int?) async throws {
        let gate = AsyncStream<Void>.makeStream()
        desk.runCheck = { _, command, _, _ in
            for await _ in gate.stream { break }
            return Rounds.Check(command: command, passed: false, output: "1 test failed")
        }
        desk.integrity = { _ in Integrity.Report() }
        let first = try await running("checking", rounds: rounds, check: "swift test")
        first.onEvent(.session("thread-1"))
        first.onEvent(.turnEnded(summary: "Fixed it.", failed: false))
        try await until { desk.job("checking")?.phase == .check }
        try desk.move("checking", to: MoveTarget(agent: "claude"))
        let second = try #require(made.agents.last?.agent)
        // The check ends after the move, failing as a cancelled check would.
        gate.continuation.yield()
        gate.continuation.finish()
        try await Task.sleep(for: .milliseconds(100))
        let moved = try #require(desk.job("checking"))
        #expect(moved.status == .running && moved.agent == "claude" && moved.limit == nil)
        #expect(moved.currentRound == 1 && second.stopped == 0 && first.sent.isEmpty && second.sent.isEmpty)
    }

    @Test func aFinishedJobsNextRoundRunsWhereItWasMoved() async throws {
        let first = try await running("later")
        first.onEvent(.session("thread-1"))
        first.onEvent(.turnEnded(summary: "fix: half", failed: false))
        first.onEvent(.finished(summary: "fix: half", failed: false))
        try await until { desk.job("later")?.isActive == false }
        let moved = try desk.move("later", to: MoveTarget(model: "claude-fable-5-1"))
        #expect(moved.status == .done && moved.agent == "claude" && moved.model == "claude-fable-5-1" && moved.session == nil)
        #expect(moved.movedLine == "Moved from Codex · Deskree to Claude Code · Personal · Fable 5.1")
        #expect(made.agents.count == 1)
        #expect(Moves.reply(moved) == "Moved Vault secrets from Codex · Deskree to Claude Code · Personal · Fable 5.1. Its next round runs there: tell it something, or Try again.")
        try desk.message("later", "finish the other half")
        let (second, started, _, resume) = try #require(made.agents.last)
        #expect(made.agents.count == 2 && resume == nil && started.agent == "claude" && started.model == "claude-fable-5-1")
        #expect(second.prompt.contains("The user moved this job to you from Codex · Deskree."))
        #expect(second.prompt.contains("The message that started this round:\n\n> finish the other half"))
    }

    @Test func aQueuedJobStartsWhereItWasMoved() async throws {
        let gate = AsyncStream<Void>.makeStream()
        desk.prepare = { job in
            for await _ in gate.stream { break }
            return job
        }
        var fix = job
        fix.id = "queued"
        fix.account = codex.id
        fix.agent = "codex"
        desk.dispatch(Desk.Draft(said: "review", reply: "", job: fix, guessed: false))
        let moved = try desk.move("queued", to: MoveTarget(account: "Personal"))
        #expect(moved.status == .queued && moved.agent == "claude")
        gate.continuation.yield()
        try await until { desk.job("queued")?.status == .running }
        let started = try #require(made.agents.last?.job)
        #expect(started.agent == "claude" && started.account == personal.id && started.moves?.count == 1)
    }

    @Test func reviewsAndUnknownJobsDontMove() throws {
        #expect(throws: Shell.Failure.self) { try desk.move("nobody", to: MoveTarget(agent: "claude")) }
        var review = job
        review.id = "review"
        review.reviewOf = "author"
        review.status = .done
        let store = JobStore(url: folder.appending(path: "reviews.sqlite"))
        store.save(review)
        let other = Desk(accounts: desk.accounts, store: store)
        #expect(throws: Shell.Failure.self) { try other.move("review", to: MoveTarget(agent: "codex")) }
    }

    // MARK: Ask Oby

    static func move(_ id: String, agent: String = "auto", account: String = "auto", model: String = "auto") -> String {
        #"{"action":"move_job","reply":"","question":null,"dispatches":[],"jobs":["\#(id)"],"all":false,"move":{"agent":"\#(agent)","account":"\#(account)","model":"\#(model)"}}"#
    }

    @Test func movePlansAreChecked() throws {
        let context = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby"], jobs: ["ab12cd34"], movable: ["ab12cd34", "d0ne0000"],
                                   models: ["claude": ["claude-fable-5-1"], "codex": ["gpt-6-astra"]], moveAccounts: ["claude": ["Personal"], "codex": ["Deskree"]])
        let problems = { (json: String) in try Plan.decode(Data(json.utf8)).problems(in: context, canary: "zq9") }
        #expect(try problems(Self.move("d0ne0000", agent: "claude")).isEmpty)
        #expect(try problems(Self.move("ab12cd34", model: "claude-fable-5-1")).isEmpty)
        #expect(try problems(Self.move("zz", agent: "claude")) == ["zz isn't a job Oby can move"])
        #expect(try problems(Self.move("ab12cd34")) == ["move names a tool, an account or a model"])
        #expect(try problems(Self.move("ab12cd34", agent: "codex", account: "Personal")) == ["Personal isn't an account of codex"])
        #expect(try problems(Self.move("ab12cd34", agent: "codex", model: "claude-fable-5-1")) == ["claude-fable-5-1 isn't a model of codex"])
        #expect(try problems(Self.move("ab12cd34", account: "Nobody")) == ["Nobody isn't an account"])
        // A stop can't name a finished job; only move_job has a move.
        #expect(try problems(ConversationTests.stop(["d0ne0000"])) == ["d0ne0000 isn't a job Oby can stop"])
        var reply = try Plan.decode(Data(ConversationTests.reply("ok").utf8))
        reply.move = Plan.Move(agent: "claude", account: "auto", model: "auto")
        #expect(reply.problems(in: context, canary: "zq9") == ["only move_job has a move object"])
        let schema = try #require(JSONSerialization.jsonObject(with: Plan.schema(for: context)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(((properties["jobs"] as? [String: Any])?["items"] as? [String: Any])?["enum"] as? [String] == ["ab12cd34", "d0ne0000"])
        #expect((properties["action"] as? [String: Any])?["enum"] as? [String] == ["dispatch", "ask_user", "reply_only", "stop_agent", "move_job", "ignore"])
        #expect((schema["required"] as? [String])?.contains("move") == true)
        // Without the brain, rules move the only job there is.
        let rules = Rules.plan("move it to Fable", context: BrainContext(accounts: [:], repos: [], movable: ["ab12cd34"]))
        #expect(rules.action == .moveJob && rules.jobs == ["ab12cd34"] && rules.move == Plan.Move(agent: "claude", account: "auto", model: "claude-fable-5-1"))
        #expect(Rules.plan("move it to Codex", context: context).action == .replyOnly)
    }

    @Test func askingObyMovesTheJobHereOrElsewhere() async throws {
        let first = try await running("ab12cd34")
        first.onEvent(.session("thread-1"))
        let brain = ConversationTests.FakeBrain([Self.move("ab12cd34", agent: "claude")])
        desk.makeBrain = { _, _ in [brain] }
        desk.repos = ["deskree-inc/oby"]
        let talk = await desk.converse("move the vault job to Claude")
        #expect(talk == .reply("Moved Vault secrets from Codex · Deskree to Claude Code · Personal. It goes on there now."))
        #expect(desk.job("ab12cd34")?.agent == "claude" && made.agents.count == 2)
        // The brain heard the jobs it may move and where they may go.
        #expect(brain.prompts.first?.contains("ab12cd34 · Vault secrets") == true)
        #expect(made.agents.last?.agent.prompt.contains("> move the vault job to Claude") == true)
        // Already there: Oby says why it couldn't.
        #expect(await desk.converse("put it on Claude") == .reply("Couldn't move it: It's on Claude Code · Personal already."))

        // A job on the runner, from the Mac: the runner moves it.
        var away = job
        away.id = "fa5a5a5a"
        away.title = "Watch home"
        away.status = .done
        away.finished = .now
        desk.elsewhere = { [Briefing.Place(name: "tetrix-lab", jobs: [away], inbox: [])] }
        final class Asked { var moves: [(String, MoveTarget, String?)] = [] }
        let asked = Asked()
        desk.moveElsewhere = { id, target, why in
            asked.moves.append((id, target, why))
            var moved = away
            moved.agent = "codex"
            moved.moves = [Job.Move(from: "Claude Code · Default", to: "Codex · Work", why: why, date: .now)]
            return moved
        }
        brain.plans = [Self.move("fa5a5a5a", agent: "codex")]
        #expect(await desk.converse("put the Watch job on Codex")
                == .reply("Moved Watch home from Claude Code · Default to Codex · Work. Its next round runs there: tell it something, or Try again."))
        #expect(asked.moves.first?.0 == "fa5a5a5a" && asked.moves.first?.1 == MoveTarget(agent: "codex") && asked.moves.first?.2 == "put the Watch job on Codex")
    }

    // MARK: The runner's API

    @Test func theMoveEndpointMovesAJobOrSaysWhyNot() async throws {
        let first = try await running("ab12cd34")
        first.onEvent(.session("thread-1"))
        let app = Application(router: API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json"))).router(owner: "well@example.com"))
        let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
        try await app.test(.router) { client in
            func post(_ id: String, _ body: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                try await client.execute(uri: "/v1/jobs/\(id)/move", method: .post, headers: owner, body: ByteBuffer(string: body)) { response in
                    (response.status, object(Data(response.body.readableBytesView)))
                }
            }
            #expect(try await post("nobody", #"{"agent": "claude"}"#).0 == .notFound)
            #expect(try await post("ab12cd34", "{").0 == .badRequest)
            let (refused, why) = try await post("ab12cd34", #"{"model": "claude-opus-9"}"#)
            #expect(refused == .unprocessableContent && why["error"] as? String == "Claude Code has no model claude-opus-9.")
            let (status, moved) = try await post("ab12cd34", #"{"account": "Personal", "model": "claude-fable-5-1", "why": "faster"}"#)
            #expect(status == .ok && moved["agent"] as? String == "claude" && moved["model"] as? String == "claude-fable-5-1")
            let move = try #require((moved["moves"] as? [[String: Any]])?.first)
            #expect(move["from"] as? String == "Codex · Deskree" && move["to"] as? String == "Claude Code · Personal · Fable 5.1" && move["why"] as? String == "faster")
            #expect(move["date"] is String)
        }
    }
}
