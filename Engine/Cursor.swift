import Foundation

/// What only a signed-in Cursor can tell (#406, spike #24), as the probe on tetrix-lab proved it
/// (cursor-agent 2026.10.12-d47ca18, scripts/cursor-probe.sh, docs/cursor.md).
nonisolated enum CursorFacts {
    /// Two Cursor accounts keep separate logins, but only when each runs with a `HOME` and an
    /// `XDG_CONFIG_HOME` of its own as well as its own `CURSOR_CONFIG_DIR`: the login is a plain file
    /// in `$XDG_CONFIG_HOME/cursor/auth.json`, and with `CURSOR_CONFIG_DIR` alone both homes showed the
    /// user's real login (`CursorStatus.environment`). Proven 2026-10-14: account A signed in, B
    /// stayed signed out.
    static let separateLogins = true
    /// An edit in `--sandbox disabled` comes to Oby as a permission request. It doesn't: with every
    /// permission rejected, Cursor wrote the file without a `session/request_permission`. Edits can't
    /// be gated through ACP, so a Cursor job in Ask mode behaves as Accept edits, and what holds them
    /// is the job's worktree and, on Linux, bubblewrap. Commands do ask (kind `execute`).
    static let editsAsk = false
    /// Cursor takes the MCP servers `session/new` carries: it POSTed to the server given, then tried
    /// OAuth discovery (`/.well-known/oauth-protected-resource`, `oauth-authorization-server`,
    /// `openid-configuration`, `POST /register`), which the runner answers `404` (Gate).
    static let honoursMcpServers = true
    /// Cursor offers its model as a `model` config option (values like
    /// `gpt-5.6-luna[context=272k,reasoning=medium,fast=false]`, `default[]` for Auto), set after
    /// `session/new`: `--model` is dropped.
    static let modelOption = true

    /// Why a Cursor account of one machine is alone (not used while `separateLogins` holds).
    static let oneLogin = "Cursor keeps one login per Mac user"
    /// What a Cursor job in Ask mode and its mode picker say, since Cursor writes files without asking.
    static let askActsAsAcceptEdits = "Cursor edits files without asking Oby, so Ask works as Accept edits for Cursor jobs: the job's worktree is what holds them"
    static let noConnectedApps = "Connected apps aren't available to Cursor jobs yet"
}

extension ACPTool {
    /// Cursor through `cursor-agent acp`, on the account home `home` (Oby made it: never `~/.cursor`,
    /// whose `permissions.allow` isn't Oby's to apply).
    /// - `--sandbox disabled`: Cursor's own sandbox is off, so every command comes to Oby.
    /// - `--model`: its model from Settings › Models, left out for `auto` (Cursor picks) and when
    ///   Cursor sets its model as an option (`CursorFacts.modelOption`).
    /// - The environment keeps Cursor's login out of the agent's reach: no `CURSOR_API_KEY` or
    ///   `CURSOR_AUTH_TOKEN`, and `CURSOR_CONFIG_DIR`, `XDG_CONFIG_HOME` and `HOME` are the
    ///   account's: its login lives under them (`CursorFacts.separateLogins`).
    /// On Linux it runs in bubblewrap with `own: home` (`Agents.sandboxed`).
    static func cursor(worktree: URL, home: URL?, model: String, bubblewrap: Bool = Agents.bubblewrap,
                       modelOption: Bool = CursorFacts.modelOption, honoursMCP: Bool = CursorFacts.honoursMcpServers,
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ACPTool {
        let picked = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let asks = picked.isEmpty || picked == "auto" ? nil : picked
        var command = ["cursor-agent", "--sandbox", "disabled"]
        if let asks, !modelOption { command += ["--model", asks] }
        command.append("acp")
        var tool = ACPTool(id: "cursor", name: "Cursor",
                           arguments: Agents.sandboxed(Agents.niced(command), in: worktree, own: home?.path, bubblewrap: bubblewrap, exists: exists))
        tool.environment = CursorStatus.environment(home: home?.path)
        tool.model = asks
        tool.honoursMCP = honoursMCP
        // The account's own MCP servers (Tetrix), with only what's needed to start them.
        tool.mcpFile = home?.appending(path: "mcp.json")
        if let home {
            tool.prepare = { try CursorConfig.rewrite(home: home) }
        } else {
            tool.cannotStart = "Cursor jobs run on an account Oby made: add one in Settings › Accounts."
        }
        tool.repositoryAllowlist = { CursorConfig.repositoryAllowlist(worktree: $0) }
        return tool
    }
}

/// The files Cursor reads its permissions from.
nonisolated enum CursorConfig {
    /// What Oby sets in `<home>/cli-config.json` before each start: no command or edit is allowed
    /// ahead of Oby, and every one is asked about (`allowlist` mode over an empty allowlist). The
    /// CLI-managed keys (`authInfo`, `version`, whatever else) stay as they are.
    static func rewrite(home: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = home.appending(path: "cli-config.json")
        var config = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        config["permissions"] = ["allow": [String](), "deny": [String]()]
        config["approvalMode"] = "allowlist"
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// What the worktree's `.cursor/cli.json` pre-allows (`permissions.allow`), in file order.
    static func repositoryAllowlist(worktree: URL) -> [String] {
        let file = worktree.appending(path: ".cursor/cli.json")
        let config = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return ((config?["permissions"] as? [String: Any])?["allow"] as? [Any] ?? []).compactMap { $0 as? String }
    }
}

/// A model a Cursor account offers.
nonisolated struct CursorModel: Equatable, Sendable {
    var id: String
    var name: String
}

/// `cursor-agent models`.
nonisolated enum CursorModels {
    /// It prints one model a line, as "id - Name", maybe marked "(current)" or "(default)",
    /// between a heading and tips.
    static func parse(_ text: String) -> [CursorModel] {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return plain.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: " - ")
            guard parts.count >= 2 else { return nil }
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains(" "), !id.hasSuffix(":") else { return nil }
            let name = parts.dropFirst().joined(separator: " - ")
                .replacingOccurrences(of: #"\s*\((current|default)\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return CursorModel(id: id, name: name.isEmpty ? id : name)
        }
    }

    /// The account's models, asked boxed like a job, with the account's own `CURSOR_CONFIG_DIR`.
    /// Empty when the CLI isn't there or the account is signed out.
    static func list(home: String?) async -> [CursorModel] {
        let argv = Agents.sandboxed(["cursor-agent", "models"], in: nil, own: home)
        guard let out = try? await Shell.run(argv, env: CursorStatus.environment(home: home), timeout: 30), out.status == 0, !out.timedOut else { return [] }
        return parse(out.text)
    }
}

/// `cursor-agent status`, and the environment Oby asks it with.
nonisolated enum CursorStatus {
    enum Result: Equatable {
        case signedIn(String)
        case signedOut
        /// The output says neither: `cursor-agent models` is the proxy then.
        case unknown
    }

    /// The account's own folders, and none of the logins an agent's environment never has. The login
    /// is a file under `XDG_CONFIG_HOME` (`~/.config/cursor/auth.json`), so an account's isolation
    /// takes its `HOME` and `XDG_CONFIG_HOME` as well as `CURSOR_CONFIG_DIR`: the combination the
    /// probe proved (`CursorFacts.separateLogins`). Without a home of its own, Cursor's defaults.
    static func environment(home: String?) -> [String: String?] {
        var environment: [String: String?] = ["CURSOR_API_KEY": nil, "CURSOR_AUTH_TOKEN": nil]
        guard let home else { return environment }
        environment["CURSOR_CONFIG_DIR"] = home
        environment["HOME"] = home
        environment["XDG_CONFIG_HOME"] = home + "/.config"
        return environment
    }

    /// "Logged in as name@example.com" is signed in, with that as its label; "Not logged in" is not.
    // ponytail: the format is from #406's comment ("Logged in as …"); a plan name, as "Pro · …", comes
    // with the signed-in probe's report (docs/cursor.md).
    static func parse(_ text: String) -> Result {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let lower = plain.lowercased()
        if lower.contains("not logged in") || lower.contains("logged out") || lower.contains("not authenticated") || lower.contains("signed out") {
            return .signedOut
        }
        if let match = plain.firstMatch(of: /(?i)logged in as\s+(\S+(?:@\S+)?)/) {
            return .signedIn(String(match.1).trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "@._-+"))))
        }
        return .unknown
    }
}
