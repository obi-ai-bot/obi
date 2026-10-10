import AVFoundation
import Observation
import OSLog
import Speech
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

    /// The phone's local notification that finishes a publish the watch asked for while Oby
    /// was in the background: its Publish action is the app's own.
    static let approve = "approve"

    private var phone: Phone?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    /// Called once, when the app launches, so the session is up before the watch's first message.
    func start(_ phone: Phone) {
        guard self.phone == nil, let session else { return }
        self.phone = phone
        session.delegate = self
        session.activate()
        follow()
    }

    /// Pushes the jobs to the watch whenever the phone's change (the runner's events, a dispatch,
    /// a publish). Observation fires once per change, so it's armed again after each.
    private func follow() {
        guard let phone else { return }
        withObservationTracking {
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

    private func pushContext() {
        guard let phone else { return }
        push(WatchContext(jobs: phone.jobs, accounts: phone.accounts, host: phone.host, sentAt: .now))
    }

    private func push(_ context: WatchContext) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext([WatchWire.context: try Self.fit(context)])
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
    /// so those jobs and the ones that finished in the last two days go, without the long texts,
    /// and the oldest are dropped until it fits.
    nonisolated static func fit(_ context: WatchContext, limit: Int = WatchWire.limit) throws -> Data {
        var context = context
        let cutoff = Date.now.addingTimeInterval(-2 * 86400)
        context.jobs = context.jobs
            .filter { $0.isActive || $0.needsYou || ($0.finished ?? .distantPast) > cutoff }
            .prefix(20)
            .map { job in
                var job = job
                job.notes = nil
                job.request = String(job.request.prefix(300))
                job.summary = String(job.summary.prefix(600))
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
                return [WatchWire.context: try Self.fit(context)]
            case .voice:
                guard let audio = message[WatchWire.audio] as? Data else { return bad }
                let said = try await Self.transcribe(audio)
                guard !said.isEmpty else { return [WatchWire.error: "Oby didn't catch that."] }
                Task { await self.plan(said, answer: nil, request: request) }
                return [WatchWire.text: said]
            case .plan:
                guard let said = message[WatchWire.said] as? String else { return bad }
                var answer: (question: String, option: String)?
                if let question = message[WatchWire.question] as? String, let option = message[WatchWire.option] as? String {
                    answer = (question, option)
                }
                Task { await self.plan(said, answer: answer, request: request) }
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
            case .publishAction:
                guard let id = message[WatchWire.job] as? String else { return bad }
                return [WatchWire.action: try await phone.runner.publishAction(id)]
            case .publish:
                guard let id = message[WatchWire.job] as? String, let action = message[WatchWire.action] as? String else { return bad }
                Task { await self.publish(id, action: action) }
                return [WatchWire.ok: true]
            case .planned, .published:
                return bad
            }
        } catch {
            return [WatchWire.error: error.localizedDescription]
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

    private func askOnPhone(_ id: String, action: String) async throws {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else {
            throw RunnerError(message: "Open Oby on your iPhone to publish with Face ID.")
        }
        var categories = await center.notificationCategories()
        if !categories.contains(where: { $0.identifier == Self.approve }) {
            let publish = UNNotificationAction(identifier: Notifications.publish, title: "Publish with Face ID", options: [.authenticationRequired, .foreground])
            categories.insert(UNNotificationCategory(identifier: Self.approve, actions: [publish], intentIdentifiers: []))
            center.setNotificationCategories(categories)
        }
        let content = UNMutableNotificationContent()
        content.title = "Publish from your watch"
        content.body = action
        content.categoryIdentifier = Self.approve
        content.userInfo = ["job": id]
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: "\(Self.approve)-\(id)", content: content, trigger: nil))
    }

    /// A message to the watch app while it's up, else queued for the next time it is.
    private func send(_ message: [String: Any]) {
        guard let session else { return }
        guard session.isReachable else { session.transferUserInfo(message); return }
        session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
    }

    // MARK: Spoken on the watch, written here

    /// SpeechAnalyzer on device, in the phone's language. The first time, the speech model has to
    /// come down: that starts here, and the watch is told to try again.
    nonisolated static func transcribe(_ audio: Data) async throws -> String {
        let file = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString).m4a")
        try audio.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw RunnerError(message: "Your iPhone can't write down \(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "this language") yet.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Task.detached { try await request.downloadAndInstall() }
            }
            throw RunnerError(message: "Your iPhone is getting the speech model. Try again in a minute.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let recording = try AVAudioFile(forReading: file)
        async let text = try transcriber.results.reduce(into: AttributedString()) { $0 += $1.text }
        if let last = try await analyzer.analyzeSequence(from: recording) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let written = try await text
        return String(written.characters).trimmingCharacters(in: .whitespacesAndNewlines)
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
        Task { @MainActor in replyHandler(await self.answer(message)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in _ = await self.answer(message) }
    }

    /// Queued on the watch while this phone was out of reach (a dictated request): its answer
    /// goes back the same way.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in _ = await self.answer(userInfo) }
    }
}
