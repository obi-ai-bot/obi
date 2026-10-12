import AppKit
import SwiftUI

/// The Settings window's tabs, so the sidebar's Accounts and keys, Integrations, Memory and
/// Settings open the right one.
nonisolated enum SettingsTab: String, CaseIterable, Sendable { case general, runner, accounts, models, vault }

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

/// The Oby window (#11): the conversation with Oby, the Agents, and Live, in three columns, as
/// `docs/images/app-chat.webp` has it. Opened from the island, the menu and ⌘O. The island stays
/// the glance: this is where the thread lives.
final class ChatWindow: NSObject, NSWindowDelegate {
    private let island: IslandController
    private var window: NSWindow?
    /// What the middle column shows.
    private let state = ChatState()

    init(island: IslandController) { self.island = island }

    /// Shows the window, on the conversation or on a job's screen when one is named.
    func show(job: (id: String, local: Bool)? = nil) {
        if let job { state.selection = .job(id: job.id, local: job.local) }
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = ChatView(model: island.model, state: state, onOpenSettings: SettingsSelection.open)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Oby"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.09, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 600)
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.setFrameAutosaveName("ObyChat")
        if !window.setFrameUsingName("ObyChat") { window.center() }
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    var isOpen: Bool { window?.isVisible ?? false }
}

@Observable
final class ChatState {
    var selection = ChatSelection.oby
}

/// The three columns: the sidebar, the conversation (or a job's screen, or an empty state), and Live.
struct ChatView: View {
    let model: IslandModel
    let state: ChatState
    let onOpenSettings: (SettingsTab) -> Void

    private var selection: Binding<ChatSelection> {
        Binding { state.selection } set: { state.selection = $0 }
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, selection: selection, onOpenSettings: onOpenSettings)
                .frame(width: 272)
            Divider().overlay(.white.opacity(0.08))
            middle.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(.white.opacity(0.08))
            LiveView(model: model, onOpen: { state.selection = .job(id: $0, local: $1) })
                .frame(width: 300)
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.09))
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    @ViewBuilder private var middle: some View {
        switch state.selection {
        case .oby:
            ConversationColumn(model: model, onOpenJob: { state.selection = .job(id: $0, local: $1) })
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
            Text(detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.45)).frame(maxWidth: 480, alignment: .leading)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The conversation with Oby: the header, the thread by day (newest at the bottom), the turn under
/// way, the plan or question card, the inbox's decision cards, and the composer.
private struct ConversationColumn: View {
    let model: IslandModel
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    @State private var text = ""
    @FocusState private var typing: Bool

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }
    private var conversation: ConversationModel { feed.conversation }
    private var thinking: Bool { if case .thinking = desk.talk { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Oby").font(.system(size: 20, weight: .semibold))
                Text("Your dispatcher. Everything you asked today.").font(.system(size: 15)).foregroundStyle(.white.opacity(0.55))
                Spacer()
                if feed.down {
                    Text("\(feed.name) isn't reachable").font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 28).padding(.top, 46).padding(.bottom, 14)
            .accessibilityAddTraits(.isHeader)
            Divider().overlay(.white.opacity(0.08))
            thread
            composer.padding(.horizontal, 28).padding(.vertical, 16)
        }
        // Escape cancels the turn Oby is thinking about.
        .onExitCommand { if thinking { desk.cancel() } }
        .onAppear { typing = true }
    }

    // MARK: The thread

    private var thread: some View {
        // Every half minute: "Today" turns into "Yesterday" at midnight, and the inbox's waits move on.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let turns = conversation.thread(with: desk.turns)
            let days = ConversationModel.days(turns, now: context.date)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if conversation.hasOlder {
                            Button(conversation.loading ? "Loading…" : "Earlier") { Task { await conversation.loadOlder() } }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                                .disabled(conversation.loading)
                                .frame(maxWidth: .infinity)
                        }
                        if let problem = conversation.problem {
                            Text("The runner's thread couldn't be read: \(problem)").font(.system(size: 12)).foregroundStyle(.orange)
                        }
                        if turns.isEmpty, !thinking {
                            Text("Ask about the work, or type a task. Hold fn to talk.")
                                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.45)).padding(.top, 20)
                        }
                        ForEach(days) { day in
                            daySeparator(day.title)
                            ForEach(day.turns) { turn in
                                TurnRow(turn: turn, jobs: ConversationModel.jobs(of: turn, among: desk.jobs + feed.jobs),
                                        account: { LiveView.account(of: $0, local: $1, desk: desk, feed: feed) },
                                        isLocal: { id in desk.jobs.contains { $0.id == id } },
                                        onOpenJob: onOpenJob)
                                    .task(id: turn.jobs ?? []) {
                                        // A runner's job older than its list: fetched, so its card shows.
                                        for id in ConversationModel.missing(of: turn, among: desk.jobs + feed.jobs) { try? await feed.fetch(id) }
                                    }
                            }
                        }
                        if thinking { pending }
                        cards
                        if IslandInbox.waits(desk: desk, feed: feed, now: context.date) {
                            IslandInbox(desk: desk, feed: feed, onOpen: onOpenJob)
                        }
                        if model.speaker.speaking {
                            Text("Speaking · press fn to stop").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 28).padding(.vertical, 18)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: turns.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: desk.talk) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .accessibilityLabel("Conversation")
    }

    private func daySeparator(_ title: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).fixedSize()
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityAddTraits(.isHeader)
    }

    /// Oby's bubble while it thinks: never left there, with a way out in sight.
    private var pending: some View {
        HStack(alignment: .top, spacing: 12) {
            ObyFace(size: 30)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Thinking…").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                Button { desk.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20).background(.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
                .accessibilityLabel("Cancel")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// The plan before anything runs, or the brain's question, under the thread, as the island shows them.
    @ViewBuilder private var cards: some View {
        switch desk.talk {
        case .plan(let drafts) where drafts.count == 1:
            PlanCard(draft: drafts[0], accounts: desk.accounts.accounts.filter(\.signedIn),
                     onDispatch: { desk.dispatch(model.tray.attach($0)); model.tray.clear() },
                     onEdit: { text = typed(drafts[0].said); desk.cancel(); typing = true },
                     onCancel: { desk.cancel() })
                .frame(maxWidth: 720)
        case .plan(let drafts):
            PlansCard(drafts: drafts, accounts: desk.accounts.accounts.filter(\.signedIn),
                      onDispatch: { for draft in $0 { desk.dispatch(model.tray.attach(draft)) }; model.tray.clear() },
                      onEdit: { text = typed(drafts[0].said); desk.cancel(); typing = true },
                      onCancel: { desk.cancel() })
                .frame(maxWidth: 720)
        case .question(let said, let question):
            DecisionCard(title: question.text, options: CardOption.of(question.options),
                         onChoose: { desk.answer($0.answer, said: said, question: question.text) },
                         onWords: { desk.answer($0, said: said, question: question.text) })
                .padding(14)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 720)
        default:
            EmptyView()
        }
    }

    // MARK: The composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TrayRow(tray: model.tray)
            HStack(spacing: 6) {
                TextField("Tell Oby what you need. Hold fn to talk.", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($typing)
                    .onSubmit(send)
                Button(action: screenshot) {
                    Image(systemName: "camera").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(model.tray.capturing)
                .help("Show Oby your screen: drag over part of it, or click for all of it")
                .accessibilityLabel("Attach a screenshot")
                Button(action: model.tray.pasteClipboard) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Attach what you copied")
                .accessibilityLabel("Attach the clipboard")
                // Oby listens only while you hold the talk key: the mic here says so, and never opens by itself.
                Image(systemName: "mic").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 30)
                    .foregroundStyle(.white.opacity(0.55))
                    .help("Hold fn (or Control-Option) to talk. Oby listens only while you hold it.")
                    .accessibilityLabel("Hold fn to talk")
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 18).padding(.trailing, 7)
            .frame(height: 50)
            .background(.white.opacity(0.08), in: Capsule())
        }
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // The chips stay until Dispatch, which hands them to the jobs. The thread shows your words alone.
        desk.ask(model.tray.note.map { "\(text)\n\n\($0)" } ?? text, shown: text)
        text = ""
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

/// One turn: yours on the right in a light bubble, "You" or "You, by voice" with the time above
/// it; Oby's on the left with its face, "Oby" and the time, its words, and a card for each job it started.
private struct TurnRow: View {
    let turn: Turn
    let jobs: [Job]
    let account: (_ job: Job, _ local: Bool) -> String
    /// Whether a job is this Mac's own (else the runner's).
    let isLocal: (_ id: String) -> Bool
    let onOpenJob: (_ job: String, _ local: Bool) -> Void

    var body: some View {
        if turn.who == .user { yours } else { obys }
    }

    private var yours: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(turn.voice == true ? "You, by voice" : "You") · \(ConversationModel.clock(turn.date))")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                ReadingText(turn.text, color: Color(white: 0.1))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You, \(ConversationModel.clock(turn.date)): \(turn.text)")
    }

    private var obys: some View {
        HStack(alignment: .top, spacing: 12) {
            ObyFace(size: 30)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Oby").font(.system(size: 13, weight: .semibold))
                    Text("· \(ConversationModel.clock(turn.date))").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                ReadingText(turn.text, weight: .medium).textSelection(.enabled)
                ForEach(jobs) { job in
                    let local = isLocal(job.id)
                    JobCard(job: job, account: account(job, local), onOpen: { onOpenJob(job.id, local) })
                }
            }
            Spacer(minLength: 60)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Oby, \(ConversationModel.clock(turn.date)): \(turn.text)")
    }
}

/// A job under Oby's words: its tool's mark, its title, "Claude Code · Deskree · its step", and
/// the status pill. Click it for the job's screen.
private struct JobCard: View {
    let job: Job
    let account: String
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentMark(agent: job.agent).font(.system(size: 17, weight: .semibold)).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.heading).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text([job.agentName, account, job.line].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusBadge(job: job)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: 560)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the job")
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
                        Text(problem).font(.system(size: 13)).foregroundStyle(.red)
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
                    onStartNow: { try desk.startNow(job.id) })
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
                    onStartNow: { if feed.runner != nil { feed.apply(try await feed.about(job.id) { try await $0.startNow(job.id) }) } })
        }
    }
}
