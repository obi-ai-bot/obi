import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// Permission modes (#134): Ask, Accept edits, Plan and Bypass. Policy's fixed denials first, in
/// every mode; then the user's rules (deny beats allow); then the mode allows or asks. A waiting
/// permission is like a waiting question: the job stays running, its clocks paused, the inbox has it.
@MainActor
final class PermissionTests {
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var prompt = ""
        var sent: [String] = []
        var answers: [(request: String, answer: ToolAnswer)] = []
        var modes: [PermissionMode] = []
        var ended = false
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            self.prompt = prompt
            self.onEvent = onEvent
        }
        func send(_ text: String) { sent.append(text) }
        func end() { ended = true }
        func stop() {}
        func kill() {}
        func answer(_ call: ToolCall, _ answer: ToolAnswer) { answers.append((call.request, answer)) }
        func setMode(_ mode: PermissionMode) { modes.append(mode) }
    }

    let folder: URL
    let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
    let worktree = URL(filePath: "/tmp/oby/jobs/abc")

    init() throws {
        folder = try temporaryFolder()
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func makeDesk() -> Desk {
        Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
    }

    func fix(_ id: String, mode: PermissionMode) -> Job {
        var fix = job
        fix.id = id
        fix.kind = .fix
        fix.pr = nil
        fix.base = "dev"
        fix.branch = "oby/fix-134"
        fix.title = "Permission modes"
        fix.mode = mode
        return fix
    }

    /// A desk running a job in `mode` on a fake agent, once it's running.
    func running(_ agent: Agent, mode: PermissionMode, id: String = "perm1", desk: Desk? = nil) async throws -> Desk {
        let desk = desk ?? makeDesk()
        desk.makeAgent = { _, _, _ in agent }
        desk.prepare = { $0 }
        desk.countCommits = { _, _ in 0 }
        desk.dispatch(Desk.Draft(said: "work on oby #134", reply: "", job: fix(id, mode: mode), guessed: false))
        for _ in 0..<500 where desk.job(id)?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        agent.onEvent(.session("s134"))
        return desk
    }

    func bash(_ command: String, _ request: String = "r1") -> ToolCall { ToolCall(request: request, tool: "Bash", command: command) }

    // MARK: The table

    @Test func eachModeAllowsOrAsks() {
        let calls = [ToolCall(request: "1", tool: "Read", paths: ["/tmp/oby/jobs/abc/a.swift"]), ToolCall(request: "2", tool: "Grep"),
                     ToolCall(request: "3", tool: "Glob"), ToolCall(request: "4", tool: "mcp__tetrix__get_entity"),
                     ToolCall(request: "5", tool: "Edit", paths: ["/tmp/oby/jobs/abc/Engine/Jobs.swift"]),
                     ToolCall(request: "6", tool: "Write", paths: ["/tmp/oby/jobs/abc/new.swift"]),
                     bash("swift test"), ToolCall(request: "8", tool: "WebFetch", url: "https://example.com")]
        let deny = PermissionPolicy.Verdict.deny(PermissionPolicy.planOnly)
        let table: [PermissionMode: [PermissionPolicy.Verdict]] = [
            .ask: [.allow, .allow, .allow, .allow, .ask, .ask, .ask, .ask],
            .acceptEdits: [.allow, .allow, .allow, .allow, .allow, .allow, .ask, .ask],
            .plan: [.allow, .allow, .allow, .allow, deny, deny, .ask, .ask],
            .bypass: [.allow, .allow, .allow, .allow, .allow, .allow, .allow, .allow],
        ]
        for (mode, verdicts) in table {
            #expect(calls.map { PermissionPolicy.decide($0, mode: mode, rules: [], worktree: worktree) } == verdicts, "\(mode)")
        }
        // Helpers and the to-do list never ask, and aren't taken for background work: the agents asked
        // Policy about that with their whole input, which a ToolCall doesn't carry.
        for tool in ["Agent", "Task", "TodoWrite"] {
            #expect(PermissionMode.allCases.allSatisfy { PermissionPolicy.decide(ToolCall(request: "h", tool: tool), mode: $0, rules: [], worktree: worktree) == .allow }, "\(tool)")
        }
        // The plan's own end asks only in Plan.
        let exit = ToolCall(request: "9", tool: "ExitPlanMode", plan: "1. Read")
        #expect(PermissionMode.allCases.map { PermissionPolicy.decide(exit, mode: $0, rules: [], worktree: worktree) } == [.allow, .allow, .ask, .allow])
        #expect(PermissionMode(named: "Accept edits") == .acceptEdits && PermissionMode(named: "acceptEdits") == .acceptEdits && PermissionMode(named: "nope") == nil)
    }

    @Test func aFixedDenialWinsInBypass() {
        let allowAll = ["Bash(git push:*)", "Bash(git:*)", "Edit", "mcp__github__create_issue"].map {
            PermissionRule(id: $0, rule: $0, repo: "deskree-inc/oby", decision: .allow, created: .now)
        }
        let fenced = [bash("git push origin HEAD"), bash("gh pr create --fill"), ToolCall(request: "2", tool: "Edit", paths: ["/etc/hosts"]),
                      ToolCall(request: "3", tool: "mcp__github__create_issue")]
        for call in fenced {
            for mode in PermissionMode.allCases {
                guard case .deny = PermissionPolicy.decide(call, mode: mode, rules: allowAll, worktree: worktree) else {
                    Issue.record("\(call.tool) \(call.command ?? "") went through in \(mode)")
                    continue
                }
            }
        }
        // A helper left running in the background is still Policy's no, before the mode.
        #expect(Policy.deny(tool: "Agent", input: ["description": "look"], worktree: worktree) != nil)
        #expect(Policy.deny(tool: "Agent", input: ["description": "look", "run_in_background": false], worktree: worktree) == nil)
        // Agents ask Policy first, as before: a push never reaches the mode.
        #expect(Policy.deny(tool: "Bash", input: ["command": "git push"], worktree: worktree) != nil)
    }

    @Test func rulesDenyBeatsAllow() {
        let allow = PermissionRule(id: "a", rule: "Bash(swift test:*)", repo: "deskree-inc/oby", decision: .allow, created: .now)
        let deny = PermissionRule(id: "d", rule: "Bash(swift test --filter Slow:*)", repo: "deskree-inc/oby", decision: .deny, created: .now)
        #expect(PermissionPolicy.decide(bash("swift test --filter SpeechTests"), mode: .ask, rules: [allow], worktree: worktree) == .allow)
        #expect(PermissionPolicy.decide(bash("swift test"), mode: .ask, rules: [allow], worktree: worktree) == .allow)
        // Not another command that starts the same, and never a chained one.
        #expect(PermissionPolicy.decide(bash("swift testing"), mode: .ask, rules: [allow], worktree: worktree) == .ask)
        #expect(PermissionPolicy.decide(bash("swift test && rm -rf build"), mode: .ask, rules: [allow], worktree: worktree) == .ask)
        #expect(PermissionPolicy.decide(bash("swift test | tee log"), mode: .ask, rules: [allow], worktree: worktree) == .ask)
        // Deny beats allow, even in Bypass, and covers a chained command.
        for mode in PermissionMode.allCases {
            guard case .deny = PermissionPolicy.decide(bash("swift test --filter Slow"), mode: mode, rules: [allow, deny], worktree: worktree) else {
                Issue.record("allowed in \(mode)")
                continue
            }
        }
        guard case .deny = PermissionPolicy.decide(bash("swift build && swift test --filter Slow"), mode: .bypass, rules: [deny], worktree: worktree) else {
            Issue.record("a chained command got past a deny rule")
            return
        }
        // Edits: every edit, or a folder's.
        let engine = PermissionRule(id: "e", rule: "Edit(Engine/*)", repo: "deskree-inc/oby", decision: .allow, created: .now)
        #expect(PermissionPolicy.decide(ToolCall(request: "e", tool: "Edit", paths: ["/tmp/oby/jobs/abc/Engine/Jobs.swift"]), mode: .ask, rules: [engine], worktree: worktree) == .allow)
        #expect(PermissionPolicy.decide(ToolCall(request: "e", tool: "Edit", paths: ["/tmp/oby/jobs/abc/Mac/App.swift"]), mode: .ask, rules: [engine], worktree: worktree) == .ask)
        // Plan changes nothing: a saved allow rule doesn't let a command through while planning.
        let touch = PermissionRule(id: "t", rule: "Bash(touch:*)", repo: "deskree-inc/oby", decision: .allow, created: .now)
        #expect(PermissionPolicy.decide(bash("touch example.swift"), mode: .ask, rules: [touch], worktree: worktree) == .allow)
        #expect(PermissionPolicy.decide(bash("touch example.swift"), mode: .plan, rules: [touch], worktree: worktree) == .ask)
    }

    @Test func theCardSaysWhatAndWhichRule() {
        #expect(PermissionPolicy.prefix(of: "swift test --filter SpeechTests") == "swift test")
        #expect(PermissionPolicy.prefix(of: "ls -la") == "ls")
        #expect(PermissionPolicy.prefix(of: "cat Package.swift") == "cat")
        #expect(PermissionPolicy.prefix(of: "swift build && swift test") == nil)
        #expect(PermissionPolicy.prefix(of: "FOO=1 swift test") == nil)
        let card = PermissionPolicy.permission(for: bash("swift test --filter SpeechTests"), id: "p1", repo: "deskree-inc/oby", worktree: worktree)
        #expect(card == Permission(id: "p1", tool: "Bash", title: "Run swift test", detail: "swift test --filter SpeechTests", rule: "Bash(swift test:*)",
                                   always: "Yes, and don't ask again for swift test in deskree-inc/oby"))
        let chained = PermissionPolicy.permission(for: bash("swift build && swift test"), id: "p2", repo: "deskree-inc/oby", worktree: worktree)
        #expect(chained.rule == nil && chained.always == nil && chained.title == "Run swift build && swift test")
        let edit = PermissionPolicy.permission(for: ToolCall(request: "e", tool: "Edit", paths: ["/tmp/oby/jobs/abc/Engine/Jobs.swift"]), id: "p3",
                                          repo: "deskree-inc/oby", worktree: worktree)
        #expect(edit.title == "Edit Jobs.swift" && edit.detail == "Engine/Jobs.swift" && edit.rule == "Edit")
        #expect(Inbox.need(of: { var job = fix("c", mode: .ask); job.status = .running; job.permission = chained; return job }())?.options == ["Allow", "Deny"])
    }

    // MARK: Waiting

    /// A helper agent in the foreground goes through in every mode, and never counts toward the
    /// denials in a row that hold a job.
    @Test func helpersGoThroughInEveryMode() async throws {
        for (index, mode) in PermissionMode.allCases.enumerated() {
            let agent = Agent()
            let desk = try await running(agent, mode: mode, id: "help\(index)")
            for request in ["h1", "h2", "h3"] { agent.onEvent(.ask(ToolCall(request: request, tool: "Agent"))) }
            #expect(agent.answers.map(\.request) == ["h1", "h2", "h3"] && agent.answers.allSatisfy { $0.answer == .allow }, "\(mode)")
            #expect(desk.job("help\(index)")?.status == .running && desk.job("help\(index)")?.permission == nil, "\(mode)")
        }
    }

    @Test func aPermissionWaitsInTheInboxAndAlwaysSavesARuleTheNextPromptUses() async throws {
        let agent = Agent()
        let desk = try await running(agent, mode: .ask)
        var told: [InboxItem] = []
        desk.onInboxChange = { told.append($0) }
        agent.onEvent(.ask(bash("swift test --filter SpeechTests", "r1")))

        let waiting = try #require(desk.job("perm1"))
        #expect(waiting.status == .running && waiting.step == "Waiting for your OK" && agent.answers.isEmpty)
        let permission = try #require(waiting.permission)
        #expect(permission.title == "Run swift test" && permission.rule == "Bash(swift test:*)")
        #expect(Push.notice(for: waiting) == .permission)
        let alert = object(try Push.notification(.permission, for: waiting))
        #expect((((alert["aps"] as? [String: Any])?["alert"] as? [String: Any])?["title"] as? String) == "Run swift test?")
        let item = try #require(desk.inbox.last)
        #expect(item.kind == .permission && item.id == "perm1-permission-\(permission.id)" && item.text == "Run swift test")
        #expect(item.options == ["Allow", "Always allow", "Deny"] && told.contains(item))

        try desk.settle(item.id, .answer("Always allow"))
        #expect(agent.answers.map(\.request) == ["r1"] && agent.answers.first?.answer == .always)
        #expect(desk.permissionRules.map(\.rule) == ["Bash(swift test:*)"] && desk.permissionRules.first?.repo == "deskree-inc/oby")
        let answered = try #require(desk.job("perm1"))
        #expect(answered.permission == nil && answered.step == "Allowed: Run swift test" && Push.notice(for: answered) == nil)
        #expect(desk.item(item.id)?.isOpen == false && desk.item(item.id)?.answer == "Always allow")

        // The next swift test goes through by itself; another command still asks.
        agent.onEvent(.ask(bash("swift test", "r2")))
        #expect(agent.answers.last?.request == "r2" && agent.answers.last?.answer == .allow && desk.job("perm1")?.permission == nil)
        agent.onEvent(.ask(bash("swift build", "r3")))
        #expect(desk.job("perm1")?.permission?.title == "Run swift build" && agent.answers.count == 2)
        // Forgetting the rule asks again.
        try desk.forgetRule(try #require(desk.permissionRules.first).id)
        #expect(desk.permissionRules.isEmpty)
        #expect(throws: Shell.Failure.self) { try desk.forgetRule("nope") }
    }

    @Test func denyReachesTheAgentWithTheWords() async throws {
        let agent = Agent()
        let desk = try await running(agent, mode: .ask)
        agent.onEvent(.ask(bash("swift test", "r1")))
        let item = try #require(desk.inbox.last)
        try desk.settle(item.id, .answer("No, run only RunnerTests"))
        #expect(agent.answers.first?.answer == .deny("No, run only RunnerTests"))
        #expect(desk.job("perm1")?.notes == ["No, run only RunnerTests"] && desk.job("perm1")?.permission == nil)
        #expect(desk.item(item.id)?.answer == "No, run only RunnerTests")

        // A plain Deny, and words told to the job while it waits, say no too.
        agent.onEvent(.ask(bash("swift build", "r2")))
        try desk.settle(try #require(desk.inbox.last).id, .answer("Deny"))
        #expect(agent.answers.last?.answer == .deny(PermissionPolicy.saidNo))
        agent.onEvent(.ask(bash("make", "r3")))
        try desk.message("perm1", "use swift build instead")
        #expect(agent.answers.last?.answer == .deny("use swift build instead") && agent.sent.isEmpty)
        // The user's no doesn't count toward Oby's limit on denials in a row.
        #expect(desk.job("perm1")?.status == .running)
    }

    @Test func aWaitingPermissionPausesTheRoundClock() async throws {
        let agent = Agent()
        let desk = makeDesk()
        desk.limits.round = 0.5
        _ = try await running(agent, mode: .ask, desk: desk)
        agent.onEvent(.ask(bash("swift test", "r1")))
        // Waiting longer than the round may take: no limit.
        try await Task.sleep(for: .milliseconds(900))
        #expect(desk.job("perm1")?.status == .running && desk.job("perm1")?.limit == nil)
        try desk.answerPermission("perm1", try #require(desk.job("perm1")?.permission?.id), .allow)
        #expect(desk.job("perm1")?.status == .running)
        // Then the round's clock goes on from where it stopped, and still holds.
        for _ in 0..<300 where desk.job("perm1")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(desk.job("perm1")?.limit == "the round ran past 0.5 seconds")
    }

    @Test func stoppingDropsItAndARestartKeepsIt() async throws {
        let agent = Agent()
        let desk = try await running(agent, mode: .acceptEdits)
        agent.onEvent(.ask(bash("swift test", "r1")))
        let item = try #require(desk.inbox.last)
        // The runner restarts: the job is interrupted, keeping its permission and its item.
        let again = makeDesk()
        let interrupted = try #require(again.job("perm1"))
        #expect(interrupted.status == .interrupted && interrupted.permission == desk.job("perm1")?.permission)
        #expect(again.item(item.id)?.isOpen == true && Push.notice(for: interrupted) == .permission)
        // Answering picks the session up again, telling the agent.
        let resumed = Agent()
        again.makeAgent = { _, _, resume in resume == "s134" ? resumed : nil }
        let permission = try #require(interrupted.permission)
        try again.answerPermission("perm1", permission.id, .allow)
        #expect(resumed.prompt == PermissionPolicy.later(permission, .allow) && again.job("perm1")?.status == .running)
        #expect(again.job("perm1")?.permission == nil && again.item(item.id)?.isOpen == false)

        // Stopping a waiting job drops its permission.
        let other = Agent()
        let stopping = try await running(other, mode: .ask, id: "perm2")
        other.onEvent(.ask(bash("swift test", "r1")))
        stopping.stop("perm2")
        #expect(stopping.job("perm2")?.permission == nil && stopping.inbox.allSatisfy { !$0.isOpen || $0.job != "perm2" })
    }

    /// On the runner, a restart picks running jobs up again, but not one waiting for the user's OK:
    /// it stays interrupted, keeping its permission, as one waiting on a question does. Nor does it
    /// hold up a runner update's drain.
    @Test func theRunnerKeepsAWaitingPermissionThroughARestart() async throws {
        let restarts = folder.appending(path: "restarts.json")
        let runner = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")),
                          restarts: Restarts(file: restarts))
        let agent = Agent()
        _ = try await running(agent, mode: .ask, desk: runner)
        agent.onEvent(.ask(bash("swift test", "r1")))
        let permission = try #require(runner.job("perm1")?.permission)
        runner.drainingForUpdate = true
        #expect(runner.updateIsIdle)

        let again = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")),
                         restarts: Restarts(file: restarts))
        var made = 0
        again.makeAgent = { _, _, _ in made += 1; return Agent() }
        again.resumeAfterRestart()
        let interrupted = try #require(again.job("perm1"))
        #expect(interrupted.status == .interrupted && interrupted.permission == permission && made == 0)
    }

    @Test func changingTheModeAnswersWhatItAllows() async throws {
        let agent = Agent()
        let desk = try await running(agent, mode: .ask)
        agent.onEvent(.ask(ToolCall(request: "e1", tool: "Edit", paths: [Workspace.worktree("perm1").appending(path: "Engine/Jobs.swift").path])))
        agent.onEvent(.ask(bash("swift test", "r2")))
        #expect(desk.job("perm1")?.permission?.title == "Edit Jobs.swift")
        // Accept edits answers the edit; the command still waits.
        try desk.setMode("perm1", .acceptEdits)
        #expect(agent.modes == [.acceptEdits] && agent.answers.map(\.request) == ["e1"])
        #expect(desk.job("perm1")?.permission?.title == "Run swift test" && desk.job("perm1")?.mode == .acceptEdits)
        // Bypass answers the rest, and the ones after it.
        try desk.setMode("perm1", .bypass)
        #expect(agent.answers.map(\.request) == ["e1", "r2"] && desk.job("perm1")?.permission == nil)
        agent.onEvent(.ask(bash("swift build", "r3")))
        #expect(agent.answers.last?.request == "r3" && agent.answers.last?.answer == .allow)
    }

    // MARK: Plans

    @Test func aPlanWaitsForApprovalAndRunsInTheModePicked() async throws {
        let agent = Agent()
        let desk = try await running(agent, mode: .plan)
        #expect(agent.prompt.contains(Prompts.planFirst))
        // Edits are refused while it plans.
        agent.onEvent(.ask(ToolCall(request: "e1", tool: "Edit", paths: [Workspace.worktree("perm1").appending(path: "a.swift").path])))
        #expect(agent.answers.last?.answer == .deny(PermissionPolicy.planOnly))
        agent.onEvent(.ask(ToolCall(request: "x1", tool: "ExitPlanMode", plan: "1. Add modes\n2. Test them")))
        let waiting = try #require(desk.job("perm1"))
        let question = try #require(waiting.question)
        #expect(question == Plan.Question(text: "Approve the plan?", options: ["Approve: Accept edits", "Approve: Bypass", "Change it"],
                                         recommended: 0, plan: "1. Add modes\n2. Test them"))
        #expect(waiting.permission == nil && waiting.status == .running && Push.notice(for: waiting) == .question)
        let item = try #require(desk.inbox.last)
        #expect(item.kind == .question && item.options == PermissionPolicy.planOptions)

        // Change it sends it back; a new plan waits again.
        try desk.settle(item.id, .answer("Change it"))
        #expect(agent.answers.last?.request == "x1" && agent.answers.last?.answer == .deny(PermissionPolicy.changePlan) && desk.job("perm1")?.question == nil)
        agent.onEvent(.ask(ToolCall(request: "x2", tool: "ExitPlanMode", plan: "1. Add modes, smaller")))
        try desk.settle(try #require(desk.inbox.last).id, .answer("Approve: Accept edits"))
        #expect(agent.answers.last?.request == "x2" && agent.answers.last?.answer == .allow && agent.modes == [.acceptEdits])
        let approved = try #require(desk.job("perm1"))
        #expect(approved.mode == .acceptEdits && approved.question == nil && approved.step == "Plan approved: Accept edits")
        // Now edits go through, and commands ask.
        agent.onEvent(.ask(ToolCall(request: "e2", tool: "Edit", paths: [Workspace.worktree("perm1").appending(path: "a.swift").path])))
        #expect(agent.answers.last?.request == "e2" && agent.answers.last?.answer == .allow)
        agent.onEvent(.ask(bash("swift test", "r1")))
        #expect(desk.job("perm1")?.permission != nil)
    }

    /// A plan given as a turn's summary waits like a permission: the job's clock stops, so waiting
    /// for the user never reaches the job's limit, and goes on once the plan is approved.
    @Test func aPlanAsASummaryPausesTheJobClock() async throws {
        let agent = Agent()
        let desk = makeDesk()
        desk.limits.job = 0.5
        _ = try await running(agent, mode: .plan, desk: desk)
        agent.onEvent(.turnEnded(summary: "Here's the plan:\n1. Add modes", failed: false))
        try await Task.sleep(for: .milliseconds(900))
        #expect(desk.job("perm1")?.status == .running && desk.job("perm1")?.limit == nil)
        try desk.setMode("perm1", .acceptEdits)
        for _ in 0..<300 where desk.job("perm1")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(desk.job("perm1")?.limit == "the job ran past 0.5 seconds")
    }

    /// The user's words for the agent with a no, or a plan sent back, are a message like any
    /// other: the vault's secrets don't reach the agent.
    @Test func denyWordsLeaveTheVaultsSecretsOut() async throws {
        let agent = Agent()
        let desk = makeDesk()
        let value = "tok/\(UUID().uuidString.prefix(12))+a=b"
        desk.vault = Vault(store: FileVault(folder: folder.appending(path: "vault")))
        try desk.vault.add(value, as: "staging-api-key")
        _ = try await running(agent, mode: .ask, desk: desk)
        agent.onEvent(.ask(bash("swift test", "r1")))
        try desk.answerPermission("perm1", try #require(desk.job("perm1")?.permission?.id), .deny, message: "use \(value) instead")
        #expect(agent.answers.last?.answer == .deny("use [vault: staging-api-key] instead"))
    }

    /// Codex, or an agent that ends its turn with the plan: the plan is the summary, and approving
    /// it sends the go-ahead for the next turn, in the mode picked.
    @Test func aPlanAsASummaryIsApprovedForTheNextTurn() async throws {
        let agent = Agent()
        let desk = try await running(agent, mode: .plan)
        agent.onEvent(.turnEnded(summary: "Here's the plan:\n1. Add modes", failed: false))
        let waiting = try #require(desk.job("perm1"))
        #expect(waiting.question?.plan == "Here's the plan:\n1. Add modes" && waiting.step == "Waiting for your OK on the plan" && !agent.ended)
        try desk.setMode("perm1", .bypass)
        #expect(agent.modes == [.bypass] && agent.sent == [PermissionPolicy.approved(.bypass)])
        #expect(desk.job("perm1")?.mode == .bypass && desk.job("perm1")?.question == nil && desk.job("perm1")?.notes == ["Approve: Bypass"])
        #expect(PermissionPolicy.approval("Approve: Accept edits") == .acceptEdits && PermissionPolicy.approval("yes") == .acceptEdits)
        #expect(PermissionPolicy.approval("Approve: Bypass") == .bypass && PermissionPolicy.approval("Change it") == nil && PermissionPolicy.approval("no, smaller") == nil)
    }

    // MARK: Questions

    @Test func theRecommendedOptionIsReadFromTheOptionsLine() throws {
        let asked = Inbox.question(in: "Read it.\nQUESTION: Keep the old status?\nOPTIONS: Remove it | Keep it (recommended) | Ask later | Never")
        #expect(asked == Plan.Question(text: "Keep the old status?", options: ["Remove it", "Keep it", "Ask later"], recommended: 1))
        #expect(Inbox.question(in: "QUESTION: Which?\nOPTIONS: A (Recommended) | B")?.recommended == 0)
        #expect(Inbox.question(in: "QUESTION: Which?\nOPTIONS: A | B")?.recommended == nil)
        // A mark on an option that's cut off recommends nothing.
        #expect(Inbox.question(in: "QUESTION: Which?\nOPTIONS: A | B | C | D (recommended)")?.recommended == nil)
        #expect(Inbox.howToAsk.contains("(recommended)") && Inbox.howToAsk.contains("at most 3 options"))
        // Every key goes out, null when there's nothing.
        let json = object(try API.encode(Plan.Question(text: "Which?", options: ["A"])))
        #expect(json["recommended"] is NSNull && json["plan"] is NSNull)
    }

    @Test func theBrainsQuestionCarriesItsRecommendation() throws {
        let context = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby"])
        let asked = #"{"action":"ask_user","reply":"","dispatches":[],"question":{"text":"Which repository?","options":["deskree-inc/oby","deskree-inc/blok"],"recommended":0},"jobs":[],"all":false,"decision":null,"message":null,"mode":null}"#
        let plan = try Plan.decode(Data(asked.utf8))
        #expect(plan.question?.recommended == 0 && plan.problems(in: context, canary: "zq9").isEmpty)
        var wrong = plan
        wrong.question?.recommended = 2
        #expect(wrong.problems(in: context, canary: "zq9") == ["recommended is the index of one of the options, or null"])
        let schema = String(decoding: Plan.schema(for: context), as: UTF8.self)
        #expect(schema.contains(#""recommended""#) && schema.contains(#""maxItems":3"#))
        #expect(Rules.plan("hello", context: BrainContext(accounts: ["claude": ["default"]], repos: ["a/1", "a/2", "a/3", "a/4"])).question?.options.count == 3)
    }

    // MARK: Conversation

    @Test func theBrainAnswersPermissionsAndChangesModes() async throws {
        let context = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby"], jobs: ["perm1"], permissions: ["perm1"])
        func plan(_ action: Plan.Action, jobs: [String], decision: PermissionDecision? = nil, message: String? = nil, mode: PermissionMode? = nil) -> Plan {
            Plan(action: action, reply: "", dispatches: [], question: nil, jobs: jobs, decision: decision, message: message, mode: mode)
        }
        #expect(plan(.answerPermission, jobs: ["perm1"], decision: .always).problems(in: context, canary: "zq9").isEmpty)
        #expect(plan(.answerPermission, jobs: ["zz"], decision: .allow).problems(in: context, canary: "zq9") == ["zz isn't waiting for the user's OK"])
        #expect(plan(.answerPermission, jobs: ["perm1"]).problems(in: context, canary: "zq9") == ["answer_permission needs its decision"])
        #expect(plan(.setMode, jobs: ["perm1"]).problems(in: context, canary: "zq9") == ["set_mode needs its mode"])
        #expect(plan(.replyOnly, jobs: [], mode: .ask).problems(in: context, canary: "zq9") == ["only set_mode has a mode"])
        #expect(plan(.replyOnly, jobs: [], decision: .allow).problems(in: context, canary: "zq9") == ["only answer_permission has a decision or a message"])

        let agent = Agent()
        let desk = try await running(agent, mode: .ask)
        agent.onEvent(.ask(bash("swift test", "r1")))
        // The briefing lists the job as waiting, and the brain may name it.
        let briefing = desk.briefing(turns: [])
        #expect(briefing.permissions == ["perm1"] && briefing.text.contains("waiting for the user's OK on a permission"))
        #expect(!briefing.text.contains("swift test"))
        #expect(desk.brainContext(turns: []).permissions == ["perm1"])

        // "no, run only RunnerTests"
        let no = await desk.card(for: Planner.Result(plan: plan(.answerPermission, jobs: ["perm1"], decision: .deny, message: "Run only RunnerTests"), by: "claude"), said: "no, run only RunnerTests")
        #expect(no == .reply("Told Permission modes no, with your words.") && agent.answers.last?.answer == .deny("Run only RunnerTests"))
        // "always allow that"
        agent.onEvent(.ask(bash("swift test --filter Speech", "r2")))
        let always = await desk.card(for: Planner.Result(plan: plan(.answerPermission, jobs: ["perm1"], decision: .always), by: "claude"), said: "always allow that")
        #expect(always == .reply("Allowed it for Permission modes, and saved the rule for oby: it won't ask again for that."))
        #expect(agent.answers.last?.answer == .always && desk.permissionRules.count == 1)
        // "allow it", with nothing waiting
        let nothing = await desk.card(for: Planner.Result(plan: plan(.answerPermission, jobs: ["perm1"], decision: .allow), by: "claude"), said: "allow it")
        #expect(nothing == .reply("Permission modes isn't waiting for your OK."))
        // "stop asking on the Watch job"
        let bypass = await desk.card(for: Planner.Result(plan: plan(.setMode, jobs: ["perm1"], mode: .bypass), by: "claude"), said: "stop asking on it")
        #expect(bypass == .reply("Permission modes is in Bypass mode now.") && desk.job("perm1")?.mode == .bypass && agent.modes == [.bypass])
        // A job elsewhere goes through the closure.
        var elsewhere = fix("away1", mode: .ask)
        elsewhere.status = .running
        desk.elsewhere = { [Briefing.Place(name: "tetrix-lab", jobs: [elsewhere], inbox: [])] }
        desk.modeElsewhere = { job, mode in job.id == "away1" && mode == .plan ? nil : "wrong" }
        let away = await desk.card(for: Planner.Result(plan: plan(.setMode, jobs: ["away1"], mode: .plan), by: "claude"), said: "plan first for that job")
        #expect(away == .reply("Permission modes is in Plan mode now."))
    }

    @Test func dispatchedJobsTakeTheDefaultOrTheirOwnMode() async throws {
        let desk = makeDesk()
        #expect(desk.defaultMode == .bypass)
        desk.defaultMode = .ask
        #expect(makeDesk().defaultMode == .ask)
        desk.prepare = { $0 }
        desk.makeAgent = { _, _, _ in Agent() }
        var plain = fix("d1", mode: .bypass)
        plain.mode = nil
        #expect(desk.enqueue(plain).mode == .ask)
        #expect(desk.enqueue(fix("d2", mode: .plan)).mode == .plan)
        // Prompts and Claude Code's command line follow the mode: plan is Claude Code's own, and
        // no mode ever starts it with its bypass.
        for mode in PermissionMode.allCases {
            let launch = try ClaudeAgent.launch(worktree: folder, configDirectory: nil, model: "opus", resume: nil, mode: mode)
            #expect(launch.arguments.contains("--permission-prompt-tool") && !launch.arguments.contains { $0.lowercased().contains("bypass") || $0.contains("skip-permissions") })
            #expect(launch.arguments.contains("--permission-mode") == (mode == .plan))
            #expect(Prompts.agent(fix("m", mode: mode)).contains(Prompts.planFirst) == (mode == .plan))
        }
    }

    // MARK: The agents' answers

    @Test func claudeCodeHearsTheAnswer() {
        let input: [String: Any] = ["command": "swift test"]
        // An always is a plain allow: no session rule of Claude Code's own, so every later call still
        // comes to Oby, whose saved rule (and the user's deny rules) answer it.
        let always = StreamJSON.answer(.always, tool: "Bash", input: input)
        #expect(always["behavior"] as? String == "allow" && always["updatedPermissions"] == nil)
        let allow = StreamJSON.answer(.allow, tool: "Bash", input: input)
        #expect(allow["behavior"] as? String == "allow" && allow["updatedPermissions"] == nil && (allow["updatedInput"] as? [String: Any])?["command"] as? String == "swift test")
        let deny = StreamJSON.answer(.deny("Run only RunnerTests"), tool: "Bash", input: input)
        #expect(deny["behavior"] as? String == "deny" && deny["message"] as? String == "Run only RunnerTests")
        let plan = StreamJSON.answer(.allow, tool: "ExitPlanMode", input: ["plan": "1."])
        #expect(((plan["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String) == "default")
        #expect(StreamJSON.claudeMode(.plan) == "plan" && StreamJSON.claudeMode(.bypass) == "default" && StreamJSON.claudeMode(.acceptEdits) == "default")
        #expect(ToolCall.claude("a1", tool: "Write", input: ["file_path": "/tmp/a"]) == ToolCall(request: "a1", tool: "Write", paths: ["/tmp/a"]))
    }

    @Test func codexFollowsTheModes() {
        let worktree = URL(filePath: "/tmp/oby/jobs/abc")
        let command: [String: Any] = ["id": 7, "method": "item/commandExecution/requestApproval",
                                      "params": ["threadId": "t", "turnId": "u", "command": "/bin/zsh -lc 'swift test'"]]
        #expect(CodexRPC.call(command, files: [:]) == ToolCall(request: "7", tool: "Bash", command: "swift test"))
        let change: [String: Any] = ["id": 8, "method": "item/fileChange/requestApproval", "params": ["itemId": "c1"]]
        #expect(CodexRPC.call(change, files: ["c1": ["/tmp/oby/jobs/abc/a.swift"]]) == ToolCall(request: "8", tool: "Edit", paths: ["/tmp/oby/jobs/abc/a.swift"]))
        #expect(CodexRPC.threadStart(worktree: worktree, git: nil, bubblewrap: false)["approvalPolicy"] as? String == "on-request")
        #expect(CodexRPC.threadStart(worktree: worktree, git: nil, bubblewrap: false, mode: .ask)["approvalPolicy"] as? String == "untrusted")
        #expect(CodexRPC.threadStart(worktree: worktree, git: nil, bubblewrap: false, mode: .acceptEdits)["sandbox"] as? String == "workspace-write")
        let plan = CodexRPC.threadStart(worktree: worktree, git: nil, bubblewrap: false, mode: .plan)
        #expect(plan["sandbox"] as? String == "read-only" && plan["approvalPolicy"] as? String == "untrusted")
        #expect(CodexRPC.threadStart(worktree: worktree, git: nil, bubblewrap: true, mode: .plan)["sandbox"] as? String == "danger-full-access")
        let approved = CodexRPC.turnOverrides(mode: .bypass, git: "/tmp/git", bubblewrap: false)
        #expect(approved["approvalPolicy"] as? String == "on-request" && (approved["sandboxPolicy"] as? [String: Any])?["type"] as? String == "workspaceWrite")
    }

    // MARK: The API

    @Test func theAPIAnswersPermissionsAndModes() async throws {
        let agent = Agent()
        let desk = try await running(agent, mode: .ask)
        agent.onEvent(.ask(bash("swift test", "r1")))
        let permission = try #require(desk.job("perm1")?.permission)
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            func call(_ uri: String, _ method: HTTPRequest.Method, _ body: String? = nil) async throws -> (HTTPResponse.Status, Any?) {
                try await client.execute(uri: uri, method: method, headers: owner, body: body.map { ByteBuffer(string: $0) }) { response in
                    (response.status, try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)))
                }
            }
            let (_, listed) = try await call("/v1/jobs/perm1", .get)
            let job = listed as? [String: Any] ?? [:]
            #expect(job["mode"] as? String == "ask")
            let card = job["permission"] as? [String: Any] ?? [:]
            #expect(card["id"] as? String == permission.id && card["title"] as? String == "Run swift test" && card["rule"] as? String == "Bash(swift test:*)")
            #expect(card["always"] as? String == "Yes, and don't ask again for swift test in deskree-inc/oby" && card["detail"] as? String == "swift test")

            #expect(try await call("/v1/jobs/perm1/permission", .post, #"{"id": "\#(permission.id)", "decision": "maybe"}"#).0 == .unprocessableContent)
            #expect(try await call("/v1/jobs/perm1/permission", .post, #"{"id": "p000000", "decision": "allow"}"#).0 == .conflict)
            #expect(try await call("/v1/jobs/nope/permission", .post, #"{"id": "p1", "decision": "allow"}"#).0 == .notFound)
            let (status, denied) = try await call("/v1/jobs/perm1/permission", .post, #"{"id": "\#(permission.id)", "decision": "deny", "message": "run only RunnerTests"}"#)
            #expect(status == .ok && (denied as? [String: Any])?["permission"] is NSNull)
            let answered = await MainActor.run { agent.answers.last?.answer }
            #expect(answered == .deny("run only RunnerTests"))

            #expect(try await call("/v1/jobs/perm1/mode", .post, #"{"mode": "sometimes"}"#).0 == .unprocessableContent)
            let (changed, moded) = try await call("/v1/jobs/perm1/mode", .post, #"{"mode": "acceptEdits"}"#)
            #expect(changed == .ok && (moded as? [String: Any])?["mode"] as? String == "acceptEdits")

            let (_, status1) = try await call("/v1/status", .get)
            #expect(((status1 as? [String: Any])?["permissions"] as? [String: Any])?["mode"] as? String == "bypass")
            #expect(try await call("/v1/settings/permissions", .put, #"{"mode": "never"}"#).0 == .unprocessableContent)
            let (_, set) = try await call("/v1/settings/permissions", .put, #"{"mode": "ask"}"#)
            #expect((set as? [String: Any])?["mode"] as? String == "ask" && desk.defaultMode == .ask)

            _ = await MainActor.run { desk.saveRule("Bash(swift test:*)", repo: "deskree-inc/oby") }
            let (_, rules) = try await call("/v1/permissions/rules", .get)
            let rule = (rules as? [[String: Any]])?.first ?? [:]
            #expect(Set(rule.keys) == ["id", "rule", "repo", "decision", "created"] && rule["decision"] as? String == "allow")
            let (gone, left) = try await call("/v1/permissions/rules/\(rule["id"] as? String ?? "")", .delete)
            #expect(gone == .ok && (left as? [Any])?.isEmpty == true)
            #expect(try await call("/v1/permissions/rules/nope", .delete).0 == .notFound)
        }
    }
}
