import AppKit
import ApplicationServices
import SwiftUI
import WebKit

nonisolated enum IslandState { case compact, peek, open, listening }

/// The three surfaces available in the open notch.
nonisolated enum IslandTab: Int, CaseIterable, Sendable {
    case home, chat, settings

    var title: String { ["Home", "Chat", "Settings"][rawValue] }
    var symbol: String { ["house", "bubble.left.and.bubble.right", "gearshape"][rawValue] }
    var shortcut: Character { Character(String(rawValue + 1)) }
}

/// The island's state and its geometry, measured from the screen Oby lives on.
@Observable
final class IslandModel {
    static let tabKey = "island.lastTab"
    let desk: Desk
    let feed: RunnerFeed
    /// The update waiting to be installed, if any (Mac/Updater.swift): the open island's pill.
    let updater: Updater
    /// What you say while you hold fn.
    let voice = Voice()
    /// Oby's reply, spoken, when you talked (Mac/Speech.swift).
    let speaker = Speaker()
    /// What goes with the next request: screenshots, what you copied.
    let tray = Tray()
    var state: IslandState = .compact
    /// The camera's cutout, from the screen's top-left corner, or nil on a screen without one.
    var notch: CGRect?
    /// The width of the screen Oby lives on: the island is centered on it.
    var screenWidth: CGFloat = 0
    /// The menu bar's height, used for the pill on screens without a notch.
    var barHeight: CGFloat = 24
    /// The open island's height, measured from its content.
    var openHeight: CGFloat = 240
    /// A job just ended: the one line the notch shows for a few seconds.
    var notice: String?
    /// The runner's job a notification opened the island on, until the island closes.
    var focus: String?
    /// The runner's job whose alert's Publish was clicked: its screen starts publishing, once.
    var publishing: String?
    /// The last open-island surface. Home takes precedence when something needs attention.
    var tab: IslandTab

    init(desk: Desk, feed: RunnerFeed, updater: Updater = Updater()) {
        self.desk = desk
        self.feed = feed
        self.updater = updater
        tab = IslandTab(rawValue: UserDefaults.standard.integer(forKey: Self.tabKey)) ?? .home
    }

    func select(_ tab: IslandTab) {
        self.tab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
    }

    var needsYou: Bool { IslandInbox.waits(desk: desk, feed: feed) || desk.jobs.contains { $0.question != nil || $0.permission != nil } || feed.jobs.contains { $0.question != nil || $0.permission != nil } }
    var openingTab: IslandTab { needsYou ? .home : tab }

    /// Both chat surfaces read and send through this model.
    var thread: [Turn] { feed.conversation.thread(with: desk.turns) }
    /// The accounts a plan's card offers: the runner's when the runner on this Mac plans (#283),
    /// else this Mac's.
    var planAccounts: [AccountState] { (feed.local ? feed.accounts : desk.accounts.accounts).filter(\.signedIn) }
    var recentTurns: [Turn] { Array(thread.suffix(4)) }
    var chatWindowVisible = false
    var readReply: String?
    var unreadReply: Bool { thread.last(where: { $0.who == .oby }).map { $0.id != readReply } ?? false }

    func markChatRead() { readReply = thread.last(where: { $0.who == .oby })?.id }

    func sendChat(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        desk.ask(tray.note.map { "\(text)\n\n\($0)" } ?? text, shown: text, attachments: tray.paths)
        tray.clear()
    }

    func stopChatJob(_ id: String, local: Bool) {
        if local { desk.stop(id) }
        else { Task { if let job = try? await feed.about(id, { try await $0.stop(id) }) { feed.apply(job) } } }
    }

    /// Agents working now, on this Mac and on the runner: not the jobs waiting their turn (#238).
    var working: Int { desk.jobs.count(where: \.isWorking) + feed.working }
    /// Jobs queued behind something, on this Mac and on the runner (`Job.waiting`).
    var waiting: Int { desk.jobs.count(where: \.isWaiting) + feed.waiting }

    /// Whether the island lists a job: it isn't settled (`Job.settled`: still running, waiting,
    /// needing you or with its pull request open), or it finished after the last Clear done on any
    /// app. The runner keeps that time, and this Mac's own jobs go by it too.
    func lists(_ job: Job) -> Bool { job.listed(after: feed.clearedAt, among: desk.jobs + feed.jobs) }

    /// Clear done would take the job from the island (`Job.settled`).
    func clears(_ job: Job) -> Bool { job.clearable(among: desk.jobs + feed.jobs) }

    /// The one line the iPhone's Home says too (Shared/JobList.swift): who's working, and what
    /// needs you among the jobs listed.
    var summary: String {
        Summary.line(working: working, waiting: waiting, needs: NeedsYou.line((desk.jobs + feed.jobs).filter { lists($0) }))
    }

    /// What peeking shows next to Oby's name: a job that just ended, else the summary.
    var peekLine: String { notice ?? summary }

    /// Where everything sits inside the island now (Mac/IslandLayout.swift).
    var layout: IslandLayout {
        IslandLayout.of(state, screenWidth: screenWidth, notch: notch, barHeight: barHeight, line: peekLine, openHeight: openHeight)
    }

    var size: CGSize { layout.size }
}

/// Pins the island to the top center of the screen with the notch (or the main screen),
/// above the menu bar, on every Space, and passes clicks through everywhere else.
final class IslandController {
    let desk = Desk()
    let feed = RunnerFeed()
    /// Sparkle, and the island's "Update ready · Restart" (Mac/Updater.swift).
    let updater = Updater()
    /// Reach this Mac from anywhere (#285): Settings › Remote access and the tunnel it runs.
    let remote = RemoteAccess()
    let model: IslandModel
    let character = ObyCharacter()
    let talkKey = TalkKey()
    let stopAllKey = StopAllKey()
    private let panel = NotchPanel()
    private var timer: Timer?
    private var lastMouse: CGPoint?
    private var clickMonitor: Any?
    private var noticeTask: Task<Void, Never>?
    /// Every repository the user pushed to lately: names the voice listens for. Fetched when you
    /// first talk, and again each time until it works.
    private var repos: [String] = []
    /// The last words sent were hands-free (fn + Space): once Oby has spoken its reply, it listens again.
    private var handsFreeAsk = false
    /// Opens the Oby window (Mac/App/ChatWindow.swift), on a job's screen when one is named: the
    /// app sets it. The island's "Open Chat" button goes there.
    var openWindow: (_ job: (id: String, local: Bool)?) -> Void = { _ in }

    init() {
        desk.issueSync.enabled = true
        model = IslandModel(desk: desk, feed: feed, updater: updater)
        // A restart never interrupts a check this Mac runs for the runner.
        updater.busy = { [weak feed] in feed?.checks.current != nil }
    }

    func start() {
        panel.contentView = NSHostingView(rootView: IslandView(
            model: model, character: character,
            onOpen: { [weak self] in self?.open() },
            onClose: { [weak self] in self?.close() },
            onOpenWindow: { [weak self] job in
                self?.close()
                self?.openWindow(job)
            }))
        place()
        panel.orderFrontRegardless()
        character.pause(true)
        // Remote access was on: the tunnel runs again, as a child of this login item.
        remote.start()
        desk.onFinish = { [weak self] job in self?.notify(job.doneLine, happy: job.status == .done) }
        // A question from one of this Mac's jobs, as the runner's come (RunnerFeed.Notice.question).
        desk.onInboxChange = { [weak self] item in
            if item.kind == .question, item.isOpen, item.later == nil { self?.notify("Question: \(item.title)", happy: false) }
        }
        feed.onNotice = { [weak self] job, notice in self?.notify(RunnerFeed.title(notice, for: job), happy: notice == .ready && job.publishError == nil) }
        // The brain's briefing takes in the runner's jobs, inbox and accounts too, and "stop" reaches its jobs.
        desk.elsewhere = { [weak self] in
            guard let self else { return [] }
            return [Briefing.Place(name: feed.name, jobs: feed.jobs, inbox: feed.inbox, accounts: feed.accounts)]
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
        // "Allow it", "no, run only the runner tests" and "stop asking on the Watch job" reach the
        // runner's jobs too (#134): a permission through its answer, a plan through the job's words,
        // as its card would send them.
        desk.answerElsewhere = { [weak self] job, decision, message in
            guard let self, let runner = feed.runner else { return "The runner isn't set up." }
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
        feed.onFollow = { [weak self] local in self?.desk.issueSync.enabled = !local }
        feed.start()
        Task { await desk.refresh() }
        talkKey.on = { [weak self] in self?.talk($0) }
        talkKey.start()
        stopAllKey.on = { [weak self] in self?.stopAll() }
        stopAllKey.start()
        model.voice.prepare()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // ponytail: polling the mouse at 30 Hz is cheaper than it sounds and needs no permission
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A click in another app closes the open island. Clicks on the island are ours and never arrive here.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// Stop all (⌃⌥⌘. or the menu): every job on this Mac and on the runner stops now, and the
    /// notch says how many.
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
            notify(line, happy: true)
        }
    }

    /// A notification was clicked: the island opens on its job, and its Publish publishes it.
    func open(job id: String, publish: Bool = false) {
        model.focus = id
        model.publishing = publish ? id : nil
        open()
    }

    func open(tab: IslandTab? = nil) {
        model.notice = nil
        if model.focus != nil { model.select(.home) }
        else if let tab { model.select(tab) }
        else { model.select(model.openingTab) }
        set(.open)
        // Typing needs the keyboard; the panel takes it without activating Oby.
        panel.makeKey()
    }

    func close() {
        guard model.state == .open else { return }
        model.focus = nil
        model.publishing = nil
        set(.compact)
        // Hand the keyboard back to the app you were in.
        if panel.isKeyWindow { NSWorkspace.shared.frontmostApplication?.activate() }
    }

    private func set(_ state: IslandState) {
        guard model.state != state else { return }
        model.state = state
        character.pause(state == .compact)
    }

    /// The talk key: the island listens while it's held, and what you said goes to the planner as if typed.
    private func talk(_ event: TalkKey.Event) {
        let voice = model.voice
        switch event {
        case .press:
            // Whatever Oby was saying, you come first.
            model.speaker.stop()
        case .start(let key):
            noticeTask?.cancel()
            model.notice = nil
            listen(key: key)
        case .handsFree:
            voice.handsFree = true
        case .send:
            let key = voice.key
            handsFreeAsk = voice.handsFree
            voice.finish { [weak self] said in self?.heard(said, key: key) }
        case .cancel:
            handsFreeAsk = false
            voice.cancel()
            stopListening()
        }
    }

    private func listen(key: TalkKey.Key) {
        // Your own jobs' repositories first: they're the ones you're likeliest to name.
        model.voice.start(key: key, context: Voice.context(repos: desk.jobs.map(\.repo) + repos))
        if repos.isEmpty { Task { repos = (try? await Workspace.knownRepos()) ?? [] } }
        set(.listening)
    }

    /// Oby answered what you said: it speaks the reply (Settings › General), and in hands-free
    /// mode listens again for yours once it has finished.
    private func replied(_ text: String, spoken: Bool) {
        guard spoken, Speaker.on else { return }
        let again = handsFreeAsk
        let key = model.voice.key
        model.speaker.speak(text) { [weak self] heard in
            guard let self, heard, again, model.state == .open, model.voice.phase == .idle else { return }
            talkKey.listenAgain()
            listen(key: key)
            model.voice.handsFree = true
        }
    }

    private func heard(_ said: String, key: TalkKey.Key) {
        // A bare "stop" or "never mind" ends the turn and the hands-free listening, and no job
        // with it: Desk.ask sends nothing to the brain for it, so nothing is spoken and nothing
        // listens again.
        if Conversation.cancels(said) { handsFreeAsk = false }
        if !said.isEmpty { desk.ask(said, spoken: true) }
        // Talking again already: that's what the island shows.
        guard model.voice.phase == .idle, model.state == .listening else { return }
        if said.isEmpty {
            let problem = model.voice.problem
            stopListening()
            notify(problem ?? "Oby didn't catch that", happy: false)
        } else {
            open(tab: .chat)
            // Not in the voice's queue: the alert waits for you, and talking mustn't.
            if key == .fn { Task { GlobeKey.guideOnce() } }
        }
    }

    private func stopListening() {
        guard model.state == .listening else { return }
        set(.compact)
        if panel.isKeyWindow { NSWorkspace.shared.frontmostApplication?.activate() }
    }

    /// A job ended, or a runner's job needs you: say so in one line, with a face to match.
    private func notify(_ line: String, happy: Bool) {
        guard model.state != .open, model.state != .listening else { return }
        model.notice = line
        set(.peek)
        character.play(happy ? "Agree" : "Confused")
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { model.notice = nil }
        }
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func place() {
        guard let screen else { return }
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notch = CGRect(x: left.width, y: 0, width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            model.notch = nil
        }
        model.screenWidth = screen.frame.width
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        model.barHeight = bar > 0 ? bar : NSStatusBar.system.thickness
        let size = CGSize(width: 720, height: 760)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private var islandRect: NSRect {
        let size = model.size
        return NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let island = islandRect
        let inside = island.contains(mouse)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        switch model.state {
        case .compact where inside: set(.peek)
        case .peek where !inside && model.notice == nil: set(.compact)
        default: break
        }
        guard model.state != .compact, mouse != lastMouse else { return }
        lastMouse = mouse
        // oby.html reads the pointer relative to its own frame, which is tiny here: scale the
        // distance from Oby so far-away pointers turn the head a little, not all the way round.
        let frame = model.layout.character
        let x = max(-1, min(1, (mouse.x - (island.minX + frame.midX)) / 420))
        let y = max(-1, min(1, ((island.maxY - frame.midY) - mouse.y) / 260))
        character.point(at: CGPoint(x: (x + 1) / 2 * frame.width, y: (y + 1) / 2 * frame.height))
    }
}

/// A borderless panel that never activates Oby, so whatever you're working in keeps focus.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
}

struct IslandView: View {
    let model: IslandModel
    let character: ObyCharacter
    let onOpen: () -> Void
    let onClose: () -> Void
    /// Opens the Oby window, on a job when one is named (Mac/App/ChatWindow.swift).
    var onOpenWindow: (_ job: (id: String, local: Bool)?) -> Void = { _ in }

    private var mood: String {
        if model.state == .listening { return "listening" }
        if case .thinking = model.desk.talk { return "thinking" }
        return model.working == 0 ? "idle" : "working"
    }

    var body: some View {
        let layout = model.layout
        let size = layout.size
        let frame = layout.character
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: layout.radius, bottomTrailingRadius: layout.radius, style: .continuous)

        ZStack(alignment: .topLeading) {
            WebView(character.page)
                .webViewContentBackground(.hidden)
                .allowsHitTesting(model.state == .open)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .accessibilityLabel("Oby")

            // Agents working on this Mac and on the runner, in the right wing.
            if let count = layout.count, model.working > 0 {
                Text("\(model.working)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: count.width, height: count.height, alignment: .trailing)
                    .offset(x: count.minX, y: count.minY)
                    .accessibilityLabel(model.working == 1 ? "1 agent running" : "\(model.working) agents running")
            }

            if let line = layout.line {
                peek(below: layout.lineBelow)
                    .frame(width: line.width, height: line.height)
                    .offset(x: line.minX, y: line.minY)
                    .transition(.opacity)
            }

            if model.state == .open {
                OpenIsland(model: model, characterWidth: frame.maxX, insets: layout.insets ?? EdgeInsets(), onClose: onClose, onOpenWindow: onOpenWindow)
                    .frame(width: size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.openHeight = $0 }
                    .transition(.opacity)
            }

            if model.state == .listening {
                ListeningIsland(voice: model.voice, insets: layout.insets ?? EdgeInsets())
                    .frame(width: size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.openHeight = $0 }
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // While the island springs open or shut, nothing spills past its shape.
        .clipShape(shape)
        // The shadow belongs to the static shape only: on the whole island it would be
        // recomputed on every one of Oby's frames.
        .background(shape.fill(.black).shadow(color: .black.opacity(model.state == .open ? 0.5 : 0), radius: 30, y: 14))
        .contentShape(shape)
        .onTapGesture { if model.state != .open { onOpen() } }
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: model.state)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: model.openHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: mood, initial: true) { character.mood = mood }
    }

    /// "Oby" and the hover line: under the camera, centered, on a screen with a notch; else Oby's
    /// name beside it and the line trailing. The line wraps to two lines, cut only past the second;
    /// IslandLayout measures it in these fonts and gives the row the height it needs.
    @ViewBuilder private func peek(below: Bool) -> some View {
        let name = Text("Oby").font(.system(size: 12, weight: .semibold)).layoutPriority(1)
        let line = Text(model.peekLine).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            .lineLimit(IslandLayout.maxLines).truncationMode(.tail)
        if below {
            HStack(alignment: .firstTextBaseline, spacing: IslandLayout.gap(below: true)) { name; line }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: IslandLayout.gap(below: false)) { name; Spacer(minLength: 0); line }
        }
    }
}

/// While you hold fn: the waveform, your words as you say them, and how to send.
private struct ListeningIsland: View {
    let voice: Voice
    /// From the island's edges (IslandLayout): the words start below the camera.
    let insets: EdgeInsets

    private var keyName: String { voice.key == .fn ? "fn" : "Control-Option" }

    private var hint: String {
        switch voice.phase {
        case .finishing: "Writing it down…"
        case _ where voice.handsFree: "Press \(keyName) to send · Oby listens until you do"
        default: "Let go of \(keyName) to send · Oby only listens while you hold it"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("LISTENING").font(.system(size: 12, weight: .semibold)).kerning(1).foregroundStyle(.white.opacity(0.55))
                Waveform(levels: voice.levels)
            }
            if let problem = voice.problem {
                Text(problem).font(.system(size: 15, weight: .medium)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(voice.words.isEmpty ? "Say what you need…" : voice.words)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white.opacity(voice.words.isEmpty ? 0.45 : 1))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(hint).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(insets)
    }
}

/// The microphone's loudness, one bar per moment, newest on the right.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule().frame(width: 3, height: 3 + 15 * CGFloat(levels[index]))
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}

/// Both the island and its native composer use the same Escape routing.
nonisolated enum IslandEscape {
    enum Action: Equatable { case stop, back, close }
    static func action(thinking: Bool, showingJob: Bool) -> Action {
        thinking ? .stop : showingJob ? .back : .close
    }
}

/// The open island: needs-you cards and jobs above a compact view of the shared chat.
private struct OpenIsland: View {
    let model: IslandModel
    let characterWidth: CGFloat
    /// From the island's edges (IslandLayout): the words start below the camera.
    let insets: EdgeInsets
    let onClose: () -> Void
    /// Opens the Oby window (Mac/App/ChatWindow.swift), on a job when one is named.
    var onOpenWindow: (_ job: (id: String, local: Bool)?) -> Void = { _ in }
    @State private var text = ""
    @FocusState private var typing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The job open in place of the list (a Row's id), or nil for the list.
    @State private var selected: String?
    /// Why the last Clear done didn't go through, until the next one does.
    @State private var problem: String?
    /// How tall the list or the job's screen wants to be: past `maxHeight`, it scrolls.
    @State private var contentHeight: CGFloat = 0

    /// The list or a job grows the island up to here, then scrolls: the panel is 760 points tall.
    private static let maxHeight: CGFloat = 420
    /// What's left under the last row of a list, a job or the chat: the island has no padding of its own there.
    private static let bottomRoom: CGFloat = 14

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }
    private var tray: Tray { model.tray }

    /// Oby is thinking about what you just said.
    private var thinking: Bool { if case .thinking = desk.talk { true } else { false } }
    /// There's a conversation to ask about.
    private var threaded: Bool { !desk.turns.isEmpty || thinking }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                header.padding(.leading, characterWidth - 20)
                Spacer(minLength: 12)
                // An update is downloaded (Mac/Updater.swift): Restart installs it and relaunches,
                // after this Mac's check if one runs.
                if let pill = model.updater.pill {
                    Button { model.updater.install() } label: {
                        Text(pill)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Color.accentColor.opacity(model.updater.waiting ? 0.5 : 1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.updater.waiting)
                    .help("Installs the update and relaunches Oby. While this Mac runs a check for the runner, it waits for the check to end.")
                }
                if selected != nil {
                    Button { selected = nil } label: { topPill { Label("Back", systemImage: "chevron.left") } }
                        .buttonStyle(.plain)
                } else if clearable {
                    // Through the runner, so the iPhone's Home clears too.
                    Button(action: clear) { topPill { Text("Clear done") } }
                        .buttonStyle(.plain)
                }
                Button { onOpenWindow(nil) } label: { topPill { Text("Open Chat") } }
                    .buttonStyle(.plain)
                    .keyboardShortcut("o", modifiers: .command)
                    .help("The window: the whole conversation, every agent, and what's live")
                Button(action: onClose) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .frame(minHeight: 92, alignment: .top)

            tabBar

            if feed.down { RunnerOfflineNotice(name: feed.name) }
            if let problem { Text(problem).font(OBYStyle.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let row = selectedRow {
                scrolling { screen(row).id(row.id) }
            } else {
                Group {
                    switch model.tab {
                    case .home:
                        scrolling { home }
                    case .chat:
                        chat
                    case .settings:
                        IslandSettings(model: model)
                    }
                }
                .id(model.tab)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.tab)
            }
            if selected != nil && thinking {
                // Over a job's screen, Oby's thinking and its Cancel stay in sight.
                thinkingRow.padding(.bottom, Self.bottomRoom)
            }
        }
        .padding(insets)
        // Escape cancels the turn Oby is thinking about first, then leaves a job's screen, then closes the island.
        .onExitCommand { exit() }
        .onAppear { if model.tab == .chat { typing = true; model.markChatRead() } }
        .onChange(of: model.tab) { _, tab in
            typing = tab == .chat
            if tab == .chat { model.markChatRead() }
        }
        .onChange(of: model.thread.last?.id) { if selected == nil && model.tab == .chat { model.markChatRead() } }
        // A notification opened the island on a runner's job: its screen opens.
        .onChange(of: model.focus, initial: true) { if let focus = model.focus { selected = Row.id(focus, local: false) } }
        // A runner's job open here stays across new lists; one older than the latest 50 (an inbox
        // item's or an alert's) is fetched, and its screen opens once it's here.
        .onChange(of: selected, initial: true) { old, new in
            if let id = Row.runnerJob(old) { feed.showing(id, false) }
            guard let id = Row.runnerJob(new) else { return }
            feed.showing(id, true)
            Task {
                do { try await feed.fetch(id) } catch {
                    if selected == new { selected = nil }
                    problem = error.localizedDescription
                }
            }
        }
        .onDisappear { if let id = Row.runnerJob(selected) { feed.showing(id, false) } }
    }

    private func exit() {
        switch IslandEscape.action(thinking: thinking, showingJob: selected != nil) {
        case .stop: desk.cancel()
        case .back: selected = nil
        case .close: onClose()
        }
    }

    /// A job in the list, and the runner it's on (nil: this Mac).
    private struct Row: Identifiable {
        var job: Job
        var host: String?
        var id: String { Self.id(job.id, local: host == nil) }
        static func id(_ job: String, local: Bool) -> String { "\(local ? "mac" : "runner")/\(job)" }
        /// The runner's job a Row's id names, or nil for this Mac's own or none.
        static func runnerJob(_ id: String?) -> String? {
            guard let id, id.hasPrefix("runner/") else { return nil }
            return String(id.dropFirst("runner/".count))
        }
    }

    /// Every job, this Mac's and the runner's, newest first.
    private var allRows: [Row] {
        (desk.jobs.map { Row(job: $0) } + feed.jobs.map { Row(job: $0, host: feed.name) })
            .sorted { $0.job.created > $1.job.created }
    }

    /// The ones the island lists: all but those that finished by the last Clear done, on any app.
    private var rows: [Row] { allRows.filter { model.lists($0.job) } }

    /// The list in the iPhone's groups: working, waiting, needs you, in review, done.
    private var groups: [JobList.Section<Row>] {
        JobList.groups(rows.filter { $0.job.group != .needsYou }) { $0.job.group }
    }

    /// The job open now, even one that's cleared (a notification opened it).
    private var selectedRow: Row? { selected.flatMap { id in allRows.first { $0.id == id } } }

    /// The job list is on screen, a runner is set (it keeps the clear's time), and a settled job is listed.
    private var clearable: Bool {
        switch desk.talk {
        case .question: false
        default: feed.runner != nil && rows.contains { model.clears($0.job) }
        }
    }

    /// The island grows with what's in here up to `maxHeight`; past that, this scrolls.
    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // The scroll area runs to the island's bottom edge; the last row ends clear of its corners.
        .contentMargins(.bottom, Self.bottomRoom, for: .scrollContent)
        .frame(height: min(contentHeight + Self.bottomRoom, selected == nil ? 250 : Self.maxHeight))
    }

    /// The jobs under their groups' headings, as Home shows them on the iPhone.
    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups) { section in
                Text(section.group.rawValue)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 4).padding(.top, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(section.jobs) { row in
                    JobRow(job: row.job, place: row.host ?? "This Mac", onOpen: { selected = row.id },
                           onStop: { stop(row) }, onDismiss: { try await dismiss(row) })
                }
            }
        }
    }

    /// Home is the job glance surface. Conversation turns belong exclusively to Chat.
    private var home: some View {
        VStack(alignment: .leading, spacing: 10) {
            needsYou
            if !groups.isEmpty { list }
            else if !IslandInbox.waits(desk: desk, feed: feed) {
                Text("Nothing needs your attention.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 4)
            }
        }
    }

    private var needsYou: some View {
        let entries = IslandInbox.entries(desk: desk, feed: feed, now: .now)
        let permissions = feed.chatPermissions.filter { $0.waits(at: .now) }
        return Group {
            if !entries.isEmpty || !permissions.isEmpty {
                Text("Needs you").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 4).accessibilityAddTraits(.isHeader)
                ForEach(entries) { entry in
                    InlineDecision(entry: entry, desk: desk, feed: feed, keyboardEnabled: true,
                                   onOpen: { selected = Row.id($0, local: $1) })
                }
                ForEach(permissions) { record in InlinePermission(record: record, feed: feed, keyboardEnabled: true) }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(IslandTab.allCases, id: \.self) { tab in
                Button { select(tab) } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(model.tab == tab ? .white.opacity(0.16) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(tab.shortcut), modifiers: .command)
                .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.white.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private func select(_ tab: IslandTab) {
        selected = nil
        model.select(tab)
    }

    /// The job's screen, with the same stages as the iPhone's. Both kinds publish here after Touch
    /// ID: this Mac's own jobs with Oby's sentence, the runner's with the runner's, signed by this
    /// Mac's key (Mac/MacDevice.swift). A Mac without Touch ID leaves the runner's to the iPhone.
    @ViewBuilder private func screen(_ row: Row) -> some View {
        if let host = row.host {
            let id = row.job.id
            JobView(job: row.job, place: host, account: feed.accounts.first { $0.account.id == row.job.account }?.account.name, onStop: { stop(row) },
                    publishing: feed.device.key.isAvailable
                        ? JobView.Publishing(action: { try await feed.publishAction(id) }, publish: { try await feed.publish(id, action: $0) })
                        : nil,
                    onMessage: { text in if feed.runner != nil { feed.apply(try await feed.about(id) { try await $0.tell(id, text) }) } },
                    onDismiss: { try await dismiss(row) },
                    extras: feed.extras[id],
                    onMode: { try await feed.setMode(id, $0) },
                    onPermission: { try await feed.answer(id, $0, message: $1) },
                    publishNow: model.publishing == id,
                    onPublishNow: { model.publishing = nil },
                    accounts: feed.accounts, onMove: mover(row),
                    onStartNow: { if feed.runner != nil { feed.apply(try await feed.about(id) { try await $0.startNow(id) }) } },
                    onUseAnyway: { account in if let runner = feed.runner { _ = try await runner.liftReserve(account, true) } })
        } else {
            let job = row.job
            JobView(job: job, place: "This Mac", account: desk.accounts.accounts.first { $0.account.id == job.account }?.account.name,
                    onStop: { stop(row) },
                    publishing: JobView.Publishing(action: { Publish.action(for: job, base: job.base ?? "") },
                                                   publish: { _ in _ = try await desk.publish(job.id, approve: Publish.touchID) }),
                    onMessage: { try desk.message(job.id, $0) }, onDismiss: { try await dismiss(row) },
                    extras: RunnerJobExtras(local: job),
                    onMode: { try desk.changeMode(job.id, to: $0) },
                    onPermission: { try desk.answerPermission(job.id, $0, message: $1) },
                    accounts: desk.accounts.accounts, onMove: mover(row), onStartNow: { try desk.startNow(job.id) },
                    onUseAnyway: { _ = desk.liftReserve($0, true) })
        }
    }

    private func stop(_ row: Row) {
        if row.host == nil {
            desk.stop(row.job.id)
        } else {
            Task { if let job = try? await feed.about(row.job.id, { try await $0.stop(row.job.id) }) { feed.apply(job) } }
        }
    }

    /// Moves the job, here or on the runner; nil for Oby's own reviews, which pick their account themselves.
    private func mover(_ row: Row) -> ((MoveTarget) async throws -> Void)? {
        guard row.job.reviewOf == nil else { return nil }
        let id = row.job.id
        if row.host == nil {
            return { target in _ = try desk.move(id, to: target) }
        }
        return { target in
            guard feed.runner != nil else { throw RunnerError(message: "The runner isn't set up.") }
            feed.apply(try await feed.about(id) { try await $0.move(id, agent: target.agent, account: target.account, model: target.model) })
        }
    }

    private func dismiss(_ row: Row) async throws {
        if row.host == nil {
            try desk.dismiss(row.job.id)
        } else if feed.runner != nil {
            feed.apply(try await feed.about(row.job.id) { try await $0.dismiss(row.job.id) })
        }
    }

    /// Clear done: the runner records the time, and the finished jobs go from here and from the iPhone's Home.
    private func clear() {
        Task {
            do {
                try await feed.clear()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// The jobs in one line, as the iPhone's Home and the closed notch say it (Shared/JobList.swift).
    /// What you said and what Oby answered are in the thread below.
    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.summary).font(.system(size: 19, weight: .semibold))
            switch desk.talk {
            case .question:
                Text("Pick one, or type your own.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            case .thinking:
                Text("Esc cancels. Type to ask something else.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            default:
                Text(threaded ? "Ask about the work, or type a task." : "Type a task below.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                // First launch was skipped or Accessibility refused: fn does nothing until it's allowed.
                // macOS doesn't say when it is, so look again every couple of seconds while open.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    if !AXIsProcessTrusted() {
                        Button("To talk with fn, allow Accessibility") { Task { await Permissions().ask(.accessibility) } }
                            .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.top, 34)
    }

    private func topPill(@ViewBuilder _ label: () -> some View) -> some View {
        label()
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).frame(height: 28)
            .background(.white.opacity(0.12), in: Capsule())
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 12) {
            compactChat
            field
        }
        .padding(.bottom, Self.bottomRoom)
    }

    private var compactChat: some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: OBYStyle.Space.sm) {
                ForEach(Array(model.recentTurns.enumerated()), id: \.element.id) { index, turn in
                    TurnRow(turn: turn, grouped: ConversationModel.grouped(turn, after: index > 0 ? model.recentTurns[index - 1] : nil),
                            jobs: [], account: { _, _ in "" }, isLocal: { _ in false },
                            onOpenJob: { onOpenWindow((id: $0, local: $1)) }, showTime: false)
                }
                switch desk.talk {
                case .question(let said, let question):
                    DecisionCard(title: question.text, options: question.cardOptions,
                                 keyboardEnabled: true, onLater: { desk.cancel() },
                                 onChoose: { desk.answer($0.answer, said: said, question: question.text) },
                                 onWords: { desk.answer($0, said: said, question: question.text) })
                default: EmptyView()
                }
                if model.speaker.speaking {
                    Text("Speaking · press fn to stop").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                if thinking { thinkingRow }
            }
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: model.recentTurns.isEmpty && !thinking ? 0 : 190)
        .accessibilityLabel("Recent conversation with Oby")
    }

    /// Oby's bubble while it thinks: never left there, with a way out in sight.
    private var thinkingRow: some View {
        ThinkingLine(onStop: { desk.cancel() })
    }

    private var field: some View {
        ChatComposer(text: $text, focused: Binding(get: { typing }, set: { typing = $0 }), tray: tray,
                     maximumHeight: 190, onSend: send, onScreenshot: screenshot,
                     onStop: { exit(); return true })
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The chips stay until Dispatch, which hands them to the jobs. The thread shows your words alone.
        model.sendChat(text)
        text = ""
    }

    /// Your words without the line about the chips, to edit them: it's added again when you send.
    private func typed(_ said: String) -> String {
        said.range(of: "\n\n(The user attached ").map { String(said[..<$0.lowerBound]) } ?? said
    }

    /// The camera: the overlay takes the keyboard while you pick, so the field takes it back after.
    private func screenshot() {
        Task {
            await tray.screenshot()
            NSApp.windows.first { $0 is NotchPanel }?.makeKey()
            typing = true
        }
    }
}

/// The plan, before anything runs: agent, account, repository and branch. Dispatch, Edit, Cancel.
/// The window shows it under the thread too (Mac/App/ChatWindow.swift).
struct PlanCard: View {
    let draft: Desk.Draft
    let accounts: [AccountState]
    let onDispatch: (Desk.Draft) -> Void
    let onEdit: () -> Void
    let onCancel: () -> Void
    @State private var branch = ""
    @State private var accountID = ""
    @State private var rounds = 1
    @State private var check = ""
    @State private var stronger = false

    private var account: Account? { (accounts.first { $0.account.id == accountID } ?? accounts.first { $0.account.id == draft.job.account })?.account }
    private var checkIsValid: Bool { check.trimmingCharacters(in: .whitespaces).isEmpty || Plan.isCheck(check) }
    private var ready: Bool { Plan.isBranchName(branch) && checkIsValid }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    tile("Agent · \(AgentModels.summary(account?.agent ?? draft.job.agent))") {
                        Label {
                            Text(Job.agentNames[account?.agent ?? draft.job.agent] ?? "")
                        } icon: {
                            AgentMark(agent: account?.agent ?? draft.job.agent)
                        }
                    }
                    tile(accounts.count > 1 ? "Account · click to change" : "Account · the one you have") {
                        if accounts.count > 1 {
                            Menu {
                                ForEach(accounts, id: \.account.id) { state in
                                    Button(Self.name(state.account)) { accountID = state.account.id }
                                }
                            } label: {
                                Text(account.map(Self.name) ?? "No account").lineLimit(1)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                        } else {
                            Text(account.map(Self.name) ?? "No account").lineLimit(1)
                        }
                    }
                }
                GridRow {
                    tile("Repository") { Text(draft.job.repo).lineLimit(1) }
                    tile("Branch") {
                        TextField("Branch", text: $branch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Plan.isBranchName(branch) ? .white : .red)
                    }
                }
            }
            HStack(spacing: 12) {
                tile("Done when · a command that must pass") {
                    TextField("Optional, like swift test", text: $check)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(checkIsValid ? .white : .red)
                }
                tile("Rounds") {
                    Stepper(rounds == 1 ? "1, no loop" : "Up to \(rounds)", value: $rounds, in: 1...10)
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(width: 170)
            }
            if draft.suggestedModel != nil, let account, ModelPicks.complex(for: account.agent) != nil {
                StrongerModel(agent: account.agent, plan: accounts.first { $0.account.id == account.id }?.label, on: $stronger)
            }
            Label("Works in Oby's own copy of the repository. Nothing is pushed or posted.", systemImage: "checkmark.shield")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            if draft.guessed {
                Label("Oby's brain didn't answer, so this plan is a guess. Check it before you dispatch.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button {
                    var draft = draft
                    draft.job.branch = branch
                    if let account {
                        draft.job.account = account.id
                        draft.job.agent = account.agent
                    }
                    draft.job.rounds = rounds > 1 ? rounds : nil
                    let command = check.trimmingCharacters(in: .whitespaces)
                    draft.job.check = command.isEmpty ? nil : command
                    draft.job.model = stronger ? ModelPicks.complex(for: draft.job.agent) : nil
                    onDispatch(draft)
                } label: {
                    Text("Dispatch").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(.white.opacity(ready ? 1 : 0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .keyboardShortcut(.defaultAction)
                pill("Edit", action: onEdit)
                pill("Cancel", action: onCancel)
            }
            .padding(.top, 6)
        }
        .onAppear(perform: load)
        .onChange(of: draft.job.id, load)
    }

    private func load() {
        branch = draft.job.branch
        accountID = draft.job.account
        rounds = draft.job.maxRounds
        check = draft.job.check ?? ""
    }

    /// "Personal · Claude Code"
    nonisolated private static func name(_ account: Account) -> String {
        "\(account.name) · \(Job.agentNames[account.agent] ?? account.agent)"
    }

    private func tile(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            value().font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20).frame(height: 44)
                .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Several jobs from one request, one row each with its own account, and Dispatch all.
struct PlansCard: View {
    let drafts: [Desk.Draft]
    let accounts: [AccountState]
    let onDispatch: ([Desk.Draft]) -> Void
    let onEdit: () -> Void
    let onCancel: () -> Void
    /// The account each draft goes to, by job id: the routed one unless the user picks another.
    @State private var picked: [String: String] = [:]
    @State private var stronger: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(drafts, id: \.job.id) { draft in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.job.heading).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(details(draft)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if draft.suggestedModel != nil, let model = ModelPicks.complex(for: agent(of: draft)) {
                        Toggle(AgentModels.name(model), isOn: Binding {
                            stronger.contains(draft.job.id)
                        } set: { on in
                            if on { stronger.insert(draft.job.id) } else { stronger.remove(draft.job.id) }
                        })
                        .toggleStyle(.checkbox).font(.system(size: 12))
                        .help("This looks complex: run it on the stronger model")
                    }
                    Menu {
                        ForEach(accounts, id: \.account.id) { state in
                            Button(Self.name(state.account)) { picked[draft.job.id] = state.account.id }
                        }
                    } label: {
                        Text(account(of: draft).map(Self.name) ?? "No account").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if drafts.contains(where: { $0.guessed }) {
                Label("Oby's brain didn't answer, so this plan is a guess. Check it before you dispatch.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button(action: dispatchAll) {
                    Text("Dispatch all \(drafts.count)").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                pill("Edit", action: onEdit)
                pill("Cancel", action: onCancel)
            }
            .padding(.top, 6)
        }
    }

    private func account(of draft: Desk.Draft) -> Account? {
        (accounts.first { $0.account.id == picked[draft.job.id] } ?? accounts.first { $0.account.id == draft.job.account })?.account
    }

    private func agent(of draft: Desk.Draft) -> String { account(of: draft)?.agent ?? draft.job.agent }

    /// "deskree-inc/oby · oby/fix-42 · until swift test passes"
    private func details(_ draft: Desk.Draft) -> String {
        var parts = [draft.job.repo, draft.job.branch]
        if let check = draft.job.check { parts.append("until \(check) passes") } else if draft.job.maxRounds > 1 { parts.append("up to \(draft.job.maxRounds) rounds") }
        return parts.joined(separator: " · ")
    }

    private func dispatchAll() {
        onDispatch(drafts.map { draft in
            var draft = draft
            if let account = account(of: draft) {
                draft.job.account = account.id
                draft.job.agent = account.agent
            }
            draft.job.model = stronger.contains(draft.job.id) ? ModelPicks.complex(for: draft.job.agent) : nil
            return draft
        })
    }

    nonisolated private static func name(_ account: Account) -> String {
        "\(account.name) · \(Job.agentNames[account.agent] ?? account.agent)"
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20).frame(height: 44)
                .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The offer for complex work: the model picked for complex jobs (Oby's stronger model if none was),
/// off until the user turns it on. Astra on a ChatGPT Plus plan gets a warning, because it uses
/// that plan's limits fast.
private struct StrongerModel: View {
    let agent: String
    /// The account's label, like "Plus · name@example.com".
    let plan: String?
    @Binding var on: Bool

    var body: some View {
        let model = ModelPicks.complex(for: agent) ?? ""
        VStack(alignment: .leading, spacing: 4) {
            Toggle("This looks complex. Use \(AgentModels.name(model)) for this job?", isOn: $on)
                .toggleStyle(.switch).font(.system(size: 13, weight: .medium))
            if model.contains("astra"), plan?.hasPrefix("Plus") == true {
                Label("Astra uses a ChatGPT Plus plan's limits fast.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
    }
}


/// One job in the list, as the iPhone's row: its tool's mark, its title, where it runs, the stage
/// it's at, its line, the status pill and Oby's verdict. Click it for the job's screen. A job that
/// needs you offers Dismiss here, and a running one Stop.
private struct JobRow: View {
    let job: Job
    /// Where it runs: the runner's name, like "tetrix-lab", or "This Mac".
    let place: String
    let onOpen: () -> Void
    let onStop: () -> Void
    /// Lets go of a job that needs you (Publish, failed, interrupted, out of reviews); it then needs nothing.
    let onDismiss: () async throws -> Void
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JobChip(job: job, account: place, onOpen: onOpen, onStop: onStop)
            if job.needsYou {
                Button("Dismiss", action: dismiss).buttonStyle(.plain).font(OBYStyle.caption)
            }
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the job")
    }

    private func dismiss() {
        Task {
            do {
                try await onDismiss()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
