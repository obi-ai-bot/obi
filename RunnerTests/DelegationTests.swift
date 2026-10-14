import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing
@testable import ObyEngine
@testable import oby_runner

/// Read-only specialists, their checked plan, persisted memo and automatic follow-up.
@MainActor
struct DelegationTests {
    final class FakeDelegate: DelegateRunner, @unchecked Sendable {
        let result: DelegateResult?
        let error: String?
        let delay: Duration
        private let stoppedState = Mutex(false)
        var stopped: Bool { stoppedState.withLock { $0 } }
        init(_ result: DelegateResult?, error: String? = nil, delay: Duration = .milliseconds(20)) {
            self.result = result; self.error = error; self.delay = delay
        }
        func run(_ delegation: Delegation, in snapshot: URL, onStep: @escaping @Sendable (String) -> Void,
                 onUsage: @escaping @Sendable (AgentEvent) -> Void) async -> (DelegateResult?, String?) {
            onStep("Reading sources")
            let deadline = ContinuousClock.now + delay
            while !stopped && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            return stopped ? (nil, "Stopped by test.") : (result, error)
        }
        func stop() { stoppedState.withLock { $0 = true } }
    }

    let folder: URL
    let desk: Desk
    let brain: ConversationTests.FakeBrain

    init() throws {
        folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max · test@example.com", for: "default")
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        brain = ConversationTests.FakeBrain([ConversationTests.reply("Fine.")])
        desk.makeBrain = { [brain] (_: String?, _: String?, _: Vault) in [brain] }
    }

    @Test func twoResearchersCombineIntoOneAnswer() async throws {
        let first = Self.brief("Read the approval guide")
        let second = Self.brief("Read Oby's approval policy")
        brain.plans = [Self.json(Plan(action: .delegate, reply: "Sending two researchers: approval handling and Oby's policy.", dispatches: [], question: nil, delegations: [first, second])),
                       Self.json(Plan(action: .replyOnly, reply: "Both systems ask before protected actions.", dispatches: [], question: nil,
                                      details: "Claude docs and Oby's runner code agree."))]
        let result = DelegateResult(outcome: .complete, summary: "The evidence supports the claim.",
            findings: [.init(claim: "Approval prompts are explicit", evidence: [.init(link: "https://example.com/approval", quote: "A short evidence quote.")], confidence: "high")],
            openQuestions: [])
        var count = 0
        desk.makeDelegate = { _ in defer { count += 1 }; return FakeDelegate(result) }

        _ = await desk.converse("Compare approval handling. Use specialists.")
        try await until { desk.turns.filter { $0.who == .oby }.count == 2 }
        #expect(desk.turns.last?.text == "Both systems ask before protected actions.")
        #expect(desk.turns.last?.details == "Claude docs and Oby's runner code agree.")
        #expect(desk.jobs.isEmpty)
        #expect(desk.delegations.count == 2)
        #expect(desk.delegations.allSatisfy { $0.status == .complete })
        let quoted = try #require(brain.quoted.last ?? nil)
        #expect(quoted.contains("Delegated work"))
        #expect(quoted.contains("Read the approval guide") && quoted.contains("Read Oby's approval policy"))
    }

    @Test func aPartialOrFailedSpecialistIsMarked() async throws {
        brain.plans = [Self.json(Plan(action: .delegate, reply: "Sending two reviewers.", dispatches: [], question: nil,
                                      delegations: [Self.brief("Review source A"), Self.brief("Review source B")])),
                       Self.json(Plan(action: .replyOnly, reply: "The available evidence is mixed.", dispatches: [], question: nil))]
        let result = DelegateResult(outcome: .complete, summary: "One source checked out.",
            findings: [.init(claim: "One claim holds", evidence: [.init(link: "https://example.com/a", quote: "Source A")], confidence: "medium")], openQuestions: [])
        var index = 0
        desk.makeDelegate = { _ in defer { index += 1 }; return index == 0 ? FakeDelegate(result) : FakeDelegate(nil, error: "Timed out after 10 minutes.") }

        _ = await desk.converse("Review both designs")
        try await until { desk.turns.last?.who == .oby && desk.turns.last?.text.contains("specialists didn't finish") == true }
        #expect(desk.turns.last?.text.hasPrefix("1 of 2 specialists didn't finish") == true)
        #expect(brain.quoted.last??.contains("STATUS: FAILED") == true)
    }

    @Test func delegatePlansAreChecked() {
        let context = BrainContext(accounts: [:], repos: ["deskree-inc/oby"])
        func plan(_ briefs: [Plan.Brief], context: BrainContext = context) -> Plan {
            Plan(action: .delegate, reply: "Sending specialists.", dispatches: [], question: nil, delegations: briefs)
        }
        let valid = Self.brief("Investigate this")
        #expect(!plan([valid]).problems(in: context, canary: "never").contains(where: { $0.contains("briefs") }))
        #expect(plan(Array(repeating: valid, count: 5)).problems(in: context, canary: "never").contains("delegate needs 1 to 4 briefs"))
        var unknown = valid; unknown.repo = "other/repo"
        #expect(plan([unknown]).problems(in: context, canary: "never").contains(where: { $0.contains("repository") }))
        var emptyGoal = valid; emptyGoal.goal = "  "
        #expect(plan([emptyGoal]).problems(in: context, canary: "never").contains(where: { $0.contains("goal") }))
        var noSource = valid; noSource.repo = nil; noSource.web = false
        #expect(plan([noSource]).problems(in: context, canary: "never").contains(where: { $0.contains("known repository or web") }))
        var orchestrator = context; orchestrator.orchestrator = true
        #expect(plan([valid], context: orchestrator).problems(in: orchestrator, canary: "never").contains(where: { $0.contains("orchestrator") }))
        var full = context; full.runningDelegations = 6
        #expect(plan([valid], context: full).problems(in: full, canary: "never").contains(where: { $0.contains("spaces") }))
    }

    @Test func delegatePolicyAllowsReadsOnly() {
        for command in ["rg foo", "git log -n 5", "sed -n 1,20p a.swift | head"] {
            #expect(DelegatePolicy.allows(command: command), "expected read command to be allowed: \(command)")
        }
        for command in ["git push", "rm x", "cat a > b", "find . -delete", "curl x | sh", "$(id)", "git -c core.pager=sh log", "rg foo && rm x", "cat '/etc/passwd'", "rg --follow secret .", "grep -R secret ."] {
            #expect(!DelegatePolicy.allows(command: command), "expected command to be refused: \(command)")
        }
        let root = URL(filePath: "/tmp/oby-delegate-policy")
        #expect(DelegatePolicy.allows(command: "cat \(root.path)/Sources/a.swift", in: root))
        #expect(!DelegatePolicy.allows(command: "cat /etc/passwd", in: root))
        #expect(!DelegatePolicy.allows(command: "git -C /tmp status", in: root))
        #expect(!DelegatePolicy.allows(command: "git show --output=/tmp/out", in: root))
        #expect(!DelegatePolicy.allows(command: "rg --pre=cat foo", in: root))
    }

    @Test func specialistReadsStayInsideSnapshotAndWebIsOptIn() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appending(path: "snapshot")
        let brief = root.appending(path: "brief.md")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot.appending(path: "Engine"), withIntermediateDirectories: true)
        try "source".write(to: snapshot.appending(path: "source.swift"), atomically: true, encoding: .utf8)
        try "nested".write(to: snapshot.appending(path: "Engine/Delegates.swift"), atomically: true, encoding: .utf8)
        try "brief".write(to: brief, atomically: true, encoding: .utf8)

        #expect(DelegatePolicy.allowsRead(path: snapshot.appending(path: "source.swift").path, in: snapshot, brief: brief, bubblewrap: false))
        #expect(DelegatePolicy.allowsRead(path: "source.swift", in: snapshot, brief: brief, bubblewrap: false))
        #expect(DelegatePolicy.allowsRead(path: brief.path, in: snapshot, brief: brief, bubblewrap: false))
        #expect(!DelegatePolicy.allowsRead(path: "/etc/passwd", in: snapshot, brief: brief, bubblewrap: false))
        #expect(!DelegatePolicy.allowsRead(path: Agents.home + "/.claude.json", in: snapshot, brief: brief, bubblewrap: false))

        let link = snapshot.appending(path: "private-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: Agents.home))
        #expect(!DelegatePolicy.allowsRead(path: link.appending(path: ".claude.json").path, in: snapshot, brief: brief, bubblewrap: false))
        #expect(DelegatePolicy.allowsRead(path: DelegateBox.alias(brief).path, in: snapshot, brief: brief, bubblewrap: true))
        #expect(!DelegatePolicy.allowsRead(path: brief.path, in: snapshot, brief: brief, bubblewrap: true))

        // Bare symlink names and nested relatives must resolve inside the snapshot (#417).
        #expect(!DelegatePolicy.allows(command: "cat private-link", in: snapshot))
        #expect(!DelegatePolicy.allows(command: "rg secret private-link", in: snapshot))
        #expect(DelegatePolicy.allows(command: "cat Engine/Delegates.swift", in: snapshot))
        #expect(DelegatePolicy.allows(command: "rg DelegatePolicy Engine/Delegates.swift", in: snapshot))
        // Shell globs must not expand onto a leak symlink; use the Glob tool instead.
        #expect(!DelegatePolicy.allows(command: "cat l*", in: snapshot))
        #expect(!DelegatePolicy.allows(command: "cat {private-link,x}", in: snapshot))

        #expect(DelegatePolicy.allows(tool: "Grep", input: ["pattern": "DelegatePolicy", "path": "Engine"], in: snapshot, brief: brief, web: false, bubblewrap: false))
        #expect(DelegatePolicy.allows(tool: "Glob", input: ["pattern": "**/*.swift"], in: snapshot, brief: brief, web: false, bubblewrap: false))
        #expect(DelegatePolicy.allows(tool: "Grep", input: ["pattern": "secret"], in: snapshot, brief: brief, web: false, bubblewrap: false))
        #expect(!DelegatePolicy.allows(tool: "Grep", input: ["pattern": "secret", "path": "private-link"], in: snapshot, brief: brief, web: false, bubblewrap: false))
        #expect(!DelegatePolicy.allows(tool: "Glob", input: ["pattern": "*", "path": "/etc"], in: snapshot, brief: brief, web: false, bubblewrap: false))
        #expect(!DelegatePolicy.allows(tool: "Glob", input: ["pattern": "/etc/*"], in: snapshot, brief: brief, web: false, bubblewrap: false))
        #expect(!DelegatePolicy.allows(tool: "Grep", input: ["pattern": "secret", "glob": "../**"], in: snapshot, brief: brief, web: false, bubblewrap: false))

        #expect(DelegateBox.claudeTools(web: false) == "Read,Grep,Glob,Bash")
        #expect(DelegateBox.claudeTools(web: true).contains("WebFetch") && DelegateBox.claudeTools(web: true).contains("WebSearch"))
    }

    @Test func runningSpecialistsCountTowardAccountRoom() async throws {
        desk.makeDelegate = { _ in FakeDelegate(DelegateResult(outcome: .complete, summary: "Checked", findings: [], openQuestions: []), delay: .seconds(30)) }
        brain.plans = [Self.json(Plan(action: .delegate, reply: "Sending a researcher.", dispatches: [], question: nil,
                                      delegations: [Self.brief("Check the claim")])),
                       Self.json(Plan(action: .replyOnly, reply: "Done.", dispatches: [], question: nil))]
        #expect(desk.accounts.accounts.first?.running == 0)
        _ = await desk.converse("Check this")
        try await until { desk.delegations.first?.status == .running }
        let item = try #require(desk.delegations.first)
        #expect(item.account == "default")
        #expect(desk.accounts.state("default")?.running == 1)
        #expect(desk.stopDelegation(item.id)?.status == .stopped)
        try await until { desk.accounts.state("default")?.running == 0 }
        #expect(desk.accounts.state("default")?.running == 0)
    }

    @Test func specialistBriefCarriesRoleInstructions() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for (role, phrase) in [(Delegation.Role.researcher, "Answer with evidence."),
                               (.reviewer, "Judge this against the cited rules and list concerns."),
                               (.verifier, "Try to falsify the claim; say holds, concerns or fails.")] {
            let item = Delegation(id: "role-\(role.rawValue)", turn: "turn", role: role, goal: "Check", context: "Context",
                repo: nil, ref: nil, commit: nil, web: true, agent: "codex", account: "test", model: "model", effort: "medium")
            let brief = try DelegateBox.briefFile(item, beside: root.appending(path: "snapshot"))
            let contents = try String(contentsOf: brief, encoding: .utf8)
            #expect(contents.contains(phrase))
            try FileManager.default.removeItem(at: brief)
        }
    }

    @Test func aStoppedSpecialistEndsAndIsMarked() async throws {
        let result = DelegateResult(outcome: .complete, summary: "Done", findings: [], openQuestions: [])
        let fake = FakeDelegate(result, delay: .seconds(30))
        desk.makeDelegate = { _ in fake }
        brain.plans = [Self.json(Plan(action: .delegate, reply: "Sending a researcher.", dispatches: [], question: nil,
                                      delegations: [Self.brief("Check the claim")])),
                       Self.json(Plan(action: .replyOnly, reply: "The claim is supported.", dispatches: [], question: nil))]
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let stream = api.follow()
        var events: [String] = []
        let listener = Task { for await event in stream { events.append(event) } }
        defer { listener.cancel() }

        _ = await desk.converse("Check this. Use a specialist.")
        try await until { desk.delegations.first?.status == .running }
        let id = try #require(desk.delegations.first?.id)
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { client in
            let (listStatus, listBody) = try await client.execute(uri: "/v1/delegations?limit=50", method: .get,
                headers: [.tailscaleUserLogin: "well@example.com"]) { response in (response.status, Data(response.body.readableBytesView)) }
            let listed = (try? JSONSerialization.jsonObject(with: listBody) as? [[String: Any]]) ?? []
            #expect(listStatus == .ok && listed.contains(where: { $0["id"] as? String == id }))
            let (getStatus, getBody) = try await client.execute(uri: "/v1/delegations/\(id)", method: .get,
                headers: [.tailscaleUserLogin: "well@example.com"]) { response in (response.status, Data(response.body.readableBytesView)) }
            #expect(getStatus == .ok && (try? JSONSerialization.jsonObject(with: getBody) as? [String: Any])?["id"] as? String == id)
            let (status, body) = try await client.execute(uri: "/v1/delegations/\(id)/stop", method: .post,
                headers: [.tailscaleUserLogin: "well@example.com"]) { response in (response.status, Data(response.body.readableBytesView)) }
            #expect(status == .ok)
            #expect((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["status"] as? String == "stopped")
        }
        try await app.test(.router) { client in
            let (status, _) = try await client.execute(uri: "/v1/delegations/\(id)/stop", method: .post,
                headers: [.tailscaleUserLogin: "well@example.com"]) { response in (response.status, Data(response.body.readableBytesView)) }
            #expect(status == .conflict)
        }
        try await until { desk.turns.last?.text.contains("specialists didn't finish") == true }
        #expect(desk.turns.last?.text.hasPrefix("1 of 1 specialists didn't finish") == true)
        #expect(brain.quoted.last??.contains("STATUS: STOPPED, NOT COMPLETE") == true)
        try await until { events.contains(where: { $0.contains("event: delegation") && $0.contains("stopped") }) }
        #expect(fake.stopped)
    }

    @Test func followUpCannotDispatchOrDelegate() async throws {
        desk.makeDelegate = { _ in FakeDelegate(DelegateResult(outcome: .complete, summary: "Checked", findings: [], openQuestions: [])) }
        let dispatch = Plan.Dispatch(agent: "auto", account: "auto", repo: "deskree-inc/oby", baseBranch: nil, pr: nil,
            issue: 12, epic: nil, kind: .fix, title: "Login screen", task: "Fix #12", inputs: [], rounds: 1,
            check: nil, complexity: .routine)
        brain.plans = [Self.json(Plan(action: .delegate, reply: "Sending a researcher.", dispatches: [], question: nil,
                                      delegations: [Self.brief("Check the claim")])),
                       Self.json(Plan(action: .dispatch, reply: "I left the proposed fix in your inbox.", dispatches: [dispatch], question: nil))]
        _ = await desk.converse("Check the fix and suggest work if needed")
        try await until { desk.turns.last?.text == "I left the proposed fix in your inbox." }
        #expect(desk.jobs.isEmpty)
        #expect(desk.inbox.contains(where: { $0.kind == .start }))

        var context = BrainContext(accounts: [:], repos: ["deskree-inc/oby"])
        context.followUp = true
        let base = Plan(action: .delegate, reply: "", dispatches: [], question: nil, delegations: [Self.brief("Again")])
        #expect(base.problems(in: context, canary: "never").contains(where: { $0.contains("follow-up") }))
        let stop = Plan(action: .stopAgent, reply: "", dispatches: [], question: nil)
        #expect(stop.problems(in: context, canary: "never").contains(where: { $0.contains("not allowed") }))
    }

    @Test func aSpecialistGetsNoGitHubLoginAndAReadOnlySnapshot() async throws {
        guard Agents.bubblewrap else { return }
        let root = Workspace.root.appending(path: "delegations/test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = try DelegateBox.environment(home: nil, variable: "CODEX_HOME")
        #expect(env["GH_TOKEN"] == nil && env["GITHUB_TOKEN"] == nil)
        let touch = Agents.sandboxed(["touch", root.appending(path: "must-not-exist").path], in: nil, own: nil,
                                     reading: [], chdir: root.path, worktreeReadOnly: true)
        let touched = try await Shell.run(touch, timeout: 10)
        #expect(touched.status != 0)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "must-not-exist").path))
        let gh = Agents.sandboxed(["gh", "auth", "status"], in: nil, own: nil, reading: [], chdir: root.path, worktreeReadOnly: true)
        let status = try await Shell.run(gh, env: env, timeout: 10)
        #expect(status.status != 0)
    }

    @Test func codexDelegateDeclinesFileChanges() {
        #expect(CodexDelegate.approvalDecision(method: "item/fileChange/requestApproval") == "decline")
        #expect(CodexDelegate.approvalDecision(method: "item/commandExecution/requestApproval", command: "git status") == "accept")
        #expect(CodexDelegate.approvalDecision(method: "item/commandExecution/requestApproval", command: "git push") == "decline")
    }

    @Test func specialistsAreNotJobs() async throws {
        desk.makeDelegate = { _ in FakeDelegate(DelegateResult(outcome: .complete, summary: "Checked", findings: [], openQuestions: []), delay: .seconds(30)) }
        brain.plans = [Self.json(Plan(action: .delegate, reply: "Sending a researcher.", dispatches: [], question: nil,
                                      delegations: [Self.brief("Check the claim")])), Self.json(Plan(action: .replyOnly, reply: "Done.", dispatches: [], question: nil))]
        _ = await desk.converse("Check this")
        try await until { desk.delegations.first?.status == .running }
        let briefing = desk.briefing(turns: []).text
        #expect(briefing.contains("Working now: No agent is working right now."))
        #expect(briefing.contains("Specialists working: 1") && briefing.contains("Check the claim"))
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/jobs", method: .get, headers: [.tailscaleUserLogin: "well@example.com"]) { response in
                let rows = (try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [[String: Any]]) ?? []
                #expect(response.status == .ok && rows.isEmpty)
            }
        }
        let id = try #require(desk.delegations.first?.id)
        #expect(desk.stopDelegation(id)?.status == .stopped)
        try await until { desk.turns.last?.text.contains("Done.") == true }
        #expect(desk.jobs.isEmpty)
    }

    private static func brief(_ goal: String) -> Plan.Brief {
        Plan.Brief(role: .researcher, goal: goal, context: "Read only. Cite each finding.", repo: nil, ref: nil, web: true)
    }

    private static func json(_ plan: Plan) -> String { String(decoding: (try? JSONEncoder().encode(plan)) ?? Data(), as: UTF8.self) }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
