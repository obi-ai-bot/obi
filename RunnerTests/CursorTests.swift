import Foundation
import Testing
@testable import ObyEngine

/// Cursor on ACP (#406): its launch, its config, and a job running against a fake ACP agent (a
/// Python script that speaks the protocol and logs every line it receives).
@MainActor
struct CursorTests {
    let folder: URL
    let worktree: URL
    let log: URL

    init() throws {
        folder = try temporaryFolder()
        worktree = folder.appending(path: "worktree")
        try FileManager.default.createDirectory(at: worktree.appending(path: ".oby"), withIntermediateDirectories: true)
        log = folder.appending(path: "received.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
    }

    static let fakeAgent = #"""
    import json, os, sys, time
    log = open(os.environ["FAKE_LOG"], "a", buffering=1)
    scenario = os.environ.get("FAKE_SCENARIO", "ask")
    hold = os.environ.get("FAKE_IGNORE_EOF") == "1"
    ALL = [{"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
           {"optionId": "allow-always", "name": "Always allow", "kind": "allow_always"},
           {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"},
           {"optionId": "reject-always", "name": "Always reject", "kind": "reject_always"}]
    NO_ONCE = [{"optionId": "allow-always", "name": "Always", "kind": "allow_always"},
               {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"}]
    prompt = None
    prompts = 0

    def send(message):
        message["jsonrpc"] = "2.0"
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()

    def update(body):
        send({"method": "session/update", "params": {"sessionId": "fake-session", "update": body}})

    def say(text):
        update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})

    def command(call, text, options, rid):
        update({"sessionUpdate": "tool_call", "toolCallId": call, "title": text, "kind": "execute", "status": "pending",
                "rawInput": {"command": text}})
        send({"id": rid, "method": "session/request_permission",
              "params": {"sessionId": "fake-session", "toolCall": {"toolCallId": call}, "options": options}})

    def finish(reason="end_turn"):
        global prompt
        if prompt is not None:
            send({"id": prompt, "result": {"stopReason": reason}})
            prompt = None

    while True:
        line = sys.stdin.readline()
        if not line:
            if hold:
                time.sleep(60)
                continue
            break
        log.write(line)
        m = json.loads(line)
        method, mid = m.get("method"), m.get("id")
        if method == "initialize":
            send({"id": mid, "result": {"protocolVersion": 1, "authMethods": [{"id": "cursor_login", "name": "Cursor login"}],
                  "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": True}, "mcpCapabilities": {"http": True}}}})
        elif method == "session/new" and scenario == "signedout":
            send({"id": mid, "error": {"code": -32000, "message": "Authentication required"}})
        elif method == "session/new":
            send({"id": mid, "result": {"sessionId": "fake-session",
                  "modes": {"currentModeId": "agent", "availableModes": [{"id": "agent", "name": "Agent"}, {"id": "plan", "name": "Plan"}]},
                  "configOptions": [{"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "default[]",
                                     "options": [{"value": "default[]", "name": "Auto"},
                                                 {"value": "gpt-5.6-luna[context=272k,reasoning=medium,fast=false]", "name": "GPT-5.6 Luna"},
                                                 {"value": "gpt-5[]", "name": "GPT-5"}]}]}})
        elif method == "session/load":
            send({"id": mid, "result": {"modes": {"currentModeId": "agent", "availableModes": [{"id": "agent", "name": "Agent"}, {"id": "plan", "name": "Plan"}]}}})
        elif method in ("session/set_mode", "session/set_config_option"):
            send({"id": mid, "result": {}})
        elif method == "session/cancel":
            finish("cancelled")
        elif method == "session/prompt":
            prompt = mid
            prompts += 1
            if scenario == "limit":
                send({"id": mid, "error": {"code": -32603, "message": "You've hit your usage limit. Try again later."}})
                prompt = None
            elif scenario == "plan" and prompts == 1:
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Planning."}})
                send({"id": 200, "method": "cursor/create_plan",
                      "params": {"toolCallId": "plan-1", "plan": "1. Add the view", "todos": []}})
            elif scenario == "plan":
                say("Went ahead.")
                finish()
            elif scenario == "question":
                send({"id": 300, "method": "cursor/ask_question", "params": {"toolCallId": "q", "questions": []}})
            elif scenario == "two":
                command("c1", "swift build", ALL, 100)
                command("c2", "swift test", ALL, 101)
            elif scenario == "push":
                command("c1", "git push origin main", ALL, 100)
            elif scenario == "noonce":
                command("c1", "swift test", NO_ONCE, 100)
            elif scenario == "stopreason":
                say("Cut short.")
                finish("refusal")
            else:
                command("c1", "swift test", ALL, 100)
        elif mid is not None and method is None:
            # An answer to one of the agent's requests.
            if scenario in ("ask", "push", "noonce", "question") or (scenario == "two" and mid == 101):
                say("Built it.")
                finish()
            elif scenario == "plan":
                say("Plan accepted.")
                finish()
    """#

    /// A fake agent as a tool: the script and the scenario it plays.
    func fake(_ scenario: String = "ask", ignoreEOF: Bool = false) throws -> ACPTool {
        let script = folder.appending(path: "fake-acp.py")
        try Self.fakeAgent.write(to: script, atomically: true, encoding: .utf8)
        var tool = ACPTool(id: "cursor", name: "Cursor", arguments: ["python3", script.path])
        tool.repositoryAllowlist = { CursorConfig.repositoryAllowlist(worktree: $0) }
        tool.environment = ["FAKE_LOG": log.path, "FAKE_SCENARIO": scenario, "FAKE_IGNORE_EOF": ignoreEOF ? "1" : nil]
        return tool
    }

    func agent(_ scenario: String = "ask", ignoreEOF: Bool = false, mode: PermissionMode = .ask) throws -> (ACPAgent, Events) {
        let agent = ACPAgent(tool: try fake(scenario, ignoreEOF: ignoreEOF), worktree: worktree)
        agent.mode = mode
        agent.account = "Work"
        agent.approvals = UserDefaults(suiteName: "oby-test-\(UUID().uuidString)") ?? .standard
        let events = Events()
        try agent.start(prompt: "Build the empty state") { events.all.append($0) }
        return (agent, events)
    }

    final class Events {
        var all: [AgentEvent] = []
        var asks: [ToolCall] { all.compactMap { if case .ask(let call) = $0 { call } else { nil } } }
        var summary: String? { all.compactMap { if case .turnEnded(let summary, _) = $0 { summary } else { nil } }.last }
    }

    /// Waits for `done`, looking every 10 ms, up to `seconds` worth of looks. Looks are counted,
    /// not the clock (as the other suites' `until`): the agent's messages are handled on the main
    /// actor, which the whole suite's other tests hold for seconds at a time.
    func until(_ seconds: Double = 30, _ done: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 100) where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// The JSON lines the fake received.
    func received() -> [[String: Any]] {
        (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        } ?? []
    }

    func answers() -> [Int: [String: Any]] {
        var found: [Int: [String: Any]] = [:]
        for line in received() where line["method"] == nil {
            if let id = line["id"] as? Int, let result = line["result"] as? [String: Any] { found[id] = result }
        }
        return found
    }

    func outcome(_ result: [String: Any]?) -> [String: String] {
        (result?["outcome"] as? [String: String]) ?? [:]
    }

    // MARK: Launch

    @Test func launch() throws {
        let home = URL(filePath: "/tmp/oby/accounts/c1")
        let tool = ACPTool.cursor(worktree: worktree, home: home, model: "gpt-5", bubblewrap: false, modelOption: false)
        let argv = tool.arguments
        #expect(argv.suffix(5) == ["--sandbox", "disabled", "--model", "gpt-5", "acp"], "\(argv)")
        #expect(argv.contains("cursor-agent") && !argv.contains("agent"))
        let env = try ACPServer.environment(for: tool, worktree: nil, base: ["PATH": "/usr/bin", "CURSOR_API_KEY": "key", "CURSOR_AUTH_TOKEN": "token"])
        #expect(env["CURSOR_CONFIG_DIR"] == "/tmp/oby/accounts/c1")
        // The login is a file under XDG_CONFIG_HOME: the account's own folders hold it (the probe's isolation).
        #expect(env["XDG_CONFIG_HOME"] == "/tmp/oby/accounts/c1/.config" && env["HOME"] == "/tmp/oby/accounts/c1")
        #expect(env["CURSOR_API_KEY"] == nil && env["CURSOR_AUTH_TOKEN"] == nil)
        // Cursor picks its own model for auto, and Oby never says so.
        let auto = ACPTool.cursor(worktree: worktree, home: home, model: "auto", bubblewrap: false, modelOption: false)
        #expect(!auto.arguments.contains("--model"))
        #expect(!ACPTool.cursor(worktree: worktree, home: home, model: "", bubblewrap: false, modelOption: false).arguments.contains("--model"))
        // Cursor offers its model as an option (the probe): `--model` is dropped, and the option sets it.
        #expect(CursorFacts.modelOption)
        let option = ACPTool.cursor(worktree: worktree, home: home, model: "gpt-5", bubblewrap: false)
        #expect(!option.arguments.contains("--model") && option.model == "gpt-5")
    }

    @Test func onBubblewrapTheCLIFolderIsAnOverlayAndTheHomeIsBound() {
        let home = URL(filePath: "/tmp/oby/accounts/c1")
        let folder = "\(Agents.home)/.local/share/cursor-agent"
        let tool = ACPTool.cursor(worktree: worktree, home: home, model: "auto", bubblewrap: true, exists: { $0 == folder })
        let argv = tool.arguments
        let at = { (run: [String]) in argv.indices.first { argv[$0...].starts(with: run) } }
        #expect(at(["--overlay-src", folder, "--tmp-overlay", folder]) != nil, "\(argv)")
        #expect(at(["--bind", home.path, home.path]) != nil)
        #expect(argv.first == "bwrap" && argv.suffix(3) == ["--sandbox", "disabled", "acp"])
        #expect(Agents.tools.contains(".local/share/cursor-agent"))
        // Never the user's own Cursor home.
        #expect(!argv.contains { $0.hasSuffix("/.cursor") || $0.hasSuffix("/.config/cursor") })
    }

    @Test func aJobWithoutAnOwnHomeDoesNotStart() throws {
        let tool = ACPTool.cursor(worktree: worktree, home: nil, model: "auto", bubblewrap: false)
        #expect(tool.cannotStart != nil && tool.prepare == nil)
        let agent = ACPAgent(tool: tool, worktree: worktree)
        #expect(throws: (any Error).self) { try agent.start(prompt: "x") { _ in } }
    }

    @Test func cliConfigRewritten() throws {
        let home = folder.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let before = #"{"version":1,"authInfo":{"email":"name@example.com"},"approvalMode":"allowlist","permissions":{"allow":["Shell(ls)","Read(**)"],"deny":["Shell(rm)"]},"model":{"modelId":"auto"}}"#
        try before.write(to: home.appending(path: "cli-config.json"), atomically: true, encoding: .utf8)
        try CursorConfig.rewrite(home: home)
        let config = object(try Data(contentsOf: home.appending(path: "cli-config.json")))
        let permissions = config["permissions"] as? [String: [String]]
        #expect(permissions?["allow"] == [] && permissions?["deny"] == [])
        #expect(config["approvalMode"] as? String == "allowlist")
        // What the CLI manages stays.
        #expect(config["version"] as? Int == 1 && (config["authInfo"] as? [String: String])?["email"] == "name@example.com")
        #expect((config["model"] as? [String: String])?["modelId"] == "auto")
        // Written fresh when there's none yet.
        let fresh = folder.appending(path: "fresh")
        try CursorConfig.rewrite(home: fresh)
        #expect(object(try Data(contentsOf: fresh.appending(path: "cli-config.json")))["approvalMode"] as? String == "allowlist")
    }

    @Test func theRepositorysAllowlistIsRead() throws {
        #expect(CursorConfig.repositoryAllowlist(worktree: worktree).isEmpty)
        try FileManager.default.createDirectory(at: worktree.appending(path: ".cursor"), withIntermediateDirectories: true)
        try #"{"permissions":{"allow":["Shell(git status)","Read(**)"],"deny":[]}}"#
            .write(to: worktree.appending(path: ".cursor/cli.json"), atomically: true, encoding: .utf8)
        #expect(CursorConfig.repositoryAllowlist(worktree: worktree) == ["Shell(git status)", "Read(**)"])
    }

    @Test func deskMakesAnACPAgentForCursor() {
        var cursor = job
        cursor.agent = "cursor"
        cursor.model = "gpt-5"
        let made = Desk.agent(for: cursor, home: URL(filePath: "/tmp/oby/accounts/c1"), resume: nil)
        #expect(made is ACPAgent)
        #expect(Job.agentNames["cursor"] == "Cursor" && cursor.agentName == "Cursor")
    }

    // MARK: Running against the fake agent

    @Test func aTurnRunsAsksAndEnds() async throws {
        let (agent, events) = try agent("ask")
        defer { agent.kill() }
        try await until { !events.asks.isEmpty }
        let call = try #require(events.asks.first)
        #expect(call == ToolCall(request: "100", tool: "Bash", command: "swift test"))
        #expect(events.all.contains(.session("fake-session")) && events.all.contains(.step("Running swift test")))
        agent.answer(call, .allow)
        try await until { events.summary != nil }
        #expect(events.summary == "Built it.")
        #expect(outcome(answers()[100]) == ["outcome": "selected", "optionId": "allow-once"])
        // The tool saw the session, the worktree and no capability.
        let new = try #require(received().first { $0["method"] as? String == "session/new" })
        #expect((new["params"] as? [String: Any])?["cwd"] as? String == worktree.path)
        let initialize = try #require(received().first { $0["method"] as? String == "initialize" })
        #expect(((initialize["params"] as? [String: Any])?["clientCapabilities"] as? [String: Any])?.isEmpty == true)
    }

    @Test func neverSendsAllowAlways() async throws {
        let (agent, events) = try agent("noonce")
        defer { agent.kill() }
        try await until { !events.asks.isEmpty }
        agent.answer(try #require(events.asks.first), .always)
        try await until { answers()[100] != nil }
        #expect(outcome(answers()[100]) == ["outcome": "selected", "optionId": "reject-once"])
        try await until { events.summary != nil }
        // What Oby couldn't allow is said at the next prompt.
        agent.send("Go on")
        try await until { received().filter { $0["method"] as? String == "session/prompt" }.count == 2 }
        let second = received().filter { $0["method"] as? String == "session/prompt" }.last
        let text = (((second?["params"] as? [String: Any])?["prompt"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("Oby declined swift test: Oby can't allow this once") && text.hasSuffix("Go on"))
    }

    @Test func pushIsRejectedWithoutAsking() async throws {
        let (agent, events) = try agent("push", mode: .bypass)
        defer { agent.kill() }
        try await until { answers()[100] != nil }
        #expect(outcome(answers()[100]) == ["outcome": "selected", "optionId": "reject-once"])
        #expect(events.asks.isEmpty)
        #expect(events.all.contains { if case .permission(let denied) = $0 { denied?.contains("Oby publishes the job's branch itself") == true } else { false } })
    }

    @Test func cancelAnswersPending() async throws {
        let (agent, events) = try agent("two", ignoreEOF: true)
        defer { agent.kill() }
        try await until { events.asks.count == 2 }
        #expect(events.asks.map(\.request).sorted() == ["100", "101"])
        agent.stop()
        try await until(10) { answers().count == 2 && received().contains { $0["method"] as? String == "session/cancel" } }
        #expect(outcome(answers()[100]) == ["outcome": "cancelled"] && outcome(answers()[101]) == ["outcome": "cancelled"])
        let cancel = try #require(received().first { $0["method"] as? String == "session/cancel" })
        #expect((cancel["params"] as? [String: Any])?["sessionId"] as? String == "fake-session")
        // Within Stop's 2 seconds the process is gone, though it ignores its stdin closing.
        await agent.ended()
    }

    @Test func createPlanGoesToTheCardAndApprovalGoesAhead() async throws {
        let (agent, events) = try agent("plan", mode: .plan)
        defer { agent.kill() }
        try await until { !events.asks.isEmpty }
        let call = try #require(events.asks.first)
        #expect(call == ToolCall(request: "200", tool: "ExitPlanMode", plan: "1. Add the view"))
        // Desk approves in a mode: the agent's mode follows, the plan is accepted, and the turn goes on.
        agent.setMode(.acceptEdits)
        agent.answer(call, .allow)
        try await until { events.summary != nil }
        #expect(outcome(answers()[200]) == ["outcome": "accepted"])
        #expect(events.summary == "Went ahead.")
        let modes = received().filter { $0["method"] as? String == "session/set_mode" }.compactMap { ($0["params"] as? [String: Any])?["modeId"] as? String }
        #expect(modes == ["plan", "agent"])
        // One round: the go-ahead was a prompt of its own, and only its end ended the turn.
        #expect(received().filter { $0["method"] as? String == "session/prompt" }.count == 2)
        #expect(events.all.filter { if case .turnEnded = $0 { true } else { false } }.count == 1)
    }

    /// A resumed session's modes come with `session/load`: the job's mode is applied from them.
    @Test func aResumedSessionTakesTheJobsMode() async throws {
        let agent = ACPAgent(tool: try fake("ask"), worktree: worktree, resume: "old-session")
        agent.mode = .plan
        agent.approvals = UserDefaults(suiteName: "oby-test-\(UUID().uuidString)") ?? .standard
        let events = Events()
        try agent.start(prompt: "Go on") { events.all.append($0) }
        defer { agent.kill() }
        try await until { events.all.contains(.session("old-session")) && received().contains { $0["method"] as? String == "session/prompt" } }
        let load = try #require(received().first { $0["method"] as? String == "session/load" })
        #expect((load["params"] as? [String: Any])?["sessionId"] as? String == "old-session")
        let modes = received().filter { $0["method"] as? String == "session/set_mode" }.compactMap { ($0["params"] as? [String: Any])?["modeId"] as? String }
        #expect(modes == ["plan"])
        // The prompt goes to the picked-up session.
        let prompt = try #require(received().first { $0["method"] as? String == "session/prompt" })
        #expect((prompt["params"] as? [String: Any])?["sessionId"] as? String == "old-session")
    }

    /// Cursor's model is an option of the session (values carry parameters), and its accounts' own
    /// MCP servers go along with the broker.
    @Test func theModelAndTheMCPServersGoWithTheSession() async throws {
        var tool = try fake("ask")
        tool.model = "gpt-5.6-luna"
        let mcp = folder.appending(path: "mcp.json")
        try #"{"mcpServers":{"tetrix":{"url":"https://tetrix.example/mcp","headers":{"Authorization":"x"}},"graph":{"url":"https://graph.example/mcp"},"local":{"command":"npx","args":["-y","thing"],"env":{"K":"v"}}}}"#
            .write(to: mcp, atomically: true, encoding: .utf8)
        tool.mcpFile = mcp
        let agent = ACPAgent(tool: tool, worktree: worktree)
        agent.mode = .ask
        agent.mcp = AgentMCP(url: "http://127.0.0.1:8787/v1/agent/mcp/abc", token: "job-token")
        agent.approvals = UserDefaults(suiteName: "oby-test-\(UUID().uuidString)") ?? .standard
        try agent.start(prompt: "Build it") { _ in }
        defer { agent.kill() }
        try await until { received().contains { $0["method"] as? String == "session/prompt" } }
        let set = try #require(received().first { $0["method"] as? String == "session/set_config_option" })
        let params = set["params"] as? [String: Any]
        #expect(params?["configId"] as? String == "model")
        #expect(params?["value"] as? String == "gpt-5.6-luna[context=272k,reasoning=medium,fast=false]")
        let new = try #require(received().first { $0["method"] as? String == "session/new" })
        let servers = (new["params"] as? [String: Any])?["mcpServers"] as? [[String: Any]] ?? []
        // The broker with the job's token, and the account's server that needs no header or env value.
        #expect(servers.map { $0["name"] as? String } == ["oby", "graph"])
        #expect((servers.first?["headers"] as? [[String: String]])?.first?["value"] == "Bearer job-token")
        #expect(servers.last?["type"] as? String == "http" && servers.last?["url"] as? String == "https://graph.example/mcp")
    }

    @Test func aRejectedPlanSaysWhy() async throws {
        let (agent, events) = try agent("plan", mode: .plan)
        defer { agent.kill() }
        try await until { !events.asks.isEmpty }
        agent.answer(try #require(events.asks.first), .deny("Smaller steps."))
        try await until { answers()[200] != nil }
        #expect(outcome(answers()[200]) == ["outcome": "rejected", "reason": "Smaller steps."])
    }

    @Test func askQuestionSkipped() async throws {
        let (agent, events) = try agent("question")
        defer { agent.kill() }
        try await until { events.summary != nil }
        #expect(outcome(answers()[300])["outcome"] == "skipped")
        #expect(events.asks.isEmpty)
    }

    @Test func stopReasonsReachDesk() async throws {
        let (refusal, refused) = try agent("stopreason")
        defer { refusal.kill() }
        try await until { refused.summary != nil }
        #expect(refused.all.contains(.turnEnded(summary: "Cut short.", failed: true)))
    }

    @Test func aLimitErrorMovesTheJobOn() async throws {
        let (agent, events) = try agent("limit")
        defer { agent.kill() }
        try await until { events.all.contains(.limit(resets: nil)) }
        #expect(events.all.contains(.limit(resets: nil)))
    }

    @Test func aSignedOutAccountFailsTheJobSayingSo() async throws {
        let (agent, events) = try agent("signedout")
        defer { agent.kill() }
        try await until { events.all.contains { if case .finished = $0 { true } else { false } } }
        #expect(events.all.contains(.finished(summary: "Cursor · Work is signed out: sign in from Settings › Accounts.", failed: true)))
    }

    @Test func aRepositoryAllowlistAsksOnceBeforeCursorStarts() async throws {
        try FileManager.default.createDirectory(at: worktree.appending(path: ".cursor"), withIntermediateDirectories: true)
        try #"{"permissions":{"allow":["Shell(git status)"]}}"#.write(to: worktree.appending(path: ".cursor/cli.json"), atomically: true, encoding: .utf8)
        let suite = UserDefaults(suiteName: "oby-test-\(UUID().uuidString)") ?? .standard
        func make() throws -> (ACPAgent, Events) {
            let agent = ACPAgent(tool: try fake("ask"), worktree: worktree)
            agent.repo = "deskree-inc/oby"
            agent.approvals = suite
            let events = Events()
            try agent.start(prompt: "Build it") { events.all.append($0) }
            return (agent, events)
        }
        let (first, firstEvents) = try make()
        defer { first.kill() }
        // Asked before anything started.
        let call = try #require(firstEvents.asks.first)
        #expect(call.tool == ACPAgent.allowlistTool && call.command == "Shell(git status)")
        #expect(received().isEmpty)
        let card = PermissionPolicy.permission(for: call, id: "p1", repo: "deskree-inc/oby", worktree: worktree)
        #expect(card.rule == nil && card.title.contains("allowlist") && card.detail == "Shell(git status)")
        first.answer(call, .allow)
        try await until { !received().isEmpty }
        #expect(received().first?["method"] as? String == "initialize")

        // The same repository and list: no question.
        let (second, secondEvents) = try make()
        defer { second.kill() }
        #expect(secondEvents.asks.isEmpty)
    }

    @Test func aRefusedAllowlistFailsTheJob() async throws {
        try FileManager.default.createDirectory(at: worktree.appending(path: ".cursor"), withIntermediateDirectories: true)
        try #"{"permissions":{"allow":["Shell(git status)"]}}"#.write(to: worktree.appending(path: ".cursor/cli.json"), atomically: true, encoding: .utf8)
        let (agent, events) = try agent("ask")
        let call = try #require(events.asks.first)
        agent.answer(call, .deny("no"))
        guard case .finished(let summary, true)? = events.all.last else { Issue.record("it didn't fail: \(events.all)"); return }
        #expect(summary.contains("allowlist"))
        #expect(received().isEmpty)
    }

    // MARK: Through the desk

    func cursorJob(_ id: String, mode: PermissionMode) -> Job {
        var cursor = job
        cursor.id = id
        cursor.kind = .fix
        cursor.pr = nil
        cursor.base = "dev"
        cursor.branch = "oby/fix-406"
        cursor.title = "Cursor empty state"
        cursor.agent = "cursor"
        cursor.mode = mode
        return cursor
    }

    @Test(.timeLimit(.minutes(1)))
    func jobRunsAndStops() async throws {
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let tool = try fake("ask", ignoreEOF: true)
        let agent = ACPAgent(tool: tool, worktree: worktree)
        agent.approvals = UserDefaults(suiteName: "oby-test-\(UUID().uuidString)") ?? .standard
        desk.makeAgent = { _, _, _ in agent }
        desk.prepare = { $0 }
        desk.countCommits = { _, _ in 0 }
        desk.dispatch(cursorJob("cursor1", mode: .ask))
        try await until { desk.job("cursor1")?.permission != nil }
        let waiting = try #require(desk.job("cursor1")?.permission)
        #expect(desk.job("cursor1")?.status == .running)
        #expect(waiting.tool == "Bash" && waiting.detail == "swift test")
        #expect(desk.job("cursor1")?.agentName == "Cursor")

        let started = Date.now
        desk.stop("cursor1")
        await agent.ended()
        // Stop's promise: the grace and the kill add up to under 2 seconds. The measured time has
        // room for a runner busy with other jobs (python itself takes its time to start there).
        #expect(Halt.grace + Halt.stopping < 2)
        #expect(Date.now.timeIntervalSince(started) < 5)
        #expect(desk.job("cursor1")?.status == .stopped)
    }

    @Test(.timeLimit(.minutes(1)))
    func bypassModeRunsToTheEndWithOnlyPolicyInTheWay() async throws {
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let agent = ACPAgent(tool: try fake("ask"), worktree: worktree)
        desk.makeAgent = { _, _, _ in agent }
        desk.prepare = { $0 }
        desk.countCommits = { _, _ in 0 }
        desk.dispatch(cursorJob("cursor2", mode: .bypass))
        try await until(20) { desk.job("cursor2")?.isActive == false }
        let ended = try #require(desk.job("cursor2"))
        #expect(outcome(answers()[100]) == ["outcome": "selected", "optionId": "allow-once"])
        #expect(ended.summaries?.last == "Built it." || ended.summary.contains("Built it."), "\(ended.status) \(ended.summary)")
    }
}
