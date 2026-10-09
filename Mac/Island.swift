import AppKit
import SwiftUI
import WebKit

enum IslandState { case compact, peek, open }

/// The island's state and its geometry, measured from the screen Oby lives on.
@Observable
final class IslandModel {
    let desk: Desk
    var state: IslandState = .compact
    /// The notch's size, or zero on a screen without one.
    var notch: CGSize = .zero
    /// The menu bar's height, used for the pill on screens without a notch.
    var barHeight: CGFloat = 24
    /// The open island's height, measured from its content.
    var openHeight: CGFloat = 240
    /// A job just ended: the one line the notch shows for a few seconds.
    var notice: String?

    init(desk: Desk) { self.desk = desk }

    private let wing: CGFloat = 52
    private var top: CGFloat { notch == .zero ? barHeight : notch.height }

    /// What peeking shows next to Oby's name.
    var peekLine: String {
        if let notice { return notice }
        if let job = desk.active.first { return job.step.isEmpty ? job.title : job.step }
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
    let model: IslandModel
    let character = ObyCharacter()
    private let panel = NotchPanel()
    private var timer: Timer?
    private var lastMouse: CGPoint?
    private var clickMonitor: Any?
    private var noticeTask: Task<Void, Never>?

    init() { model = IslandModel(desk: desk) }

    func start() {
        panel.contentView = NSHostingView(rootView: IslandView(
            model: model, character: character,
            onOpen: { [weak self] in self?.open() },
            onClose: { [weak self] in self?.close() }))
        place()
        panel.orderFrontRegardless()
        character.pause(true)
        desk.onFinish = { [weak self] job in self?.notify(job) }
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

    func open() {
        model.notice = nil
        set(.open)
        // Typing needs the keyboard; the panel takes it without activating Oby.
        panel.makeKey()
    }

    func close() {
        guard model.state == .open else { return }
        set(.compact)
        // Hand the keyboard back to the app you were in.
        if panel.isKeyWindow { NSWorkspace.shared.frontmostApplication?.activate() }
    }

    private func set(_ state: IslandState) {
        guard model.state != state else { return }
        model.state = state
        character.pause(state == .compact)
    }

    /// A job ended: say so in one line, with a face to match.
    private func notify(_ job: Job) {
        guard model.state != .open else { return }
        model.notice = job.doneLine
        set(.peek)
        character.play(job.status == .done ? "Agree" : "Confused")
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
        return model.desk.active.isEmpty ? "idle" : "working"
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

            if model.state == .compact, !model.desk.active.isEmpty {
                Text("\(model.desk.active.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: size.width - 16, height: size.height, alignment: .trailing)
                    .accessibilityLabel("\(model.desk.active.count) jobs running")
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
                OpenIsland(desk: model.desk, characterWidth: frame.maxX, top: model.contentTop, onClose: onClose)
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
    let characterWidth: CGFloat
    let top: CGFloat
    let onClose: () -> Void
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                header.padding(.leading, characterWidth - 20)
                Spacer(minLength: 12)
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
            case .plan(let draft):
                PlanCard(draft: draft, accounts: desk.accounts.accounts.filter(\.signedIn),
                         onDispatch: { desk.dispatch($0) },
                         onEdit: { text = draft.said; desk.cancel(); typing = true },
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
                ForEach(visibleJobs) { job in
                    JobRow(job: job, onStop: { desk.stop(job.id) })
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

    /// Running jobs first, then the latest finished ones: four at most.
    private var visibleJobs: [Job] {
        let active = desk.active
        return active + desk.jobs.filter { !$0.isActive }.prefix(max(0, 4 - active.count))
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch desk.talk {
            case .thinking(let said):
                Text("Thinking…").font(.system(size: 19, weight: .semibold))
                Text("You said “\(said)”").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            case .plan(let draft):
                Text("You said “\(draft.said)”").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Text(draft.reply).font(.system(size: 19, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            case .reply(let reply):
                Text(reply).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Type a task below.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            case .question(_, let question):
                Text(question.text).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Pick one, or type below.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            case .none:
                let working = desk.active.count
                Text(working == 0 ? "All quiet." : working == 1 ? "1 agent is working. Nothing needs you." : "\(working) agents are working. Nothing needs you.")
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

    private var account: Account? { (accounts.first { $0.account.id == accountID } ?? accounts.first { $0.account.id == draft.job.account })?.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    tile("Agent") { Label(Job.agentNames[account?.agent ?? draft.job.agent] ?? "", systemImage: "asterisk") }
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
                    onDispatch(draft)
                } label: {
                    Text("Dispatch").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(.white.opacity(Plan.isBranchName(branch) ? 1 : 0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!Plan.isBranchName(branch))
                .keyboardShortcut(.defaultAction)
                pill("Edit", action: onEdit)
                pill("Cancel", action: onCancel)
            }
            .padding(.top, 6)
        }
        .onAppear { branch = draft.job.branch; accountID = draft.job.account }
        .onChange(of: draft.job.id) { branch = draft.job.branch; accountID = draft.job.account }
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

/// One job: what it is, what it's doing now, and how it ended. Click a finished one to read its summary.
private struct JobRow: View {
    let job: Job
    let onStop: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "asterisk").font(.system(size: 17, weight: .semibold)).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 8)
                status
                if job.isActive {
                    Button(action: onStop) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24).background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                }
            }
            if expanded, !job.summary.isEmpty {
                ScrollView {
                    Text(job.summary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !job.isActive { expanded.toggle() } }
    }

    private var subtitle: String {
        switch job.status {
        case .queued, .running: job.step
        case .done: job.doneLine
        case .failed, .stopped, .interrupted: job.summary.split(separator: "\n").first.map(String.init) ?? ""
        }
    }

    private var status: some View {
        let (text, color): (String, Color) = switch job.status {
        case .queued: ("Starting", .blue)
        case .running: ("Working", .blue)
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
