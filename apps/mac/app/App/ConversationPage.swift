import AppKit
import SwiftUI

/// The conversation with Oby (Sangam's ChatView.tsx): your words in bubbles on the right, Oby's
/// as plain text on the left under its face, in runs with the time under each; the tasks an answer
/// started as cards under it; decisions as cards where they belong, answerable in place; Oby at
/// work last; and the message box at the foot. It shows the conversation picked in the side panel (obid
/// keeps many, #493), or the runner's one thread.
struct ConversationPage: View {
    let model: IslandModel
    let composerFocusRequest: Int
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    /// Esc with nothing to stop: back a page.
    let onBack: () -> Void
    @State private var text = ""
    struct ReplyTarget {
        var title: String
        var send: @MainActor (String) async throws -> Void
    }
    @State private var replyTarget: ReplyTarget?
    @State private var sendingAnswer = false
    @State private var sendProblem: String?
    @State private var decisionFocus = 0
    @State private var height: CGFloat = 600
    @State private var typing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }
    private var conversation: ConversationModel { feed.conversation }
    private var thinking: Bool { if case .thinking = desk.talk { true } else { false } }

    var body: some View {
        VStack(spacing: 0) {
            thread
            if case .question(let said, let question) = desk.talk {
                BrainQuestion(question: question, onChoose: { desk.answer($0, said: said, question: question.text) }, onLater: { desk.cancel() })
                    .frame(maxWidth: Tokens.column).padding(.horizontal, Tokens.gutter).padding(.top, 8)
                    .transition(.opacity.combined(with: .offset(y: 12)))
            }
            if model.listening {
                ListeningLine(voice: model.voice).frame(maxWidth: Tokens.column).padding(.horizontal, Tokens.gutter).padding(.top, 8)
            }
            composer
                .frame(maxWidth: Tokens.column).padding(.horizontal, Tokens.gutter)
                .padding(.top, 8).padding(.bottom, Tokens.gutter)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // Esc stops the turn Oby is thinking about; with nothing to stop, it goes back a page.
        .onExitCommand { if thinking { desk.cancel() } else { onBack() } }
        .onAppear { typing = true; model.markChatRead() }
        .onChange(of: composerFocusRequest) { typing = true }
        .onChange(of: model.thread.last?.id) { if model.chatWindowVisible { model.markChatRead() } }
    }

    // MARK: The thread

    /// Whether a runner job's decision shows in this conversation: only its own jobs' (C3), and an
    /// item with no job only in the conversation it came from (`InboxWords.conversation`).
    private func own(_ job: String, _ turns: [Turn], item: String? = nil) -> Bool {
        ConversationModel.shows(decisionOf: job, startedIn: feed.extras[job]?.conversation,
                                from: item.flatMap { feed.inboxWords[$0]?.conversation },
                                served: feed.conversations.served, shown: feed.conversations.shown, turns: turns)
    }

    private var thread: some View {
        // Every half minute: a time that turns into yesterday's, and the inbox's waits move on.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let turns = conversation.thread(with: model.localTurns)
            let entries = (desk.inbox.map { IslandInbox.Entry(item: $0, local: true) }
                + (feed.inbox + feed.inboxHistory).map { IslandInbox.Entry(item: $0, local: false) })
                .filter { $0.item.isDecision && ($0.item.later == nil || $0.item.later! <= context.date) }
                .filter { $0.local || own($0.item.job, turns, item: $0.item.id) }
                .sorted { $0.item.created < $1.item.created }
            let waiting = entries.filter { $0.item.isOpen }
            // The watcher's and the listener's items: no job, no conversation, so on top of the thread.
            let notices = feed.notices.filter { $0.carded && $0.waiting(at: context.date) }
            let permissions = feed.chatPermissions.filter { ($0.done != nil || $0.waits(at: context.date)) && own($0.job, turns) }
            let permissionWaits = permissions.filter { $0.waits(at: context.date) }
            let oldest = (waiting.map { ($0.id, $0.item.created) } + permissionWaits.map { ($0.id, $0.created) }
                + notices.map { ("notice/\($0.id)", $0.created) }).min { $0.1 < $1.1 }?.0
            let anchors = Dictionary(uniqueKeysWithValues: entries.map {
                ($0.id, ConversationModel.decisionAnchor(job: $0.item.job, created: $0.item.created, turns: turns))
            })
            let rows = ChatRuns.rows(turns)
            // Every job a card may show, which words started each (obid's `turn`), and those shown where they started.
            let all = desk.jobs + feed.jobs
            let startedBy = { (job: Job) in
                ThreadTaskLine.startedBy(turn: feed.extras[job.id]?.turn, in: feed.extras[job.id]?.conversation,
                                         showing: feed.conversations.shown)
            }
            let shown = ThreadTaskLine.shown(in: turns, jobs: all, startedBy: startedBy, ended: conversation.endedTurn)
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if feed.down { RunnerOfflineNotice(name: feed.name) }
                    if let oldest {
                        WaitingBar(count: waiting.count + permissionWaits.count + notices.count) {
                            typing = false; decisionFocus += 1
                            withAnimation(Tokens.warm) { proxy.scrollTo(oldest, anchor: .center) }
                        }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if conversation.hasOlder {
                                Button(conversation.loading ? "Loading…" : "Earlier") { Task { await conversation.loadOlder() } }
                                    .buttonStyle(ChipButtonStyle()).disabled(conversation.loading)
                                    .frame(maxWidth: .infinity).padding(.bottom, 16)
                            }
                            if let problem = conversation.problem {
                                Text("The runner's thread couldn't be read: \(problem)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.needs)
                                    .padding(.bottom, 12)
                            }
                            if turns.isEmpty, !thinking {
                                if conversation.problem == nil, !feed.conversations.starting, !conversation.loaded, !feed.down {
                                    ThreadBones()
                                } else {
                                    Text("Ask Oby anything. Hold fn to talk.").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
                                        .frame(maxWidth: .infinity).padding(.top, 40)
                                }
                            }
                            ForEach(notices) { notice in
                                InlineNotice(notice: notice, feed: feed, keyboardEnabled: oldest == "notice/\(notice.id)", focusRequest: decisionFocus,
                                             onOpen: { onOpenJob($0, false) })
                                    .id("notice/\(notice.id)").padding(.bottom, 12)
                            }
                            ForEach(entries.filter { anchors[$0.id] == .some(nil) }) { decision($0, active: oldest == $0.id).padding(.bottom, 12) }
                            ForEach(permissions.filter { ConversationModel.decisionAnchor(job: $0.job, created: $0.created, turns: turns) == nil }) { record in
                                permission(record, active: oldest == record.id).id(record.id).padding(.bottom, 12)
                            }
                            ForEach(Array(rows.enumerated()), id: \.element.turn.id) { index, row in
                                MessageRow(row: row, first: index == 0, now: context.date,
                                           jobs: ThreadTaskLine.cards(under: row.turn, in: turns, jobs: all, startedBy: startedBy),
                                           followUps: { conversation.endedTurn(row.turn) ? [] : ThreadTaskLine.attached(to: $0, in: all, shown: shown) },
                                           account: { LiveView.account(of: $0, local: $1, desk: desk, feed: feed) },
                                           isLocal: { id in desk.jobs.contains { $0.id == id } },
                                           steps: conversation.steps(under: row.turn, in: turns),
                                           arrived: conversation.arrived[row.turn.id],
                                           streamed: conversation.streamed(under: row.turn, in: turns),
                                           conversation: conversation, feed: feed,
                                           onOpenJob: onOpenJob, onStopJob: { model.stopChatJob($0, local: $1) },
                                           onRetry: { feed.retryEcho(row.turn.id); desk.ask(row.turn.text) },
                                           onEdit: { feed.dropEcho(row.turn.id); text = row.turn.text; typing = true })
                                    .task(id: row.turn.jobs ?? []) {
                                        // A runner's job older than its list: fetched, so its card shows.
                                        for id in ConversationModel.missing(of: row.turn, among: desk.jobs + feed.jobs) { try? await feed.fetch(id) }
                                    }
                                ForEach(entries.filter { anchors[$0.id] == .some(row.turn.id) }) { decision($0, active: oldest == $0.id).padding(.top, 12) }
                                ForEach(permissions.filter { ConversationModel.decisionAnchor(job: $0.job, created: $0.created, turns: turns) == row.turn.id }) { record in
                                    permission(record, active: oldest == record.id).id(record.id).padding(.top, 12)
                                }
                            }
                            if thinking || conversation.working {
                                ObyAtWork(working: conversation.working, problem: feed.stopProblem, face: conversation.streamed.isEmpty)
                                    .padding(.top, rows.last?.turn.who == .oby ? 12 : 16)
                            }
                            if model.speaker.speaking {
                                Text("Speaking · press fn to stop").font(Tokens.font(11)).foregroundStyle(Tokens.muted).padding(.top, 8)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: Tokens.column)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Tokens.gutter).padding(.top, 16).padding(.bottom, 24)
                    }
                    .scrollIndicators(.never)
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: turns.count) { withAnimation(reduceMotion ? nil : Tokens.warm) { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: desk.talk) { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: conversation.steps) { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: conversation.streamed) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .accessibilityLabel("Conversation with Oby")
    }

    private func stop() {
        if thinking { desk.cancel() }
        if conversation.working { Task { await feed.stopTurn() } }
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

    // MARK: The message box

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyTarget {
                HStack(spacing: 6) {
                    if sendingAnswer { ProgressView().controlSize(.mini).accessibilityLabel("Sending answer") }
                    Text("Replying to \(replyTarget.title)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).fadeOut()
                    Button { self.replyTarget = nil; sendProblem = nil } label: {
                        Image(systemName: "xmark").font(Tokens.font(10, .semibold)).foregroundStyle(Tokens.muted)
                    }
                    .buttonStyle(.plain).disabled(sendingAnswer).accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 12)
            }
            if let sendProblem {
                HStack(spacing: 8) {
                    Text(sendProblem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger)
                    Button("Try again", action: send).buttonStyle(.plain).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.ink)
                }
                .padding(.horizontal, 12)
            }
            MessageBox(text: $text, focused: $typing, tray: model.tray,
                       placeholder: replyTarget == nil ? "Reply to Oby…" : "Your answer…", label: "Reply to Oby",
                       maximumHeight: height * 0.5, focusRequest: composerFocusRequest,
                       onSend: send, onScreenshot: screenshot,
                       onStop: { guard thinking || conversation.working else { return false }; stop(); return true },
                       onEscape: onBack, usage: model.usageRows,
                       voice: model.voice, talkKeyListening: model.listening,
                       onStopTurn: stop, working: thinking || conversation.working)
                .disabled(sendingAnswer)
                .keepsDraft($text, as: Drafts.conversation(feed.conversations.shown))
        }
    }

    /// What's typed: an answer when a card asked for one in words (`replyTarget`), the answer to
    /// Oby's own question while one waits, else words for Oby.
    private func send() {
        let value = text
        let words = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sendingAnswer, !words.isEmpty else { return }
        let question: (said: String, text: String)? = if case .question(let said, let question) = desk.talk { (said, question.text) } else { nil }
        let route = ChatSend.route(replying: replyTarget != nil, questionWaits: question != nil)
        // An answer goes to an agent or the brain as one message, at most 2,000 characters.
        if route != .oby, words.count > ChatSend.most { sendProblem = ChatSend.tooLong; return }
        switch route {
        case .answer:
            if let question { desk.answer(value, said: question.said, question: question.text) }
            text = ""
            return
        case .oby:
            model.sendChat(value)
            text = ""
            return
        case .reply: break
        }
        guard let target = replyTarget else { return }
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

    private func screenshot() {
        Task {
            await model.tray.screenshot()
            typing = true
        }
    }
}

/// One message in its run: yours in a bubble at the right, Oby's as plain text under its face (on
/// the first of its run), then what Oby did for it (folded) and the tasks it started, and the time
/// under the last of a run.
private struct MessageRow: View {
    let row: ChatRuns.Row
    let first: Bool
    let now: Date
    let jobs: [Job]
    /// The follow-ups that go with a job's card, told somewhere the thread doesn't show.
    let followUps: (Job) -> [Job]
    let account: (_ job: Job, _ local: Bool) -> String
    let isLocal: (_ id: String) -> Bool
    let steps: [TurnStep]
    /// When Oby's answer came while the thread was open: its words come in from then.
    let arrived: Date?
    /// Oby's words for these, while they're still being written.
    let streamed: ConversationModel.Streamed?
    let conversation: ConversationModel
    let feed: RunnerFeed
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    let onStopJob: (_ job: String, _ local: Bool) -> Void
    /// On words that didn't reach the runner (`RunnerFeed.Echo`): send them again, or take them back
    /// into the box.
    let onRetry: () -> Void
    let onEdit: () -> Void

    private var turn: Turn { row.turn }
    private var yours: Bool { turn.who == .user }

    var body: some View {
        VStack(alignment: yours ? .trailing : .leading, spacing: yours ? 15 : 12) {
            if !yours && !row.continues { ObyMark().padding(.bottom, -4) }
            if yours {
                BubbleLayout {
                    SaidText(text: turn.text, color: Tokens.ink, plain: true)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Tokens.bubble, in: RoundedRectangle(cornerRadius: Tokens.bubbleRadius, style: .continuous))
                }
                if let problem = feed.echoProblem(turn.id) {
                    Text("Didn't reach Oby: \(problem)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger)
                        .multilineTextAlignment(.trailing).padding(.top, -9)
                    HStack(spacing: 16) {
                        Button("Try again", action: onRetry)
                        Button("Edit", action: onEdit)
                    }
                    .buttonStyle(.plain).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.ink)
                }
            } else {
                if !turn.text.isEmpty { ArrivingSaid(text: turn.text, color: Tokens.item, since: arrived) }
                if let markdown = ConversationModel.markdownDetails(for: turn) {
                    Text(markdown).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item).lineSpacing(6).textSelection(.enabled)
                }
            }
            // What Oby did for these words, folded into one line once its words come, then the words as
            // they arrive: Oby's side, whoever's turn it hangs from.
            if !steps.isEmpty { ToolSteps(steps: steps, words: streamed != nil) }
            if let streamed { StreamingAnswer(streamed: streamed) }
            ForEach(conversation.artifactRefs(of: turn), id: \.self) { artifact($0) }
            ForEach(jobs) { job in
                let local = isLocal(job.id)
                ThreadTask(job: job, account: account(job, local), on: local ? nil : feed.extras[job.id]?.runsOn.map { RunnerMac.person($0.owner) },
                           onOpen: { onOpenJob(job.id, local) }, onStop: { onStopJob(job.id, local) })
                if !local { ForEach(feed.extras[job.id]?.artifacts ?? [], id: \.self) { artifact($0) } }
                ForEach(followUps(job)) { next in
                    let local = isLocal(next.id)
                    Text(ThreadTaskLine.followUp(next, account: account(next, local))).font(Tokens.font(Tokens.textMd))
                        .foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ThreadTask(job: next, account: account(next, local), on: local ? nil : feed.extras[next.id]?.runsOn.map { RunnerMac.person($0.owner) },
                               onOpen: { onOpenJob(next.id, local) }, onStop: { onStopJob(next.id, local) })
                }
            }
            if row.endsRun {
                Text(ChatRuns.clock(turn.date, now: now)).font(Tokens.font(11)).monospacedDigit().foregroundStyle(Tokens.muted)
                    .padding(.top, -9)
            }
        }
        .frame(maxWidth: .infinity, alignment: yours ? .trailing : .leading)
        .padding(.top, first ? 0 : row.continues ? (yours ? 4 : 12) : (yours ? 24 : 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(yours ? "You" : "Oby"), \(ChatRuns.clock(turn.date, now: now)): \(turn.text)")
    }

    /// An artifact's card, resolved from the runner when the thread doesn't know it yet.
    private func artifact(_ ref: ArtifactRef) -> some View {
        let artifact = conversation.artifacts[ref.id]
        return ArtifactCard(ref: ref, artifact: artifact, gone: conversation.gone.contains(ref.id), runner: feed.runner,
                            agent: feed.jobs.first { $0.id == artifact?.job }?.agentName)
            .task(id: ref) { await conversation.resolve(ref.id) }
    }
}

/// A task an answer started, as a small card under it (Sangam's ThreadTask): its agent's mark,
/// its title, where it stands and who has it, its mark, and a chevron; a click opens its page.
struct ThreadTask: View {
    let job: Job
    let account: String
    /// Whose Mac it runs on, when not this one (#808).
    var on: String? = nil
    let onOpen: () -> Void
    var onStop: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        let mark = ThreadTaskLine.mark(job)
        // No Stop on hover (Sangam's ThreadTask has none, and it covered the mark): the menu and the
        // task's page stop it.
        card(mark)
            .onHover { hovering = $0 }
    }

    private func card(_ mark: WorkMark) -> some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: job.agent).font(Tokens.font(13, .semibold)).frame(width: 16).padding(.top, 1)
                    .foregroundStyle(Tokens.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.heading).font(Tokens.font(Tokens.textMd, .medium)).foregroundStyle(Tokens.ink).fadeOut()
                    Text(ThreadTaskLine.meta(job: job, mark: mark, account: account, on: on)).font(Tokens.font(Tokens.textSm))
                        .foregroundStyle(Tokens.muted).fadeOut()
                    JobCardLines(job: job).padding(.top, 4)
                }
                WorkMarkView(mark: mark).padding(.top, 3)
                Image(systemName: "chevron.right").font(Tokens.font(11, .semibold)).padding(.top, 3)
                    .foregroundStyle(hovering ? Tokens.text : Tokens.muted.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(hovering ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovering ? Tokens.lineStrong : Tokens.line) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Tokens.fade, value: hovering)
        .accessibilityLabel("Open \(job.heading), \(ThreadTaskLine.status(mark))")
        .contextMenu {
            Button("Open task", action: onOpen)
            if job.isActive, let onStop { Button("Stop", action: onStop) }
        }
    }
}

/// Oby at work, last in the thread: its face, and what it's on with a sheen crossing it, and Stop.
private struct ObyAtWork: View {
    let working: Bool
    let problem: String?
    /// Its face, unless its words already show it under way. Stop is in the box (A14).
    var face = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Melting into dots that bounce until its words land (Sangam's ObyFaceLive), as on the iPhone.
            if face { ObyFaceLive(live: true) }
            HStack(spacing: 10) {
                Sheen(text: working ? "Working" : "Thinking")
                if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.needs) }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// "2 waiting for you", over the thread: a click (or ⌘J) scrolls to the oldest and gives it the keys.
private struct WaitingBar: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(Tokens.needs).frame(width: 6, height: 6)
                Text("\(count) waiting for you").font(Tokens.font(Tokens.textMd))
                Spacer()
                Text("⌘J").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
            }
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 16).frame(height: 34)
            .background(Tokens.chip, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("j", modifiers: .command)
        .frame(maxWidth: Tokens.column)
        .padding(.horizontal, Tokens.gutter).padding(.top, 8)
    }
}

/// Oby asking you something back (the brain's question, not a task's), over the message box
/// until you answer: a pick, or your own words below.
private struct BrainQuestion: View {
    let question: Plan.Question
    let onChoose: (String) -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskCard(kind: "Question", title: question.text, options: question.cardOptions, keyboardEnabled: true,
                    hint: "Or answer in your own words below", onChoose: { onChoose($0.answer) }, onLater: onLater)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
    }
}
