import Foundation
import Observation

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

    /// "Codex · Deskree": the tool and the account, as reports name it.
    var heading: String { "\(Job.agentNames[agent] ?? agent) · \(name)" }
}

/// An account with what Oby knows about it right now. Only `account` is saved.
nonisolated struct AccountState: Equatable, Sendable {
    var account: Account
    /// What the tool says about the login, like "Max · name@example.com"; nil while signed out.
    var label: String?
    /// How much of each limit window is used, 0...1, as the account's last job reported it.
    var fiveHour: Double?
    var sevenDay: Double?
    /// When each window resets, as the tool last said; nil when it didn't say.
    var fiveHourResets: Date?
    var sevenDayResets: Date?
    /// Jobs queued or running on it.
    var running = 0
    /// A job of its hit the account's usage limit: it gets no job until then.
    var fullUntil: Date?

    var signedIn: Bool { label != nil }
    func isFull(at now: Date = .now) -> Bool { (fullUntil ?? .distantPast) > now }

    /// The share of its weekly limit an account keeps for jobs the user sends to it by name.
    static let reserve = 0.8
    /// At 80% of its weekly limit an account gets no automatic work, only jobs sent to it by name,
    /// until its week resets: Claude Code reports usage only during a job, so the 80% would stay.
    func isReserved(at now: Date = .now) -> Bool {
        (sevenDay ?? 0) >= Self.reserve && (sevenDayResets ?? .distantFuture) > now
    }

    /// How much of the 7-day window has passed, 0...1, or nil when its reset time is unknown.
    func weekGone(at now: Date = .now) -> Double? {
        sevenDayResets.map { min(max(1 - $0.timeIntervalSince(now) / (7 * 86_400), 0), 1) }
    }

    /// How far the weekly usage is ahead of the share of the week gone, 0 when on pace or unknown:
    /// 62% used with 30% of the week gone is 0.32 ahead.
    func ahead(at now: Date = .now) -> Double {
        guard let sevenDay, let gone = weekGone(at: now) else { return 0 }
        return max(sevenDay - gone, 0)
    }
}

/// The accounts Oby spreads jobs across, saved in `accounts.json`. Homes Oby makes live in
/// `accounts/<id>`. Oby never reads the logins: each tool signs in through its own command.
@Observable
final class AccountStore {
    private(set) var accounts: [AccountState]
    private let file: URL
    /// Where the homes Oby makes for accounts live.
    let homes: URL

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

    /// Keeps the usage an account's job just reported. A window it didn't report keeps its last
    /// value and reset time; a window reported without a reset time keeps the last one.
    func record(_ usage: AgentEvent, for accountID: String) {
        guard case let .usage(fiveHour, sevenDay, fiveHourResets, sevenDayResets) = usage,
              let index = accounts.firstIndex(where: { $0.account.id == accountID }) else { return }
        if let fiveHour {
            accounts[index].fiveHour = fiveHour
            if let fiveHourResets { accounts[index].fiveHourResets = fiveHourResets }
        }
        if let sevenDay {
            accounts[index].sevenDay = sevenDay
            if let sevenDayResets { accounts[index].sevenDayResets = sevenDayResets }
        }
    }

    /// A job of the account's hit its usage limit: no job goes to it until `until`.
    func markFull(_ accountID: String, until: Date) {
        guard let index = accounts.firstIndex(where: { $0.account.id == accountID }) else { return }
        accounts[index].fullUntil = until
    }

    /// What the tool says about the account's login, or nil when it's signed out.
    func setLabel(_ label: String?, for accountID: String) {
        guard let index = accounts.firstIndex(where: { $0.account.id == accountID }) else { return }
        accounts[index].label = label
    }

    func state(_ id: String) -> AccountState? { accounts.first { $0.account.id == id } }

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
                // It exits 1 when signed out, still printing its JSON. Boxed like a job: agents can write
                // to this home, so its settings may be theirs.
                let status = Agents.sandboxed(["claude", "auth", "status", "--json"], in: nil, own: account.home ?? "\(Agents.home)/.claude")
                let result = try? await Shell.run(status, env: ["CLAUDE_CONFIG_DIR": account.home], timeout: 30)
                label = result.flatMap { Self.claudeLabel(status: $0.out) }
            case "codex":
                // Codex's app-server knows both the login and the limits; Claude Code's limits
                // arrive with its first job.
                let home = account.home.map { URL(filePath: $0) }
                label = (try? await CodexAgent.account(home: home)) ?? nil
                if label != nil, let used = try? await CodexAgent.usage(home: home) {
                    record(used.event, for: account.id)
                }
            default:
                break
            }
            setLabel(label, for: account.id)
        }
    }

    /// What the tool said about an account's login: a label while signed in, nil when it isn't.
    /// `refresh` learns it; tests set it.

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts.map(\.account)).write(to: file, options: .atomic)
    }

    /// The account for a new job, keeping every account in balance: a signed-in account of that
    /// agent (any agent if nil) under 95% of its 5-hour window, not reserved for the week
    /// (`isReserved`) and not marked full, with the lowest `score`. Each account's usage is measured
    /// against its own plan, so a small plan fills up faster and gets fewer jobs. Unknown usage
    /// counts as 0; ties keep list order. Every automatic choice goes through here (the brain's
    /// dispatch, failover, reviews); only a job the user sends to an account by name skips it.
    nonisolated static func route(_ accounts: [AccountState], agent: String?, now: Date = .now) -> Account? {
        accounts.enumerated()
            .filter { $0.element.signedIn && (agent == nil || $0.element.account.agent == agent) && !$0.element.isFull(at: now)
                && ($0.element.fiveHour ?? 0) < 0.95 && !$0.element.isReserved(at: now) }
            .min { (score($0.element, now: now), $0.offset) < (score($1.element, now: now), $1.offset) }?
            .element.account
    }

    /// Where a job goes on from an account that hit its limit: the same tool first, then any.
    nonisolated static func next(_ accounts: [AccountState], agent: String, now: Date = .now) -> Account? {
        route(accounts, agent: agent, now: now) ?? route(accounts, agent: nil, now: now)
    }

    /// The busier of its two windows, plus how far its week is ahead of pace (`ahead`), plus 0.15
    /// per running job. Lower is better.
    nonisolated static func score(_ state: AccountState, now: Date = .now) -> Double {
        max(state.fiveHour ?? 0, state.sevenDay ?? 0) + state.ahead(at: now) + 0.15 * Double(state.running)
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
