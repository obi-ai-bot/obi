import CryptoKit
import Foundation
import Testing
@testable import Oby

/// Settings › Connectors (#498): every connection that exists today, each with how it's signed in
/// and how to disconnect it, and a search by name or by what it does. Nothing listed is a placeholder.
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

    /// This Mac's signed-in accounts are connected, with how they signed in (the plan, never the
    /// email) and a Disconnect that removes them; a signed-out one is available, with Sign In.
    @Test func thisMacsAccounts() throws {
        let list = Connectors.list(mac: [personal, deskree, cursor], runner: nil)
        let claude = try #require(list.first { $0.id == "account-This Mac-default" })
        #expect(claude.name == "Claude Code · Personal" && claude.about == "Runs jobs in Claude Code" && claude.place == "This Mac")
        #expect(claude.connected && claude.how == "Signed in with Claude Code's own login · Max")
        #expect(claude.way == .button("Disconnect…", .removeAccount(personal.account)))
        #expect(!list.contains { $0.how.contains("someone@example.com") })
        let signedOut = try #require(list.first { $0.id == "account-This Mac-c5r" })
        #expect(!signedOut.connected && signedOut.how == "Not signed in" && signedOut.way == .button("Sign In", .signIn(cursor.account)))
    }

    /// Tetrix for each account once its tool has said: signed in is connected, with the tool's own
    /// sign-out; not signed in is available, with the tool's own login. Not said yet: not listed.
    @Test func tetrixPerAccount() throws {
        let list = Connectors.list(mac: [personal, deskree, cursor], runner: nil)
        let tetrix = list.filter { $0.name == "Tetrix" }
        #expect(tetrix.map(\.id) == ["tetrix-This Mac-default", "tetrix-This Mac-c0de"])
        let on = try #require(tetrix.first)
        #expect(on.connected && on.how == "Claude Code · Personal's agents, through Claude Code's own MCP login")
        #expect(on.way == .button("Disconnect…", .signOutTetrix(personal.account)))
        #expect(tetrix.last?.connected == false && tetrix.last?.way == .button("Sign In", .signInTetrix(deskree.account)))
    }

    /// The runner's accounts, Tetrix, GitHub, plug-ins and connections are listed under its name;
    /// what only its machine can change says how, with no button.
    @Test func theRunnersConnections() throws {
        let plugins = [RunnerPlugin(id: "tetrix", name: "Tetrix", version: "0.1.0", kinds: ["agent-mcp"], enabled: true, state: "ready", lastError: nil),
                       RunnerPlugin(id: "notes", name: "Notes", version: nil, kinds: ["context", "events"], enabled: false, state: "disabled", lastError: nil)]
        let mail = ConnectedApp(name: "mail", mcp: "https://mcp.example.com/mcp", api: nil, secret: "mail-token", header: nil, secretSaved: true, lastUsed: nil)
        let list = Connectors.list(mac: [personal], runner: lab(plugins: plugins, connections: [mail]))
        let account = try #require(list.first { $0.id == "account-tetrix-lab-lab-1" })
        #expect(account.place == "tetrix-lab" && account.connected)
        guard case .steps(let steps) = account.way else { Issue.record("The runner's account has no button"); return }
        #expect(steps.contains("tetrix-lab") && steps.contains("accounts.json"))

        let plugin = try #require(list.first { $0.id == "plugin-tetrix" })
        #expect(plugin.connected && plugin.how == "A plug-in of obid's (0.1.0) · Ready" && plugin.way == .button("Disconnect", .disablePlugin("tetrix")))
        let off = try #require(list.first { $0.id == "plugin-notes" })
        #expect(!off.connected && off.about == "Context for jobs, events in your inbox")
        #expect(off.way == .button("Connect…", .enablePlugin(id: "notes", needsURL: false)))

        let github = try #require(list.first { $0.id == "github" })
        #expect(github.connected && github.place == "tetrix-lab")
        #expect(github.how == "Oby's GitHub app for its own calls; your gh login pushes and opens pull requests · check runs on pull requests")
        guard case .steps(let unset) = github.way else { Issue.record("GitHub has no steps"); return }
        #expect(unset.contains("OBY_GITHUB_APP_ID") && unset.contains("tetrix-lab"))

        let connection = try #require(list.first { $0.id == "connection-mail" })
        #expect(connection.connected && connection.about == "MCP server at mcp.example.com")
        #expect(connection.how == "The vault secret mail-token, as Authorization: Bearer")
        #expect(connection.way == .button("Disconnect…", .disconnect("mail")))
    }

    /// Only the owner's gh login: disconnecting it is gh's own logout, on the runner's machine.
    @Test func gitHubAsTheOwner() throws {
        let list = Connectors.list(mac: [], runner: Connectors.RunnerState(name: "This Mac", local: true, accounts: [], github: "owner"))
        let github = try #require(list.first { $0.id == "github" })
        #expect(github.how == "Your gh login on this Mac")
        #expect(github.way == .steps("To disconnect it, run gh auth logout on this Mac. Oby can't clone, push or open pull requests until you sign in again with gh auth login."))
    }

    /// A secret the runner's vault doesn't have, sent in a header of its own, says so.
    @Test func connectionWithoutItsSecret() {
        let api = ConnectedApp(name: "linear", mcp: nil, api: "https://api.linear.app", secret: "linear-key", header: "X-Api-Key", secretSaved: false, lastUsed: nil)
        #expect(Connectors.connection(api, place: "tetrix-lab").how
                == "The vault secret linear-key is missing: add it on the runner with oby-runner vault add linear-key")
        #expect(Connectors.connection(api, place: "tetrix-lab").about == "API at api.linear.app")
        var saved = api
        saved.secretSaved = true
        #expect(Connectors.connection(saved, place: "tetrix-lab").how == "The vault secret linear-key, in the header X-Api-Key")
    }

    /// The runner on this Mac shares this Mac's accounts: each is listed once, with this Mac's buttons.
    @Test func theRunnerOnThisMacListsEachAccountOnce() {
        let local = Connectors.RunnerState(name: "This Mac", local: true, accounts: [personal, deskree])
        let list = Connectors.list(mac: [personal, deskree], runner: local)
        #expect(list.filter { $0.name == "Claude Code · Personal" }.count == 1)
        #expect(list.filter { $0.name == "Tetrix" }.count == 2)
        #expect(list.allSatisfy { if case .steps = $0.way { false } else { true } })
    }

    /// What the runner doesn't say isn't listed: an older runner sends no `github`, and the Swift
    /// runner has no plug-ins while obid lists no connections yet (#444).
    @Test func onlyWhatTheRunnerSays() {
        let list = Connectors.list(mac: [], runner: lab(github: nil))
        #expect(list.map(\.id) == ["account-tetrix-lab-lab-1", "tetrix-tetrix-lab-lab-1"])
        #expect(Connectors.list(mac: [], runner: nil).isEmpty)
    }

    /// No placeholders: the services the design shows that don't exist yet (Slack #26, Gmail,
    /// Deskree Ops, Google Meet, Zoom) are nowhere on the page.
    @Test func noPlaceholderServices() {
        let everything = Connectors.list(mac: [personal, deskree, cursor], runner: lab())
        for name in ["Slack", "Gmail", "Deskree Ops", "Google Meet", "Zoom"] {
            #expect(!everything.contains { $0.name.localizedCaseInsensitiveContains(name) || $0.about.localizedCaseInsensitiveContains(name) },
                    "\(name) is listed")
        }
    }

    /// Search finds a connector by its name or by what it does, whatever the case and accents,
    /// every word anywhere in it; an empty search shows everything, split into the two groups.
    @Test func searchByNameOrWhatItDoes() {
        let list = Connectors.list(mac: [personal, deskree, cursor], runner: lab())
        #expect(Connectors.groups(list, query: "codex").connected.map(\.id) == ["account-This Mac-c0de"])
        #expect(Connectors.groups(list, query: "  PULL requests ").connected.map(\.id) == ["github"])
        #expect(Connectors.groups(list, query: "blast radius").connected.map(\.id) == ["tetrix-This Mac-default", "tetrix-tetrix-lab-lab-1"])
        #expect(Connectors.groups(list, query: "blast radius").available.map(\.id) == ["tetrix-This Mac-c0de"])
        #expect(Connectors.groups(list, query: "runs jobs lab").connected.map(\.id) == ["account-tetrix-lab-lab-1"])
        #expect(Connectors.groups(list, query: "CLÁUDE").connected.count == 2)
        let all = Connectors.groups(list, query: "")
        #expect(all.connected.count + all.available.count == list.count)
        #expect(all.available.map(\.id) == ["account-This Mac-c5r", "tetrix-This Mac-c0de"])
        let none = Connectors.groups(list, query: "zoom")
        #expect(none.connected.isEmpty && none.available.isEmpty)
    }

    /// Tetrix's sign-out runs the tool's own command with the account's home, quoted.
    @Test func tetrixSignOutScripts() {
        let claude = Connectors.tetrixSignOutScript(for: personal.account)
        #expect(claude.contains("unset CLAUDE_CONFIG_DIR") && claude.contains("Clear authentication") && claude.contains("\nclaude\n"))
        let codex = Connectors.tetrixSignOutScript(for: deskree.account)
        #expect(codex.contains("export CODEX_HOME='/tmp/oby/accounts/c0de'") && codex.contains("\ncodex mcp logout tetrix\n"))
        #expect(codex.contains(#"echo 'Oby: sign Deskree'\''s agents out of Tetrix.'"#))
        let cursorScript = Connectors.tetrixSignOutScript(for: cursor.account)
        #expect(cursorScript.contains("export CURSOR_CONFIG_DIR='/tmp/oby/accounts/c5r'") && cursorScript.contains("export HOME='/tmp/oby/accounts/c5r'"))
        #expect(cursorScript.contains("\ncursor-agent mcp disable tetrix\n"))
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
        let stub = RunnerStub { request in
            switch request.path {
            case "/v1/connections":
                (200, #"[{"name": "mail", "mcp": "https://mcp.example.com/mcp", "api": null, "secret": "mail-token", "header": "Authorization", "created": "2026-10-11T16:02:11Z", "secretSaved": true, "lastUsed": "2026-10-11T16:20:03Z"}]"#)
            default: (404, #"{"error": "Not found."}"#)
            }
        }
        let connections = try #require(try await stub.runner.connections())
        #expect(connections.map(\.name) == ["mail"] && connections.first?.secretSaved == true && connections.first?.lastUsed != nil)
        #expect(try await stub.runner.plugins() == nil)

        let obid = RunnerStub { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/obid/plugins"):
                (200, #"[{"id": "tetrix", "name": "Tetrix", "version": "0.1.0", "kinds": ["agent-mcp"], "enabled": false, "state": "disabled", "lastError": null}]"#)
            case ("PUT", "/v1/obid/plugins/tetrix"):
                (200, #"{"id": "tetrix", "name": "Tetrix", "version": "0.1.0", "kinds": ["agent-mcp"], "enabled": true, "state": "ready", "lastError": null}"#)
            default: (404, "")
            }
        }
        #expect(try await obid.runner.connections() == nil)
        #expect(try await obid.runner.plugins()?.map(\.state) == ["disabled"])
        let on = try await obid.runner.setPlugin("tetrix", enabled: true, config: ["url": "https://tetrix.example.com/mcp"])
        #expect(on.enabled && on.state == "ready")
        let put = try #require(obid.requests.last?.json)
        #expect(put["enabled"] as? Bool == true && (put["config"] as? [String: String]) == ["url": "https://tetrix.example.com/mcp"])
        _ = try await obid.runner.setPlugin("tetrix", enabled: false)
        #expect(obid.requests.last?.json?.keys.sorted() == ["enabled"])
    }

    /// Disconnecting a runner's connection signs the runner's own sentence, under the connection
    /// prefix, after Touch ID; a cancelled Touch ID sends nothing.
    @Test func disconnectSignsTheRunnersSentence() async throws {
        let sentence = "Disconnect mail."
        let stub = RunnerStub { request in
            switch (request.method, request.path) {
            case ("POST", "/v1/devices"): (200, #"{"id": "d7c1"}"#)
            case ("DELETE", "/v1/connections/mail") where request.body.isEmpty:
                (403, #"{"error": "Approve this on your iPhone first: \#(sentence)", "action": "\#(sentence)"}"#)
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
        #expect(approval["device"] == "d7c1" && approval["action"] == sentence)
        let der = try #require(approval["signature"].flatMap { Data(base64Encoded: $0) })
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        let signedAt = try #require(approval["signedAt"])
        #expect(key.signing.publicKey.isValidSignature(signature, for: Approval.connectionMessage(action: sentence, signedAt: signedAt)))
        // Not a publish's signature: the runner can't take one for the other.
        #expect(!key.signing.publicKey.isValidSignature(signature, for: Approval.message(job: "", action: sentence, signedAt: signedAt)))
        #expect(String(decoding: Approval.connectionMessage(action: sentence, signedAt: "2026-10-16T12:00:00Z"), as: UTF8.self)
                == "oby-connection\nDisconnect mail.\n2026-10-16T12:00:00Z")

        let cancelled = RunnerStub(answer: stub.answer)
        let refusing = MacDevice(key: FakeKey(cancels: true), name: "Mac", defaults: cancelled.defaults)
        await #expect(throws: RunnerError.self) { try await refusing.disconnect("mail", with: cancelled.runner) }
        // Asked what to approve, then nothing: no signature went out.
        let deletes = cancelled.requests.filter { $0.method == "DELETE" }
        #expect(deletes.count == 1 && deletes.first?.body.isEmpty == true)
    }
}
