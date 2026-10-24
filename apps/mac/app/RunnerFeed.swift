import AppKit
import Foundation
import Observation
import OSLog
import UserNotifications

/// The always-on runner (Settings › Runner) for as long as Oby runs, not only while the window is
/// open: its jobs, followed over `GET /v1/events` (one idle connection the runner pings every 15
/// seconds), and an alert when one needs the user, as the iPhone gets them (Runner/Push.swift).
@Observable
final class RunnerFeed {
    /// What a job needs from the user, the only thing an alert is for: the runner's own notices.
    nonisolated enum Notice: String, Sendable {
        /// Done with commits Oby couldn't publish by itself: it waits for Publish.
        case ready
        case failed
        case interrupted
        /// Oby's review requested changes for the last time it may: a person takes it from here.
        case review
        /// Its agent waits for an OK on a command or a file: Allow and Deny in the alert.
        case permission
        /// Its agent asked the user something and waits for the answer (the inbox has it).
        case question
        /// Oby's merge stopped: it couldn't merge, or the Mac check failed with no round left.
        case merge
        /// A job the owner started ended done (#613): its one-line result.
        case done
    }

    private(set) var jobs: [Job] = [] {
        didSet {
            let count = jobs.count(where: \.isWorking)
            if count != working { working = count }
            let queued = jobs.count(where: \.isWaiting)
            if queued != waiting { waiting = queued }
        }
    }
    /// Agents working on the runner now (jobs waiting their turn aren't, #238). The menu bar's count
    /// reads this, not `jobs`, so a new step doesn't redraw it.
    private(set) var working = 0
    /// The runner's jobs queued behind something (`Job.waiting`).
    private(set) var waiting = 0
    /// What waits in the runner's inbox, put-off items too, oldest first: answered on the iPhone,
    /// it goes from here too.
    private(set) var inbox: [InboxItem] = []
    /// Confirmed decisions stay in the messenger even after leaving the attention inbox.
    private(set) var inboxHistory: [InboxItem] = []
    /// Oby's plain words for each of those items (#65), which Engine's InboxItem doesn't read, by item
    /// id; on a `confirm` item, also what its Confirm carries out.
    private(set) var inboxWords: [String: InboxWords] = [:]

    /// The item's kind as the runner names it: `confirm` for one Engine reads as a `start` (`InboxItem.runner`).
    func kind(of item: InboxItem) -> String { item.shownKind(inboxWords[item.id]) }

    /// Whether the item is a `confirm` (obid only, #546): only the user's own answer carries it out,
    /// never the brain's. With no words for it, an item read as a `start` that offers Confirm counts too.
    func isConfirm(_ item: InboxItem) -> Bool {
        inboxWords[item.id]?.confirm != nil || (item.kind == .start && item.options.contains(RunnerConfirm.confirm))
    }

    /// What the brain's briefing may read of the inbox: everything but confirm items, which only the
    /// user answers (the brain can't name what it doesn't see).
    /// A job's agent's question (#858) is the user's alone to answer: the brain isn't told it.
    var briefingInbox: [InboxItem] { inbox.filter { !isConfirm($0) && $0.kind != .agentQuestion } }
    /// The runner's accounts and their usage, as it last said: the brain tells them too.
    private(set) var accounts: [AccountState] = []
    /// obid's Tetrix, held once for every agent: read on connecting, then kept by its `tetrix`
    /// event and by Settings › Connectors' own reads; nil from a runner that doesn't hold one.
    var tetrix: TetrixStatus?
    /// obid's Slack and its watcher (Settings › Connectors), read there and kept by their events.
    var slack: SlackStatus?
    /// obid's Sentry as its last `sentry` event said (Settings › Connectors keeps the repositories).
    var sentry: SentryStatus?
    var watch: WatchStatus?
    /// The watcher's and the channel listener's items waiting in the inbox (Engine's inbox doesn't
    /// know their kinds), oldest first.
    private(set) var notices: [WatchNotice] = []
    /// What each job carries that Engine's Job doesn't read yet (its mode, the permission it waits
    /// on, its question's recommended option and plan), by job id.
    /// Counts the `routine` events (#395): Settings › Routines reads the routines again on each.
    private(set) var routineChanges = 0
    /// obid's routines (#395), for the next runs on Home's Routines page; none from a runner without.
    private(set) var routines: [RunnerRoutine] = []
    /// The teammates' Macs a job can run on (#808), as obid last listed them; each list goes to `onMacs`.
    private(set) var macs: [RunnerMac] = [] { didSet { if macs != oldValue { onMacs?(macs) } } }
    var onMacs: (([RunnerMac]) -> Void)?
    /// The shares of their API accounts teammates gave this owner (#809), read with the Macs; each
    /// list goes to `onShares`.
    private(set) var shares: [RunnerShares.Share] = [] { didSet { if shares != oldValue { onShares?(shares) } } }
    var onShares: (([RunnerShares.Share]) -> Void)?
    /// The teammate's Obi whose Mac the next words' jobs run on, taken by the next `plan` (the
    /// message box's "Run on another Mac"; Engine's Desk, frozen, doesn't carry it).
    // ponytail: one message at a time from this Mac, so a slot is enough; a queue if sends overlap.
    var runsOnNext: String?
    private var macsTask: Task<Void, Never>?
    /// The session the window shows (#785): its job's `transcript` events go to it, and it reads
    /// what it missed when the connection comes back.
    @ObservationIgnored var liveSession: LiveSession?
    private(set) var extras: [String: RunnerJobExtras] = [:] {
        didSet { capturePermissions() }
    }
    struct PermissionRecord: Identifiable, Equatable {
        var job: String
        var permission: RunnerPermission
        var created: Date
        var done: Date?
        var answer: String?
        var later: Date?
        var id: String { job + "/" + permission.id }
        func waits(at date: Date) -> Bool { done == nil && (later == nil || later! <= date) }
    }
    private(set) var permissionHistory: [PermissionRecord] = []

    /// #134 supplies canonical permission inbox records. Legacy runners only send job extras;
    /// use their temporary records only when the same request is absent from the inbox/history.
    var chatPermissions: [PermissionRecord] {
        let canonical = Set((inbox + inboxHistory).filter { $0.kind == .permission }.map(\.id))
        return permissionHistory.filter { !canonical.contains("\($0.job)-permission-\($0.permission.id)") }
    }

    private func capturePermissions() {
        for (job, extra) in extras {
            guard let permission = extra.permission else { continue }
            if !permissionHistory.contains(where: { $0.job == job && $0.permission.id == permission.id }) {
                permissionHistory.append(PermissionRecord(job: job, permission: permission, created: .now))
            }
        }
        for index in permissionHistory.indices where permissionHistory[index].done == nil {
            let record = permissionHistory[index]
            if extras[record.job]?.permission?.id != record.permission.id { permissionHistory[index].done = .now }
        }
    }

    func laterPermission(_ id: String) {
        guard let index = permissionHistory.firstIndex(where: { $0.id == id && $0.done == nil }) else { return }
        permissionHistory[index].later = .now.addingTimeInterval(3600)
    }
    /// The mode the runner's new jobs get by default, or nil from a runner without modes.
    private(set) var defaultMode: RunnerMode?
    /// The name the runner reports in /v1/status, like "tetrix-lab".
    private(set) var host: String?
    /// The runner version shown in quick Settings.
    private(set) var version: String?
    /// When Clear done was last pressed, here or on the iPhone (the runner's clock), or nil: the
    /// window hides the jobs that finished by then, the runner's and this Mac's alike.
    private(set) var clearedAt: Date?
    /// How the line to the runner is: Settings › Runner says it.
    private(set) var connection = RunnerConnection.connecting {
        didSet { if connection == .live && oldValue != .live { onLive() } }
    }
    /// The runner answers again (or for the first time): kept hook deliveries go to it (#1315).
    @ObservationIgnored var onLive: () -> Void = {}
    /// The runner didn't answer the last try; the feed keeps trying.
    var down: Bool { if case .offline = connection { true } else { false } }
    /// The model and effort the runner's jobs use, as it last said (Settings › Models).
    private(set) var models: ModelSettings?
    private(set) var cleanup: RunnerStatus.Cleanup?
    /// Who the runner's own GitHub calls act as, `app` or `owner`, and whether its check runs reach
    /// pull requests, as it last said (Settings › Connectors); nil from older runners.
    private(set) var github: String?
    private(set) var checkRuns: String?
    /// Your work on GitHub as obid's gh finds it (Review PR and Issues), nil from a runner that doesn't list it.
    private(set) var gitHubWork: GitHubWork?
    /// The first GitHub read since [`forget`] has finished, feed or not. Until then Issues and Review PR show skeletons.
    private(set) var gitHubListed = false
    /// The GitHub items put off with Later, until Oby quits.
    var gitHubLater: Set<String> = []

    /// obid's GitHub work, as the `github` event or a refresh brings it: the whole feed.
    func apply(_ work: GitHubWork) { gitHubWork = work }

    /// Has obid read GitHub again (opening Review PR or Issues); the feed it answers replaces this one.
    func refreshGitHubWork() async {
        guard let runner else { return }
        #if DEBUG
        if GitHubWork.sample != nil { return }
        #endif
        await readGitHub { try await runner.refreshGitHubWork() }
    }

    /// Applies obid's answer about GitHub to the feed as it is by then, unless the runner changed meanwhile.
    private func readGitHub(_ ask: () async throws -> GitHubWork?) async {
        let asked = runnerChanges
        let answer = await GitHubWork.ask(ask)
        guard runnerChanges == asked else { return }
        gitHubWork = answer.applied(to: gitHubWork)
        gitHubListed = true
    }

    /// One click on a GitHub item: Oby's job on it, which joins the list as the runner's job.
    func startGitHubWork(_ id: String) async throws {
        guard let runner else { throw RunnerError(message: "Oby isn't following a runner.") }
        let asked = runnerChanges
        let job = try await runner.startGitHubWork(id)
        if runnerChanges == asked { apply(job) }
    }
    /// Merge checks this Mac runs for the runner (Settings › Runner, off by default).
    let checks = MacChecks()
    /// This Mac's Touch ID key, registered on every connection: with it, the runner's jobs publish from here.
    let device = MacDevice()
    /// The runner's conversation, read in pages and followed over `turn` events, for the window's
    /// thread (apps/shared/ConversationModel.swift): one thread for every device (#11).
    let conversation = ConversationModel()
    /// obid's many conversations (#493), when the runner on this Mac serves them: the side panel
    /// lists them and `conversation` shows the one picked. Empty for a runner with one thread.
    let conversations: ConversationList
    /// A job's notice just changed to something that needs the user, once its alert is posted.
    @ObservationIgnored var onNotice: (Job, Notice) -> Void = { _, _ in }

    /// The URL followed now, or nil before `start`.
    @ObservationIgnored private var url: String?
    /// Settings › Runner says "This Mac" (#283): the runner is the login item on this Mac, at
    /// `LocalRunner.url`, with its own token; this Mac's desk then plans and runs nothing itself.
    private(set) var local = false
    /// The local runner's token, read from obid's private file or the Swift runner's keychain.
    @ObservationIgnored private var token: String?
    /// Settings › Runner changed which runner is followed, with whether it's the one on this Mac.
    @ObservationIgnored var onFollow: (_ local: Bool) -> Void = { _ in }
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// What each job's alert last said, or nil until the first list arrives: what the jobs already
    /// need when Oby starts isn't news.
    @ObservationIgnored private var notified: [String: String]?
    /// The runner's jobs whose screen the window shows: new lists keep them even when they're
    /// older than the latest 50, as on the iPhone.
    @ObservationIgnored private var onScreen: Set<String> = []
    /// How many times Settings › Runner changed: an answer from before the last change is the
    /// other runner's, and is dropped.
    @ObservationIgnored private var runnerChanges = 0

    /// The runner followed, or nil: none is set, or the one on this Mac hasn't made its token yet.
    var runner: Runner? { Self.runner(url ?? "", token: local ? token : nil, local: local) }
    var active: [Job] { jobs.filter(\.isActive) }

    /// "tetrix-lab": what the runner calls itself, or its URL's first name before it has answered.
    /// The runner on this Mac is "This Mac".
    var name: String {
        if local { return "This Mac" }
        return host ?? runner?.base.host()?.split(separator: ".").first.map(String.init) ?? "The runner"
    }

    /// Settings › Runner's choice: true for the runner on this Mac (#283), false for a remote one at `runnerURL`.
    static let thisMacKey = "runnerOnThisMac"

    /// A runner at `url`; one on this Mac (`local`) only with its `token`, which every request carries.
    static func runner(_ url: String, token: String? = nil, local: Bool = false) -> Runner? {
        if local, token == nil { return nil }
        return URL(string: url.trimmingCharacters(in: .whitespaces)).flatMap { $0.host() == nil ? nil : Runner(base: $0, token: token) }
    }

    init() {
        conversations = ConversationList(thread: conversation)
        conversations.runner = { [weak self] in self?.runner }
        conversation.page = { [weak self] before, limit in
            guard let self, let runner = self.runner else { return [] }
            // A new conversation has nothing to read until its first words start it.
            if conversations.served, conversations.shown == nil { return [] }
            let turns = try await runner.conversationTurns(id: conversations.served ? conversations.shown : nil, before: before, limit: limit)
            conversation.note(turns)
            return turns.map(\.turn)
        }
        conversation.lookUp = { [weak self] id in try await self?.runner?.artifact(id) }
    }

    #if DEBUG
    /// What Settings' pictures show (apps/mac/tests/WindowScreens.swift): the runner on this Mac with
    /// made-up accounts and models, and no runner asked.
    @ObservationIgnored var stagedOptions: ModelOptions?
    func stage(accounts: [AccountState], models: ModelSettings, options: ModelOptions) {
        local = true
        self.accounts = accounts
        self.models = models
        stagedOptions = options
        connection = .live
    }

    /// Following `runner`, past its first lists: what changes from here alerts (the alert tests).
    func stageAlerts(following runner: Runner) {
        url = runner.base.absoluteString
        local = false
        inboxListed = true
        notified = [:]
    }

    /// Settings › Connectors' lists and obid's Tetrix, and jobs' extras, for the pictures of them.
    @ObservationIgnored var stagedLists: Connectors.Lists?
    func stage(tetrix: TetrixStatus?, lists: Connectors.Lists = .init(), extras: [String: RunnerJobExtras] = [:]) {
        self.tetrix = tetrix
        stagedLists = lists
        self.extras.merge(extras) { $1 }
    }
    #endif

    func start() {
        follow()
        // Settings › Runner writes the URL as it's typed: follow it once the typing settles.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        // After sleep the old connection is dead but may take a minute to say so: reconnect now.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow(again: true) }
        }
        // A merge check a Mac took and went quiet on comes back after a while, with no event: look now and then.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(600))
                guard let self else { return }
                if let runner, !down { checks.look(runner) }
            }
        }
    }

    private func follow(again: Bool = false) {
        let local = UserDefaults.standard.bool(forKey: Self.thisMacKey)
        let url = local ? LocalRunner.url.absoluteString : UserDefaults.standard.string(forKey: "runnerURL") ?? ""
        guard again || url != self.url || local != self.local else { return }
        let first = self.url == nil
        let changed = url != self.url || local != self.local
        // At launch the last runner's answers are kept for `showKept`; after that a change drops them.
        if changed { forget(droppingKept: !first) }
        self.url = url
        self.local = local
        token = nil
        if changed { onFollow(local) }
        connection = .connecting
        loop?.cancel()
        loop = nil
        guard local || Self.runner(url) != nil else { return }
        // At launch: the runner's last answers until it answers again.
        if first { _ = showKept(for: url) }
        loop = Task {
            if !first { try? await Task.sleep(for: .seconds(1)) }
            await run()
        }
    }

    /// Another runner: nothing the last one said holds, and what's still on its way from it is dropped,
    /// with what was kept of it for the next launch (`droppingKept`).
    func forget(droppingKept: Bool = true) {
        runnerChanges += 1
        showingKept = false
        if droppingKept { try? FileManager.default.removeItem(at: keptFile) }
        jobs = []
        inbox = []
        inboxHistory = []
        inboxWords = [:]
        notices = []
        accounts = []
        tetrix = nil
        slack = nil
        watch = nil
        models = nil
        extras = [:]
        permissionHistory = []
        defaultMode = nil
        host = nil
        version = nil
        github = nil
        checkRuns = nil
        gitHubWork = nil
        gitHubListed = false
        gitHubLater = []
        clearedAt = nil
        notified = nil
        inboxListed = false
        asked = [:]
        answered = [:]
        askedAt = [:]
        conversation.forget()
        conversations.reset()
        echoes = []
        device.reset()
    }

    /// Follows the runner's events and, once it's following, fetches the jobs and the inbox; after
    /// any drop it tries again, waiting a little longer each time, up to half a minute. The runner
    /// on this Mac is followed once its file or keychain token exists:
    /// until then the line says so, and the next try reads it again.
    private func run() async {
        var wait = 1.0
        while !Task.isCancelled {
            do {
                if local, token == nil { token = LocalRunner.token() }
                guard let runner else {
                    throw RunnerError(message: "The runner on this Mac hasn't started yet: Oby follows it once it has (Settings › Runner).")
                }
                // Following first, then fetching: what changes in between waits in the stream and
                // applies over what was fetched.
                for try await event in runner.events() {
                    switch event {
                    case .connected:
                        // Side by side. The window goes live once status, jobs and the inbox are in.
                        // GitHub, chat history and the rest fill in after: a slow read must not
                        // leave the window on "the runner hasn't started".
                        async let statusAnswer = runner.status()
                        async let jobsAnswer = runner.jobsAnswer()
                        async let inboxAnswer = runner.inboxAnswer()
                        async let historyAnswer = try? runner.inboxWithWords(state: "done")
                        async let tetrixAnswer = try? runner.tetrix()
                        async let routinesAnswer = try? runner.routines()
                        async let conversationsAnswer: Data? = local ? runner.conversationsAnswer(limit: 200) : nil
                        async let gitHubRead: Void = readGitHub { try await runner.gitHubWork() }
                        let status = try await statusAnswer
                        let jobsData = try await jobsAnswer
                        let (list, extras) = try Runner.jobsWithExtras(jobsData)
                        let inboxData = try await inboxAnswer
                        let (items, words) = try inboxData.map(Runner.inboxWithWords) ?? ([], [:])
                        let fetchedNotices = inboxData.map(WatchNotice.list) ?? []
                        try Task.checkCancellation()
                        host = status.runner.host
                        version = status.runner.version
                        clearedAt = status.clearedAt
                        accounts = status.accounts
                        models = status.models
                        cleanup = status.cleanup
                        github = status.github
                        checkRuns = status.checks
                        defaultMode = RunnerMode(status.permissions?.mode)
                        self.extras = extras
                        await take(list, from: runner)
                        try Task.checkCancellation()
                        // Alerts of items that don't wait any more, from before a drop or before Oby last quit,
                        // against the inbox as it is by then (an item may have come meanwhile).
                        Task { [weak self] in
                            guard let self else { return }
                            let delivered = await deliveredInbox()
                            let stale = Alerts.stale(delivered, waiting: Set(inbox.filter { $0.waiting() }.map(\.id)))
                            if !stale.isEmpty { withdraw(stale) }
                        }
                        // What waits when Oby starts isn't news; after a drop, what came meanwhile is.
                        if !inboxListed { told.formUnion(items.map(\.id)) }
                        inboxListed = true
                        inbox = items
                        let stillOpen = fetchedNotices.filter { $0.done == nil }.sorted { $0.created < $1.created }
                        let gone = Self.settledWhileAway(before: notices, after: stillOpen)
                        if !gone.isEmpty { withdraw(gone) }
                        notices = stillOpen
                        inboxWords.merge(words, uniquingKeysWith: { _, fresh in fresh })
                        alertInbox()
                        connection = .live
                        showingKept = false
                        wait = 1
                        Self.ask()
                        checks.look(runner)
                        register(runner)
                        let conversationsData = try? await conversationsAnswer
                        let history = await historyAnswer
                        let tetrix = await tetrixAnswer
                        let routines = await routinesAnswer
                        await gitHubRead
                        try Task.checkCancellation()
                        if let routines { self.routines = routines ?? [] }
                        // The launch build hides Runner share (`Launch`): with no Macs and no shares, Run on
                        // another Mac, Shared with you and Use X's share hide themselves.
                        if Launch.everything {
                            macs = (try? await runner.macs()) ?? []
                            shares = (try? await runner.sharedWithMe())?.shares ?? []
                            macsTask?.cancel()
                            macsTask = Task { [weak self] in
                                while !Task.isCancelled {
                                    try? await Task.sleep(for: .seconds(60))
                                    guard let self, let list = try? await runner.macs() else { continue }
                                    self.macs = list
                                    if let shared = try? await runner.sharedWithMe() { self.shares = shared.shares }
                                }
                            }
                        }
                        self.tetrix = tetrix
                        #if DEBUG
                        if let sample = GitHubWork.sample { gitHubWork = sample }
                        #endif
                        if let (past, pastWords) = history {
                            inboxHistory = past.filter { !$0.isOpen }
                            inboxWords = pastWords.merging(words, uniquingKeysWith: { _, fresh in fresh })
                        }
                        if let conversationsData, let parsed = try? Runner.conversations(conversationsData) {
                            conversations.take(parsed)
                        }
                        // A failed conversation read keeps the last saved list. Writing nil here would drop it.
                        if !local || conversationsData != nil {
                            keep(Kept(url: url ?? "", jobs: jobsData, inbox: inboxData, conversations: conversationsData))
                        }
                        await conversation.reload()
                        if let liveSession { Task { await liveSession.catchUp() } }
                    case .job(let job, let extras): apply(job, extras: extras)
                    case .jobDeleted(let id): gone(id, 404)
                    case .cleared(let date): clearedAt = date
                    case .inbox(let item, let words):
                        apply(item, words: words)
                    case .accounts(let list): accounts = list
                    case .check(let check): if check.state == .queued { checks.look(runner) }
                    case .tetrix(let status): tetrix = status
                    case .watchNotice(let notice): take(notice)
                    case .slack(let status): slack = status
                    case .sentry(let status): sentry = status
                    case .watch(let status): watch = status
                    case .cleanup(let measured): cleanup = measured
                    // obid names each turn's, step's and word's conversation: the window shows one (#493).
                    case .turn(let turn, let extras):
                        if conversations.shows(turn.conversation) { conversation.apply(turn, extras) }
                        settleEchoes(turn)
                        heard(turn, extras)
                    case .step(let step): if conversations.shows(step.conversation) { conversation.apply(step) }
                    case .delta(let delta): if conversations.shows(delta.conversation) { conversation.apply(delta) }
                    case .artifact(let artifact): conversation.apply(artifact)
                    case .github(let work): apply(work)
                    case .conversation(let change): conversations.apply(change)
                    case .routine:
                        routineChanges += 1
                        Task { if let routines = try? await runner.routines() { self.routines = routines ?? [] } }
                    case .transcript(let event): liveSession?.apply(event)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                if local, let denied = error as? RunnerError, denied.status == 401 {
                    token = LocalRunner.token(excluding: token)
                }
                if !down { Logger.feed.error("following the runner failed: \(error.localizedDescription, privacy: .public)") }
                connection = .offline(error.localizedDescription)
            }
            await pause(wait)
            wait = min(wait * 2, 30)
        }
    }

    /// Whether Oby's window is on screen (ObyApp): then a dropped runner is tried again within
    /// `openWindowWait`, however long the wait has grown.
    @ObservationIgnored var windowOpen: () -> Bool = { false }
    static let openWindowWait = 5.0

    /// Waits `seconds` before the next try, in steps of at most `most` (`openWindowWait`), and
    /// stops after a step once the window is open. With it closed that's a wake every 5 seconds
    /// while the runner is down, nothing while it's up.
    func pause(_ seconds: Double, steps most: Double = openWindowWait) async {
        var left = seconds
        repeat {
            let step = min(left, most)
            try? await Task.sleep(for: .seconds(step))
            left -= step
        } while left > 0 && !Task.isCancelled && !windowOpen()
    }

    // MARK: Kept for the next launch

    /// The runner's last answers for its jobs, inbox and conversations, as they came. Oby shows them
    /// at launch while the runner starts or the connection comes up, and the first connection
    /// replaces them. Only for the runner they came from (`url`), and gone once another is
    /// followed. obid took secrets out of them before they left it. The file is the user's alone
    /// (0600, in a 0700 folder), in Caches, so it's never backed up.
    struct Kept: Codable, Equatable {
        var url: String
        var jobs: Data
        var inbox: Data?
        var conversations: Data?
    }

    /// `~/Library/Caches/Oby/runner-feed.json`.
    static var keptURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Oby", directoryHint: .isDirectory).appending(path: "runner-feed.json")
    }

    /// Where `keep` writes: `keptURL`, or, while Oby hosts tests, a temporary file of this feed's
    /// own, so no test ever reads or deletes the user's.
    @ObservationIgnored var keptFile = NSClassFromString("XCTestCase") == nil ? RunnerFeed.keptURL
        : FileManager.default.temporaryDirectory.appending(path: "RunnerFeed-\(UUID().uuidString)").appending(path: "runner-feed.json")

    /// The window shows what was kept, not what the runner says now: actions wait (`acting`).
    private(set) var showingKept = false

    nonisolated static let reconnecting = "Still reconnecting to the runner: try again in a moment."

    /// Writes `kept` for the next launch, on the main actor, so a later connection's answers always
    /// land after an earlier one's.
    func keep(_ kept: Kept) {
        do {
            let folder = keptFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try RunnerLoginItem.writePrivately(try JSONEncoder().encode(kept), to: keptFile)
        } catch {
            Logger.feed.error("keeping the runner's answers for the next launch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What `keep` saved for `url`, shown until the runner answers; whether it was. Nothing from
    /// another runner (followed since, while Oby was closed), and nothing the app can't read any
    /// more (an older or newer shape): that file goes.
    func showKept(for url: String) -> Bool {
        guard let data = try? Data(contentsOf: keptFile) else { return false }
        guard let kept = try? JSONDecoder().decode(Kept.self, from: data), kept.url == url,
              let (list, extras) = try? Runner.jobsWithExtras(kept.jobs) else {
            try? FileManager.default.removeItem(at: keptFile)
            return false
        }
        jobs = list
        self.extras = extras
        if let (items, words) = try? kept.inbox.map(Runner.inboxWithWords) {
            inbox = items
            inboxWords = words
        }
        if local, let list = try? kept.conversations.map(Runner.conversations) { conversations.take(list) }
        showingKept = true
        return true
    }

    /// The runner, for an action on a job or an inbox item the window shows; refused while those
    /// are what was kept, which may be long out of date (a plan approved by voice could reach a job
    /// that finished meanwhile, and start a follow-up).
    /// `missing` is what the caller says when no runner is set, as it did before the gate.
    func acting(_ missing: String = "Set the runner's URL in Settings first.") throws -> Runner {
        try Self.acting(runner, showingKept: showingKept, missing: missing)
    }

    /// `acting`'s rule: no runner says `missing`, then kept answers say `reconnecting`.
    nonisolated static func acting(_ runner: Runner?, showingKept: Bool, missing: String) throws -> Runner {
        guard let runner else { throw RunnerError(message: missing) }
        if showingKept { throw RunnerError(message: reconnecting) }
        return runner
    }

    /// Registers this Mac's publishing key, as the iPhone does on each connection. A runner whose
    /// pairing is closed answers 403: Settings › Runner shows its line, with Try again. The runner
    /// on this Mac keeps its files under this user, so Oby opens its pairing itself first
    /// (`touch $OBY_HOME/pairing`, Runner/Devices.swift).
    func register(_ runner: Runner? = nil) {
        guard let runner = runner ?? self.runner else { return }
        if local {
            let pairing = LocalRunner.home.appending(path: "pairing")
            try? FileManager.default.createDirectory(at: LocalRunner.home, withIntermediateDirectories: true)
            if !FileManager.default.createFile(atPath: pairing.path, contents: Data()) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: pairing.path)
            }
        }
        Task {
            do { try await device.register(with: runner) } catch {
                Logger.feed.error("registering this Mac failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Planning through the runner on this Mac (#283)

    /// Words this Mac sent to obid that its thread doesn't list yet (the iPhone's echoes): in the
    /// thread the instant Send is pressed, Oby's Thinking under them, until obid's own turn with
    /// the same words takes their place in the same update (`ChatThread.pending`), so nothing
    /// shows twice. `problem`: why they didn't reach obid, with Try again and Edit.
    struct Echo: Equatable {
        var turn: Turn
        /// The conversation shown when they went, nil for a new one.
        var conversation: String?
        var problem: String?
        /// `plan` sends them: an echo made at Send waits for it (`echo`).
        var sending = false
    }
    private(set) var echoes: [Echo] = []

    /// The echoes the conversation shown lists: its own, and a new one's while it starts. One that
    /// failed gives way only to obid's turn of its id (they reached obid after all).
    var shownEchoes: [Turn] {
        let mine = echoes.filter { $0.conversation == conversations.shown || ($0.conversation == nil && (conversations.shown == nil || conversations.creating)) }
        return mine.filter { echo in
            !conversation.runnerTurns.contains { echo.problem == nil ? ChatThread.lists($0, echo.turn) : $0.id == echo.turn.id }
        }.map(\.turn)
    }

    func echoProblem(_ id: String) -> String? { echoes.first { $0.turn.id == id }?.problem }

    /// Lets go of an echo: listed by obid, given up or edited.
    func dropEcho(_ id: String) { echoes.removeAll { $0.turn.id == id } }

    /// Try again on words that didn't reach obid: the same echo goes again, with its id, so obid
    /// keeps them once even if the first request did reach it (`Runner.planned`'s `id`).
    func retryEcho(_ id: String) {
        guard let at = echoes.firstIndex(where: { $0.turn.id == id }) else { return }
        echoes[at].problem = nil
        echoes[at].sending = false
    }

    /// The runner listed the user's `turn`: the echo it lists has done its job (obid's: the one of
    /// its id; a failed one only so, never by its words).
    func settleEchoes(_ turn: Turn) {
        echoes.removeAll { $0.turn.id == turn.id || ($0.problem == nil && $0.conversation == turn.conversation && ChatThread.lists(turn, $0.turn)) }
    }

    /// Send was pressed: the words show now. `Desk.ask` may first wait for the turn they replace to
    /// let go, and `plan` then takes this echo up. Words that only stop a turn never plan.
    func echo(_ said: String) {
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !Conversation.cancels(said) else { return }
        echoes.append(Echo(turn: Turn(who: .user, text: said), conversation: conversations.shown))
    }

    /// The runner's brain's answer to the user's words, as the window's cards
    /// show it (`Desk.planElsewhere`): the drafts are its, and Dispatch sends them back to it.
    /// `conversation`: where words from an alert go (#863); nil for the window's. Tests give their own `runner`.
    func plan(_ said: String, answer: (question: String, option: String)?, attachments: [String] = [], in conversation: String? = nil,
              on given: Runner? = nil) async throws -> Desk.Talk {
        guard let runner = given ?? runner else { throw RunnerError(message: "The runner on this Mac isn't running yet.") }
        // Shown at once (or since Send), as obid will list them: an answer is its option.
        let text = answer?.option ?? said
        let echo: String
        if let made = echoes.firstIndex(where: { !$0.sending && $0.problem == nil && $0.turn.text == text }) {
            echoes[made].sending = true
            echo = echoes[made].turn.id
        } else {
            let made = Echo(turn: Turn(who: .user, text: text), conversation: conversation ?? conversations.shown, sending: true)
            echoes.append(made)
            echo = made.turn.id
        }
        // In the conversation shown, or a new one (obid keeps many, #493); neither for one thread.
        let planned: PlannedTurn
        do {
            // The message box's "Run on another Mac" is for its own words, not an alert's.
            let runsOn = conversation == nil ? runsOnNext : nil
            if conversation == nil { runsOnNext = nil }
            let target = conversation.map(PlanTarget.conversation) ?? conversations.target(said)
            planned = try await runner.planned(said, answer: answer, attachments: attachments, in: target, id: echo, runsOn: runsOn)
        } catch {
            // An alert's words went to a conversation of their own: the window's new one isn't theirs.
            if conversation == nil { conversations.failed() }
            // Given up (Stop, or other words in their place): they leave the thread. Else they stay, failed.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { dropEcho(echo) }
            else if let at = echoes.firstIndex(where: { $0.turn.id == echo }) { echoes[at].problem = error.localizedDescription }
            throw error
        }
        // obid listed them before it answered: whatever its event missed, they're its now.
        dropEcho(echo)
        if conversation == nil { await conversations.joined(planned.conversation) }
        switch planned.result {
        case .question(let said, let question):
            let asked = Plan.Question(text: question.text, options: question.options, details: question.details,
                                      recommended: question.recommended, plan: question.plan)
            if let at = planned.conversation { noteQuestion(asked, said: said, in: at) }
            return .question(said: said, asked)
        case .reply(let text, let started):
            for job in started { apply(job) }
            return .reply(text)
        case .none: return .none
        }
    }

    /// Words to Oby in `conversation` from an alert's Reply or a question's option (#863), as its box
    /// sends them; the window stays where it is.
    func say(_ words: String, in conversation: String) async throws {
        _ = try await plan(words, answer: nil, in: conversation)
    }

    /// Cancels a plan still running on the local runner (tests give their own `runner`).
    func cancelPlan(on given: Runner? = nil) async {
        // The conversation shown's (#493): obid otherwise cancels the latest plan in any of them.
        await (given ?? runner)?.cancelPlan(conversations.shown)
    }

    /// The runner's exact sentence for publishing a job: Publish shows it, and Touch ID approves it.
    func publishAction(_ id: String) async throws -> String {
        let runner = try acting("Set the runner's URL in Settings to publish it.")
        return try await runner.publishAction(id)
    }

    /// Publishes a runner's job with that sentence, after Touch ID; the runner pushes and opens the pull request.
    @discardableResult
    func publish(_ id: String, action: String) async throws -> URL {
        let runner = try acting("Set the runner's URL in Settings to publish it.")
        let url = try await device.publish(id, action: action, with: runner)
        // Its event brings the rest; until then it's published here too.
        if var job = jobs.first(where: { $0.id == id }) {
            job.published = url.absoluteString
            job.publishError = nil
            apply(job)
        }
        return url
    }

    /// Saves the model and effort the runner's jobs use (Settings › Models).
    func setModels(_ models: ModelSettings) async throws {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings first.") }
        self.models = try await runner.setModels(models)
    }

    /// Settles one of the runner's inbox items: an answer goes to its job, `done` lets it go, `later` puts it off.
    func settle(_ id: String, answer: String? = nil, done: Bool? = nil, later: Date? = nil) async throws {
        let runner = try acting("Set the runner's URL in Settings to answer it.")
        // Only the owner's tap confirms (#776): a Confirm on a confirm item is signed with Touch ID,
        // its title the reason. A cancelled Touch ID sends nothing and the card stays.
        // On the Mac a confirm item reads as Engine's `start`; its words say it's a confirm.
        if answer == "Confirm", inboxWords[id]?.confirm != nil, let item = inbox.first(where: { $0.id == id }) {
            do {
                apply(try await device.confirm(id, title: item.title, with: runner))
            } catch is ConfirmCancelled {
                return
            }
            return
        }
        apply(try await runner.settle(id, answer: answer, done: done, later: later))
    }

    /// Changes a runner job's mode (its screen's Mode menu): a permission it waits on that the new
    /// mode allows is answered.
    func setMode(_ id: String, _ mode: RunnerMode) async throws {
        let runner = try acting("Set the runner's URL in Settings to change it.")
        let job = try await runner.setMode(id, mode)
        extras[id, default: RunnerJobExtras(id: id)].mode = mode.rawValue
        apply(job)
    }

    /// Allow, Always allow or Deny on what a runner job's agent waits for; words go with a deny.
    /// `ask`: only that ask (an alert's), never a newer one the alert didn't show.
    func answer(_ id: String, _ decision: RunnerPermission.Decision, message: String? = nil, ask: String? = nil) async throws {
        let runner = try acting("Set the runner's URL in Settings to answer it.")
        guard let permission = extras[id]?.permission else {
            if ask != nil { throw RunnerError(message: "It isn't waiting for your OK any more.") }
            return
        }
        guard ask == nil || ask == permission.id else { throw RunnerError(message: "It asks something else now.") }
        let job = try await runner.answer(id, permission: permission.id, decision, message: message)
        if let index = permissionHistory.firstIndex(where: { $0.job == id && $0.permission.id == permission.id }) {
            permissionHistory[index].done = .now
            permissionHistory[index].answer = decision == .allow ? "Allowed once" : decision == .always ? "Always allowed" : "Denied"
        }
        // The job's own event brings the next one, if any.
        if extras[id]?.permission?.id == permission.id { extras[id]?.permission = nil }
        apply(job)
    }

    /// Settings › Permissions: the mode the runner's new jobs get.
    func setDefaultMode(_ mode: RunnerMode) async throws {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings first.") }
        try await runner.setDefaultMode(mode)
        defaultMode = mode
    }

    /// Whether `id` names a confirm item, open or settled.
    func isConfirm(id: String) -> Bool {
        inboxWords[id]?.confirm != nil || (inbox + inboxHistory).contains { $0.id == id && isConfirm($0) }
    }

    /// What the brain asks of the runner's jobs and inbox (`Desk.actElsewhere`), as the apps' own
    /// buttons do (#300). A confirm item (#546) is the user's own call, never the brain's, even
    /// named by id: it's refused before anything reaches the runner.
    func act(_ remote: Desk.Remote) async throws {
        switch remote {
        case .settle(let id, _), .startNow(let id):
            if isConfirm(id: id) { throw RunnerError(message: "That waits for your own Confirm in the inbox: Oby doesn't answer it for you.") }
        case .tell, .dismiss, .liftReserve: break
        }
        let runner = try acting("The runner isn't set up.")
        switch remote {
        case .settle(let item, let words): try await settle(item, answer: words)
        case .tell(let job, let words): apply(try await about(job) { try await $0.tell(job, words) })
        case .dismiss(let job): apply(try await about(job) { try await $0.dismiss(job) })
        case .startNow(let job): apply(try await about(job) { try await $0.startNow(job) })
        case .liftReserve(let account): _ = try await runner.liftReserve(account, true)
        }
    }

    /// An inbox item as the runner last said it, with its words (an `inbox` event's).
    func apply(_ item: InboxItem, words: InboxWords?) {
        if let words { inboxWords[item.id] = words }
        apply(item)
    }

    /// An inbox item as the runner last said it: one that's done leaves the list. Settled or put
    /// off, here or on any other app, its alert goes; a new ask alerts (#862).
    func apply(_ item: InboxItem) {
        inbox.removeAll { $0.id == item.id }
        if item.isOpen { inbox.append(item) }
        else {
            inboxHistory.removeAll { $0.id == item.id }
            inboxHistory.append(item)
        }
        if !item.waiting() { withdraw([item.id]) }
        alertInbox()
    }

    /// The runner's answer to Stop or a message, or one of its events: the job with that id.
    /// A `job` event: what obid adds to the job (its decision, conversation, turn…), then the job.
    func apply(_ job: Job, extras: RunnerJobExtras?) {
        if let extras { self.extras[job.id] = extras }
        apply(job)
    }

    func apply(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        noticeChanges()
    }

    /// Why Stop didn't go through, shown by the Stop button; nil once it did.
    private(set) var stopProblem: String?

    /// Stop: the runner ends the turn Oby is working on (`POST /v1/conversation/stop`, #304), and
    /// the steps that ran show as ended.
    func stopTurn(on given: Runner? = nil) async {
        guard let runner = given ?? runner else {
            stopProblem = "Set the runner's URL in Settings first."
            return
        }
        do {
            // The conversation shown's turn (#493), as the iPhone's Stop does.
            try await runner.stopConversation(conversations.shown)
            stopProblem = nil
            conversation.settleSteps()
        } catch let error as RunnerError where error.status == 404 {
            stopProblem = "This runner can't stop a turn yet."
        } catch {
            stopProblem = error.localizedDescription
        }
    }

    /// Asks the runner something about its job `id` (stop, dismiss, a message, a move): when it
    /// answers 404, it has no such job, and the job leaves the lists here, its alert too (#223).
    func about<T>(_ id: String, _ call: (Runner) async throws -> T) async throws -> T {
        let runner = try acting()
        do {
            return try await call(runner)
        } catch let error as RunnerError {
            gone(id, error.status)
            throw error
        }
    }

    /// Rename, Archive task and Delete task (Sangam's TaskMenu), on obid's jobs: each answers
    /// at once here, and every other app hears it as the job's event.
    func rename(_ id: String, to title: String) async throws {
        apply(try await about(id) { try await $0.rename(id, to: title) })
    }

    func archive(_ id: String, _ archived: Bool = true) async throws {
        let job = try await about(id) { try await $0.archive(id, archived) }
        extras[id, default: RunnerJobExtras(id: id)].archived = archived ? .now : nil
        apply(job)
    }

    func delete(_ id: String) async throws {
        try await about(id) { try await $0.deleteJob(id) }
        gone(id, 404)
    }

    /// The runner answered `status` about the job `id`: on a 404 the job goes from here.
    private func gone(_ id: String, _ status: Int?) {
        guard status == 404 else { return }
        jobs = JobList.answered(status, about: id, in: jobs, id: \.id)
        extras[id] = nil
        onScreen.remove(id)
        notified?[id] = nil
        withdraw([id])
    }

    /// A job's screen opened or closed in the window: while it's open, new lists keep its job.
    func showing(_ id: String, _ shown: Bool) {
        if shown { onScreen.insert(id) } else { onScreen.remove(id) }
    }

    /// A job older than the list's 50 (an inbox item or an alert opened it): fetched, and kept
    /// among the others in age order.
    func fetch(_ id: String, from runner: Runner? = nil) async throws {
        guard !jobs.contains(where: { $0.id == id }) else { return }
        guard let runner = runner ?? self.runner else { throw RunnerError(message: "Set the runner's URL in Settings to open it.") }
        let asked = runnerChanges
        let job: Job, more: RunnerJobExtras?
        do { (job, more) = try await runner.jobWithExtras(id) } catch let error as RunnerError {
            if runnerChanges == asked { gone(id, error.status) }
            throw error
        }
        // Settings › Runner changed while it was on its way: it's the other runner's job.
        guard runnerChanges == asked, !jobs.contains(where: { $0.id == id }) else { return }
        jobs = JobList.placed(job, in: jobs, id: \.id, created: \.created)
        if let more { extras[id] = more }
        noticeChanges()
    }

    /// The whole list, the latest 50, on every (re)connection: what changed while the connection
    /// was down alerts now. A job whose screen is open stays, fetched again so it's current.
    private func take(_ fresh: [Job], from runner: Runner) async {
        let (list, refetch) = JobList.keeping(fresh, old: jobs, onScreen: onScreen, id: \.id, created: \.created)
        jobs = list
        let asked = runnerChanges
        for id in refetch {
            let fetched: (Job, RunnerJobExtras?)?
            do { fetched = try await runner.jobWithExtras(id) } catch { fetched = nil; if runnerChanges == asked { gone(id, (error as? RunnerError)?.status) } }
            // Settings › Runner changed meanwhile: these are the other runner's.
            guard runnerChanges == asked, !Task.isCancelled else { return }
            if let (job, more) = fetched {
                jobs = JobList.placed(job, in: jobs, id: \.id, created: \.created)
                if let more { extras[id] = more }
            }
        }
        noticeChanges()
        // Alerts left in Notification Center, from before a drop or a restart, whose job needs nothing now.
        let gone = jobs.filter { Self.notice(for: $0, routine: extras[$0.id]?.routine != nil) == nil }.map(\.id)
        if !gone.isEmpty { withdraw(gone) }
    }

    // ponytail: Swift 6.4 (swiftlang-6.4.0.34.1) crashes in SIL CopyPropagation compiling this
    // function optimized, so Release archives fail; Debug never runs the pass. Remove this once a
    // newer Xcode archives without it.
    @_optimize(none)
    private func noticeChanges() {
        let (changes, now) = Self.notices(jobs, after: notified ?? [:], routines: Set(extras.filter { $0.value.routine != nil }.keys))
        var kept = now
        defer { notified = kept }
        guard let before = notified else {
            // What the jobs already need when Oby starts isn't news, and the jobs done by then have ended.
            tellDone(changes.filter { $0.1 == .done }.map(\.0.id))
            return
        }
        for (job, notice) in changes {
            let step = Self.step(notice, before: before[job.id], active: job.isActive, toldDone: doneTold.contains(job.id))
            if notice == .done { tellDone([job.id]) }
            switch step {
            case .keep: continue
            // Published, from the iPhone or by the runner, dismissed, or running again: its alert goes.
            case .clear: withdraw([job.id])
            case .post:
                guard let notice else { continue }
                // On screen: nothing. What needs the owner alerts once the window goes (`windowLeft`).
                let conversation = extras[job.id]?.conversation
                if windowShows(.job(job.id)) || conversation.map({ windowShows(.conversation($0)) }) == true {
                    if notice != .done { kept[job.id] = nil }
                    continue
                }
                show(Alerts.alert(notice, for: job, conversation: conversation))
                onNotice(job, notice)
            }
        }
    }

    /// What a job's alert does when what it needs changes (`notices`).
    nonisolated enum NoticeStep: Equatable, Sendable { case post, clear, keep }

    /// Done alerts once per job, ever (`toldDone`): a round Oby runs by itself after it (a review, a
    /// rebase, a Mac check) keeps it, and ending again says nothing. A job that leaves Ready to publish,
    /// Changes requested or Not merged for done (published, reviewed or merged elsewhere) only loses
    /// that alert. Anything else that needs the owner alerts each time it changes; nothing needed: gone.
    nonisolated static func step(_ notice: Notice?, before: String?, active: Bool, toldDone: Bool) -> NoticeStep {
        let done = Notice.done.rawValue
        switch notice {
        case nil: return before == done && active ? .keep : .clear
        case .done?:
            let leaves = before.map { [Notice.ready, .review, .merge].map(\.rawValue).contains($0) } ?? false
            if !leaves, !toldDone { return .post }
            return before == nil || before == done ? .keep : .clear
        default: return .post
        }
    }

    /// The jobs whose end alerted (or ended before Oby started, or while the window showed them), the
    /// latest 500, kept across launches.
    // ponytail: the app's defaults; a few days of jobs at most, older ones are long settled.
    @ObservationIgnored private lazy var doneTold = Set(doneDefaults.stringArray(forKey: Self.doneKey) ?? [])
    /// Where they're kept: the app's defaults, or a test's.
    @ObservationIgnored var doneDefaults = UserDefaults.standard
    static let doneKey = "alertedDone"

    private func tellDone(_ ids: [String]) {
        let new = ids.filter { !doneTold.contains($0) }
        guard !new.isEmpty else { return }
        doneTold.formUnion(new)
        let kept = (doneDefaults.stringArray(forKey: Self.doneKey) ?? []) + new
        doneDefaults.set(Array(kept.suffix(500)), forKey: Self.doneKey)
    }

    // MARK: Notices, as the runner decides them (Runner/Push.swift)

    /// Nothing for a job the user dismissed: its alert clears. Done only for a job the owner started:
    /// not Oby's own review, nor a routine's run (`routine`), whose failure still alerts.
    static func notice(for job: Job, routine: Bool = false) -> Notice? {
        if job.waitsForPermission { return .permission }
        if job.waitsForAnswer { return .question }
        guard job.needsYou else {
            return job.status == .done && job.dismissed == nil && job.reviewOf == nil && !routine ? .done : nil
        }
        if job.canPublish { return .ready }
        if job.reviewNeedsYou { return .review }
        if job.mergeNeedsYou { return .merge }
        switch job.status {
        case .failed: return .failed
        case .interrupted: return .interrupted
        default: return nil
        }
    }

    /// What each job needs now, against what its alert last said: the jobs whose alert changes
    /// (nil: clear it), and what to remember. Jobs no longer listed are forgotten.
    /// Remembered per job: the notice, and for an OK the ask's own id, so each new ask alerts.
    static func notices(_ jobs: [Job], after notified: [String: String], routines: Set<String> = []) -> (changes: [(Job, Notice?)], notified: [String: String]) {
        var changes: [(Job, Notice?)] = []
        var now: [String: String] = [:]
        for job in jobs {
            let notice = Self.notice(for: job, routine: routines.contains(job.id))
            let said = notice.map { Self.said($0, for: job) }
            now[job.id] = said
            if said != notified[job.id] { changes.append((job, notice)) }
        }
        return (changes, now)
    }

    /// What a job's alert says, as `notices` remembers it: the notice, and for an OK its ask's id.
    static func said(_ notice: Notice, for job: Job) -> String {
        notice == .permission ? "permission:\(job.permission?.id ?? "")" : notice.rawValue
    }

    /// What the job's alert would say now, or nil when it needs nothing.
    func said(_ id: String) -> String? {
        jobs.first { $0.id == id }.flatMap { job in
            Self.notice(for: job, routine: extras[id]?.routine != nil).map { Self.said($0, for: job) }
        }
    }

    /// "Couldn't publish: Fix oby #42", as the iPhone's alert says it. A ready job whose publish
    /// didn't say why is just ready to publish.
    static func title(_ notice: Notice, for job: Job) -> String {
        switch notice {
        case .ready: "\(job.publishError == nil ? "Ready to publish" : "Couldn't publish"): \(job.heading)"
        case .failed: "Failed: \(job.heading)"
        case .interrupted: "Needs you: \(job.heading)"
        case .review: "Changes requested: \(job.heading)"
        case .question: "Question: \(job.heading)"
        case .merge: "Not merged: \(job.heading)"
        case .permission: "Needs your OK: \(job.heading)"
        case .done: "Done: \(job.heading)"
        }
    }

    /// Why its own publish failed when that's what it needs, why Oby's review stopped, or the summary's first line.
    static func body(_ notice: Notice, for job: Job) -> String {
        let line = job.summary.split(separator: "\n").first.map(String.init)
        if notice == .ready { return job.publishError ?? line ?? "Done" }
        if notice == .review { return job.review?.stopReason ?? Review.stopLine }
        if notice == .question, let question = job.question { return question.text }
        if notice == .permission, let permission = job.permission { return permission.title }
        if notice == .merge { return job.mergeError ?? job.macCheck.map { $0.problem ?? $0.failureLine + (job.checkStop.map { " " + $0 } ?? "") } ?? "Not merged" }
        if notice == .interrupted, let reason = job.reason { return reason }
        return line ?? job.status.rawValue.capitalized
    }

    // MARK: Alerts

    /// The `job` key holds the job's id, as on the iPhone; the request's identifier is the id too,
    /// so a newer notice replaces the older one.
    static let jobKey = "job"

    /// The "ready" alert's Publish: the window opens on the job, shows the runner's sentence, and asks for Touch ID.
    static let publishButton = "publish"
    /// The "permission" alert's answers, and the key holding the ask it answers.
    static let allowButton = "allow"
    static let denyButton = "deny"
    static let permissionKey = "permission"

    /// Each alert's buttons, registered the first time an alert has them (`Alerts`), by category id.
    // ponytail: kept until Oby quits, a few per agent and one per question's options; trim the oldest if questions pile up.
    private static var categories: [String: UNNotificationCategory] = [:]

    /// The categories registered so far: the delivered alerts' buttons keep working (at launch, none
    /// yet, and an alert from before still opens its page).
    static func registerCategories() {
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
    }

    /// macOS's category for `category`: its buttons, Reply before Open. Only Open and Publish (which
    /// asks for Touch ID in the window) bring the window up; every answer needs the Mac unlocked.
    static func notificationCategory(_ category: Alert.Category) -> UNNotificationCategory {
        var actions = category.buttons.map { button -> UNNotificationAction in
            var options: UNNotificationActionOptions = button.opens ? [.foreground] : [.authenticationRequired]
            if button.destructive { options.insert(.destructive) }
            return UNNotificationAction(identifier: button.id, title: button.title, options: options)
        }
        if let reply = category.reply {
            let field = UNTextInputNotificationAction(identifier: Alerts.replyButton, title: "Reply", options: [.authenticationRequired],
                                                      textInputButtonTitle: "Send", textInputPlaceholder: reply)
            actions.insert(field, at: category.buttons.last == Alerts.openButton ? actions.count - 1 : actions.count)
        }
        return UNNotificationCategory(identifier: category.id, actions: actions, intentIdentifiers: [])
    }

    /// Shows `alert`, replacing the one with its id.
    static func post(_ alert: Alert) {
        let center = UNUserNotificationCenter.current()
        if categories[alert.category.id] == nil {
            categories[alert.category.id] = notificationCategory(alert.category)
            registerCategories()
        }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        if alert.sound { content.sound = .default }
        content.categoryIdentifier = alert.category.id
        content.threadIdentifier = alert.thread
        var info: [String: Any] = alert.info
        if !alert.options.isEmpty { info[Alerts.optionsKey] = alert.options }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        Task {
            do { try await center.add(request) } catch {
                Logger.feed.error("posting an alert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The first connection to a runner asks whether Oby may notify; after that it doesn't ask again.
    private static func ask() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Logger.feed.error("asking to notify failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// What alerted already (the watcher's notices, inbox asks, Oby's answers), so a reconnect's
    /// replay doesn't alert again.
    @ObservationIgnored private var told: Set<String> = []

    /// A `watch` or `listen` item as the runner last said it: its card while it waits, and a
    /// notification when it's new. Settled, its card and notification go.
    func take(_ notice: WatchNotice) {
        notices.removeAll { $0.id == notice.id }
        if notice.done == nil { notices.append(notice) }
        if notice.done != nil || !notice.waiting() || !notice.needsYou {
            withdraw([notice.id])
        }
        tell(notice)
    }

    /// The notices that were open and aren't any more: settled elsewhere while the Mac was away.
    nonisolated static func settledWhileAway(before: [WatchNotice], after: [WatchNotice]) -> [String] {
        let open = Set(after.map(\.id))
        return before.map(\.id).filter { !open.contains($0) }
    }

    /// Answers a `watch` or `listen` item (Dismiss, Approve) or puts it off.
    func settle(notice id: String, answer: String? = nil, later: Date? = nil) async throws {
        let runner = try acting("Set the runner's URL in Settings to answer it.")
        take(try await runner.settle(notice: id, answer: answer, later: later))
    }

    /// A notification with obid's own words (who, where), never what was written, for a notice
    /// that `WatchNotice.shows` (new, open, recent).
    private func tell(_ notice: WatchNotice) {
        guard WatchNotice.shows(notice, told: told) else { return }
        told.insert(notice.id)
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.text
        content.sound = .default
        content.threadIdentifier = "watch"
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        Task {
            do { try await UNUserNotificationCenter.current().add(request) } catch {
                Logger.feed.error("posting a watcher notice failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: What needs the owner away from the window (#862)

    /// Whether the window is in front on that page now (the app sets it): nothing alerts for what it shows.
    @ObservationIgnored var windowShows: (AlertPlace) -> Bool = { _ in false }
    /// Shows an alert, takes alerts away, and lists the delivered alerts of inbox items: Notification
    /// Center's, or a test's.
    @ObservationIgnored var show: (Alert) -> Void = { RunnerFeed.post($0) }
    @ObservationIgnored var withdraw: ([String]) -> Void = { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) }
    @ObservationIgnored var deliveredInbox: () async -> [(id: String, item: String)] = {
        await UNUserNotificationCenter.current().deliveredNotifications().compactMap { delivered in
            (delivered.request.content.userInfo[Alerts.inboxKey] as? String).map { (id: delivered.request.identifier, item: $0) }
        }
    }
    /// When an inbox ask of each conversation (its own, or one of its jobs') last alerted.
    @ObservationIgnored private var askedAt: [String: Date] = [:]
    /// The first inbox list from this runner is in: what waited before isn't news.
    @ObservationIgnored private var inboxListed = false
    /// Oby's questions to this Mac's words, by conversation, until their turn's alert takes them.
    @ObservationIgnored private var asked: [String: (said: String, question: Plan.Question, at: Date)] = [:]
    /// Each conversation's last answer that alerted, for a question that comes after its turn.
    @ObservationIgnored private var answered: [String: (turn: Turn, at: Date)] = [:]

    /// An alert for each inbox ask that waits for the owner and isn't told yet (`Alerts.alerts`). One
    /// the window shows stays untold, and alerts once the window goes (`windowLeft`).
    private func alertInbox() {
        guard inboxListed else { return }
        let asking = Set(jobs.filter { Self.notice(for: $0) == .question }.map(\.id))
        for item in inbox {
            let kind = kind(of: item)
            guard Alerts.alerts(item, kind: kind, jobAlerts: asking.contains(item.job), told: told, now: .now) else { continue }
            let conversation = inboxWords[item.id]?.conversation
            let place = Alerts.place(of: item, conversation: conversation)
            guard !windowShows(place) else { continue }
            told.insert(item.id)
            show(Alerts.alert(for: item, kind: kind, conversation: conversation))
            // One thing, one alert: Oby's words beside the ask ("It waits for your Start") give way to it.
            let about: String? = switch place {
            case .conversation(let id): id
            case .job(let id): extras[id]?.conversation
            default: nil
            }
            if let about {
                askedAt[about] = .now
                if let (_, at) = answered[about], at > .now.addingTimeInterval(-60) {
                    answered[about] = nil
                    withdraw([Alerts.answerID(about)])
                }
            }
        }
    }

    /// A turn of any conversation. The owner's words, from any app, settle the alert of Oby's answer
    /// there; Oby's answer alerts unless the window shows that conversation.
    func heard(_ turn: Turn, _ extras: TurnExtras) {
        guard let conversation = turn.conversation else { return }
        if let settled = Alerts.settled(by: turn) {
            asked[conversation] = nil
            answered[conversation] = nil
            withdraw([settled])
            return
        }
        let known = conversations.items.contains { $0.id == conversation }
        guard Alerts.answers(turn, extras: extras, known: known, told: told, asked: askedAt[conversation], now: .now) else { return }
        told.insert(turn.id)
        let question = asked.removeValue(forKey: conversation).flatMap { $0.at > .now.addingTimeInterval(-60) ? ($0.said, $0.question) : nil }
        guard !windowShows(.conversation(conversation)) else { return }
        answered[conversation] = (turn, .now)
        show(Alerts.answer(turn.text, in: conversation, title: title(of: conversation), question: question))
    }

    /// Oby asked something back about this Mac's words: its answer's alert gets the options, at once
    /// when the turn came first (quietly, replacing it), else when it comes.
    private func noteQuestion(_ question: Plan.Question, said: String, in conversation: String) {
        guard !windowShows(.conversation(conversation)) else { return }
        guard let (turn, at) = answered[conversation], at > .now.addingTimeInterval(-60) else {
            asked[conversation] = (said, question, .now)
            return
        }
        answered[conversation] = nil
        var alert = Alerts.answer(turn.text, in: conversation, title: title(of: conversation), question: (said, question))
        alert.sound = false
        show(alert)
    }

    private func title(of conversation: String) -> String {
        conversations.items.first { $0.id == conversation }?.title ?? ConversationList.newTitle
    }

    /// The window closed, went to the Dock, or Oby went behind another app: what needs the owner
    /// and waited while the window showed it alerts now.
    func windowLeft() {
        noticeChanges()
        alertInbox()
    }

    /// The window shows `place`: the alerts for what's there go (the job's; Oby's answer and the asks
    /// in a conversation).
    func seen(_ place: AlertPlace) {
        let ids: [String] = switch place {
        case .job(let id), .localJob(let id): [id]
        case .conversation(let id):
            [Alerts.answerID(id)] + inbox.filter { Alerts.place(of: $0, conversation: inboxWords[$0.id]?.conversation) == place }.map(\.id)
        case .window: []
        }
        if !ids.isEmpty { withdraw(ids) }
    }
}

extension Logger {
    nonisolated static let feed = Logger(subsystem: "com.deskree.oby", category: "runner")
}
