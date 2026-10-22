import SwiftUI

extension ChatThread {
    /// "Claude Code · Deskree · Running pnpm test", the job card's second line, from what's there.
    static func cardLine(_ job: Job, account: String) -> String {
        [job.agentName, account, job.line].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The side panel's Conversations (Sangam's Sidebar.tsx, #493): obid's conversations, Pinned then
/// Recent, each with its last line and how long ago; search finds them by what was said. Swipe to
/// delete, hold for Pin and Rename. A runner that keeps one thread lists just that one.
struct ConversationsColumn: View {
    @Environment(Phone.self) private var phone
    /// Opens a conversation over Home, closing the panel.
    let open: (Route) -> Void
    @State private var query = ""
    /// What the search found, or nil while there's no search.
    @State private var found: [RunnerConversation]?
    @State private var renaming: RunnerConversation?
    @State private var title = ""
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(Tokens.font(13)).foregroundStyle(Tokens.muted)
                TextField("Search conversations", text: $query)
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.ink)
                    .submitLabel(.search)
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(Tokens.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tokens.line) }
            .padding(.horizontal, 12).padding(.bottom, 8)
            list
        }
        .task(id: query) { await search() }
        .alert("Rename conversation", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Name", text: $title)
            Button("Save") { if let renaming { rename(renaming.id) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var list: some View {
        if let conversations = found ?? phone.conversations {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                List {
                    let sections = ConversationOrder.sections(conversations)
                    if conversations.isEmpty {
                        Text(found == nil ? "No conversations yet" : "Nothing matches “\(query)”")
                            .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
                    }
                    if !sections.pinned.isEmpty {
                        Section { rows(sections.pinned, now: context.date) } header: { label("Pinned") }
                    }
                    if !sections.recent.isEmpty {
                        // No headings while nothing's pinned, as the design has it.
                        if sections.pinned.isEmpty { Section { rows(sections.recent, now: context.date) } }
                        else { Section { rows(sections.recent, now: context.date) } header: { label("Recent") } }
                    }
                    if let problem {
                        Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .listSectionSpacing(0)
                .refreshable { await phone.reload() }
            }
        } else {
            // A runner with one thread: that thread.
            List {
                Button { open(.conversation(nil)) } label: {
                    row(title: "Oby", last: phone.conversation.runnerTurns.last?.text, at: phone.conversation.runnerTurns.last?.date, now: .now)
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.label).textCase(nil)
    }

    private func rows(_ list: [RunnerConversation], now: Date) -> some View {
        ForEach(list) { conversation in
            Button { open(.conversation(conversation.id)) } label: {
                row(title: conversation.title.isEmpty ? "Conversation" : conversation.title,
                    last: conversation.turn?.text ?? phone.previews[conversation.id], at: conversation.latest, now: now)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .task { await phone.preview(conversation.id) }
            .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) { run { try await phone.delete(conversation.id) } }
            }
            .contextMenu {
                Button(conversation.pinned ? "Unpin" : "Pin", systemImage: conversation.pinned ? "pin.slash" : "pin") {
                    run { try await phone.update(conversation.id, pinned: !conversation.pinned) }
                }
                Button("Rename", systemImage: "pencil") { title = conversation.title; renaming = conversation }
                Button("Delete", systemImage: "trash", role: .destructive) { run { try await phone.delete(conversation.id) } }
            }
        }
    }

    private func row(title: String, last: String?, at: Date?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item).fadeOut()
                Spacer(minLength: 8)
                if let at, at > .distantPast {
                    Text(ConversationOrder.ago(at, now: now)).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                }
            }
            if let last, !last.isEmpty {
                Text(last).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).fadeOut()
            }
        }
        .padding(.vertical, 4)
    }

    /// obid's own search (`?q=`), a moment after the typing stops.
    private func search() async {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, phone.conversations != nil else { found = nil; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            found = try await phone.runner.conversations(query: words) ?? []
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    private func rename(_ id: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        run { try await phone.update(id, title: name) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); problem = nil } catch { problem = error.localizedDescription }
        }
    }
}

/// A conversation with Oby (Sangam's ChatView.tsx, the Mac's ConversationPage): your words in
/// bubbles at the right, Oby's as plain text under its face, in runs with the time under each; the
/// tasks an answer started as cards under it, and their decisions; Oby at work, with what it's
/// on; its question, when it asks one; and the box at the foot.
struct ConversationPage: View {
    @Environment(Phone.self) private var phone
    @Environment(\.scenePhase) private var scenePhase
    /// obid's conversation, or nil for the latest (the one thread).
    let id: String?
    /// The one Home's box just started: it's the thread shown until obid names it.
    var isNew = false
    @State private var adopted: String?
    @State private var text = ""
    @FocusState private var typing: Bool
    @State private var renaming = false
    @State private var title = ""
    @State private var problem: String?

    private var shown: String? { isNew ? adopted : id }
    private var conversation: RunnerConversation? { shown.flatMap { id in phone.conversations?.first { $0.id == id } } }
    private var thinking: Bool { if case .thinking = phone.talkHere { true } else { false } }
    private var working: Bool { phone.conversation.working }

    var body: some View {
        thread
            .obyPage()
            .navigationTitle(conversation?.title ?? (isNew ? "New conversation" : "Oby"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Composer(text: $text, prompt: "Reply to Oby…", typing: $typing, onSend: send,
                         onStop: thinking || working ? { Task { await phone.stopTurn() } } : nil)
            }
            .keepsDraft($text, as: Drafts.conversation(shown))
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                if let conversation {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(conversation.pinned ? "Unpin" : "Pin", systemImage: conversation.pinned ? "pin.slash" : "pin") {
                                run { try await phone.update(conversation.id, pinned: !conversation.pinned) }
                            }
                            Button("Rename", systemImage: "pencil") { title = conversation.title; renaming = true }
                        } label: { Image(systemName: "ellipsis") }
                            .accessibilityLabel("Conversation options")
                    }
                }
            }
            .alert("Rename conversation", isPresented: $renaming) {
                TextField("Name", text: $title)
                Button("Save") {
                    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let id = conversation?.id, !name.isEmpty { run { try await phone.update(id, title: name) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { if !isNew || adopted != nil { phone.show(shown) } }
            .onChange(of: phone.current, initial: true) {
                if isNew, adopted == nil, !phone.startingNew, let current = phone.current { adopted = current }
            }
            .onDisappear { phone.cancelVoice() }
            .onChange(of: scenePhase) { if scenePhase != .active { phone.leftForeground(background: scenePhase == .background) } }
    }

    private var thread: some View {
        // Every half minute: a time that turns into yesterday's, and what was put off comes back.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let turns = phone.thread
            let rows = ChatRuns.rows(turns)
            // The jobs shown where they started: a follow-up told elsewhere goes with its parent's card.
            let startedBy = { (job: Job) in ThreadTaskLine.startedBy(turn: job.turn, in: job.conversation, showing: shown) }
            let placed = ThreadTaskLine.shown(in: turns, jobs: phone.jobs, startedBy: startedBy, ended: phone.conversation.endedTurn)
            let decisions = InboxItem.waiting(phone.inbox, now: context.date)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if phone.conversation.hasOlder {
                            Button(phone.conversation.loading ? "Loading…" : "Earlier") {
                                let top = turns.first?.id
                                Task {
                                    await phone.conversation.loadOlder()
                                    if let top { proxy.scrollTo(top, anchor: .top) }
                                }
                            }
                            .font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text)
                            .disabled(phone.conversation.loading)
                            .frame(maxWidth: .infinity).padding(.bottom, 16)
                        }
                        if let problem = phone.conversation.problem {
                            Text("The runner's thread couldn't be read: \(problem)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.needsInk)
                                .padding(.bottom, 12)
                        }
                        if turns.isEmpty, !thinking {
                            if !phone.startingNew, phone.conversation.problem == nil, !phone.conversation.loaded, !phone.connection.isOffline {
                                ThreadBones()
                            } else {
                                Text(phone.loaded ? "Ask Oby anything." : "Reaching the runner…").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
                                    .frame(maxWidth: .infinity).padding(.top, 40)
                            }
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.turn.id) { index, row in
                            MessageRow(row: row, first: index == 0, now: context.date,
                                       jobs: ThreadTaskLine.cards(under: row.turn, in: turns, jobs: phone.jobs, startedBy: startedBy),
                                       followUps: { phone.conversation.endedTurn(row.turn) ? [] : ThreadTaskLine.attached(to: $0, in: phone.jobs, shown: placed) },
                                       steps: phone.conversation.steps(under: row.turn, in: turns),
                                       streamed: phone.conversation.streamed(under: row.turn, in: turns),
                                       failure: phone.failures[row.turn.id],
                                       waiting: phone.waitsToSend(echo: row.turn.id),
                                       onRetry: { phone.retry(echo: row.turn.id) },
                                       onEdit: { text = row.turn.text; phone.discard(echo: row.turn.id); typing = true })
                                .id(row.turn.id)
                                .task(id: row.turn.jobs ?? []) {
                                    // A job older than the runner's list: fetched, so its card shows.
                                    for id in ConversationModel.missing(of: row.turn, among: phone.jobs) { await phone.fetch(id) }
                                }
                            ForEach(decisions.filter { row.turn.jobs?.contains($0.job) ?? false }) { item in
                                InboxDecision(item: item).padding(.top, 12)
                            }
                        }
                        // Until its words come: they show it at work from then.
                        if thinking || working, phone.conversation.streamed.isEmpty {
                            ObyAtWork(line: working ? "Working" : "Thinking", problem: phone.stopProblem, waiting: thinking,
                                      onCancel: { phone.cancel() })
                                .padding(.top, rows.last?.turn.who == .oby ? 12 : 16)
                        }
                        if case .question(let said, let question) = phone.talkHere {
                            AskCard(kind: AskKind.label("question", plan: question.plan != nil), title: question.text, plan: question.plan,
                                    options: question.cardOptions, hint: "Or answer in your own words below",
                                    onChoose: { phone.answer($0.answer, said: said, question: question) },
                                    onLater: { phone.cancel() })
                                .padding(16)
                                .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
                                .padding(.top, 16)
                        }
                        if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 8) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Tokens.gutter).padding(.top, 12).padding(.bottom, 16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: turns.last?.id) { withAnimation(Tokens.warm) { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: phone.talk) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: phone.conversation.steps) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: phone.conversation.streamed) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: typing) { if typing { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .accessibilityLabel("Conversation with Oby")
    }

    /// While Oby asks its question, words in the box answer it; else they're a message for Oby.
    private func send(spoken: Bool) {
        if case .question(let said, let question) = phone.talkHere {
            phone.answer(text, said: said, question: question)
        } else {
            phone.ask(text, spoken: spoken)
        }
        text = ""
        typing = false
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); problem = nil } catch { problem = error.localizedDescription }
        }
    }
}

/// One message in its run: yours in a bubble at the right, Oby's as plain text under its face (on
/// the first of its run), then what Oby did for it and the tasks it started, and the time under
/// the last of a run.
private struct MessageRow: View {
    @Environment(Phone.self) private var phone
    let row: ChatRuns.Row
    let first: Bool
    let now: Date
    let jobs: [Job]
    /// The follow-ups that go with a job's card, told somewhere the thread doesn't show.
    let followUps: (Job) -> [Job]
    let steps: [TurnStep]
    /// Oby's words for these, while they're still being written.
    var streamed: ConversationModel.Streamed?
    /// Why the words didn't reach the runner, on an echo whose request failed.
    var failure: String?
    /// The words wait on this iPhone for the Mac (docs/oby-ux.md row 18).
    var waiting = false
    var onRetry: () -> Void
    var onEdit: () -> Void

    private var turn: Turn { row.turn }
    private var yours: Bool { turn.who == .user }

    var body: some View {
        VStack(alignment: yours ? .trailing : .leading, spacing: 10) {
            if !yours && !row.continues { ObyMark().padding(.bottom, -2) }
            if yours {
                BubbleLayout {
                    SaidText(text: turn.text, color: Tokens.ink, plain: true)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Tokens.bubble, in: RoundedRectangle(cornerRadius: Tokens.bubbleRadius, style: .continuous))
                }
                if waiting {
                    Text(ReachNotice.waiting).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                }
                if let failure {
                    Text("Didn't reach Oby: \(failure)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger)
                        .multilineTextAlignment(.trailing)
                    HStack(spacing: 16) {
                        Button("Try again", action: onRetry)
                        Button("Edit", action: onEdit)
                    }
                    .font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.ink)
                }
            } else {
                if !turn.text.isEmpty { ArrivingSaid(text: turn.text, color: Tokens.item, since: phone.conversation.arrived[turn.id]) }
                if let markdown = ConversationModel.markdownDetails(for: turn) {
                    Text(markdown).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).lineSpacing(6).textSelection(.enabled)
                }
            }
            // What Oby did for these words (#304), folded into one line once its words come, then the words as they arrive.
            if !steps.isEmpty { ToolSteps(steps: steps, words: streamed != nil) }
            if let streamed { StreamingAnswer(streamed: streamed) }
            ForEach(phone.conversation.artifactRefs(of: turn), id: \.self) { ArtifactShelf(ref: $0) }
            ForEach(jobs) { job in
                ThreadTask(job: job, account: phone.accountName(job.account))
                ForEach(job.artifacts ?? [], id: \.self) { ArtifactShelf(ref: $0) }
                ForEach(followUps(job)) { next in
                    Text(ThreadTaskLine.followUp(next, account: phone.accountName(next.account))).font(Tokens.font(Tokens.textMd))
                        .foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ThreadTask(job: next, account: phone.accountName(next.account))
                }
            }
            if row.endsRun {
                Text(ChatRuns.clock(turn.date, now: now)).font(Tokens.font(11)).monospacedDigit().foregroundStyle(Tokens.muted)
                    .padding(.top, -4)
            }
        }
        .frame(maxWidth: .infinity, alignment: yours ? .trailing : .leading)
        // The same speaker 4 apart, a new one 24.
        .padding(.top, first ? 0 : row.continues ? 4 : 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(yours ? "You" : "Oby"), \(ChatRuns.clock(turn.date, now: now)): \(turn.text)")
    }
}

/// A task an answer started, as a small card under it (Sangam's ThreadTask): its agent's mark,
/// its title, "Running · agent · account · repo", its mark and a chevron; a tap opens its page.
struct ThreadTask: View {
    @Environment(\.push) private var push
    let job: Job
    let account: String

    var body: some View {
        let mark = ThreadTaskLine.mark(job)
        Button { push(.task(job.id)) } label: {
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: job.agent).font(Tokens.font(13, .semibold)).frame(width: 16).padding(.top, 1)
                    .foregroundStyle(Tokens.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.heading).font(Tokens.font(Tokens.textMd, .medium)).foregroundStyle(Tokens.ink).lineLimit(1)
                    Text(ThreadTaskLine.meta(job: job, mark: mark, account: account)).font(Tokens.font(Tokens.textSm))
                        .foregroundStyle(Tokens.muted).lineLimit(1)
                    JobCardLines(job: job).padding(.top, 4)
                }
                Spacer(minLength: 4)
                WorkMarkView(mark: mark).padding(.top, 3)
                Image(systemName: "chevron.right").font(Tokens.font(11, .semibold)).padding(.top, 3)
                    .foregroundStyle(Tokens.muted.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.line) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(job.heading), \(ThreadTaskLine.status(mark))")
    }
}

/// Oby at work, last in the thread: its face, and what it's on with a sheen crossing it, Stop,
/// and while this phone waits for the answer, a way to stop waiting.
private struct ObyAtWork: View {
    let line: String
    let problem: String?
    let waiting: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Melting into dots that bounce until its words land (Sangam's ObyFaceLive).
            ObyFaceLive(live: true)
            HStack(spacing: 12) {
                Sheen(text: line)
                if waiting {
                    Button("Cancel", action: onCancel).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                        .accessibilityHint("Stops waiting for the answer")
                }
            }
            if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.needsInk) }
        }
        .accessibilityElement(children: .contain)
    }
}

/// An artifact's card, resolved from obid when the thread doesn't know it yet.
private struct ArtifactShelf: View {
    @Environment(Phone.self) private var phone
    let ref: ArtifactRef

    var body: some View {
        let artifact = phone.conversation.artifacts[ref.id]
        ArtifactCard(ref: ref, artifact: artifact, gone: phone.conversation.gone.contains(ref.id), runner: phone.runner,
                     agent: phone.jobs.first { $0.id == artifact?.job }?.agentName)
            .task(id: ref) { await phone.conversation.resolve(ref.id) }
    }
}
