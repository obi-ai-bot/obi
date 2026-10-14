import Foundation
import Testing
@testable import ObyEngine

/// The ACP wire format (#406). The fixtures are written from the protocol's schema
/// (agentclientprotocol.com) and Cursor's ACP page (cursor.com/docs/cli/acp): a signed-in
/// `cursor-agent acp` wasn't reachable when they were written, so none is a recording yet.
/// docs/cursor.md says which facts the probe has still to confirm.
struct ACPTests {
    let worktree = URL(filePath: "/tmp/oby/jobs/abc")

    func message(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    static let allFour = #"[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"allow-always","name":"Always allow","kind":"allow_always"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"},{"optionId":"reject-always","name":"Always reject","kind":"reject_always"}]"#

    func request(_ id: Int, call: String, options: String = allFour) -> [String: Any] {
        message(#"{"jsonrpc":"2.0","id":\#(id),"method":"session/request_permission","params":{"sessionId":"s1","toolCall":\#(call),"options":\#(options)}}"#)
    }

    func selected(_ reply: ACPRPC.Reply) -> String? {
        (reply.result["outcome"] as? [String: Any])?["optionId"] as? String
    }

    // MARK: Start

    @Test func initializeAdvertisesNothingTheToolCouldUse() {
        let params = ACPRPC.initialize(version: "1.2")
        #expect(params["protocolVersion"] as? Int == 1)
        #expect((params["clientCapabilities"] as? [String: Any])?.isEmpty == true)
        #expect((params["clientInfo"] as? [String: Any])?["name"] as? String == "oby")
    }

    @Test func sessionNewCarriesTheWorktreeAndTheBroker() {
        let broker = ACPRPC.broker(AgentMCP(url: "http://127.0.0.1:8787/mcp/abc", token: "tok"))
        let params = ACPRPC.sessionNew(cwd: worktree.path, mcp: [broker])
        #expect(params["cwd"] as? String == "/tmp/oby/jobs/abc")
        let server = (params["mcpServers"] as? [[String: Any]])?.first
        #expect(server?["type"] as? String == "http" && server?["name"] as? String == "oby")
        let header = (server?["headers"] as? [[String: String]])?.first
        #expect(header == ["name": "Authorization", "value": "Bearer tok"])
    }

    @Test func sessionAnswerNamesModesAndOptions() {
        let result = message(#"{"sessionId":"sess-1","modes":{"currentModeId":"agent","availableModes":[{"id":"agent","name":"Agent"},{"id":"plan","name":"Plan"},{"id":"ask","name":"Ask"}]},"configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"auto","options":[{"value":"auto","name":"Auto"},{"value":"gpt-5","name":"GPT-5"}]}]}"#)
        let session = ACPRPC.session(result)
        #expect(session.id == "sess-1" && session.modes == ["agent", "plan", "ask"] && session.currentMode == "agent")
        #expect(session.modelOption == "model" && session.models == ["auto", "gpt-5"] && session.model == "auto")
        #expect(session.modeOption == nil)
        let both = ACPRPC.session(message(#"{"sessionId":"s","configOptions":[{"id":"mode","category":"mode","currentValue":"plan","options":[{"value":"agent"},{"value":"plan"}]}]}"#))
        #expect(both.modeOption == "mode" && both.modes == ["agent", "plan"] && both.currentMode == "plan")
    }

    @Test func capabilitiesAreOptIn() {
        let caps = ACPRPC.capabilities(message(#"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true},"mcpCapabilities":{"http":true,"sse":false}},"authMethods":[{"id":"cursor_login","name":"Cursor login"}]}"#))
        #expect(caps == ACPRPC.Capabilities(loadSession: true, image: true, http: true))
        #expect(ACPRPC.capabilities([:]) == ACPRPC.Capabilities())
    }

    @Test func accountServersKeepOnlyWhatStartsThem() {
        let config = #"{"mcpServers":{"tetrix":{"url":"https://t.example/mcp","type":"http"},"authed":{"url":"https://a.example","headers":{"Authorization":"x"}},"sse":{"url":"https://s.example","type":"sse"},"local":{"command":"npx","args":["-y","x"],"cwd":"/secret"},"keyed":{"command":"x","env":{"K":"v"}}}}"#
        let servers = ACPRPC.accountServers(Data(config.utf8), http: true)
        #expect(servers.map { $0["name"] as? String } == ["local", "tetrix"])
        #expect(servers[0]["command"] as? String == "npx" && servers[0]["args"] as? [String] == ["-y", "x"] && servers[0]["cwd"] == nil)
        #expect(servers[1]["type"] as? String == "http" && (servers[1]["headers"] as? [Any])?.isEmpty == true)
        // A tool without HTTP MCP gets the stdio ones only; no file, none.
        #expect(ACPRPC.accountServers(Data(config.utf8), http: false).map { $0["name"] as? String } == ["local"])
        #expect(ACPRPC.accountServers(nil, http: true).isEmpty)
    }

    @Test func modelValueFindsTheVariantWithItsParameters() {
        let values = ["default[]", "gpt-5.6-luna[context=272k,reasoning=medium,fast=false]", "gpt-5.6-luna[context=1m,reasoning=high,fast=false]", "gpt-5[]"]
        #expect(ACPRPC.modelValue("gpt-5.6-luna", in: values, current: nil) == values[1])
        #expect(ACPRPC.modelValue("gpt-5.6-luna", in: values, current: values[2]) == values[2])
        #expect(ACPRPC.modelValue("gpt-5", in: values, current: "default[]") == "gpt-5[]")
        #expect(ACPRPC.modelValue("gpt-5[]", in: values, current: nil) == "gpt-5[]")
        // Auto lets Cursor pick, and a model it doesn't offer is none.
        #expect(ACPRPC.modelValue("auto", in: values, current: nil) == nil && ACPRPC.modelValue("claude-x", in: values, current: nil) == nil)
    }

    // MARK: Permissions

    @Test func permissionMapsToBash() {
        var tools: [String: ACPToolCall] = [:]
        let started = message(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"Run swift test","kind":"execute","status":"pending","rawInput":{"command":"swift test"}}}}"#)
        #expect(ACPRPC.events(started, tools: &tools) == [.step("Running swift test")])
        let ask = request(7, call: #"{"toolCallId":"call_1"}"#)
        #expect(ACPRPC.call(ask, tools: tools) == ToolCall(request: "7", tool: "Bash", command: "swift test"))
        // The request may carry everything itself, the command as words.
        let alone = request(8, call: #"{"toolCallId":"call_9","title":"git status","kind":"execute","rawInput":{"command":["git","status"]}}"#)
        #expect(ACPRPC.call(alone, tools: [:]) == ToolCall(request: "8", tool: "Bash", command: "git status"))
        let bare = request(9, call: #"{"toolCallId":"call_10","title":"ls -la","kind":"execute"}"#)
        #expect(ACPRPC.call(bare, tools: [:])?.command == "ls -la")
    }

    @Test func otherKindsMapToTheirFamilies() {
        let edit = request(1, call: #"{"toolCallId":"c","title":"Edit a.swift","kind":"edit","locations":[{"path":"/tmp/oby/jobs/abc/a.swift"}],"content":[{"type":"diff","path":"/tmp/oby/jobs/abc/b.swift","oldText":"a","newText":"b"}]}"#)
        #expect(ACPRPC.call(edit, tools: [:]) == ToolCall(request: "1", tool: "Edit", paths: ["/tmp/oby/jobs/abc/a.swift", "/tmp/oby/jobs/abc/b.swift"]))
        let read = request(2, call: #"{"toolCallId":"c","title":"Read a.swift","kind":"read","locations":[{"path":"/tmp/oby/jobs/abc/a.swift"}]}"#)
        #expect(ACPRPC.call(read, tools: [:])?.tool == "Read")
        let fetch = request(3, call: #"{"toolCallId":"c","title":"Fetch","kind":"fetch","rawInput":{"url":"https://example.com"}}"#)
        #expect(ACPRPC.call(fetch, tools: [:]) == ToolCall(request: "3", tool: "WebFetch", url: "https://example.com"))
        let mcp = request(4, call: #"{"toolCallId":"c","title":"mcp__tetrix__get_entity","kind":"other"}"#)
        #expect(ACPRPC.call(mcp, tools: [:])?.tool == "mcp__tetrix__get_entity")
        let other = request(5, call: #"{"toolCallId":"c","title":"Switch to agent mode","kind":"switch_mode"}"#)
        #expect(ACPRPC.call(other, tools: [:])?.tool == "Cursor(Switch to agent mode)")
        #expect(ACPRPC.call(message(#"{"id":1,"method":"fs/read_text_file","params":{}}"#), tools: [:]) == nil)
    }

    @Test func neverAllowAlways() {
        let options = [ACPOption(id: "a", kind: "allow_always"), ACPOption(id: "r", kind: "reject_once")]
        let reply = ACPRPC.answer(.always, options: options)
        #expect(selected(reply) == "r")
        #expect(reply.said == "Oby can't allow this once")
        // Always is a plain allow once too, even with every option there.
        let all = ACPRPC.options(request(1, call: #"{"toolCallId":"c"}"#))
        #expect(selected(ACPRPC.answer(.always, options: all)) == "allow-once")
    }

    @Test func allowOncePicked() {
        let options = ACPRPC.options(request(1, call: #"{"toolCallId":"c"}"#))
        #expect(options.map(\.kind) == ["allow_once", "allow_always", "reject_once", "reject_always"])
        let reply = ACPRPC.answer(.allow, options: options)
        #expect(reply.result["outcome"] as? [String: String] == ["outcome": "selected", "optionId": "allow-once"])
        #expect(reply.said == nil)
    }

    @Test func denyIsRejectOnceWithItsReason() {
        let options = ACPRPC.options(request(1, call: #"{"toolCallId":"c"}"#))
        let reply = ACPRPC.answer(.deny("Stay inside the worktree."), options: options)
        #expect(selected(reply) == "reject-once" && reply.said == "Stay inside the worktree.")
        // No reject_once at all: the permission is cancelled, never an allow.
        let none = ACPRPC.answer(.deny("no"), options: [ACPOption(id: "a", kind: "allow_once")])
        #expect(none.result["outcome"] as? [String: String] == ["outcome": "cancelled"])
    }

    @Test func policyDeniesWhatItDeniesElsewhere() throws {
        let publish = request(1, call: #"{"toolCallId":"c","title":"git push origin main","kind":"execute","rawInput":{"command":"git push origin main"}}"#)
        let call = try #require(ACPRPC.call(publish, tools: [:]))
        let reason = try #require(ACPRPC.denial(call, worktree: worktree))
        #expect(reason.contains("Oby publishes the job's branch itself"))
        let outside = try #require(ACPRPC.call(request(2, call: #"{"toolCallId":"c","title":"Edit","kind":"edit","locations":[{"path":"/Users/someone/x.txt"}]}"#), tools: [:]))
        #expect(ACPRPC.denial(outside, worktree: worktree)?.contains("Stay inside") == true)
        let nowhere = try #require(ACPRPC.call(request(3, call: #"{"toolCallId":"c","title":"Edit","kind":"edit"}"#), tools: [:]))
        #expect(ACPRPC.denial(nowhere, worktree: worktree) != nil)
        let status = try #require(ACPRPC.call(request(4, call: #"{"toolCallId":"c","title":"git status","kind":"execute","rawInput":{"command":"git status"}}"#), tools: [:]))
        #expect(ACPRPC.denial(status, worktree: worktree) == nil)
    }

    // MARK: Cursor's own requests

    @Test func createPlanIsExitPlanMode() {
        let plan = message(#"{"jsonrpc":"2.0","id":12,"method":"cursor/create_plan","params":{"toolCallId":"plan_1","name":"Empty state","overview":"Add an empty state","plan":"1. Add the view\n2. Test it","todos":[{"id":"1","content":"Add the view","status":"pending"}]}}"#)
        #expect(ACPRPC.incoming(plan) == .plan)
        #expect(ACPRPC.plan(plan) == ToolCall(request: "12", tool: "ExitPlanMode", plan: "1. Add the view\n2. Test it"))
        #expect(ACPRPC.plan(.allow)["outcome"] as? [String: String] == ["outcome": "accepted"])
        #expect(ACPRPC.plan(.deny("Smaller steps."))["outcome"] as? [String: String] == ["outcome": "rejected", "reason": "Smaller steps."])
        // The plan card (Plan mode) is where it waits; in any other mode it goes through.
        let call = ACPRPC.plan(plan)
        #expect(PermissionPolicy.decide(call, mode: .plan, rules: [], worktree: worktree) == .ask)
        #expect(PermissionPolicy.decide(call, mode: .acceptEdits, rules: [], worktree: worktree) == .allow)
    }

    @Test func askQuestionSkipped() {
        let question = message(#"{"jsonrpc":"2.0","id":13,"method":"cursor/ask_question","params":{"toolCallId":"q_1","title":"Which?","questions":[{"id":"a","prompt":"Which?","options":[{"id":"x","label":"X"}]}]}}"#)
        #expect(ACPRPC.incoming(question) == .question)
        #expect((ACPRPC.skipped()["outcome"] as? [String: String])?["outcome"] == "skipped")
        #expect(ACPRPC.incoming(message(#"{"id":1,"method":"terminal/create","params":{}}"#)) == .other)
    }

    // MARK: Turns

    @Test func stopReasons() {
        #expect(ACPRPC.finished(stopReason: "end_turn", text: "Built it.") == .turnEnded(summary: "Built it.", failed: false))
        #expect(ACPRPC.finished(stopReason: "end_turn", text: "") == .turnEnded(summary: "Done.", failed: false))
        #expect(ACPRPC.finished(stopReason: "cancelled", text: "") == .turnEnded(summary: "Stopped.", failed: false))
        guard case .turnEnded(_, let failed) = ACPRPC.finished(stopReason: "refusal", text: "") else { Issue.record("refusal didn't end the turn"); return }
        #expect(failed)
        #expect(ACPRPC.finished(stopReason: "max_turn_requests", text: "x") == .maxTurns)
        let limit = ACPError(code: -32603, message: "You've hit your usage limit.")
        #expect(ACPRPC.failed(limit, tool: "Cursor") == .limit(resets: nil))
        #expect(ACPRPC.failed(ACPError(code: -32603, message: "boom"), tool: "Cursor") == .turnEnded(summary: "Cursor hit an error: boom", failed: true))
    }

    @Test func authErrors() {
        #expect(ACPError(code: -32000, message: "Authentication required").isAuth)
        #expect(ACPError(code: -32603, message: "Not logged in. Run cursor-agent login.").isAuth)
        #expect(!ACPError(code: -32603, message: "Internal error").isAuth)
    }

    @Test func updatesBecomeSteps() {
        var tools: [String: ACPToolCall] = [:]
        let edit = message(#"{"method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"c2","title":"Edit Home.swift","kind":"edit","status":"pending","locations":[{"path":"/tmp/oby/jobs/abc/iOS/Home.swift"}]}}}"#)
        #expect(ACPRPC.events(edit, tools: &tools) == [.step("Editing Home.swift")])
        // The same step again says nothing.
        let done = message(#"{"method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"c2","status":"completed"}}}"#)
        #expect(ACPRPC.events(done, tools: &tools).isEmpty)
        let todos = message(#"{"method":"cursor/update_todos","params":{"toolCallId":"t","todos":[{"id":"1","content":"Add the view","status":"in_progress"}],"merge":true}}"#)
        #expect(ACPRPC.events(todos, tools: &tools) == [.step("Working on: Add the view")])
        let helper = message(#"{"method":"cursor/task","params":{"toolCallId":"t2","description":"Explore the repo","prompt":"","subagentType":"explore"}}"#)
        #expect(ACPRPC.events(helper, tools: &tools) == [.step("Explore the repo")])
        let text = message(#"{"method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}"#)
        #expect(ACPRPC.chunk(text) == "Hello" && ACPRPC.events(text, tools: &tools).isEmpty)
    }

    @Test func promptCarriesImagesAsBlocks() {
        let params = ACPRPC.prompt(session: "s1", text: "Build it", images: [(Data([1, 2, 3]), "image/png")])
        let blocks = params["prompt"] as? [[String: Any]]
        #expect(blocks?.count == 2 && blocks?[0]["text"] as? String == "Build it")
        #expect(blocks?[1]["type"] as? String == "image" && blocks?[1]["mimeType"] as? String == "image/png" && blocks?[1]["data"] as? String == "AQID")
    }

    // MARK: Framing

    /// Foundation's `lines` also breaks at U+2028, which a JSON string may hold: only \n ends a message.
    @Test func splitsOnNewlineOnly() async throws {
        let pipe = Pipe()
        let line = #"{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"one\#u{2028}two"}}}}"#
        pipe.fileHandleForWriting.write(Data((line + "\n" + line + "\n").utf8))
        try pipe.fileHandleForWriting.close()
        nonisolated(unsafe) var lines: [Data] = []
        try await eachLine(of: pipe.fileHandleForReading) { lines.append($0) }
        #expect(lines.count == 2)
        let parsed = try #require(try JSONSerialization.jsonObject(with: lines[0]) as? [String: Any])
        #expect(ACPRPC.chunk(parsed) == "one\u{2028}two")
    }
}
