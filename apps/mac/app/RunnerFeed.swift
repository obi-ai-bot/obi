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
    var briefingInbox: [InboxItem] { inbox.filter { !isConfirm($0) } }
    /// The runner's accounts and their usage, as it last said: the brain tells them too.
    private(set) var accounts: [AccountState] = []
    /// What each job carries that Engine's Job doesn't read yet (its mode, the permission it waits
    /// on, its question's recommended option and plan), by job id.
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
    private(set) var connection = RunnerConnection.connecting
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
    /// The GitHub items put off with Later, until Oby quits.
    var gitHubLater: Set<String> = []

    /// obid's GitHub work, as the `github` event or a refresh brings it: the whole feed.
    func apply(_ work: GitHubWork) { gitHubWork = work }

    /// Has obid read GitHub again (opening Review PR or Issues); the feed it answers replaces this one.
    func refreshGitHubWork() async {
        guard gitHubWork != nil, let runner else { return }
        #if DEBUG
        if GitHubWork.sample != nil { return }
        #endif
        if let work = try? await runner.refreshGitHubWork() { apply(work) }
    }

    /// One click on a GitHub item: Oby's job on it, which joins the list as the runner's job.
    func startGitHubWork(_ id: String) async throws {
        guard let runner else { throw RunnerError(message: "Oby isn't following a runner.") }
        apply(try await runner.startGitHubWork(id))
    }
    /// Merge checks this Mac runs for the runner (Settings › Runner, on by default).
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
        if changed { forget() }
        self.url = url
        self.local = local
        token = nil
        if changed { onFollow(local) }
        connection = .connecting
        loop?.cancel()
        loop = nil
        guard local || Self.runner(url) != nil else { return }
        loop = Task {
            if !first { try? await Task.sleep(for: .seconds(1)) }
            await run()
        }
    }

    /// Another runner: nothing the last one said holds, and what's still on its way from it is dropped.
    func forget() {
        runnerChanges += 1
        jobs = []
        inbox = []
        inboxHistory = []
        inboxWords = [:]
        accounts = []
        models = nil
        extras = [:]
        permissionHistory = []
        defaultMode = nil
        host = nil
        version = nil
        github = nil
        checkRuns = nil
        clearedAt = nil
        notified = nil
        conversation.forget()
        conversations.reset()
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
                        // Status every time: a Clear done while the connection was down is in it.
                        let status = try await runner.status()
                        let (list, extras) = try await runner.jobsWithExtras()
                        let (items, words) = try await runner.inboxWithWords()
                        // History is an enhancement: an older runner or failed history request must not take chat offline.
                        let history = try? await runner.inboxWithWords(state: "done")
                        // Settings › Runner changed, or the Mac woke, while these were on their way.
                        try Task.checkCancellation()
                        host = status.runner.host
                        version = status.runner.version
                        clearedAt = status.clearedAt
                        accounts = status.accounts
                        models = status.models
                        cleanup = status.cleanup
                        github = status.github
                        checkRuns = status.checks
                        gitHubWork = try? await runner.gitHubWork()
                        #if DEBUG
                        if let sample = GitHubWork.sample { gitHubWork = sample }
                        #endif
                        defaultMode = RunnerMode(status.permissions?.mode)
                        self.extras = extras
                        await take(list, from: runner)
                        // Settings › Runner changed while the open jobs were fetched again.
                        try Task.checkCancellation()
                        inbox = items
                        if let (past, pastWords) = history {
                            inboxHistory = past.filter { !$0.isOpen }
                            inboxWords = pastWords.merging(words, uniquingKeysWith: { _, fresh in fresh })
                        } else { inboxWords.merge(words, uniquingKeysWith: { _, fresh in fresh }) }
                        // obid's conversations before the thread, which reads the one shown.
                        try await conversations.load(from: runner, planning: local)
                        // The thread's latest page every time too: what was said from the iPhone
                        // while the connection was down is in it.
                        await conversation.reload()
                        try Task.checkCancellation()
                        connection = .live
                        wait = 1
                        Self.ask()
                        checks.look(runner)
                        register(runner)
                    case .job(let job, let extras):
                        if let extras { self.extras[job.id] = extras }
                        apply(job)
                    case .cleared(let date): clearedAt = date
                    case .inbox(let item, let words):
                        apply(item, words: words)
                    case .accounts(let list): accounts = list
                    case .check(let check): if check.state == .queued { checks.look(runner) }
                    // obid names each turn's, step's and word's conversation: the window shows one (#493).
                    case .turn(let turn, let extras): if conversations.shows(turn.conversation) { conversation.apply(turn, extras) }
                    case .step(let step): if conversations.shows(step.conversation) { conversation.apply(step) }
                    case .delta(let delta): if conversations.shows(delta.conversation) { conversation.apply(delta) }
                    case .artifact(let artifact): conversation.apply(artifact)
                    case .github(let work): apply(work)
                    case .conversation(let change): conversations.apply(change)
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
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 30)
        }
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

    /// The runner's brain's answer to the user's words, as the window's cards
    /// show it (`Desk.planElsewhere`): the drafts are its, and Dispatch sends them back to it.
    func plan(_ said: String, answer: (question: String, option: String)?, attachments: [String] = []) async throws -> Desk.Talk {
        guard let runner else { throw RunnerError(message: "The runner on this Mac isn't running yet.") }
        // In the conversation shown, or a new one (obid keeps many, #493); neither for one thread.
        let planned: PlannedTurn
        do {
            planned = try await runner.planned(said, answer: answer, attachments: attachments, in: conversations.target(said))
        } catch {
            conversations.failed()
            throw error
        }
        await conversations.joined(planned.conversation)
        switch planned.result {
        case .question(let said, let question):
            return .question(said: said, Plan.Question(text: question.text, options: question.options, details: question.details,
                                                       recommended: question.recommended, plan: question.plan))
        case .reply(let text, let started):
            for job in started { apply(job) }
            return .reply(text)
        case .none: return .none
        }
    }

    /// Cancels a plan still running on the local runner (tests give their own `runner`).
    func cancelPlan(on given: Runner? = nil) async {
        // The conversation shown's (#493): obid otherwise cancels the latest plan in any of them.
        await (given ?? runner)?.cancelPlan(conversations.shown)
    }

    /// The runner's exact sentence for publishing a job: Publish shows it, and Touch ID approves it.
    func publishAction(_ id: String) async throws -> String {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings to publish it.") }
        return try await runner.publishAction(id)
    }

    /// Publishes a runner's job with that sentence, after Touch ID; the runner pushes and opens the pull request.
    @discardableResult
    func publish(_ id: String, action: String) async throws -> URL {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings to publish it.") }
        let url = try await device.publish(id, action: action, with: runner)
        // Its event brings the rest; until then it's published here too.
        if var job = jobs.first(where: { $0.id == id }) {
            job.published = url.absoluteString
            job.publishError = nil
            apply(job)
        }
        return url
    }

    /// Clear done: the runner records the time, and the window here and Home on the iPhone hide
    /// the jobs that finished by then.
    func clear() async throws {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings to clear done jobs.") }
        clearedAt = try await runner.clear()
    }

    /// Saves the model and effort the runner's jobs use (Settings › Models).
    func setModels(_ models: ModelSettings) async throws {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings first.") }
        self.models = try await runner.setModels(models)
    }

    /// Settles one of the runner's inbox items: an answer goes to its job, `done` lets it go, `later` puts it off.
    func settle(_ id: String, answer: String? = nil, done: Bool? = nil, later: Date? = nil) async throws {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings to answer it.") }
        apply(try await runner.settle(id, answer: answer, done: done, later: later))
    }

    /// Changes a runner job's mode (its screen's Mode menu): a permission it waits on that the new
    /// mode allows is answered.
    func setMode(_ id: String, _ mode: RunnerMode) async throws {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings to change it.") }
        let job = try await runner.setMode(id, mode)
        extras[id, default: RunnerJobExtras(id: id)].mode = mode.rawValue
        apply(job)
    }

    /// Allow, Always allow or Deny on what a runner job's agent waits for; words go with a deny.
    /// `ask`: only that ask (an alert's), never a newer one the alert didn't show.
    func answer(_ id: String, _ decision: RunnerPermission.Decision, message: String? = nil, ask: String? = nil) async throws {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings to answer it.") }
        guard let permission = extras[id]?.permission else { return }
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
        guard let runner else { throw RunnerError(message: "The runner isn't set up.") }
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

    /// An inbox item as the runner last said it: one that's done leaves the list.
    func apply(_ item: InboxItem) {
        inbox.removeAll { $0.id == item.id }
        if item.isOpen { inbox.append(item) }
        else {
            inboxHistory.removeAll { $0.id == item.id }
            inboxHistory.append(item)
        }
    }

    /// The runner's answer to Stop or a message, or one of its events: the job with that id.
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
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings first.") }
        do {
            return try await call(runner)
        } catch let error as RunnerError {
            gone(id, error.status)
            throw error
        }
    }

    /// The runner answered `status` about the job `id`: on a 404 the job goes from here.
    private func gone(_ id: String, _ status: Int?) {
        guard status == 404 else { return }
        jobs = JobList.answered(status, about: id, in: jobs, id: \.id)
        extras[id] = nil
        onScreen.remove(id)
        notified?[id] = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
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
        let job: Job
        do { job = try await runner.job(id) } catch let error as RunnerError {
            if runnerChanges == asked { gone(id, error.status) }
            throw error
        }
        // Settings › Runner changed while it was on its way: it's the other runner's job.
        guard runnerChanges == asked, !jobs.contains(where: { $0.id == id }) else { return }
        jobs = JobList.placed(job, in: jobs, id: \.id, created: \.created)
        noticeChanges()
    }

    /// The whole list, the latest 50, on every (re)connection: what changed while the connection
    /// was down alerts now. A job whose screen is open stays, fetched again so it's current.
    private func take(_ fresh: [Job], from runner: Runner) async {
        let (list, refetch) = JobList.keeping(fresh, old: jobs, onScreen: onScreen, id: \.id, created: \.created)
        jobs = list
        let asked = runnerChanges
        for id in refetch {
            let job: Job?
            do { job = try await runner.job(id) } catch { job = nil; if runnerChanges == asked { gone(id, (error as? RunnerError)?.status) } }
            // Settings › Runner changed meanwhile: these are the other runner's.
            guard runnerChanges == asked, !Task.isCancelled else { return }
            if let job { jobs = JobList.placed(job, in: jobs, id: \.id, created: \.created) }
        }
        noticeChanges()
        // Alerts left in Notification Center, from before a drop or a restart, whose job needs nothing now.
        let gone = jobs.filter { Self.notice(for: $0) == nil }.map(\.id)
        if !gone.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone) }
    }

    private func noticeChanges() {
        let (changes, now) = Self.notices(jobs, after: notified ?? [:])
        defer { notified = now }
        guard notified != nil else { return }
        for (job, notice) in changes {
            if let notice {
                Self.post(notice, for: job)
                onNotice(job, notice)
            } else {
                // Published, from the iPhone or by the runner, dismissed, or running again: its alert goes.
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [job.id])
            }
        }
    }

    // MARK: Notices, as the runner decides them (Runner/Push.swift)

    /// Nothing for a job the user dismissed: its alert clears.
    static func notice(for job: Job) -> Notice? {
        if job.waitsForPermission { return .permission }
        if job.waitsForAnswer { return .question }
        guard job.needsYou else { return nil }
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
    static func notices(_ jobs: [Job], after notified: [String: String]) -> (changes: [(Job, Notice?)], notified: [String: String]) {
        var changes: [(Job, Notice?)] = []
        var now: [String: String] = [:]
        for job in jobs {
            let notice = Self.notice(for: job)
            let said = notice.map { $0 == .permission ? "permission:\(job.permission?.id ?? "")" : $0.rawValue }
            now[job.id] = said
            if said != notified[job.id] { changes.append((job, notice)) }
        }
        return (changes, now)
    }

    /// "Couldn't publish: Fix oby #42", as the iPhone's alert says it. A ready job whose publish
    /// didn't say why is just ready to publish.
    static func title(_ notice: Notice, for job: Job) -> String {
        switch notice {
        case .ready: "\(job.publishError == nil ? "Ready to publish" : "Couldn't publish"): \(job.heading)"
        case .failed: "Failed: \(job.heading)"
        case .interrupted: "Interrupted: \(job.heading)"
        case .review: "Changes requested: \(job.heading)"
        case .question: "Question: \(job.heading)"
        case .merge: "Not merged: \(job.heading)"
        case .permission: "Needs your OK: \(job.heading)"
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

    /// The runner's categories: "ready" for a job waiting for Publish, with Publish and Open, as the
    /// iPhone's; "job" for the rest, which only opens it.
    static func registerCategories() {
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let publish = UNNotificationAction(identifier: publishButton, title: "Publish with Touch ID", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "ready", actions: [publish, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "job", actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission", actions: [
                UNNotificationAction(identifier: allowButton, title: "Allow", options: []),
                UNNotificationAction(identifier: denyButton, title: "Deny", options: [.destructive]),
                open,
            ], intentIdentifiers: []),
        ])
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

    private static func post(_ notice: Notice, for job: Job) {
        let content = UNMutableNotificationContent()
        content.title = title(notice, for: job)
        content.body = body(notice, for: job)
        content.sound = .default
        content.categoryIdentifier = notice == .ready ? "ready" : notice == .permission ? "permission" : "job"
        content.threadIdentifier = "jobs"
        content.userInfo = [jobKey: job.id]
        if notice == .permission, let ask = job.permission?.id { content.userInfo[permissionKey] = ask }
        let request = UNNotificationRequest(identifier: job.id, content: content, trigger: nil)
        Task {
            do { try await UNUserNotificationCenter.current().add(request) } catch {
                Logger.feed.error("posting an alert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension Logger {
    nonisolated static let feed = Logger(subsystem: "com.deskree.oby", category: "runner")
}
