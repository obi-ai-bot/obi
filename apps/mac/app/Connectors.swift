import Foundation

/// One thing Oby is connected to, or can connect now, as Settings › Connectors lists it (#498): a
/// coding tool's account, Tetrix, the runner's GitHub login, an obid plug-in or one of the
/// runner's connections. Each comes from something that exists; nothing here is a placeholder.
nonisolated struct Connector: Identifiable, Equatable, Sendable {
    /// Whether it works, as far as Oby can tell. Connected is only said of what was checked.
    enum State: Equatable, Sendable {
        /// Signed in, and the tool or the runner said so.
        case connected
        /// Set up to work, but it can't now: `how` says why.
        case broken
        /// In use, but nothing checks that it's signed in: `how` says what is known.
        case unconfirmed
        /// Set up and not connected: `way` connects it.
        case available
    }

    /// What a button does. Each one runs something real.
    enum Action: Equatable, Sendable {
        /// Oby forgets this Mac's account, deleting the home it made for it (Settings › Accounts' Remove).
        case removeAccount(Account)
        /// The tool's own login, in Terminal, with the account's home.
        case signIn(Account)
        /// obid signs in to this Tetrix for every agent (`POST /v1/tetrix/sign-in`): Tetrix's own page.
        case connectTetrix(TetrixStatus.Server)
        /// Asks for another Tetrix's MCP address, then connects it as `connectTetrix` does.
        case connectOtherTetrix
        /// The sign-in under way: its page again, after the same checks (`TetrixSignIn.opens`).
        case reopenTetrixSignIn
        /// `DELETE /v1/tetrix/sign-in`: ends the sign-in under way.
        case cancelTetrixSignIn
        /// `DELETE /v1/tetrix`: obid forgets its Tetrix login.
        case disconnectTetrix
        /// `PUT /v1/obid/plugins/{id}` on; `needsURL` asks for Tetrix's MCP URL first.
        case enablePlugin(id: String, needsURL: Bool)
        /// `PUT /v1/obid/plugins/{id}` off.
        case disablePlugin(String)
        /// `DELETE /v1/connections/{name}`, approved with Touch ID.
        case disconnect(String)
        /// gh's own sign-in on the runner (`POST /v1/github/sign-in`): GitHub's page and its code.
        case signInGitHub
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
    /// How it's signed in, or why it doesn't work.
    var how: String
    var state: State
    var way: Way?
    /// A second button after `way`'s: "Another Tetrix…".
    var also: Way? = nil
    /// The SF Symbol in front of it.
    var symbol: String

    var connected: Bool { state == .connected }

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
    static let tetrixAbout = TetrixStatus.about

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
        /// Whether its gh is signed in (`GET /v1/github`), from obid; nil from a runner that doesn't say.
        var gitHubLogin: GitHubLogin? = nil
        var plugins: [RunnerPlugin]?
        var connections: [ConnectedApp]?
        /// obid's Tetrix, held once for every agent (`GET /v1/tetrix`); nil from a runner that doesn't hold one.
        var tetrix: TetrixStatus? = nil
    }

    /// One of the page's groups, with its title.
    struct Group: Equatable, Sendable {
        var title: String
        var items: [Connector]
    }

    /// What the runner lists besides its status, and each list it couldn't read.
    struct Lists: Equatable, Sendable {
        var plugins: [RunnerPlugin]?
        var connections: [ConnectedApp]?
        /// obid's GitHub login (`GET /v1/github`); nil from a runner that doesn't say.
        var gitHub: GitHubLogin?
        /// obid's Tetrix (`GET /v1/tetrix`); nil from a runner that doesn't hold one.
        var tetrix: TetrixStatus?
        /// Why a list couldn't be read: a timeout, a 500, a 401. Only a 404 means the runner has
        /// none to list; anything else is said, never shown as an empty list.
        var problems: [String] = []
    }

    /// obid's plug-ins and the Swift runner's connections, as `runner` (called `name`) lists them.
    static func lists(from runner: Runner, name: String) async -> Lists {
        var lists = Lists()
        do {
            lists.plugins = try await runner.plugins()
        } catch {
            lists.problems.append("Couldn't read the plug-ins on \(name): \(error.localizedDescription)")
        }
        do {
            lists.connections = try await runner.connections()
        } catch {
            lists.problems.append("Couldn't read the connections on \(name): \(error.localizedDescription)")
        }
        // Said on GitHub's own row: without it, the row says what the status says.
        lists.gitHub = try? await runner.gitHubLogin()
        do {
            lists.tetrix = try await runner.tetrix()
        } catch {
            lists.problems.append("Couldn't read Tetrix on \(name): \(error.localizedDescription)")
        }
        return lists
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
        // obid's own Tetrix replaces its older plug-in of the same name: one Tetrix row.
        let plugins = (runner?.plugins ?? []).filter { runner?.tetrix == nil || $0.id != "tetrix" }
        if let runner { list += plugins.map { plugin($0, place: runner.name) } }
        if let runner, let status = runner.tetrix { list.append(tetrix(status, place: runner.name, local: runner.local)) }
        if let runner, let login = runner.gitHubLogin { list.append(gitHub(login, place: runner.name)) }
        else if let runner, let github = runner.github { list.append(gitHub(github, checks: runner.checks, place: runner.name)) }
        if let runner { list += (runner.connections ?? []).map { connection($0, place: runner.name) } }
        return list
    }

    /// The page's groups, each in `list`'s order, with only what matches `query`; empty ones are left out.
    static func groups(_ list: [Connector], query: String) -> [Group] {
        let shown = list.filter { $0.matches(query) }
        return [("Connected", Connector.State.connected), ("Needs attention", .broken), ("Not confirmed", .unconfirmed), ("Available", .available)]
            .map { title, state in Group(title: title, items: shown.filter { $0.state == state }) }
            .filter { !$0.items.isEmpty }
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
                         state: state.signedIn ? .connected : .available, way: way, symbol: Usage.symbol(state.account.agent))
    }

    /// Tetrix, held by obid for every agent of every account: one sign-in, on Tetrix's own page.
    /// Not connected, it offers the first server obid knows ("Tetrix Dogfood") and another one.
    /// Only obid on this Mac gets buttons: the sign-in comes back to 127.0.0.1 on obid's own machine,
    /// so a remote runner's is done there.
    static func tetrix(_ status: TetrixStatus, place: String, local: Bool) -> Connector {
        let row = { (state: Connector.State, way: Connector.Way?, also: Connector.Way?) in
            Connector(id: "tetrix", name: "Tetrix", about: tetrixAbout, place: place, how: status.how, state: state,
                      way: way, also: also, symbol: "point.3.connected.trianglepath.dotted")
        }
        let there = local ? nil : Connector.Way.steps("Connect or disconnect it on \(place) itself, with Oby there: Tetrix's sign-in comes back to that machine.")
        switch status.state {
        case .connected:
            return row(.connected, there ?? .button("Disconnect…", .disconnectTetrix), nil)
        case .signingIn:
            return row(.unconfirmed, there ?? .button("Open the Page Again", .reopenTetrixSignIn), local ? .button("Cancel", .cancelTetrixSignIn) : nil)
        case .available:
            let first = status.presets.first
            return row(status.error == nil ? .available : .broken,
                       there ?? first.map { .button("Connect", .connectTetrix($0)) } ?? .button("Connect…", .connectOtherTetrix),
                       local && first != nil ? .button("Another Tetrix…", .connectOtherTetrix) : nil)
        }
    }

    /// A plug-in obid found (docs/ARCHITECTURE.md, "Plug-ins"). Ready is connected, failed needs
    /// attention, starting isn't confirmed yet, and off is available.
    static func plugin(_ plugin: RunnerPlugin, place: String) -> Connector {
        let (said, state): (String, Connector.State) = switch (plugin.enabled, plugin.state) {
        case (false, _): ("Off", .available)
        case (true, "ready"): ("Ready", .connected)
        case (true, "failed"): ("Failed" + (plugin.lastError.map { ": \($0)" } ?? ", and obid didn't say why"), .broken)
        case (true, "starting"): ("Starting", .unconfirmed)
        case (true, let other): ("obid says “\(other)”", .unconfirmed)
        }
        return Connector(id: "plugin-\(plugin.id)", name: plugin.name, about: plugin.id == "tetrix" ? tetrixAbout : about(kinds: plugin.kinds),
                         place: place, how: "A plug-in of obid's\(plugin.version.map { " (\($0))" } ?? "") · \(said)", state: state,
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

    /// The runner's own GitHub login (docs/runner-api.md, `github` in `GET /v1/status`). `app` is
    /// checked (its last token request worked); `owner` is only who the calls act as: the runner
    /// never asks gh whether that login is there (#517), so it isn't said to be connected.
    static func gitHub(_ github: String, checks: String?, place: String) -> Connector {
        let there = place == thisMac ? "this Mac" : place
        let app = github == "app"
        let how = app ? "Oby's GitHub app, whose last token request worked, for the runner's own calls. Pushing and opening pull requests use your gh login, which the runner doesn't check."
                      : "Acts as your gh login on \(there). The runner doesn't check that it's signed in."
        let runs: String? = switch checks {
        case "ok": "Check runs reach pull requests."
        case "missing permission": "Check runs need the app's Checks permission."
        case "no app": "No check runs: they need the GitHub app."
        default: nil
        }
        let steps = app
            ? "To disconnect the app, unset OBY_GITHUB_APP_ID on \(there) and restart the runner: its calls then go as your gh login. gh auth logout there signs that out too, and then Oby can't clone, push or open pull requests."
            : "To disconnect it, run gh auth logout on \(there). Oby can't clone, push or open pull requests until you sign in again with gh auth login."
        return Connector(id: "github", name: "GitHub", about: "Repositories, pull requests and checks", place: place,
                         how: how + (runs.map { " \($0)" } ?? ""), state: app ? .connected : .unconfirmed, way: .steps(steps),
                         symbol: "arrow.triangle.branch")
    }

    /// GitHub as obid's gh is signed in to it (`GET /v1/github`): connected as its user, or a button
    /// that runs gh's own sign-in. The token stays gh's: Oby only learns who it's signed in as.
    static func gitHub(_ login: GitHubLogin, place: String) -> Connector {
        let there = place == thisMac ? "this Mac" : place
        if login.signedIn {
            let who = login.user.map { " as \($0)" } ?? ""
            return Connector(id: "github", name: "GitHub", about: "Repositories, pull requests and checks", place: place,
                             how: "Signed in with GitHub's own login\(who). Oby clones, pushes and opens pull requests with it.",
                             state: .connected, way: .steps("To disconnect it, run gh auth logout on \(there)."),
                             symbol: "arrow.triangle.branch")
        }
        guard login.gh else {
            return Connector(id: "github", name: "GitHub", about: "Repositories, pull requests and checks", place: place,
                             how: "\(place == thisMac ? "This Mac" : place) has no GitHub CLI for Oby to sign in with.",
                             state: .broken, way: nil, symbol: "arrow.triangle.branch")
        }
        return Connector(id: "github", name: "GitHub", about: "Repositories, pull requests and checks", place: place,
                         how: "Not signed in: Oby can't clone private repositories, push or open pull requests. Signing in uses GitHub's own page.",
                         state: .available, way: .button("Sign In…", .signInGitHub), symbol: "arrow.triangle.branch")
    }

    /// An app or API the runner's agents use through its broker, with the secret it sends, by name.
    /// Without that secret in the runner's vault, every call fails (Runner/Broker.swift): it needs attention.
    static func connection(_ connection: ConnectedApp, place: String) -> Connector {
        let host = URL(string: connection.mcp ?? connection.api ?? "")?.host() ?? connection.mcp ?? connection.api ?? ""
        let header = connection.header.flatMap { $0.lowercased() == "authorization" ? nil : $0 }
        let how = connection.secretSaved
            ? "The vault secret \(connection.secret), " + (header.map { "in the header \($0)" } ?? "as Authorization: Bearer")
            : "Its vault secret \(connection.secret) is missing, so agents' calls fail: add it on the runner with oby-runner vault add \(connection.secret)"
        return Connector(id: "connection-\(connection.name)", name: connection.name,
                         about: connection.mcp != nil ? "MCP server at \(host)" : "API at \(host)", place: place, how: how,
                         state: connection.secretSaved ? .connected : .broken, way: .button("Disconnect…", .disconnect(connection.name)),
                         symbol: "link")
    }

    /// What the page says while the runner doesn't answer, when its rows are left out; nil while it does.
    static func waiting(for name: String, _ connection: RunnerConnection) -> String? {
        let later = "Its accounts, GitHub, plug-ins and connections show here once it answers."
        return switch connection {
        case .live: nil
        case .connecting: "Connecting to \(name)… \(later)"
        case .offline(let why): "\(name) isn't answering: \(why.hasSuffix(".") ? why : why + ".") \(later)"
        }
    }

    /// What obid takes as Tetrix's MCP URL (plugins/tetrix/obi-plugin.json): HTTPS, with a host.
    static func isURL(_ text: String) -> Bool {
        text.lowercased().hasPrefix("https://") && URL(string: text)?.host()?.isEmpty == false
    }

    /// "Signed in with Claude Code's own login · Max": the plan, never the email the label carries.
    static func signedIn(tool: String, label: String?) -> String {
        "Signed in with \(tool)'s own login" + (Usage.plan(label).map { " · \($0)" } ?? "")
    }
}
