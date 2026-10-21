import Foundation
import OSLog
import UserNotifications
import WatchConnectivity
import WatchKit
import WidgetKit

/// The watch's view of the runner, through the iPhone (apps/ios/app/WatchRelay.swift): the jobs the
/// phone keeps here, and the requests it carries out. What they say to each other is in
/// apps/shared/WatchWire.swift. With the phone out of reach, a paired watch calls the runner's Watch
/// API itself (apps/watch/WatchLink.swift), and goes back to the phone once it's in reach again.
@Observable
final class Watch: NSObject {
    enum Talk: Equatable {
        case none
        /// The mic is open; the words appear as they're said.
        case recording
        /// Stopped: the last of the audio is on its way, and the final words come back.
        case sending
        /// The words, kept: Send asks Oby, the mic adds more.
        case draft(String)
        case thinking(String)
        /// Dictated while the phone was out of reach: the phone plans it when it's back.
        case queued(String)
        case question(said: String, Question)
        /// What Oby said: the work it started (#269) is in the jobs, with nothing to confirm.
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
    private(set) var offline = false
    private(set) var lastSeen: Date?
    /// The Watch API, once the iPhone paired this watch with the runner.
    private(set) var link = WatchLink.saved
    /// Oby is on screen: only then does the watch follow the runner's events itself.
    @ObservationIgnored private var isOnScreen = false
    @ObservationIgnored private var following: Task<Void, Never>?
    var talk: Talk = .none
    /// The steps of Oby's turn for the ask under way, kept after its answer arrives: short lines
    /// under Oby (#304). Empty from a runner without steps.
    private(set) var steps: [TurnStep] = []
    /// The runner's turn the steps belong to: the first one that arrives for the ask.
    @ObservationIgnored private var stepTurn: String?
    /// Why Stop didn't go through, or nil.
    private(set) var stopProblem: String?
    /// What this time listening has said so far; the draft's earlier words are `earlier`.
    private(set) var words = ""
    private(set) var level = 0.0
    /// Why the last words couldn't be written down, under the draft that kept the rest.
    private(set) var notice: String?
    /// A failed live connection offers the system's input on the next tap.
    var useDictation = false
    /// The microphone, open only while `talk` is `.recording`.
    let recorder = Recorder()
    /// The draft's words from before this time listening; the new ones join them.
    @ObservationIgnored private var earlier = ""
    /// The audio not yet sent. It can hold the whole 60 seconds: a slow line delays the words
    /// rather than dropping them.
    @ObservationIgnored private var voiceBacklog = Data()
    /// Wakes the sender when audio arrives; finished when listening stops.
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
    var offlineLine: String {
        let time = lastSeen.map { $0.formatted(date: .omitted, time: .shortened) } ?? "never"
        return "Your Mac is asleep or offline. Last seen \(time)"
    }
    /// The runner directly, while the phone is out of reach.
    private var direct: WatchLink? { reachable ? nil : link }
    /// Live words come from the phone, or from the runner when paired.
    var canTalk: Bool { reachable || paired }
    /// The draft as it reads now: its earlier words, then what's being said.
    var heard: String { Self.join(earlier, words) }

    var needing: [Job] { jobs.filter(\.needsYou) }
    /// Running, or getting ready to: not the jobs waiting their turn (#238).
    var working: [Job] { jobs.filter(\.isWorking) }
    var waiting: [Job] { jobs.filter(\.isWaiting) }
    /// What needs you first, then what's running, then what waits.
    var shown: [Job] { needing + working + waiting }

    /// "1 needs you · 2 working · 14 waiting", or "All quiet": what Oby's pose says, for VoiceOver.
    var line: String {
        var parts: [String] = []
        if !needing.isEmpty { parts.append(needing.count == 1 ? "1 needs you" : "\(needing.count) need you") }
        if !working.isEmpty { parts.append("\(working.count) working") }
        if let queued = Summary.waitingLine(waiting.count) { parts.append(queued) }
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
        offline = false
        lastSeen = context.sentAt
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
            offline = false
            lastSeen = .now
            saveGlance()
        } catch {
            offline = true
            Logger.watch.error("fetching the jobs from the runner failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The complications and the Smart Stack (apps/watch/Widget) draw from the app group.
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
                        case .step(let step): take(step)
                        case .cleared, .inbox, .turn, .conversation, .delta, .artifact, .routine, .github, .transcript: break
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

    /// Allow, Always allow or Deny on what a job's agent waits for; words go with a deny.
    func answer(_ job: Job, _ decision: RunnerPermission.Decision, message: String? = nil) async throws {
        guard let permission = job.permission else { return }
        if let link = direct {
            apply(try await link.answer(job.id, permission: permission.id, decision, message: message))
        } else {
            var request: [String: Any] = [WatchWire.kind: WatchWire.Kind.permission.rawValue, WatchWire.job: job.id,
                                          WatchWire.permission: permission.id, WatchWire.decision: decision.rawValue]
            if let message { request[WatchWire.text] = message }
            try apply(try await self.request(request))
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

    /// Starts a job waiting for its `startWhen` now (#216).
    func startNow(_ id: String) async throws {
        if let link = direct {
            apply(try await link.startNow(id))
        } else {
            try apply(try await request([WatchWire.kind: WatchWire.Kind.start.rawValue, WatchWire.job: id]))
        }
    }

    /// Moves a job to another tool, account or model; the runner picks what's left nil.
    func move(_ id: String, agent: String? = nil, account: String? = nil, model: String? = nil) async throws {
        if let link = direct {
            apply(try await link.move(id, agent: agent, account: account, model: model))
        } else {
            var message: [String: Any] = [WatchWire.kind: WatchWire.Kind.move.rawValue, WatchWire.job: id]
            message[WatchWire.agent] = agent
            message[WatchWire.account] = account
            message[WatchWire.model] = model
            try apply(try await request(message))
        }
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

    /// The mic's tap. The microphone opens at once, with no await, so the next tap can always close
    /// it. A draft keeps its words and the new ones join them; any other answer on Home gives way.
    func listen() {
        guard talk != .recording, talk != .sending else { return }
        var draft = ""
        if case .draft(let text) = talk { draft = text }
        cancel()
        do {
            let rate = try recorder.start(deliver: { [weak self] audio, level in self?.stream(audio, level: level) },
                                          limit: { [weak self] in self?.stopListening() })
            beginVoice(sampleRate: rate, after: draft)
        } catch {
            recorder.cancel()
            if recorder.allowed == true { useDictation = true }
            keep(draft, notice: error.localizedDescription)
        }
    }

    /// Stop, the 60-second limit, the screen turning off or leaving Home: the microphone closes now,
    /// and the final words become the draft. Nothing is sent.
    func stopListening() {
        guard talk == .recording else { return }
        // Audio captured before the stop but not yet received is the end of the last word.
        let heard = recorder.stop()
        guard heard >= 0.4 || !words.isEmpty else {
            // A tap and a stop right after: nothing was said.
            let draft = earlier
            cancel()
            keep(draft, notice: nil)
            return
        }
        talk = .sending
        level = 0
        voiceInput?.finish()
        voiceInput = nil
    }

    /// Send: the draft goes to Oby, as a typed request would.
    func sendDraft() {
        guard case .draft(let text) = talk else { return }
        ask(text)
    }

    /// The system's dictation or scribble: its words join the draft, as spoken ones do.
    func dictated(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        var draft = ""
        if case .draft(let text) = talk { draft = text } else { cancel() }
        keep(Self.join(draft, said), notice: nil)
    }

    /// One ordered, acknowledged stream each time the mic listens. Each chunk waits for the reply
    /// before the next; when the line is slow, the backlog goes in bigger chunks (up to
    /// `chunkLimit`) to catch up. The phone sends the live words as `transcript` messages; the
    /// runner answers each piece with them.
    private func beginVoice(sampleRate: Double, after draft: String) {
        useDictation = false
        let id = UUID().uuidString
        asking = id
        earlier = draft
        words = ""
        level = 0
        notice = nil
        talk = .recording
        voiceBacklog = Data()
        let (stream, input) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        voiceInput = input
        let link = direct
        voiceTask = Task {
            do {
                try Task.checkCancellation()
                var sequence = 0
                let said: String
                if let link {
                    // The phone is out of reach: the runner's Whisper writes it down. A runner
                    // without it says so at the first piece, and the system's dictation takes over.
                    let send: (Data, Int) async throws -> Void = { audio, sequence in
                        let text = try await link.speech(request: id, sequence: sequence, audio: audio)
                        if let text, self.asking == id, self.talk == .recording || self.talk == .sending { self.words = text }
                    }
                    for await _ in stream { try await sendBacklog(id, sequence: &sequence, send: send) }
                    try await sendBacklog(id, sequence: &sequence, send: send)
                    guard asking == id else { return }
                    said = try await link.speech(request: id, sequence: sequence, audio: Data(), final: true) ?? words
                } else {
                    _ = try await request([WatchWire.kind: WatchWire.Kind.voiceStart.rawValue,
                                           WatchWire.request: id, WatchWire.sampleRate: sampleRate])
                    let send: (Data, Int) async throws -> Void = { audio, sequence in
                        _ = try await self.request([WatchWire.kind: WatchWire.Kind.voiceChunk.rawValue,
                                                    WatchWire.request: id, WatchWire.sequence: sequence,
                                                    WatchWire.audio: audio])
                    }
                    for await _ in stream { try await sendBacklog(id, sequence: &sequence, send: send) }
                    // The stream finishes on Stop; the last of the audio may have come with it.
                    try await sendBacklog(id, sequence: &sequence, send: send)
                    guard asking == id else { return }
                    let reply = try await request([WatchWire.kind: WatchWire.Kind.voiceEnd.rawValue,
                                                   WatchWire.request: id, WatchWire.sequence: sequence])
                    guard let text = reply[WatchWire.text] as? String else {
                        throw RunnerError(message: "Your iPhone sent no final words back.")
                    }
                    said = text
                }
                guard asking == id, talk == .sending else { return }
                let final = said.trimmingCharacters(in: .whitespacesAndNewlines)
                let draft = earlier
                // Written down: the line has nothing left to drop.
                asking = nil
                cancel()
                keep(Self.join(draft, final), notice: final.isEmpty ? "Oby didn't catch that. Tap the mic to try again." : nil)
            } catch let unavailable as WatchLink.SpeechUnavailable {
                guard asking == id, !Task.isCancelled else { return }
                let kept = heard
                cancel()
                useDictation = true
                keep(kept, notice: unavailable.message + " Tap the mic to dictate instead.")
            } catch {
                guard asking == id, !Task.isCancelled else { return }
                // The session may know the phone is gone before its reachability update arrives.
                let connectionFailed = link == nil && (!reachable || !WCSession.default.isReachable
                    || (error as NSError).domain == WCErrorDomain)
                let kept = heard
                cancel()
                // A paired watch goes to the runner on the next tap instead.
                useDictation = connectionFailed && !paired
                keep(kept, notice: error.localizedDescription + (useDictation ? " Tap the mic to dictate instead." : " Tap the mic to try again."))
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

    private func stream(_ audio: Data, level: Double) {
        guard talk == .recording, let input = voiceInput else { return }
        self.level = level
        // The recorder stops at the limit; this only bounds a runaway (61 s of audio, ~1.9 MB).
        guard voiceBacklog.count + audio.count <= Int(WatchWire.voiceSampleRate) * WatchWire.voiceSampleBytes * (WatchWire.voiceSeconds + 1) else { return }
        voiceBacklog.append(audio)
        input.yield()
    }

    /// The words kept so far become the draft, with why the rest couldn't be; with no words,
    /// the reason alone.
    private func keep(_ text: String, notice: String?) {
        if text.isEmpty {
            talk = notice.map(Talk.reply) ?? .none
            self.notice = nil
        } else {
            talk = .draft(text)
            self.notice = notice
        }
    }

    /// Earlier words and new ones, with a space between when neither has one.
    nonisolated static func join(_ earlier: String, _ new: String) -> String {
        guard !earlier.isEmpty else { return new }
        guard !new.isEmpty else { return earlier }
        return earlier.last!.isWhitespace || new.first!.isWhitespace ? earlier + new : earlier + " " + new
    }

    /// Typed, or a draft sent.
    func ask(_ words: String) {
        // One fallback input doesn't permanently replace the live mic on a reachable phone.
        useDictation = false
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        notice = nil
        plan(said, answer: nil)
    }

    /// The user picked one of the brain's options.
    func answer(_ option: String, said: String, question: Question) {
        plan(said, answer: (question.text, option))
    }

    /// A jobs tap or notification leaves Home: listening stops and keeps its words. It doesn't
    /// dismiss an answer, a draft or a queued ask.
    func leaveHome() {
        stopListening()
    }

    /// The phone went out of reach while an unpaired watch was listening through it: what was
    /// heard stays, and the mic opens the system's dictation next.
    private func lostPhone() {
        guard !reachable, !paired, talk == .recording || talk == .sending else { return }
        let kept = heard
        cancel()
        useDictation = true
        keep(kept, notice: "Your iPhone isn't in reach. Tap the mic to dictate instead.")
    }

    func cancel() {
        let id = asking
        asking = nil
        recorder.cancel()
        voiceInput?.finish()
        voiceInput = nil
        voiceTask?.cancel()
        voiceTask = nil
        voiceBacklog = Data()
        earlier = ""
        words = ""
        level = 0
        notice = nil
        talk = .none
        forgetSteps()
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
        forgetSteps()
        var message: [String: Any] = [WatchWire.kind: WatchWire.Kind.plan.rawValue, WatchWire.said: said, WatchWire.request: request]
        if let answer {
            message[WatchWire.question] = answer.question
            message[WatchWire.option] = answer.option
        }
        if !reachable, let link {
            talk = .thinking(said)
            Task {
                do {
                    let result = try await link.plan(said, answer: answer)
                    guard asking == request else { return }
                    asking = nil
                    // The work it started (#269) shows in the jobs at once.
                    if case .reply(_, let started) = result { for job in started { apply(job) } }
                    show(RelayedPlan(result))
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

    private func forgetSteps() {
        steps = []
        stepTurn = nil
        stopProblem = nil
    }

    /// A step of the turn the ask under way started, from the runner's events or the phone: only
    /// the first turn that shows up while the watch waits, not another device's.
    private func take(_ step: TurnStep) {
        if stepTurn == nil {
            guard case .thinking = talk else { return }
        } else if stepTurn != step.turn {
            return
        }
        stepTurn = step.turn
        steps = ConversationModel.placed(step, in: steps)
    }

    /// Stop: the runner ends the turn Oby is working on (#304), straight from the watch or through
    /// the phone, and what ran shows as ended.
    func stopTurn() async {
        do {
            if let link = direct {
                try await link.stopConversation()
            } else {
                _ = try await request([WatchWire.kind: WatchWire.Kind.stopTurn.rawValue])
            }
            stopProblem = nil
            steps = ConversationModel.settled(steps)
        } catch {
            stopProblem = error.localizedDescription
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
        case .step:
            guard let id = message[WatchWire.request] as? String, id == asking || stepTurn != nil,
                  let data = message[WatchWire.step] as? Data, let step = try? Runner.decoder.decode(TurnStep.self, from: data) else { return }
            take(step)
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
        // The answer is here: a step whose end was missed is done.
        steps = ConversationModel.settled(steps, as: .done)
        if let question = plan.question { talk = .question(said: plan.questionSaid ?? "", question) }
        else if let reply = plan.reply { talk = .reply(reply) }
        else { talk = .none }
    }

    // MARK: Pairing and pushes

    /// What the phone asks while it pairs this watch (apps/ios/app/WatchPairing.swift), or unpairs it.
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

    /// The complications' token, until the runner has accepted the latest one (apps/shared/WidgetToken.swift).
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
            self.offline = !reachable && self.link == nil
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
            if reachable { self.offline = false }
            if reachable { self.useDictation = false } else { self.lostPhone() }
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
