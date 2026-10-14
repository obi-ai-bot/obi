import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// OpenAI's Codex CLI through `codex app-server` (proven 2026-10-09). It works in Codex's own
/// sandbox, which lets it write only in the worktree; anything more comes to Oby as an approval.
final class CodexAgent: AgentRun {
    private let worktree: URL
    private let kind: Plan.Kind
    private let reading: [String]
    /// The account's own `CODEX_HOME`, or nil for Codex's default `~/.codex`.
    private let home: URL?
    private var server: CodexServer?
    private var thread: String?
    /// The turn under way, or nil between turns.
    private var turn: String?
    /// The thread to pick up again, or nil for a new one.
    private let resume: String?
    /// The files each file change writes: Codex's approval request names only the change.
    private var files: [String: [String]] = [:]
    private var onEvent: (AgentEvent) -> Void = { _ in }
    private var finished = false
    /// The latest turn's result: the job ends when the server does.
    private var result: (summary: String, failed: Bool)?
    /// This job's model, or nil for Settings › Models.
    var model: String?
    var effort: String?
    /// The broker's endpoint for this job (Engine/Connected.swift), or nil when nothing is connected.
    var mcp: AgentMCP?
    /// The job's mode: the thread starts with its sandbox and approvals, and a turn after a change
    /// carries the new ones.
    var mode = PermissionMode.bypass
    /// The mode the thread started with.
    private var started = PermissionMode.bypass
    private var git: String?
    /// Approvals waiting for an answer, by request id: the JSON-RPC id to answer, and the turn to
    /// tell why it was declined.
    private var pending: [String: (id: Any, thread: String?, turn: String?)] = [:]

    init(worktree: URL, home: URL?, resume: String? = nil, kind: Plan.Kind = .build, reading: [String] = []) {
        self.worktree = worktree
        self.home = home
        self.resume = resume
        self.kind = kind
        self.reading = reading
    }

    func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
        self.onEvent = onEvent
        let log = worktree.appending(path: ".oby/agent.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let server = try CodexServer(home: home, in: worktree, log: log, mcp: mcp, reading: reading, research: kind == .research)
        self.server = server
        server.onMessage = { [weak self] in self?.handle($0) }
        server.onExit = { [weak self] in
            self?.finish(summary: self?.result?.summary ?? "Codex stopped without finishing.", failed: self?.result?.failed ?? true)
        }

        Task {
            do {
                try await server.initialize()
                let git = await Self.gitDirectory(worktree)
                self.git = git
                self.started = mode
                let started = if let resume {
                    try await server.call("thread/resume", CodexRPC.threadResume(thread: resume, worktree: worktree, git: git, mode: mode, research: kind == .research))
                } else {
                    try await server.call("thread/start", CodexRPC.threadStart(worktree: worktree, git: git, mode: mode, research: kind == .research))
                }
                guard let thread = (started["thread"] as? [String: Any])?["id"] as? String else {
                    throw Shell.Failure(message: "Codex didn't start a thread.")
                }
                self.thread = thread
                onEvent(.session(thread))
                // Whether Tetrix is connected (Engine/TetrixUse.swift), alongside the turn: an older Codex doesn't say.
                Task { if let on = (try? await server.call("mcpServerStatus/list", [:])).flatMap(TetrixUse.codexStatus) { onEvent(.tetrix(.connected(on))) } }
                let turn = try await server.call("turn/start", CodexRPC.turnStart(thread: thread, prompt: prompt,
                                                                                 model: model ?? AgentModels.value("codex", "model"),
                                                                                 effort: effort ?? AgentModels.value("codex", "effort")))
                self.turn = (turn["turn"] as? [String: Any])?["id"] as? String
            } catch {
                finish(summary: "Codex couldn't start: \(error.localizedDescription)", failed: true)
                server.end()
            }
        }
    }

    /// While a turn runs, the words join it; between turns they start the next one.
    // ponytail: a steer that crosses its turn's end falls back to a new turn, but the ended turn
    // has already reported; count steers in flight if that window ever bites.
    func send(_ text: String) {
        guard let server, let thread else { return }
        Task {
            if let turn, (try? await server.call("turn/steer", CodexRPC.steer(thread: thread, turn: turn, text: text))) != nil { return }
            var params = CodexRPC.turnStart(thread: thread, prompt: text, model: model ?? AgentModels.value("codex", "model"),
                                            effort: effort ?? AgentModels.value("codex", "effort"))
            // The mode changed since the thread started (a plan approved): this turn runs with the new one.
            if mode != started { params.merge(CodexRPC.turnOverrides(mode: mode, git: git, research: kind == .research)) { $1 } }
            let turn = try? await server.call("turn/start", params)
            self.turn = (turn?["turn"] as? [String: Any])?["id"] as? String
        }
    }

    /// Closing stdin ends the server, and with it the job.
    func end() {
        server?.end()
    }

    func stop() {
        guard let server, server.isRunning else { return }
        if let thread, let turn {
            Task { _ = try? await server.call("turn/interrupt", ["threadId": thread, "turnId": turn]) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Halt.grace) { server.halt() }
    }

    func kill() {
        server?.kill()
    }

    func ended() async {
        await server?.ended()
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
            switch event {
            case let .finished(summary, failed):
                // The turn's result. Desk decides whether another round follows.
                result = (summary, failed)
                turn = nil
                onEvent(.turnEnded(summary: summary, failed: failed))
            case .limit:
                // The turn died on the account's limit: Desk moves the job to another account.
                turn = nil
                onEvent(event)
            default:
                onEvent(event)
            }
        }
    }

    /// The job's mode changed: the next turn runs with it.
    func setMode(_ mode: PermissionMode) {
        self.mode = mode
    }

    /// Oby's answer, or the user's: accept (an always too: `acceptForSession` would let the same
    /// command through without asking Oby, past the user's deny rules; Oby's saved rule answers
    /// it instead), or decline, with why as a word to the turn.
    func answer(_ call: ToolCall, _ answer: ToolAnswer) {
        guard let server, let (id, thread, turn) = pending.removeValue(forKey: call.request) else { return }
        switch answer {
        case .allow, .always: server.reply(id, ["decision": "accept"])
        case .deny(let reason):
            server.reply(id, ["decision": "decline"])
            if let thread, let turn {
                Task { _ = try? await server.call("turn/steer", CodexRPC.steer(thread: thread, turn: turn, text: "Declined: \(reason)")) }
            }
        }
    }

    private func answer(_ id: Any, _ request: [String: Any]) {
        guard let server else { return }
        switch CodexRPC.answer(request, files: files, worktree: worktree, kind: kind) {
        case .accept:
            // Policy lets it through: the job's mode and the user's rules decide (Desk).
            guard let call = CodexRPC.call(request, files: files) else { return server.reply(id, ["decision": "accept"]) }
            let params = request["params"] as? [String: Any] ?? [:]
            pending[call.request] = (id, params["threadId"] as? String, params["turnId"] as? String)
            onEvent(.ask(call))
        case let .decline(reason):
            Logger.jobs.notice("declined \(request["method"] as? String ?? "", privacy: .public): \(reason, privacy: .public)")
            server.reply(id, ["decision": "decline"])
            onEvent(.permission(denied: reason))
            // The decision has no room for a reason, so it reaches Codex as a word from Oby.
            let params = request["params"] as? [String: Any] ?? [:]
            if let thread = params["threadId"] as? String, let turn = params["turnId"] as? String {
                Task { _ = try? await server.call("turn/steer", CodexRPC.steer(thread: thread, turn: turn, text: "Oby declined that: \(reason)")) }
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

    /// How much of the account's limits is used, 0...1, and when each window resets.
    static func usage(home: URL?) async throws -> CodexRPC.Usage {
        let result = try await ask(home: home, "account/rateLimits/read")
        return (result["rateLimits"] as? [String: Any]).flatMap(CodexRPC.usage) ?? CodexRPC.Usage()
    }

    /// Whether the account's Codex has Tetrix's MCP server connected, or nil when it doesn't say.
    static func tetrix(home: URL?) async throws -> Bool? {
        TetrixUse.codexStatus(try await ask(home: home, "mcpServerStatus/list"))
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
    private var group: ProcessGroup?
    private let input = Pipe()
    private let output = Pipe()
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onExit: () -> Void = {}
    var isRunning: Bool { process.isRunning }

    /// `mcp`: the broker, as Codex's `oby` MCP server, its token in the environment.
    init(home: URL?, in directory: URL?, log: URL?, mcp: AgentMCP? = nil, reading: [String] = [], research: Bool = false) throws {
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = Agents.sandboxed(Agents.niced(["codex"] + (mcp?.codexArguments ?? []) + ["app-server"]), in: directory, own: home?.path ?? "\(Agents.home)/.codex", reading: reading, research: research)
        process.currentDirectoryURL = directory
        process.environment = try Agents.environment(AppleCheck.environment(worktree: directory)
            .merging(directory.map { Agents.swiftEnvironment(worktree: $0) } ?? [:]) { $1 }
            .merging(["CODEX_HOME": home?.path, AgentMCP.tokenVariable: mcp?.token]) { $1 })
        process.standardInput = input
        process.standardOutput = output
        process.standardError = log.flatMap { try? FileHandle(forWritingTo: $0) } ?? FileHandle.nullDevice
        group = try ProcessGroup.run(process)
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

    /// Ends it, with whatever it started (`Halt`).
    func kill() {
        group?.end(after: Halt.dropping)
    }

    /// Ends it now, with whatever it started: Stop's 2 seconds.
    func halt() {
        group?.end(after: Halt.stopping)
    }

    /// Returns once it has ended.
    func ended() async {
        await group?.ended()
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
    /// On Linux, Oby's bubblewrap is the sandbox: Codex's own is bubblewrap too and can't run inside it
    /// (Ubuntu's AppArmor denies it), so Codex runs none and asks Oby about every command instead.
    /// Modes (#134): Bypass is the above. Ask and Accept edits keep the sandbox but approve nothing
    /// by themselves (`untrusted`: every command that isn't a known read, and every file change,
    /// comes to Oby). Plan runs read-only and untrusted, for a plan-only turn. On Linux every mode
    /// is untrusted already, and Oby refuses edits in Plan itself.
    static func threadStart(worktree: URL, git: String?, bubblewrap: Bool = Agents.bubblewrap, mode: PermissionMode = .bypass, research: Bool = false) -> [String: Any] {
        // Proven in `codex app-server generate-json-schema --experimental`: Config.web_search is
        // a nullable WebSearchMode (`disabled`, `cached`, `indexed`, `live`). Search is model-side;
        // the Mac's sandbox remains network-disabled.
        let web: [String: Any] = research ? ["web_search": "live"] : [:]
        if bubblewrap {
            var params: [String: Any] = ["cwd": worktree.path, "sandbox": "danger-full-access", "approvalPolicy": "untrusted", "approvalsReviewer": "user"]
            if !web.isEmpty { params["config"] = web }
            return params
        }
        if research {
            var params: [String: Any] = ["cwd": worktree.path, "sandbox": "read-only", "approvalPolicy": "untrusted", "approvalsReviewer": "user"]
            if !web.isEmpty { params["config"] = web }
            return params
        }
        if mode == .plan {
            var params: [String: Any] = ["cwd": worktree.path, "sandbox": "read-only", "approvalPolicy": "untrusted", "approvalsReviewer": "user"]
            if !web.isEmpty { params["config"] = web }
            return params
        }
        var params: [String: Any] = ["cwd": worktree.path, "sandbox": "workspace-write",
                                     "approvalPolicy": mode == .bypass ? "on-request" : "untrusted", "approvalsReviewer": "user"]
        var config = web
        if let git { config["sandbox_workspace_write"] = ["writable_roots": [git], "network_access": false] }
        if !config.isEmpty { params["config"] = config }
        return params
    }

    /// A thread Codex already has, in the same sandbox: Oby picks it up again to talk to a finished job.
    static func threadResume(thread: String, worktree: URL, git: String?, mode: PermissionMode = .bypass, research: Bool = false) -> [String: Any] {
        threadStart(worktree: worktree, git: git, mode: mode, research: research).merging(["threadId": thread]) { $1 }
    }

    /// What a turn carries when the job's mode changed since its thread started: the mode's
    /// approvals and sandbox, as `threadStart` would set them.
    // ponytail: turn/start's sandboxPolicy shape is from app-server's v2 protocol, not yet proven against a real Codex.
    static func turnOverrides(mode: PermissionMode, git: String?, bubblewrap: Bool = Agents.bubblewrap, research: Bool = false) -> [String: Any] {
        if bubblewrap { return ["approvalPolicy": "untrusted", "sandboxPolicy": ["type": "dangerFullAccess"]] }
        if research { return ["approvalPolicy": "untrusted", "sandboxPolicy": ["type": "readOnly"]] }
        if mode == .plan { return ["approvalPolicy": "untrusted", "sandboxPolicy": ["type": "readOnly"]] }
        return ["approvalPolicy": mode == .bypass ? "on-request" : "untrusted",
                "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": git.map { [$0] } ?? [], "networkAccess": false]]
    }

    /// Words for the turn under way; Codex refuses them once that turn has ended.
    static func steer(thread: String, turn: String, text: String) -> [String: Any] {
        ["threadId": thread, "expectedTurnId": turn, "input": [Self.text(text)]]
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
            let item = params["item"] as? [String: Any] ?? [:]
            let tetrix = item["type"] as? String == "mcpToolCall"
                ? TetrixUse.tool(server: item["server"] as? String ?? "", tool: item["tool"] as? String ?? "").map { [AgentEvent.tetrix(.call($0))] } : nil
            return (step(item).map { [.step($0)] } ?? []) + (tetrix ?? [])
        case "account/rateLimits/updated":
            return (params["rateLimits"] as? [String: Any]).flatMap(usage).map { [$0.event] } ?? []
        case "turn/completed":
            let ended = finished(params["turn"] as? [String: Any] ?? [:])
            // "You've hit your usage limit. Try again at 10:45 PM.": the account is full, not the work wrong.
            if case let .finished(summary, true) = ended, Limits.isLimit(summary) { return [.limit(resets: Limits.reset(in: summary))] }
            return [ended]
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
    static func answer(_ request: [String: Any], files: [String: [String]], worktree: URL, kind: Plan.Kind? = nil) -> Answer? {
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
        return calls.lazy.compactMap { Policy.deny(tool: $0.tool, input: $0.input, worktree: worktree, kind: kind) }.first.map(Answer.decline) ?? .accept
    }

    /// An approval request as a tool call, for the job's mode and the user's rules: a command is
    /// "Bash" (without the shell Codex wraps it in), a file change "Edit".
    static func call(_ request: [String: Any], files: [String: [String]]) -> ToolCall? {
        let params = request["params"] as? [String: Any] ?? [:]
        let key = (request["id"] as? Int).map(String.init) ?? request["id"] as? String ?? UUID().uuidString
        switch request["method"] as? String {
        case "item/commandExecution/requestApproval":
            return (params["command"] as? String).map { ToolCall(request: key, tool: "Bash", command: command($0)) }
        case "item/fileChange/requestApproval":
            let paths = (params["itemId"] as? String).flatMap { files[$0] } ?? []
            return ToolCall(request: key, tool: "Edit", paths: paths + [params["grantRoot"] as? String].compactMap { $0 })
        default:
            return nil
        }
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

    /// The five-hour and weekly windows of Codex's own limit, 0...1, and when each resets.
    nonisolated struct Usage: Equatable, Sendable {
        var fiveHour: Double?
        var sevenDay: Double?
        var fiveHourResets: Date?
        var sevenDayResets: Date?

        var event: AgentEvent {
            .usage(fiveHour: fiveHour, sevenDay: sevenDay, fiveHourResets: fiveHourResets, sevenDayResets: sevenDayResets)
        }
    }

    /// Codex's own limit from `account/rateLimits/read` or an `account/rateLimits/updated` notification.
    static func usage(_ limits: [String: Any]) -> Usage? {
        // Other limits (like a model's reserve) arrive with their own id and say nothing about Codex's.
        guard (limits["limitId"] as? String ?? "codex") == "codex" else { return nil }
        var used: [Int: (Double, Date?)] = [:]
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any], let minutes = window["windowDurationMins"] as? Int,
                  let percent = window["usedPercent"] as? Double else { continue }
            used[minutes] = (percent / 100, AgentEvent.epoch(window["resetsAt"]))
        }
        return used.isEmpty ? nil : Usage(fiveHour: used[300]?.0, sevenDay: used[10_080]?.0,
                                          fiveHourResets: used[300]?.1, sevenDayResets: used[10_080]?.1)
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
