import Foundation

/// One thing Oby is connected to, or can connect now, as Settings › Connectors lists it (#498): a
/// coding tool's account, Tetrix, the runner's GitHub login, an obid plug-in or one of the
/// runner's connections. Each comes from something that exists; nothing here is a placeholder.
nonisolated struct Connector: Identifiable, Equatable, Sendable {
    /// What a button does. Each one runs something real.
    enum Action: Equatable, Sendable {
        /// Oby forgets this Mac's account, deleting the home it made for it (Settings › Accounts' Remove).
        case removeAccount(Account)
        /// The tool's own login, in Terminal, with the account's home.
        case signIn(Account)
        /// The tool's own login to its `tetrix` MCP server, in Terminal (Engine/TetrixUse.swift).
        case signInTetrix(Account)
        /// The tool's own sign-out from its `tetrix` MCP server, in Terminal (`Connectors.tetrixSignOutScript`).
        case signOutTetrix(Account)
        /// `PUT /v1/obid/plugins/{id}` on; `needsURL` asks for Tetrix's MCP URL first.
        case enablePlugin(id: String, needsURL: Bool)
        /// `PUT /v1/obid/plugins/{id}` off.
        case disablePlugin(String)
        /// `DELETE /v1/connections/{name}`, approved with Touch ID.
        case disconnect(String)
    }

    /// How to disconnect a connected one, or connect an available one.
    enum Way: Equatable, Sendable {
        /// A button with its label.
        case button(String, Action)
        /// What the user does themselves, where Oby has no button for it: on the runner's machine.
        case steps(String)
    }

    var id: String
    var name: String
    /// What it does: search reads it with the name.
    var about: String
    /// Where it is: "This Mac", or the runner's name.
    var place: String
    /// How it's signed in, or why it isn't.
    var how: String
    var connected: Bool
    var way: Way?
    /// The SF Symbol in front of it.
    var symbol: String

    /// Whether every word of `query` is in its name, what it does or where it is, whatever the
    /// case or accents. An empty query matches every one.
    func matches(_ query: String) -> Bool {
        let text = "\(name) \(about) \(place)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

nonisolated enum Connectors {
    static let thisMac = "This Mac"
    static let tetrixAbout = "Project knowledge and blast radius"

    /// What the runner said about itself, for the page: nil parts are what it doesn't say (an
    /// older runner, or obid, which lists no connections yet, #444).
    struct RunnerState: Equatable, Sendable {
        /// "tetrix-lab", or "This Mac" for the runner on this Mac.
        var name: String
        /// The runner is this Mac's own (#283): the Swift one shares this Mac's accounts.
        var local: Bool
        var accounts: [AccountState]
        var github: String?
        var checks: String?
        var plugins: [RunnerPlugin]?
        var connections: [ConnectedApp]?
    }

    /// Everything this Mac and its runner are connected to, and what's set up but not connected
    /// yet: the coding tools' accounts, Tetrix, GitHub, then the runner's connections.
    static func list(mac: [AccountState], runner: RunnerState?) -> [Connector] {
        // The runner on this Mac lists this Mac's own accounts: once is enough, with this Mac's buttons.
        let runnerAccounts = (runner?.accounts ?? []).filter { account in
            !(runner?.local == true && mac.contains { $0.account.id == account.account.id })
        }
        var list = mac.map { account($0, place: thisMac, runner: nil) }
        if let runner { list += runnerAccounts.map { account($0, place: runner.name, runner: runner.name) } }
        if let runner { list += (runner.plugins ?? []).map { plugin($0, place: runner.name) } }
        list += mac.compactMap { tetrix($0, place: thisMac, runner: nil) }
        if let runner { list += runnerAccounts.compactMap { tetrix($0, place: runner.name, runner: runner.name) } }
        if let runner, let github = runner.github { list.append(gitHub(github, checks: runner.checks, place: runner.name)) }
        if let runner { list += (runner.connections ?? []).map { connection($0, place: runner.name) } }
        return list
    }

    /// The page's two groups, each in `list`'s order, with only what matches `query`.
    static func groups(_ list: [Connector], query: String) -> (connected: [Connector], available: [Connector]) {
        let shown = list.filter { $0.matches(query) }
        return (shown.filter(\.connected), shown.filter { !$0.connected })
    }

    /// A coding tool's account. This Mac's have buttons; the runner's are set up on its machine.
    static func account(_ state: AccountState, place: String, runner: String?) -> Connector {
        let tool = Usage.tool(state.account.agent)
        let way: Connector.Way = switch (state.signedIn, runner) {
        case (true, nil): .button("Disconnect…", .removeAccount(state.account))
        case (false, nil): .button("Sign In", .signIn(state.account))
        case (true, let runner?):
            .steps("To disconnect it, take it out of accounts.json in OBY_HOME on \(runner), or sign out with \(tool)'s own logout in its home.")
        case (false, let runner?):
            .steps("Sign it in on \(runner) with \(tool)'s own login, in this account's home.")
        }
        return Connector(id: "account-\(place)-\(state.account.id)", name: state.account.heading, about: "Runs jobs in \(tool)",
                         place: place, how: state.signedIn ? signedIn(tool: tool, label: state.label) : "Not signed in",
                         connected: state.signedIn, way: way, symbol: Usage.symbol(state.account.agent))
    }

    /// Tetrix for one account's agents, once its tool has said whether they have it (`tetrix`): its
    /// own MCP login, never Oby's. An account that isn't signed in can't say.
    static func tetrix(_ state: AccountState, place: String, runner: String?) -> Connector? {
        guard state.signedIn, let connected = state.tetrix else { return nil }
        let tool = Usage.tool(state.account.agent)
        let way: Connector.Way = switch (connected, runner) {
        case (true, nil): .button("Disconnect…", .signOutTetrix(state.account))
        case (false, nil): .button("Sign In", .signInTetrix(state.account))
        case (true, let runner?):
            .steps("To disconnect it, sign this account out of its tetrix MCP server on \(runner), with \(tool)'s own login in its home.")
        case (false, let runner?):
            .steps("Sign this account in to its tetrix MCP server on \(runner), with \(tool)'s own login in its home.")
        }
        return Connector(id: "tetrix-\(place)-\(state.account.id)", name: "Tetrix", about: tetrixAbout, place: place,
                         how: connected ? "\(state.account.heading)'s agents, through \(tool)'s own MCP login"
                                        : "\(state.account.heading)'s agents aren't signed in to it",
                         connected: connected, way: way, symbol: "point.3.connected.trianglepath.dotted")
    }

    /// A plug-in obid found (docs/ARCHITECTURE.md, "Plug-ins"). On is connected; off is available.
    static func plugin(_ plugin: RunnerPlugin, place: String) -> Connector {
        let state = switch plugin.state {
        case "ready": "Ready"
        case "starting": "Starting"
        case "failed": "Failed" + (plugin.lastError.map { ": \($0)" } ?? "")
        default: "Off"
        }
        return Connector(id: "plugin-\(plugin.id)", name: plugin.name, about: plugin.id == "tetrix" ? tetrixAbout : about(kinds: plugin.kinds),
                         place: place, how: "A plug-in of obid's\(plugin.version.map { " (\($0))" } ?? "") · \(state)",
                         connected: plugin.enabled,
                         way: plugin.enabled ? .button("Disconnect", .disablePlugin(plugin.id))
                                             : .button("Connect…", .enablePlugin(id: plugin.id, needsURL: plugin.id == "tetrix")),
                         symbol: plugin.id == "tetrix" ? "point.3.connected.trianglepath.dotted" : "puzzlepiece.extension")
    }

    /// What a plug-in of these kinds gives (docs/ARCHITECTURE.md 5.1).
    static func about(kinds: [String]) -> String {
        let said = kinds.compactMap { ["context": "context for jobs", "events": "events in your inbox", "agent-mcp": "tools for agents"][$0] }
        guard !said.isEmpty else { return "A plug-in" }
        let text = said.joined(separator: ", ")
        return text.prefix(1).uppercased() + String(text.dropFirst())
    }

    /// The runner's own GitHub login (docs/runner-api.md, `github` in `GET /v1/status`).
    static func gitHub(_ github: String, checks: String?, place: String) -> Connector {
        let there = place == thisMac ? "this Mac" : place
        let how = github == "app" ? "Oby's GitHub app for its own calls; your gh login pushes and opens pull requests"
                                  : "Your gh login on \(there)"
        let runs: String? = switch checks {
        case "ok": "check runs on pull requests"
        case "missing permission": "check runs need the app's Checks permission"
        case "no app": "no check runs: they need the GitHub app"
        default: nil
        }
        let steps = github == "app"
            ? "To disconnect the app, unset OBY_GITHUB_APP_ID on \(there) and restart the runner: its calls then go as your gh login. gh auth logout there signs that out too, and then Oby can't clone, push or open pull requests."
            : "To disconnect it, run gh auth logout on \(there). Oby can't clone, push or open pull requests until you sign in again with gh auth login."
        return Connector(id: "github", name: "GitHub", about: "Repositories, pull requests and checks", place: place,
                         how: how + (runs.map { " · \($0)" } ?? ""), connected: true, way: .steps(steps), symbol: "arrow.triangle.branch")
    }

    /// An app or API the runner's agents use through its broker, with the secret it sends, by name.
    static func connection(_ connection: ConnectedApp, place: String) -> Connector {
        let host = URL(string: connection.mcp ?? connection.api ?? "")?.host() ?? connection.mcp ?? connection.api ?? ""
        let header = connection.header.flatMap { $0.lowercased() == "authorization" ? nil : $0 }
        let how = connection.secretSaved
            ? "The vault secret \(connection.secret), " + (header.map { "in the header \($0)" } ?? "as Authorization: Bearer")
            : "The vault secret \(connection.secret) is missing: add it on the runner with oby-runner vault add \(connection.secret)"
        return Connector(id: "connection-\(connection.name)", name: connection.name,
                         about: connection.mcp != nil ? "MCP server at \(host)" : "API at \(host)", place: place, how: how,
                         connected: true, way: .button("Disconnect…", .disconnect(connection.name)), symbol: "link")
    }

    /// "Signed in with Claude Code's own login · Max": the plan, never the email the label carries.
    static func signedIn(tool: String, label: String?) -> String {
        "Signed in with \(tool)'s own login" + (Usage.plan(label).map { " · \($0)" } ?? "")
    }

    /// What Terminal runs to sign an account's agents out of Tetrix: the tool's own sign-out for its
    /// `tetrix` MCP server, with the account's home, as `TetrixUse.signInScript` signs them in.
    static func tetrixSignOutScript(for account: Account) -> String {
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        let (variable, steps) = switch account.agent {
        case "codex": ("CODEX_HOME", "codex mcp logout tetrix")
        case "cursor": ("CURSOR_CONFIG_DIR", "cursor-agent mcp disable tetrix")
        default:
            ("CLAUDE_CONFIG_DIR", """
                echo 'In Claude Code, type /mcp, choose tetrix and Clear authentication, then /exit.'
                claude
                """)
        }
        // Cursor's settings are under XDG_CONFIG_HOME: the account's own takes its HOME too.
        let own = account.agent == "cursor" ? account.home.map { "\nexport XDG_CONFIG_HOME=\(quote($0 + "/.config"))\nexport HOME=\(quote($0))" } ?? "" : ""
        return """
        #!/bin/sh
        \(account.home.map { "export \(variable)=\(quote($0))" } ?? "unset \(variable)")\(own)
        echo \(quote("Oby: sign \(account.name)'s agents out of Tetrix."))
        \(steps)
        echo
        echo 'Done? Go back to Oby. You can close this window.'

        """
    }
}
