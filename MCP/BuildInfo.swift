import Foundation

/// The commit this `oby-mcp` binary was built from (#385). Sent as `serverInfo.version` on
/// `initialize`, and compared with the runner's `GET /v1/status` `runner.update.commit` so a
/// stale MCP can warn once.
enum BuildInfo {
    /// Sidecar next to the executable (Contents/Helpers/oby-mcp.commit when bundled).
    static let sidecarName = "oby-mcp.commit"
    static let staleLine = "oby-mcp is older than the runner: update Oby or rebuild it."

    /// `OBY_MCP_COMMIT`, else the sidecar beside the executable, else `"unknown"`.
    static func commit(environment: [String: String] = ProcessInfo.processInfo.environment,
                       executable: URL = URL(filePath: CommandLine.arguments[0])) -> String {
        if let env = environment["OBY_MCP_COMMIT"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        let sidecar = executable.deletingLastPathComponent().appending(path: sidecarName)
        if let text = try? String(contentsOf: sidecar, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "unknown"
    }

    /// A stamped commit can be compared with the runner's; `unknown` never warns.
    static func canCompare(_ mcp: String) -> Bool {
        !mcp.isEmpty && mcp != "unknown"
    }

    /// True when both commits are known and differ: the MCP may be missing API the runner has.
    static func isStale(mcp: String, runner: String?) -> Bool {
        guard canCompare(mcp), let runner, !runner.isEmpty else { return false }
        return mcp != runner
    }
}
