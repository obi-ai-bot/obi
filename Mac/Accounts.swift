import Foundation
import SwiftUI

/// One login of a coding tool that Oby can send jobs to, and who pays for it.
nonisolated struct Account: Codable, Identifiable, Equatable, Sendable {
    var id: String
    /// "claude" or "codex".
    var agent: String
    /// The user's label, like "Personal".
    var name: String
    /// Who pays for it, like "Wellington" or "Deskree".
    var payer: String
    /// The account's config directory, or nil for the tool's default (`~/.claude`, `~/.codex`).
    var home: String?
}

/// An account with what Oby knows about it right now. Only `account` is saved.
nonisolated struct AccountState: Equatable, Sendable {
    var account: Account
    /// What the tool says about the login, like "Max · name@example.com"; nil while signed out.
    var label: String?
    /// How much of each limit window is used, 0...1, as the account's last job reported it.
    var fiveHour: Double?
    var sevenDay: Double?
    /// Jobs queued or running on it.
    var running = 0

    var signedIn: Bool { label != nil }
}

/// The accounts Oby spreads jobs across, saved in `accounts.json`. Homes Oby makes live in
/// `accounts/<id>`. Oby never reads the logins: each tool signs in through its own command.
@Observable
final class AccountStore {
    private(set) var accounts: [AccountState]
    /// Codex's sign-in label for a home, or nil while signed out. The Codex runner can swap in
    /// its app-server's `account/read`; until then `codex login status` answers.
    @ObservationIgnored var codexLabel: (_ home: String?) async -> String? = { home in
        // It exits 0 when signed in and says how on stderr: "Logged in using ChatGPT".
        guard let result = try? await Shell.run(["codex", "login", "status"], env: ["CODEX_HOME": home], timeout: 30),
              result.status == 0 else { return nil }
        return result.err.split(separator: "\n").last.map(String.init) ?? "Signed in"
    }
    private let file: URL
    private let homes: URL

    init(root: URL = Workspace.root) {
        file = root.appending(path: "accounts.json")
        homes = root.appending(path: "accounts")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Account].self, from: $0) }
        accounts = (saved ?? [Account(id: "default", agent: "claude", name: "Default", payer: "", home: nil)])
            .map { AccountState(account: $0) }
    }

    /// Adds an account with a fresh, empty home. It's signed out until the user signs in.
    @discardableResult
    func add(agent: String, name: String, payer: String) throws -> Account {
        let id = UUID().uuidString.lowercased()
        let home = homes.appending(path: id)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let account = Account(id: id, agent: agent, name: name, payer: payer, home: home.path)
        accounts.append(AccountState(account: account))
        try save()
        return account
    }

    /// Forgets the account and deletes its home if Oby made it. The tool's default home and
    /// anything outside `accounts/` are never deleted.
    func remove(_ account: Account) throws {
        guard let index = accounts.firstIndex(where: { $0.account.id == account.id }) else { return }
        let home = accounts.remove(at: index).account.home
        try save()
        if let home, Self.isOwned(home, in: homes) { try? FileManager.default.removeItem(atPath: home) }
    }

    /// Keeps the usage an account's job just reported. A window it didn't report keeps its last value.
    func record(_ usage: AgentEvent, for accountID: String) {
        guard case let .usage(fiveHour, sevenDay) = usage,
              let index = accounts.firstIndex(where: { $0.account.id == accountID }) else { return }
        if let fiveHour { accounts[index].fiveHour = fiveHour }
        if let sevenDay { accounts[index].sevenDay = sevenDay }
    }

    /// Counts each account's active jobs; `Job.account` holds the account's id.
    func countRunning(_ jobs: [Job]) {
        for index in accounts.indices {
            accounts[index].running = jobs.filter { $0.isActive && $0.account == accounts[index].account.id }.count
        }
    }

    /// Asks each tool who is signed in to each account.
    func refresh() async {
        for account in accounts.map(\.account) {
            var label: String?
            switch account.agent {
            case "claude":
                // It exits 1 when signed out, still printing its JSON.
                let result = try? await Shell.run(["claude", "auth", "status", "--json"], env: ["CLAUDE_CONFIG_DIR": account.home], timeout: 30)
                label = result.flatMap { Self.claudeLabel(status: $0.out) }
            case "codex":
                label = await codexLabel(account.home)
            default:
                break
            }
            if let index = accounts.firstIndex(where: { $0.account.id == account.id }) { accounts[index].label = label }
        }
    }

    /// Opens Terminal on the tool's own login, with the account's home in the environment.
    func signIn(_ account: Account) throws {
        let script = URL(filePath: account.home ?? homes.path).appending(path: "sign-in-\(account.id).command")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.signInScript(for: account).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw Shell.Failure(message: "Couldn't open Terminal to sign in.") }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts.map(\.account)).write(to: file, options: .atomic)
    }

    /// The account for a new job: a signed-in account of that agent (any agent if nil) under 95%
    /// of its five-hour window, with the fewest running jobs, then the lowest five-hour and
    /// seven-day usage. Unknown usage counts as 0; ties keep list order.
    nonisolated static func route(_ accounts: [AccountState], agent: String?) -> Account? {
        let rank = { (index: Int, state: AccountState) in (state.running, state.fiveHour ?? 0, state.sevenDay ?? 0, index) }
        return accounts.enumerated()
            .filter { $0.element.signedIn && (agent == nil || $0.element.account.agent == agent) && ($0.element.fiveHour ?? 0) < 0.95 }
            .min { rank($0.offset, $0.element) < rank($1.offset, $1.element) }?
            .element.account
    }

    /// "Max · name@example.com" from `claude auth status --json`, or nil when it isn't signed in.
    nonisolated static func claudeLabel(status: Data) -> String? {
        guard let info = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
              info["loggedIn"] as? Bool == true else { return nil }
        let parts = [(info["subscriptionType"] as? String)?.capitalized, info["email"] as? String].compactMap { $0 }
        return parts.isEmpty ? "Signed in" : parts.joined(separator: " · ")
    }

    /// What Terminal runs to sign in: the tool's own login command and nothing else.
    nonisolated static func signInScript(for account: Account) -> String {
        let (variable, login) = account.agent == "codex" ? ("CODEX_HOME", "codex login") : ("CLAUDE_CONFIG_DIR", "claude auth login")
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        let who = account.payer.isEmpty ? account.name : "\(account.name), paid by \(account.payer)"
        return """
        #!/bin/sh
        \(account.home.map { "export \(variable)=\(quote($0))" } ?? "unset \(variable)")
        echo \(quote("Oby: sign in to the account for \(who)."))
        \(login)
        echo
        echo 'Done? Go back to Oby. You can close this window.'

        """
    }

    nonisolated static func isOwned(_ path: String, in homes: URL) -> Bool {
        let root = homes.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root)
    }
}

/// Settings › Accounts: the logins Oby spreads jobs across, who pays for each, and how much each has used.
struct AccountsSettingsView: View {
    let store: AccountStore
    @State private var agent = "claude"
    @State private var name = ""
    @State private var payer = ""
    @State private var removing: Account?
    @State private var problem: String?

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(store.accounts, id: \.account.id, content: row)
            }
            Section("Add an account") {
                Picker("Tool", selection: $agent) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                }
                TextField("Name", text: $name, prompt: Text("Personal"))
                TextField("Paid by", text: $payer, prompt: Text("Wellington"))
                Button("Add Account") {
                    attempt {
                        try store.add(agent: agent, name: name.trimmingCharacters(in: .whitespaces), payer: payer.trimmingCharacters(in: .whitespaces))
                        name = ""
                        payer = ""
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { await store.refresh() }
        // Back from signing in, in Terminal.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this account")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button("Remove", role: .destructive) { attempt { try store.remove(account) } }
        } message: { account in
            Text(account.home == nil ? "Its login stays in the tool's own settings." : "Oby deletes this account's settings folder.")
        }
    }

    private func row(_ state: AccountState) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.account.name) · \(state.account.agent == "codex" ? "Codex" : "Claude Code")")
                Text(state.label ?? "Signed out")
                    .font(.caption).foregroundStyle(.secondary)
                if !state.account.payer.isEmpty {
                    Text("Paid by \(state.account.payer)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.signedIn {
                Text("5h \(percent(state.fiveHour)) · 7d \(percent(state.sevenDay))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Button("Sign In") { attempt { try store.signIn(state.account) } }
            }
            Button("Remove", role: .destructive) { removing = state.account }
        }
    }

    private func percent(_ used: Double?) -> String {
        used.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–"
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}
