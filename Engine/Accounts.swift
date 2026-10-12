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
    /// Whether the account's agents have Tetrix's MCP server connected, as its tool last said
    /// (Engine/TetrixUse.swift), or nil before it said.
    var tetrix: Bool?
    /// Of its recent jobs that ended and whose tool said what it had, how many there are, and how
    /// many used Tetrix.
    var tetrixJobs = 0
    var tetrixUsed = 0
    /// The user let it past its weekly reserve until this time, its week's reset (#278): until
    /// then it isn't `isReserved`. Saved with its usage, so a restart keeps it.
    var reserveLifted: Date?

    var signedIn: Bool { label != nil }
    func isFull(at now: Date = .now) -> Bool { (fullUntil ?? .distantPast) > now }

    /// The share of its weekly limit an account keeps for jobs the user sends to it by name.
    static let reserve = 0.8
    /// Past this share of either window an account gets nothing, its reserve lifted or not.
    static let nearlyFull = 0.95
    /// At 80% of its weekly limit an account gets no automatic work, only jobs sent to it by name,
    /// until its week resets: Claude Code reports usage only during a job, so the 80% would stay.
    /// Not while the user lifted it (`reserveLiftedUntil`).
    func isReserved(at now: Date = .now) -> Bool { inReserve(at: now) && reserveLiftedUntil(at: now) == nil }

    /// At 80% of its week before the reset, lifted or not: what Settings' switch is for.
    func inReserve(at now: Date = .now) -> Bool {
        (sevenDay ?? 0) >= Self.reserve && (sevenDayResets ?? .distantFuture) > now
    }

    /// Until when the user let it past its reserve, or nil when they didn't or that has passed.
    func reserveLiftedUntil(at now: Date = .now) -> Date? { reserveLifted.flatMap { $0 > now ? $0 : nil } }

    /// Its week is at 95%: no automatic work, not even a review or with its reserve lifted. A week
    /// whose reset has passed is empty.
    func weekNearlyFull(at now: Date = .now) -> Bool {
        (sevenDay ?? 0) >= Self.nearlyFull && (sevenDayResets ?? .distantFuture) > now
    }

    /// Lifting its reserve would let it take work (#278): reserved, signed in, not marked full and
    /// under 95% of both windows. The apps' "Use Personal anyway" button shows for these.
    func mayLiftReserve(at now: Date = .now) -> Bool {
        signedIn && isReserved(at: now) && !isFull(at: now) && !weekNearlyFull(at: now)
            && ((fiveHour ?? 0) < Self.nearlyFull || (fiveHourResets ?? .distantFuture) <= now)
    }

    /// How much of the 7-day window has passed, 0...1, or nil when its reset time is unknown.
    func weekGone(at now: Date = .now) -> Double? {
        sevenDayResets.map { min(max(1 - $0.timeIntervalSince(now) / (7 * 86_400), 0), 1) }
    }

    /// How fast the week is burning against its pace: the share used over the share of the week
    /// gone, counting at least a seventh gone so the first hours of a week don't swing it. Above 1
    /// it runs out before its reset: 33% used with 7.6% of the week gone is 2.3. Nil when the usage
    /// or the reset time is unknown.
    func pace(at now: Date = .now) -> Double? {
        guard let sevenDay, let gone = weekGone(at: now) else { return nil }
        return sevenDay / max(gone, 1.0 / 7)
    }

    /// Burning its week faster than it lasts (`pace` above 1). Unknown is not ahead.
    func isAhead(at now: Date = .now) -> Bool { (pace(at: now) ?? 0) > 1 }

    /// The weekly room per day until the week resets: 57% left with 4.8 days to go is 0.12/day.
    /// At least a quarter of a day counts as left; without a reset time, the whole week. Nil when
    /// the weekly usage is unknown.
    func roomPerDay(at now: Date = .now) -> Double? {
        guard let sevenDay else { return nil }
        let days = sevenDayResets.map { max($0.timeIntervalSince(now) / 86_400, 0.25) } ?? 7
        return max(1 - sevenDay, 0) / days
    }
}

/// The accounts Oby spreads jobs across, saved in `accounts.json`. Homes Oby makes live in
/// `accounts/<id>`. Oby never reads the logins: each tool signs in through its own command.
@Observable
final class AccountStore {
    private(set) var accounts: [AccountState]
    private let file: URL
    /// What Oby last knew of each account's usage, by id, in `usage.json`: a restart keeps it, so
    /// a job waiting for an account's room doesn't start early (#216). Claude Code reports usage
    /// only during a job, so its refresh can't learn it again.
    private let usageFile: URL

    /// One account's usage as `usage.json` keeps it.
    private struct Usage: Codable, Equatable {
        var fiveHour, sevenDay: Double?
        var fiveHourResets, sevenDayResets, fullUntil: Date?
        /// Older files don't have it.
        var reserveLifted: Date?

        init(_ state: AccountState) {
            (fiveHour, sevenDay, fiveHourResets, sevenDayResets, fullUntil) = (state.fiveHour, state.sevenDay, state.fiveHourResets, state.sevenDayResets, state.fullUntil)
            reserveLifted = state.reserveLifted
        }
    }
    /// Where the homes Oby makes for accounts live.
    let homes: URL

    init(root: URL = Workspace.root) {
        file = root.appending(path: "accounts.json")
        usageFile = root.appending(path: "usage.json")
        homes = root.appending(path: "accounts")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Account].self, from: $0) }
        let usage = (try? Data(contentsOf: usageFile)).flatMap { try? JSONDecoder().decode([String: Usage].self, from: $0) } ?? [:]
        accounts = (saved ?? [Account(id: "default", agent: "claude", name: "Default", payer: "", home: nil)])
            .map { account in
                var state = AccountState(account: account)
                if let kept = usage[account.id] {
                    (state.fiveHour, state.sevenDay, state.fiveHourResets, state.sevenDayResets, state.fullUntil)
                        = (kept.fiveHour, kept.sevenDay, kept.fiveHourResets, kept.sevenDayResets, kept.fullUntil)
                    state.reserveLifted = kept.reserveLifted
                }
                return state
            }
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
        let before = Usage(accounts[index])
        defer { if Usage(accounts[index]) != before { saveUsage() } }
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
        saveUsage()
    }

    /// "Use anyway" (#278): with `lift`, the account takes automatic work past its weekly reserve
    /// until its week resets (a week from now while its reset time is unknown), then it's reserved
    /// again by itself; without, it's reserved again now. Nil for an unknown account.
    @discardableResult
    func liftReserve(_ accountID: String, _ lift: Bool, now: Date = .now) -> AccountState? {
        guard let index = accounts.firstIndex(where: { $0.account.id == accountID }) else { return nil }
        let resets = accounts[index].sevenDayResets.flatMap { $0 > now ? $0 : nil }
        let until = lift ? resets ?? now.addingTimeInterval(7 * 86_400) : nil
        if accounts[index].reserveLifted != until {
            accounts[index].reserveLifted = until
            saveUsage()
        }
        return accounts[index]
    }

    /// Whether the account's agents have Tetrix connected, as its tool just said. Nil changes nothing.
    func setTetrix(_ connected: Bool?, for accountID: String) {
        guard let connected, let index = accounts.firstIndex(where: { $0.account.id == accountID }) else { return }
        accounts[index].tetrix = connected
    }

    /// What the tool says about the account's login, or nil when it's signed out.
    func setLabel(_ label: String?, for accountID: String) {
        guard let index = accounts.firstIndex(where: { $0.account.id == accountID }) else { return }
        accounts[index].label = label
    }

    func state(_ id: String) -> AccountState? { accounts.first { $0.account.id == id } }

    /// Counts each account's active jobs, and its recent ones that used Tetrix; `Job.account`
    /// holds the account's id. A job waiting for its `startWhen` (#216) isn't on it yet.
    func countRunning(_ jobs: [Job]) {
        for index in accounts.indices {
            accounts[index].running = jobs.filter { $0.isActive && !$0.waitsToStart && $0.account == accounts[index].account.id }.count
            (accounts[index].tetrixJobs, accounts[index].tetrixUsed) = TetrixUse.share(jobs, account: accounts[index].account.id)
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
                // Its own MCP servers, as agents get them: claude.ai's connectors are off for agents (#84).
                if label != nil {
                    let list = Agents.sandboxed(["claude", "mcp", "list"], in: nil, own: account.home ?? "\(Agents.home)/.claude")
                    let env = Agents.noConnectors.merging(["CLAUDE_CONFIG_DIR": account.home]) { $1 }
                    if let listed = try? await Shell.run(list, env: env, timeout: 30), listed.status == 0, !listed.timedOut {
                        setTetrix(TetrixUse.claudeList(listed.text), for: account.id)
                    }
                }
            case "codex":
                // Codex's app-server knows both the login and the limits; Claude Code's limits
                // arrive with its first job.
                let home = account.home.map { URL(filePath: $0) }
                label = (try? await CodexAgent.account(home: home)) ?? nil
                if label != nil, let used = try? await CodexAgent.usage(home: home) {
                    record(used.event, for: account.id)
                }
                if label != nil { setTetrix((try? await CodexAgent.tetrix(home: home)) ?? nil, for: account.id) }
            default:
                break
            }
            setLabel(label, for: account.id)
        }
    }

    /// What the tool said about an account's login: a label while signed in, nil when it isn't.
    /// `refresh` learns it; tests set it.

    /// Keeps every account's usage in `usage.json`; a failure only costs it after a restart.
    private func saveUsage() {
        let usage = Dictionary(accounts.map { ($0.account.id, Usage($0)) }) { first, _ in first }
        try? FileManager.default.createDirectory(at: usageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(usage).write(to: usageFile, options: .atomic)
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts.map(\.account)).write(to: file, options: .atomic)
    }

    /// What a job is for routing: new work keeps to accounts on pace, a review is short and goes
    /// to one ahead of it.
    nonisolated enum Work: Sendable { case new, review }

    /// The account `choose` chose, and why, for the job's report.
    nonisolated struct Route: Equatable, Sendable {
        var account: Account
        /// "most weekly room per day left (0.12/day); Codex · Deskree is 2.3× ahead of pace"
        var reason: String
        var id: String { account.id }
        /// "On Claude Code · Deskree: most weekly room per day left (0.12/day); Codex · Deskree is 2.3× ahead of pace."
        var why: String { "On \(account.heading): \(reason)." }
    }

    /// Prefer accounts under this share of their 5-hour window: one above it may stop mid-job.
    nonisolated static let busy = 0.8
    /// Accounts this close in weekly room per day count as even, and the fewer running jobs wins.
    nonisolated static let even = 0.01

    /// The account for a job, budgeted by each account's weekly pace: a signed-in account of that
    /// agent (any agent if nil) under 95% of both windows, not reserved for the week (`isReserved`:
    /// a review may take one that is, last; the user can lift it, #278) and not marked full. Of
    /// those, in order:
    /// - one under 80% of its 5-hour window, when there is one;
    /// - for new work, one on pace (`isAhead` false) with its usage known, then one whose usage
    ///   isn't known yet, then one ahead of pace; a review takes one ahead of pace first, then
    ///   on pace, then unknown;
    /// - the most weekly room per day left (`roomPerDay`); within 0.01/day of it, the fewest
    ///   running jobs, then the most room, then list order.
    /// Each account's usage is measured against its own plan. Every automatic choice goes through
    /// here (the brain's dispatch, the Lead's picks, failure fixes, failover, reviews, and a move
    /// with no account named, among accounts under 80% of both windows: Engine/Move.swift); only a
    /// job the user sends to an account by name skips it.
    nonisolated static func choose(_ accounts: [AccountState], agent: String?, for work: Work = .new, now: Date = .now) -> Route? {
        // A review is small: it may use an account in its weekly reserve (80%), last, while that
        // week is under 95%. Otherwise a job written on the only account outside its reserve
        // waits for a review no account will ever take (#269's PR, 2026-10-12). One whose reserve
        // the user lifted (#278) isn't reserved, but at 95% it's still left alone.
        let open = accounts.filter { $0.signedIn && (agent == nil || $0.account.agent == agent) && !$0.isFull(at: now)
            && ($0.fiveHour ?? 0) < AccountState.nearlyFull && !$0.weekNearlyFull(at: now)
            && (work == .review || !$0.isReserved(at: now)) }
        let calm = open.filter { ($0.fiveHour ?? 0) < busy }
        let pool = calm.isEmpty ? open : calm
        func tier(_ state: AccountState) -> Int {
            if state.isReserved(at: now) { return 4 }
            guard state.sevenDay != nil else { return 2 }
            switch work {
            case .new: return state.isAhead(at: now) ? 3 : 1
            case .review: return state.isAhead(at: now) ? 0 : 1
            }
        }
        guard let first = pool.map(tier).min() else { return nil }
        let tied = pool.filter { tier($0) == first }
        let room = { (state: AccountState) in state.roomPerDay(at: now) ?? 0 }
        let most = tied.map(room).max() ?? 0
        let close = tied.filter { room($0) >= most - even }
        let chosen = close.enumerated().min { (a, b) in
            (a.element.running, -room(a.element), a.offset) < (b.element.running, -room(b.element), b.offset)
        }!.element
        return Route(account: chosen.account, reason: reason(chosen, over: open, close: close, work: work, now: now))
    }

    /// Why `chosen` was taken over the other `open` accounts.
    nonisolated static func reason(_ chosen: AccountState, over open: [AccountState], close: [AccountState], work: Work, now: Date) -> String {
        var reasons: [String] = []
        if let room = chosen.roomPerDay(at: now) {
            var line = "most weekly room per day left (\(String(format: "%.2f", room))/day)"
            if close.count > 1 { line += " and the fewest jobs running" }
            if let pace = chosen.pace(at: now), chosen.isAhead(at: now) {
                line += work == .review ? ", \(times(pace)) ahead of pace, so a short review suits it" : ", though \(times(pace)) ahead of pace: none is on pace"
            }
            reasons.append(line)
        } else {
            reasons.append("its usage isn't known yet" + (close.count > 1 ? ", and the fewest jobs running" : ""))
        }
        if (chosen.fiveHour ?? 0) >= busy { reasons.append("every account is above 80% of its 5-hour window") }
        if work == .new, let ahead = open.filter({ $0.account.id != chosen.account.id && $0.isAhead(at: now) })
            .max(by: { ($0.pace(at: now) ?? 0) < ($1.pace(at: now) ?? 0) }), let pace = ahead.pace(at: now) {
            reasons.append("\(ahead.account.heading) is \(times(pace)) ahead of pace")
        }
        return reasons.joined(separator: "; ")
    }

    /// 2.31 as "2.3×".
    nonisolated static func times(_ pace: Double) -> String { String(format: "%.1f×", pace) }

    /// The accounts in their weekly reserve that would take this work if the user lifted it
    /// (`mayLiftReserve`): when `choose` finds none, these are why, and what "Use anyway" offers.
    nonisolated static func heldInReserve(_ accounts: [AccountState], agent: String?, now: Date = .now) -> [AccountState] {
        accounts.filter { (agent == nil || $0.account.agent == agent) && $0.mayLiftReserve(at: now) }
    }

    /// "Personal is in its weekly reserve", "Personal and Codex are in their weekly reserve".
    nonisolated static func reserveLine(_ held: [AccountState]) -> String {
        let names = held.map(\.account.name)
        let listed = names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return listed + (names.count == 1 ? " is in its weekly reserve" : " are in their weekly reserve")
    }

    /// What a plan card says of a job that waits for room because only `held` could take it:
    /// "Waiting: Personal is in its weekly reserve. Use it anyway to start it now; otherwise it
    /// starts when an account has room."
    nonisolated static func roomWait(_ held: [AccountState]) -> String {
        "Waiting: \(reserveLine(held)). Use \(held.count == 1 ? "it" : "one") anyway to start it now; otherwise it starts when an account has room."
    }

    /// Why no account takes new work, when only reserves stand in the way: "Personal and Codex are
    /// in their weekly reserve: use one anyway from Settings › Accounts." Nil when an account would
    /// take it, or none would even with its reserve lifted.
    nonisolated static func reserveWait(_ accounts: [AccountState], agent: String?, now: Date = .now) -> String? {
        guard choose(accounts, agent: agent, now: now) == nil else { return nil }
        let held = heldInReserve(accounts, agent: agent, now: now)
        guard !held.isEmpty else { return nil }
        return reserveLine(held) + ": use \(held.count == 1 ? "it" : "one") anyway from Settings › Accounts."
    }

    /// The account `choose` chose, without the why.
    nonisolated static func route(_ accounts: [AccountState], agent: String?, for work: Work = .new, now: Date = .now) -> Account? {
        choose(accounts, agent: agent, for: work, now: now)?.account
    }

    /// The account for the next of several jobs started together (the Lead's): `choose`, with the
    /// pick counted as running in `states`, so the next pick spreads out.
    nonisolated static func pick(_ states: inout [AccountState], agent: String?, now: Date = .now) -> Route? {
        guard let route = choose(states, agent: agent, now: now) else { return nil }
        if let index = states.firstIndex(where: { $0.account.id == route.id }) { states[index].running += 1 }
        return route
    }

    /// Where a job goes on from an account that hit its limit: the same tool first, then any.
    nonisolated static func next(_ accounts: [AccountState], agent: String, now: Date = .now) -> Route? {
        choose(accounts, agent: agent, now: now) ?? choose(accounts, agent: nil, now: now)
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
