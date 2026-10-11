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
    /// The name the runner reports in /v1/status, like "tetrix-lab".
    private(set) var host: String?
    /// When Clear done was last pressed, here or on the iPhone (the runner's clock), or nil: the
    /// island hides the jobs that finished by then, the runner's and this Mac's alike.
    private(set) var clearedAt: Date?
    /// The runner didn't answer the last try; the feed keeps trying.
    private(set) var down = false
    /// Merge checks this Mac runs for the runner (Settings › Runner, on by default).
    let checks = MacChecks()
    /// A job's notice just changed to something that needs the user: the notch's heads-up.
    @ObservationIgnored var onNotice: (Job, Notice) -> Void = { _, _ in }

    /// The URL followed now, or nil before `start`.
    @ObservationIgnored private var url: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// What each job's alert last said, or nil until the first list arrives: what the jobs already
    /// need when Oby starts isn't news.
    @ObservationIgnored private var notified: [String: Notice]?

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
            host = nil
            clearedAt = nil
            notified = nil
        }
        self.url = url
        down = false
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
                        let list = try await runner.jobs()
                        let items = try await runner.inbox()
                        // Settings › Runner changed, or the Mac woke, while these were on their way.
                        try Task.checkCancellation()
                        host = status.runner.host
                        clearedAt = status.clearedAt
                        take(list)
                        inbox = items
                        down = false
                        wait = 1
                        Self.ask()
                        checks.look(runner)
                    case .job(let job): apply(job)
                    case .cleared(let date): clearedAt = date
                    case .inbox(let item): apply(item)
                    case .accounts: break
                    case .check(let check): if check.state == .queued { checks.look(runner) }
                    }
                }
            } catch {
                if Task.isCancelled { return }
                if !down { Logger.feed.error("following the runner failed: \(error.localizedDescription, privacy: .public)") }
                down = true
            }
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 30)
        }
    }

    /// Clear done: the runner records the time, and the island here and Home on the iPhone hide
    /// the jobs that finished by then.
    func clear() async throws {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings to clear done jobs.") }
        clearedAt = try await runner.clear()
    }

    /// Settles one of the runner's inbox items: an answer goes to its job, `done` lets it go, `later` puts it off.
    func settle(_ id: String, answer: String? = nil, done: Bool? = nil, later: Date? = nil) async throws {
        guard let runner else { throw RunnerError(message: "Set the runner's URL in Settings to answer it.") }
        apply(try await runner.settle(id, answer: answer, done: done, later: later))
    }

    /// An inbox item as the runner last said it: one that's done leaves the list.
    func apply(_ item: InboxItem) {
        inbox.removeAll { $0.id == item.id }
        if item.isOpen { inbox.append(item) }
    }

    /// The runner's answer to Stop or a message, or one of its events: the job with that id.
    func apply(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        noticeChanges()
    }

    /// The whole list, on every (re)connection: what changed while the connection was down alerts now.
    private func take(_ list: [Job]) {
        jobs = list
        noticeChanges()
        // Alerts left in Notification Center, from before a drop or a restart, whose job needs nothing now.
        let gone = list.filter { Self.notice(for: $0) == nil }.map(\.id)
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
        }
    }

    /// Why its own publish failed when that's what it needs, why Oby's review stopped, or the summary's first line.
    static func body(_ notice: Notice, for job: Job) -> String {
        let line = job.summary.split(separator: "\n").first.map(String.init)
        if notice == .ready { return job.publishError ?? line ?? "Done" }
        if notice == .review { return Review.stopLine }
        if notice == .question, let question = job.question { return question.text }
        return line ?? job.status.rawValue.capitalized
    }

    // MARK: Alerts

    /// The `job` key holds the job's id, as on the iPhone; the request's identifier is the id too,
    /// so a newer notice replaces the older one.
    static let jobKey = "job"

    /// The runner's categories: "ready" for a job waiting for Publish, "job" for the rest. The Mac
    /// can't publish a runner's job (that's the iPhone's Face ID), so both only open it.
    static func registerCategories() {
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "ready", actions: [open], intentIdentifiers: []),
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
