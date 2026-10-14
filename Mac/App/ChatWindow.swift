import AppKit
import SwiftUI

/// The Settings window's tabs, so the sidebar's Accounts and keys, Integrations, Memory and
/// Settings open the right one.
nonisolated enum SettingsTab: String, CaseIterable, Sendable { case general, runner, remote, accounts, models, vault, about }

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

/// A messenger window for Oby and the running agents, opened from the notch or ⌘O.
final class ChatWindow: NSObject, NSWindowDelegate {
    private let island: IslandController
    private var window: NSWindow?
    /// What the middle column shows.
    private let state = ChatState()

    init(island: IslandController) { self.island = island }

    /// Shows the window, on the conversation or on a job's screen when one is named.
    func show(job: (id: String, local: Bool)? = nil) {
        state.open(job: job)
        island.model.chatWindowVisible = true
        if job == nil { island.model.markChatRead() }
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = ChatView(model: island.model, state: state, onOpenSettings: SettingsSelection.open)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Oby"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.09, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 740, height: 540)
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.setFrameAutosaveName("ObyChat")
        if !window.setFrameUsingName("ObyChat") { window.center() }
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) { island.model.chatWindowVisible = false }
    func windowDidMiniaturize(_ notification: Notification) { island.model.chatWindowVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) {
        island.model.chatWindowVisible = true
        if state.selection == .oby { island.model.markChatRead() }
    }

    var isOpen: Bool { window?.isVisible ?? false }
}

@Observable
final class ChatState {
    var selection = ChatSelection.oby
    var composerFocusRequest = 0

    func open(job: (id: String, local: Bool)? = nil) {
        selection = job.map { .job(id: $0.id, local: $0.local) } ?? .oby
        if job == nil { composerFocusRequest += 1 }
    }
}

/// The chat list and the selected thread, with working agents tucked into a disclosure.
struct ChatView: View {
    let model: IslandModel
    let state: ChatState
    let onOpenSettings: (SettingsTab) -> Void
    @AppStorage("ObyChatLiveExpanded") private var liveExpanded = false

    private var selection: Binding<ChatSelection> {
        Binding { state.selection } set: { state.selection = $0 }
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, selection: selection, onOpenSettings: onOpenSettings)
                .frame(width: 272)
            middle.frame(maxWidth: .infinity, maxHeight: .infinity)
            if liveExpanded {
                LiveView(model: model, onOpen: { state.selection = .job(id: $0, local: $1) }).frame(width: 290)
            }
        }
        .foregroundStyle(.white)
        .background(OBYStyle.window)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    @ViewBuilder private var middle: some View {
        switch state.selection {
        case .oby:
            ConversationColumn(model: model, liveExpanded: $liveExpanded, composerFocusRequest: state.composerFocusRequest, onOpenJob: { state.selection = .job(id: $0, local: $1) })
        case .job(let id, let local):
            JobPane(model: model, id: id, local: local, onBack: { state.selection = .oby })
        case .channels:
            placeholder("# channels", SidebarSections.channelsEmpty, detail: "A channel is where you, your team and your Obys post heads-ups, and where other Obys ask yours for a review.")
        case .obys:
            placeholder("Obys", SidebarSections.obysEmpty, detail: "Other people's Obys will show here with what they're running, and what they're waiting on from you.")
        }
    }

    private func placeholder(_ title: String, _ line: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(line).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Text(detail).font(OBYStyle.small).foregroundStyle(OBYStyle.tertiary).frame(maxWidth: 480, alignment: .leading)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The conversation with Oby: the header, the thread by day (newest at the bottom), the turn under
/// way, the plan or question card, the inbox's decision cards, and the composer.
private struct ConversationColumn: View {
    let model: IslandModel
    @Binding var liveExpanded: Bool
    let composerFocusRequest: Int
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    @State private var text = ""
    @State private var editingIssueDraft: RunnerIssueDraft?
    struct ReplyTarget {
        var title: String
        var send: @MainActor (String) async throws -> Void
    }
    @State private var replyTarget: ReplyTarget?
    @State private var sendingAnswer = false
    @State private var sendProblem: String?
    @State private var decisionFocus = 0
    @State private var columnHeight: CGFloat = 600
    @State private var typing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }
    private var conversation: ConversationModel { feed.conversation }
    private var thinking: Bool { if case .thinking = desk.talk { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OBYStyle.Space.md) {
                ObyFace(size: 30).background(OBYStyle.surface, in: Circle()).clipShape(Circle())
                Text("Oby").font(OBYStyle.title)
                Spacer()
                Button { liveExpanded.toggle() } label: {
                    Label("Live · \(model.working)", systemImage: "sidebar.right")
                        .font(OBYStyle.small.weight(.medium))
                        .padding(OBYStyle.Space.sm)
                        .background(liveExpanded ? OBYStyle.surface : .clear, in: Capsule())
                }
                .buttonStyle(.plain).accessibilityValue(liveExpanded ? "Open" : "Closed")
                Menu {
                    Button("Accounts") { SettingsSelection.open(.accounts) }
                    Button("Integrations") { SettingsSelection.open(.runner) }
                    Button("Settings") { SettingsSelection.open(.general) }
                } label: { Image(systemName: "ellipsis").font(OBYStyle.title) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Chat menu")
            }
            .padding(.horizontal, OBYStyle.Space.xl).padding(.top, 46).padding(.bottom, OBYStyle.Space.lg)
            .accessibilityAddTraits(.isHeader)
            thread
            composer.padding(.horizontal, 28).padding(.vertical, 16)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }
        // Escape cancels the turn Oby is thinking about.
        .onExitCommand { if thinking { desk.cancel() } }
        .onAppear { typing = true; model.markChatRead() }
        .onChange(of: composerFocusRequest) { typing = true }
        .onChange(of: model.thread.last?.id) { if model.chatWindowVisible { model.markChatRead() } }
    }

    // MARK: The thread

    private var thread: some View {
        // Every half minute: "Today" turns into "Yesterday" at midnight, and the inbox's waits move on.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let turns = conversation.thread(with: desk.turns)
            let days = ConversationModel.days(turns, now: context.date)
            let entries = (desk.inbox.map { IslandInbox.Entry(item: $0, local: true) }
                + (feed.inbox + feed.inboxHistory).map { IslandInbox.Entry(item: $0, local: false) })
                .filter { $0.item.isDecision && ($0.item.later == nil || $0.item.later! <= context.date) }
                .sorted { $0.item.created < $1.item.created }
            let waiting = entries.filter { $0.item.isOpen }
            let permissions = feed.chatPermissions.filter { $0.done != nil || $0.waits(at: context.date) }
            let permissionWaits = permissions.filter { $0.waits(at: context.date) }
            let oldest = (waiting.map { ($0.id, $0.item.created) } + permissionWaits.map { ($0.id, $0.created) })
                .min { $0.1 < $1.1 }?.0
            let waitingCount = waiting.count + permissionWaits.count
            let anchors = Dictionary(uniqueKeysWithValues: entries.map {
                ($0.id, ConversationModel.decisionAnchor(job: $0.item.job, created: $0.item.created, turns: turns))
            })
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if feed.down {
                        RunnerOfflineNotice(name: feed.name)
                    }
                    if let oldest {
                        Button { typing = false; decisionFocus += 1; proxy.scrollTo(oldest, anchor: .center) } label: {
                            HStack {
                                Image(systemName: "exclamationmark.bubble")
                                Text("\(waitingCount) waiting for you")
                                Spacer()
                                Text("⌘J")
                            }
                            .font(OBYStyle.caption).foregroundStyle(OBYStyle.secondary)
                            .padding(.horizontal, OBYStyle.Space.xl).padding(.vertical, OBYStyle.Space.sm)
                        }
                        .buttonStyle(.plain).keyboardShortcut("j", modifiers: .command)
                        .background(OBYStyle.sidebar)
                    }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if conversation.hasOlder {
                            Button(conversation.loading ? "Loading…" : "Earlier") { Task { await conversation.loadOlder() } }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(OBYStyle.secondary)
                                .disabled(conversation.loading)
                                .frame(maxWidth: .infinity)
                        }
                        if let problem = conversation.problem {
                            Text("The runner's thread couldn't be read: \(problem)").font(OBYStyle.caption).foregroundStyle(.orange)
                        }
                        if turns.isEmpty, !thinking {
                            Text("Ask Oby anything. Hold fn to talk.")
                                .font(.system(size: 14)).foregroundStyle(OBYStyle.tertiary).padding(.top, 20)
                        }
                        ForEach(entries.filter { anchors[$0.id] == .some(nil) }) { entry in
                            decision(entry, active: oldest == entry.id)
                        }
                        ForEach(permissions.filter { ConversationModel.decisionAnchor(job: $0.job, created: $0.created, turns: turns) == nil }) { record in
                            permission(record, active: oldest == record.id).id(record.id)
                        }
                        ForEach(days) { day in
                            ForEach(Array(day.turns.enumerated()), id: \.element.id) { index, turn in
                                TurnRow(turn: turn, grouped: ConversationModel.grouped(turn, after: index > 0 ? day.turns[index - 1] : nil), jobs: ConversationModel.jobs(of: turn, among: desk.jobs + feed.jobs),
                                        issueDraft: turn.issueDraft.flatMap { feed.issueDrafts[$0] },
                                        onCreateIssue: { id, version in Task { try? await feed.createIssueDraft(id, version: version) } },
                                        onDiscardIssue: { id in
                                            leaveIssueEdit(id)
                                            Task { try? await feed.discardIssueDraft(id) }
                                        },
                                        onEditIssue: { draft in editingIssueDraft = draft; sendProblem = nil; text = draft.preview; typing = true },
                                        account: { LiveView.account(of: $0, local: $1, desk: desk, feed: feed) },
                                        isLocal: { id in desk.jobs.contains { $0.id == id } },
                                        onOpenJob: onOpenJob,
                                        onStopJob: { model.stopChatJob($0, local: $1) },
                                        showTime: ConversationModel.showsTime(turn, after: index > 0 ? day.turns[index - 1] : nil),
                                        steps: conversation.steps(under: turn, in: turns))
                                    .task(id: turn.jobs ?? []) {
                                        // A runner's job older than its list: fetched, so its card shows.
                                        for id in ConversationModel.missing(of: turn, among: desk.jobs + feed.jobs) { try? await feed.fetch(id) }
                                    }
                                ForEach(entries.filter { anchors[$0.id] == .some(turn.id) }) { entry in
                                    decision(entry, active: oldest == entry.id)
                                }
                                ForEach(permissions.filter { ConversationModel.decisionAnchor(job: $0.job, created: $0.created, turns: turns) == turn.id }) { record in
                                    permission(record, active: oldest == record.id).id(record.id)
                                }
                            }
                        }
                        if thinking || conversation.working { pending }
                        cards
                        if model.speaker.speaking {
                            Text("Speaking · press fn to stop").font(.system(size: 11)).foregroundStyle(OBYStyle.tertiary)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: OBYStyle.threadWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, OBYStyle.Space.xl).padding(.vertical, OBYStyle.Space.lg)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: turns.count) { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: desk.talk) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: conversation.steps) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .accessibilityLabel("Conversation")
    }

    private func decision(_ entry: IslandInbox.Entry, active: Bool) -> some View {
        InlineDecision(entry: entry, desk: desk, feed: feed, keyboardEnabled: active, focusRequest: decisionFocus, onOpen: onOpenJob,
                       onTell: {
                           guard !sendingAnswer else { return }
                           replyTarget = ReplyTarget(title: entry.item.title, send: { value in
                               if entry.local { try await desk.answer(entry.item.id, .answer(value)) }
                               else { try await feed.settle(entry.item.id, answer: value) }
                           })
                           sendProblem = nil
                           typing = true
                       })
            .id(entry.id)
    }

    private func permission(_ record: RunnerFeed.PermissionRecord, active: Bool) -> some View {
        InlinePermission(record: record, feed: feed, keyboardEnabled: active, focusRequest: decisionFocus,
                         onTell: {
                             guard !sendingAnswer else { return }
                             replyTarget = ReplyTarget(title: record.permission.title, send: { value in
                                 guard feed.extras[record.job]?.permission?.id == record.permission.id else {
                                     throw RunnerError(message: "This request has already been answered.")
                                 }
                                 try await feed.answer(record.job, .deny, message: value)
                             })
                             sendProblem = nil
                             typing = true
                         })
    }

    /// "Thinking" while the desk plans, "Working" while the runner's steps go; Stop ends the
    /// runner's turn (#304) as well as the desk's.
    private var pending: some View {
        ThinkingLine(working: conversation.working, problem: feed.stopProblem, onStop: {
            if thinking { desk.cancel() }
            if conversation.working { Task { await feed.stopTurn() } }
        })
    }

    /// The plan before anything runs, or the brain's question, under the thread, as the island shows them.
    @ViewBuilder private var cards: some View {
        switch desk.talk {
        case .question(let said, let question):
            DecisionCard(title: question.text, options: question.cardOptions, keyboardEnabled: true, onLater: { desk.cancel() },
                         onChoose: { desk.answer($0.answer, said: said, question: question.text) },
                         onWords: { desk.answer($0, said: said, question: question.text) })
                .padding(14)
                .background(OBYStyle.surface, in: RoundedRectangle(cornerRadius: OBYStyle.card, style: .continuous))
                .frame(maxWidth: 720)
        default:
            EmptyView()
        }
    }

    // MARK: The composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: OBYStyle.Space.sm) {
            if let replyTarget {
                HStack {
                    Text("Replying to \(replyTarget.title)").font(OBYStyle.caption).foregroundStyle(OBYStyle.secondary).lineLimit(1)
                    Spacer()
                    Button { self.replyTarget = nil; sendProblem = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).disabled(sendingAnswer).accessibilityLabel("Cancel reply")
                }
            }
            if let editingIssueDraft {
                HStack {
                    Text("Editing \(editingIssueDraft.fields.title)").font(OBYStyle.caption).foregroundStyle(OBYStyle.secondary).lineLimit(1)
                    Spacer()
                    Button { leaveIssueEdit(editingIssueDraft.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).disabled(sendingAnswer).accessibilityLabel("Cancel edit")
                }
            }
            if let sendProblem {
                HStack {
                    Text(sendProblem).font(OBYStyle.caption).foregroundStyle(.red)
                    Button("Try again", action: send).buttonStyle(.plain).font(OBYStyle.caption)
                }
            }
            if sendingAnswer { ProgressView().controlSize(.small).accessibilityLabel("Sending answer") }
            ChatComposer(text: $text, focused: $typing, tray: model.tray,
                         maximumHeight: columnHeight * 0.5, focusRequest: composerFocusRequest,
                         onSend: send, onScreenshot: screenshot,
                         onStop: { if thinking { desk.cancel(); return true }; return false })
                .disabled(sendingAnswer)
        }
    }

    /// Leaves the issue-draft edit in the composer (Discard, Cancel, or a successful PUT).
    private func leaveIssueEdit(_ id: String, clearText: Bool = true) {
        guard editingIssueDraft?.id == id else { return }
        editingIssueDraft = RunnerIssueDraft.composerAfterLeaving(editingIssueDraft, draftID: id)
        if clearText { text = "" }
        sendProblem = nil
        typing = false
    }

    private func send() {
        let value = text
        guard !sendingAnswer, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let draft = editingIssueDraft {
            guard let fields = draft.fields.editing(value) else {
                sendProblem = "Keep the What, Why, How and acceptance headings, with one checkbox test per line."
                return
            }
            sendingAnswer = true
            sendProblem = nil
            Task {
                defer { sendingAnswer = false }
                do {
                    try await feed.editIssueDraft(draft.id, version: draft.version, fields: fields)
                    leaveIssueEdit(draft.id, clearText: text == value)
                } catch { sendProblem = error.localizedDescription }
            }
            return
        }
        guard let target = replyTarget else {
            model.sendChat(value)
            text = ""
            return
        }
        sendingAnswer = true
        sendProblem = nil
        Task {
            defer { sendingAnswer = false }
            do {
                try await target.send(value)
                if text == value { text = "" }
                replyTarget = nil
            } catch { sendProblem = error.localizedDescription }
        }
    }

    /// Your words without the line about the chips, to edit them: it's added again when you send.
    private func typed(_ said: String) -> String {
        said.range(of: "\n\n(The user attached ").map { String(said[..<$0.lowerBound]) } ?? said
    }

    /// The camera: the overlay takes the keyboard while you pick, so the field takes it back after.
    private func screenshot() {
        Task {
            await model.tray.screenshot()
            typing = true
        }
    }
}

/// Shared messenger bubbles: no per-message chrome, one centered timestamp above each group.
struct TurnRow: View {
    let turn: Turn
    var grouped = false
    let jobs: [Job]
    var issueDraft: RunnerIssueDraft? = nil
    var onCreateIssue: (String, Int) -> Void = { _, _ in }
    var onDiscardIssue: (String) -> Void = { _ in }
    var onEditIssue: (RunnerIssueDraft) -> Void = { _ in }
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
            if let issueDraft {
                IssueDraftCard(draft: issueDraft, keyboardEnabled: true,
                               onCreate: { onCreateIssue(issueDraft.id, issueDraft.version) },
                               onEdit: { onEditIssue(issueDraft) },
                               onDiscard: { onDiscardIssue(issueDraft.id) })
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

/// A job's screen in the middle column (Mac/JobView.swift), with Back: the same screen the island
/// opens, publishing after Touch ID the same way.
private struct JobPane: View {
    let model: IslandModel
    let id: String
    let local: Bool
    let onBack: () -> Void
    @State private var problem: String?

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }
    private var job: Job? { (local ? desk.jobs : feed.jobs).first { $0.id == id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Text(job?.heading ?? "Job \(id)").font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 46).padding(.bottom, 14)
            Divider().overlay(.white.opacity(0.08))
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
                    onStartNow: { try desk.startNow(job.id) }, onUseAnyway: { _ = desk.liftReserve($0, true) })
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
                    onUseAnyway: { account in if let runner = feed.runner { _ = try await runner.liftReserve(account, true) } })
        }
    }
}
