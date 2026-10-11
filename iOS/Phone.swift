import Foundation
import OSLog

/// The app's tabs (#11): Home is the glance, Chat the thread with Oby, Settings the runner and its accounts.
nonisolated enum PhoneTab: String, Hashable, Sendable { case home, chat, settings }

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

    let voice = PhoneVoice()
    /// The tab in front; a notification's job opens on Home.
    var tab = PhoneTab.home
    /// The runner's conversation, read in pages and followed over `turn` events, for the Chat
    /// tab's thread (Shared/ConversationModel.swift): one thread for every device (#11).
    let conversation = ConversationModel()
    /// What this iPhone said and the runner hasn't listed yet (ChatThread): the runner adds the
    /// user's turn with Oby's answer, so the words show here from the moment they're sent.
    private(set) var echoes: [Turn] = []
    /// Why an echo's request didn't go through, by echo id: the words stay in the thread with the
    /// reason, to try again or edit, until the runner lists them after all.
    private(set) var failures: [String: String] = [:]
    /// What each echo sent, by echo id, to send it again.
    @ObservationIgnored private var requests: [String: Request] = [:]
    /// The echo of the request under way, or nil: the one Cancel or a new request lets go of.
    /// Never another (an older failed one, say): the runner may settle this one before the
    /// request answers, and then `echoes.last` is someone else.
    @ObservationIgnored private var pending: String?

    private struct Request {
        var said: String
        var answer: (question: String, option: String)?
        var voice: Bool
    }
    @ObservationIgnored private let speaker = PhoneSpeaker()
    @ObservationIgnored private var planning: Task<Void, Never>?
    @ObservationIgnored private var spoken = false
    var speakReplies = UserDefaults.standard.object(forKey: "voice.speakReplies") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(speakReplies, forKey: "voice.speakReplies")
            if !speakReplies { speaker.stop() }
        }
    }

    func holdMic() {
        guard !voice.held, !voice.finishing else { return }
        cancel()
        voice.start(context: PhoneSpeech.context(repos: jobs.map(\.repo))) { [weak self] in self?.ask($0, spoken: true) }
    }

    func releaseMic() { voice.release() }

    func cancelVoice() {
        spoken = false
        voice.cancel()
        speaker.stop()
    }

    var runnerURL: URL {
        didSet {
            UserDefaults.standard.set(runnerURL, forKey: "runner.url")
            stop()
            // Another runner: nothing the last one said holds.
            conversation.forget()
            echoes = []
            failures = [:]
            requests = [:]
            pending = nil
            start()
        }
    }
    var talk: Talk = .none
    private(set) var connection: RunnerConnection = .connecting
    private(set) var host = ""
    /// The job list arrived at least once, so an empty list really is empty.
    private(set) var loaded = false
    private(set) var jobs: [Job] = [] {
        didSet {
            // Published, dismissed or running again, here or on the Mac: its alert goes.
            // A question waiting for its answer keeps its alert too.
            let needed = Set(oldValue.filter { $0.needsYou || $0.waitsForAnswer }.map(\.id))
            let done = Set(jobs.filter { !$0.needsYou && !$0.waitsForAnswer && needed.contains($0.id) }.map(\.id))
            if !done.isEmpty { Task { await Notifications.clear(done) } }
            // One Live Activity update at a time, in order.
            syncing = Task { [jobs, syncing] in
                await syncing?.value
                await JobsActivity.sync(jobs)
            }
            JobWaiter.shared.wait(for: jobs, runner: runnerURL)
        }
    }
    /// The jobs whose screens are open (JobScreen): a new list keeps them, even older than its 50.
    @ObservationIgnored private var onScreen: Set<String> = []
    /// The Live Activity's latest update, so a background wake can wait for it to land.
    @ObservationIgnored private var syncing: Task<Void, Never>?
    private(set) var accounts: [Account] = []
    /// What waits in the runner's inbox, put-off items too: answered on the Mac, it goes from here too.
    private(set) var inbox: [InboxItem] = []
    private(set) var models: ModelSettings?
    /// The mode new jobs get by default, as the runner last said, or nil from a runner without modes.
    private(set) var defaultMode: RunnerMode?
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
        conversation.page = { [weak self] before, limit in
            guard let self else { return [] }
            return try await runner.conversation(before: before, limit: limit)
        }
    }

    /// The thread Chat shows: the runner's turns and this iPhone's words still on their way, by time.
    var thread: [Turn] { conversation.thread(with: ChatThread.pending(echoes, runner: conversation.runnerTurns)) }

    var runner: Runner { Runner(base: runnerURL) }
    var active: [Job] { jobs.filter(\.isActive) }
    var signedIn: [Account] { accounts.filter(\.signedIn) }

    /// The jobs Home lists: all but those that finished by the last Clear done, newest first. Home
    /// puts them in their groups (JobList.groups), as the Mac's island does.
    var visibleJobs: [Job] { jobs.filter { $0.isActive || JobList.shows(finished: $0.finished, clearedAt: clearedAt) } }

    // MARK: Staying live

    /// Follows the runner's events and, once it's following, fetches everything; after any drop it
    /// tries again, waiting a little longer each time.
    func start() {
        guard loop == nil else { return }
        loop = Task {
            var wait = 1.0
            while !Task.isCancelled {
                do {
                    // Following first, then fetching (`connected`): what changes in between waits in
                    // the stream and applies over what was fetched.
                    for try await event in runner.events() {
                        guard case .connected = event else { apply(event); continue }
                        try await connected()
                        wait = 1
                    }
                } catch {
                    if Task.isCancelled { return }
                    connection = .offline(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(wait))
                wait = min(wait * 2, 15)
            }
        }
    }

    /// The runner follows this app now: everything it has, fetched.
    private func connected() async throws {
        let status = try await runner.status()
        host = status.runner.host
        accounts = status.accounts
        models = status.models
        clearedAt = status.clearedAt
        defaultMode = RunnerMode(status.permissions?.mode)
        await take(try await runner.jobs())
        inbox = try await runner.inbox()
        // The thread's latest page every time: what was said on the Mac while the connection was
        // down is in it.
        await conversation.reload()
        loaded = true
        // Alerts whose job needs nothing any more, if their clearing push didn't arrive.
        await Notifications.clear(Set(jobs.filter { !$0.needsYou && !$0.waitsForAnswer }.map(\.id)))
        connection = .live
        // Jobs dispatched from the Mac or the runner API notify too, so ask on connecting.
        Notifications.ask()
        do { _ = try await registerDevice(again: true) } catch {
            Logger.phone.error("registering this iPhone failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// iOS woke Oby because a job ended (JobWaiter): fetch the list, and wait until the Live
    /// Activity says how it ended before iOS suspends Oby again.
    func catchUp() async {
        JobWaiter.shared.reconnect()
        guard let fresh = try? await runner.jobs() else { return }
        await take(fresh)
        await syncing?.value
    }

    /// Pull to refresh: fetch the job list now, without waiting for the runner's next event.
    func reload() async {
        do {
            await take(try await runner.jobs())
            inbox = try await runner.inbox()
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
        case .connected:
            break
        case .inbox(let item):
            // One that's done leaves the list.
            inbox.removeAll { $0.id == item.id }
            if item.isOpen { inbox.append(item) }
        case .turn(let turn):
            conversation.apply(turn)
            // The runner listed what this iPhone said: its echo has done its job.
            settleEchoes()
        }
    }

    /// Drops the echoes the runner has listed, with what went with them.
    private func settleEchoes() {
        echoes = ChatThread.pending(echoes, runner: conversation.runnerTurns)
        let kept = Set(echoes.map(\.id))
        failures = failures.filter { kept.contains($0.key) }
        requests = requests.filter { kept.contains($0.key) }
    }

    /// Lets go of an echo: cancelled, edited, or sent again.
    private func drop(echo id: String) {
        echoes.removeAll { $0.id == id }
        failures[id] = nil
        requests[id] = nil
        if pending == id { pending = nil }
    }

    // MARK: Planning

    func ask(_ words: String, spoken: Bool = false) {
        guard let said = ChatThread.words(words) else { return }
        cancelVoice()
        self.spoken = spoken
        plan(said, answer: nil, voice: spoken)
    }

    /// The user picked one of the brain's options.
    func answer(_ option: String, said: String, question: Question) {
        plan(said, answer: (question.text, option))
    }

    func cancel() {
        planning?.cancel()
        planning = nil
        spoken = false
        speaker.stop()
        // The words the user gave up on leave the thread, as on the Mac; the runner still lists
        // them with its answer if it got them, and then they show.
        dropPending()
        talk = .none
    }

    /// Lets go of the request under way's echo, if it's still in the thread.
    private func dropPending() {
        if let pending { drop(echo: pending) }
        pending = nil
    }

    /// Try again on words that didn't go through: the same request, sent anew.
    func retry(echo id: String) {
        guard let request = requests[id] else { return }
        drop(echo: id)
        plan(request.said, answer: request.answer, voice: request.voice)
    }

    /// Edit on words that didn't go through: they leave the thread for the field.
    func discard(echo id: String) {
        drop(echo: id)
    }

    private func plan(_ said: String, answer: (question: String, option: String)?, voice: Bool = false) {
        planning?.cancel()
        speaker.stop()
        dropPending()
        talk = .thinking(said)
        // The thread shows the words as the runner will list them: an answer is its option.
        let echo = Turn(who: .user, text: answer?.option ?? said, voice: voice ? true : nil)
        echoes.append(echo)
        requests[echo.id] = Request(said: said, answer: answer, voice: voice)
        pending = echo.id
        planning = Task {
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
                // The request didn't go through (or the runner answered with an error): the words
                // stay in the thread with why, to try again or edit. If the runner got them after
                // all (a timeout), its turn settles the echo as usual.
                if !Task.isCancelled { failures[echo.id] = error.localizedDescription }
            }
            // Cancelled or replaced while the brain was thinking.
            guard !Task.isCancelled else { return }
            // The request is over: its words are the runner's now, or stay with their failure.
            if pending == echo.id { pending = nil }
            talk = result
            if spoken, speakReplies {
                switch result {
                case .reply(let text): speaker.say(text)
                case .question(_, let question): speaker.say(question.text)
                case .plan(let drafts): speaker.say(drafts.map(\.reply).joined(separator: " "))
                default: break
                }
            }
        }
    }

    // MARK: Jobs

    /// A notification was tapped: open its job on Home, and publish it if that's what was tapped.
    func open(_ id: String, publish: Bool) {
        tab = .home
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

    /// Moves a job to another tool, account or model; the runner picks what's left nil.
    func move(_ id: String, agent: String?, account: String?, model: String?) async throws {
        apply(.job(try await runner.move(id, agent: agent, account: account, model: model)))
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

    /// A job's screen opened or closed: while it's open, new lists keep its job.
    func showing(_ id: String, _ shown: Bool) {
        if shown { onScreen.insert(id) } else { onScreen.remove(id) }
    }

    /// A new list from the runner, the latest 50. A job whose screen is open stays even when it's
    /// older than those, fetched again so it's current.
    private func take(_ fresh: [Job]) async {
        let (list, refetch) = JobList.keeping(fresh, old: jobs, onScreen: onScreen, id: \.id, created: \.created)
        jobs = list
        for id in refetch {
            guard let job = try? await runner.job(id) else { continue }
            jobs = JobList.placed(job, in: jobs, id: \.id, created: \.created)
        }
    }

    /// A job older than the list's 50 (an inbox item or a notification opened it): fetched, and
    /// kept among the others in age order.
    func fetch(_ id: String) async {
        guard !jobs.contains(where: { $0.id == id }) else { return }
        do {
            let job = try await runner.job(id)
            guard !jobs.contains(where: { $0.id == id }) else { return }
            jobs = JobList.placed(job, in: jobs, id: \.id, created: \.created)
        } catch {
            Logger.phone.error("fetching job \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
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

    // MARK: Permissions

    /// Changes a running job's mode (the job screen's Mode menu).
    func setMode(_ id: String, _ mode: RunnerMode) async throws {
        apply(.job(try await runner.setMode(id, mode)))
    }

    /// Allow, Always allow or Deny on what a job's agent waits for; words go with a deny.
    func answer(_ job: Job, _ decision: RunnerPermission.Decision, message: String? = nil) async throws {
        guard let permission = job.permission else { return }
        apply(.job(try await runner.answer(job.id, permission: permission.id, decision, message: message)))
    }

    /// Settings › Permissions: the mode new jobs get.
    func setDefaultMode(_ mode: RunnerMode) async throws {
        try await runner.setDefaultMode(mode)
        defaultMode = mode
    }

    // MARK: Models

    func setModels(_ models: ModelSettings) async throws {
        self.models = try await runner.setModels(models)
    }

    // MARK: This phone's publishing key

    private var deviceKey: String { "device.\(runnerURL.host() ?? runnerURL.absoluteString)" }
    var deviceID: String? { UserDefaults.standard.string(forKey: deviceKey) }

    /// Registers the phone's Face ID key with the runner and returns its id. On every connection it
    /// registers `again`: the runner keeps a known key's id, and a reinstalled runner learns it anew.
    func registerDevice(again: Bool = false) async throws -> String {
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
