import CryptoKit
import Foundation
import Testing
@testable import Oby

/// Settings › Connectors (#498), as Sangam's design: one row per service in his order, Connected then
/// Available, and a search by name or by what it does. Connected is said only of what was checked,
/// and a service Oby can't connect yet is listed as coming, never as connected.
@MainActor
struct ConnectorsTests {
    let personal = AccountState(account: Account(id: "default", agent: "claude", name: "Personal", payer: "", home: nil),
                                label: "Max · someone@example.com", tetrix: true)
    let deskree = AccountState(account: Account(id: "c0de", agent: "codex", name: "Deskree", payer: "Deskree", home: "/tmp/oby/accounts/c0de"),
                               label: "Team · someone@example.com", tetrix: false)
    let cursor = AccountState(account: Account(id: "c5r", agent: "cursor", name: "Cursor", payer: "", home: "/tmp/oby/accounts/c5r"))

    /// A remote runner that says everything it can: its accounts, GitHub, obid's plug-ins and its connections.
    func lab(github: String? = "app", checks: String? = "ok", plugins: [RunnerPlugin]? = nil, connections: [ConnectedApp]? = nil) -> Connectors.RunnerState {
        Connectors.RunnerState(
            name: "tetrix-lab", local: false,
            accounts: [AccountState(account: Account(id: "lab-1", agent: "claude", name: "Lab", payer: "", home: nil), label: "Max", tetrix: true)],
            github: github, checks: checks, plugins: plugins, connections: connections)
    }

    func plugin(_ id: String, enabled: Bool, state: String, lastError: String? = nil) -> RunnerPlugin {
        RunnerPlugin(id: id, name: id.capitalized, version: "0.1.0", kinds: ["agent-mcp"], enabled: enabled, state: state, lastError: lastError)
    }

    /// The ids in the group titled `title`.
    func ids(_ groups: [Connectors.Group], _ title: String) -> [String] {
        groups.first { $0.title == title }?.items.map(\.id) ?? []
    }

    /// A coding tool is one row, the design's name for it: connected while one of its accounts is
    /// signed in, saying which by name (never the email the label carries); Connect, or Manage
    /// Accounts… once connected, opens Settings › Accounts.
    @Test func oneRowPerTool() throws {
        let list = Connectors.list(accounts: [personal, deskree, cursor], runner: nil)
        let claude = try #require(list.first { $0.id == "claude" })
        #expect(claude.name == "Claude" && claude.about == "Run jobs in Claude Code" && claude.brand == "claude")
        #expect(claude.state == .connected && claude.how == "Signed in with Claude Code's own login: Personal")
        #expect(claude.way == .button("Manage Accounts…", .accounts))
        let chatGPT = try #require(list.first { $0.id == "codex" })
        #expect(chatGPT.name == "ChatGPT" && chatGPT.about == "Run jobs in Codex, ask ChatGPT" && chatGPT.brand == "openai" && chatGPT.connected)
        #expect(!list.contains { $0.how.contains("someone@example.com") })
        let signedOut = try #require(list.first { $0.id == "cursor" })
        #expect(signedOut.state == .available && signedOut.how == "Not signed in: Cursor" && signedOut.way == .button("Connect", .accounts))
        #expect(Connectors.list(accounts: [], runner: nil).first { $0.id == "claude" }?.how == "No Claude Code account yet")
    }

    /// The design's ten services, in its order, each with its own mark; then what the runner adds.
    @Test func theDesignsServicesInItsOrder() {
        let mail = ConnectedApp(name: "mail", mcp: "https://mcp.example.com/mcp", api: nil, secret: "mail-token", header: nil, secretSaved: true, lastUsed: nil)
        let list = Connectors.list(accounts: [personal], runner: lab(connections: [mail]))
        #expect(list.map(\.name) == ["Deskree Ops", "Tetrix", "GitHub", "Claude", "ChatGPT", "Cursor", "Slack", "Gmail", "Google Meet", "Zoom", "mail"])
        #expect(list.prefix(10).map(\.brand) == ["deskree", "tetrix", "github", "claude", "openai", "cursor", "slack", "gmail", "meet", "zoom"])
        #expect(list.last?.brand == nil && list.last?.symbol == "link")
    }

    /// With obid on this Mac, the accounts are obid's alone, as Settings › Accounts lists them: this
    /// Mac's own accounts.json names the same logins under other ids (Claude Code's Deskree as
    /// `32203c5b…` beside obid's `deskree`, Codex's default as `codex-default` beside `codex`), and
    /// listing both showed "Claude Code · Deskree" twice. A remote runner adds its own to this Mac's.
    @Test func theAccountsJobsRunOnOnce() {
        func claude(_ id: String, _ name: String) -> AccountState {
            AccountState(account: Account(id: id, agent: "claude", name: name, payer: "", home: nil), label: "Max")
        }
        let mac = [claude("default", "Personal"), claude("32203c5b", "Deskree")]
        let obid = [claude("default", "Personal"), claude("deskree", "Deskree")]
        #expect(Connectors.accounts(mac: mac, runner: obid, local: true, hasRunner: true)?.map(\.account.id) == ["default", "deskree"])
        #expect(Connectors.accounts(mac: mac, runner: obid, local: false, hasRunner: true)?.count == 4)
        #expect(Connectors.accounts(mac: mac, runner: nil, local: false, hasRunner: false)?.map(\.account.id) == ["default", "32203c5b"])
        // A remote runner that doesn't answer leaves this Mac's own; obid on this Mac that doesn't, nothing known yet.
        #expect(Connectors.accounts(mac: mac, runner: nil, local: false, hasRunner: true)?.count == 2)
        #expect(Connectors.accounts(mac: mac, runner: nil, local: true, hasRunner: true) == nil)
        let row = Connectors.list(accounts: Connectors.accounts(mac: mac, runner: obid, local: true, hasRunner: true), runner: nil).first { $0.id == "claude" }
        #expect(row?.how == "Signed in with Claude Code's own login: Personal, Deskree")
    }

    let dogfood = TetrixStatus.Server(preset: "dogfood", name: "Tetrix Dogfood", url: URL(string: "https://mcp.tetrix.dev/mcp")!)

    /// Tetrix is one row, Sangam's "Tetrix", held by obid for every agent: not connected, it names
    /// "Tetrix Dogfood" with Connect and Another Tetrix…; signing in, Open the Page Again and Cancel;
    /// connected, Disconnect. No per-account rows, and obid's older tetrix plug-in isn't listed beside it.
    @Test func tetrixOnceForEveryAgent() throws {
        var runner = Connectors.RunnerState(name: "This Mac", local: true, accounts: [], plugins: [plugin("tetrix", enabled: false, state: "disabled")])
        runner.tetrix = TetrixStatus(presets: [dogfood])
        let list = Connectors.list(accounts: [personal, deskree], runner: runner)
        #expect(list.filter { $0.about == Connectors.tetrixAbout }.map(\.id) == ["tetrix"])
        let ready = try #require(list.first { $0.id == "tetrix" })
        #expect(ready.name == "Tetrix" && ready.state == .available && ready.place == "This Mac" && ready.brand == "tetrix")
        #expect(ready.how == "Tetrix Dogfood: every agent on every account uses it. You sign in once, on Tetrix's own page.")
        #expect(ready.way == .button("Connect", .connectTetrix(dogfood)) && ready.also == .button("Another Tetrix…", .connectOtherTetrix))

        let signingIn = TetrixStatus(url: dogfood.url, preset: "dogfood", presets: [dogfood],
                                     signIn: TetrixSignIn(url: URL(string: "https://auth.tetrix.dev/authorize?x=1")!, server: URL(string: "https://auth.tetrix.dev")))
        let signing = Connectors.tetrix(signingIn, place: "This Mac", local: true)
        #expect(signing.state == .unconfirmed && signing.how == "Signing in to Tetrix Dogfood in your browser…")
        #expect(signing.way == .button("Open the Page Again", .reopenTetrixSignIn) && signing.also == .button("Cancel", .cancelTetrixSignIn))

        let connected = TetrixStatus(connected: true, url: dogfood.url, preset: "dogfood", presets: [dogfood])
        let on = Connectors.tetrix(connected, place: "This Mac", local: true)
        #expect(on.state == .connected && on.name == "Tetrix" && on.how == "Signed in to Tetrix Dogfood. Every agent on every account uses it.")
        #expect(on.way == .button("Disconnect…", .disconnectTetrix) && on.also == nil)

        // A failed sign-in says why; a runner that knows no server asks for one.
        let failed = Connectors.tetrix(TetrixStatus(presets: [dogfood], error: "Tetrix refused the sign-in."), place: "This Mac", local: true)
        #expect(failed.state == .broken && failed.how == "Tetrix refused the sign-in.")
        #expect(Connectors.tetrix(TetrixStatus(), place: "This Mac", local: true).way == .button("Connect…", .connectOtherTetrix))
    }

    /// Slack, held by obid for its watcher with the owner's own app's tokens: a real row once obid
    /// says it holds Slack, Connect… asking for the two tokens, and the watcher's Slack message
    /// switched here.
    @Test func slackOnceObidHoldsIt() throws {
        var runner = Connectors.RunnerState(name: "This Mac", local: true, accounts: [])
        #expect(try #require(Connectors.list(accounts: [], runner: runner).first { $0.id == "slack" }).soon, "coming until obid says")
        runner.slack = SlackStatus()
        let first = try #require(Connectors.list(accounts: [], runner: runner).first { $0.id == "slack" })
        #expect(!first.soon && first.state == .available && first.brand == "slack")
        #expect(first.way == .button("Connect…", .connectSlack) && first.also == nil)

        let refused = Connectors.slack(SlackStatus(error: "Slack refused Oby's tokens: paste new ones in Settings › Connectors › Slack."),
                                       watch: nil, place: "This Mac", local: true)
        #expect(refused.state == .broken && refused.how.hasPrefix("Slack refused"))

        let dry = WatchStatus(rules: .init(name: "Dmitry watcher", live: false, enabled: true))
        let on = Connectors.slack(SlackStatus(connected: true, team: "Deskree"), watch: dry, place: "This Mac", local: true)
        #expect(on.state == .connected && on.way == .button("Disconnect…", .disconnectSlack))
        #expect(on.also == .button("Watcher: Send Slack Messages", .setWatchLive(true)))
        #expect(on.how.hasSuffix("Dmitry watcher: a dry run, it tells you in Oby and only writes down the Slack message."))
        #expect(on.more == .button("Reviews: Tell Authors on Slack", .setTellAuthors(true)))
        let telling = Connectors.slack(SlackStatus(connected: true, tellAuthors: true), watch: nil, place: "This Mac", local: true)
        #expect(telling.more == .button("Reviews: Don't Tell Authors", .setTellAuthors(false)))
        #expect(telling.how.contains("to the author of a pull request once your review of it is posted"))
        #expect(first.more == nil, "only once connected")
        let live = WatchStatus(rules: .init(name: "Dmitry watcher", live: true, enabled: true))
        #expect(Connectors.slack(SlackStatus(connected: true), watch: live, place: "This Mac", local: true).also
                == .button("Watcher: Dry Run Only", .setWatchLive(false)))

        let remote = Connectors.slack(SlackStatus(), watch: nil, place: "tetrix-lab", local: false)
        #expect(remote.also == nil && remote.more == nil && remote.way == .steps("Connect or disconnect it on tetrix-lab itself, with Oby there."))
    }

    /// Connect takes only what looks like each kind of token.
    @Test func onlySlackTokensOfTheirKindAreTaken() {
        let user = "xoxp-" + "1111-2222-3333-7c41e09b2fd8a365"
        #expect(SlackStatus.isToken(user, "xoxp-") && SlackStatus.isToken(" \(user)\n", "xoxp-"))
        #expect(!SlackStatus.isToken(user, "xoxb-") && !SlackStatus.isToken("xoxp-short", "xoxp-"))
        #expect(!SlackStatus.isToken("xoxp-1111 2222-3333-7c41e09b2fd8", "xoxp-"))
    }

    /// A remote runner's Tetrix has no button in any state: its sign-in comes back to 127.0.0.1 on
    /// that machine, so it's done there.
    @Test func aRemoteRunnersTetrixIsDoneThere() throws {
        var runner = lab()
        for status in [TetrixStatus(presets: [dogfood]),
                       TetrixStatus(url: dogfood.url, preset: "dogfood", signIn: TetrixSignIn(url: URL(string: "https://mcp.tetrix.dev/a")!, server: dogfood.url)),
                       TetrixStatus(connected: true, url: dogfood.url, preset: "dogfood")] {
            runner.tetrix = status
            let row = try #require(Connectors.list(accounts: [], runner: runner).first { $0.id == "tetrix" })
            #expect(row.way == .steps("Connect or disconnect it on tetrix-lab itself, with Oby there: Tetrix's sign-in comes back to that machine.") && row.also == nil)
        }
    }

    /// Tetrix (obid's older plug-in, from a runner without obid's own Tetrix), the runner's other
    /// plug-ins and its connections are listed under its name.
    @Test func theRunnersConnections() throws {
        let plugins = [plugin("tetrix", enabled: true, state: "ready"), RunnerPlugin(id: "notes", name: "Notes", version: nil, kinds: ["context", "events"], enabled: false, state: "disabled", lastError: nil)]
        let mail = ConnectedApp(name: "mail", mcp: "https://mcp.example.com/mcp", api: nil, secret: "mail-token", header: nil, secretSaved: true, lastUsed: nil)
        let list = Connectors.list(accounts: [personal], runner: lab(plugins: plugins, connections: [mail]))
        #expect(list.filter { $0.name == "Tetrix" }.count == 1)

        let tetrix = try #require(list.first { $0.id == "plugin-tetrix" })
        #expect(tetrix.state == .connected && tetrix.how == "A plug-in of obid's (0.1.0) · Ready" && tetrix.way == .button("Disconnect", .disablePlugin("tetrix")))
        let off = try #require(list.first { $0.id == "plugin-notes" })
        #expect(off.state == .available && off.about == "Context for jobs, events in your inbox")
        #expect(off.way == .button("Connect…", .enablePlugin(id: "notes", needsURL: false)))

        let connection = try #require(list.first { $0.id == "connection-mail" })
        #expect(connection.state == .connected && connection.about == "MCP server at mcp.example.com")
        #expect(connection.how == "The vault secret mail-token, as Authorization: Bearer")
        #expect(connection.way == .button("Disconnect…", .disconnect("mail")))
    }

    /// GitHub as the app is checked (its last token request worked); as the owner's gh login it's
    /// only who the calls act as: the runner never asks gh (#517), so it's not said to be connected.
    @Test func gitHubIsConnectedOnlyWhenChecked() throws {
        let app = try #require(Connectors.list(accounts: [], runner: lab()).first { $0.id == "github" })
        #expect(app.state == .connected && app.place == "tetrix-lab")
        #expect(app.how.hasPrefix("Oby's GitHub app, whose last token request worked") && app.how.hasSuffix("Check runs reach pull requests."))
        guard case .steps(let unset) = app.way else { Issue.record("GitHub has no steps"); return }
        #expect(unset.contains("OBY_GITHUB_APP_ID") && unset.contains("tetrix-lab"))

        let list = Connectors.list(accounts: [], runner: Connectors.RunnerState(name: "This Mac", local: true, accounts: [], github: "owner", checks: "no app"))
        let owner = try #require(list.first { $0.id == "github" })
        #expect(owner.state == .unconfirmed && !owner.connected)
        #expect(owner.how == "Acts as your gh login on this Mac. The runner doesn't check that it's signed in. No check runs: they need the GitHub app.")
        #expect(owner.way == .steps("To disconnect it, run gh auth logout on this Mac. Oby can't clone, push or open pull requests until you sign in again with gh auth login."))
        #expect(ids(Connectors.groups(list, query: "github"), "Available") == ["github"])
        #expect(ids(Connectors.groups(list, query: ""), "Connected").isEmpty)
    }

    /// With obid saying whether its gh is signed in (`GET /v1/github`), GitHub is connected as its
    /// user, or offers gh's own sign-in; with no gh at all it can't work.
    @Test func gitHubFollowsObidsGhLogin() throws {
        func row(_ login: GitHubLogin) throws -> Connector {
            let runner = Connectors.RunnerState(name: "This Mac", local: true, accounts: [], github: "owner", checks: "no app", gitHubLogin: login)
            return try #require(Connectors.list(accounts: [], runner: runner).first { $0.id == "github" })
        }
        let signed = try row(GitHubLogin(gh: true, signedIn: true, user: "octo-cat", signIn: nil))
        #expect(signed.state == .connected && signed.how.contains("as octo-cat"))
        let out = try row(GitHubLogin(gh: true, signedIn: false, user: nil, signIn: nil))
        #expect(out.state == .available && out.way == .button("Sign In…", .signInGitHub))
        let none = try row(GitHubLogin(gh: false, signedIn: false, user: nil, signIn: nil))
        #expect(none.state == .broken && none.way == nil)
    }

    /// The Mac opens and copies only what gh's sign-in gives: GitHub's device page, and a code of
    /// two groups of four capitals or digits.
    @Test func onlyGitHubsDevicePageAndCodeAreTaken() {
        func signIn(_ url: String, _ code: String) -> GitHubSignIn {
            GitHubSignIn(url: URL(string: url)!, userCode: code, expiresAt: "2026-10-18T20:00:00Z")
        }
        #expect(signIn("https://github.com/login/device", "AB12-CD34").isGitHubs)
        #expect(!signIn("https://github.com/login/device?x=1", "AB12-CD34").isGitHubs)
        #expect(!signIn("http://github.com/login/device", "AB12-CD34").isGitHubs)
        #expect(!signIn("https://github.com.evil.example/login/device", "AB12-CD34").isGitHubs)
        #expect(!signIn("https://example.com/login/device", "AB12-CD34").isGitHubs)
        #expect(!signIn("https://github.com/login/device", "ab12-cd34").isGitHubs)
        #expect(!signIn("https://github.com/login/device", "AB12-CD34 && rm").isGitHubs)
        #expect(!signIn("https://github.com/login/device", "AB12CD34").isGitHubs)
    }

    /// What can't work isn't connected: a connection whose vault secret is missing (every call
    /// fails, Runner/Broker.swift) and a plug-in obid gave up on need attention, with the reason; a
    /// plug-in still starting isn't confirmed yet.
    @Test func whatCantWorkNeedsAttention() throws {
        let api = ConnectedApp(name: "linear", mcp: nil, api: "https://api.linear.app", secret: "linear-key", header: "X-Api-Key", secretSaved: false, lastUsed: nil)
        let missing = Connectors.connection(api, place: "tetrix-lab")
        #expect(missing.state == .broken && missing.about == "API at api.linear.app")
        #expect(missing.how == "Its vault secret linear-key is missing, so agents' calls fail: add it on the runner with oby-runner vault add linear-key")
        #expect(missing.way == .button("Disconnect…", .disconnect("linear")))
        var saved = api
        saved.secretSaved = true
        #expect(Connectors.connection(saved, place: "tetrix-lab").state == .connected)
        #expect(Connectors.connection(saved, place: "tetrix-lab").how == "The vault secret linear-key, in the header X-Api-Key")

        let failed = Connectors.plugin(plugin("tetrix", enabled: true, state: "failed", lastError: "It exited 3 times in a row."), place: "This Mac")
        #expect(failed.state == .broken && failed.how == "A plug-in of obid's (0.1.0) · Failed: It exited 3 times in a row.")
        #expect(failed.way == .button("Disconnect", .disablePlugin("tetrix")))
        #expect(Connectors.plugin(plugin("tetrix", enabled: true, state: "failed"), place: "This Mac").how.hasSuffix("Failed, and obid didn't say why"))
        let starting = Connectors.plugin(plugin("tetrix", enabled: true, state: "starting"), place: "This Mac")
        #expect(starting.state == .unconfirmed && starting.how.hasSuffix("Starting"))

        // The design's two groups: what isn't connected is Available, saying what it needs on its row.
        let groups = Connectors.groups([missing, failed, starting], query: "")
        #expect(groups.map(\.title) == ["Available"] && ids(groups, "Available") == ["connection-linear", "plugin-tetrix", "plugin-tetrix"])
    }

    /// While the runner doesn't answer (or there's none), Tetrix and GitHub, which it holds, say they
    /// wait for it, never connected; so do the coding tools while obid on this Mac, which holds their
    /// accounts, doesn't answer (no "No account yet" and Connect). The runner's plug-ins and connections aren't listed.
    @Test func whatTheRunnerHoldsWaitsForIt() throws {
        let list = Connectors.list(accounts: [personal], runner: nil)
        for id in ["tetrix", "github"] {
            let row = try #require(list.first { $0.id == id })
            #expect(row.state == .available && row.way == .steps("Shows here once Oby's runner answers (Settings › Runner)."))
        }
        let silent = Connectors.list(accounts: Connectors.accounts(mac: [personal], runner: nil, local: true, hasRunner: true), runner: nil)
        for id in ["claude", "codex", "cursor"] {
            let row = try #require(silent.first { $0.id == id })
            #expect(!row.connected && row.way == .steps("Shows here once Oby's runner answers (Settings › Runner)."))
        }
        #expect(list.count == 10)
        #expect(Connectors.list(accounts: [], runner: lab(github: nil)).first { $0.id == "github" }?.way
                == .steps("tetrix-lab doesn't say: it needs a newer runner."))
    }

    /// The design's services Oby can't connect yet (Deskree Ops #502, Slack #26, Gmail #501, Google
    /// Meet #503, Zoom #504) are listed under Available, as coming, with no button: never connected.
    @Test func servicesNotYetConnectableAreComing() {
        let everything = Connectors.list(accounts: [personal, deskree, cursor], runner: lab())
        let coming = everything.filter(\.soon)
        #expect(coming.map(\.name) == ["Deskree Ops", "Slack", "Gmail", "Google Meet", "Zoom"])
        #expect(coming.allSatisfy { $0.state == .available && $0.way == nil && $0.also == nil })
        #expect(coming.map(\.about) == ["Projects, deploys and incidents", "Read and send messages", "Read and manage your email",
                                        "Join meetings and keep the notes", "Join meetings and keep the notes"])
    }

    /// Search finds a service by its name or by what it does, whatever the case and accents, every
    /// word anywhere in it; an empty search shows everything, Connected then Available.
    @Test func searchByNameOrWhatItDoes() {
        let list = Connectors.list(accounts: [personal, deskree, cursor], runner: lab())
        #expect(ids(Connectors.groups(list, query: "codex"), "Connected") == ["codex"])
        #expect(ids(Connectors.groups(list, query: "  PULL requests "), "Connected") == ["github"])
        #expect(ids(Connectors.groups(list, query: "CLÁUDE"), "Connected") == ["claude"])
        #expect(ids(Connectors.groups(list, query: "meetings notes"), "Available") == ["meet", "zoom"])
        let all = Connectors.groups(list, query: "")
        #expect(all.map(\.title) == ["Connected", "Available"])
        #expect(all.map(\.items.count).reduce(0, +) == list.count)
        #expect(ids(all, "Connected") == ["github", "claude", "codex"])
        #expect(ids(all, "Available") == ["deskree", "tetrix", "cursor", "slack", "gmail", "meet", "zoom"])
        #expect(Connectors.groups(list, query: "nothing like it").isEmpty)
        // Where a row is isn't shown, so it isn't searched: "mac" isn't in every row.
        #expect(Connectors.groups(list, query: "this mac").isEmpty && Connectors.groups(list, query: "tetrix-lab").isEmpty)
    }

    /// Once connected, the steps to disconnect where Oby has no button (gh auth logout, a remote
    /// runner's Tetrix) are in the row's tooltip, since the row no longer shows them.
    @Test func disconnectStepsStayFindable() throws {
        let gh = Connectors.gitHub(GitHubLogin(gh: true, signedIn: true, user: "octo-cat", signIn: nil), place: "This Mac")
        #expect(gh.connected && gh.tip == gh.how + "\nTo disconnect it, run gh auth logout on this Mac.")
        let app = try #require(Connectors.list(accounts: [], runner: lab()).first { $0.id == "github" })
        #expect(app.connected && app.tip.contains("OBY_GITHUB_APP_ID"))
        var runner = lab()
        runner.tetrix = TetrixStatus(connected: true, url: dogfood.url, preset: "dogfood")
        let tetrix = try #require(Connectors.list(accounts: [], runner: runner).first { $0.id == "tetrix" })
        #expect(tetrix.connected && tetrix.tip.hasSuffix("Connect or disconnect it on tetrix-lab itself, with Oby there: Tetrix's sign-in comes back to that machine."))
        // A row with a button keeps it in the context menu, so the tooltip is only how it's signed in.
        let local = Connectors.tetrix(TetrixStatus(connected: true, url: dogfood.url, preset: "dogfood"), place: "This Mac", local: true)
        #expect(local.tip == local.how)
        #expect(Connectors.list(accounts: [], runner: nil).first { $0.id == "zoom" }?.tip == "Oby can't connect Zoom yet.")
    }

    /// While the runner doesn't answer its rows are left out, and the page says why; the Tetrix
    /// URL must be HTTPS with a host before Connect does anything.
    @Test func whatThePageSaysAndTakes() {
        #expect(Connectors.waiting(for: "tetrix-lab", .live) == nil)
        #expect(Connectors.waiting(for: "tetrix-lab", .connecting) == "Connecting to tetrix-lab… Its accounts, GitHub, plug-ins and connections show here once it answers.")
        #expect(Connectors.waiting(for: "tetrix-lab", .offline("The request timed out"))
                == "tetrix-lab isn't answering: The request timed out. Its accounts, GitHub, plug-ins and connections show here once it answers.")
        #expect(Connectors.isURL("https://tetrix.example.com/mcp"))
        #expect(!Connectors.isURL("") && !Connectors.isURL("https://") && !Connectors.isURL("http://tetrix.example.com/mcp"))
    }

    /// The runner's status says who its GitHub calls go as; an older runner says nothing.
    @Test func statusSaysTheGitHubLogin() throws {
        let body = #"{"runner": {"version": "0.2.0", "host": "tetrix-lab"}, "accounts": [], "models": {"claude": {"model": "m", "effort": "high"}, "codex": {"model": "c", "effort": "high"}}, "github": "app", "checks": "missing permission"}"#
        let status = try Runner.decoder.decode(RunnerStatus.self, from: Data(body.utf8))
        #expect(status.github == "app" && status.checks == "missing permission")
        let older = try Runner.decoder.decode(RunnerStatus.self, from: Data(body.replacingOccurrences(of: #", "github": "app", "checks": "missing permission""#, with: "").utf8))
        #expect(older.github == nil && older.checks == nil)
    }

    /// The runner's connections and obid's plug-ins are read from the runner; a runner without them
    /// (404) has none to list, which isn't an error.
    @Test func readsConnectionsAndPlugins() async throws {
        let swift = RunnerStub { request in
            switch request.path {
            case "/v1/connections":
                (200, #"[{"name": "mail", "mcp": "https://mcp.example.com/mcp", "api": null, "secret": "mail-token", "header": "Authorization", "created": "2026-10-11T16:02:11Z", "secretSaved": true, "lastUsed": "2026-10-11T16:20:03Z"}]"#)
            default: (404, #"{"error": "Not found."}"#)
            }
        }
        let lists = await Connectors.lists(from: swift.runner, name: "tetrix-lab")
        #expect(lists.connections?.map(\.name) == ["mail"] && lists.connections?.first?.lastUsed != nil)
        #expect(lists.plugins == nil && lists.problems.isEmpty)

        let obid = RunnerStub { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/obid/plugins"):
                (200, #"[{"id": "tetrix", "name": "Tetrix", "version": "0.1.0", "kinds": ["agent-mcp"], "enabled": false, "state": "disabled", "lastError": null}]"#)
            case ("PUT", "/v1/obid/plugins/tetrix"):
                (200, #"{"id": "tetrix", "name": "Tetrix", "version": "0.1.0", "kinds": ["agent-mcp"], "enabled": true, "state": "ready", "lastError": null}"#)
            default: (404, "")
            }
        }
        let obidLists = await Connectors.lists(from: obid.runner, name: "This Mac")
        #expect(obidLists.connections == nil && obidLists.plugins?.map(\.state) == ["disabled"] && obidLists.problems.isEmpty)
        let on = try await obid.runner.setPlugin("tetrix", enabled: true, config: ["url": "https://tetrix.example.com/mcp"])
        #expect(on.enabled && on.state == "ready")
        let put = try #require(obid.requests.last?.json)
        #expect(put["enabled"] as? Bool == true && (put["config"] as? [String: String]) == ["url": "https://tetrix.example.com/mcp"])
        _ = try await obid.runner.setPlugin("tetrix", enabled: false)
        #expect(obid.requests.last?.json?.keys.sorted() == ["enabled"])
    }

    /// A read that fails for another reason than "none to list" (a 500, a 401) is said, with why,
    /// and is never taken for an empty list.
    @Test func aFailedReadIsSaidNotHidden() async {
        let failing = RunnerStub { request in
            request.path == "/v1/connections" ? (500, #"{"error": "The runner couldn't read connections.json."}"#) : (401, "")
        }
        let lists = await Connectors.lists(from: failing.runner, name: "tetrix-lab")
        #expect(lists.plugins == nil && lists.connections == nil)
        #expect(lists.problems == ["Couldn't read the plug-ins on tetrix-lab: The runner didn't let this device in.",
                                   "Couldn't read the connections on tetrix-lab: The runner couldn't read connections.json.",
                                   "Couldn't read Tetrix on tetrix-lab: The runner didn't let this device in.",
                                   "Couldn't read Slack on tetrix-lab: The runner didn't let this device in.",
                                   "Couldn't read the watcher on tetrix-lab: The runner didn't let this device in.",
                                   "Couldn't read Sentry on tetrix-lab: The runner didn't let this device in.",
                                   "Couldn't read the alerting hooks on tetrix-lab: The runner didn't let this device in."])
    }

    /// Sentry is a row of its own once obid has it (the owner's decision of 2026-10-23, #1117):
    /// Connect… asks for its address, the organization and a token; connected, Disconnect… and
    /// Projects…; a remote runner's is done there.
    @Test func sentryOnceObidHoldsIt() throws {
        var runner = Connectors.RunnerState(name: "This Mac", local: true, accounts: [])
        #expect(!Connectors.list(accounts: [], runner: runner).contains { $0.id == "sentry" }, "no row until obid says")
        runner.sentry = SentryStatus()
        let first = try #require(Connectors.list(accounts: [], runner: runner).first { $0.id == "sentry" })
        #expect(first.state == .available && first.way == .button("Connect…", .connectSentry) && first.brand == nil)
        #expect(first.about == "Errors in your projects")
        let refused = Connectors.sentry(SentryStatus(error: "Sentry refused Oby's token: paste a new one in Settings › Connectors › Sentry."),
                                        place: "This Mac", local: true)
        #expect(refused.state == .broken && refused.how.hasPrefix("Sentry refused"))
        let on = Connectors.sentry(SentryStatus(connected: true, org: "acme",
                                                projects: [.init(slug: "api", name: "API", follow: true, repo: "obi-ai-bot/obi"),
                                                           .init(slug: "web", name: "Web", follow: false, repo: nil)]),
                                   place: "This Mac", local: true)
        #expect(on.state == .connected && on.way == .button("Disconnect…", .disconnectSentry) && on.also == .button("Projects…", .sentryProjects))
        #expect(on.how.contains("Following API (obi-ai-bot/obi).") && !on.how.contains("Web"))
        let remote = Connectors.sentry(SentryStatus(), place: "tetrix-lab", local: false)
        #expect(remote.way == .steps("Connect or disconnect it on tetrix-lab itself, with Oby there.") && remote.also == nil)
        // Connect… takes only what looks like Sentry's address, an organization's slug and a token.
        #expect(SentryStatus.isURL("https://sentry.io") && SentryStatus.isURL("https://de.sentry.io/"))
        #expect(!SentryStatus.isURL("http://sentry.io") && !SentryStatus.isURL("https://sentry.io/acme") && !SentryStatus.isURL("https://me@sentry.io"))
        #expect(SentryStatus.isOrg("acme-1") && !SentryStatus.isOrg("Acme") && !SentryStatus.isOrg(""))
        #expect(SentryStatus.isToken("sntryu_" + "4f1c9a7e2b8d4c6fa0e3b5d7") && !SentryStatus.isToken("short"))
        #expect(!SentryStatus.isToken("has a space in it and is long enough"))
    }

    /// Prometheus and Grafana are rows of their own once obid has hooks (#1311): Connect… makes the
    /// hook; connected, Disconnect… removes it, and a refused delivery needs attention.
    @Test func alertingToolsOnceObidHasHooks() throws {
        var runner = Connectors.RunnerState(name: "This Mac", local: true, accounts: [])
        #expect(!Connectors.list(accounts: [], runner: runner).contains { $0.id == "prometheus" }, "no rows until obid has hooks")
        runner.hooks = []
        let list = Connectors.list(accounts: [], runner: runner)
        let prometheus = try #require(list.first { $0.id == "prometheus" })
        #expect(prometheus.name == "Prometheus" && prometheus.about == "Alerts from Alertmanager" && prometheus.way == .button("Connect…", .connectAlerts("alertmanager")))
        #expect(prometheus.brand == nil && prometheus.symbol == "flame" && prometheus.how.contains("Remote access"))
        #expect(list.first { $0.id == "grafana" }?.way == .button("Connect…", .connectAlerts("grafana")))
        let hook = Runner.HookRow(id: "abcdefghij0123456789abcdefghij01", name: "prometheus", source: "alertmanager", repo: "obi-ai-bot/obi",
                                  url: "https://oby-control.test/h/abcdefghij0123456789abcdefghij01",
                                  lastDelivery: .init(at: .now, result: "accepted"))
        runner.hooks = [hook]
        let on = try #require(Connectors.list(accounts: [], runner: runner).first { $0.id == "prometheus" })
        #expect(on.state == .connected && on.way == .button("Disconnect…", .disconnectAlerts(hook.id)))
        #expect(on.how.contains("obi-ai-bot/obi") && on.how.contains("Last delivery: accepted."))
        var refused = hook
        refused.lastDelivery?.result = "bad signature"
        #expect(Connectors.alerting(AlertingTool.all[0], hook: refused, place: "This Mac", local: true).state == .broken)
        let remote = Connectors.alerting(AlertingTool.all[1], hook: nil, place: "tetrix-lab", local: false)
        #expect(remote.way == .steps("Connect or disconnect it on tetrix-lab itself, with Oby there."))
        // What to paste where: the address and the secret, in each tool's own words.
        let steps = AlertingTool.all[0].steps(url: "https://oby-control.test/h/x", secret: "s3cret")
        #expect(steps.contains("url: https://oby-control.test/h/x") && steps.contains("X-Oby-Token:") && steps.contains(#"secrets: ["s3cret"]"#))
        #expect(AlertingTool.all[1].steps(url: "u", secret: "s").contains("X-Grafana-Alerting-Timestamp"))
        #expect(AlertingTool.all[0].steps(url: "u", secret: "s", label: "job").contains("the alert's job label"))
        // PagerDuty (#1312): its own secret, pasted back after the address; no project label.
        let pagerDuty = try #require(AlertingTool.all.first { $0.id == "pagerduty" })
        #expect(pagerDuty.secretFromTool && !pagerDuty.asksLabel && !AlertingTool.all[0].secretFromTool)
        #expect(pagerDuty.steps(url: "https://oby-control.test/h/x", secret: "").contains("incident.triggered, incident.reopened and incident.resolved"))
        #expect(list.first { $0.id == "pagerduty" }?.way == .button("Connect…", .connectAlerts("pagerduty")))
        // Datadog (#1313): Oby's payload and the token in a hidden variable; the project is the service tag.
        let datadog = try #require(AlertingTool.all.first { $0.id == "datadog" })
        #expect(!datadog.secretFromTool && !datadog.asksLabel)
        let dd = datadog.steps(url: "https://oby-control.test/h/x", secret: "s3cret")
        #expect(dd.contains(#""oby": 1"#) && dd.contains(#"{"X-Oby-Token": "$OBY_TOKEN"}"#) && dd.contains("s3cret"))
        #expect(list.first { $0.id == "datadog" }?.way == .button("Connect…", .connectAlerts("datadog")))
    }

    /// The Mac reads obid's Sentry, connects it and follows a project as obid answers; a repository
    /// taken off is sent as null.
    @Test func sentryConnectsAndListsItsProjects() async throws {
        let obid = RunnerStub { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/sentry"):
                (200, #"{"connected": false, "projects": [], "repos": ["obi-ai-bot/obi"], "error": null}"#)
            case ("PUT", "/v1/sentry"):
                (200, #"{"connected": true, "url": "https://sentry.io", "org": "acme", "user": "me@example.com", "projects": [{"slug": "api", "name": "API", "follow": false, "repo": null}], "repos": ["obi-ai-bot/obi"], "error": null}"#)
            case ("PATCH", "/v1/sentry/projects/api"):
                (200, #"{"connected": true, "org": "acme", "projects": [{"slug": "api", "name": "API", "follow": true, "repo": "obi-ai-bot/obi"}], "repos": ["obi-ai-bot/obi"]}"#)
            default: (404, "")
            }
        }
        let lists = await Connectors.lists(from: obid.runner, name: "This Mac")
        #expect(lists.sentry?.connected == false && lists.sentry?.repos == ["obi-ai-bot/obi"] && lists.problems.isEmpty)
        let connected = try await obid.runner.connectSentry(url: "https://sentry.io", org: "acme", token: "sntryu_test")
        #expect(connected.connected && connected.projects.map(\.slug) == ["api"] && connected.org == "acme")
        let put = try #require(obid.requests.last?.json)
        #expect(put["url"] as? String == "https://sentry.io" && put["org"] as? String == "acme" && put["token"] as? String == "sntryu_test")
        let followed = try await obid.runner.setSentryProject("api", .follow(true))
        #expect(followed.projects.first?.follow == true && followed.projects.first?.repo == "obi-ai-bot/obi")
        #expect(obid.requests.last?.json?.keys.sorted() == ["follow"], "only the field that changed")
        _ = try await obid.runner.setSentryProject("api", .repo(nil))
        let off = try #require(obid.requests.last?.json)
        #expect(off.keys.sorted() == ["repo"] && off["repo"] is NSNull, "a repository taken off is sent as null")
        // A runner without Sentry (404) has no row, and says nothing's wrong.
        let old = RunnerStub { _ in (404, "") }
        let oldLists = await Connectors.lists(from: old.runner, name: "tetrix-lab")
        #expect(oldLists.sentry == nil && !oldLists.problems.contains { $0.contains("Sentry") })
    }

    /// Disconnecting a runner's connection signs the runner's own sentence, under the connection
    /// prefix, after Touch ID: a publish's signature can't pass for it, nor it for a publish's.
    @Test func disconnectSignsTheRunnersSentence() async throws {
        let stub = RunnerStub { request in
            switch (request.method, request.path) {
            case ("POST", "/v1/devices"): (200, #"{"id": "d7c1"}"#)
            case ("DELETE", "/v1/connections/mail") where request.body.isEmpty:
                (403, #"{"error": "Approve this on your iPhone first: Disconnect mail.", "action": "Disconnect mail."}"#)
            case ("DELETE", "/v1/connections/mail"): (200, #"{"removed": "mail"}"#)
            default: (404, #"{"error": "No."}"#)
            }
        }
        let key = FakeKey()
        let device = MacDevice(key: key, name: "Mac", defaults: stub.defaults)
        try await device.disconnect("mail", with: stub.runner)
        let sent = stub.requests
        #expect(sent.map(\.method) == ["POST", "DELETE", "DELETE"])
        let approval = try #require(sent.last?.json?["approval"] as? [String: String])
        #expect(approval["device"] == "d7c1" && approval["action"] == "Disconnect mail.")
        let der = try #require(approval["signature"].flatMap { Data(base64Encoded: $0) })
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        let signedAt = try #require(approval["signedAt"])
        #expect(key.signing.publicKey.isValidSignature(signature, for: Approval.connectionMessage(action: "Disconnect mail.", signedAt: signedAt)))
        #expect(!key.signing.publicKey.isValidSignature(signature, for: Approval.message(job: "", action: "Disconnect mail.", signedAt: signedAt)))
        #expect(String(decoding: Approval.connectionMessage(action: "Disconnect mail.", signedAt: "2026-10-16T12:00:00Z"), as: UTF8.self)
                == "oby-connection\nDisconnect mail.\n2026-10-16T12:00:00Z")
    }

    /// The same prefix approves adding a connection, so this Mac signs only "Disconnect <name>.":
    /// a runner asking for anything else (here, a connection carrying a secret to another host)
    /// gets no signature, and a cancelled Touch ID sends none either.
    @Test func disconnectSignsNothingElse() async throws {
        let other = "Connect mail: agents' read-only calls to the MCP server https://elsewhere.example/mcp carry the vault secret github-token as Authorization: Bearer."
        let asking = RunnerStub { request in
            switch (request.method, request.path) {
            case ("POST", "/v1/devices"): (200, #"{"id": "d7c1"}"#)
            case ("DELETE", "/v1/connections/mail") where request.body.isEmpty: (403, #"{"error": "Approve this.", "action": "\#(other)"}"#)
            case ("DELETE", "/v1/connections/mail"): (200, #"{"removed": "mail"}"#)
            default: (404, #"{"error": "No."}"#)
            }
        }
        let device = MacDevice(key: FakeKey(), name: "Mac", defaults: asking.defaults)
        let error = await #expect(throws: RunnerError.self) { try await device.disconnect("mail", with: asking.runner) }
        #expect(error?.message == "The runner asked this Mac to approve something other than disconnecting mail, so nothing was signed.")
        let deletes = asking.requests.filter { $0.method == "DELETE" }
        #expect(deletes.count == 1 && deletes.first?.body.isEmpty == true)

        let fair = RunnerStub { request in
            switch (request.method, request.path) {
            case ("POST", "/v1/devices"): (200, #"{"id": "d7c1"}"#)
            case ("DELETE", "/v1/connections/mail"): (403, #"{"error": "Approve this.", "action": "Disconnect mail."}"#)
            default: (404, #"{"error": "No."}"#)
            }
        }
        let refusing = MacDevice(key: FakeKey(cancels: true), name: "Mac", defaults: fair.defaults)
        await #expect(throws: RunnerError.self) { try await refusing.disconnect("mail", with: fair.runner) }
        let asked = fair.requests.filter { $0.method == "DELETE" }
        #expect(asked.count == 1 && asked.first?.body.isEmpty == true)
    }
}
