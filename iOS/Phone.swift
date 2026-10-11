import Foundation
import OSLog

/// The phone's view of the runner: its jobs and accounts, kept live while the app is open, and
/// the conversation that turns words into a plan.
@Observable
final class Phone {
    enum Talk: Equatable {
        case none
        case thinking(String)
        case plan([Draft])
        case question(said: String, Question)
        case reply(String)
    }

    enum Connection: Equatable {
        case connecting
        case live
        case offline(String)
    }

    var runnerURL: URL {
        didSet {
            UserDefaults.standard.set(runnerURL, forKey: "runner.url")
            stop()
            start()
        }
    }
    var talk: Talk = .none
    private(set) var connection: Connection = .connecting
    private(set) var host = ""
    /// The job list arrived at least once, so an empty list really is empty.
    private(set) var loaded = false
    private(set) var jobs: [Job] = [] {
        didSet {
            // Published, dismissed or running again, here or on the Mac: its alert goes.
            let needed = Set(oldValue.filter(\.needsYou).map(\.id))
            let done = Set(jobs.filter { !$0.needsYou && needed.contains($0.id) }.map(\.id))
            if !done.isEmpty { Task { await Notifications.clear(done) } }
            // One Live Activity update at a time, in order.
            syncing = Task { [jobs, syncing] in
                await syncing?.value
                await JobsActivity.sync(jobs)
            }
            JobWaiter.shared.wait(for: jobs, runner: runnerURL)
        }
    }
    /// The Live Activity's latest update, so a background wake can wait for it to land.
    @ObservationIgnored private var syncing: Task<Void, Never>?
    private(set) var accounts: [Account] = []
    /// What waits in the runner's inbox, put-off items too: answered on the Mac, it goes from here too.
    private(set) var inbox: [InboxItem] = []
    private(set) var models: ModelSettings?
    /// When Clear done was last pressed, here or on the Mac (the runner's clock), or nil: Home
    /// hides the jobs that finished by then. The runner keeps them all.
    private(set) var clearedAt: Date?
    private var loop: Task<Void, Never>?
    /// The job a notification asked to open; Home opens it.
    var opening: String?
    /// The job whose notification's Publish was tapped; its screen publishes once it's ready.
    var publishing: String?

    init() {
        runnerURL = UserDefaults.standard.url(forKey: "runner.url") ?? Runner.defaultURL
        JobsActivity.watchTokens { [weak self] in self?.runner }
    }

    var runner: Runner { Runner(base: runnerURL) }
    var active: [Job] { jobs.filter(\.isActive) }
    var signedIn: [Account] { accounts.filter(\.signedIn) }

    /// The jobs Home lists: all but those that finished by the last Clear done, newest first. Home
    /// puts them in their groups (JobList.groups), as the Mac's island does.
    var visibleJobs: [Job] { jobs.filter { $0.isActive || JobList.shows(finished: $0.finished, clearedAt: clearedAt) } }

    // MARK: Staying live

    /// Fetches everything, then follows the runner's events; after any drop it tries again,
    /// waiting a little longer each time.
    func start() {
        guard loop == nil else { return }
        loop = Task {
            var wait = 1.0
            while !Task.isCancelled {
                do {
                    let status = try await runner.status()
                    host = status.runner.host
                    accounts = status.accounts
                    models = status.models
                    clearedAt = status.clearedAt
                    jobs = try await runner.jobs()
                    // A runner older than the inbox has none.
                    inbox = (try? await runner.inbox()) ?? []
                    loaded = true
                    // Alerts whose job needs nothing any more, if their clearing push didn't arrive.
                    await Notifications.clear(Set(jobs.filter { !$0.needsYou }.map(\.id)))
                    connection = .live
                    wait = 1
                    // Jobs dispatched from the Mac or the runner API notify too, so ask on connecting.
                    Notifications.ask()
                    do { _ = try await registerDevice(again: true) } catch {
                        Logger.phone.error("registering this iPhone failed: \(error.localizedDescription, privacy: .public)")
                    }
                    for try await event in runner.events() { apply(event) }
                } catch {
                    if Task.isCancelled { return }
                    connection = .offline(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(wait))
                wait = min(wait * 2, 15)
            }
        }
    }

    /// iOS woke Oby because a job ended (JobWaiter): fetch the list, and wait until the Live
    /// Activity says how it ended before iOS suspends Oby again.
    func catchUp() async {
        JobWaiter.shared.reconnect()
        guard let fresh = try? await runner.jobs() else { return }
        jobs = fresh
        await syncing?.value
    }

    /// Pull to refresh: fetch the job list now, without waiting for the runner's next event.
    func reload() async {
        do {
            jobs = try await runner.jobs()
            inbox = (try? await runner.inbox()) ?? inbox
            loaded = true
        } catch {
            Logger.phone.error("reloading jobs failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The app went to the background: no connection, no battery spent.
    func stop() {
        loop?.cancel()
        loop = nil
        if connection == .live { connection = .connecting }
        JobsActivity.markStale()
    }

    private func apply(_ event: RunnerEvent) {
        switch event {
        case .job(let job):
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        case .accounts(let accounts):
            self.accounts = accounts
        case .cleared(let date):
            clearedAt = date
        case .inbox(let item):
            // One that's done leaves the list.
            inbox.removeAll { $0.id == item.id }
            if item.isOpen { inbox.append(item) }
        }
    }

    // MARK: Planning

    func ask(_ words: String) {
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        plan(said, answer: nil)
    }

    /// The user picked one of the brain's options.
    func answer(_ option: String, said: String, question: Question) {
        plan(said, answer: (question.text, option))
    }

    func cancel() { talk = .none }

    private func plan(_ said: String, answer: (question: String, option: String)?) {
        talk = .thinking(said)
        Task {
            let result: Talk
            do {
                switch try await runner.plan(said, answer: answer) {
                case .plan(let drafts): result = .plan(drafts)
                case .question(let said, let question): result = .question(said: said, question)
                case .reply(let text): result = .reply(text)
                case .none: result = .none
                }
            } catch {
                result = .reply(error.localizedDescription)
            }
            // Cancelled or replaced while the brain was thinking.
            if talk == .thinking(said) { talk = result }
        }
    }

    // MARK: Jobs

    /// A notification was tapped: open its job, and publish it if that's what was tapped.
    func open(_ id: String, publish: Bool) {
        opening = id
        publishing = publish ? id : nil
    }

    func dispatch(_ draft: Draft) async throws {
        let job = try await runner.dispatch(draft.job)
        talk = .none
        apply(.job(job))
        Notifications.ask()
    }

    /// Dispatch all: one `POST /v1/jobs` per draft, in order, then the card closes. A draft whose
    /// job is already here was sent before, so after a failure this sends only the rest.
    func dispatch(all drafts: [Draft]) async throws {
        for draft in drafts where !jobs.contains(where: { $0.id == draft.job.id }) {
            apply(.job(try await runner.dispatch(draft.job)))
        }
        talk = .none
        Notifications.ask()
    }

    func stop(_ id: String) async throws {
        apply(.job(try await runner.stop(id)))
    }

    /// Stop all: every job on the runner stops now, and shows here as stopped.
    func stopAll() async throws {
        for job in try await runner.stopAll().jobs { apply(.job(job)) }
    }

    /// Lets go of a job that needs you; its alert clears with the runner's answer.
    func dismiss(_ id: String) async throws {
        apply(.job(try await runner.dismiss(id)))
    }

    /// Clear done: the runner records the time, and Home here and the Mac's island hide the jobs
    /// that finished by then.
    func clear() async throws {
        clearedAt = try await runner.clear()
    }

    /// Settles an inbox item: an answer goes to its job, `done` lets it go, `later` puts it off.
    func settle(_ id: String, answer: String? = nil, done: Bool? = nil, later: Date? = nil) async throws {
        apply(.inbox(try await runner.settle(id, answer: answer, done: done, later: later)))
    }

    /// Tells the job's agent something; the runner answers with the job, running again.
    func tell(_ id: String, _ text: String) async throws {
        apply(.job(try await runner.tell(id, text)))
    }

    /// The exact sentence publishing this job would carry out.
    func publishAction(_ id: String) async throws -> String {
        try await runner.publishAction(id)
    }

    /// Face ID signs the action; the runner checks the signature, then pushes and opens a draft PR.
    func publish(_ id: String, action: String) async throws -> URL {
        guard DeviceKey.isAvailable else { throw RunnerError(message: "Publishing needs Face ID on your iPhone.") }
        let device = try await registerDevice()
        let approval = try await Task.detached { try DeviceKey.approve(job: id, action: action, device: device) }.value
        let url = try await runner.publish(id, approval: approval)
        if var job = jobs.first(where: { $0.id == id }) {
            job.published = url.absoluteString
            apply(.job(job))
        }
        return url
    }

    // MARK: Models

    func modelOptions() async throws -> ModelOptions { try await runner.modelOptions() }

    func setModels(_ models: ModelSettings) async throws {
        self.models = try await runner.setModels(models)
    }

    // MARK: This phone's publishing key

    private var deviceKey: String { "device.\(runnerURL.host() ?? runnerURL.absoluteString)" }
    var deviceID: String? { UserDefaults.standard.string(forKey: deviceKey) }

    /// Registers the phone's Face ID key with the runner and returns its id. On every connection it
    /// registers `again`: the runner keeps a known key's id, and a reinstalled runner learns it anew.
    private func registerDevice(again: Bool = false) async throws -> String {
        if !again, let deviceID { return deviceID }
        guard DeviceKey.isAvailable else { throw RunnerError(message: "Publishing needs Face ID on your iPhone.") }
        let id = try await runner.register(name: "iPhone", publicKey: try DeviceKey.publicKey())
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }
}

extension Logger {
    nonisolated static let phone = Logger(subsystem: "com.deskree.oby", category: "phone")
}
