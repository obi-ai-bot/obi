import Observation
import OSLog
import UIKit
import UserNotifications
import WatchConnectivity

/// The watch can't reach the tailnet, so this phone stands between it and the runner
/// (Shared/WatchWire.swift says what they tell each other). It keeps the jobs on the watch as the
/// WatchConnectivity application context, on every change, and carries out what the watch asks
/// (plan, dispatch, publish, a message to a job) as the app itself does. iOS wakes Oby in the
/// background for a message from the watch, so this works with the phone in a pocket.
///
/// Publish needs this phone's Face ID key: the watch asks, the phone signs. Spoken requests come
/// as audio and are written down here, on device (watchOS has no SpeechAnalyzer).
final class WatchRelay: NSObject {
    static let shared = WatchRelay()

    private var phone: Phone?
    private var liveVoice: PhoneSpeech?
    private var preparingVoice: String?
    private var planning: [String: Task<Void, Never>] = [:]
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    /// Called once, when the app launches, so the session is up before the watch's first message.
    func start(_ phone: Phone) {
        guard self.phone == nil, let session else { return }
        self.phone = phone
        session.delegate = self
        session.activate()
        follow()
        // Clear done on the phone hides finished jobs; the watch hides the same ones at once.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { _ in
            Task { @MainActor in
                guard self.clearedAt != self.pushedClearedAt else { return }
                self.pushContext()
            }
        }
    }

    /// Pushes the jobs to the watch whenever the phone's change (the runner's events, a dispatch,
    /// a publish). Observation fires once per change, so it's armed again after each.
    private func follow() {
        guard let phone else { return }
        withObservationTracking {
            _ = phone.loaded
            _ = phone.jobs
            _ = phone.accounts
            _ = phone.host
        } onChange: {
            Task { @MainActor in
                self.pushContext()
                self.follow()
            }
        }
    }

    // MARK: The jobs on the watch

    /// Only once the phone has a list: before that, an empty one would wipe the watch's.
    private func pushContext() {
        guard let phone, phone.loaded else { return }
        push(WatchContext(jobs: phone.jobs, accounts: phone.accounts, host: phone.host, sentAt: .now))
    }

    /// Clear done on the phone's Home (iOS/Home.swift): finished jobs up to this time are hidden.
    private var clearedAt: Date { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "home.clearedAt")) }
    /// The Clear done time the watch's list was last trimmed with.
    private var pushedClearedAt: Date?

    private func push(_ context: WatchContext) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            let clearedAt = clearedAt
            try session.updateApplicationContext([WatchWire.context: try Self.fit(context, clearedAt: clearedAt)])
            pushedClearedAt = clearedAt
        } catch {
            Logger.phone.error("keeping the jobs on the watch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The jobs as the runner has them now, on the watch. For a request handled while Oby is in
    /// the background, when its own list isn't live.
    private func refresh() async -> WatchContext? {
        guard let phone else { return nil }
        do {
            var host = phone.host
            var accounts = phone.accounts
            if host.isEmpty, let status = try? await phone.runner.status() {
                host = status.runner.host
                accounts = status.accounts
            }
            let context = WatchContext(jobs: try await phone.runner.jobs(), accounts: accounts, host: host, sentAt: .now)
            push(context)
            return context
        } catch {
            Logger.phone.error("fetching the jobs for the watch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// WatchConnectivity carries about 65 KB. The watch shows what needs you and what's running,
    /// so those jobs go first, then the ones that finished in the last two days, without the long
    /// texts; the list is cut at 20 and then from the end until it fits, so what needs you stays.
    /// A job hidden by Clear done on the phone (`clearedAt`), or one that failed over a week ago,
    /// doesn't count as needing you on the wrist either.
    nonisolated static func fit(_ context: WatchContext, clearedAt: Date = .distantPast, now: Date = .now, limit: Int = WatchWire.limit) throws -> Data {
        var context = context
        let jobs = context.jobs
        func finished(_ job: Job, after date: Date) -> Bool { (job.finished ?? now) > date }
        let needing = jobs.filter { $0.needsYou && finished($0, after: max(clearedAt, now.addingTimeInterval(-7 * 86400))) }
        let recent = jobs.filter { !$0.needsYou && !$0.isActive && finished($0, after: max(clearedAt, now.addingTimeInterval(-2 * 86400))) }
        context.jobs = (needing + jobs.filter { $0.isActive && !$0.needsYou } + recent)
            .prefix(20)
            .map { job in
                var job = job
                job.notes = nil
                job.request = String(job.request.prefix(300))
                job.summary = String(job.summary.prefix(600))
                // A plan to approve can be long: the wrist gets its start.
                if let plan = job.question?.plan, plan.count > 1500 { job.question?.plan = String(plan.prefix(1500)) + "…" }
                return job
            }
        while true {
            let data = try Runner.encoder.encode(context)
            if data.count <= limit || context.jobs.isEmpty { return data }
            context.jobs.removeLast()
        }
    }

    // MARK: What the watch asks

    /// Answers one message from the watch. Fast things are answered in the reply; planning and
    /// publishing are acknowledged, and their outcome comes as a message of its own (`send`).
    private func answer(_ message: [String: Any]) async -> [String: Any] {
        guard let phone, let kind = (message[WatchWire.kind] as? String).flatMap(WatchWire.Kind.init(rawValue:)) else {
            return [WatchWire.error: "Your iPhone didn't understand the watch."]
        }
        let bad: [String: Any] = [WatchWire.error: "The watch's message was incomplete."]
        let request = message[WatchWire.request] as? String ?? ""
        do {
            switch kind {
            case .refresh:
                guard let context = await refresh() else { return [WatchWire.error: "Your iPhone can't reach the runner."] }
                return [WatchWire.context: try Self.fit(context, clearedAt: clearedAt)]
            case .voice:
                guard let audio = message[WatchWire.audio] as? Data else { return bad }
                let said = try await PhoneSpeech.transcribe(audio, context: PhoneSpeech.context(repos: phone.jobs.map(\.repo)))
                guard !said.isEmpty else { return [WatchWire.error: "Oby didn't catch that."] }
                startPlan(said, answer: nil, request: request)
                return [WatchWire.text: said]
            case .voiceStart:
                guard !request.isEmpty, let rate = message[WatchWire.sampleRate] as? Double,
                      rate == WatchWire.voiceSampleRate else { return bad }
                liveVoice?.cancel()
                liveVoice = nil
                preparingVoice = request
                defer { if preparingVoice == request { preparingVoice = nil } }
                let live = try await PhoneSpeech.make(request: request, sampleRate: rate, context: PhoneSpeech.context(repos: phone.jobs.map(\.repo))) { [weak self] text in
                    // Live words have no meaning after this hold: never queue them.
                    guard let self, self.liveVoice?.request == request,
                          let session = self.session, session.isReachable else { return }
                    session.sendMessage([WatchWire.kind: WatchWire.Kind.transcript.rawValue,
                                         WatchWire.request: request, WatchWire.text: text], replyHandler: nil, errorHandler: nil)
                }
                guard preparingVoice == request else { live.cancel(); return bad }
                liveVoice = live
                return [WatchWire.ok: true]
            case .voiceChunk:
                guard let live = liveVoice, live.request == request,
                      let sequence = message[WatchWire.sequence] as? Int,
                      let audio = message[WatchWire.audio] as? Data else { return bad }
                do { try live.append(audio, sequence: sequence) }
                catch { live.cancel(); liveVoice = nil; throw error }
                return [WatchWire.ok: true]
            case .voiceEnd:
                guard let live = liveVoice, live.request == request,
                      let sequence = message[WatchWire.sequence] as? Int else { return bad }
                defer { if liveVoice === live { liveVoice = nil } }
                let said = try await live.finish(sequence: sequence)
                guard liveVoice === live, !live.cancelled else { return bad }
                // Only the words: the watch keeps them as a draft, and its Send is a `plan`.
                return [WatchWire.text: said]
            case .voiceCancel:
                if preparingVoice == request { preparingVoice = nil }
                if liveVoice?.request == request { liveVoice?.cancel(); liveVoice = nil }
                planning.removeValue(forKey: request)?.cancel()
                return [WatchWire.ok: true]
            case .plan:
                guard let said = message[WatchWire.said] as? String else { return bad }
                var answer: (question: String, option: String)?
                if let question = message[WatchWire.question] as? String, let option = message[WatchWire.option] as? String {
                    answer = (question, option)
                }
                startPlan(said, answer: answer, request: request)
                return [WatchWire.ok: true]
            case .dispatch:
                guard let data = message[WatchWire.draft] as? Data else { return bad }
                let draft = try Runner.decoder.decode(Draft.self, from: data)
                let job = try await phone.runner.dispatch(draft.job)
                Notifications.ask()
                _ = await refresh()
                return [WatchWire.job: try Runner.encoder.encode(job)]
            case .tell:
                guard let id = message[WatchWire.job] as? String, let text = message[WatchWire.text] as? String else { return bad }
                let job = try await phone.runner.tell(id, text)
                _ = await refresh()
                return [WatchWire.job: try Runner.encoder.encode(job)]
            case .stop:
                guard let id = message[WatchWire.job] as? String else { return bad }
                let job = try await phone.runner.stop(id)
                _ = await refresh()
                return [WatchWire.job: try Runner.encoder.encode(job)]
            case .dismiss:
                guard let id = message[WatchWire.job] as? String else { return bad }
                let job = try await phone.runner.dismiss(id)
                _ = await refresh()
                return [WatchWire.job: try Runner.encoder.encode(job)]
            case .start:
                guard let id = message[WatchWire.job] as? String else { return bad }
                let job = try await phone.runner.startNow(id)
                _ = await refresh()
                return [WatchWire.job: try Runner.encoder.encode(job)]
            case .permission:
                guard let id = message[WatchWire.job] as? String, let prompt = message[WatchWire.permission] as? String,
                      let decision = (message[WatchWire.decision] as? String).flatMap(RunnerPermission.Decision.init(rawValue:)) else { return bad }
                let job = try await phone.runner.answer(id, permission: prompt, decision, message: message[WatchWire.text] as? String)
                _ = await refresh()
                return [WatchWire.job: try Runner.encoder.encode(job)]
            case .move:
                guard let id = message[WatchWire.job] as? String else { return bad }
                let job = try await phone.runner.move(id, agent: message[WatchWire.agent] as? String, account: message[WatchWire.account] as? String,
                                                      model: message[WatchWire.model] as? String)
                _ = await refresh()
                return [WatchWire.job: try Runner.encoder.encode(job)]
            case .publishAction:
                guard let id = message[WatchWire.job] as? String else { return bad }
                return [WatchWire.action: try await phone.runner.publishAction(id)]
            case .publish:
                guard let id = message[WatchWire.job] as? String, let action = message[WatchWire.action] as? String else { return bad }
                Task { await self.inBackground("publish") { await self.publish(id, action: action) } }
                return [WatchWire.ok: true]
            case .transcript, .planned, .published, .pairKey, .paired, .unpaired:
                return bad
            }
        } catch {
            return [WatchWire.error: error.localizedDescription]
        }
    }

    private func startPlan(_ said: String, answer: (question: String, option: String)?, request: String) {
        planning[request]?.cancel()
        planning[request] = Task {
            defer { planning[request] = nil }
            await inBackground("plan") { await plan(said, answer: answer, request: request) }
        }
    }

    /// Asks the brain, then tells the watch. The brain takes up to about 20 seconds, longer than
    /// a reply may wait for.
    private func plan(_ said: String, answer: (question: String, option: String)?, request: String) async {
        guard let phone else { return }
        var message: [String: Any] = [WatchWire.kind: WatchWire.Kind.planned.rawValue, WatchWire.request: request, WatchWire.said: said]
        do {
            message[WatchWire.plan] = try Runner.encoder.encode(RelayedPlan(try await phone.runner.plan(said, answer: answer)))
        } catch {
            message[WatchWire.error] = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        send(message)
    }

    /// Signs the publish with this phone's Face ID key, as the app does, and tells the watch how
    /// it went. Face ID can't come up while Oby is in the background, so then a notification on
    /// the phone finishes it: its Publish is the app's own (iOS/Notifications.swift).
    private func publish(_ id: String, action: String) async {
        guard let phone else { return }
        var message: [String: Any] = [WatchWire.kind: WatchWire.Kind.published.rawValue, WatchWire.job: id]
        do {
            if UIApplication.shared.applicationState == .active {
                message[WatchWire.url] = try await phone.publish(id, action: action).absoluteString
            } else {
                try await askOnPhone(id, action: action)
                message[WatchWire.pending] = "Face ID is on your iPhone: open Oby's notification there."
            }
        } catch {
            message[WatchWire.error] = error.localizedDescription
        }
        send(message)
        _ = await refresh()
    }

    /// The "approve" category is registered at launch with the others (iOS/Notifications.swift),
    /// so the button is there however long the notification waits.
    private func askOnPhone(_ id: String, action: String) async throws {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else {
            throw RunnerError(message: "Open Oby on your iPhone to publish with Face ID.")
        }
        let content = UNMutableNotificationContent()
        content.title = "Publish from your watch"
        content.body = action
        content.categoryIdentifier = Notifications.approve
        content.userInfo = ["job": id]
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: "\(Notifications.approve)-\(id)", content: content, trigger: nil))
    }

    /// iOS wakes Oby in the background for the watch and suspends it again soon after the reply:
    /// this asks for the time to finish (planning, a publish, writing a recording down) first.
    private func inBackground<T>(_ name: String, _ work: () async -> T) async -> T {
        let app = UIApplication.shared
        // The expiration handler ends the task it belongs to, so it has to see the id set below it.
        nonisolated(unsafe) var task = UIBackgroundTaskIdentifier.invalid
        task = app.beginBackgroundTask(withName: name) {
            app.endBackgroundTask(task)
            task = .invalid
        }
        defer { if task != .invalid { app.endBackgroundTask(task) } }
        return await work()
    }

    /// A message to the watch app while it's up, else queued for the next time it is.
    private func send(_ message: [String: Any]) {
        guard let session else { return }
        guard session.isReachable else { session.transferUserInfo(message); return }
        session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
    }

}

// The session calls back on its own queue; everything hops to the main actor.
extension WatchRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if let error { Logger.phone.error("the watch session didn't activate: \(error.localizedDescription, privacy: .public)") }
        Task { @MainActor in self.pushContext() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched watches: the session comes up again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushContext() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in replyHandler(await self.inBackground("answer the watch") { await self.answer(message) }) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in _ = await self.inBackground("answer the watch") { await self.answer(message) } }
    }

    /// Queued on the watch while this phone was out of reach (a dictated request): its answer
    /// goes back the same way.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in _ = await self.inBackground("answer the watch") { await self.answer(userInfo) } }
    }
}
