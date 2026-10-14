import Foundation
#if canImport(OSLog)
import OSLog
#endif

// A generic Agent Client Protocol client (#406): newline-delimited JSON-RPC 2.0 over a tool's
// stdio (https://agentclientprotocol.com). Cursor is the first tool (Engine/Cursor.swift); Gemini
// CLI, opencode or Copilot CLI later need only an `ACPTool`.

/// One answer a `session/request_permission` offers.
nonisolated struct ACPOption: Equatable, Sendable {
    var id: String
    /// `allow_once`, `allow_always`, `reject_once` or `reject_always`. Cursor's own page names the
    /// options `allow-once` and so on: both read the same.
    var kind: String
}

/// A JSON-RPC error the tool answered with.
nonisolated struct ACPError: LocalizedError, Sendable {
    var code: Int
    var message: String
    var errorDescription: String? { message }

    /// The tool says the login is missing: ACP's "authentication required" (-32000), or words to that effect.
    var isAuth: Bool {
        code == -32000 || message.contains(/(?i)\bauth(?:enticat\w*|orization)?\b|signed out|sign in|log ?in|logged out/)
    }
}

/// A tool call the agent reported (`tool_call`, then `tool_call_update`s), kept by `toolCallId`: a
/// permission request names the call, and what it needs (the command, the files) came earlier.
nonisolated struct ACPToolCall {
    var id: String
    var kind: String?
    var title: String?
    var status: String?
    var command: String?
    var url: String?
    var pattern: String?
    var paths: [String] = []
    var background = false
    /// The step last said for it, so an update that changes nothing says nothing.
    var said: String?

    init(id: String) { self.id = id }

    /// Takes in the fields of a `tool_call`, a `tool_call_update` or a request's own `toolCall`.
    mutating func merge(_ fields: [String: Any]) {
        if let kind = fields["kind"] as? String { self.kind = kind }
        if let title = fields["title"] as? String, !title.isEmpty { self.title = title }
        if let status = fields["status"] as? String { self.status = status }
        if let input = fields["rawInput"] as? [String: Any] {
            switch input["command"] {
            case let text as String: command = text
            case let words as [Any]: command = words.map { "\($0)" }.joined(separator: " ")
            default: break
            }
            if let value = input["url"] as? String { url = value }
            if let value = (input["pattern"] ?? input["query"]) as? String { pattern = value }
            if input["run_in_background"] as? Bool == true { background = true }
        }
        var found: [String] = []
        for location in fields["locations"] as? [[String: Any]] ?? [] {
            if let path = location["path"] as? String { found.append(path) }
        }
        for block in fields["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "diff" {
            if let path = block["path"] as? String { found.append(path) }
        }
        for path in found where !paths.contains(path) { paths.append(path) }
    }
}

/// Reads what an ACP tool sends and writes what it takes: pure, so the wire format is tested from
/// recorded fixtures (RunnerTests/ACPTests.swift).
nonisolated enum ACPRPC {
    // MARK: Requests Oby sends

    static func initialize(version: String) -> [String: Any] {
        // No `fs` or `terminal` capability: the tool reads and runs commands itself, and every
        // command and edit comes to Oby as a permission request.
        ["protocolVersion": 1, "clientCapabilities": [String: Any](), "clientInfo": ["name": "oby", "title": "Oby", "version": version]]
    }

    static func sessionNew(cwd: String, mcp: [[String: Any]]) -> [String: Any] {
        ["cwd": cwd, "mcpServers": mcp]
    }

    static func sessionLoad(session: String, cwd: String, mcp: [[String: Any]]) -> [String: Any] {
        ["sessionId": session, "cwd": cwd, "mcpServers": mcp]
    }

    /// The text, then each image as an image block, when the tool takes images.
    static func prompt(session: String, text: String, images: [(data: Data, mediaType: String)] = []) -> [String: Any] {
        let blocks: [[String: Any]] = [["type": "text", "text": text]]
            + images.map { ["type": "image", "data": $0.data.base64EncodedString(), "mimeType": $0.mediaType] }
        return ["sessionId": session, "prompt": blocks]
    }

    static func cancel(session: String) -> [String: Any] { ["sessionId": session] }

    static func setMode(session: String, mode: String) -> [String: Any] { ["sessionId": session, "modeId": mode] }

    static func setConfigOption(session: String, option: String, value: String) -> [String: Any] {
        ["sessionId": session, "configId": option, "value": value]
    }

    /// The MCP server entry for the broker (`AgentMCP`): Streamable HTTP, the job's token in a
    /// header. Only for a tool whose `mcpCapabilities.http` holds.
    static func broker(_ mcp: AgentMCP) -> [String: Any] {
        ["type": "http", "name": AgentMCP.server, "url": mcp.url,
         "headers": [["name": "Authorization", "value": "Bearer \(mcp.token)"]]]
    }

    /// The account's MCP servers as `session/new` takes them, from an `mcp.json`'s contents: a
    /// server with a URL is HTTP (`http` when the tool takes it), one with a command is stdio. Only
    /// `ClaudeAgent.mcpKeys` of each: one that needs a header or an environment variable is left
    /// out, and one signed in with OAuth keeps its login in the account's own store.
    static func accountServers(_ config: Data?, http: Bool) -> [[String: Any]] {
        guard let config, let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().compactMap { name in
            guard let server = servers[name] as? [String: Any], server["headers"] == nil, server["env"] == nil else { return nil }
            let kept = server.filter { ClaudeAgent.mcpKeys.contains($0.key) }
            if let url = kept["url"] as? String {
                // `type: "sse"` is the old transport: not offered.
                guard http, kept["type"] as? String ?? "http" == "http" else { return nil }
                return ["type": "http", "name": name, "url": url, "headers": [[String: String]]()]
            }
            guard let command = kept["command"] as? String else { return nil }
            return ["name": name, "command": command, "args": kept["args"] as? [String] ?? [], "env": [[String: String]]()]
        }
    }

    /// The `model` option's value for the model Settings names: the value itself, or the first one
    /// that starts with it and its parameters (`gpt-5.6-luna[context=272k,…]`), its current value
    /// first. Nil for Auto (Cursor picks) and for a model the option doesn't offer.
    static func modelValue(_ model: String, in values: [String], current: String?) -> String? {
        guard !model.isEmpty, model != "auto" else { return nil }
        if values.contains(model) { return model }
        let variants = values.filter { $0.hasPrefix(model + "[") }
        if let current, variants.contains(current) { return current }
        return variants.first
    }

    /// What `session/new` and `session/load` answered, as Oby needs it.
    nonisolated struct Session: Equatable, Sendable {
        var id: String?
        /// Mode ids the tool offers (`modes.availableModes`, or the `mode` config option's values).
        var modes: [String] = []
        var currentMode: String?
        /// The config option that sets the mode (category `mode`), when the tool has one.
        var modeOption: String?
        /// The config option that sets the model (category `model`), its current value and values.
        var modelOption: String?
        var model: String?
        var models: [String] = []
    }

    static func session(_ result: [String: Any]) -> Session {
        var session = Session(id: result["sessionId"] as? String)
        if let modes = result["modes"] as? [String: Any] {
            session.modes = (modes["availableModes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            session.currentMode = modes["currentModeId"] as? String
        }
        for option in result["configOptions"] as? [[String: Any]] ?? [] {
            guard let id = option["id"] as? String else { continue }
            let values = (option["options"] as? [[String: Any]] ?? []).flatMap { entry -> [String] in
                // Options come flat, or in groups of their own.
                if let value = entry["value"] as? String { return [value] }
                return (entry["options"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
            }
            switch option["category"] as? String {
            case "mode":
                session.modeOption = id
                session.modes = values
                session.currentMode = option["currentValue"] as? String
            case "model":
                session.modelOption = id
                session.models = values
                session.model = option["currentValue"] as? String
            default: break
            }
        }
        return session
    }

    /// Whether the tool can load a session it ran before, and take images and HTTP MCP servers.
    nonisolated struct Capabilities: Equatable, Sendable {
        var loadSession = false
        var image = false
        var http = false
    }

    static func capabilities(_ result: [String: Any]) -> Capabilities {
        let agent = result["agentCapabilities"] as? [String: Any] ?? [:]
        return Capabilities(loadSession: agent["loadSession"] as? Bool == true,
                            image: (agent["promptCapabilities"] as? [String: Any])?["image"] as? Bool == true,
                            http: (agent["mcpCapabilities"] as? [String: Any])?["http"] as? Bool == true)
    }

    // MARK: Updates

    /// The text of an `agent_message_chunk`, or nil for any other message.
    static func chunk(_ message: [String: Any]) -> String? {
        guard message["method"] as? String == "session/update",
              let update = (message["params"] as? [String: Any])?["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "agent_message_chunk",
              let content = update["content"] as? [String: Any], content["type"] as? String == "text" else { return nil }
        return content["text"] as? String
    }

    /// What a notification says Oby should show: the steps of tool calls (`tools` keeps each call
    /// by its id, to read a later update and a permission request against), the plan, to-dos and
    /// helpers.
    // ponytail: no AgentActivity (#381 isn't in yet): a tool call is a step, to-dos and helpers a line.
    static func events(_ message: [String: Any], tools: inout [String: ACPToolCall]) -> [AgentEvent] {
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "session/update":
            let update = params["update"] as? [String: Any] ?? [:]
            switch update["sessionUpdate"] as? String {
            case "tool_call", "tool_call_update":
                guard let id = update["toolCallId"] as? String else { return [] }
                var call = tools[id] ?? ACPToolCall(id: id)
                call.merge(update)
                let step = step(call)
                defer { tools[id] = call }
                guard step != call.said else { return [] }
                call.said = step
                return [.step(step)]
            case "plan":
                return [.step("Planning the work")]
            default:
                return []
            }
        case "cursor/update_todos":
            let todos = params["todos"] as? [[String: Any]] ?? []
            let doing = todos.first { $0["status"] as? String == "in_progress" }?["content"] as? String
            return [.step(doing.map { "Working on: \($0)" } ?? "Planning the work")]
        case "cursor/task":
            return [.step((params["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Starting a helper")]
        default:
            return []
        }
    }

    /// What a tool call is doing, in the same words as Claude Code's steps.
    static func step(_ call: ACPToolCall) -> String {
        let title = call.title.flatMap { $0.isEmpty ? nil : $0 }
        switch call.kind {
        case "execute":
            return StreamJSON.step(tool: "Bash", input: ["command": call.command ?? title ?? ""])
        case "read":
            return StreamJSON.step(tool: "Read", input: call.paths.first.map { ["file_path": $0] } ?? [:])
        case "search":
            return call.pattern.map { StreamJSON.step(tool: "Grep", input: ["pattern": $0]) } ?? title ?? "Searching"
        case "edit", "move":
            return StreamJSON.step(tool: "Edit", input: call.paths.first.map { ["file_path": $0] } ?? [:])
        case "delete":
            return call.paths.first.map { "Deleting \(URL(filePath: $0).lastPathComponent)" } ?? title ?? "Deleting a file"
        case "fetch":
            return StreamJSON.step(tool: "WebFetch", input: [:])
        case "think":
            return title ?? "Thinking"
        default:
            return title ?? "Using a tool"
        }
    }

    // MARK: Requests the tool sends

    /// What a request of the tool's is, by its method.
    enum Incoming: Equatable {
        /// `session/request_permission`: a command, an edit, a fetch or an MCP call.
        case permission
        /// Cursor's `cursor/create_plan`: a plan to approve.
        case plan
        /// Cursor's `cursor/ask_question`: blocks until answered, and Oby answers it skipped.
        case question
        /// Anything else (`fs/*`, `terminal/*`, other `cursor/*`): refused, so the tool never waits.
        case other
    }

    static func incoming(_ request: [String: Any]) -> Incoming {
        switch request["method"] as? String {
        case "session/request_permission": .permission
        case "cursor/create_plan": .plan
        case "cursor/ask_question": .question
        default: .other
        }
    }

    /// The id a request is answered by and keyed under: ids are numbers or strings.
    static func key(_ request: [String: Any]) -> String {
        (request["id"] as? Int).map(String.init) ?? request["id"] as? String ?? UUID().uuidString
    }

    static func options(_ request: [String: Any]) -> [ACPOption] {
        let params = request["params"] as? [String: Any] ?? [:]
        return (params["options"] as? [[String: Any]] ?? []).compactMap { option in
            guard let id = option["optionId"] as? String else { return nil }
            let kind = (option["kind"] as? String ?? id).replacing("-", with: "_")
            return ACPOption(id: id, kind: kind)
        }
    }

    /// The tool call a permission request is about: what its own earlier messages said (`tools`)
    /// with what the request carries.
    static func resolved(_ request: [String: Any], tools: [String: ACPToolCall]) -> ACPToolCall? {
        guard request["method"] as? String == "session/request_permission" else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        let fields = params["toolCall"] as? [String: Any] ?? [:]
        var call = (fields["toolCallId"] as? String).flatMap { tools[$0] } ?? ACPToolCall(id: fields["toolCallId"] as? String ?? "")
        call.merge(fields)
        return call
    }

    /// A permission request as a tool call, for the job's mode and the user's rules.
    static func call(_ request: [String: Any], tools: [String: ACPToolCall]) -> ToolCall? {
        resolved(request, tools: tools).map { toolCall($0, request: key(request)) }
    }

    /// Whether the notification starts a tool call.
    static func startsToolCall(_ message: [String: Any]) -> Bool {
        let update = (message["params"] as? [String: Any])?["update"] as? [String: Any]
        return message["method"] as? String == "session/update" && update?["sessionUpdate"] as? String == "tool_call"
    }

    /// `execute` is "Bash", file changes "Edit", reads and searches "Read", fetches "WebFetch"; a
    /// tool shaped as an MCP tool is `mcp__<server>__<tool>`. Anything else is `Cursor(<title>)`,
    /// which `PermissionPolicy.decide` asks about in every mode.
    static func toolCall(_ call: ACPToolCall, request: String) -> ToolCall {
        let title = call.title ?? ""
        if let mcp = mcpName(title) { return ToolCall(request: request, tool: mcp) }
        switch call.kind {
        case "execute":
            return ToolCall(request: request, tool: "Bash", command: call.command ?? title)
        case "edit", "delete", "move":
            return ToolCall(request: request, tool: "Edit", paths: call.paths)
        case "read", "search":
            return ToolCall(request: request, tool: "Read", paths: call.paths)
        case "fetch":
            return ToolCall(request: request, tool: "WebFetch", url: call.url ?? (title.hasPrefix("http") ? title : nil))
        default:
            let line = (title.split(separator: "\n").first.map(String.init) ?? title).trimmingCharacters(in: .whitespaces)
            return ToolCall(request: request, tool: "Cursor(\(line.isEmpty ? "a tool" : String(line.prefix(80))))")
        }
    }

    /// "mcp__tetrix__get_entity", "mcp:tetrix:get_entity" or "mcp.tetrix.get_entity" as the first form.
    static func mcpName(_ title: String) -> String? {
        guard let match = title.wholeMatch(of: /mcp(?:__|[:.])([A-Za-z0-9_-]+?)(?:__|[:.])([A-Za-z0-9_.-]+)/) else { return nil }
        return "mcp__\(match.1)__\(match.2)"
    }

    /// Why Policy's fixed rules refuse the call, or nil: a push, a file outside the worktree, an
    /// MCP server that isn't Tetrix's. An edit with no file named is refused as Codex's is.
    static func denial(_ call: ToolCall, worktree: URL, background: Bool = false) -> String? {
        switch call.tool {
        case "Bash":
            var input: [String: Any] = ["command": call.command ?? ""]
            if background { input["run_in_background"] = true }
            return Policy.deny(tool: "Bash", input: input, worktree: worktree)
        case "Edit":
            guard !call.paths.isEmpty else { return "Oby couldn't see which files this change writes." }
            return call.paths.lazy.compactMap { Policy.deny(tool: "Edit", input: ["file_path": $0], worktree: worktree) }.first
        case "Read":
            return call.paths.lazy.compactMap { Policy.deny(tool: "Read", input: ["file_path": $0], worktree: worktree) }.first
        default:
            return Policy.deny(tool: call.tool, input: [:], worktree: worktree)
        }
    }

    /// The `cursor/create_plan` request as a plan card's call: "ExitPlanMode", with the plan.
    static func plan(_ request: [String: Any]) -> ToolCall {
        let params = request["params"] as? [String: Any] ?? [:]
        let text = (params["plan"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? [params["name"] as? String, params["overview"] as? String].compactMap { $0 }.joined(separator: "\n\n")
        return ToolCall(request: key(request), tool: "ExitPlanMode", plan: text)
    }

    // MARK: Answers

    /// A permission answered with the option chosen, or none (`cancelled`).
    nonisolated struct Reply: Equatable {
        var result: [String: Any]
        /// Words for the agent at its next prompt: what Oby declined, and why.
        var said: String?

        static func == (a: Reply, b: Reply) -> Bool {
            (a.result as NSDictionary).isEqual(to: b.result) && a.said == b.said
        }
    }

    /// Oby's answer: allow and always are the `allow_once` option, never `allow_always` (it would
    /// let the same call through later without asking Oby, past the user's deny rules); with no
    /// `allow_once` Oby rejects, saying so. Deny is `reject_once`, with the reason for the next prompt.
    static func answer(_ answer: ToolAnswer, options: [ACPOption]) -> Reply {
        let choose = { (kind: String) in options.first { $0.kind == kind }?.id }
        switch answer {
        case .allow, .always:
            if let once = choose("allow_once") { return Reply(result: selected(once)) }
            let why = "Oby can't allow this once"
            return Reply(result: choose("reject_once").map(selected) ?? cancelled(), said: why)
        case .deny(let reason):
            return Reply(result: choose("reject_once").map(selected) ?? cancelled(), said: reason)
        }
    }

    static func selected(_ option: String) -> [String: Any] { ["outcome": ["outcome": "selected", "optionId": option]] }

    static func cancelled() -> [String: Any] { ["outcome": ["outcome": "cancelled"]] }

    /// `cursor/ask_question` blocks until answered: Oby doesn't ask the user from inside a turn.
    static func skipped() -> [String: Any] {
        ["outcome": ["outcome": "skipped", "reason": "Oby can't put a question to the user here. Decide yourself, or say what you need in your summary."]]
    }

    /// `cursor/create_plan`'s answer: the user approved the plan, or sent it back with `reason`.
    static func plan(_ answer: ToolAnswer) -> [String: Any] {
        switch answer {
        case .allow, .always: ["outcome": ["outcome": "accepted"]]
        case .deny(let reason): ["outcome": ["outcome": "rejected", "reason": reason]]
        }
    }

    // MARK: Turns

    /// What a `session/prompt` answered: the turn ended, or ran out of requests.
    static func finished(stopReason: String, text: String) -> AgentEvent {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stopReason {
        case "end_turn": return .turnEnded(summary: said.isEmpty ? "Done." : said, failed: false)
        case "cancelled": return .turnEnded(summary: said.isEmpty ? "Stopped." : said, failed: false)
        case "max_turn_requests": return .maxTurns
        case "refusal": return .turnEnded(summary: said.isEmpty ? "The model refused to continue." : said, failed: true)
        case "max_tokens": return .turnEnded(summary: said.isEmpty ? "The model ran out of tokens in this turn." : said, failed: true)
        default: return .turnEnded(summary: said.isEmpty ? "The turn ended: \(stopReason)." : said, failed: true)
        }
    }

    /// `session/prompt` answered with an error: the account's limit (Desk moves the job on), or a failure.
    static func failed(_ error: ACPError, tool: String) -> AgentEvent {
        if Limits.isLimit(error.message) { return .limit(resets: nil) }
        return .turnEnded(summary: "\(tool) hit an error: \(error.message)", failed: true)
    }
}

// MARK: The tool

/// An agent that speaks ACP: what it takes to start one and what Oby needs to know of it. Cursor
/// is `ACPTool.cursor` (Engine/Cursor.swift); a tool of Gemini CLI's or opencode's kind later
/// needs only a value like it.
nonisolated struct ACPTool: Sendable {
    /// The id jobs and accounts name it by: "cursor".
    var id: String
    /// How reports say it: "Cursor".
    var name: String
    /// The command line, boxed and niced: the first word is found on PATH.
    var arguments: [String]
    /// What changes in the agent's environment (a nil value removes one); on top of
    /// `Agents.environment`, the Apple checks' and Swift's.
    var environment: [String: String?] = [:]
    /// Its modes' ids for Plan and for everything else.
    var planMode = "plan"
    var agentMode = "agent"
    /// The model to ask for through its `model` config option, when it offers one.
    var model: String?
    /// Whether the broker's MCP server may go to it in `session/new` (once the tool is known to take it).
    var honoursMCP = true
    /// The account's own MCP servers (`{"mcpServers": {…}}`, Cursor's `mcp.json`), which go along
    /// with only the keys that start them (`ClaudeAgent.mcpKeys`: never a header or an env value).
    var mcpFile: URL?
    /// Runs before the process starts (a config file Oby owns).
    var prepare: (@Sendable () throws -> Void)?
    /// Why it can't start at all, or nil.
    var cannotStart: String?
    /// Commands the repository pre-allows (`.cursor/cli.json`), which Oby asks about once.
    var repositoryAllowlist: (@Sendable (URL) -> [String])?
}

// MARK: The process

/// One ACP agent process speaking JSON-RPC 2.0 over stdio: a copy of `CodexServer`'s shape. Answers
/// come back to `call`; the tool's requests and notifications go to `onMessage`.
final class ACPServer {
    private let process = Process()
    private var group: ProcessGroup?
    private let input = Pipe()
    private let output = Pipe()
    /// Writes to the tool, in order and off the main thread: an image in a prompt is megabytes.
    private let writes = DispatchQueue(label: "com.deskree.oby.acp-input")
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let tool: String
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onExit: () -> Void = {}
    var isRunning: Bool { process.isRunning }

    /// The environment an ACP tool starts with: the agent environment (no GitHub login, no vault
    /// secret), the Apple checks' and Swift's variables, then the tool's own.
    static func environment(for tool: ACPTool, worktree: URL?, base: [String: String] = Shell.environment) throws -> [String: String] {
        try Agents.environment(AppleCheck.environment(worktree: worktree)
            .merging(worktree.map { Agents.swiftEnvironment(worktree: $0, base: base) } ?? [:]) { $1 }
            .merging(tool.environment) { $1 }, base: base)
    }

    init(tool: ACPTool, in directory: URL?, log: URL?) throws {
        self.tool = tool.name
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = tool.arguments
        process.currentDirectoryURL = directory
        process.environment = try Self.environment(for: tool, worktree: directory)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = log.flatMap { try? FileHandle(forWritingTo: $0) } ?? FileHandle.nullDevice
        group = try ProcessGroup.run(process)
        Task { await read() }
    }

    func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            send(["id": id, "method": method, "params": params])
        }
    }

    /// A notification: no answer comes.
    func notify(_ method: String, _ params: [String: Any]) {
        send(["method": method, "params": params])
    }

    func reply(_ id: Any, _ result: [String: Any]) {
        send(["id": id, "result": result])
    }

    func refuse(_ id: Any) {
        send(["id": id, "error": ["code": -32601, "message": "Oby doesn't answer this request."]])
    }

    /// Closing stdin ends the server.
    func end() {
        let input = input.fileHandleForWriting
        writes.async { try? input.close() }
    }

    /// Ends it, with whatever it started (`Halt`).
    func kill() {
        group?.end(after: Halt.dropping)
    }

    /// Ends it now, with whatever it started: Stop's 2 seconds.
    func halt() {
        group?.end(after: Halt.stopping)
    }

    /// Ends it `delay` seconds from now unless it ended. Off the main queue: Stop's 2 seconds hold
    /// however busy the main thread is.
    func halt(after delay: TimeInterval) {
        let group = group
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { group?.end(after: Halt.stopping) }
    }

    func ended() async {
        await group?.ended()
    }

    /// How the process ended, once it has: "exit status 1".
    func exit() async -> String {
        await ClaudeAgent.exit(of: process)
    }

    private func read() async {
        do {
            try await eachLine(of: output.fileHandleForReading, receive)
        } catch {
            Logger.jobs.error("reading \(self.tool, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        for continuation in waiting.values { continuation.resume(throwing: ACPError(code: 0, message: "\(tool) stopped.")) }
        waiting = [:]
        onExit()
    }

    private func receive(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if message["method"] != nil { return onMessage(message) }
        guard let id = message["id"] as? Int, let continuation = waiting.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: ACPError(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? "\(tool) refused."))
        } else {
            continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }

    private func send(_ message: [String: Any]) {
        guard process.isRunning else { return }
        var message = message
        message["jsonrpc"] = "2.0"
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        let input = input.fileHandleForWriting, line = data
        writes.async { try? input.write(contentsOf: line) }
    }
}

// MARK: The agent

/// A job's agent on any ACP tool (#406). It is `ClaudeAgent` and `CodexAgent`'s sibling: Desk
/// starts it, sends it words, answers its prompts and stops it.
final class ACPAgent: AgentRun {
    private let tool: ACPTool
    private let worktree: URL
    private var server: ACPServer?
    private var session: String?
    private var capabilities = ACPRPC.Capabilities()
    private var found = ACPRPC.Session()
    private var onEvent: (AgentEvent) -> Void = { _ in }
    /// The session to pick up again, or nil for a new one.
    private let resume: String?

    /// This job's model, or nil for Settings › Models.
    var model: String?
    /// The account's name, for "Cursor · Work is signed out".
    var account = ""
    /// The repository the job works in, for the allowlist question, and where its approvals are kept.
    var repo = ""
    var approvals = UserDefaults.standard
    /// The broker's endpoint for this job (Engine/Connected.swift), or nil when nothing is connected.
    var mcp: AgentMCP?
    /// The job's mode: Plan is the tool's plan mode; every other mode its agent mode, where
    /// Oby answers each permission.
    var mode = PermissionMode.bypass
    /// The mode the tool is in now.
    private var applied: String?

    /// A prompt is in flight: its result ends the turn.
    private var prompting = false
    /// Words that came while a turn ran: the next prompts (ACP has no steer).
    private var queue: [String] = []
    /// What the agent said this turn: the message in progress, and the one before the last tool call.
    private var current = ""
    private var before = ""
    private var tools: [String: ACPToolCall] = [:]
    /// Permission and plan requests waiting for an answer, by request key.
    private var pending: [String: Pending] = [:]
    /// What Oby declined, for the next prompt to say.
    private var declined: [String] = []
    /// The plan was approved while the tool was in plan mode: its next prompt tells it to go ahead.
    private var goAhead = false
    private var result: (summary: String, failed: Bool)?
    private var finished = false
    private var closing = false
    private var stopped = false
    /// A change of mode that came mid-turn, applied when the turn ends.
    private var wantedMode: String?

    private struct Pending {
        var id: Any
        var options: [ACPOption]
        var plan: Bool
        var title: String
    }

    init(tool: ACPTool, worktree: URL, resume: String? = nil) {
        self.tool = tool
        self.worktree = worktree
        self.resume = resume
    }

    /// The call that asks about a repository's own allowlist (`ACPTool.repositoryAllowlist`).
    static let allowlistTool = "Cursor(this repository's allowlist)"
    /// The approvals kept per repository and list: "deskree-inc/oby|Shell(git status)".
    private static let approvedKey = "acp.allowlistApproved"

    func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
        self.onEvent = onEvent
        if let why = tool.cannotStart { throw Shell.Failure(message: why) }
        let listed = tool.repositoryAllowlist?(worktree) ?? []
        guard !listed.isEmpty, !approved(repo, listed) else { return try launch(prompt) }
        // A repository that pre-allows commands lets them through without asking Oby: the user says
        // once whether that's fine, naming them.
        queue.append(prompt)
        pending[Self.allowlistTool] = Pending(id: 0, options: [], plan: false, title: Self.allowlistTool)
        onEvent(.ask(ToolCall(request: Self.allowlistTool, tool: Self.allowlistTool, command: listed.joined(separator: "\n"))))
    }

    private func approved(_ repo: String, _ list: [String]) -> Bool {
        (approvals.stringArray(forKey: Self.approvedKey) ?? []).contains(repo + "|" + list.sorted().joined(separator: "\n"))
    }

    private func approve(_ list: [String]) {
        var kept = approvals.stringArray(forKey: Self.approvedKey) ?? []
        kept.append(repo + "|" + list.sorted().joined(separator: "\n"))
        approvals.set(kept, forKey: Self.approvedKey)
        // Foundation on Linux writes it only when asked.
        _ = approvals.synchronize()
    }

    private func launch(_ prompt: String) throws {
        try tool.prepare?()
        let log = worktree.appending(path: ".oby/agent.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let server = try ACPServer(tool: tool, in: worktree, log: log)
        self.server = server
        server.onMessage = { [weak self] in self?.handle($0) }
        server.onExit = { [weak self] in self?.exited() }
        let images = resume == nil ? Attachments.images(in: worktree) : []
        Task {
            do {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                capabilities = ACPRPC.capabilities(try await server.call("initialize", ACPRPC.initialize(version: version)))
                var servers: [[String: Any]] = []
                if tool.honoursMCP {
                    if let mcp, capabilities.http { servers.append(ACPRPC.broker(mcp)) }
                    servers += ACPRPC.accountServers(tool.mcpFile.flatMap { try? Data(contentsOf: $0) }, http: capabilities.http)
                }
                var made: String?
                if let resume, capabilities.loadSession {
                    // Its modes and options come with the load, as with a new session: the job's mode
                    // and model are applied from them. The session's id is the one picked up.
                    found = ACPRPC.session(try await server.call("session/load", ACPRPC.sessionLoad(session: resume, cwd: worktree.path, mcp: servers)))
                    found.id = resume
                    made = resume
                } else {
                    found = ACPRPC.session(try await server.call("session/new", ACPRPC.sessionNew(cwd: worktree.path, mcp: servers)))
                    made = found.id
                }
                guard let made else { throw ACPError(code: 0, message: "\(tool.name) didn't start a session.") }
                session = made
                onEvent(.session(made))
                applied = found.currentMode
                await settle()
                run(prompt, images: capabilities.image ? images : [])
            } catch let error as ACPError where error.isAuth {
                finish(summary: "\(tool.name) · \(account) is signed out: sign in from Settings › Accounts.", failed: true)
                server.end()
            } catch {
                // A process that ended says how, and a command that isn't there says so.
                let how = server.isRunning ? nil : await server.exit()
                let hint = how == "exit status 127" ? ": its command wasn't found, so is it installed?" : ""
                finish(summary: "\(tool.name) couldn't start: \(error.localizedDescription)" + (how.map { " (\($0))" } ?? "") + hint, failed: true)
                server.end()
            }
        }
    }

    /// Sets the model it offers as an option, and the mode the job is in.
    private func settle() async {
        guard let server, let session else { return }
        if let model = tool.model, !model.isEmpty {
            if let option = found.modelOption, let value = ACPRPC.modelValue(model, in: found.models, current: found.model) {
                if value != found.model {
                    _ = try? await server.call("session/set_config_option", ACPRPC.setConfigOption(session: session, option: option, value: value))
                }
            } else {
                // Said, never silent: Cursor goes on with its own.
                onEvent(.step("\(tool.name) doesn't offer \(model): it uses its own model"))
            }
        }
        await switchMode(to: target(for: mode))
    }

    private func target(for mode: PermissionMode) -> String { mode == .plan ? tool.planMode : tool.agentMode }

    /// Puts the tool in `wanted` (as a config option when it has one, else `session/set_mode`),
    /// when it offers that mode and isn't in it.
    private func switchMode(to wanted: String) async {
        guard let server, let session, wanted != applied, found.modes.contains(wanted) else { return }
        do {
            if let option = found.modeOption {
                _ = try await server.call("session/set_config_option", ACPRPC.setConfigOption(session: session, option: option, value: wanted))
            } else {
                _ = try await server.call("session/set_mode", ACPRPC.setMode(session: session, mode: wanted))
            }
            applied = wanted
        } catch {
            Logger.jobs.error("\(self.tool.name, privacy: .public) wouldn't switch to \(wanted, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Words for the next prompt: what Oby declined since the last one, then the message.
    private func said(_ text: String) -> String {
        guard !declined.isEmpty else { return text }
        defer { declined = [] }
        return declined.joined(separator: "\n") + "\n\n" + text
    }

    /// One prompt, a turn of the session; its result ends the turn.
    private func run(_ text: String, images: [(data: Data, mediaType: String)] = []) {
        guard let server, let session else { return }
        prompting = true
        current = ""
        before = ""
        let params = ACPRPC.prompt(session: session, text: said(text), images: images)
        Task {
            do {
                let answer = try await server.call("session/prompt", params)
                promptEnded(answer["stopReason"] as? String ?? "end_turn")
            } catch let error as ACPError {
                prompting = false
                if error.isAuth, session == self.session {
                    return finish(summary: "\(tool.name) · \(account) is signed out: sign in from Settings › Accounts.", failed: true)
                }
                // A turn killed with the process ends in `exited`.
                guard server.isRunning else { return }
                turnDone(ACPRPC.failed(error, tool: tool.name))
            } catch {
                prompting = false
            }
        }
    }

    private func promptEnded(_ stopReason: String) {
        prompting = false
        guard !stopped else { return }
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? before : current
        Task {
            if let wanted = wantedMode {
                wantedMode = nil
                await switchMode(to: wanted)
            }
            // The plan was approved: the turn that showed it goes on with the work, as one round.
            if goAhead {
                goAhead = false
                return run(PermissionPolicy.approved(mode))
            }
            if !queue.isEmpty { return run(queue.removeFirst()) }
            turnDone(ACPRPC.finished(stopReason: stopReason, text: text))
        }
    }

    /// A turn's result: Desk decides whether another round follows.
    private func turnDone(_ event: AgentEvent) {
        // A limit is the account's, not the work's: Desk moves the job on and drops this agent.
        if case .turnEnded(let summary, let failed) = event { result = (summary, failed) }
        onEvent(event)
        if closing, !prompting { closeNow() }
    }

    /// While a turn runs, the words wait and are the next prompt (ACP has no steer); between
    /// turns they start one. Before the session exists they follow the first prompt.
    func send(_ text: String) {
        queue.append(text)
        guard session != nil, !prompting else { return }
        run(queue.removeFirst())
    }

    /// No more turns: it finishes what it's doing, and its stdin closes. A process that doesn't
    /// exit on that is ended a moment later.
    func end() {
        closing = true
        if !prompting, session != nil || server != nil { closeNow() }
    }

    private func closeNow() {
        guard let server else { return }
        server.end()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if server.isRunning { server.kill() } }
    }

    func stop() {
        stopped = true
        queue = []
        guard let server, server.isRunning else { return }
        if let session { server.notify("session/cancel", ACPRPC.cancel(session: session)) }
        // A permission left unanswered would hold the turn: every one is cancelled.
        for (_, waiting) in pending { server.reply(waiting.id, ACPRPC.cancelled()) }
        pending = [:]
        server.end()
        server.halt(after: Halt.grace)
    }

    func kill() {
        server?.kill()
    }

    func ended() async {
        await server?.ended()
    }

    /// The job's mode changed: the tool's follows, between turns.
    func setMode(_ mode: PermissionMode) {
        self.mode = mode
        let wanted = target(for: mode)
        guard session != nil else { return }
        if prompting { wantedMode = wanted } else { Task { await switchMode(to: wanted) } }
    }

    /// Oby's answer, or the user's.
    func answer(_ call: ToolCall, _ answer: ToolAnswer) {
        guard let waiting = pending.removeValue(forKey: call.request) else { return }
        if call.request == Self.allowlistTool {
            switch answer {
            case .allow, .always:
                approve((tool.repositoryAllowlist?(worktree) ?? []))
                do { try launch(queue.isEmpty ? "" : queue.removeFirst()) } catch {
                    finish(summary: "\(tool.name) didn't start: \(error.localizedDescription)", failed: true)
                }
            case .deny:
                finish(summary: "\(tool.name) didn't start: this repository's \(tool.name) allowlist lets commands through without asking Oby, and you didn't allow that.", failed: true)
            }
            return
        }
        guard let server else { return }
        if waiting.plan {
            server.reply(waiting.id, ACPRPC.plan(answer))
            if case .deny = answer { return }
            // Approved while the tool plans: it works on once its turn ends, in its agent mode.
            goAhead = applied == tool.planMode
            return
        }
        let reply = ACPRPC.answer(answer, options: waiting.options)
        server.reply(waiting.id, reply.result)
        if let why = reply.said { declined.append("Oby declined \(waiting.title): \(why)") }
    }

    // MARK: Messages

    private func handle(_ message: [String: Any]) {
        if message["id"] != nil, message["method"] != nil { return request(message) }
        if let text = ACPRPC.chunk(message) {
            current += text
            return
        }
        // A tool call ends the message before it: that one is what the agent said last.
        if ACPRPC.startsToolCall(message), !current.isEmpty {
            before = current
            current = ""
        }
        for event in ACPRPC.events(message, tools: &tools) { onEvent(event) }
    }

    /// A request the tool waits on: every one is answered, or the tool hangs.
    private func request(_ message: [String: Any]) {
        guard let server, let id = message["id"] else { return }
        switch ACPRPC.incoming(message) {
        case .permission:
            guard let kept = ACPRPC.resolved(message, tools: tools) else { return server.refuse(id) }
            let call = ACPRPC.toolCall(kept, request: ACPRPC.key(message))
            let options = ACPRPC.options(message)
            let title = kept.title ?? call.tool
            // Policy's fixed denials first, in every mode; then the job's mode and the user's rules (Desk).
            if let denied = ACPRPC.denial(call, worktree: worktree, background: kept.background) {
                Logger.jobs.notice("denied \(call.tool, privacy: .public): \(denied, privacy: .public)")
                server.reply(id, ACPRPC.answer(.deny(denied), options: options).result)
                declined.append("Oby declined \(title): \(denied)")
                onEvent(.permission(denied: denied))
                return
            }
            pending[call.request] = Pending(id: id, options: options, plan: false, title: title)
            onEvent(.ask(call))
        case .plan:
            let call = ACPRPC.plan(message)
            pending[call.request] = Pending(id: id, options: [], plan: true, title: "its plan")
            onEvent(.ask(call))
        case .question:
            server.reply(id, ACPRPC.skipped())
        case .other:
            server.refuse(id)
        }
    }

    /// The process ended: with a turn's result it's finished, else it was cut off mid-turn.
    private func exited() {
        Task {
            let how = await server?.exit() ?? "unknown"
            let job = worktree.lastPathComponent
            guard let result, !prompting else {
                Logger.jobs.error("job \(job, privacy: .public): \(self.tool.name, privacy: .public) ended mid-turn, \(how, privacy: .public)")
                return finish(event: .cutOff(summary: "\(tool.name) stopped without finishing (\(how))."))
            }
            Logger.jobs.notice("job \(job, privacy: .public): \(self.tool.name, privacy: .public) ended, \(how, privacy: .public)")
            finish(event: .finished(summary: result.summary, failed: result.failed))
        }
    }

    private func finish(summary: String, failed: Bool) { finish(event: .finished(summary: summary, failed: failed)) }

    private func finish(event: AgentEvent) {
        guard !finished else { return }
        finished = true
        onEvent(event)
    }
}
