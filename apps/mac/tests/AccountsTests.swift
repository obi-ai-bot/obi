import Foundation
import Testing
@testable import Oby

struct AccountsTests {
    func state(_ id: String, _ agent: String = "claude", signedIn: Bool = true, running: Int = 0,
               fiveHour: Double? = nil, sevenDay: Double? = nil) -> AccountState {
        AccountState(account: Account(id: id, agent: agent, name: id, payer: "", home: nil),
                     label: signedIn ? "Max · \(id)@example.com" : nil, fiveHour: fiveHour, sevenDay: sevenDay, running: running)
    }

    func route(_ states: [AccountState], _ agent: String? = "claude") -> String? {
        AccountStore.route(states, agent: agent)?.id
    }

    func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "oby-accounts-\(UUID().uuidString)")
    }

    @Test func routeTakesOnlySignedInAccountsOfTheAgent() {
        #expect(route([state("a", signedIn: false), state("b", "codex"), state("c")]) == "c")
        #expect(route([state("a", signedIn: false), state("b", "codex")], nil) == "b")
        #expect(route([state("a", signedIn: false), state("b", "codex")]) == nil)
        #expect(route([]) == nil)
    }

    @Test func routeSkipsAccountsNearEitherLimit() {
        #expect(route([state("a", fiveHour: 0.95), state("b", running: 3, fiveHour: 0.94)]) == "b")
        #expect(route([state("a", fiveHour: 1), state("b", fiveHour: 0.97)]) == nil)
        #expect(route([state("a", sevenDay: 0.99), state("b", running: 2, sevenDay: 0.5)]) == "b")
        #expect(route([state("a", sevenDay: 0.95)]) == nil)
        // At 80% of its week an account is reserved for jobs sent to it by name.
        #expect(route([state("a", sevenDay: 0.8), state("b", running: 3, fiveHour: 0.9)]) == "b")
        #expect(route([state("a", sevenDay: 0.79)]) == "a")
    }

    /// Without reset times (no pace), the most weekly room left wins; running jobs only break ties
    /// (RunnerTests/PaceTests has the pace).
    @Test func routeBalancesUsageAndRunningJobs() {
        // Under 80% of the 5-hour window first.
        #expect(route([state("a", running: 1, sevenDay: 0.5), state("b", fiveHour: 0.9, sevenDay: 0.1)]) == "a")
        // The more weekly room: 60% left beats 25%, whatever the 5-hour window under 80%.
        #expect(route([state("a", fiveHour: 0.5, sevenDay: 0.4), state("b", fiveHour: 0.2, sevenDay: 0.75)]) == "a")
        #expect(route([state("a", fiveHour: 0.2, sevenDay: 0.6), state("b", fiveHour: 0.2, sevenDay: 0.3)]) == "b")
        // Running jobs break ties, and only ties.
        #expect(route([state("a", running: 2, sevenDay: 0.3), state("b", sevenDay: 0.3)]) == "b")
        #expect(route([state("a", running: 5, sevenDay: 0.3), state("b", sevenDay: 0.5)]) == "a")
    }

    @Test func routeKeepsListOrderOnTiesAndRanksUnknownUsageAfterKnown() {
        #expect(route([state("a", sevenDay: 0.3), state("b", sevenDay: 0.3), state("c", sevenDay: 0.3)]) == "a")
        #expect(route([state("a"), state("b", fiveHour: 0, sevenDay: 0)]) == "b")
        #expect(route([state("a", fiveHour: 0.1), state("b")]) == "a")
        #expect(route([state("a", "codex"), state("b")], nil) == "a")
    }

    /// `claude auth status` as Claude Code 2.1.296 printed it on 2026-10-09 (trimmed).
    @Test func claudeStatus() {
        let signedIn = #"{"loggedIn": true, "authMethod": "claude.ai", "email": "name@example.com", "subscriptionType": "max"}"#
        #expect(AccountStore.claudeLabel(status: Data(signedIn.utf8)) == "Max · name@example.com")
        let signedOut = #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#
        #expect(AccountStore.claudeLabel(status: Data(signedOut.utf8)) == nil)
        #expect(AccountStore.claudeLabel(status: Data(#"{"loggedIn": true}"#.utf8)) == "Signed in")
        #expect(AccountStore.claudeLabel(status: Data("command not found".utf8)) == nil)
    }

    @Test func signInScriptRunsOnlyTheToolsLogin() {
        let claude = AccountStore.signInScript(for: Account(id: "a", agent: "claude", name: "It's mine", payer: "",
                                                            home: "/Users/x/Library/Application Support/Oby/accounts/a"))
        #expect(claude.contains("export CLAUDE_CONFIG_DIR='/Users/x/Library/Application Support/Oby/accounts/a'\n"))
        #expect(claude.contains(#"'Oby: sign in to the account for It'\''s mine.'"#))
        #expect(claude.contains("sandbox-exec"))
        #expect(claude.contains("Library/Keychains"))
        #expect(claude.contains("claude auth login"))
        let codex = AccountStore.signInScript(for: Account(id: "b", agent: "codex", name: "Work", payer: "Deskree", home: nil))
        #expect(codex.contains("unset CODEX_HOME\n") && codex.contains("\ncodex login\n"))
    }

    @MainActor @Test func storeSavesAndLoads() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(root: root)
        #expect(store.accounts.map(\.account) == [Account(id: "default", agent: "claude", name: "Default", payer: "", home: nil)])

        let work = try store.add(agent: "claude", name: "Work", payer: "Deskree")
        try store.add(agent: "codex", name: "Personal", payer: "Wellington")
        #expect(work.home == root.appending(path: "accounts/\(work.id)").path)
        #expect(FileManager.default.fileExists(atPath: try #require(work.home)))
        store.record(.usage(fiveHour: 0.4, sevenDay: nil), for: work.id)

        let loaded = AccountStore(root: root)
        #expect(loaded.accounts.map(\.account) == store.accounts.map(\.account))
        #expect(loaded.accounts.allSatisfy { $0.label == nil && $0.running == 0 })
        // Usage stays, so a job waiting for an account's room doesn't start early after a restart (#216).
        #expect(loaded.accounts.map(\.fiveHour) == [nil, 0.4, nil])
    }

    @MainActor @Test func storeKeepsLiveState() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(root: root)
        store.record(.usage(fiveHour: 0.4, sevenDay: 0.2), for: "default")
        store.record(.usage(fiveHour: nil, sevenDay: 0.3), for: "default")
        store.record(.step("Running pnpm test"), for: "default")
        store.record(.usage(fiveHour: 1, sevenDay: 1), for: "missing")
        #expect(store.accounts[0].fiveHour == 0.4 && store.accounts[0].sevenDay == 0.3)

        var job = Job(id: "j1", request: "", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-j1", kind: .fix, task: "")
        var done = job
        done.id = "j2"
        done.status = .done
        job.status = .running
        store.countRunning([job, done])
        #expect(store.accounts[0].running == 1)
    }

    @MainActor @Test func removeNeverDeletesOutsideAccounts() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let outside = root.appending(path: "outside/inner")
        let link = root.appending(path: "accounts/link")
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())

        let homes = [outside.path, root.path + "/accounts/../outside/inner", root.appending(path: "accounts").path,
                     link.appending(path: "inner").path, nil]
        let saved = homes.enumerated().map { Account(id: "a\($0)", agent: "claude", name: "A", payer: "", home: $1) }
        try JSONEncoder().encode(saved).write(to: root.appending(path: "accounts.json"))
        let store = AccountStore(root: root)
        for account in saved { try store.remove(account) }
        #expect(store.accounts.isEmpty)
        #expect(files.fileExists(atPath: outside.path))
        #expect(files.fileExists(atPath: root.appending(path: "accounts").path))

        let added = try store.add(agent: "codex", name: "Work", payer: "Deskree")
        try store.remove(added)
        #expect(!files.fileExists(atPath: try #require(added.home)))
        #expect(AccountStore(root: root).accounts.isEmpty)
    }
}
