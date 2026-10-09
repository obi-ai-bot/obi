import Foundation
import OSLog

/// The phone's view of the runner: its jobs and accounts, kept live while the app is open, and
/// the conversation that turns words into a plan.
@Observable
final class Phone {
    enum Talk: Equatable {
        case none
        case thinking(String)
        case plan(Draft)
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
    private(set) var jobs: [Job] = []
    private(set) var accounts: [Account] = []
    private(set) var models: ModelSettings?
    private var loop: Task<Void, Never>?

    init() {
        runnerURL = UserDefaults.standard.url(forKey: "runner.url") ?? Runner.defaultURL
    }

    var runner: Runner { Runner(base: runnerURL) }
    var active: [Job] { jobs.filter(\.isActive) }
    var signedIn: [Account] { accounts.filter(\.signedIn) }

    /// Running jobs first, then the rest, newest first.
    var visibleJobs: [Job] { active + jobs.filter { !$0.isActive } }

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
                    jobs = try await runner.jobs()
                    connection = .live
                    wait = 1
                    do { _ = try await registerDevice() } catch {
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

    /// The app went to the background: no connection, no battery spent.
    func stop() {
        loop?.cancel()
        loop = nil
        if connection == .live { connection = .connecting }
    }

    private func apply(_ event: RunnerEvent) {
        switch event {
        case .job(let job):
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        case .accounts(let accounts):
            self.accounts = accounts
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
                case .plan(let draft): result = .plan(draft)
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

    func dispatch(_ draft: Draft) async throws {
        let job = try await runner.dispatch(draft.job)
        talk = .none
        apply(.job(job))
    }

    func stop(_ id: String) async throws {
        apply(.job(try await runner.stop(id)))
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

    /// Registers the phone's Face ID key with the runner, once per runner, and returns its id.
    private func registerDevice() async throws -> String {
        if let deviceID { return deviceID }
        guard DeviceKey.isAvailable else { throw RunnerError(message: "Publishing needs Face ID on your iPhone.") }
        let id = try await runner.register(name: "iPhone", publicKey: try DeviceKey.publicKey())
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }
}

extension Logger {
    nonisolated static let phone = Logger(subsystem: "com.deskree.oby", category: "phone")
}
