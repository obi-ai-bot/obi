import AppKit
import SwiftUI
import WebKit

/// The Settings window's tabs, so the sidebar's Accounts and keys, Integrations, Memory and
/// Settings open the right one.
nonisolated enum SettingsTab: String, CaseIterable, Sendable { case general, runner, remote, accounts, models, connectors, vault, about }

/// Which Settings tab is up: the sidebar sets it before opening the window.
@Observable
final class SettingsSelection {
    static let shared = SettingsSelection()
    var tab = SettingsTab.general

    /// Opens Settings on `tab`.
    static func open(_ tab: SettingsTab) {
        shared.tab = tab
        NSApp.activate()
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// The Oby window (Sangam's design, #11 and #270), opened from the notch, the menu or ⌘O: the side
/// panel, and Home with pages opening over it.
final class ChatWindow: NSObject, NSWindowDelegate {
    private let island: IslandController
    private var window: NSWindow?
    /// What's open over Home, and where the title bar's content starts.
    private let state = ChatState()
    /// Oby on Home's stage: its own page, apart from the notch's, paused while out of sight.
    private lazy var character = ObyCharacter(query: "embed&size=1.23")

    init(island: IslandController) { self.island = island }

    /// Shows the window, on the conversation or on a job's page when one is named.
    func show(job: (id: String, local: Bool)? = nil) {
        state.open(job: job)
        island.model.chatWindowVisible = true
        if job == nil { island.model.markChatRead() }
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = Self.make(ChatView(model: island.model, state: state, character: character, onOpenSettings: SettingsSelection.open))
        window.delegate = self
        window.setFrameAutosaveName("ObyChat")
        if !window.setFrameUsingName("ObyChat") { window.center() }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        Self.measureLights(window, into: state)
    }

    /// The window around `view`, as Sangam's: a toolbar's title bar, so the traffic lights sit in
    /// the middle of a taller bar that the trail shares (nothing's in the toolbar; it only sets the
    /// height), dark, at least as wide as the view gets.
    static func make(_ view: some View, size: NSSize = NSSize(width: 994, height: 670)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Oby"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "ObyWindow")
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 11 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: Tokens.viewMin, height: 520)
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    /// Where macOS put the traffic lights: the title bar is as tall as twice their middle, and its
    /// content starts just right of them. In full screen there are none.
    static func measureLights(_ window: NSWindow, into state: ChatState) {
        // In full screen the lights live in a toolbar window of their own (and hide): no measuring across it.
        guard let zoom = window.standardWindowButton(.zoomButton), zoom.window === window, !zoom.isHidden,
              !window.styleMask.contains(.fullScreen), let bar = zoom.superview, let content = window.contentView else {
            state.chrome = WindowChrome(bar: Tokens.bar, afterLights: 12)
            return
        }
        let frame = content.convert(bar.convert(zoom.frame, to: nil), from: nil)
        let middle = content.isFlipped ? frame.midY : content.bounds.height - frame.midY
        state.chrome = WindowChrome(bar: min(64, max(Tokens.bar, (middle * 2).rounded())), afterLights: (frame.maxX + 10).rounded())
    }

    private func measureLights() { if let window { Self.measureLights(window, into: state) } }

    func windowDidResize(_ notification: Notification) { measureLights() }
    func windowDidEnterFullScreen(_ notification: Notification) { measureLights() }
    func windowDidExitFullScreen(_ notification: Notification) { measureLights() }
    func windowWillClose(_ notification: Notification) {
        island.model.chatWindowVisible = false
        state.visible = false
    }
    func windowDidMiniaturize(_ notification: Notification) {
        island.model.chatWindowVisible = false
        state.visible = false
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        island.model.chatWindowVisible = true
        state.visible = true
        if state.trail.top == .talk { island.model.markChatRead() }
    }

    var isOpen: Bool { window?.isVisible ?? false }
}

/// The title bar's height and where its content starts, from where macOS put the traffic lights.
nonisolated struct WindowChrome: Equatable, Sendable {
    var bar = Tokens.bar
    var afterLights = Tokens.afterLights
}

@Observable
final class ChatState {
    /// What's open over Home, in the order it was opened.
    var trail = WindowTrail()
    /// Asks the conversation's box, and Home's, to take the keyboard.
    var composerFocusRequest = 0
    var homeFocusRequest = 0
    var chrome = WindowChrome()
    /// The window is on screen (not closed or in the Dock): Oby on Home draws only then.
    var visible = true
    /// When this state began, and the job rows opened since: a job created after it and not
    /// opened yet is new (#496), its row and its kind's chip with a blue dot.
    let since = Date.now
    var seen: Set<String> = []
    /// The side panel's folded groups and those showing all their done tasks.
    var folded: Set<String> = []
    var more: Set<String> = []

    /// A job's page, or the conversation with Oby, from a fresh start.
    func open(job: (id: String, local: Bool)? = nil) {
        visible = true
        if let job {
            trail.start(.job(id: job.id, local: job.local))
        } else {
            trail.start(.talk)
            composerFocusRequest += 1
        }
    }

    /// New task: back Home, into its message box.
    func newTask() {
        trail.closeAll()
        homeFocusRequest += 1
    }
}

/// The window: the side panel and Home, the title bar over Home with its trail, and what's open
/// over Home, the top one showing.
struct ChatView: View {
    let model: IslandModel
    let state: ChatState
    var character: ObyCharacter?
    let onOpenSettings: (SettingsTab) -> Void
    /// The side panel opens as you left it: closed the first time.
    @AppStorage("ObySidebarOpen") private var sidebarOpen = false
    @AppStorage("ObySidebarWidth") private var sidebarWidth = Double(Tokens.sidebar)
    /// While the panel's edge is dragged: its width then, rubber-banding past the limits.
    @State private var dragWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panelWidth: CGFloat { dragWidth ?? CGFloat(sidebarWidth) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if sidebarOpen {
                    SidebarView(model: model, state: state, width: panelWidth, onNewTask: { withAnimation(motion) { state.newTask() } },
                                onOpenSettings: onOpenSettings)
                        .overlay(alignment: .trailing) { resizeHandle }
                        .transition(.move(edge: .leading))
                }
                HomeView(model: model, state: state, character: character, sidebarOpen: sidebarOpen)
                    .frame(minWidth: Tokens.viewMin, maxWidth: .infinity, maxHeight: .infinity)
            }
            // Right of the traffic lights, over whatever is beneath, whether the panel is open or not.
            IconButton(symbol: "sidebar.left", action: { withAnimation(reduceMotion ? nil : sidebarOpen ? Tokens.easeIn : Tokens.settle) { sidebarOpen.toggle() } })
                .help(sidebarOpen ? "Hide sidebar" : "Show sidebar")
                .accessibilityLabel(sidebarOpen ? "Hide sidebar" : "Show sidebar")
                .padding(.leading, state.chrome.afterLights).padding(.top, (state.chrome.bar - 32) / 2)
        }
        .foregroundStyle(Tokens.text)
        .background(Tokens.bg)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        // Esc goes back one page.
        .onExitCommand { if !state.trail.isHome { withAnimation(motion) { state.trail.back() } } }
        // Opened: its blue dot goes.
        .onChange(of: state.trail.top, initial: true) { _, top in
            if case .job(let id, let local) = top { state.seen.insert(SidebarSections.JobRow.id(id, local: local)) }
            if top == .talk { model.markChatRead() }
        }
        // A job that left every list: its page goes too.
        .onChange(of: model.desk.jobs.map(\.id) + model.feed.jobs.map(\.id)) {
            state.trail.drop { step in
                guard case .job(let id, let local) = step else { return false }
                return !(local ? model.desk.jobs : model.feed.jobs).contains { $0.id == id }
            }
        }
    }

    private var motion: Animation? { reduceMotion ? nil : Tokens.warm }

    /// The panel's right edge: drag to resize, double-click for the default width.
    private var resizeHandle: some View {
        Color.clear.frame(width: 8).contentShape(Rectangle())
            .offset(x: 1)
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in dragWidth = PanelWidth.dragging(CGFloat(sidebarWidth) + drag.translation.width) }
                .onEnded { drag in
                    let settled = PanelWidth.settled(CGFloat(sidebarWidth) + drag.translation.width)
                    withAnimation(reduceMotion ? nil : Tokens.settle) { dragWidth = nil; sidebarWidth = Double(settled) }
                })
            .onTapGesture(count: 2) { withAnimation(reduceMotion ? nil : Tokens.settle) { sidebarWidth = Double(Tokens.sidebar) } }
            .accessibilityLabel("Resize side panel")
    }
}

/// Home (Sangam's Home.tsx): the title bar and its trail, Oby's stage with what's running and the
/// chips under it, the message box at the foot, and the pages that open over it.
private struct HomeView: View {
    let model: IslandModel
    let state: ChatState
    let character: ObyCharacter?
    let sidebarOpen: Bool
    @State private var text = ""
    @State private var typing = false
    @State private var height: CGFloat = 600
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var work: [WorkList.Item<SidebarSections.JobRow>] { model.work(since: state.since, seen: state.seen) }
    private var away: Bool { !state.trail.isHome }

    var body: some View {
        VStack(spacing: 0) {
            // Over the pages: their scroll views reach up under the bar, and would take its clicks.
            TitleBar(model: model, state: state, sidebarOpen: sidebarOpen).zIndex(1)
            ZStack {
                VStack(spacing: 0) {
                    stage
                        .opacity(away ? 0 : 1).scaleEffect(away && !reduceMotion ? 0.98 : 1)
                    box
                        .opacity(away ? 0 : 1).offset(y: away && !reduceMotion ? 12 : 0)
                }
                .allowsHitTesting(!away)
                .accessibilityHidden(away)
                if let top = state.trail.top {
                    page(top)
                        .id(top)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 28)),
                                                removal: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 12))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Tokens.warm, value: state.trail)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onChange(of: away || !state.visible, initial: true) { _, hidden in character?.pause(hidden) }
        .onChange(of: model.mood, initial: true) { _, mood in character?.mood = mood }
        .onChange(of: state.homeFocusRequest) { typing = true }
        // A page over Home: the hidden box lets go of the keyboard, so nothing typed lands in it.
        .onChange(of: away) { if away { typing = false } }
    }

    /// Oby, a little above the middle (as a face at eye level), what's going on under it, and the
    /// chips: every kind of work with something in it, whatever the side panel groups by.
    private var stage: some View {
        let groups = WorkList.groups(work, by: .type)
        let running = work.count { $0.status == .running }, needs = work.count { $0.status == .needs }
        return EyeLevel {
            VStack(spacing: 16) {
                OnStage(character: character).frame(width: 280, height: 220)
                    .padding(.bottom, -8)
                Text(HomeLine.attention(running: running, needs: needs))
                    .font(Tokens.font(Tokens.textBase))
                    .foregroundStyle(running + needs == 0 ? Tokens.text : Tokens.muted)
                if !groups.isEmpty {
                    CenteredFlow(spacing: 8) {
                        ForEach(groups) { group in
                            HomeChip(group: group) { if let kind = group.type { state.trail.start(.group(kind)) } }
                        }
                    }
                    .frame(maxWidth: 440)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Your tasks")
                }
            }
        }
        .padding(.horizontal, Tokens.gutter).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Asking Oby: the conversation opens on it.
    private var box: some View {
        MessageBox(text: $text, focused: $typing, tray: model.tray,
                   placeholder: HomeLine.placeholder(fullName: NSFullUserName()),
                   maximumHeight: height * 0.5, focusRequest: state.homeFocusRequest,
                   onSend: ask, onScreenshot: screenshot, onStop: { false }, usage: model.usageRows)
            .frame(maxWidth: Tokens.homeBox - 2 * Tokens.gutter)
            .padding(.horizontal, Tokens.gutter).padding(.bottom, Tokens.gutter)
    }

    private func back() { withAnimation(reduceMotion ? nil : Tokens.warm) { state.trail.back() } }

    /// Asked in Home's box: it goes to Oby, and the conversation opens on it.
    private func ask() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.sendChat(text)
        text = ""
        state.open()
    }

    private func screenshot() {
        Task {
            await model.tray.screenshot()
            typing = true
        }
    }

    @ViewBuilder private func page(_ step: WindowStep) -> some View {
        switch step {
        case .talk:
            ConversationPage(model: model, composerFocusRequest: state.composerFocusRequest,
                             onOpenJob: { state.trail.push(.job(id: $0, local: $1)) }, onBack: back)
        case .job(let id, let local):
            JobPane(model: model, id: id, local: local).takesKeys()
        case .group(let kind):
            GroupPane(model: model, kind: kind, items: work.filter { $0.type == kind },
                      onOpenJob: { state.trail.push(.job(id: $0, local: $1)) })
                .takesKeys()
        }
    }
}

/// Oby on Home's stage: the live character, hidden until its first frame is drawn so nothing
/// the page paints while it loads can flash.
private struct OnStage: View {
    let character: ObyCharacter?

    var body: some View {
        if let character {
            WebView(character.page)
                .webViewContentBackground(.hidden)
                .opacity(character.ready ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Oby")
        } else {
            ObyFace(size: 96)
        }
    }
}

/// A kind of work's chip on Home: a blue dot ahead of its name while it holds a new task, an
/// orange one when something in it needs you; both can show.
private struct HomeChip: View {
    let group: WorkList.Group<SidebarSections.JobRow>
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if group.fresh || group.needs > 0 {
                    HStack(spacing: 4) {
                        if group.fresh { Circle().fill(Tokens.unread).frame(width: 6, height: 6).accessibilityLabel("New") }
                        if group.needs > 0 { Circle().fill(Tokens.needs).frame(width: 6, height: 6).accessibilityLabel("Needs you") }
                    }
                }
                Text(group.label).font(Tokens.font(Tokens.textBase)).lineLimit(1)
            }
            .foregroundStyle(hovering ? Tokens.ink : Tokens.text)
            .padding(.horizontal, 16).frame(height: 34)
            .background(hovering ? Tokens.pillHover : Tokens.pill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering)
        .accessibilityElement(children: .combine)
    }
}

/// The title bar: back to Home and the trail (each earlier step goes back to it, the last is
/// where you are), and on a task's page the way into its conversation.
private struct TitleBar: View {
    let model: IslandModel
    let state: ChatState
    let sidebarOpen: Bool

    var body: some View {
        HStack(spacing: 0) {
            if !state.trail.isHome {
                IconButton(symbol: "chevron.left", action: { state.trail.closeAll() })
                    .help("Back to Home").accessibilityLabel("Back to Home")
                    .padding(.trailing, 8)
                HStack(spacing: 2) {
                    ForEach(Array(state.trail.steps.enumerated()), id: \.element) { index, step in
                        if index > 0 {
                            Image(systemName: "chevron.right").font(Tokens.font(11, .light)).foregroundStyle(Tokens.muted.opacity(0.6))
                                .frame(width: 22).accessibilityHidden(true)
                        }
                        let last = index == state.trail.steps.count - 1
                        Crumb(title: WindowLabels.label(step, model: model), here: last) { state.trail.back(to: index) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Where you are")
            }
            Spacer(minLength: 16)
            if case .job(let id, _) = state.trail.top, ConversationModel.started(id, in: model.thread) {
                Button("Go to conversation") { state.trail.push(.talk) }
                    .buttonStyle(ChipButtonStyle())
                    .padding(.trailing, Tokens.gutter)
            }
        }
        .padding(.leading, sidebarOpen ? Tokens.gutter : state.chrome.afterLights + 40)
        .frame(height: state.chrome.bar)
        .background { WindowDragArea() }
    }
}

/// One step of the trail: a link back to it, or (`here`) where you are.
private struct Crumb: View {
    let title: String
    let here: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(Tokens.font(Tokens.textMd)).lineLimit(1)
                .foregroundStyle(here ? Tokens.text : hovering ? Tokens.ink : Tokens.muted)
                .padding(.horizontal, 6).frame(height: 26)
                .background(!here && hovering ? Tokens.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(maxWidth: here ? nil : 200, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(here)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering)
        .accessibilityAddTraits(here ? .isHeader : [])
    }
}

/// A small pill button on the chip colour (the trail's "Go to conversation").
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label.font(Tokens.font(Tokens.textMd)).lineLimit(1)
                .foregroundStyle(hovering ? Tokens.ink : Tokens.text)
                .padding(.horizontal, 12).frame(height: 28)
                .background(hovering || configuration.isPressed ? Tokens.chipHover : Tokens.chip, in: Capsule())
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Tokens.fade, value: hovering)
        }
    }
}

/// What each step is called in the trail.
enum WindowLabels {
    static func label(_ step: WindowStep, model: IslandModel) -> String {
        switch step {
        case .group(let kind): kind.label
        case .talk: "Oby"
        case .job(let id, let local):
            (local ? model.desk.jobs : model.feed.jobs).first { $0.id == id }?.heading ?? "Task"
        }
    }
}

extension View {
    /// A page over Home takes the keyboard as it opens (the box under it lets go), so Esc reaches
    /// the window's back, whatever was clicked to open it.
    func takesKeys() -> some View { modifier(TakesKeys()) }
}

private struct TakesKeys: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focusable().focusEffectDisabled().focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// One view a little above the middle: the room over it and under it split 1 to 1.6.
struct EyeLevel: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: proposal.height ?? size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let room = max(0, bounds.height - size.height)
        view.place(at: CGPoint(x: bounds.midX, y: bounds.minY + room / 2.6 + size.height / 2), anchor: .center,
                   proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

/// Chips in rows, each row centred, wrapping when the next one doesn't fit.
struct CenteredFlow: Layout {
    var spacing: CGFloat = 8
    /// Off: each row starts at the left, as a card's choices do.
    var centred = true

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if !rows[rows.count - 1].isEmpty && used + spacing + size.width > width {
                rows.append([]); used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append((index, size))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let height = rows.map { $0.map(\.size.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map { row in row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        return CGSize(width: min(width, widest), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let width = row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1))
            var x = centred ? bounds.midX - width / 2 : bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }
}

/// The notch's messenger bubbles (Island.swift): no per-message chrome, one centered timestamp above each group.
struct TurnRow: View {
    let turn: Turn
    var grouped = false
    let jobs: [Job]
    let account: (_ job: Job, _ local: Bool) -> String
    let isLocal: (_ id: String) -> Bool
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    var onStopJob: ((_ job: String, _ local: Bool) -> Void)? = nil
    var showTime = true
    /// What Oby does for these words, a step at a time (#304): under the bubble, before its answer.
    var steps: [TurnStep] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showTime {
                Text(ConversationModel.dayTitle(turn.date, now: .now, calendar: .current) + " " + ConversationModel.clock(turn.date))
                    .font(OBYStyle.caption).foregroundStyle(OBYStyle.tertiary)
                    .frame(maxWidth: .infinity).padding(.top, OBYStyle.Space.lg).padding(.bottom, OBYStyle.Space.sm)
            }
            MessageBubbleLayout(trailing: turn.who == .user) {
                ReadingText(turn.text, color: turn.who == .user ? OBYStyle.userText : OBYStyle.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, OBYStyle.Space.lg).padding(.vertical, 14)
                    .background(turn.who == .user ? OBYStyle.userBubble : OBYStyle.assistantBubble,
                                in: RoundedRectangle(cornerRadius: OBYStyle.bubble, style: .continuous))
            }
            if let markdown = ConversationModel.markdownDetails(for: turn) {
                Text(markdown).font(OBYStyle.body).foregroundStyle(OBYStyle.primary).textSelection(.enabled)
                    .padding(.leading, OBYStyle.Space.lg)
            }
            if !steps.isEmpty {
                StepList(steps: steps).padding(.horizontal, OBYStyle.Space.sm)
            }
            ForEach(jobs) { job in
                Text("Started \(job.heading)").font(OBYStyle.caption).foregroundStyle(OBYStyle.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, OBYStyle.Space.sm)
                let local = isLocal(job.id)
                JobChip(job: job, account: account(job, local), onOpen: { onOpenJob(job.id, local) },
                        onStop: onStopJob.map { stop in { stop(job.id, local) } })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(turn.who == .user ? "You" : "Oby"), \(ConversationModel.clock(turn.date)): \(turn.text)")
    }
}

/// The bubble hugs its text while its row fills the column; long text gets at most 75%.
struct MessageBubbleLayout: Layout {
    var trailing: Bool
    private func content(_ width: CGFloat, subviews: Subviews) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: min(width * 0.75, OBYStyle.threadWidth * 0.75), height: nil))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? OBYStyle.threadWidth
        return CGSize(width: width, height: content(width, subviews: subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = content(bounds.width, subviews: subviews)
        subviews[0].place(at: CGPoint(x: trailing ? bounds.maxX - size.width : bounds.minX, y: bounds.minY),
                          proposal: ProposedViewSize(size))
    }
}

struct ThinkingLine: View {
    /// Steps of the runner's turn run: "Working" instead of "Thinking" (#304).
    var working = false
    /// Why Stop didn't go through, or nil.
    var problem: String? = nil
    let onStop: () -> Void
    var body: some View {
        HStack(spacing: OBYStyle.Space.sm) {
            HStack(spacing: OBYStyle.Space.xs) {
                ForEach(0..<3) { _ in Circle().fill(OBYStyle.tertiary).frame(width: 4, height: 4) }
            }.accessibilityHidden(true)
            Text(working ? "Working" : "Thinking").font(OBYStyle.small).foregroundStyle(OBYStyle.tertiary)
            StopButton(action: onStop)
            if let problem {
                Text(problem).font(OBYStyle.caption).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(.vertical, OBYStyle.Space.sm)
    }
}

/// A job's screen in the middle column (apps/mac/app/JobView.swift), with Back: the same screen the island
/// opens, publishing after Touch ID the same way.
private struct JobPane: View {
    let model: IslandModel
    let id: String
    let local: Bool
    @State private var problem: String?

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }
    private var job: Job? { (local ? desk.jobs : feed.jobs).first { $0.id == id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let job {
                        screen(job)
                    } else if let problem {
                        Text(problem).font(OBYStyle.small).foregroundStyle(.red)
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(28)
            }
        }
        // A runner's job open here stays across new lists; one older than the latest 50 is fetched.
        .onChange(of: id, initial: true) { old, new in
            if old != new, !local { feed.showing(old, false) }
            guard !local else { return }
            feed.showing(new, true)
            Task {
                do { try await feed.fetch(new) } catch { problem = error.localizedDescription }
            }
        }
        .onDisappear { if !local { feed.showing(id, false) } }
    }

    @ViewBuilder private func screen(_ job: Job) -> some View {
        if local {
            JobView(job: job, place: "This Mac", account: desk.accounts.accounts.first { $0.account.id == job.account }?.account.name,
                    onStop: { desk.stop(job.id) },
                    publishing: JobView.Publishing(action: { Publish.action(for: job, base: job.base ?? "") },
                                                   publish: { _ in _ = try await desk.publish(job.id, approve: Publish.touchID) }),
                    onMessage: { try desk.message(job.id, $0) }, onDismiss: { try desk.dismiss(job.id) },
                    extras: RunnerJobExtras(local: job),
                    onMode: { try desk.changeMode(job.id, to: $0) },
                    onPermission: { try desk.answerPermission(job.id, $0, message: $1) },
                    accounts: desk.accounts.accounts,
                    onStartNow: { try desk.startNow(job.id) }, onUseAnyway: { _ = desk.liftReserve($0, true) },
                    readReport: {
                        guard let saved = desk.store.report(job.id) else { throw Shell.Failure(message: "This job has no research report.") }
                        return ResearchDocument(job: saved.job, commit: saved.commit, markdown: saved.markdown,
                                                proposals: saved.proposals.map { ResearchProposal(index: $0.index, repo: $0.repo, title: $0.title, body: $0.body, labels: $0.labels, filed: $0.filed, filedAt: $0.filedAt) })
                    },
                    fileProposal: { index, start in
                        guard var saved = desk.store.report(job.id),
                              let position = saved.proposals.firstIndex(where: { $0.index == index }) else {
                            throw Shell.Failure(message: "There's no proposed issue with that index.")
                        }
                        guard saved.proposals[position].filed == nil else { throw Shell.Failure(message: "This issue was already filed.") }
                        let proposal = saved.proposals[position]
                        do {
                            let findings = try await Publish.scan(texts: [("issue title", proposal.title), ("issue body", proposal.body)])
                            guard findings.isEmpty else { throw Shell.Failure(message: "The proposed issue didn't pass Oby's secret scan.") }
                        } catch { throw Shell.Failure(message: "Oby's secret scanner couldn't run or found a secret; nothing was filed.") }
                        let result = try await Shell.run(["gh", "issue", "create", "-R", proposal.repo, "--title", proposal.title, "--body-file", "-"],
                                                         input: Data(proposal.body.utf8), as: .app)
                        guard result.status == 0, let url = URL(string: result.text), url.scheme == "https", url.host == "github.com" else {
                            throw Shell.Failure(message: result.err.isEmpty ? "GitHub couldn't create the proposed issue." : result.err)
                        }
                        let issueURL = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.proposals[position].filed = issueURL
                        saved.proposals[position].filedAt = .now
                        desk.store.save(saved)
                        desk.sent(job.id, Outgoing(action: .issue, repo: proposal.repo, id: issueURL))
                        let number = url.path.split(separator: "/").last.flatMap { Int($0) }
                        var started: Job?
                        if start, let number {
                            started = try await desk.dispatch(Desk.NewJob(repo: proposal.repo, kind: "build", task: "Work on #\(number): \(proposal.title)", issue: number))
                        }
                        return FileProposalResult(issue: issueURL, jobId: started?.id)
                    })
        } else {
            JobView(job: job, place: feed.name, account: nil,
                    onStop: { Task { if let stopped = try? await feed.about(job.id, { try await $0.stop(job.id) }) { feed.apply(stopped) } } },
                    publishing: feed.device.key.isAvailable
                        ? JobView.Publishing(action: { try await feed.publishAction(job.id) }, publish: { try await feed.publish(job.id, action: $0) })
                        : nil,
                    onMessage: { text in if feed.runner != nil { feed.apply(try await feed.about(job.id) { try await $0.tell(job.id, text) }) } },
                    onDismiss: { if feed.runner != nil { feed.apply(try await feed.about(job.id) { try await $0.dismiss(job.id) }) } },
                    extras: feed.extras[job.id],
                    onMode: { try await feed.setMode(job.id, $0) },
                    onPermission: { try await feed.answer(job.id, $0, message: $1) },
                    accounts: feed.accounts,
                    onStartNow: { if feed.runner != nil { feed.apply(try await feed.about(job.id) { try await $0.startNow(job.id) }) } },
                    onUseAnyway: { account in if let runner = feed.runner { _ = try await runner.liftReserve(account, true) } },
                    readReport: { try await feed.about(job.id) { try await $0.report(job.id) } },
                    fileProposal: { index, start in try await feed.about(job.id) { try await $0.fileProposal(job.id, index: index, start: start) } })
        }
    }
}
