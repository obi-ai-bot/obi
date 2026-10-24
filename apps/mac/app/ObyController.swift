import AppKit
import Foundation
import OSLog
import UserNotifications

/// What Oby does outside its window: the runner's feed and this Mac's desk, the talk key and its
/// pill, Stop all, and the alerts that open the window on a job. Nothing of it draws over the screen
/// but the pill.
final class IslandController {
    let desk = Desk()
    let feed = RunnerFeed()
    /// Sparkle (apps/mac/app/Updater.swift).
    let updater = Updater()
    /// Reach this Mac from anywhere (#285): Settings › Remote access and the tunnel it runs.
    let remote = RemoteAccess()
    let availability = MacAvailability()
    let model: IslandModel
    let talkKey = TalkKey()
    let stopAllKey = StopAllKey()
    private var pill: TalkPillPanel?
    /// Handing kept hook deliveries to obid (#1315): the 5-minute loop, a try running now, and the
    /// queue key registered last.
    private var collecting: Task<Void, Never>?
    private var handing = false
    private var registeredKey: String?
    private var observingAvailability = false
    /// Every repository the user pushed to lately: names the voice listens for. Fetched when you
    /// first talk, and again each time until it works.
    private var repos: [String] = []
    /// The last words sent were hands-free (fn + Space): once Oby's reply shows, it listens again.
    private var handsFreeAsk = false
    /// Oby is listening again after its reply, by itself: a press with no words ends it quietly.
    private var relistening = false
    /// Takes the reply off the pill after `TalkStage.replyShows`.
    private var fading: Task<Void, Never>?
    /// Opens the Oby window (apps/mac/app/App/ChatWindow.swift), on a job's screen when one is named: the
    /// app sets it.
    var openWindow: (_ job: (id: String, local: Bool)?) -> Void = { _ in }
    /// The window (or first launch) is up, in front, and showing what you say and Oby's answer: the
    /// pill stays away then. The app sets it.
    var windowShowsTalk: () -> Bool = { false }
    /// The window is in front on the conversation page: what you say carries on there. Anywhere
    /// else it goes to the latest conversation (#493). The app sets it.
    var windowShowsConversation: () -> Bool = { false }

    init() {
        desk.issueSync.enabled = true
        model = IslandModel(desk: desk, feed: feed, updater: updater, availability: availability)
        model.remote = remote
        model.vault = .shared
        // A restart never interrupts a check this Mac runs for the runner.
        updater.busy = { [weak feed] in feed?.checks.current != nil }
        feed.onLive = { [weak self] in self?.collectKept() }
        remote.onConnected = { [weak self] in self?.collectKept() }
        // Oby's answer the pill shows doesn't alert as well (#862).
        feed.pillShowsTalk = { [weak self] in self?.showsTalkReply ?? false }
    }

    /// The talk key's turn shows Oby's reply: it's on its way (Thinking: the pill shows it, unless the
    /// conversation page in front does), or the pill shows it now.
    private var showsTalkReply: Bool { model.turn == .thinking || (model.reply != nil && pill?.isVisible == true) }

    /// Deliveries the control plane kept while this Mac or its obid was away (#1315): at once
    /// whenever obid comes up (at launch, after a restart or sleep) or the tunnel does, and every
    /// 5 minutes after, since the Worker also keeps what came while obid answered 5xx with the Mac
    /// awake. Only while remote access is on, with obid on this Mac.
    func collectKept() {
        if collecting == nil {
            collecting = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    await self?.handOverKept()
                }
            }
        }
        Task { await handOverKept() }
    }

    /// One try, one at a time: obid's queue key registered when it isn't yet, then what was kept.
    /// An obid or control plane with no queue yet (404) is left alone.
    private func handOverKept() async {
        guard !handing, remote.on, remote.hostname != nil, feed.local, let obid = feed.runner,
              let signer = try? remote.signer() else { return }
        handing = true
        defer { handing = false }
        do {
            let key = try await obid.queueKey()
            if key != registeredKey {
                try await remote.plane.setQueueKey(key, signer)
                registeredKey = key
            }
            try await HookQueue.collect(plane: remote.plane, signer: signer, obid: obid)
        } catch let old as RunnerError where old.status == 404 {
        } catch let old as ControlPlane.Failure where old.status == 404 {
        } catch {
            Logger.remote.error("kept deliveries: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start() {
        availability.startMonitoring()
        observeAvailability()
        // Remote access: obid runs the tunnel (#896); a token an older Oby kept goes to obid once.
        Task { await remote.start() }
        // What needs you on this Mac's jobs is an alert, as the runner's are (RunnerFeed.post); a click opens the window on it.
        desk.onFinish = { job in
            if job.waitsForYou { Self.alert(job.doneLine, id: job.id, local: job.id) }
        }
        desk.onInboxChange = { item in
            if item.kind == .question, item.isOpen, item.later == nil { Self.alert("Question: \(item.title)", id: item.id, local: item.job.isEmpty ? nil : item.job) }
        }
        // The brain's briefing takes in the runner's jobs, inbox and accounts too, and "stop" reaches its jobs.
        desk.elsewhere = { [weak self] in
            guard let self else { return [] }
            return [Briefing.Place(name: feed.name, jobs: feed.jobs, inbox: feed.briefingInbox, accounts: feed.accounts)]
        }
        desk.loadSettingOptions = {
            guard let codex = try? await CodexAgent.models(home: nil), !codex.isEmpty else { return nil }
            return (["claude": AgentModels.claude.map(\.0), "codex": codex.map(\.id)],
                    ["claude": AgentModels.claudeEfforts, "codex": Array(Set(codex.flatMap(\.efforts))).sorted()],
                    ["codex": Dictionary(uniqueKeysWithValues: codex.map { ($0.id, $0.efforts) })])
        }
        desk.stopElsewhere = { [weak self] ids in
            guard let self else { return [:] }
            var failed: [String: String] = [:]
            for id in ids {
                do {
                    guard feed.runner != nil else { throw RunnerError(message: "\(feed.name) isn't set up.") }
                    feed.apply(try await feed.about(id) { try await $0.stop(id) })
                } catch {
                    failed[id] = error.localizedDescription
                }
            }
            return failed
        }
        desk.moveElsewhere = { [weak self] id, target, why in
            guard let self, feed.runner != nil else { throw RunnerError(message: "The runner isn't set up.") }
            let job = try await feed.about(id) { try await $0.move(id, agent: target.agent, account: target.account, model: target.model, why: why) }
            feed.apply(job)
            return job
        }
        desk.liftElsewhereReserve = { [weak self] id, lift in
            guard let self, let runner = try? feed.acting() else { return false }
            do {
                _ = try await runner.liftReserve(id, lift)
                return true
            } catch { return false }
        }
        // "Allow it", "no, run only the runner tests" and "stop asking on the Watch job" reach the
        // runner's jobs too (#134): a permission through its answer, a plan through the job's words,
        // as its card would send them.
        desk.answerElsewhere = { [weak self] job, decision, message in
            guard let self, let runner = feed.runner else { return "The runner isn't set up." }
            if feed.showingKept { return RunnerFeed.reconnecting }
            do {
                if job.question?.plan != nil {
                    let words = decision == .deny ? (message ?? PermissionPolicy.changeIt) : "Approve: \(PermissionMode.acceptEdits.title)"
                    feed.apply(try await runner.tell(job.id, words))
                    return nil
                }
                guard let permission = job.permission?.id ?? feed.extras[job.id]?.permission?.id,
                      let answer = RunnerPermission.Decision(rawValue: decision.rawValue) else { return "It isn't waiting for your OK any more." }
                feed.apply(try await runner.answer(job.id, permission: permission, answer, message: message))
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        desk.modeElsewhere = { [weak self] job, mode in
            guard let self, let choice = RunnerMode(rawValue: mode.rawValue) else { return "The runner isn't set up." }
            do {
                try await feed.setMode(job.id, choice)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        // "Try it again", "let it go", "answer the merge item: try again" and "start it now" reach the
        // runner's jobs and inbox as the apps' own buttons do (#300).
        desk.actElsewhere = { [weak self] remote in
            guard let self else { throw RunnerError(message: "The runner isn't set up.") }
            try await feed.act(remote)
        }
        desk.onReply = { [weak self] text, spoken in self?.replied(text, spoken: spoken) }
        desk.plansElsewhere = { [weak self] in self?.feed.local ?? false }
        desk.planElsewhere = { [weak self] said, answer in
            guard let self else { throw RunnerError(message: "Oby is closing.") }
            return try await feed.plan(said, answer: answer)
        }
        desk.planElsewhereWithAttachments = { [weak self] said, answer, attachments in
            guard let self else { throw RunnerError(message: "Oby is closing.") }
            return try await feed.plan(said, answer: answer, attachments: attachments)
        }
        desk.cancelElsewhere = { [weak self] in await self?.feed.cancelPlan() }
        feed.onFollow = { [weak self] local in
            self?.desk.issueSync.enabled = !local
            self?.availability.setRunnerEnabled(local)
            self?.updateAvailability()
        }
        feed.start()
        Task { await desk.refresh() }
        talkKey.on = { [weak self] in self?.talk($0) }
        talkKey.start()
        stopAllKey.on = { [weak self] in self?.stopAll() }
        stopAllKey.start()
        model.voice.prepare()
    }

    private func updateAvailability() {
        availability.setRunningJobs(!desk.active.isEmpty || (feed.local && !feed.active.isEmpty) || feed.checks.current != nil)
    }

    /// Observation fires once per change, so re-register after updating the assertion. This keeps
    /// Oby idle with its window closed, instead of polling the runner and the local desk on a timer.
    private func observeAvailability() {
        guard !observingAvailability else { return }
        observingAvailability = true
        withObservationTracking {
            _ = desk.active
            _ = feed.active
            _ = feed.local
            _ = feed.checks.current
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                observingAvailability = false
                updateAvailability()
                observeAvailability()
            }
        }
        updateAvailability()
    }

    /// Stop all (⌃⌥⌘. or the menu): every job on this Mac and on the runner stops now, and an alert
    /// says how many.
    func stopAll() {
        let here = desk.stopAll()
        Task {
            var line: String
            do {
                let there = try await feed.runner?.stopAll()
                for job in there?.jobs ?? [] { feed.apply(job) }
                let stopped = here + (there?.stopped ?? 0)
                line = stopped == 0 ? "Nothing is running." : "Stopped \(stopped) job\(stopped == 1 ? "" : "s")."
            } catch {
                line = "Stopped \(here) here. Couldn't reach the runner: \(error.localizedDescription)"
            }
            Self.alert(line, id: "stop-all")
        }
    }

    /// The talk key: a turn starts, with the pill while the window isn't showing it, and what you
    /// said goes to the planner as if typed.
    private func talk(_ event: TalkKey.Event) {
        let voice = model.voice
        switch event {
        case .press:
            // The reply the pill shows goes, and VoiceOver stops reading it: you come first.
            if model.reply != nil { Self.announce(" ") }
            hideReply()
        case .start(let key):
            relistening = false
            listen(key: key)
        case .handsFree:
            voice.handsFree = true
        case .send:
            let key = voice.key
            let again = relistening
            relistening = false
            handsFreeAsk = voice.handsFree
            // The microphone closes now; the words are written down while the pill says it's thinking.
            // Until they're known, no conversation's answer is the pill's.
            feed.talking(nil)
            setTurn(.thinking)
            voice.finish { [weak self] said in self?.heard(said, key: key, again: again) }
        case .cancel:
            relistening = false
            handsFreeAsk = false
            voice.cancel()
            stopListening()
        }
    }

    private func listen(key: TalkKey.Key) {
        // Your own jobs' repositories first: they're the ones you're likeliest to name.
        model.voice.start(key: key, context: Voice.context(repos: desk.jobs.map(\.repo) + repos))
        if repos.isEmpty { Task { repos = (try? await Workspace.knownRepos()) ?? [] } }
        model.listening = true
        setTurn(.listening)
    }

    /// Oby answered what you said: the pill shows the reply's first lines in writing, never aloud
    /// (the owner's decision of 2026-10-23), and in hands-free mode Oby listens again for yours at once,
    /// unless the talk key is down already: that press is yours, and it isn't taken over.
    private func replied(_ text: String, spoken: Bool) {
        guard spoken else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing to show: the turn ends, and nothing listens again.
            if model.turn == .thinking { setTurn(nil) }
            return
        }
        model.reply = Alerts.lines(text)
        fading?.cancel()
        fading = Task { [weak self] in
            try? await Task.sleep(for: TalkStage.replyShows)
            guard !Task.isCancelled else { return }
            self?.hideReply()
        }
        let stage = TalkStage.afterReply(handsFree: handsFreeAsk, keyDown: talkKey.busy,
                                         talking: model.voice.phase != .idle || model.listening)
        if stage == .listening, talkKey.listenAgain() {
            relistening = true
            listen(key: model.voice.key)
            model.voice.handsFree = true
        } else if stage != nil {
            setTurn(.replied)
            // VoiceOver reads it out; not while a press is on its way to open the microphone.
            if !talkKey.busy { Self.announce(text) }
        }
    }

    /// VoiceOver says `text` now, cutting off what it was saying.
    private static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The reply leaves the pill, and the pill goes with it unless Oby is listening again (then it
    /// shows only where the window doesn't show what you say).
    private func hideReply() {
        fading?.cancel()
        fading = nil
        guard model.reply != nil else { return }
        model.reply = nil
        setTurn(model.turn == .replied ? nil : model.turn)
    }

    /// Whether the talk key's words go to the latest conversation (#493): said away from the
    /// conversation page. A bare "stop" or "never mind" sends nothing (Desk.ask), so it redirects
    /// nothing either: the next words, typed or said, go where they would have.
    nonisolated static func toLatest(_ said: String, showsConversation: Bool) -> Bool {
        !showsConversation && !Conversation.cancels(said)
    }

    /// `again`: the words came while Oby listened again by itself after its reply.
    private func heard(_ said: String, key: TalkKey.Key, again: Bool) {
        // A bare "stop" or "never mind" ends the turn and the hands-free listening, and no job
        // with it: Desk.ask sends nothing to the brain for it, so no reply shows and nothing
        // listens again.
        let cancels = Conversation.cancels(said)
        if cancels { handsFreeAsk = false }
        if !said.isEmpty {
            feed.conversations.nextToLatest = Self.toLatest(said, showsConversation: windowShowsConversation())
            if !cancels { feed.talking(said) }
            desk.ask(said, spoken: true)
        }
        // Talking again already: that's what shows.
        guard model.voice.phase == .idle, model.listening else { return }
        model.listening = false
        if said.isEmpty {
            let problem = model.voice.problem
            setTurn(nil)
            // A press that only ends Oby's listening again says nothing.
            if problem != nil || !again { Self.alert(problem ?? "Oby didn't catch that", id: "talk") }
        } else if cancels {
            setTurn(nil)
        } else {
            watchThinking()
            // Not in the voice's queue: the alert waits for you, and talking mustn't.
            if key == .fn { Task { GlobeKey.guideOnce() } }
        }
    }

    private func stopListening() {
        guard model.listening else { return }
        model.listening = false
        setTurn(nil)
    }

    /// The brain stops thinking without a reply to show (the turn was replaced or cancelled): the
    /// pill ends. A reply, or a question, shows in `replied`.
    /// Observation fires once, on the change: nothing runs while the pill is away.
    private func watchThinking() {
        withObservationTracking {
            _ = desk.talk
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, model.turn == .thinking, !model.listening else { return }
                if case .thinking = desk.talk { watchThinking(); return }
                // A reply or a question is `replied`'s to show, and it has been by now.
                setTurn(nil)
            }
        }
    }

    /// The turn's stage changes: the pill follows, unless the window is showing the turn. With no
    /// turn, no reply shows either, and no conversation's answer is the pill's.
    private func setTurn(_ stage: TalkStage?) {
        model.turn = stage
        if stage == nil {
            model.reply = nil
            feed.talking(nil)
        }
        if TalkStage.shows(stage, reply: model.reply != nil, windowShowsTalk: windowShowsTalk(),
                           windowShowsConversation: windowShowsConversation()) {
            let pill = pill ?? TalkPillPanel(model: model)
            self.pill = pill
            pill.place()
            pill.orderFrontRegardless()
        } else {
            pill?.orderOut(nil)
        }
    }

    // MARK: Alerts

    /// An alert for a job on this Mac, as the runner's (RunnerFeed.post): a click opens the window on it.
    static let localJobKey = "localJob"

    /// One alert, replacing an earlier one with the same `id`. `local`: the id of this Mac's job it is about.
    static func alert(_ title: String, id: String, local job: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        content.threadIdentifier = "jobs"
        if let job { content.userInfo = [localJobKey: job] }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            do { try await UNUserNotificationCenter.current().add(request) } catch {
                Logger.feed.error("posting an alert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
