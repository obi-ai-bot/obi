import CryptoKit
import Foundation
import Testing
@testable import Oby

/// Settings › Connectors (#498): every connection that exists today, each with how it's signed in
/// and how to disconnect it, and a search by name or by what it does. Connected is said only of
/// what was checked, and nothing listed is a placeholder.
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

    /// This Mac's signed-in accounts are connected, with how they signed in (the plan, never the
    /// email) and a Disconnect that removes them; a signed-out one is available, with Sign In.
    @Test func thisMacsAccounts() throws {
        let list = Connectors.list(mac: [personal, deskree, cursor], runner: nil)
        let claude = try #require(list.first { $0.id == "account-This Mac-default" })
        #expect(claude.name == "Claude Code · Personal" && claude.about == "Runs jobs in Claude Code" && claude.place == "This Mac")
        #expect(claude.state == .connected && claude.how == "Signed in with Claude Code's own login · Max")
        #expect(claude.way == .button("Disconnect…", .removeAccount(personal.account)))
        #expect(!list.contains { $0.how.contains("someone@example.com") })
        let signedOut = try #require(list.first { $0.id == "account-This Mac-c5r" })
        #expect(signedOut.state == .available && signedOut.how == "Not signed in" && signedOut.way == .button("Sign In", .signIn(cursor.account)))
    }

    /// Tetrix for each account once its tool has said: signed in is connected, with the tool's own
    /// sign-out; not signed in is available, with the tool's own login. Not said yet: not listed.
    /// Oby never reads Cursor's MCP list, so a Cursor account gets no Tetrix row at all.
    @Test func tetrixPerAccount() throws {
        var cursorWithTetrix = cursor
        cursorWithTetrix.label = "Pro"
        cursorWithTetrix.tetrix = true
        let list = Connectors.list(mac: [personal, deskree, cursorWithTetrix], runner: nil)
        let tetrix = list.filter { $0.name == "Tetrix" }
        #expect(tetrix.map(\.id) == ["tetrix-This Mac-default", "tetrix-This Mac-c0de"])
        let on = try #require(tetrix.first)
        #expect(on.state == .connected && on.how == "Claude Code · Personal's agents, through Claude Code's own MCP login")
        #expect(on.way == .button("Disconnect…", .signOutTetrix(personal.account)))
        #expect(tetrix.last?.state == .available && tetrix.last?.way == .button("Sign In", .signInTetrix(deskree.account)))
    }

    /// The runner's accounts, Tetrix, GitHub, plug-ins and connections are listed under its name;
    /// what only its machine can change says how, with no button.
    @Test func theRunnersConnections() throws {
        let plugins = [plugin("tetrix", enabled: true, state: "ready"), RunnerPlugin(id: "notes", name: "Notes", version: nil, kinds: ["context", "events"], enabled: false, state: "disabled", lastError: nil)]
        let mail = ConnectedApp(name: "mail", mcp: "https://mcp.example.com/mcp", api: nil, secret: "mail-token", header: nil, secretSaved: true, lastUsed: nil)
        let list = Connectors.list(mac: [personal], runner: lab(plugins: plugins, connections: [mail]))
        let account = try #require(list.first { $0.id == "account-tetrix-lab-lab-1" })
        #expect(account.place == "tetrix-lab" && account.state == .connected)
        guard case .steps(let steps) = account.way else { Issue.record("The runner's account has no button"); return }
        #expect(steps.contains("tetrix-lab") && steps.contains("accounts.json"))

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
        let app = try #require(Connectors.list(mac: [], runner: lab()).first { $0.id == "github" })
        #expect(app.state == .connected && app.place == "tetrix-lab")
        #expect(app.how.hasPrefix("Oby's GitHub app, whose last token request worked") && app.how.hasSuffix("Check runs reach pull requests."))
        guard case .steps(let unset) = app.way else { Issue.record("GitHub has no steps"); return }
        #expect(unset.contains("OBY_GITHUB_APP_ID") && unset.contains("tetrix-lab"))

        let list = Connectors.list(mac: [], runner: Connectors.RunnerState(name: "This Mac", local: true, accounts: [], github: "owner", checks: "no app"))
        let owner = try #require(list.first { $0.id == "github" })
        #expect(owner.state == .unconfirmed && !owner.connected)
        #expect(owner.how == "Acts as your gh login on this Mac. The runner doesn't check that it's signed in. No check runs: they need the GitHub app.")
        #expect(owner.way == .steps("To disconnect it, run gh auth logout on this Mac. Oby can't clone, push or open pull requests until you sign in again with gh auth login."))
        #expect(ids(Connectors.groups(list, query: ""), "Not confirmed") == ["github"])
        #expect(ids(Connectors.groups(list, query: ""), "Connected").isEmpty)
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

        let groups = Connectors.groups([missing, failed, starting], query: "")
        #expect(groups.map(\.title) == ["Needs attention", "Not confirmed"])
        #expect(ids(groups, "Needs attention") == ["connection-linear", "plugin-tetrix"])
    }

    /// The runner on this Mac shares this Mac's accounts: each is listed once, with this Mac's buttons.
    @Test func theRunnerOnThisMacListsEachAccountOnce() {
        let local = Connectors.RunnerState(name: "This Mac", local: true, accounts: [personal, deskree])
        let list = Connectors.list(mac: [personal, deskree], runner: local)
        #expect(list.filter { $0.name == "Claude Code · Personal" }.count == 1)
        #expect(list.filter { $0.name == "Tetrix" }.count == 2)
        #expect(!list.contains { if case .steps = $0.way { true } else { false } })
    }

    /// What the runner doesn't say isn't listed: an older runner sends no `github`, and the Swift
    /// runner has no plug-ins while obid lists no connections yet (#444).
    @Test func onlyWhatTheRunnerSays() {
        let list = Connectors.list(mac: [], runner: lab(github: nil))
        #expect(list.map(\.id) == ["account-tetrix-lab-lab-1", "tetrix-tetrix-lab-lab-1"])
        #expect(Connectors.list(mac: [], runner: nil).isEmpty)
    }

    /// No placeholders: the services the design shows that don't exist yet (Slack #26, Gmail #501,
    /// Deskree Ops #502, Google Meet #503, Zoom #504) are nowhere on the page.
    @Test func noPlaceholderServices() {
        let everything = Connectors.list(mac: [personal, deskree, cursor], runner: lab())
        for name in ["Slack", "Gmail", "Deskree Ops", "Google Meet", "Zoom"] {
            #expect(!everything.contains { $0.name.localizedCaseInsensitiveContains(name) || $0.about.localizedCaseInsensitiveContains(name) },
                    "\(name) is listed")
        }
    }

    /// Search finds a connector by its name or by what it does, whatever the case and accents,
    /// every word anywhere in it; an empty search shows everything, in its groups.
    @Test func searchByNameOrWhatItDoes() {
        let list = Connectors.list(mac: [personal, deskree, cursor], runner: lab())
        #expect(ids(Connectors.groups(list, query: "codex"), "Connected") == ["account-This Mac-c0de"])
        #expect(ids(Connectors.groups(list, query: "  PULL requests "), "Connected") == ["github"])
        let blast = Connectors.groups(list, query: "blast radius")
        #expect(ids(blast, "Connected") == ["tetrix-This Mac-default", "tetrix-tetrix-lab-lab-1"])
        #expect(ids(blast, "Available") == ["tetrix-This Mac-c0de"])
        #expect(ids(Connectors.groups(list, query: "runs jobs lab"), "Connected") == ["account-tetrix-lab-lab-1"])
        #expect(ids(Connectors.groups(list, query: "CLÁUDE"), "Connected").count == 2)
        let all = Connectors.groups(list, query: "")
        #expect(all.map(\.title) == ["Connected", "Available"])
        #expect(all.map(\.items.count).reduce(0, +) == list.count)
        #expect(ids(all, "Available") == ["account-This Mac-c5r", "tetrix-This Mac-c0de"])
        #expect(Connectors.groups(list, query: "zoom").isEmpty)
    }

    /// Tetrix's sign-out runs the tool's own command with the account's home, quoted; Cursor has none.
    @Test func tetrixSignOutScripts() throws {
        let claude = try #require(Connectors.tetrixSignOutScript(for: personal.account))
        #expect(claude.contains("unset CLAUDE_CONFIG_DIR") && claude.contains("Clear authentication")
                && claude.hasSuffix("\nclaude\necho\necho 'Done? Go back to Oby. You can close this window.'\n"))
        let codex = try #require(Connectors.tetrixSignOutScript(for: deskree.account))
        #expect(codex.contains("export CODEX_HOME='/tmp/oby/accounts/c0de'") && codex.contains("\ncodex mcp logout tetrix\n"))
        #expect(codex.contains(#"echo 'Oby: sign Deskree'\''s agents out of Tetrix.'"#))
        #expect(Connectors.tetrixSignOutScript(for: cursor.account) == nil)
    }

    /// Claude Code's sign-out starts with neither the Claude session nor the API credentials a
    /// Terminal may inherit (AGENTS.md, "Spawning claude"), and keeps everything else.
    @Test func claudeSignOutDropsInheritedSessionAndProviderVariables() async throws {
        let script = try #require(Connectors.tetrixSignOutScript(for: personal.account)).replacingOccurrences(of: "\nclaude\n", with: """

        test -z "${CLAUDECODE+x}" && test -z "${CLAUDE_CODE_TEST+x}" && test -z "${ANTHROPIC_API_KEY+x}" && test "$OBY_KEEP" = yes || exit 9

        """)
        let result = try await Shell.run(["/bin/sh"], input: Data(script.utf8),
                                         env: ["CLAUDECODE": "nested", "CLAUDE_CODE_TEST": "test", "ANTHROPIC_API_KEY": "test", "OBY_KEEP": "yes"])
        #expect(result.status == 0)
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
                                   "Couldn't read the connections on tetrix-lab: The runner couldn't read connections.json."])
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
