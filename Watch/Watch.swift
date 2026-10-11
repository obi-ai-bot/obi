import Foundation
import OSLog
import UserNotifications
import WatchConnectivity
import WatchKit
import WidgetKit

/// The watch's view of the runner, through the iPhone (iOS/WatchRelay.swift): the jobs the
/// phone keeps here, and the requests it carries out. What they say to each other is in
/// Shared/WatchWire.swift. With the phone out of reach, a paired watch calls the runner's Watch
/// API itself (Watch/WatchLink.swift), and goes back to the phone once it's in reach again.
@Observable
final class Watch: NSObject {
    enum Talk: Equatable {
        case none
        case recording
        /// The recording is on its way to the phone, to be written down.
        case sending
        case thinking(String)
        /// Dictated while the phone was out of reach: the phone plans it when it's back.
        case queued(String)
        case plan([Draft])
        case question(said: String, Question)
        case reply(String)
    }

    private(set) var jobs: [Job] = []
    private(set) var accounts: [Account] = []
    private(set) var host = ""
    /// The jobs arrived at least once, so an empty list really is empty.
    private(set) var loaded = false
    /// The phone is near and answers now. Without it, a paired watch calls the runner itself;
    /// an unpaired one queues requests until the phone is back.
    private(set) var reachable = false
    /// The Watch API, once the iPhone paired this watch with the runner.
    private(set) var link = WatchLink.saved
    /// Oby is on screen: only then does the watch follow the runner's events itself.
    @ObservationIgnored private var isOnScreen = false
    @ObservationIgnored private var following: Task<Void, Never>?
    var talk: Talk = .none
    private(set) var words = ""
    private(set) var level = 0.0
    /// A failed live connection offers the system's input on the next tap.
    var useDictation = false
    /// The hold's audio not yet sent. It can hold the whole hold: a slow phone delays the words
    /// rather than dropping the request.
    @ObservationIgnored private var voiceBacklog = Data()
    /// Wakes the sender when audio arrives; finished when the hold ends.
    @ObservationIgnored private var voiceInput: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    /// The job a notification asked to open; Home opens it.
    var opening: String?
    /// The job whose notification's Publish was tapped; its screen asks for the crown once it's ready.
    var publishing: String?
    /// How a publish the phone is carrying out went, by job id.
    private(set) var outcomes: [String: String] = [:]

    /// The ask whose plan is awaited, so an older one's answer is ignored. Kept across launches:
    /// a queued ask may be answered after the app was closed.
    @ObservationIgnored private var asking: String? {
        get { UserDefaults.standard.string(forKey: "watch.asking") }
        set { UserDefaults.standard.set(newValue, forKey: "watch.asking") }
    }
    /// The system woke the app because the phone sent something; each ends once it's delivered.
    @ObservationIgnored private var deliveries: [WKWatchConnectivityRefreshBackgroundTask] = []

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        load(session.receivedApplicationContext)
    }

    // MARK: What Home shows

    /// Paired with the runner: the watch works without its iPhone.
    var paired: Bool { link != nil }
    /// The runner directly, while the phone is out of reach.
    private var direct: WatchLink? { reachable ? nil : link }
    /// Hold-to-talk works through the phone, or through the runner when paired.
    var canTalk: Bool { reachable || paired }

    var needing: [Job] { jobs.filter(\.needsYou) }
    var working: [Job] { jobs.filter(\.isActive) }
    /// What needs you first, then what's running.
    var shown: [Job] { needing + working }

    /// "1 needs you · 2 working", or "All quiet": what Oby's pose says, for VoiceOver.
    var line: String {
        var parts: [String] = []
        if !needing.isEmpty { parts.append(needing.count == 1 ? "1 needs you" : "\(needing.count) need you") }
        if !working.isEmpty { parts.append("\(working.count) working") }
        return parts.isEmpty ? "All quiet" : parts.joined(separator: " · ")
    }

    func account(_ id: String) -> String { accounts.first { $0.id == id }?.name ?? id }

    // MARK: The jobs

    /// Asks the phone for the jobs as the runner has them now, or the runner itself when the
    /// phone is out of reach; the context the phone keeps here is the fallback.
    func refresh() {
        if reachable {
            Task {
                if let reply = try? await request([WatchWire.kind: WatchWire.Kind.refresh.rawValue]) { load(reply) }
            }
        } else if let link {
            Task { await fetch(link) }
        }
        if paired { Task { await uploadWidgetToken() } }
    }

    private func load(_ dictionary: [String: Any]) {
        guard let data = dictionary[WatchWire.context] as? Data,
              let context = try? Runner.decoder.decode(WatchContext.self, from: data) else { return }
        jobs = context.jobs
        accounts = context.accounts
        host = context.host
        loaded = true
        saveGlance()
    }

    /// The jobs from the runner, trimmed as the phone trims them: what needs you, what's working,
    /// and what finished in the last two days.
    private func fetch(_ link: WatchLink) async {
        do {
            let now = Date.now
            let all = try await link.jobs()
            let recent = all.filter { !$0.needsYou && !$0.isActive && ($0.finished ?? now) > now.addingTimeInterval(-2 * 86400) }
            jobs = Array((all.filter(\.needsYou) + all.filter { $0.isActive && !$0.needsYou } + recent).prefix(20))
            loaded = true
            saveGlance()
        } catch {
            Logger.watch.error("fetching the jobs from the runner failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The complications and the Smart Stack (Watch/Widget) draw from the app group.
    private func saveGlance() {
        if Glance.save(Glance.of(jobs)) {
            WidgetCenter.shared.reloadTimelines(ofKind: Glance.kind)
        }
    }

    /// Oby came on screen or left it.
    func onScreen(_ active: Bool) {
        isOnScreen = active
        follow()
        if active { refresh() }
    }

    /// While Oby is on screen and the phone is out of reach, the runner's events keep the jobs
    /// current (watchOS streams only for an app on screen). Reconnects after a drop.
    private func follow() {
        guard isOnScreen, let link = direct else {
            following?.cancel()
            following = nil
            return
        }
        guard following == nil else { return }
        following = Task {
            while !Task.isCancelled {
                do {
                    for try await event in link.events() {
                        switch event {
                        case .connected: await fetch(link)
                        case .job(let job):
                            apply(job)
                            saveGlance()
                        case .accounts(let accounts): self.accounts = accounts
                        case .cleared, .inbox: break
                        }
                    }
                } catch {
                    Logger.watch.error("the runner's events stopped: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The phone sent the job list while the app wasn't in front: the session hands it to `load`,
    /// which updates the complications, and the task ends once nothing more is pending.
    func finishWhenDelivered(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        deliveries.append(task)
        finishDelivered()
    }

    private func finishDelivered() {
        let session = WCSession.default
        guard !deliveries.isEmpty, session.activationState == .activated, !session.hasContentPending else { return }
        for task in deliveries { task.setTaskCompletedWithSnapshot(false) }
        deliveries.removeAll()
    }

    private func apply(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
    }

    private func apply(_ reply: [String: Any]) throws {
        guard let data = reply[WatchWire.job] as? Data else { throw RunnerError(message: "Your iPhone sent no job back.") }
        apply(try Runner.decoder.decode(Job.self, from: data))
    }

    /// A notification was tapped: open its job, and publish it if that's what was tapped.
    func open(_ id: String, publish: Bool) {
        opening = id
        publishing = publish ? id : nil
    }

    func dispatch(_ draft: Draft) async throws {
        let previous = talk
        try await send(draft)
        if talk == previous { talk = .none }
    }

    /// One dispatch per draft, in order; a draft whose job is here already was sent before.
    func dispatch(all drafts: [Draft]) async throws {
        let previous = talk
        for draft in drafts where !jobs.contains(where: { $0.id == draft.job.id }) {
            try await send(draft)
        }
        if talk == previous { talk = .none }
    }

    private func send(_ draft: Draft) async throws {
        if let link = direct {
            apply(try await link.dispatch(draft.job))
        } else {
            try apply(try await request([WatchWire.kind: WatchWire.Kind.dispatch.rawValue, WatchWire.draft: try Runner.encoder.encode(draft)]))
        }
    }

    /// The Watch API has no Stop: that waits for the phone.
    func stop(_ id: String) async throws {
        guard direct == nil else { throw RunnerError(message: "Stopping a job needs your iPhone in reach.") }
        try apply(try await request([WatchWire.kind: WatchWire.Kind.stop.rawValue, WatchWire.job: id]))
    }

    func tell(_ id: String, _ text: String) async throws {
        if let link = direct {
            apply(try await link.tell(id, text))
        } else {
            try apply(try await request([WatchWire.kind: WatchWire.Kind.tell.rawValue, WatchWire.job: id, WatchWire.text: text]))
        }
    }

    /// Lets go of a job that needs you: it then needs nothing.
    func dismiss(_ id: String) async throws {
        if let link = direct {
            apply(try await link.dismiss(id))
        } else {
            try apply(try await request([WatchWire.kind: WatchWire.Kind.dismiss.rawValue, WatchWire.job: id]))
        }
        saveGlance()
    }

    /// The exact sentence publishing this job would carry out.
    func publishAction(_ id: String) async throws -> String {
        if let link = direct { return try await link.publishAction(id) }
        guard let action = try await request([WatchWire.kind: WatchWire.Kind.publishAction.rawValue, WatchWire.job: id])[WatchWire.action] as? String else {
            throw RunnerError(message: "Your iPhone sent no action back.")
        }
        return action
    }

    /// The phone signs with Face ID and publishes; how it went arrives as a `published` message.
    /// Without the phone, the crown's turn is the approval: the watch's signed request carries it.
    func publish(_ id: String, action: String) async throws {
        if let link = direct {
            outcomes[id] = "Publishing…"
            do {
                _ = try await link.publish(id, action: action)
                outcomes[id] = "Published: the pull request is open."
                apply(try await link.job(id))
                saveGlance()
            } catch {
                outcomes[id] = nil
                throw error
            }
            return
        }
        outcomes[id] = "Publishing on your iPhone…"
        do {
            _ = try await request([WatchWire.kind: WatchWire.Kind.publish.rawValue, WatchWire.job: id, WatchWire.action: action])
        } catch {
            outcomes[id] = nil
            throw error
        }
    }

    // MARK: Talking to Oby

    /// One ordered, acknowledged stream per hold. Each chunk waits for the phone's reply; when
    /// the phone is slow, the backlog goes in bigger chunks (up to `chunkLimit`) to catch up.
    func beginVoice(sampleRate: Double) {
        useDictation = false
        let id = UUID().uuidString
        asking = id
        words = ""
        level = 0
        talk = .recording
        voiceBacklog = Data()
        let (stream, input) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        voiceInput = input
        let link = direct
        voiceTask = Task {
            do {
                try Task.checkCancellation()
                if let link {
                    // The phone is out of reach: the pieces go to the runner. It can't write speech
                    // down yet and says so at the first one, so the system's dictation takes over.
                    let send: (Data, Int) async throws -> Void = { try await link.speech(request: id, sequence: $1, audio: $0) }
                    var sequence = 0
                    for await _ in stream { try await sendBacklog(id, sequence: &sequence, send: send) }
                    try await sendBacklog(id, sequence: &sequence, send: send)
                    throw WatchLink.SpeechUnavailable(message: "Speech-to-text isn't set up on the runner yet.")
                }
                _ = try await request([WatchWire.kind: WatchWire.Kind.voiceStart.rawValue,
                                       WatchWire.request: id, WatchWire.sampleRate: sampleRate])
                let send: (Data, Int) async throws -> Void = { audio, sequence in
                    _ = try await self.request([WatchWire.kind: WatchWire.Kind.voiceChunk.rawValue,
                                                WatchWire.request: id, WatchWire.sequence: sequence,
                                                WatchWire.audio: audio])
                }
                var sequence = 0
                for await _ in stream { try await sendBacklog(id, sequence: &sequence, send: send) }
                // The stream finishes on release; the last of the audio may have come with it.
                try await sendBacklog(id, sequence: &sequence, send: send)
                guard asking == id else { return }
                let reply = try await request([WatchWire.kind: WatchWire.Kind.voiceEnd.rawValue,
                                               WatchWire.request: id, WatchWire.sequence: sequence])
                guard asking == id else { return }
                guard let said = reply[WatchWire.text] as? String else {
                    throw RunnerError(message: "Your iPhone sent no final words back.")
                }
                words = said
                if talk == .sending { talk = .thinking(said) }
            } catch let unavailable as WatchLink.SpeechUnavailable {
                guard asking == id, !Task.isCancelled else { return }
                cancel()
                useDictation = true
                talk = .reply(unavailable.message + " Tap the mic to dictate instead.")
            } catch {
                guard asking == id, !Task.isCancelled else { return }
                // The session may know the phone is gone before its reachability update arrives.
                let connectionFailed = !reachable || !WCSession.default.isReachable
                    || (error as NSError).domain == WCErrorDomain
                cancel()
                useDictation = connectionFailed
                talk = .reply(error.localizedDescription + (connectionFailed ? " Tap the mic to dictate instead." : ""))
            }
        }
    }

    /// Sends what's waiting, in order, each chunk after the last was acknowledged.
    private func sendBacklog(_ id: String, sequence: inout Int, send: (Data, Int) async throws -> Void) async throws {
        while true {
            try Task.checkCancellation()
            guard asking == id else { throw CancellationError() }
            guard !voiceBacklog.isEmpty else { return }
            let audio = Data(voiceBacklog.prefix(WatchWire.chunkLimit))
            voiceBacklog.removeFirst(audio.count)
            try await send(audio, sequence)
            sequence += 1
        }
    }

    func stream(_ audio: Data, level: Double) {
        guard talk == .recording, let input = voiceInput else { return }
        self.level = level
        // The recorder stops at the limit; this only bounds a runaway (16 s of audio, ~512 KB).
        guard voiceBacklog.count + audio.count <= Int(WatchWire.voiceSampleRate) * WatchWire.voiceSampleBytes * (WatchWire.voiceSeconds + 1) else { return }
        voiceBacklog.append(audio)
        input.yield()
    }

    func endVoice() {
        guard talk == .recording else { return }
        talk = .sending
        level = 0
        voiceInput?.finish()
        voiceInput = nil
    }

    /// Dictated or typed.
    func ask(_ words: String) {
        // One fallback input doesn't permanently replace hold-to-talk on a reachable phone.
        useDictation = false
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        plan(said, answer: nil)
    }

    /// The user picked one of the brain's options.
    func answer(_ option: String, said: String, question: Question) {
        plan(said, answer: (question.text, option))
    }

    /// A jobs tap or notification leaves Home without dismissing its answer or queued ask.
    func leaveHome() {
        if talk == .recording { cancel() }
    }

    func cancel() {
        let id = asking
        asking = nil
        voiceInput?.finish()
        voiceInput = nil
        voiceTask?.cancel()
        voiceTask = nil
        voiceBacklog = Data()
        words = ""
        level = 0
        talk = .none
        if let id {
            for transfer in WCSession.default.outstandingUserInfoTransfers
                where transfer.userInfo[WatchWire.request] as? String == id {
                transfer.cancel()
            }
        }
        if let id, reachable {
            Task { _ = try? await request([WatchWire.kind: WatchWire.Kind.voiceCancel.rawValue, WatchWire.request: id]) }
        }
    }

    private func plan(_ said: String, answer: (question: String, option: String)?) {
        let request = UUID().uuidString
        asking = request
        var message: [String: Any] = [WatchWire.kind: WatchWire.Kind.plan.rawValue, WatchWire.said: said, WatchWire.request: request]
        if let answer {
            message[WatchWire.question] = answer.question
            message[WatchWire.option] = answer.option
        }
        if !reachable, let link {
            talk = .thinking(said)
            Task {
                do {
                    let plan = RelayedPlan(try await link.plan(said, answer: answer))
                    guard asking == request else { return }
                    asking = nil
                    show(plan)
                } catch {
                    if asking == request, talk == .thinking(said) { talk = .reply(error.localizedDescription) }
                }
            }
            return
        }
        guard reachable else {
            WCSession.default.transferUserInfo(message)
            talk = .queued(said)
            return
        }
        talk = .thinking(said)
        Task {
            do {
                _ = try await self.request(message)
            } catch {
                if asking == request, talk == .thinking(said) { talk = .reply(error.localizedDescription) }
            }
        }
    }

    /// A message from the phone: the plan for the current ask, or how a publish went.
    private func take(_ message: [String: Any]) {
        guard let kind = (message[WatchWire.kind] as? String).flatMap(WatchWire.Kind.init(rawValue:)) else { return }
        switch kind {
        case .transcript:
            guard let id = message[WatchWire.request] as? String, id == asking,
                  talk == .recording || talk == .sending,
                  let text = message[WatchWire.text] as? String else { return }
            words = text
        case .planned:
            guard let request = message[WatchWire.request] as? String, request == asking else { return }
            asking = nil
            if let error = message[WatchWire.error] as? String {
                talk = .reply(error)
            } else if let data = message[WatchWire.plan] as? Data, let plan = try? Runner.decoder.decode(RelayedPlan.self, from: data) {
                show(plan)
            }
        case .published:
            guard let id = message[WatchWire.job] as? String else { return }
            if message[WatchWire.url] != nil { outcomes[id] = "Published: the pull request is open." }
            else if let pending = message[WatchWire.pending] as? String { outcomes[id] = pending }
            else if let error = message[WatchWire.error] as? String { outcomes[id] = error }
        default:
            break
        }
    }

    private func show(_ plan: RelayedPlan) {
        if !plan.drafts.isEmpty { talk = .plan(plan.drafts) }
        else if let question = plan.question { talk = .question(said: plan.questionSaid ?? "", question) }
        else if let reply = plan.reply { talk = .reply(reply) }
        else { talk = .none }
    }

    // MARK: Pairing and pushes

    /// What the phone asks while it pairs this watch (iOS/WatchPairing.swift), or unpairs it.
    private func answer(_ message: [String: Any]) -> [String: Any] {
        switch (message[WatchWire.kind] as? String).flatMap(WatchWire.Kind.init(rawValue:)) {
        case .pairKey:
            do {
                return [WatchWire.publicKey: try WatchLink.publicKey(), WatchWire.name: WKInterfaceDevice.current().name]
            } catch {
                return [WatchWire.error: error.localizedDescription]
            }
        case .paired:
            guard let watch = message[WatchWire.watch] as? String, let url = (message[WatchWire.url] as? String).flatMap(URL.init(string:)),
                  let clientID = message[WatchWire.clientID] as? String, let clientSecret = message[WatchWire.clientSecret] as? String else {
                return [WatchWire.error: "The pairing was incomplete."]
            }
            do {
                try WatchLink.save(WatchLink.Pairing(watch: watch, url: url, clientID: clientID, clientSecret: clientSecret))
            } catch {
                return [WatchWire.error: error.localizedDescription]
            }
            link = WatchLink.saved
            askForAlerts()
            follow()
            return [WatchWire.ok: true]
        case .unpaired:
            // Only this watch's own pairing: the phone may be removing another watch.
            if let watch = message[WatchWire.watch] as? String, link?.pairing.watch == watch {
                WatchLink.forget()
                link = nil
                follow()
            }
            return [WatchWire.ok: true]
        default:
            take(message)
            return [WatchWire.ok: true]
        }
    }

    /// Alerts straight from the runner, the same ones the phone gets: asks once, then registers
    /// for this watch's own device token (WatchNotifications hands it to `registerPush`).
    func askForAlerts() {
        guard paired else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            WKApplication.shared().registerForRemoteNotifications()
        }
    }

    /// Hands the runner this watch's device token, and the complications' WidgetKit token when
    /// the widget has one.
    func registerPush(_ token: Data) async {
        guard let link else { return }
        let topic = Bundle.main.bundleIdentifier ?? ""
        do {
            _ = try await link.registerPush(token, kind: "alert", topic: topic)
        } catch {
            Logger.watch.error("handing the runner the push token failed: \(error.localizedDescription, privacy: .public)")
        }
        await uploadWidgetToken()
    }

    /// The complications' token, until the runner has accepted the latest one (Shared/WidgetToken.swift).
    private func uploadWidgetToken() async {
        guard let link else { return }
        Glance.appTopic = Bundle.main.bundleIdentifier ?? ""
        if !(await Glance.uploadWidgetToken(link, attempts: 3)) {
            Logger.watch.error("the runner hasn't taken the complications' push token yet; trying again next time")
        }
    }

    // MARK: The line to the phone

    /// Sends one message and waits for its reply; an `error` in the reply is thrown.
    private func request(_ message: [String: Any]) async throws -> [String: Any] {
        let session = WCSession.default
        guard session.activationState == .activated else { throw RunnerError(message: "Still connecting to your iPhone.") }
        guard session.isReachable else { throw RunnerError(message: "Your iPhone isn't in reach.") }
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(message) { continuation.resume(returning: $0) } errorHandler: { continuation.resume(throwing: $0) }
        }
        if let error = reply[WatchWire.error] as? String { throw RunnerError(message: error) }
        return reply
    }
}

// The session calls back on its own queue; everything hops to the main actor.
extension Watch: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if let error { Logger.watch.error("the phone session didn't activate: \(error.localizedDescription, privacy: .public)") }
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.load(context)
            self.reachable = reachable
            if reachable { self.useDictation = false }
            self.follow()
            self.refresh()
            self.finishDelivered()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if reachable { self.useDictation = false }
            self.follow()
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in replyHandler(self.answer(message)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.load(applicationContext)
            self.finishDelivered()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.take(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            self.take(userInfo)
            self.finishDelivered()
        }
    }
}

extension Logger {
    nonisolated static let watch = Logger(subsystem: "com.deskree.oby", category: "watch")
}
