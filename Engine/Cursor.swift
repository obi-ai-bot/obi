import Foundation

/// What only a signed-in Cursor can tell (#406, spike #24): the probe's signed-in half
/// (scripts/cursor-probe.sh, docs/cursor.md) decides each one, and its report is committed here.
/// Until then each holds the safe value: what Oby does is true whichever way Cursor behaves.
nonisolated enum CursorFacts {
    /// Two Cursor accounts keep separate logins under their own `CURSOR_CONFIG_DIR`. False: Settings
    /// allows one Cursor account per machine and says why.
    static let separateLogins = false
    /// An edit in `--sandbox disabled` comes to Oby as a permission request. False: a Cursor job in
    /// Ask mode behaves as Accept edits, and the mode picker and the job's card say so.
    static let editsAsk = false
    /// Cursor takes the MCP servers `session/new` carries. False: no server is handed over, and the
    /// job's report says connected apps aren't available to Cursor jobs yet.
    static let honoursMcpServers = false
    /// Cursor offers its model as a `model` config option, set after `session/new`. False: `--model`.
    static let modelOption = false

    /// Why Settings allows one Cursor account.
    static let oneLogin = "Cursor keeps one login per Mac user"
    /// What a Cursor job in Ask mode and its mode picker say when Cursor writes without asking.
    static let askActsAsAcceptEdits = "Cursor edits files without asking Oby, so Ask works as Accept edits for Cursor jobs"
    static let noConnectedApps = "Connected apps aren't available to Cursor jobs yet"
}

extension ACPTool {
    /// Cursor through `cursor-agent acp`, on the account home `home` (Oby made it: never `~/.cursor`,
    /// whose `permissions.allow` isn't Oby's to apply).
    /// - `--sandbox disabled`: Cursor's own sandbox is off, so every command comes to Oby.
    /// - `--model`: its model from Settings › Models, left out for `auto` (Cursor picks) and when
    ///   Cursor sets its model as an option (`CursorFacts.modelOption`).
    /// - The environment keeps Cursor's login out of the agent's reach: no `CURSOR_API_KEY` or
    ///   `CURSOR_AUTH_TOKEN`, and `CURSOR_CONFIG_DIR` is the account's.
    /// On Linux it runs in bubblewrap with `own: home` (`Agents.sandboxed`).
    static func cursor(worktree: URL, home: URL?, model: String, bubblewrap: Bool = Agents.bubblewrap,
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ACPTool {
        let picked = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let asks = picked.isEmpty || picked == "auto" ? nil : picked
        var command = ["cursor-agent", "--sandbox", "disabled"]
        if let asks, !CursorFacts.modelOption { command += ["--model", asks] }
        command.append("acp")
        var tool = ACPTool(id: "cursor", name: "Cursor",
                           arguments: Agents.sandboxed(Agents.niced(command), in: worktree, own: home?.path, bubblewrap: bubblewrap, exists: exists))
        tool.environment = ["CURSOR_CONFIG_DIR": home?.path, "CURSOR_API_KEY": nil, "CURSOR_AUTH_TOKEN": nil]
        tool.model = asks
        tool.honoursMCP = CursorFacts.honoursMcpServers
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
