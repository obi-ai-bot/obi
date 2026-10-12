import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ObyEngine

/// The broker for connected apps (F17, #60): in the runner's own process, outside every agent's
/// sandbox. Each job's agent gets an MCP endpoint on 127.0.0.1 (`/v1/agent/mcp/{job}`) with a token
/// for that job only, which stops working when the job ends (Engine/Connected.swift). The broker
/// lists the connected servers' tools, each prefixed with its connection's name, and forwards the
/// calls it allows with the vault secret in the connection's header, like a password manager
/// filling the fields: the agent never sees the value, and every result has the vault's values
/// taken out, plain or encoded. Read-only tools (MCP's `readOnlyHint`) go through; tools that act
/// as the user (send, post, create, delete, pay) are refused until permission modes arrive (#134).
/// Every call goes in the job's report and the vault's use log.
// ponytail: every connection reaches every job; binding a connection to repos or kinds of job, and
// asking the user for writes, come with permission modes.
@MainActor
final class Broker {
    nonisolated static let acting = "Acting as you needs your OK, which arrives with permission modes."
    /// The MCP versions the broker speaks to agents, newest first.
    static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// The most of an API's answer an agent gets.
    static let longest = 256 * 1024

    let desk: Desk
    let connections: ConnectionStore
    let uses: UseLog
    /// The runner's API on this machine, like `http://127.0.0.1:7777`.
    let base: String
    /// Sends one request to a connected server, its secret attached, never following a redirect.
    /// Tests put in their own.
    var send: (URLRequest) async throws -> (Data, HTTPURLResponse) = Broker.fetch

    /// Each live token, and the job it's for.
    private var tokens: [String: String] = [:]
    /// The connections each job started with: a job uses one only while it's still the same,
    /// so one added or replaced since (by anyone reaching the API) never reaches a running job.
    private var snapshots: [String: [Connection]] = [:]
    /// What each job's agent has from each MCP connection, by "job/connection": the server's
    /// session, and its tools as it last listed them.
    private var upstreams: [String: Upstream] = [:]
    private var nextID = 0

    private struct Upstream {
        var session: String?
        var version: String?
        var tools: [String: [String: Any]]?
    }

    init(desk: Desk, connections: ConnectionStore, uses: UseLog, base: String) {
        self.desk = desk
        self.connections = connections
        self.uses = uses
        self.base = base
        desk.openBroker = { [weak self] job in self?.open(job.id) }
        desk.closeBroker = { [weak self] id in self?.close(id) }
    }

    // MARK: Tokens

    /// The endpoint for job `id`'s agent, with its token (the same one while the job runs), or nil
    /// when nothing is connected.
    func open(_ id: String) -> AgentMCP? {
        if snapshots[id] == nil { snapshots[id] = connections.all }
        guard !usable(id).isEmpty else { return nil }
        let token = tokens.first { $0.value == id }?.key ?? Self.newToken()
        tokens[token] = id
        return AgentMCP(url: "\(base)/v1/agent/mcp/\(id)", token: token)
    }

    /// Job `id` ended: its token is useless from now on, and its sessions are forgotten.
    func close(_ id: String) {
        tokens = tokens.filter { $0.value != id }
        snapshots[id] = nil
        upstreams = upstreams.filter { !$0.key.hasPrefix(id + "/") }
    }

    /// Whether `token` is job `id`'s, and the job runs.
    func allows(_ token: String, job id: String) -> Bool {
        !token.isEmpty && tokens[token] == id && desk.job(id)?.isActive == true
    }

    /// The connections job `id` may use: the ones it started with that are still there, unchanged.
    func usable(_ id: String) -> [Connection] {
        (snapshots[id] ?? []).filter(connections.all.contains)
    }

    private static func newToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacing("-", with: "").lowercased()
    }

    // MARK: The agent's side

    /// One JSON-RPC message from job `id`'s agent, and the answer, or nil for a notification.
    func handle(_ body: Data, job id: String) async -> [String: Any]? {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any], message["method"] is String else {
            return ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Oby's broker takes one JSON-RPC message at a time."]]
        }
        guard let rpcID = message["id"], !(rpcID is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch message["method"] as? String {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            result = ["protocolVersion": Self.versions.contains(asked) ? asked : Self.versions[0],
                      "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": AgentMCP.server, "version": API.version],
                      "instructions": "Your user's connected apps, through Oby: Oby holds each login and you get results only. Tools are named <connection>_<tool>. Read-only tools work; tools that act as the user (send, post, create, delete, pay) are refused for now."]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": await tools(job: id)]
        case "tools/call":
            result = await call(params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:], job: id)
        default:
            return ["jsonrpc": "2.0", "id": rpcID, "error": ["code": -32601, "message": "Oby's broker doesn't answer \(message["method"] as? String ?? "that")."]]
        }
        return ["jsonrpc": "2.0", "id": rpcID, "result": clean(result)]
    }

    /// Every connection's tools, named `<connection>_<tool>`. A server that can't be reached is
    /// left out, and the log says why.
    private func tools(job id: String) async -> [[String: Any]] {
        var listed: [[String: Any]] = []
        for connection in usable(id) {
            if connection.api != nil {
                listed += Self.apiTools(connection)
                continue
            }
            do {
                for (name, tool) in try await upstreamTools(connection, job: id).sorted(by: { $0.key < $1.key }) {
                    var tool = tool
                    let write = Self.access(name, tool) == .write
                    tool["name"] = "\(connection.name)_\(name)"
                    tool["description"] = "\(connection.name) (through Oby): " + (tool["description"] as? String ?? name)
                        + (write ? " Acts as the user, so Oby refuses it for now." : "")
                    listed.append(tool)
                }
            } catch {
                Logger.runner.error("job \(id, privacy: .public): can't list \(connection.name, privacy: .public)'s tools: \(error.localizedDescription, privacy: .public)")
            }
        }
        return listed
    }

    /// One tool call: refused when it acts as the user, else forwarded with the secret attached.
    /// Either way it goes in the job's report and the vault's use log.
    private func call(_ name: String, arguments: [String: Any], job id: String) async -> [String: Any] {
        guard let connection = usable(id).filter({ name.hasPrefix($0.name + "_") }).max(by: { $0.name.count < $1.name.count }) else {
            return Self.failure("There's no connected app with a tool named \(name).")
        }
        let tool = String(name.dropFirst(connection.name.count + 1))
        let access: ConnectionUse.Access
        if connection.api != nil {
            guard let found = Self.apiTools(connection).first(where: { $0["name"] as? String == name }) else {
                return Self.failure("\(connection.name) has no tool \(tool).")
            }
            access = Self.access(tool, found)
        } else {
            do {
                var tools = try await upstreamTools(connection, job: id)
                // A tool the server added since it last listed them.
                if tools[tool] == nil { tools = try await upstreamTools(connection, job: id, again: true) }
                guard let found = tools[tool] else { return Self.failure("\(connection.name) has no tool \(tool).") }
                access = Self.access(tool, found)
            } catch {
                return Self.failure("Oby couldn't reach \(connection.name): \(error.localizedDescription)")
            }
        }
        let use = ConnectionUse(job: id, connection: connection.name, tool: tool, access: access, allowed: access == .read,
                                secret: connection.secret, host: connection.host)
        record(use)
        guard access == .read else { return Self.failure(Self.acting) }
        do {
            if connection.api != nil { return try await get(connection, arguments) }
            return try await rpc(connection, job: id, "tools/call", ["name": tool, "arguments": arguments])
        } catch {
            return Self.failure("Oby couldn't reach \(connection.name): \(error.localizedDescription)")
        }
    }

    private func record(_ use: ConnectionUse) {
        Logger.runner.notice("job \(use.job, privacy: .public): \(use.line, privacy: .public), vault secret \(use.secret, privacy: .public), host \(use.host, privacy: .public)")
        desk.connectionUsed(use.job, use)
        uses.append(use)
    }

    /// Read or write: read only when the tool says it's read-only (MCP's `readOnlyHint`) and its
    /// name isn't one that acts (a server's hint is only a hint).
    static func access(_ name: String, _ tool: [String: Any]) -> ConnectionUse.Access {
        let hints = tool["annotations"] as? [String: Any] ?? [:]
        let words = name.replacing(/([a-z0-9])([A-Z])/) { "\($0.1)_\($0.2)" }.lowercased().split(whereSeparator: { !$0.isLetter })
        let acts: Set<String> = ["send", "post", "create", "delete", "remove", "pay", "update", "write", "edit", "reply", "publish",
                                 "upload", "transfer", "invite", "archive", "merge", "comment", "put", "patch", "set", "add", "move"]
        let readOnly = hints["readOnlyHint"] as? Bool == true && hints["destructiveHint"] as? Bool != true
        return readOnly && !words.contains(where: { acts.contains(String($0)) }) ? .read : .write
    }

    static func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    /// `value` as it may reach an agent: every string in it (keys too) with the vault's values
    /// taken out, plain or encoded. When the vault can't be read, or a value is still in it as a
    /// whole, nothing of it goes.
    func clean(_ value: [String: Any]) -> [String: Any] {
        let refused = Self.failure("Oby can't show this: the vault can't be read, or the answer held a vault secret it couldn't take out.")
        guard let leaks = try? desk.vault.forAgents() else { return refused }
        func scrub(_ value: Any) -> Any {
            switch value {
            case let text as String: return leaks.redact(text)
            case let list as [Any]: return list.map(scrub)
            case let fields as [String: Any]: return Dictionary(fields.map { (leaks.redact($0.key), scrub($0.value)) }) { first, _ in first }
            default: return value
            }
        }
        guard let clean = scrub(value) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: clean, options: [.withoutEscapingSlashes]),
              leaks.hits(in: String(decoding: data, as: UTF8.self)).isEmpty else { return refused }
        return clean
    }

    // MARK: Connected MCP servers

    /// The server's tools by name, as it last listed them for this job, or listed now.
    private func upstreamTools(_ connection: Connection, job id: String, again: Bool = false) async throws -> [String: [String: Any]] {
        let key = "\(id)/\(connection.name)"
        if !again, let tools = upstreams[key]?.tools { return tools }
        var tools: [String: [String: Any]] = [:]
        var cursor: String?
        repeat {
            let page = try await rpc(connection, job: id, "tools/list", cursor.map { ["cursor": $0] } ?? [:])
            for tool in page["tools"] as? [[String: Any]] ?? [] {
                // Names an agent's tool list takes; anything else is left out.
                guard let name = tool["name"] as? String, name.wholeMatch(of: /[A-Za-z0-9_.-]{1,64}/) != nil else { continue }
                tools[name] = tool
            }
            cursor = page["nextCursor"] as? String
        } while cursor != nil && tools.count < 1000
        upstreams[key, default: Upstream()].tools = tools
        return tools
    }

    /// One request to the connected server for this job: its session is set up first, and again
    /// once when the server forgot it.
    private func rpc(_ connection: Connection, job id: String, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let key = "\(id)/\(connection.name)"
        if upstreams[key]?.version == nil { try await initialize(connection, key: key) }
        do {
            return try await post(connection, key: key, method, params) ?? [:]
        } catch is Expired {
            try await initialize(connection, key: key)
            return try await post(connection, key: key, method, params) ?? [:]
        }
    }

    private struct Expired: Error {}

    /// A new session with the server for this job. Until it succeeds, the next request tries again.
    private func initialize(_ connection: Connection, key: String) async throws {
        upstreams[key] = Upstream()
        do {
            let result = try await post(connection, key: key, "initialize",
                                        ["protocolVersion": Self.versions[0], "capabilities": [String: Any](),
                                         "clientInfo": ["name": "oby", "version": API.version]]) ?? [:]
            upstreams[key]?.version = result["protocolVersion"] as? String ?? Self.versions[0]
            _ = try await post(connection, key: key, "notifications/initialized", nil)
        } catch {
            upstreams[key]?.version = nil
            throw error
        }
    }

    /// Posts one message to the server, the secret in its header, and returns the answer's
    /// result (nil for a notification). Throws with the server's error, or how the request failed.
    private func post(_ connection: Connection, key: String, _ method: String, _ params: [String: Any]?) async throws -> [String: Any]? {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        let notification = method.hasPrefix("notifications/")
        nextID += 1
        let rpcID = nextID
        if !notification { message["id"] = rpcID }
        var request = URLRequest(url: connection.url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let session = upstreams[key]?.session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if method != "initialize", let version = upstreams[key]?.version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, response) = try await authorized(connection, request)
        if response.statusCode == 404, upstreams[key]?.session != nil { throw Expired() }
        try Self.check(response, connection)
        if method == "initialize", let session = response.value(forHTTPHeaderField: "Mcp-Session-Id") { upstreams[key]?.session = session }
        if notification { return nil }
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let answers = type.contains("text/event-stream") ? Self.events(data) : [data]
        for answer in answers {
            guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
                  (object["id"] as? Int) == rpcID || (object["id"] as? String) == String(rpcID) else { continue }
            if let error = object["error"] as? [String: Any] {
                throw Shell.Failure(message: "\(connection.name) said: \(error["message"] as? String ?? "an error").")
            }
            return object["result"] as? [String: Any] ?? [:]
        }
        throw Shell.Failure(message: "\(connection.name) didn't answer.")
    }

    /// The data of each Server-Sent Event in `data`.
    static func events(_ data: Data) -> [Data] {
        String(decoding: data, as: UTF8.self).replacing("\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { event in
            let lines = event.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5).drop { $0 == " " } }
            return lines.isEmpty ? nil : Data(lines.joined(separator: "\n").utf8)
        }
    }

    /// The request sent with the connection's secret in its header: read from the vault for this
    /// request alone, in this process, and never kept.
    private func authorized(_ connection: Connection, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        try desk.vault.use(connection.secret) { try connection.authorize(&request, with: $0) }
        return try await send(request)
    }

    /// Throws, saying why, for an answer that isn't a success. A redirect isn't followed: the
    /// secret is for the connection's host only.
    static func check(_ response: HTTPURLResponse, _ connection: Connection) throws {
        switch response.statusCode {
        case 200..<300: return
        case 300..<400: throw Shell.Failure(message: "\(connection.host) sent Oby elsewhere (HTTP \(response.statusCode)); the login stays with \(connection.host), so Oby doesn't follow.")
        case 401, 403: throw Shell.Failure(message: "\(connection.host) refused the login (HTTP \(response.statusCode)): the vault secret \(connection.secret) may be wrong or expired.")
        default: throw Shell.Failure(message: "\(connection.host) answered HTTP \(response.statusCode).")
        }
    }

    // MARK: Connected APIs

    /// An API's tools: `get` reads (GET, on the API's host only); `send` acts as the user, so it's
    /// refused for now.
    static func apiTools(_ connection: Connection) -> [[String: Any]] {
        let path: [String: Any] = ["type": "string", "description": "The path under \(connection.api ?? ""), starting with /, like /v1/me."]
        let query: [String: Any] = ["type": "object", "additionalProperties": ["type": "string"], "description": "Query parameters."]
        return [
            ["name": "\(connection.name)_get", "description": "\(connection.name) (through Oby): GET a path of \(connection.api ?? "") with the user's login. Answers with the status and the body.",
             "inputSchema": ["type": "object", "properties": ["path": path, "query": query], "required": ["path"]],
             "annotations": ["readOnlyHint": true]],
            ["name": "\(connection.name)_send", "description": "\(connection.name) (through Oby): POST, PUT, PATCH or DELETE as the user. Acts as the user, so Oby refuses it for now.",
             "inputSchema": ["type": "object", "properties": ["method": ["type": "string", "enum": ["POST", "PUT", "PATCH", "DELETE"]], "path": path,
                                                               "query": query, "body": ["type": "string"]], "required": ["method", "path"]],
             "annotations": ["readOnlyHint": false]],
        ]
    }

    /// A GET on the API's host, with its secret: the status and the body as text.
    private func get(_ connection: Connection, _ arguments: [String: Any]) async throws -> [String: Any] {
        guard let url = Self.url(connection, path: arguments["path"] as? String ?? "", query: arguments["query"] as? [String: Any] ?? [:]) else {
            return Self.failure("The path starts with / and stays on \(connection.host), like /v1/me.")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "GET"
        let (data, response) = try await authorized(connection, request)
        if (300..<400).contains(response.statusCode) { try Self.check(response, connection) }
        let body = data.count > Self.longest ? data.prefix(Self.longest) : data
        let text = String(data: body, encoding: .utf8) ?? "(\(data.count) bytes that aren't text)"
        return ["content": [["type": "text", "text": "HTTP \(response.statusCode)\n\n\(text)" + (data.count > Self.longest ? "\n\n(cut at \(Self.longest) bytes)" : "")]],
                "isError": response.statusCode >= 400]
    }

    /// `path` and `query` under the API's base URL, or nil when the path could leave its host.
    static func url(_ connection: Connection, path: String, query: [String: Any]) -> URL? {
        guard path.wholeMatch(of: /\/(?:[A-Za-z0-9\-._~!$&'()*+,;=:@\/]|%[0-9A-Fa-f]{2})*/) != nil, !path.hasPrefix("//"),
              var components = URLComponents(url: connection.url, resolvingAgainstBaseURL: false) else { return nil }
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + path
        let items = query.sorted { $0.key < $1.key }.compactMap { item in (item.value as? String).map { URLQueryItem(name: item.key, value: $0) } }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url, url.scheme == connection.url.scheme, url.host == connection.url.host, url.port == connection.url.port else { return nil }
        return url
    }

    // MARK: Sending

    /// No cookies, no cache, and no redirect followed.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    nonisolated static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Shell.Failure(message: "That wasn't an HTTP answer.") }
        return (data, http)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
