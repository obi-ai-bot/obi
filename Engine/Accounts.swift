import Foundation
import Observation

/// One login of a coding tool that Oby can send jobs to, and who pays for it.
nonisolated struct Account: Codable, Identifiable, Equatable, Sendable {
    var id: String
    /// "claude", "codex" or "cursor".
    var agent: String
    /// The user's label, like "Personal".
    var name: String
    /// Who pays for it, like "Wellington" or "Deskree".
    var payer: String
    /// The account's config directory, or nil for the tool's default (`~/.claude`, `~/.codex`). Cursor
    /// accounts always have one of Oby's own.
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
    /// Whether the runner says the login is there (obid's `signedIn`): it knows logins the label
    /// doesn't show, like Claude Code's in the Keychain, and sends `label: null` until a tool reports
    /// one (#626). Nil for Oby's own accounts and from older runners: then the label says.
    var runnerSignedIn: Bool?

    var signedIn: Bool { runnerSignedIn ?? (label != nil) }
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

    /// Reads `accounts.json` again when another program (the Oby app, for a runner that shares its
    /// accounts) changed it: new accounts appear signed out until `refresh`, removed ones go, and
    /// the ones that stay keep what Oby knows of them. Returns whether the list changed.
    @discardableResult
    func reloadSaved() -> Bool {
        guard let saved = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode([Account].self, from: $0) }),
              saved != accounts.map(\.account) else { return false }
        accounts = saved.map { account in
            var state = accounts.first { $0.account.id == account.id } ?? AccountState(account: account)
            state.account = account
            return state
        }
        return true
    }

    /// Adds an account with a fresh, empty home. It's signed out until the user signs in.
    @discardableResult
    func add(agent: String, name: String, payer: String, separateLogins: Bool = CursorFacts.separateLogins) throws -> Account {
        // Cursor keeps one login per Mac user until the probe shows two homes keep separate ones (#24).
        if agent == "cursor", !separateLogins, accounts.contains(where: { $0.account.agent == "cursor" }) {
            throw Shell.Failure(message: CursorFacts.oneLogin + ": it has one Cursor account already.")
        }
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
            case "cursor":
                label = await Self.cursorLabel(home: account.home)
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
            // A tool that reports no usage (Cursor) takes automatic work only when nothing else can:
            // its usage is unknown, which would otherwise rank it with the accounts that haven't said yet.
            if !reportsUsage(state.account.agent) { return 5 }
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
        if !reportsUsage(chosen.account.agent) {
            return "\(Job.agentNames[chosen.account.agent] ?? chosen.account.agent) reports no usage: fewest jobs running"
        }
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

    /// The Claude account Oby's brain thinks with (the chat, the inbox's plain words, the Lead's
    /// goals). A turn is small, so like a review it may use an account in its weekly reserve; past
    /// that, any signed-in one that isn't stopped at its limit, the least busy first. Without this
    /// the chat went silent when every account was past 80% of its week (2026-10-12), which is just
    /// when the user needs it to re-route the jobs. Nil when no Claude account can answer.
    nonisolated static func thinker(_ accounts: [AccountState], now: Date = .now) -> Account? {
        route(accounts, agent: "claude", for: .review, now: now)
            ?? accounts.filter { $0.signedIn && $0.account.agent == "claude" && !$0.isFull(at: now) }
                .min { ($0.fiveHour ?? 0) < ($1.fiveHour ?? 0) }?.account
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

    /// The account's Cursor login: what `cursor-agent status` says, boxed like a job, with the
    /// account's `CURSOR_CONFIG_DIR`. When that says neither way, a non-empty `cursor-agent models`
    /// means "Signed in". Oby never reads a token file.
    static func cursorLabel(home: String?) async -> String? {
        let own = home ?? "\(Agents.home)/.cursor"
        let status = Agents.sandboxed(["cursor-agent", "status"], in: nil, own: own)
        if let result = try? await Shell.run(status, env: CursorStatus.environment(home: home), timeout: 30), !result.timedOut {
            switch CursorStatus.parse(result.text) {
            case .signedIn(let label): return label
            case .signedOut: return nil
            case .unknown: break
            }
        }
        return await CursorModels.list(home: own).isEmpty ? nil : "Signed in"
    }

    /// Whether a tool tells Oby about its usage windows at all: Claude Code and Codex do (the apps'
    /// `Usage.reports` says the same). Cursor doesn't, so routing keeps it for last.
    nonisolated static func reportsUsage(_ agent: String) -> Bool { agent == "claude" || agent == "codex" }

    /// "Max · name@example.com" from `claude auth status --json`, or nil when it isn't signed in.
    nonisolated static func claudeLabel(status: Data) -> String? {
        guard let info = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
              info["loggedIn"] as? Bool == true else { return nil }
        let parts = [(info["subscriptionType"] as? String)?.capitalized, info["email"] as? String].compactMap { $0 }
        return parts.isEmpty ? "Signed in" : parts.joined(separator: " · ")
    }

    /// What Terminal runs to sign in: the tool's own login command and nothing else.
    nonisolated static func signInScript(for account: Account, headless: Bool = Agents.bubblewrap) -> String {
        let (variable, login) = switch account.agent {
        case "codex": ("CODEX_HOME", "codex login")
        case "cursor": ("CURSOR_CONFIG_DIR", "cursor-agent login")
        default: ("CLAUDE_CONFIG_DIR", "claude auth login")
        }
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        let who = account.payer.isEmpty ? account.name : "\(account.name), paid by \(account.payer)"
        // On a machine with no browser (the runner) Cursor prints a link to open on any device.
        let headless = account.agent == "cursor" && headless
        var lines = ["#!/bin/sh", account.home.map { "export \(variable)=\(quote($0))" } ?? "unset \(variable)"]
        // Cursor's login is a file under XDG_CONFIG_HOME: a login of the account's own takes its HOME too.
        if account.agent == "cursor", let home = account.home {
            lines += ["export XDG_CONFIG_HOME=\(quote(home + "/.config"))", "export HOME=\(quote(home))"]
        }
        if headless { lines.append("export NO_OPEN_BROWSER=1") }
        lines.append("echo \(quote("Oby: sign in to the account for \(who)."))")
        if headless { lines.append("echo 'Open the link on any device.'") }
        // On macOS Claude writes its login to the keychain when it can. A job cannot reach that
        // keychain (#459). When the keychain's files are denied, Claude writes `.credentials.json`
        // into `CLAUDE_CONFIG_DIR` instead, and that file is what the job uses. Oby never reads it.
        #if os(macOS)
        if account.agent == "claude" {
            lines.append("sandbox-exec -p '(version 1)(allow default)(deny file-read* file-write* (regex \"^/Users/[^/]+/Library/Keychains\") (regex \"^/private/var/folders/.*/com.apple.security\"))' \(login)")
        } else {
            lines.append(login)
        }
        #else
        lines.append(login)
        #endif
        lines += ["echo", "echo 'Done? Go back to Oby. You can close this window.'"]
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func isOwned(_ path: String, in homes: URL) -> Bool {
        let root = homes.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root)
    }
}
