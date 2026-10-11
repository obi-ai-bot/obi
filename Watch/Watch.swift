import Foundation
import OSLog
import WatchConnectivity
import WatchKit
import WidgetKit

/// The watch's view of the runner, through the iPhone (iOS/WatchRelay.swift): the jobs the
/// phone keeps here, and the requests it carries out. What they say to each other is in
/// Shared/WatchWire.swift.
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
    /// The phone is near and answers now. Without it, requests queue until it is.
    private(set) var reachable = false
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

    /// Asks the phone for the jobs as the runner has them now; the context it keeps here is
    /// the fallback.
    func refresh() {
        guard reachable else { return }
        Task {
            if let reply = try? await request([WatchWire.kind: WatchWire.Kind.refresh.rawValue]) { load(reply) }
        }
    }

    private func load(_ dictionary: [String: Any]) {
        guard let data = dictionary[WatchWire.context] as? Data,
              let context = try? Runner.decoder.decode(WatchContext.self, from: data) else { return }
        jobs = context.jobs
        accounts = context.accounts
        host = context.host
        loaded = true
        // The complications and the Smart Stack (Watch/Widget) draw from the app group.
        if Glance.save(Glance(needs: needing.count, working: working.count, top: needing.first?.heading)) {
            WidgetCenter.shared.reloadTimelines(ofKind: Glance.kind)
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
        try apply(try await request([WatchWire.kind: WatchWire.Kind.dispatch.rawValue, WatchWire.draft: try Runner.encoder.encode(draft)]))
        if talk == previous { talk = .none }
    }

    /// One dispatch per draft, in order; a draft whose job is here already was sent before.
    func dispatch(all drafts: [Draft]) async throws {
        let previous = talk
        for draft in drafts where !jobs.contains(where: { $0.id == draft.job.id }) {
            try apply(try await request([WatchWire.kind: WatchWire.Kind.dispatch.rawValue, WatchWire.draft: try Runner.encoder.encode(draft)]))
        }
        if talk == previous { talk = .none }
    }

    func stop(_ id: String) async throws {
        try apply(try await request([WatchWire.kind: WatchWire.Kind.stop.rawValue, WatchWire.job: id]))
    }

    func tell(_ id: String, _ text: String) async throws {
        try apply(try await request([WatchWire.kind: WatchWire.Kind.tell.rawValue, WatchWire.job: id, WatchWire.text: text]))
    }

    /// The exact sentence publishing this job would carry out.
    func publishAction(_ id: String) async throws -> String {
        guard let action = try await request([WatchWire.kind: WatchWire.Kind.publishAction.rawValue, WatchWire.job: id])[WatchWire.action] as? String else {
            throw RunnerError(message: "Your iPhone sent no action back.")
        }
        return action
    }

    /// The phone signs with Face ID and publishes; how it went arrives as a `published` message.
    func publish(_ id: String, action: String) async throws {
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
        voiceTask = Task {
            do {
                try Task.checkCancellation()
                _ = try await request([WatchWire.kind: WatchWire.Kind.voiceStart.rawValue,
                                       WatchWire.request: id, WatchWire.sampleRate: sampleRate])
                var sequence = 0
                for await _ in stream { try await sendBacklog(id, sequence: &sequence) }
                // The stream finishes on release; the last of the audio may have come with it.
                try await sendBacklog(id, sequence: &sequence)
                guard asking == id else { return }
                let reply = try await request([WatchWire.kind: WatchWire.Kind.voiceEnd.rawValue,
                                               WatchWire.request: id, WatchWire.sequence: sequence])
                guard asking == id else { return }
                guard let said = reply[WatchWire.text] as? String else {
                    throw RunnerError(message: "Your iPhone sent no final words back.")
                }
                words = said
                if talk == .sending { talk = .thinking(said) }
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

    /// Sends what's waiting, in order, each chunk after the phone acknowledged the last.
    private func sendBacklog(_ id: String, sequence: inout Int) async throws {
        while true {
            try Task.checkCancellation()
            guard asking == id else { throw CancellationError() }
            guard !voiceBacklog.isEmpty else { return }
            let audio = Data(voiceBacklog.prefix(WatchWire.chunkLimit))
            voiceBacklog.removeFirst(audio.count)
            _ = try await request([WatchWire.kind: WatchWire.Kind.voiceChunk.rawValue,
                                   WatchWire.request: id, WatchWire.sequence: sequence,
                                   WatchWire.audio: audio])
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
                if !plan.drafts.isEmpty { talk = .plan(plan.drafts) }
                else if let question = plan.question { talk = .question(said: plan.questionSaid ?? "", question) }
                else if let reply = plan.reply { talk = .reply(reply) }
                else { talk = .none }
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
            self.refresh()
            self.finishDelivered()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if reachable { self.useDictation = false }
            self.refresh()
        }
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
