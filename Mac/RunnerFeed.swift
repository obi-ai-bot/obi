import AppKit
import Foundation
import Observation
import OSLog
import UserNotifications

/// The always-on runner (Settings › Runner) for as long as Oby runs, not only while the island is
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
        /// Its agent asked the user something and waits for the answer (the inbox has it).
        case question
        /// Oby's merge stopped: it couldn't merge, or the Mac check failed with no round left.
        case merge
    }

    private(set) var jobs: [Job] = [] {
        didSet {
            let count = jobs.count(where: \.isActive)
            if count != working { working = count }
        }
    }
    /// Agents working on the runner now. The closed notch reads this, not `jobs`, so a new step
    /// doesn't redraw it.
    private(set) var working = 0
    /// What waits in the runner's inbox, put-off items too, oldest first: answered on the iPhone,
    /// it goes from here too.
    private(set) var inbox: [InboxItem] = []
    /// Oby's plain words for each of those items (#65), which Engine's InboxItem doesn't read, by item id.
    private(set) var inboxWords: [String: InboxWords] = [:]
    /// The runner's accounts and their usage, as it last said: the brain tells them too.
    private(set) var accounts: [AccountState] = []
    /// What each job carries that Engine's Job doesn't read yet (its mode, the permission it waits
    /// on, its question's recommended option and plan), by job id.
    private(set) var extras: [String: RunnerJobExtras] = [:]
    /// The mode the runner's new jobs get by default, or nil from a runner without modes.
    private(set) var defaultMode: RunnerMode?
    /// The name the runner reports in /v1/status, like "tetrix-lab".
    private(set) var host: String?
    /// When Clear done was last pressed, here or on the iPhone (the runner's clock), or nil: the
    /// island hides the jobs that finished by then, the runner's and this Mac's alike.
    private(set) var clearedAt: Date?
    /// How the line to the runner is: Settings › Runner says it.
    private(set) var connection = RunnerConnection.connecting
    /// The runner didn't answer the last try; the feed keeps trying.
    var down: Bool { if case .offline = connection { true } else { false } }
    /// The model and effort the runner's jobs use, as it last said (Settings › Models).
    private(set) var models: ModelSettings?
    /// Merge checks this Mac runs for the runner (Settings › Runner, on by default).
    let checks = MacChecks()
    /// This Mac's Touch ID key, registered on every connection: with it, the runner's jobs publish from here.
    let device = MacDevice()
    /// A job's notice just changed to something that needs the user: the notch's heads-up.
    @ObservationIgnored var onNotice: (Job, Notice) -> Void = { _, _ in }

    /// The URL followed now, or nil before `start`.
    @ObservationIgnored private var url: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// What each job's alert last said, or nil until the first list arrives: what the jobs already
    /// need when Oby starts isn't news.
    @ObservationIgnored private var notified: [String: Notice]?
    /// The runner's jobs whose screen the island shows: new lists keep them even when they're
    /// older than the latest 50, as on the iPhone.
    @ObservationIgnored private var onScreen: Set<String> = []

    var runner: Runner? { Self.runner(url ?? "") }
    var active: [Job] { jobs.filter(\.isActive) }

    /// "tetrix-lab": what the runner calls itself, or its URL's first name before it has answered.
    var name: String {
        host ?? runner?.base.host()?.split(separator: ".").first.map(String.init) ?? "The runner"
    }

    static func runner(_ url: String) -> Runner? {
        URL(string: url.trimmingCharacters(in: .whitespaces)).flatMap { $0.host() == nil ? nil : Runner(base: $0) }
    }

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
        let url = UserDefaults.standard.string(forKey: "runnerURL") ?? ""
        guard again || url != self.url else { return }
        let first = self.url == nil
        if url != self.url {
            jobs = []
            inbox = []
            inboxWords = [:]
            accounts = []
            models = nil
            extras = [:]
            defaultMode = nil
            host = nil
            clearedAt = nil
            notified = nil
            device.reset()
        }
        self.url = url
        connection = .connecting
        loop?.cancel()
        loop = nil
        guard let runner = Self.runner(url) else { return }
        loop = Task {
            if !first { try? await Task.sleep(for: .seconds(1)) }
            await run(runner)
        }
    }

    /// Follows the runner's events and, once it's following, fetches the jobs and the inbox; after
    /// any drop it tries again, waiting a little longer each time, up to half a minute.
    private func run(_ runner: Runner) async {
        var wait = 1.0
        while !Task.isCancelled {
            do {
                // Following first, then fetching: what changes in between waits in the stream and
                // applies over what was fetched.
                for try await event in runner.events() {
                    switch event {
                    case .connected:
                        // Status every time: a Clear done while the connection was down is in it.
                        let status = try await runner.status()
                        let (list, extras) = try await runner.jobsWithExtras()
                        let (items, words) = try await runner.inboxWithWords()
                        // Settings › Runner changed, or the Mac woke, while these were on their way.
                        try Task.checkCancellation()
                        host = status.runner.host
                        clearedAt = status.clearedAt
                        accounts = status.accounts
                        models = status.models
                        defaultMode = RunnerMode(status.permissions?.mode)
                        self.extras = extras
                        await take(list, from: runner)
                        inbox = items
                        inboxWords = words
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
                        if let words { inboxWords[item.id] = words }
                        apply(item)
                    case .accounts(let list): accounts = list
                    case .check(let check): if check.state == .queued { checks.look(runner) }
                    }
                }
            } catch {
                if Task.isCancelled { return }
                if !down { Logger.feed.error("following the runner failed: \(error.localizedDescription, privacy: .public)") }
                connection = .offline(error.localizedDescription)
            }
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 30)
        }
    }

    /// Registers this Mac's publishing key, as the iPhone does on each connection. A runner whose
    /// pairing is closed answers 403: Settings › Runner shows its line, with Try again.
    func register(_ runner: Runner? = nil) {
        guard let runner = runner ?? self.runner else { return }
        Task {
            do { try await device.register(with: runner) } catch {
                Logger.feed.error("registering this Mac failed: \(error.localizedDescription, privacy: .public)")
            }
        }
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

    /// Clear done: the runner records the time, and the island here and Home on the iPhone hide
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
    func answer(_ id: String, _ decision: RunnerPermission.Decision, message: String? = nil) async throws {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings to answer it.") }
        guard let permission = extras[id]?.permission else { return }
        let job = try await runner.answer(id, permission: permission.id, decision, message: message)
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

    /// An inbox item as the runner last said it: one that's done leaves the list.
    func apply(_ item: InboxItem) {
        inbox.removeAll { $0.id == item.id }
        if item.isOpen { inbox.append(item) } else { inboxWords[item.id] = nil }
    }

    /// The runner's answer to Stop or a message, or one of its events: the job with that id.
    func apply(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        noticeChanges()
    }

    /// A job's screen opened or closed on the island: while it's open, new lists keep its job.
    func showing(_ id: String, _ shown: Bool) {
        if shown { onScreen.insert(id) } else { onScreen.remove(id) }
    }

    /// A job older than the list's 50 (an inbox item or an alert opened it): fetched, and kept
    /// among the others in age order.
    func fetch(_ id: String, from runner: Runner? = nil) async throws {
        guard !jobs.contains(where: { $0.id == id }) else { return }
        guard let runner = runner ?? self.runner else { throw RunnerError(message: "Set the runner's URL in Settings to open it.") }
        let job = try await runner.job(id)
        guard !jobs.contains(where: { $0.id == id }) else { return }
        jobs = JobList.placed(job, in: jobs, id: \.id, created: \.created)
        noticeChanges()
    }

    /// The whole list, the latest 50, on every (re)connection: what changed while the connection
    /// was down alerts now. A job whose screen is open stays, fetched again so it's current.
    private func take(_ fresh: [Job], from runner: Runner) async {
        let (list, refetch) = JobList.keeping(fresh, old: jobs, onScreen: onScreen, id: \.id, created: \.created)
        jobs = list
        // Settings › Runner changed meanwhile: these were the other runner's.
        for id in refetch where !Task.isCancelled {
            guard let job = try? await runner.job(id) else { continue }
            jobs = JobList.placed(job, in: jobs, id: \.id, created: \.created)
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
    static func notices(_ jobs: [Job], after notified: [String: Notice]) -> (changes: [(Job, Notice?)], notified: [String: Notice]) {
        var changes: [(Job, Notice?)] = []
        var now: [String: Notice] = [:]
        for job in jobs {
            let notice = Self.notice(for: job)
            now[job.id] = notice
            if notice != notified[job.id] { changes.append((job, notice)) }
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
        }
    }

    /// Why its own publish failed when that's what it needs, why Oby's review stopped, or the summary's first line.
    static func body(_ notice: Notice, for job: Job) -> String {
        let line = job.summary.split(separator: "\n").first.map(String.init)
        if notice == .ready { return job.publishError ?? line ?? "Done" }
        if notice == .review { return Review.stopLine }
        if notice == .question, let question = job.question { return question.text }
        if notice == .merge { return job.mergeError ?? job.macCheck.map { $0.problem ?? $0.failureLine + (job.checkStop.map { " " + $0 } ?? "") } ?? "Not merged" }
        return line ?? job.status.rawValue.capitalized
    }

    // MARK: Alerts

    /// The `job` key holds the job's id, as on the iPhone; the request's identifier is the id too,
    /// so a newer notice replaces the older one.
    static let jobKey = "job"

    /// The "ready" alert's Publish: the island opens on the job, shows the runner's sentence, and asks for Touch ID.
    static let publishButton = "publish"

    /// The runner's categories: "ready" for a job waiting for Publish, with Publish and Open, as the
    /// iPhone's; "job" for the rest, which only opens it.
    static func registerCategories() {
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let publish = UNNotificationAction(identifier: publishButton, title: "Publish with Touch ID", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "ready", actions: [publish, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "job", actions: [open], intentIdentifiers: []),
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
        content.categoryIdentifier = notice == .ready ? "ready" : "job"
        content.threadIdentifier = "jobs"
        content.userInfo = [jobKey: job.id]
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
