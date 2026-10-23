import Foundation

/// One service on Settings › Connectors, one row each as Sangam's `CONNECTORS` has them (#498): a coding
/// tool (connected while one of its accounts is signed in), Tetrix, GitHub, a service Oby can't connect
/// yet (`soon`), then an obid plug-in or one of the runner's connections. Connected is only said of
/// what was checked; a service that's coming is never said to be connected.
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
        /// Settings › Accounts, where a tool's accounts are added, signed in and removed.
        case accounts
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
        /// Asks for the Slack app's two tokens and gives them to obid (`PUT /v1/slack`).
        case connectSlack
        /// `DELETE /v1/slack`: obid forgets the Slack tokens.
        case disconnectSlack
        /// `PATCH /v1/watch`: the watcher's Slack message on, or back to a dry run.
        case setWatchLive(Bool)
        /// `PATCH /v1/slack`: whether a posted review's author is told on Slack.
        case setTellAuthors(Bool)
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
    /// A third, in a connected row's context menu: Slack's "Reviews: Don't Tell Authors".
    var more: Way? = nil
    /// The SF Symbol in front of it, where it has no brand mark.
    var symbol = "link"
    /// Its brand's mark in the asset catalog (Brands/, from Sangam's brands.tsx).
    var brand: String? = nil
    /// A service Oby can't connect yet: listed under Available, as the design does, saying so.
    var soon = false

    var connected: Bool { state == .connected }

    /// The row's tooltip: how it's signed in and, once connected, how to disconnect it where Oby has
    /// no button (the row shows those steps only while it isn't connected).
    var tip: String {
        if soon { return "Oby can't connect \(name) yet." }
        if connected, case .steps(let steps) = way { return "\(how)\n\(steps)" }
        return how
    }

    /// Whether every word of `query` is in its name or what it does, as the design searches, whatever
    /// the case or accents. An empty query matches every one.
    func matches(_ query: String) -> Bool {
        let text = "\(name) \(about)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

nonisolated enum Connectors {
    static let thisMac = "This Mac"
    static let tetrixAbout = TetrixStatus.about
    static let gitHubAbout = "Repos, pull requests and checks"

    /// The coding tools, a row each as the design names them: agent, name, line and mark.
    static let tools = [("claude", "Claude", "Run jobs in Claude Code", "claude"),
                        ("codex", "ChatGPT", "Run jobs in Codex, ask ChatGPT", "openai"),
                        ("cursor", "Cursor", "Run jobs in Cursor", "cursor")]

    /// The design's services Oby can't connect yet (Deskree Ops #502, Slack #26, Gmail #501, Google
    /// Meet #503, Zoom #504): id, name, line and mark.
    static let coming = [("deskree", "Deskree Ops", "Projects, deploys and incidents", "deskree"),
                         ("slack", "Slack", SlackStatus.about, "slack"),
                         ("gmail", "Gmail", "Read and manage your email", "gmail"),
                         ("meet", "Google Meet", "Join meetings and keep the notes", "meet"),
                         ("zoom", "Zoom", "Join meetings and keep the notes", "zoom")]

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
        /// obid's Slack (`GET /v1/slack`) and its watcher (`GET /v1/watch`); nil from a runner without them.
        var slack: SlackStatus? = nil
        var watch: WatchStatus? = nil
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
        /// obid's Slack and its watcher; nil from a runner without them.
        var slack: SlackStatus?
        var watch: WatchStatus?
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
        // Only a 404 means obid has no Slack (the row stays "Coming soon"); anything else is said.
        do {
            lists.slack = try await runner.slack()
        } catch {
            lists.problems.append("Couldn't read Slack on \(name): \(error.localizedDescription)")
        }
        do {
            lists.watch = try await runner.watch()
        } catch {
            lists.problems.append("Couldn't read the watcher on \(name): \(error.localizedDescription)")
        }
        return lists
    }

    /// The accounts jobs run on, from where Settings › Accounts lists them (`AccountPlaces`): with obid
    /// on this Mac only obid's, never this Mac's own `accounts.json` beside it, which names the same
    /// logins under other ids; with a remote runner this Mac's and the runner's; with none, this Mac's.
    /// `runner` is nil while the runner doesn't answer: with obid on this Mac that's nil too, as nothing is known yet.
    static func accounts(mac: [AccountState], runner: [AccountState]?, local: Bool, hasRunner: Bool) -> [AccountState]? {
        let places = AccountPlaces.of(local: local, runner: hasRunner)
        if places == [.runner], runner == nil { return nil }
        return places.flatMap { $0 == .mac ? mac : runner ?? [] }
    }

    /// Every service, in the design's order: Deskree Ops, Tetrix, GitHub, the coding tools, then the
    /// rest the design shows, and after them what the runner adds (obid's plug-ins, its connections).
    /// `accounts` are the ones jobs run on (`accounts(mac:runner:local:hasRunner:)`), nil while the runner
    /// that holds them doesn't answer; `runner` is nil while it doesn't answer. Then what it holds says it waits for it.
    static func list(accounts: [AccountState]?, runner: RunnerState?) -> [Connector] {
        let soon = coming.map { id, name, about, brand in
            Connector(id: id, name: name, about: about, place: thisMac, how: "Coming soon", state: .available, way: nil, brand: brand, soon: true)
        }
        var list = [soon[0]]
        if let runner, let status = runner.tetrix { list.append(tetrix(status, place: runner.name, local: runner.local)) }
        else if let runner, let old = runner.plugins?.first(where: { $0.id == "tetrix" }) { list.append(plugin(old, place: runner.name)) }
        else { list.append(untilRunner(id: "tetrix", name: "Tetrix", about: tetrixAbout, brand: "tetrix", runner: runner?.name)) }
        if let runner, let login = runner.gitHubLogin { list.append(gitHub(login, place: runner.name)) }
        else if let runner, let github = runner.github { list.append(gitHub(github, checks: runner.checks, place: runner.name)) }
        else { list.append(untilRunner(id: "github", name: "GitHub", about: gitHubAbout, brand: "github", runner: runner?.name)) }
        list += tools.map { agent, name, about, brand in
            accounts.map { tool(agent, name: name, about: about, brand: brand, accounts: $0) }
                ?? untilRunner(id: agent, name: name, about: about, brand: brand, runner: nil)
        }
        list += soon.dropFirst().map { coming in
            guard coming.id == "slack", let runner, let status = runner.slack else { return coming }
            return slack(status, watch: runner.watch, place: runner.name, local: runner.local)
        }
        if let runner {
            list += (runner.plugins ?? []).filter { $0.id != "tetrix" }.map { plugin($0, place: runner.name) }
            list += (runner.connections ?? []).map { connection($0, place: runner.name) }
        }
        return list
    }

    /// The page's groups, as the design has them: Connected, then Available (everything else, what it
    /// needs said on its row), each in `list`'s order, with only what matches `query`; empty ones are left out.
    static func groups(_ list: [Connector], query: String) -> [Group] {
        let shown = list.filter { $0.matches(query) }
        return [Group(title: "Connected", items: shown.filter(\.connected)), Group(title: "Available", items: shown.filter { !$0.connected })]
            .filter { !$0.items.isEmpty }
    }

    /// A coding tool: connected while one of its accounts is signed in, saying which by name (never a
    /// login's email). Its accounts are added, signed in and removed in Settings › Accounts.
    static func tool(_ agent: String, name: String, about: String, brand: String, accounts: [AccountState]) -> Connector {
        let own = accounts.filter { $0.account.agent == agent }
        let signedIn = own.filter(\.signedIn).map(\.account.name)
        let how = !signedIn.isEmpty ? "Signed in with \(Usage.tool(agent))'s own login: " + signedIn.joined(separator: ", ")
            : own.isEmpty ? "No \(Usage.tool(agent)) account yet" : "Not signed in: " + own.map(\.account.name).joined(separator: ", ")
        return Connector(id: agent, name: name, about: about, place: thisMac, how: how, state: signedIn.isEmpty ? .available : .connected,
                         way: .button(signedIn.isEmpty ? "Connect" : "Manage Accounts…", .accounts), brand: brand)
    }

    /// What the runner holds (Tetrix, GitHub, obid's accounts) while it doesn't answer (`runner` nil), or one that doesn't say.
    static func untilRunner(id: String, name: String, about: String, brand: String, runner: String?) -> Connector {
        Connector(id: id, name: name, about: about, place: runner ?? thisMac, how: "Oby's runner holds it", state: .available,
                  way: .steps(runner.map { "\($0) doesn't say: it needs a newer runner." } ?? "Shows here once Oby's runner answers (Settings › Runner)."),
                  brand: brand)
    }

    /// Tetrix, held by obid for every agent of every account: one sign-in, on Tetrix's own page.
    /// Not connected, it offers the first server obid knows ("Tetrix Dogfood") and another one.
    /// Only obid on this Mac gets buttons: the sign-in comes back to 127.0.0.1 on obid's own machine,
    /// so a remote runner's is done there.
    static func tetrix(_ status: TetrixStatus, place: String, local: Bool) -> Connector {
        let row = { (state: Connector.State, way: Connector.Way?, also: Connector.Way?) in
            Connector(id: "tetrix", name: "Tetrix", about: tetrixAbout, place: place, how: status.how, state: state,
                      way: way, also: also, brand: "tetrix")
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

    /// Slack, held by obid for its watcher with the owner's own Slack app's tokens, pasted once.
    /// Only obid on this Mac gets buttons, as for Tetrix. Connected, the watcher's Slack message is
    /// turned on or back to a dry run here, and telling a posted review's author on or off.
    static func slack(_ status: SlackStatus, watch: WatchStatus?, place: String, local: Bool) -> Connector {
        let how = [status.how, watch?.line].compactMap { $0 }.joined(separator: "\n")
        let row = { (state: Connector.State, way: Connector.Way?, also: Connector.Way?) in
            Connector(id: "slack", name: "Slack", about: SlackStatus.about, place: place, how: how, state: state,
                      way: way, also: also, more: local && status.connected
                          ? .button(status.tellAuthors ? "Reviews: Don't Tell Authors" : "Reviews: Tell Authors on Slack",
                                    .setTellAuthors(!status.tellAuthors))
                          : nil,
                      brand: "slack")
        }
        guard local else {
            return row(status.connected ? .connected : .available,
                       .steps("Connect or disconnect it on \(place) itself, with Oby there."), nil)
        }
        if status.connected {
            let live = watch?.rules.map { rules in
                Connector.Way.button(rules.live ? "Watcher: Dry Run Only" : "Watcher: Send Slack Messages", .setWatchLive(!rules.live))
            }
            return row(.connected, .button("Disconnect…", .disconnectSlack), live)
        }
        return row(status.error == nil ? .available : .broken, .button("Connect…", .connectSlack), nil)
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
                         symbol: "puzzlepiece.extension", brand: plugin.id == "tetrix" ? "tetrix" : nil)
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
        return Connector(id: "github", name: "GitHub", about: gitHubAbout, place: place,
                         how: how + (runs.map { " \($0)" } ?? ""), state: app ? .connected : .unconfirmed, way: .steps(steps),
                         brand: "github")
    }

    /// GitHub as obid's gh is signed in to it (`GET /v1/github`): connected as its user, or a button
    /// that runs gh's own sign-in. The token stays gh's: Oby only learns who it's signed in as.
    static func gitHub(_ login: GitHubLogin, place: String) -> Connector {
        let there = place == thisMac ? "this Mac" : place
        if login.signedIn {
            let who = login.user.map { " as \($0)" } ?? ""
            return Connector(id: "github", name: "GitHub", about: gitHubAbout, place: place,
                             how: "Signed in with GitHub's own login\(who). Oby clones, pushes and opens pull requests with it.",
                             state: .connected, way: .steps("To disconnect it, run gh auth logout on \(there)."),
                             brand: "github")
        }
        guard login.gh else {
            return Connector(id: "github", name: "GitHub", about: gitHubAbout, place: place,
                             how: "\(place == thisMac ? "This Mac" : place) has no GitHub CLI for Oby to sign in with.",
                             state: .broken, way: nil, brand: "github")
        }
        return Connector(id: "github", name: "GitHub", about: gitHubAbout, place: place,
                         how: "Not signed in: Oby can't clone private repositories, push or open pull requests. Signing in uses GitHub's own page.",
                         state: .available, way: .button("Sign In…", .signInGitHub), brand: "github")
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
                         state: connection.secretSaved ? .connected : .broken, way: .button("Disconnect…", .disconnect(connection.name)))
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
}
