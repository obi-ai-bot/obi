import AppKit
import SwiftUI
import WebKit

enum IslandState { case compact, peek, open }

/// The island's state and its geometry, measured from the screen Oby lives on.
@Observable
final class IslandModel {
    let desk: Desk
    let feed: RunnerFeed
    var state: IslandState = .compact
    /// The notch's size, or zero on a screen without one.
    var notch: CGSize = .zero
    /// The menu bar's height, used for the pill on screens without a notch.
    var barHeight: CGFloat = 24
    /// The open island's height, measured from its content.
    var openHeight: CGFloat = 240
    /// A job just ended: the one line the notch shows for a few seconds.
    var notice: String?
    /// The runner's job a notification opened the island on, until the island closes.
    var focus: String?

    init(desk: Desk, feed: RunnerFeed) {
        self.desk = desk
        self.feed = feed
    }

    /// Agents working now, on this Mac and on the runner.
    var working: Int { desk.active.count + feed.working }

    private let wing: CGFloat = 52
    private var top: CGFloat { notch == .zero ? barHeight : notch.height }

    /// What peeking shows next to Oby's name.
    var peekLine: String {
        if let notice { return notice }
        if let job = desk.active.first ?? feed.active.first { return job.step.isEmpty ? job.heading : job.step }
        return "All quiet"
    }

    var size: CGSize {
        let base = notch == .zero ? 180 : notch.width + 2 * wing
        switch state {
        case .compact: return CGSize(width: base, height: top)
        case .peek: return CGSize(width: base + (peekLine == "All quiet" ? 140 : 320), height: top + 6)
        case .open: return CGSize(width: 600, height: openHeight)
        }
    }

    var radius: CGFloat {
        switch state {
        case .compact: 12
        case .peek: 18
        case .open: 32
        }
    }

    /// Where Oby sits inside the island, from its top-left corner.
    var characterFrame: CGRect {
        switch state {
        case .compact, .peek: CGRect(x: 8, y: -3, width: top + 6, height: top + 6)
        // Oby's body sits low in its frame (room to jump), so the frame starts under the notch.
        case .open: CGRect(x: 14, y: top - 14, width: 136, height: 136)
        }
    }

    var contentTop: CGFloat { top }
}

/// Pins the island to the top center of the screen with the notch (or the main screen),
/// above the menu bar, on every Space, and passes clicks through everywhere else.
final class IslandController {
    let desk = Desk()
    let feed = RunnerFeed()
    let model: IslandModel
    let character = ObyCharacter()
    private let panel = NotchPanel()
    private var timer: Timer?
    private var lastMouse: CGPoint?
    private var clickMonitor: Any?
    private var noticeTask: Task<Void, Never>?

    init() { model = IslandModel(desk: desk, feed: feed) }

    func start() {
        panel.contentView = NSHostingView(rootView: IslandView(
            model: model, character: character,
            onOpen: { [weak self] in self?.open() },
            onClose: { [weak self] in self?.close() }))
        place()
        panel.orderFrontRegardless()
        character.pause(true)
        desk.onFinish = { [weak self] job in self?.notify(job.doneLine, happy: job.status == .done) }
        feed.onNotice = { [weak self] job, notice in self?.notify(RunnerFeed.title(notice, for: job), happy: notice == .ready && job.publishError == nil) }
        feed.start()
        Task { await desk.refresh() }
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

    /// A notification was clicked: the island opens on its job.
    func open(job id: String) {
        model.focus = id
        open()
    }

    func open() {
        model.notice = nil
        set(.open)
        // Typing needs the keyboard; the panel takes it without activating Oby.
        panel.makeKey()
    }

    func close() {
        guard model.state == .open else { return }
        model.focus = nil
        set(.compact)
        // Hand the keyboard back to the app you were in.
        if panel.isKeyWindow { NSWorkspace.shared.frontmostApplication?.activate() }
    }

    private func set(_ state: IslandState) {
        guard model.state != state else { return }
        model.state = state
        character.pause(state == .compact)
    }

    /// A job ended, or a runner's job needs you: say so in one line, with a face to match.
    private func notify(_ line: String, happy: Bool) {
        guard model.state != .open else { return }
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
            model.notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            model.notch = .zero
        }
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
        let frame = model.characterFrame
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

    private var mood: String {
        if case .thinking = model.desk.talk { return "thinking" }
        return model.working == 0 ? "idle" : "working"
    }

    var body: some View {
        let size = model.size
        let frame = model.characterFrame
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: model.radius, bottomTrailingRadius: model.radius, style: .continuous)

        ZStack(alignment: .topLeading) {
            WebView(character.page)
                .webViewContentBackground(.hidden)
                .allowsHitTesting(model.state == .open)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .accessibilityLabel("Oby")

            // Agents working on this Mac and on the runner.
            if model.state == .compact, model.working > 0 {
                Text("\(model.working)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: size.width - 16, height: size.height, alignment: .trailing)
                    .accessibilityLabel(model.working == 1 ? "1 agent running" : "\(model.working) agents running")
            }

            if model.state == .peek {
                HStack(spacing: 12) {
                    Text("Oby").font(.system(size: 12, weight: .semibold))
                        .padding(.leading, frame.maxX + 4)
                    Spacer(minLength: 0)
                    Text(model.peekLine).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .padding(.trailing, 14)
                }
                .frame(width: size.width, height: size.height)
                .transition(.opacity)
            }

            if model.state == .open {
                OpenIsland(desk: model.desk, feed: model.feed, focus: model.focus, characterWidth: frame.maxX, top: model.contentTop, onClose: onClose)
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
}

/// The open island: what Oby is up to, the jobs, and the field where you type a task.
private struct OpenIsland: View {
    let desk: Desk
    /// The runner's jobs, followed all the time (RunnerFeed).
    let feed: RunnerFeed
    /// The runner's job a notification opened the island on.
    let focus: String?
    let characterWidth: CGFloat
    let top: CGFloat
    let onClose: () -> Void
    @State private var text = ""
    @FocusState private var typing: Bool
    /// Finished jobs that ended before this are hidden from the island only; Desk keeps them all.
    @AppStorage("islandClearedAt") private var clearedAt: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                header.padding(.leading, characterWidth - 20)
                Spacer(minLength: 12)
                if clearable {
                    Button { clearedAt = Date.now.timeIntervalSince1970 } label: {
                        Text("Clear done")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
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

            switch desk.talk {
            case .plan(let drafts) where drafts.count == 1:
                PlanCard(draft: drafts[0], accounts: desk.accounts.accounts.filter(\.signedIn),
                         onDispatch: { desk.dispatch($0) },
                         onEdit: { text = drafts[0].said; desk.cancel(); typing = true },
                         onCancel: { desk.cancel() })
            case .plan(let drafts):
                PlansCard(drafts: drafts, accounts: desk.accounts.accounts.filter(\.signedIn),
                          onDispatch: { for draft in $0 { desk.dispatch(draft) } },
                          onEdit: { text = drafts[0].said; desk.cancel(); typing = true },
                          onCancel: { desk.cancel() })
            case .question(let said, let question):
                ForEach(question.options, id: \.self) { option in
                    Button { desk.answer(option, said: said, question: question.text) } label: {
                        Text(option).font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                field
            default:
                ForEach(visibleJobs) { row in
                    if let host = row.host {
                        // Publishing needs the iPhone's device key, so runner rows don't offer it.
                        JobRow(job: row.job, host: host, focused: row.job.id == focus,
                               onStop: { Task { if let job = try? await feed.runner?.stop(row.job.id) { feed.apply(job) } } },
                               onPublish: nil, onMessage: { text in if let runner = feed.runner { feed.apply(try await runner.tell(row.job.id, text)) } })
                    } else {
                        let job = row.job
                        JobRow(job: job, onStop: { desk.stop(job.id) }, onPublish: { try await desk.publish(job.id, approve: Publish.touchID) },
                               onMessage: { try desk.message(job.id, $0) })
                    }
                }
                if feed.down {
                    Text("\(feed.name) isn't reachable").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
                field
            }
        }
        .padding(.top, top + 10)
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .onExitCommand(perform: onClose)
        .onAppear { typing = true }
    }

    /// A job in the list, and the runner it's on (nil: this Mac).
    private struct Row: Identifiable {
        var job: Job
        var host: String?
        var id: String { "\(host ?? "")/\(job.id)" }
    }

    /// Running jobs first, this Mac's and the runner's, then the latest finished ones: four at most.
    /// The job a notification opened comes first, even if it's cleared or further down.
    private var visibleJobs: [Row] {
        let rows = desk.jobs.map { Row(job: $0) } + feed.jobs.map { Row(job: $0, host: feed.name) }
        let active = rows.filter(\.job.isActive)
        let finished = rows.filter { isListed($0.job) }.sorted { ($0.job.finished ?? .distantPast) > ($1.job.finished ?? .distantPast) }
        let listed = active + finished.prefix(max(0, 4 - active.count))
        guard let focused = rows.first(where: { $0.host != nil && $0.job.id == focus }) else { return listed }
        return [focused] + listed.filter { $0.id != focused.id }
    }

    /// Finished jobs that ended after the last Clear done.
    private var finished: [Job] {
        (desk.jobs + feed.jobs).filter(isListed)
    }

    private func isListed(_ job: Job) -> Bool {
        !job.isActive && (job.finished ?? .distantPast).timeIntervalSince1970 > clearedAt
    }

    /// The job list is on screen and has something finished to clear.
    private var clearable: Bool {
        switch desk.talk {
        case .plan, .question: false
        default: !finished.isEmpty
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch desk.talk {
            case .thinking(let said):
                Text("Thinking…").font(.system(size: 19, weight: .semibold))
                Text("You said “\(said)”").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            case .plan(let drafts):
                Text("You said “\(drafts[0].said)”").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Text(drafts[0].reply).font(.system(size: 19, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            case .reply(let reply):
                Text(reply).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Type a task below.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            case .question(_, let question):
                Text(question.text).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Pick one, or type below.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            case .none:
                let working = desk.active.count + feed.working
                // What needs you among the jobs listed: ready to publish, failed or interrupted.
                let needs = NeedsYou.line(finished).map { "\($0)." }
                let agents = working == 1 ? "1 agent is working." : "\(working) agents are working."
                Text(working == 0 ? needs ?? "All quiet." : "\(agents) \(needs ?? "Nothing needs you.")")
                    .font(.system(size: 19, weight: .semibold))
                Text("Type a task below.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.top, 34)
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("Type a task, like “Review oby PR #12”", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($typing)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(text.isEmpty ? 0.4 : 1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 18)
        .padding(.trailing, 7)
        .frame(height: 48)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        desk.ask(text)
        text = ""
    }
}

/// The plan, before anything runs: agent, account, repository and branch. Dispatch, Edit, Cancel.
private struct PlanCard: View {
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
                        Label(Job.agentNames[account?.agent ?? draft.job.agent] ?? "", systemImage: "asterisk")
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
            if draft.suggestedModel != nil, let account {
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
                    draft.job.model = stronger ? AgentModels.stronger[draft.job.agent] : nil
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
private struct PlansCard: View {
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
                    if draft.suggestedModel != nil {
                        Toggle(AgentModels.name(AgentModels.stronger[agent(of: draft)] ?? ""), isOn: Binding {
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
            draft.job.model = stronger.contains(draft.job.id) ? AgentModels.stronger[draft.job.agent] : nil
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

/// The offer for complex work: the tool's stronger model, off until the user turns it on. Astra
/// on a ChatGPT Plus plan gets a warning, because it uses that plan's limits fast.
private struct StrongerModel: View {
    let agent: String
    /// The account's label, like "Plus · name@example.com".
    let plan: String?
    @Binding var on: Bool

    var body: some View {
        let model = AgentModels.stronger[agent] ?? ""
        VStack(alignment: .leading, spacing: 4) {
            Toggle("This looks complex. Use \(AgentModels.name(model)) for this job?", isOn: $on)
                .toggleStyle(.switch).font(.system(size: 13, weight: .medium))
            if agent == "codex", plan?.hasPrefix("Plus") == true {
                Label("Astra uses a ChatGPT Plus plan's limits fast.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
    }
}

/// One job: what it is, what it's doing now, and how it ended. Click a finished one to read its
/// summary; a done one whose own publish failed can be published by hand, after Oby shows exactly
/// what that does. A running or
/// opened one takes a word for its agent.
private struct JobRow: View {
    let job: Job
    /// The runner the job is on, like "tetrix-lab", or nil for this Mac.
    var host: String? = nil
    /// A notification opened the island on this job: it opens, and stands out.
    var focused = false
    let onStop: () -> Void
    /// Nil where this Mac can't publish: a runner's job needs the iPhone's device key.
    let onPublish: (() async throws -> Void)?
    let onMessage: (String) async throws -> Void
    @State private var expanded = false
    @State private var confirming = false
    @State private var publishing = false
    @State private var problem: String?
    @State private var note = ""
    @State private var noteProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "asterisk").font(.system(size: 17, weight: .semibold)).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(job.heading).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if let host {
                            Text(host).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 7).frame(height: 18)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if job.maxRounds > 1 {
                    Text("\(job.currentRound)/\(job.maxRounds)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                        .accessibilityLabel("Round \(job.currentRound) of \(job.maxRounds)")
                }
                status
                if let link = job.published.flatMap(URL.init(string:)) {
                    Link(destination: link) { pill("Pull request") }
                }
                // Oby's own publish failed: before the first publish, or with later rounds' commits.
                if job.canPublish {
                    if onPublish == nil {
                        Text("Publish from your iPhone").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    } else if !confirming {
                        Button { confirming = true } label: { pill(job.published == nil ? "Publish" : "Publish the new commits") }
                            .buttonStyle(.plain)
                    }
                }
                if job.isActive {
                    Button(action: onStop) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24).background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                }
            }
            // Only the top line opens and closes the row, so clicks in the field below stay there.
            .contentShape(Rectangle())
            .onTapGesture { if !job.isActive { expanded.toggle() } }
            if job.canPublish, let reason = job.publishError {
                Text(reason).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(3)
            }
            if expanded, !job.summary.isEmpty {
                ScrollView {
                    Text(job.summary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            if job.status == .running || (expanded && job.session != nil) {
                talk
            }
            if confirming {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Publish.action(for: job, base: job.base ?? "")).font(.system(size: 13, weight: .medium))
                    if let problem {
                        Text(problem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
                    }
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                publishing = true
                                defer { publishing = false }
                                do {
                                    try await onPublish?()
                                    confirming = false
                                    problem = nil
                                } catch {
                                    problem = error.localizedDescription
                                }
                            }
                        } label: {
                            Label(publishing ? "Publishing…" : "Publish with Touch ID", systemImage: "touchid")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                                .padding(.horizontal, 14).frame(height: 30)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(publishing)
                        Button { confirming = false; problem = nil } label: { pill("Not now") }
                            .buttonStyle(.plain)
                            .disabled(publishing)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if focused { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.35)) }
        }
        .onChange(of: focused, initial: true) { if focused, !job.isActive { expanded = true } }
    }

    /// One line for the agent, and why it didn't go if it didn't.
    @ViewBuilder private var talk: some View {
        let blank = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
            TextField("Tell the agent…", text: $note)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(tell)
            Button(action: tell) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(blank ? 0.4 : 1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(blank)
            .accessibilityLabel("Send to the agent")
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: 32)
        .background(.white.opacity(0.08), in: Capsule())
        if let noteProblem {
            Text(noteProblem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func tell() {
        let text = note
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        note = ""
        Task {
            do {
                try await onMessage(text)
                noteProblem = nil
            } catch {
                note = text
                noteProblem = error.localizedDescription
            }
        }
    }

    private func pill(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 24)
            .background(.white.opacity(0.12), in: Capsule())
    }

    private var subtitle: String {
        switch job.status {
        case .queued, .running: job.step
        case .done: (job.commits ?? 0) > 0 ? "\(job.commits ?? 0) commit\(job.commits == 1 ? "" : "s") on \(job.branch) · \(job.doneLine)" : job.doneLine
        case .failed, .stopped, .interrupted: job.summary.split(separator: "\n").first.map(String.init) ?? ""
        }
    }

    private var status: some View {
        let (text, color): (String, Color) = switch job.status {
        case .queued: ("Starting", .blue)
        case .running: ("Working", .blue)
        case .done where job.canPublish: (job.publishError == nil ? "Ready to publish" : "Couldn't publish", .orange)
        case .done where job.published != nil: ("Published", .green)
        case .done: ("Done", .green)
        case .failed: ("Failed", .red)
        case .stopped: ("Stopped", .gray)
        case .interrupted: ("Interrupted", .gray)
        }
        return Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
    }
}
