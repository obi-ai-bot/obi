import SwiftUI

/// What the Chat tab works out with no view in the way, so the tests read it (iOSTests/ChatTests.swift).
nonisolated enum ChatThread {
    /// The words a send carries: trimmed, or nil for nothing to send.
    static func words(_ text: String) -> String? {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? nil : said
    }

    /// The runner lists the user's turn with Oby's answer, seconds after the send; its clock may
    /// differ from the phone's by this much.
    static let tolerance: TimeInterval = 60

    /// The echoes the runner hasn't listed yet. One is settled once the runner's turns hold the
    /// same words from the user, said at or after it (within `tolerance`): an older turn with the
    /// same words is another message.
    static func pending(_ echoes: [Turn], runner: [Turn]) -> [Turn] {
        echoes.filter { echo in
            !runner.contains { $0.who == .user && $0.text == echo.text && $0.date >= echo.date - tolerance }
        }
    }

    /// "Claude Code · Deskree · Running pnpm test", the job card's second line, from what's there.
    static func cardLine(_ job: Job, account: String) -> String {
        [job.agentName, account, job.line].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The Chat tab (#11): the one thread with Oby every device shares, as the Mac's window has it
/// (docs/images/app-chat.webp), on the phone. Oby's turns with its face and the time, yours as
/// bubbles, day separators, a card for each job a turn started and the inbox's decision cards,
/// "Working now" at the top, and the composer at the bottom. It opens on the latest turn and
/// follows new ones.
struct ChatScreen: View {
    @Environment(Phone.self) private var phone
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @FocusState private var typing: Bool
    /// The job screens open: a card opens its job here.
    @State private var path: [String] = []

    private var thinking: Bool { if case .thinking = phone.talk { true } else { false } }
    /// A step of Oby's turn runs, started from here or from another device (#304).
    private var working: Bool { phone.conversation.working }

    var body: some View {
        NavigationStack(path: $path) {
            thread
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Oby")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: String.self) { JobScreen(id: $0) }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if phone.active.contains(where: \.isWorking) {
                        WorkingNow(jobs: phone.active.filter(\.isWorking), waiting: phone.active.count(where: \.isWaiting), onOpen: { path.append($0) })
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Composer(text: $text, prompt: "Tell Oby what you need", typing: $typing, onSend: send)
                }
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    if case .offline = phone.connection {
                        ToolbarItem(placement: .topBarTrailing) {
                            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                                .accessibilityLabel("The runner isn't answering")
                        }
                    }
                }
                .onDisappear { phone.cancelVoice() }
                .onChange(of: scenePhase) { if scenePhase != .active { phone.leftForeground(background: scenePhase == .background) } }
                .onChange(of: path) { if !path.isEmpty { phone.cancelVoice() } }
        }
    }

    // MARK: The thread

    private var thread: some View {
        // Every half minute: "Today" turns into "Yesterday" at midnight, and the inbox's waits move on.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let turns = phone.thread
            let days = ConversationModel.days(turns, now: context.date)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if phone.conversation.hasOlder {
                            Button(phone.conversation.loading ? "Loading…" : "Earlier") {
                                // The page goes in above: the turn that was at the top stays there.
                                let top = turns.first?.id
                                Task {
                                    await phone.conversation.loadOlder()
                                    if let top { proxy.scrollTo(top, anchor: .top) }
                                }
                            }
                            .font(.footnote.weight(.semibold))
                            .disabled(phone.conversation.loading)
                            .frame(maxWidth: .infinity)
                        }
                        if let problem = phone.conversation.problem {
                            Text("The runner's thread couldn't be read: \(problem)").font(.footnote).foregroundStyle(.orange)
                        }
                        if turns.isEmpty, !thinking {
                            empty
                        }
                        ForEach(days) { day in
                            DaySeparator(title: day.title)
                            ForEach(day.turns) { turn in
                                TurnRow(turn: turn, jobs: ConversationModel.jobs(of: turn, among: phone.jobs), account: account,
                                        steps: phone.conversation.steps(under: turn, in: turns),
                                        failure: phone.failures[turn.id],
                                        onRetry: { phone.retry(echo: turn.id) },
                                        onEdit: { text = turn.text; phone.discard(echo: turn.id); typing = true })
                                    .id(turn.id)
                                    .task(id: turn.jobs ?? []) {
                                        // A job older than the runner's list: fetched, so its card shows.
                                        for id in ConversationModel.missing(of: turn, among: phone.jobs) { await phone.fetch(id) }
                                    }
                            }
                        }
                        if thinking || working { pending }
                        cards
                        InboxSection()
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
                // A new turn at the end, sent or received: follow it. A page of older ones above
                // keeps the reading position (Earlier scrolls to the turn that was at the top).
                .onChange(of: turns.last?.id) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: phone.talk) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: phone.conversation.steps) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: typing) { if typing { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .accessibilityLabel("Conversation")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            ObyFace(size: 44)
            Text("Ask about the work, or type a task.").font(.body.weight(.medium))
            Text(phone.loaded ? "What you and Oby say here shows on your Mac too." : "Reaching the runner…")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    /// Oby's bubble while it works: never left there, with a way out in sight. Stop ends the turn
    /// on the runner (#304); the cross, only while this phone waits for the plan, stops waiting.
    private var pending: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                ObyFace(size: 28)
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(working ? "Working…" : "Thinking…").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Button("Stop") { Task { await phone.stopTurn() } }
                        .font(.footnote.weight(.semibold))
                        .accessibilityHint("Ends what Oby is doing")
                    if thinking {
                        Button { phone.cancel() } label: {
                            Image(systemName: "xmark").font(.caption.weight(.bold))
                                .frame(width: 24, height: 24).background(Color.primary.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel waiting")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if let problem = phone.stopProblem {
                Text(problem).font(.footnote).foregroundStyle(.orange).padding(.leading, 38)
            }
        }
    }

    /// The plan before anything runs, or the brain's question, in the thread: the cards Home
    /// shows as sheets. A plan's and a question's words arrive as Oby's turn too, above them.
    @ViewBuilder private var cards: some View {
        switch phone.talk {
        case .plan(let drafts) where drafts.count == 1:
            card { PlanCard(draft: drafts[0], onEdit: edit) }
        case .plan(let drafts):
            card { PlansCard(drafts: drafts, onEdit: edit) }
        case .question(let said, let question):
            card {
                DecisionCard(title: question.text, plan: question.plan, options: question.cardOptions,
                             onChoose: { phone.answer($0.answer, said: said, question: question) },
                             onWords: { phone.answer($0, said: said, question: question) })
                    .padding(16)
            }
        default:
            EmptyView()
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The account's name as the runner knows it, else its id.
    private func account(_ job: Job) -> String {
        phone.accounts.first { $0.id == job.account }?.name ?? job.account
    }

    // MARK: The composer

    /// `spoken`: the draft has dictated words, so Oby may speak its reply.
    private func send(spoken: Bool) {
        phone.ask(text, spoken: spoken)
        text = ""
        typing = false
    }

    /// Edit on a plan card: its words go back in the field.
    private func edit(_ said: String) {
        text = said
        phone.cancel()
        typing = true
    }
}

/// "Today", "Yesterday", or the weekday and date, between the days of the thread.
private struct DaySeparator: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One turn: yours on the right in a bubble, "You" or "You, by voice" with the time above it, and
/// why it didn't go through with Try again and Edit when it didn't; Oby's on the left with its
/// face, "Oby" and the time, its words, and a card for each job it started.
private struct TurnRow: View {
    let turn: Turn
    let jobs: [Job]
    let account: (Job) -> String
    /// What Oby does for these words, a step at a time (#304): under them, before its answer.
    var steps: [TurnStep] = []
    /// Why the words didn't reach the runner, on an echo whose request failed (Phone.failures).
    var failure: String? = nil
    var onRetry: () -> Void = {}
    var onEdit: () -> Void = {}

    var body: some View {
        if turn.who == .user { yours } else { obys }
    }

    private var yours: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(turn.voice == true ? "You, by voice" : "You") · \(ConversationModel.clock(turn.date))")
                        .font(.caption).foregroundStyle(.secondary)
                    ReadingText(turn.text, color: Color(uiColor: .systemBackground))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.primary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if let failure {
                        Text("Didn't reach Oby: \(failure)")
                            .font(.footnote).foregroundStyle(.red).multilineTextAlignment(.trailing)
                        HStack(spacing: 16) {
                            Button("Try again", action: onRetry)
                            Button("Edit", action: onEdit)
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }
            }
            .accessibilityElement(children: failure == nil ? .combine : .contain)
            .accessibilityLabel(failure.map { "You, \(ConversationModel.clock(turn.date)): \(turn.text). Didn't reach Oby: \($0)" }
                                ?? "You, \(ConversationModel.clock(turn.date)): \(turn.text)")
            // What Oby does for these words, before its answer (#304).
            if !steps.isEmpty {
                StepList(steps: steps).padding(.leading, 4)
            }
        }
    }

    private var obys: some View {
        HStack(alignment: .top, spacing: 10) {
            ObyFace(size: 28)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Oby").font(.subheadline.weight(.semibold))
                    Text("· \(ConversationModel.clock(turn.date))").font(.caption).foregroundStyle(.secondary)
                }
                ReadingText(turn.text, weight: .medium).textSelection(.enabled)
                ForEach(jobs) { job in
                    JobCard(job: job, account: account(job))
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Oby, \(ConversationModel.clock(turn.date)): \(turn.text)")
    }
}

/// A job under Oby's words: its tool's mark, its title, "Claude Code · Deskree · its step", and
/// the status pill. Tap it for the job's screen (iOS/JobScreen.swift).
private struct JobCard: View {
    let job: Job
    let account: String

    var body: some View {
        NavigationLink(value: job.id) {
            HStack(alignment: .center, spacing: 12) {
                AgentMark(agent: job.agent).font(.body.weight(.semibold)).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.heading).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(ChatThread.cardLine(job, account: account)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                StatusPill(badge: job.badge)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the job")
    }
}

/// The Mac's Agents and Live, on the phone: a strip at the top of Chat with every agent working
/// now, its tool, the job's title and its step, and how many wait their turn (#238). Tap one for
/// its screen. At the accessibility text sizes the cards stack, so nothing is cut off.
private struct WorkingNow: View {
    let jobs: [Job]
    let waiting: Int
    let onOpen: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Newest first, as Live lists them.
    private var working: [Job] { jobs.sorted { $0.created > $1.created } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Working now · \(working.count)" + (Summary.waitingLine(waiting).map { " · \($0)" } ?? ""))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    ForEach(working) { job in card(job).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(working) { job in card(job).frame(width: 240, alignment: .leading) }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.top, 6).padding(.bottom, 8)
        .background(.bar)
    }

    private func card(_ job: Job) -> some View {
        Button { onOpen(job.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: job.agent).font(.subheadline.weight(.semibold)).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.heading).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(job.line.isEmpty ? job.agentName : job.line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the job")
    }
}
