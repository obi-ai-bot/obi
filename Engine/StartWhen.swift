import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// One thing a job waits for before it starts (#216): another job or a pull request to finish, an
/// account to have room, or a time. A job's `startWhen` lists them, and it starts once all of them
/// hold (`Desk.checkStartWhen`). Each kind describes itself and checks itself against what the
/// runner knows (`StartWhen.verdict`), so a new kind is one case in each.
///
/// As JSON (docs/runner-api.md): `{"job": "ab12cd34", "is": "merged"}`, `{"pr": 205, "is":
/// "merged"}`, `{"account": "<id>", "window": "fiveHour", "under": 0.5}`, `{"account": "<id>",
/// "onPace": true}`, `{"room": true, "agent": "claude"}`, `{"at": "2026-10-13T09:00:00Z"}`.
nonisolated enum StartCondition: Codable, Equatable, Sendable {
    /// What another job must have come to: `done` (it ended done), `merged` (its pull request was
    /// merged), `published` (its pull request is out) or `ended` (it ended in any way).
    enum JobState: String, Codable, CaseIterable, Sendable { case done, merged, published, ended }
    /// What a pull request must have come to: `closed` counts a merge too.
    enum PullRequestState: String, Codable, CaseIterable, Sendable { case merged, closed }
    enum Window: String, Codable, CaseIterable, Sendable { case fiveHour, sevenDay }

    case job(String, is: JobState)
    /// A pull request in the waiting job's repository.
    case pullRequest(Int, is: PullRequestState)
    /// The account's window is used under `under` (`AccountStore.busy` when nil): it reset, or
    /// went below the share. The account by id once Oby checked it (`StartWhen.checked`).
    case window(account: String, Window, under: Double?)
    /// The account's weekly use is back on pace (`AccountState.isAhead` false, #176).
    case onPace(account: String)
    /// Routing has an account for it, of `agent`'s tool (any when nil): a job sent while only
    /// accounts in their weekly reserve could take it waits for this (#278), and starts on the
    /// account routing picks then (`AccountStore.choose`).
    case room(agent: String?)
    case at(Date)

    /// The account it's about, if any: a job waiting on one runs on it.
    var account: String? {
        switch self {
        case .window(let account, _, _), .onPace(let account): account
        case .job, .pullRequest, .room, .at: nil
        }
    }

    /// It waits for an account with room, whichever (`room`).
    var isRoom: Bool { if case .room = self { true } else { false } }

    private enum Keys: String, CodingKey { case job, pr, `is`, account, window, under, onPace, room, agent, at }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        if try keys.decodeIfPresent(Bool.self, forKey: .room) == true {
            self = .room(agent: try keys.decodeIfPresent(String.self, forKey: .agent))
        } else if keys.contains(.job) {
            self = .job(try keys.decode(String.self, forKey: .job), is: try keys.decodeIfPresent(JobState.self, forKey: .is) ?? .done)
        } else if keys.contains(.pr) {
            self = .pullRequest(try keys.decode(Int.self, forKey: .pr), is: try keys.decodeIfPresent(PullRequestState.self, forKey: .is) ?? .merged)
        } else if keys.contains(.account) {
            let account = try keys.decode(String.self, forKey: .account)
            if let window = try keys.decodeIfPresent(Window.self, forKey: .window) {
                self = .window(account: account, window, under: try keys.decodeIfPresent(Double.self, forKey: .under))
            } else if try keys.decodeIfPresent(Bool.self, forKey: .onPace) == true {
                self = .onPace(account: account)
            } else {
                throw DecodingError.dataCorruptedError(forKey: .account, in: keys, debugDescription: "An account condition has a window or onPace true.")
            }
        } else if keys.contains(.at) {
            let text = try keys.decode(String.self, forKey: .at)
            guard let date = Self.date(text) else {
                throw DecodingError.dataCorruptedError(forKey: .at, in: keys, debugDescription: "at is an ISO 8601 time, like 2026-10-13T09:00:00Z.")
            }
            self = .at(date)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A condition has job, pr, account, room or at."))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        switch self {
        case .job(let id, let state):
            try keys.encode(id, forKey: .job)
            try keys.encode(state, forKey: .is)
        case .pullRequest(let number, let state):
            try keys.encode(number, forKey: .pr)
            try keys.encode(state, forKey: .is)
        case .window(let account, let window, let under):
            try keys.encode(account, forKey: .account)
            try keys.encode(window, forKey: .window)
            try keys.encodeIfPresent(under, forKey: .under)
        case .onPace(let account):
            try keys.encode(account, forKey: .account)
            try keys.encode(true, forKey: .onPace)
        case .room(let agent):
            try keys.encode(true, forKey: .room)
            try keys.encodeIfPresent(agent, forKey: .agent)
        case .at(let date):
            // A string whatever the encoder does with dates: the store and the API read the same.
            try keys.encode(date.formatted(.iso8601), forKey: .at)
        }
    }

    /// An ISO 8601 time with its offset, with or without fractions of a second.
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}

enum StartWhen {
    /// At most this many conditions per job.
    nonisolated static let most = 5
    /// What the inbox offers when a condition can never hold.
    nonisolated static let startAnyway = "Start anyway"
    nonisolated static let cancel = "Cancel"
    nonisolated static let somethingElse = "Wait for something else"

    /// Where one condition stands: it holds, it may hold later (saying what it waits for, after
    /// "Waiting"), or it never can (saying why).
    nonisolated enum Verdict: Equatable, Sendable {
        case holds
        case waits(String)
        case never(String)
    }

    /// What a condition is checked against: jobs by id, accounts by id, and pull requests' states
    /// (in a repository, by number) as Oby last read them, nil when it doesn't know; and every
    /// account, for `room`.
    struct Lookup {
        var job: (String) -> Job?
        var account: (String) -> AccountState?
        var pullRequest: (_ repo: String, _ number: Int) -> PullRequestStatus.State?
        var accounts: () -> [AccountState] = { [] }
    }

    /// Where `condition` of `job` stands at `now`. A window whose reset time has passed counts as
    /// empty: Claude Code reports usage only during a job, so its last share would stay.
    static func verdict(_ condition: StartCondition, of job: Job, now: Date, lookup: Lookup) -> Verdict {
        switch condition {
        case .job(let id, let wanted):
            guard let other = lookup.job(id) else { return .never("there's no job \(id) any more") }
            let name = other.heading
            let number = pullRequestNumber(other)
            let ended = ending(other)
            switch wanted {
            case .ended:
                return other.isActive ? .waits("for \(name) to end") : .holds
            case .done:
                if other.status == .done { return .holds }
                return other.isActive ? .waits("for \(name) to be done") : .never("\(name) \(ended), so it won't be done")
            case .published:
                if other.published != nil { return .holds }
                return other.isActive || other.canPublish ? .waits("for \(name) to be published") : .never("\(name) \(ended) with nothing published")
            case .merged:
                // What following its pull request saw, else what Oby read for these conditions.
                var state = other.pullRequest?.state
                if state != .merged, let number, let read = lookup.pullRequest(other.repo, number) { state = read }
                if state == .merged { return .holds }
                if state == .closed { return .never("\(name)'s pull request\(number.map { " #\($0)" } ?? "") was closed without merging") }
                if other.published != nil { return .waits("for \(name)\(number.map { " (#\($0))" } ?? "") to merge") }
                return other.isActive || other.canPublish ? .waits("for \(name) to merge") : .never("\(name) \(ended) with nothing published")
            }
        case .pullRequest(let number, let wanted):
            let state = lookup.pullRequest(job.repo, number)
            switch wanted {
            case .merged:
                if state == .merged { return .holds }
                return state == .closed ? .never("#\(number) was closed without merging") : .waits("for #\(number) to merge")
            case .closed:
                return state == .merged || state == .closed ? .holds : .waits("for #\(number) to close")
            }
        case .window(let id, let window, let under):
            guard let account = lookup.account(id) else { return .never("the account it waits on is gone") }
            if let waits = unavailable(account, now: now) { return .waits(waits) }
            let (used, resets) = window == .fiveHour ? (account.fiveHour, account.fiveHourResets) : (account.sevenDay, account.sevenDayResets)
            let limit = under ?? AccountStore.busy
            let share = resets.map { $0 <= now } == true ? 0 : used ?? 0
            if share < limit { return .holds }
            let name = window == .fiveHour ? "5-hour window" : "weekly window"
            let upcoming = resets.flatMap { $0 > now ? $0 : nil }
            if under == nil, let upcoming { return .waits("for \(account.account.heading): \(name) resets at \(when(upcoming, now: now))") }
            return .waits("for \(account.account.heading): \(name) under \(percent(limit))" + (upcoming.map { " (resets at \(when($0, now: now)))" } ?? ""))
        case .onPace(let id):
            guard let account = lookup.account(id) else { return .never("the account it waits on is gone") }
            if let waits = unavailable(account, now: now) { return .waits(waits) }
            guard account.isAhead(at: now), let pace = account.pace(at: now) else { return .holds }
            return .waits("for \(account.account.heading) to be back on its weekly pace (\(AccountStore.times(pace)) ahead)")
        case .room(let agent):
            let accounts = lookup.accounts()
            if AccountStore.choose(accounts, agent: agent, now: now) != nil { return .holds }
            let held = AccountStore.heldInReserve(accounts, agent: agent, now: now)
            return .waits(held.isEmpty ? "for an account with room" : "for room: " + AccountStore.reserveLine(held))
        case .at(let date):
            return now >= date ? .holds : .waits("until \(when(date, now: now))")
        }
    }

    /// Why a job can't start on the account now whatever its usage: it's signed out, or full.
    private static func unavailable(_ account: AccountState, now: Date) -> String? {
        if !account.signedIn { return "for \(account.account.heading) to be signed in" }
        if account.isFull(at: now), let until = account.fullUntil { return "for \(account.account.heading): it hit its limit, back at \(when(until, now: now))" }
        return nil
    }

    /// The job's step, `waiting` and question for what its conditions came to: "Waiting for
    /// Codex · Deskree: 5-hour window resets at 4:59", `waiting` with what follows "Waiting" (kind
    /// `limit` when the first thing it waits for is an account's room, else `schedule`, as #238
    /// defines them), and, when one can never hold and the user hasn't chosen to keep waiting, the
    /// inbox's decision. Nil when they all hold.
    nonisolated static func wait(_ checked: [(condition: StartCondition, verdict: Verdict)], kept: Bool)
        -> (step: String, waiting: Job.Waiting, question: Plan.Question?)? {
        var waits: [String] = []
        var never: [String] = []
        let open = checked.filter { $0.verdict != .holds }
        for (_, verdict) in open {
            switch verdict {
            case .holds: continue
            case .waits(let text): waits.append(text)
            case .never(let why): never.append(why)
            }
        }
        guard let first = open.first?.condition else { return nil }
        let kind: Job.Waiting.Kind = first.account == nil && !first.isRoom ? .schedule : .limit
        let job = open.lazy.compactMap { if case .job(let id, _) = $0.condition { id } else { nil } }.first
        if let why = never.first {
            let text = "for you: \(why)"
            return ("Waiting \(text).", Job.Waiting(kind: kind, text: text, job: job),
                    kept ? nil : Plan.Question(text: "It can't start as planned: \(why). Start it anyway, cancel it, or wait for something else?",
                                               options: [startAnyway, cancel, somethingElse]))
        }
        let text = waits.joined(separator: ", and ")
        return ("Waiting " + text, Job.Waiting(kind: kind, text: text, job: job), nil)
    }

    /// What started it, for its report: "Started when every condition held: job ab12cd34 merged, at 9:00 AM."
    static func describe(_ conditions: [StartCondition], accounts: (String) -> AccountState?) -> String {
        conditions.map { condition in
            switch condition {
            case .job(let id, let state): "job \(id) \(state == .done ? "done" : state.rawValue)"
            case .pullRequest(let number, let state): "#\(number) \(state.rawValue)"
            case .window(let id, let window, let under):
                "\(accounts(id)?.account.heading ?? id) \(window == .fiveHour ? "5-hour" : "weekly") window under \(percent(under ?? AccountStore.busy))"
            case .onPace(let id): "\(accounts(id)?.account.heading ?? id) on its weekly pace"
            case .room(let agent): "an account\(agent.map { " of \(Job.agentNames[$0] ?? $0)" } ?? "") with room"
            case .at(let date): "at \(date.formatted(.iso8601))"
            }
        }.joined(separator: ", ")
    }

    /// The conditions as given, checked, with every account by id: at most `most`, a known job
    /// other than `job`, a pull request's positive number, a share above 0 and up to 1, and an
    /// account known by id or name (`account`). A job waits on one account at most: it runs on it.
    static func checked(_ conditions: [StartCondition], job: String, jobs: (String) -> Job?, accounts: [AccountState]) throws -> [StartCondition] {
        guard conditions.count <= most else { throw Shell.Failure(message: "A job waits for \(most) things at most.") }
        let checked = try conditions.map { condition -> StartCondition in
            switch condition {
            case .job(let id, _):
                guard id != job else { throw Shell.Failure(message: "A job can't wait for itself.") }
                guard jobs(id) != nil else { throw Shell.Failure(message: "There's no job \(id) to wait for.") }
                return condition
            case .pullRequest(let number, _):
                guard number > 0 else { throw Shell.Failure(message: "A pull request's number is positive.") }
                return condition
            case .window(let named, let window, let under):
                if let under, !(under > 0 && under <= 1) { throw Shell.Failure(message: "under is a share above 0 and up to 1, like 0.5.") }
                return .window(account: try account(named, in: accounts).account.id, window, under: under)
            case .onPace(let named):
                return .onPace(account: try account(named, in: accounts).account.id)
            case .room(let agent):
                if let agent, Job.agentNames[agent] == nil { throw Shell.Failure(message: "There's no tool \(agent) to wait for room on.") }
                return condition
            case .at:
                return condition
            }
        }
        guard Set(checked.compactMap(\.account)).count <= 1 else { throw Shell.Failure(message: "A job waits on one account at most: it runs on that account.") }
        guard !checked.contains(where: \.isRoom) || !checked.contains(where: { $0.account != nil }) else {
            throw Shell.Failure(message: "A job waiting on an account runs on it: it doesn't wait for room on another.")
        }
        return checked
    }

    /// The account `named` names: by id, else by name (ignoring case), the signed-in one first,
    /// of `agent`'s tool first when it's given.
    static func account(_ named: String, agent: String? = nil, in accounts: [AccountState]) throws -> AccountState {
        if let byID = accounts.first(where: { $0.account.id == named }) { return byID }
        let matching = accounts.filter { $0.account.name.compare(named, options: .caseInsensitive) == .orderedSame }
        let ranked = matching.sorted { a, b in
            ((agent == nil || a.account.agent == agent) ? 0 : 1, a.signedIn ? 0 : 1) < ((agent == nil || b.account.agent == agent) ? 0 : 1, b.signedIn ? 0 : 1)
        }
        guard let first = ranked.first else { throw Shell.Failure(message: "There's no account \(named) to wait on.") }
        return first
    }

    /// The pull request a job published, by number, or nil.
    nonisolated static func pullRequestNumber(_ job: Job) -> Int? {
        job.published.flatMap { URL(string: $0) }.flatMap { Int($0.lastPathComponent) }
    }

    /// How a job that isn't active ended, in words: "failed", "was stopped".
    nonisolated private static func ending(_ job: Job) -> String {
        switch job.status {
        case .done: "is done"
        case .failed: "failed"
        case .stopped: "was stopped"
        case .interrupted: "was interrupted"
        case .queued, .running: "is \(job.status.rawValue)"
        }
    }

    /// "4:59 PM" today, else "Tue, Oct 13, 9:00 AM".
    nonisolated static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return Limits.clock(date) }
        return date.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().hour().minute().locale(Locale(identifier: "en_US")))
    }

    nonisolated private static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
}

extension Job {
    /// It's queued and waits for its `startWhen` (#216): it isn't running on its account yet.
    nonisolated var waitsToStart: Bool { status == .queued && startWhen != nil }
}

// MARK: The desk

extension Desk {
    /// What conditions are checked against here: the desk's jobs and the ones elsewhere (the
    /// runner's, on the Mac), its accounts, and pull requests as last read.
    var startWhenLookup: StartWhen.Lookup {
        StartWhen.Lookup(job: { [weak self] id in self?.job(id) ?? self?.elsewhere().flatMap(\.jobs).first { $0.id == id } },
                         account: { [weak self] id in self?.accounts.state(id) },
                         pullRequest: { [weak self] repo, number in self?.pullRequestStates["\(repo)#\(number)"] },
                         accounts: { [weak self] in self?.accounts.accounts ?? [] })
    }

    /// Whether a job that's ready to start waits for its `startWhen` instead (`startOrWait`): it
    /// stays queued, saying what it waits for, and is checked every `startWhenEvery`. False when it
    /// has none, or they all hold: then it's cleared and the job goes on to start.
    func holdsToStart(_ job: Job) -> Bool {
        guard job.startWhen != nil else { return false }
        // As it's ready: its worktree's commit is what it catches up from when it starts.
        replace(job)
        scheduled.insert(job.id)
        if reconsider(job.id, now: clock()) { return false }
        watchStartWhen()
        return true
    }

    /// Checks every waiting job's conditions now: pull requests they wait on are read first. A job
    /// whose conditions all hold starts (or waits for a slot), the others say what they wait for.
    func checkStartWhen() async {
        var wanted: Set<String> = []
        for id in scheduled {
            guard let job = job(id) else { continue }
            for condition in job.startWhen ?? [] {
                switch condition {
                case .pullRequest(let number, _): wanted.insert("\(job.repo)#\(number)")
                case .job(let other, .merged):
                    guard let other = startWhenLookup.job(other), other.pullRequest?.state != .merged,
                          let number = StartWhen.pullRequestNumber(other) else { continue }
                    wanted.insert("\(other.repo)#\(number)")
                default: continue
                }
            }
        }
        for key in wanted.sorted() {
            let parts = key.split(separator: "#")
            guard parts.count == 2, let number = Int(parts[1]) else { continue }
            if let state = await pullRequestState(String(parts[0]), number) { pullRequestStates[key] = state }
        }
        let now = clock()
        for id in scheduled.sorted() {
            if reconsider(id, now: now), let job = job(id) { startOrWait(job, catchUp: true) }
        }
    }

    /// Brings a waiting job's step and question up to date: true when its conditions all hold,
    /// and then its `startWhen` is cleared, for the caller to start it.
    @discardableResult
    func reconsider(_ id: String, now: Date) -> Bool {
        guard var job = job(id), job.status == .queued, let conditions = job.startWhen else {
            scheduled.remove(id)
            keptWaiting.remove(id)
            return false
        }
        let checked = conditions.map { ($0, StartWhen.verdict($0, of: job, now: now, lookup: startWhenLookup)) }
        guard let wait = StartWhen.wait(checked, kept: keptWaiting.contains(id)) else {
            scheduled.remove(id)
            keptWaiting.remove(id)
            Logger.jobs.notice("job \(id, privacy: .public): starts, what it waited for came")
            // It waited for room (#278): it runs where routing finds it, as if just sent.
            if let room = conditions.first(where: \.isRoom), case .room(let agent) = room,
               let route = AccountStore.choose(accounts.accounts, agent: agent, now: now) {
                if route.account.agent != job.agent { job.model = nil }
                (job.account, job.agent) = (route.account.id, route.account.agent)
                noteStart(route.why, for: id)
            }
            job.startWhen = nil
            job.waiting = nil
            job.question = nil
            job.step = "Getting \(job.repoName) ready"
            noteStart("Started when what it waited for came: \(StartWhen.describe(conditions, accounts: accounts.state)).", for: id)
            replace(job)
            return true
        }
        var waiting = wait.waiting
        // Waiting for room while only reserves stand in the way (#278): the apps offer "Use
        // Personal anyway" on these accounts.
        if let room = conditions.first(where: \.isRoom), case .room(let agent) = room {
            let held = AccountStore.heldInReserve(accounts.accounts, agent: agent, now: now).map(\.account.id)
            waiting.reserved = held.isEmpty ? nil : held
        }
        if job.step != wait.step || job.waiting != waiting || job.question != wait.question {
            (job.step, job.waiting, job.question) = (wait.step, waiting, wait.question)
            replace(job)
        }
        return false
    }

    /// Checks the waiting jobs every `startWhenEvery` while there are any (the runner's minute).
    func watchStartWhen() {
        guard startWhenTimer == nil, !scheduled.isEmpty else { return }
        startWhenTimer = Task { [weak self] in
            while let every = self?.startWhenEvery, self?.scheduled.isEmpty == false {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled, let self else { return }
                await self.checkStartWhen()
            }
            self?.startWhenTimer = nil
        }
    }

    /// Start now: a job waiting for its `startWhen` starts as if it had come (or waits for a
    /// slot); one still getting ready starts once it's ready.
    func startNow(_ id: String) throws {
        guard var job = job(id), job.waitsToStart else { throw Shell.Failure(message: "That job isn't waiting to start.") }
        job.startWhen = nil
        job.waiting = nil
        job.question = nil
        let held = scheduled.remove(id) != nil
        keptWaiting.remove(id)
        if held { job.step = "Getting \(job.repoName) ready" }
        noteStart("Started by you before what it waited for came.", for: id)
        replace(job)
        if held { startOrWait(job, catchUp: true) }
    }

    /// Changes what a queued job waits for (none: it starts now). An account condition moves it
    /// to that account. Not once it started.
    @discardableResult
    func setStartWhen(_ id: String, _ conditions: [StartCondition]) throws -> Job {
        guard var job = job(id), job.status == .queued, !isStartingUp(id) else {
            throw Shell.Failure(message: "Only a job that hasn't started can wait for something.")
        }
        guard job.reviewOf == nil else { throw Shell.Failure(message: "Oby's own reviews start by themselves.") }
        guard !conditions.isEmpty else {
            if job.startWhen != nil { try startNow(id) }
            return self.job(id) ?? job
        }
        job.startWhen = try StartWhen.checked(conditions, job: id, jobs: startWhenLookup.job, accounts: accounts.accounts)
        if let account = job.startWhen?.compactMap(\.account).first, let state = accounts.state(account), account != job.account {
            if state.account.agent != job.agent { job.model = nil }
            (job.account, job.agent) = (state.account.id, state.account.agent)
        }
        job.question = nil
        keptWaiting.remove(id)
        // Waiting for a slot: it waits for this first, and then for a slot again.
        let wasWaiting = dropFromSlotQueue(id)
        replace(job)
        // Ready already: it waits for this now (`startOrWait` holds it), or starts when it holds.
        if scheduled.contains(id) || wasWaiting { startOrWait(job, catchUp: true) }
        return self.job(id) ?? job
    }

    /// The user's answer to the inbox's decision on a job whose condition can never hold.
    func decideStart(_ id: String, _ answer: String) throws {
        switch answer {
        case StartWhen.startAnyway: try startNow(id)
        case StartWhen.cancel: stop(id)
        case StartWhen.somethingElse:
            // It keeps waiting, unasked: the user changes what for (`setStartWhen`), starts or cancels it.
            keptWaiting.insert(id)
            reconsider(id, now: clock())
        default:
            throw Shell.Failure(message: "Answer \(StartWhen.startAnyway), \(StartWhen.cancel) or \(StartWhen.somethingElse). To wait for something else, change what it waits for.")
        }
    }

    /// Whether the inbox's question on job `id` is the decision on its `startWhen`: it's waiting
    /// to start, so no agent asked it.
    func asksAboutStart(_ id: String) -> Bool { job(id)?.waitsToStart == true }

    /// The job's account conditions on the account it left go when it moves, and so does waiting
    /// for room on any (#278): it runs where it went.
    nonisolated static func movedStartWhen(_ conditions: [StartCondition]?, leaving account: String) -> [StartCondition]? {
        conditions.map { $0.filter { $0.account != account && !$0.isRoom } }
    }

    /// "Use anyway" (#278): the account takes work past its weekly reserve until its week resets
    /// (`AccountStore.liftReserve`), and jobs waiting for room look at once; without `lift` it's
    /// reserved again. Nil for an unknown account.
    @discardableResult
    func liftReserve(_ accountID: String, _ lift: Bool) -> AccountState? {
        guard let state = accounts.liftReserve(accountID, lift, now: clock()) else { return nil }
        if lift, !scheduled.isEmpty { Task { await checkStartWhen() } }
        return state
    }
}
