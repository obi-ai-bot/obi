import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// OpenAI's Codex CLI through `codex app-server` (proven 2026-10-09). It works in Codex's own
/// sandbox, which lets it write only in the worktree; anything more comes to Oby as an approval.
final class CodexAgent: AgentRun {
    private let worktree: URL
    /// The account's own `CODEX_HOME`, or nil for Codex's default `~/.codex`.
    private let home: URL?
    private var server: CodexServer?
    private var thread: String?
    private var turn: String?
    /// The files each file change writes: Codex's approval request names only the change.
    private var files: [String: [String]] = [:]
    private var onEvent: (AgentEvent) -> Void = { _ in }
    private var finished = false

    init(worktree: URL, home: URL?) {
        self.worktree = worktree
        self.home = home
    }

    func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
        self.onEvent = onEvent
        let log = worktree.appending(path: ".oby/agent.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let server = try CodexServer(home: home, in: worktree, log: log)
        self.server = server
        server.onMessage = { [weak self] in self?.handle($0) }
        server.onExit = { [weak self] in self?.finish(summary: "Codex stopped without finishing.", failed: true) }

        Task {
            do {
                try await server.initialize()
                let git = await Self.gitDirectory(worktree)
                let started = try await server.call("thread/start", CodexRPC.threadStart(worktree: worktree, git: git))
                guard let thread = (started["thread"] as? [String: Any])?["id"] as? String else {
                    throw Shell.Failure(message: "Codex didn't start a thread.")
                }
                self.thread = thread
                onEvent(.session(thread))
                let turn = try await server.call("turn/start", CodexRPC.turnStart(thread: thread, prompt: prompt,
                                                                                 model: AgentModels.value("codex", "model"),
                                                                                 effort: AgentModels.value("codex", "effort")))
                self.turn = (turn["turn"] as? [String: Any])?["id"] as? String
            } catch {
                finish(summary: "Codex couldn't start: \(error.localizedDescription)", failed: true)
                server.end()
            }
        }
    }

    func stop() {
        guard let server, server.isRunning else { return }
        if let thread, let turn {
            Task { _ = try? await server.call("turn/interrupt", ["threadId": thread, "turnId": turn]) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { server.kill() }
    }

    func kill() {
        server?.kill()
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] {
            answer(id, message)
            return
        }
        if let (item, paths) = CodexRPC.changes(message) { files[item] = paths }
        // Helpers Codex starts run in threads of their own: only this job's thread reports.
        let params = message["params"] as? [String: Any] ?? [:]
        if let other = params["threadId"] as? String, let thread, other != thread { return }
        for event in CodexRPC.events(message) {
            if case let .finished(summary, failed) = event {
                // One task per job for now: the server ends with the turn.
                server?.end()
                finish(summary: summary, failed: failed)
            } else {
                onEvent(event)
            }
        }
    }

    private func answer(_ id: Any, _ request: [String: Any]) {
        guard let server else { return }
        switch CodexRPC.answer(request, files: files, worktree: worktree) {
        case .accept:
            server.reply(id, ["decision": "accept"])
        case let .decline(reason):
            Logger.jobs.notice("declined \(request["method"] as? String ?? "", privacy: .public): \(reason, privacy: .public)")
            server.reply(id, ["decision": "decline"])
            // The decision has no room for a reason, so it reaches Codex as a word from Oby.
            let params = request["params"] as? [String: Any] ?? [:]
            if let thread = params["threadId"] as? String, let turn = params["turnId"] as? String {
                let input = [CodexRPC.text("Oby declined that: \(reason)")]
                Task { _ = try? await server.call("turn/steer", ["threadId": thread, "expectedTurnId": turn, "input": input]) }
            }
        case nil:
            // Questions, forms and logins are the user's to answer, not Oby's.
            server.refuse(id)
        }
    }

    private func finish(summary: String, failed: Bool) {
        guard !finished else { return }
        finished = true
        onEvent(.finished(summary: summary, failed: failed))
    }

    /// Where the worktree's git data lives: in Oby's clone, outside the worktree.
    static func gitDirectory(_ worktree: URL) async -> String? {
        try? await Shell.ok(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], in: worktree)
    }

    /// The account's label, like "Plus · name@example.com", or nil when it's signed out.
    static func account(home: URL?) async throws -> String? {
        CodexRPC.account(try await ask(home: home, "account/read"))
    }

    /// How much of the account's limits is used, 0...1.
    static func usage(home: URL?) async throws -> (fiveHour: Double?, sevenDay: Double?) {
        let result = try await ask(home: home, "account/rateLimits/read")
        return (result["rateLimits"] as? [String: Any]).flatMap(CodexRPC.usage) ?? (nil, nil)
    }

    /// The models the account offers, with the efforts each takes.
    static func models(home: URL?) async throws -> [CodexModel] {
        CodexRPC.models(try await ask(home: home, "model/list"))
    }

    /// Starts a short-lived app-server, asks it one thing, and ends it.
    private static func ask(home: URL?, _ method: String) async throws -> [String: Any] {
        let server = try CodexServer(home: home, in: nil, log: nil)
        defer { server.end() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { server.kill() }
        try await server.initialize()
        return try await server.call(method, [:])
    }
}

/// One `codex app-server` process speaking JSON-RPC over stdio. Answers come back to `call`;
/// notifications and the server's own requests go to `onMessage`.
final class CodexServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onExit: () -> Void = {}
    var isRunning: Bool { process.isRunning }

    init(home: URL?, in directory: URL?, log: URL?) throws {
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["codex", "app-server"]
        process.currentDirectoryURL = directory
        process.environment = Agents.environment(["CODEX_HOME": home?.path])
        process.standardInput = input
        process.standardOutput = output
        process.standardError = log.flatMap { try? FileHandle(forWritingTo: $0) } ?? FileHandle.nullDevice
        try process.run()
        Task { await read() }
    }

    func initialize() async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        _ = try await call("initialize", ["clientInfo": ["name": "oby", "title": "Oby", "version": version]])
        send(["method": "initialized"])
    }

    func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            send(["id": id, "method": method, "params": params])
        }
    }

    func reply(_ id: Any, _ result: [String: Any]) {
        send(["id": id, "result": result])
    }

    func refuse(_ id: Any) {
        send(["id": id, "error": ["code": -32601, "message": "Oby doesn't answer this request."]])
    }

    /// Closing stdin ends the server.
    func end() {
        try? input.fileHandleForWriting.close()
    }

    func kill() {
        if process.isRunning { process.terminate() }
    }

    private func read() async {
        do {
            try await eachLine(of: output.fileHandleForReading, receive)
        } catch {
            Logger.jobs.error("reading Codex failed: \(error.localizedDescription, privacy: .public)")
        }
        for continuation in waiting.values { continuation.resume(throwing: Shell.Failure(message: "Codex stopped.")) }
        waiting = [:]
        onExit()
    }

    private func receive(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if message["method"] != nil { return onMessage(message) }
        guard let id = message["id"] as? Int, let continuation = waiting.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: Shell.Failure(message: error["message"] as? String ?? "Codex refused."))
        } else {
            continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }

    private func send(_ message: [String: Any]) {
        guard process.isRunning, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }
}

/// A model a Codex account offers.
nonisolated struct CodexModel: Equatable, Sendable {
    var id: String
    var name: String
    var efforts: [String]
}

/// Reads what `codex app-server` sends.
nonisolated enum CodexRPC {
    enum Answer: Equatable { case accept, decline(String) }

    /// Codex's own sandbox, workspace-write: it writes only in the worktree and in the clone's git
    /// data (so commits stay sandboxed), with no network. Escalations go to the user, which is Oby,
    /// rather than to Codex's reviewer agent. Without the git directory, plain workspace-write.
    static func threadStart(worktree: URL, git: String?) -> [String: Any] {
        var params: [String: Any] = ["cwd": worktree.path, "sandbox": "workspace-write",
                                     "approvalPolicy": "on-request", "approvalsReviewer": "user"]
        if let git {
            params["config"] = ["sandbox_workspace_write": ["writable_roots": [git], "network_access": false]]
        }
        return params
    }

    /// The task, with the model and effort chosen in Settings › Models (empty means Codex's own default).
    static func turnStart(thread: String, prompt: String, model: String, effort: String) -> [String: Any] {
        var params: [String: Any] = ["threadId": thread, "input": [text(prompt)]]
        if !model.isEmpty { params["model"] = model }
        if !effort.isEmpty { params["effort"] = effort }
        return params
    }

    static func models(_ result: [String: Any]) -> [CodexModel] {
        (result["data"] as? [[String: Any]] ?? []).compactMap { model in
            guard let id = model["id"] as? String else { return nil }
            let efforts = (model["supportedReasoningEfforts"] as? [Any] ?? []).compactMap { effort in
                (effort as? String) ?? (effort as? [String: Any])?["reasoningEffort"] as? String
            }
            return CodexModel(id: id, name: model["displayName"] as? String ?? id, efforts: efforts)
        }
    }

    static func text(_ text: String) -> [String: Any] {
        ["type": "text", "text": text, "text_elements": [Any]()]
    }

    static func events(_ message: [String: Any]) -> [AgentEvent] {
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "item/started":
            return (params["item"] as? [String: Any]).flatMap(step).map { [.step($0)] } ?? []
        case "account/rateLimits/updated":
            return (params["rateLimits"] as? [String: Any]).flatMap(usage).map { [.usage(fiveHour: $0.fiveHour, sevenDay: $0.sevenDay)] } ?? []
        case "turn/completed":
            return [finished(params["turn"] as? [String: Any] ?? [:])]
        default:
            return []
        }
    }

    /// What Codex is doing, in the same words as Claude Code's steps.
    static func step(_ item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "commandExecution":
            let actions = item["commandActions"] as? [[String: Any]] ?? []
            if actions.count == 1, let action = actions.first {
                switch action["type"] as? String {
                case "read": return StreamJSON.step(tool: "Read", input: ["file_path": action["path"] ?? ""])
                case "search": return StreamJSON.step(tool: "Grep", input: action["query"].map { ["pattern": $0] } ?? [:])
                case "listFiles": return StreamJSON.step(tool: "Glob", input: [:])
                default: break
                }
            }
            return StreamJSON.step(tool: "Bash", input: ["command": command(item["command"] as? String ?? "")])
        case "fileChange":
            let paths = files(item)
            return paths.count == 1 ? StreamJSON.step(tool: "Edit", input: ["file_path": paths[0]]) : "Editing \(paths.count) files"
        case "mcpToolCall": return StreamJSON.step(tool: item["tool"] as? String ?? "a tool", input: [:])
        case "webSearch": return StreamJSON.step(tool: "WebSearch", input: [:])
        default: return nil
        }
    }

    /// The command without the shell Codex wraps it in: `/bin/zsh -lc 'git status'` is `git status`.
    static func command(_ command: String) -> String {
        guard let inner = command.wholeMatch(of: /\/\S+ -l?c '(.*)'/.dotMatchesNewlines())?.1 else { return command }
        return String(inner.replacing("'\\''", with: "'"))
    }

    /// The files a change writes, as the item started or as its patch was updated.
    static func changes(_ message: [String: Any]) -> (item: String, files: [String])? {
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "item/started":
            guard let item = params["item"] as? [String: Any], item["type"] as? String == "fileChange",
                  let id = item["id"] as? String else { return nil }
            return (id, files(item))
        case "item/fileChange/patchUpdated":
            guard let id = params["itemId"] as? String else { return nil }
            return (id, files(params))
        default:
            return nil
        }
    }

    static func files(_ change: [String: Any]) -> [String] {
        (change["changes"] as? [[String: Any]] ?? []).flatMap { change in
            [change["path"] as? String, (change["kind"] as? [String: Any])?["move_path"] as? String].compactMap { $0 }
        }
    }

    /// Oby's answer to an approval request, through Policy like Claude Code's permission prompts;
    /// nil for requests that aren't approvals.
    static func answer(_ request: [String: Any], files: [String: [String]], worktree: URL) -> Answer? {
        let params = request["params"] as? [String: Any] ?? [:]
        let calls: [(tool: String, input: [String: Any])]
        switch request["method"] as? String {
        case "item/commandExecution/requestApproval":
            guard let command = params["command"] as? String else { return .decline("Oby couldn't see the command.") }
            calls = [("Bash", ["command": command])]
        case "item/fileChange/requestApproval":
            guard let paths = (params["itemId"] as? String).flatMap({ files[$0] }) else {
                return .decline("Oby couldn't see which files this change writes.")
            }
            calls = (paths + [params["grantRoot"] as? String].compactMap { $0 }).map { ("Edit", ["file_path": $0]) }
        default:
            return nil
        }
        return calls.lazy.compactMap { Policy.deny(tool: $0.tool, input: $0.input, worktree: worktree) }.first.map(Answer.decline) ?? .accept
    }

    static func finished(_ turn: [String: Any]) -> AgentEvent {
        let failed = turn["status"] as? String != "completed"
        let items = turn["items"] as? [[String: Any]] ?? []
        if let said = items.last(where: { $0["type"] as? String == "agentMessage" })?["text"] as? String, !said.isEmpty {
            return .finished(summary: said, failed: failed)
        }
        guard failed else { return .finished(summary: "Done.", failed: false) }
        if turn["status"] as? String == "interrupted" { return .finished(summary: "Stopped.", failed: true) }
        // The API's own error arrives as JSON inside the message.
        let message = (turn["error"] as? [String: Any])?["message"] as? String ?? ""
        let api = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any]
        let reason = (api?["error"] as? [String: Any])?["message"] as? String ?? message
        return .finished(summary: reason.isEmpty ? "Codex hit an error." : "Codex hit an error: \(reason)", failed: true)
    }

    /// The five-hour and weekly windows of Codex's own limit, 0...1.
    static func usage(_ limits: [String: Any]) -> (fiveHour: Double?, sevenDay: Double?)? {
        // Other limits (like a model's reserve) arrive with their own id and say nothing about Codex's.
        guard (limits["limitId"] as? String ?? "codex") == "codex" else { return nil }
        var used: [Int: Double] = [:]
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any], let minutes = window["windowDurationMins"] as? Int,
                  let percent = window["usedPercent"] as? Double else { continue }
            used[minutes] = percent / 100
        }
        return used.isEmpty ? nil : (used[300], used[10_080])
    }

    static func account(_ result: [String: Any]) -> String? {
        guard let account = result["account"] as? [String: Any] else { return nil }
        switch account["type"] as? String {
        case "chatgpt":
            let plan = (account["planType"] as? String).flatMap { $0 == "unknown" ? nil : $0.replacing("_", with: " ").capitalized }
            let label = [plan, account["email"] as? String].compactMap { $0 }.joined(separator: " · ")
            return label.isEmpty ? "ChatGPT" : label
        case "apiKey": return "API key"
        case "amazonBedrock": return "Amazon Bedrock"
        default: return account["type"] as? String ?? "Signed in"
        }
    }
}
