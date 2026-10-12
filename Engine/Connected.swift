import Foundation

/// Connected apps through the vault (F17, #60): the user's logged-in apps and APIs, used by
/// agents while the login stays in Oby, like a password manager filling the fields. On the
/// runner, a broker outside the agent's sandbox (Runner/Broker.swift) holds each connection's
/// secret, lists the connected servers' tools to the agent as one MCP server, `oby`, and forwards
/// the calls it allows with the secret attached. This side is what the engine needs: the agent's
/// MCP config, and the job's report of every call.
// ponytail: the runner only. The Mac app has no broker yet, and OAuth flows and website logins come later.

/// The broker's endpoint for one job's agent: a URL on 127.0.0.1 and a token for that job only,
/// which stops working when the job ends. Never a vault secret.
nonisolated struct AgentMCP: Equatable, Sendable {
    var url: String
    var token: String

    /// The server's name in the agent's MCP config: its tools are `mcp__oby__<connection>_<tool>`.
    static let server = "oby"
    /// Where Claude Code's config goes, in the worktree (`.oby/` is never committed).
    static let file = ".oby/mcp.json"
    /// The variable Codex reads the token from.
    static let tokenVariable = "OBY_MCP_TOKEN"

    /// Claude Code's `--mcp-config` file: the broker, as a Streamable HTTP server, with the job's token.
    var claudeConfig: Data {
        let config: [String: Any] = ["mcpServers": [Self.server: ["type": "http", "url": url, "headers": ["Authorization": "Bearer \(token)"]]]]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Writes `claudeConfig` into the worktree, readable only by the runner's user (other users
    /// would see an argument in `ps`), and returns its path.
    func writeClaudeConfig(in worktree: URL) throws -> String {
        let file = worktree.appending(path: Self.file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try claudeConfig.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file.path
    }

    /// Codex's config overrides for the broker, with the token in `tokenVariable`.
    // ponytail: not run against a real Codex yet; its MCP calls may also ask for approvals Oby refuses.
    var codexArguments: [String] {
        ["-c", "mcp_servers.\(Self.server).url=\"\(url)\"", "-c", "mcp_servers.\(Self.server).bearer_token_env_var=\"\(Self.tokenVariable)\""]
    }
}

/// One call an agent made to a connected app through the broker: in the job's report and the
/// vault's use log. Names only (the connection, the tool, the secret, the host), never a value.
nonisolated struct ConnectionUse: Codable, Equatable, Sendable {
    enum Access: String, Codable, Sendable { case read, write }

    var job: String
    var connection: String
    /// The tool as the connected server names it, without the connection's prefix.
    var tool: String
    var access: Access
    /// Oby forwarded it; false when it was refused (acting as the user).
    var allowed: Bool
    /// The vault secret the call used, by name, and the host it went to.
    var secret: String
    var host: String
    var date = Date.now

    /// One line of the report: "Read mail search (allowed)", "Write mail send_message (refused)".
    var line: String { "\(access == .read ? "Read" : "Write") \(connection) \(tool) (\(allowed ? "allowed" : "refused"))" }
}

extension Desk {
    /// An agent called a connected app: the job's report lists it, whatever state the job is in now.
    func connectionUsed(_ id: String, _ use: ConnectionUse) {
        guard var job = job(id) else { return }
        job.connectionUses = (job.connectionUses ?? []) + [use]
        replace(job)
    }
}
