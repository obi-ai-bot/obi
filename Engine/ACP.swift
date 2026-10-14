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

    /// A permission request as a tool call, for the job's mode and the user's rules. Reads what the
    /// call's own earlier messages said (`tools`) with what the request carries.
    static func call(_ request: [String: Any], tools: [String: ACPToolCall]) -> ToolCall? {
        guard request["method"] as? String == "session/request_permission" else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        let fields = params["toolCall"] as? [String: Any] ?? [:]
        var call = (fields["toolCallId"] as? String).flatMap { tools[$0] } ?? ACPToolCall(id: fields["toolCallId"] as? String ?? "")
        call.merge(fields)
        return toolCall(call, request: key(request))
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
