import Foundation

/// `oby-mcp` inside Oby.app (#385): Contents/Helpers/oby-mcp, updated with the app by Sparkle.
/// Settings › Assistants points Claude Code and Codex at this path, never a copy.
enum MCPHelper {
    static let helperPath = "Contents/Helpers/oby-mcp"
    /// Sidecar the bundle phase writes next to the binary (MCP/BuildInfo.swift reads it).
    static let commitPath = "Contents/Helpers/oby-mcp.commit"

    static var url: URL { Bundle.main.bundleURL.appending(path: helperPath) }
    static var path: String { url.path }
    static var isPresent: Bool { FileManager.default.isExecutableFile(atPath: path) }

    /// What's missing from `bundle` for Assistants to work. Empty when the build bundled it.
    static func missing(in bundle: Bundle) -> [String] {
        FileManager.default.fileExists(atPath: bundle.bundleURL.appending(path: helperPath).path)
            ? [] : [helperPath]
    }

    /// `claude mcp add --scope user oby -- <path>`
    static func claudeAdd(path: String = path) -> [String] {
        ["claude", "mcp", "add", "--scope", "user", "oby", "--", path]
    }

    /// `codex mcp add oby -- <path>`
    static func codexAdd(path: String = path) -> [String] {
        ["codex", "mcp", "add", "oby", "--", path]
    }

    static func shellLine(_ argv: [String]) -> String {
        argv.map(shellEscape).joined(separator: " ")
    }

    private static func shellEscape(_ argument: String) -> String {
        guard argument.contains(where: { !"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:@+=,".contains($0) }) else {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
