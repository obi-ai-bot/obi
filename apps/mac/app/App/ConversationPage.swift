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

    private var thread: some View {
        // Every half minute: a time that turns into yesterday's, and the inbox's waits move on.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let turns = conversation.thread(with: desk.turns)
            let entries = (desk.inbox.map { IslandInbox.Entry(item: $0, local: true) }
                + (feed.inbox + feed.inboxHistory).map { IslandInbox.Entry(item: $0, local: false) })
                .filter { $0.item.isDecision && ($0.item.later == nil || $0.item.later! <= context.date) }
                .sorted { $0.item.created < $1.item.created }
            let waiting = entries.filter { $0.item.isOpen }
            let permissions = feed.chatPermissions.filter { $0.done != nil || $0.waits(at: context.date) }
            let permissionWaits = permissions.filter { $0.waits(at: context.date) }
            let oldest = (waiting.map { ($0.id, $0.item.created) } + permissionWaits.map { ($0.id, $0.created) }).min { $0.1 < $1.1 }?.0
            let anchors = Dictionary(uniqueKeysWithValues: entries.map {
                ($0.id, ConversationModel.decisionAnchor(job: $0.item.job, created: $0.item.created, turns: turns))
            })
            let rows = ChatRuns.rows(turns)
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if feed.down { RunnerOfflineNotice(name: feed.name) }
                    if let oldest {
                        WaitingBar(count: waiting.count + permissionWaits.count) {
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
                                Text("Ask Oby anything. Hold fn to talk.").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
                                    .frame(maxWidth: .infinity).padding(.top, 40)
                            }
                            ForEach(entries.filter { anchors[$0.id] == .some(nil) }) { decision($0, active: oldest == $0.id).padding(.bottom, 12) }
                            ForEach(permissions.filter { ConversationModel.decisionAnchor(job: $0.job, created: $0.created, turns: turns) == nil }) { record in
                                permission(record, active: oldest == record.id).id(record.id).padding(.bottom, 12)
                            }
                            ForEach(Array(rows.enumerated()), id: \.element.turn.id) { index, row in
                                MessageRow(row: row, first: index == 0, now: context.date,
                                           jobs: ConversationModel.jobs(of: row.turn, among: desk.jobs + feed.jobs),
                                           account: { LiveView.account(of: $0, local: $1, desk: desk, feed: feed) },
                                           isLocal: { id in desk.jobs.contains { $0.id == id } },
                                           steps: conversation.steps(under: row.turn, in: turns),
                                           onOpenJob: onOpenJob, onStopJob: { model.stopChatJob($0, local: $1) })
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
                                ObyAtWork(working: conversation.working, problem: feed.stopProblem, onStop: stop)
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
                       onStop: { if thinking { desk.cancel(); return true }; return false },
                       onEscape: onBack, usage: model.usageRows)
                .disabled(sendingAnswer)
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
        if route != .oby, words.count > 2000 { sendProblem = "An answer can be at most 2,000 characters."; return }
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
    let account: (_ job: Job, _ local: Bool) -> String
    let isLocal: (_ id: String) -> Bool
    let steps: [TurnStep]
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    let onStopJob: (_ job: String, _ local: Bool) -> Void

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
            } else {
                if !turn.text.isEmpty { SaidText(text: turn.text, color: Tokens.item) }
                if let markdown = ConversationModel.markdownDetails(for: turn) {
                    Text(markdown).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item).lineSpacing(6).textSelection(.enabled)
                }
            }
            // What Oby did for these words: Oby's side, whoever's turn it hangs from.
            if !steps.isEmpty { Steps(steps: steps).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(jobs) { job in
                let local = isLocal(job.id)
                ThreadTask(job: job, account: account(job, local), onOpen: { onOpenJob(job.id, local) },
                           onStop: { onStopJob(job.id, local) })
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
}

/// Your bubble hugs its words, at most 80% of the column.
private struct BubbleLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Tokens.column
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: width * 0.8, height: nil))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width * 0.8, height: nil))
        subviews[0].place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}

/// What Oby (or you) said: paragraphs a blank line apart, lines starting "- " as a list, and
/// links, references, paths and `code` set apart as Sangam's message box does.
struct SaidText: View {
    let text: String
    var color: Color = Tokens.item
    /// Yours: as typed, no paragraphs or lists.
    var plain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.allSatisfy({ $0.hasPrefix("- ") }) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(block.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(Tokens.muted)
                                Text(Self.styled(String(line.dropFirst(2))))
                            }
                        }
                    }
                } else {
                    Text(Self.styled(block.joined(separator: "\n")))
                }
            }
        }
        .font(Tokens.font(Tokens.textBase)).foregroundStyle(color).lineSpacing(6)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var blocks: [[String]] {
        if plain { return [[text]] }
        return text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\n") }
    }

    /// Inline markdown as Oby writes it (bold, links, `code`), then what the message box
    /// recognises set apart on top: links and references in blue, paths and code in coral monospace.
    static func styled(_ text: String) -> AttributedString {
        var string = Reading.markdown(text, code: Tokens.mono(13))
        for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true { coral(&string, run.range) }
        let plain = String(string.characters)
        for match in SaidTokens.matches(plain) {
            let start = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let count = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let lower = string.characters.index(string.startIndex, offsetBy: start)
            let range = lower..<string.characters.index(lower, offsetBy: count)
            // Already code or a link in the markdown: left as it is.
            if string[range].runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true || $0.link != nil }) { continue }
            switch match.kind {
            case .url:
                string[range].foregroundColor = Tokens.link
                if let url = URL(string: String(plain[match.range])) { string[range].link = url }
            case .ref: string[range].foregroundColor = Tokens.link
            case .code, .path: coral(&string, range)
            }
        }
        for run in string.runs where run.link != nil { string[run.range].foregroundColor = Tokens.link }
        return string
    }

    private static func coral(_ string: inout AttributedString, _ range: Range<AttributedString.Index>) {
        string[range].foregroundColor = Tokens.code
        string[range].font = Tokens.mono(13)
        string[range].backgroundColor = Tokens.pill
    }
}

/// What Oby did for your words (#304), folded into one line over its answer: a click opens them,
/// each with its mark.
private struct Steps: View {
    let steps: [TurnStep]
    @State private var open = false

    private var label: String {
        let running = steps.contains { $0.state == .running }
        if running, let current = steps.last(where: { $0.state == .running }) { return current.text }
        return "Took \(steps.count) step\(steps.count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(Tokens.warm) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(label).font(Tokens.font(Tokens.textMd))
                    Image(systemName: "chevron.right").font(Tokens.font(10, .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(Tokens.muted).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Open" : "Folded")
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(steps) { step in
                        HStack(spacing: 8) {
                            Group {
                                switch step.state {
                                case .running: ProgressView().controlSize(.mini)
                                case .done: Image(systemName: "checkmark").foregroundStyle(Tokens.check)
                                case .failed: Image(systemName: "xmark").foregroundStyle(Tokens.danger)
                                }
                            }
                            .font(Tokens.font(10, .semibold)).frame(width: 12)
                            Text(step.text).font(Tokens.font(Tokens.textMd)).foregroundStyle(step.state == .failed ? Tokens.danger : Tokens.muted)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(step.text), \(step.state.spoken)")
                    }
                }
            }
        }
    }
}

/// A task an answer started, as a small card under it (Sangam's ThreadTask): its agent's mark,
/// its title, where it stands and who has it, its mark, and a chevron; a click opens its page.
private struct ThreadTask: View {
    let job: Job
    let account: String
    let onOpen: () -> Void
    let onStop: () -> Void
    @State private var hovering = false

    var body: some View {
        let mark = ThreadTaskLine.mark(job)
        card(mark)
            .overlay(alignment: .topTrailing) {
                if hovering && job.isActive { StopButton(action: onStop).padding(.top, 8).padding(.trailing, 38) }
            }
            .onHover { hovering = $0 }
    }

    private func card(_ mark: WorkMark) -> some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: job.agent).font(Tokens.font(13, .semibold)).frame(width: 16).padding(.top, 1)
                    .foregroundStyle(Tokens.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.heading).font(Tokens.font(Tokens.textMd, .medium)).foregroundStyle(Tokens.ink).fadeOut()
                    Text(ThreadTaskLine.meta(job: job, mark: mark, account: account)).font(Tokens.font(Tokens.textSm))
                        .foregroundStyle(Tokens.muted).fadeOut()
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
            if job.isActive { Button("Stop", action: onStop) }
        }
    }
}

/// Oby at work, last in the thread: its face, and what it's on with a sheen crossing it, and Stop.
private struct ObyAtWork: View {
    let working: Bool
    let problem: String?
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ObyMark()
            HStack(spacing: 10) {
                Sheen(text: working ? "Working" : "Thinking")
                StopButton(action: onStop)
                if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.needs) }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A line being worked on: a lighter band sweeps across it, left to right, every 1.6 seconds
/// (Sangam's `sheen`); still, in ink, with Reduce Motion.
struct Sheen: View {
    let text: String
    var size: CGFloat = Tokens.textMd
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let label = Text(text).font(Tokens.font(size))
        if reduceMotion {
            label.foregroundStyle(Tokens.ink)
        } else {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                // The band's middle crosses from before the start to past the end.
                let middle = phase * 1.6 - 0.3
                label.foregroundStyle(LinearGradient(stops: [
                    .init(color: Tokens.muted, location: 0),
                    .init(color: Tokens.muted, location: min(1, max(0, middle - 0.15))),
                    .init(color: Tokens.ink, location: min(1, max(0, middle))),
                    .init(color: Tokens.muted, location: min(1, max(0, middle + 0.15))),
                    .init(color: Tokens.muted, location: 1),
                ], startPoint: .leading, endPoint: .trailing))
            }
            .accessibilityLabel(text)
        }
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

/// Oby's small face in a conversation (Sangam's ObyFace.tsx): its soft white block, a little wider
/// than tall, two tall dark eyes, and two short ears on top leaning toward each other. Drawn in a
/// 24-unit square.
struct ObyMark: View {
    var size: CGFloat = 22

    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / 24
            let body = Color(hex: 0xF1F1EE), eye = Color(hex: 0x0D0D0E)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            var ears = Path()
            ears.addLines([point(5, 6.6), point(7.9, 3.6), point(8.9, 6.6)]); ears.closeSubpath()
            ears.addLines([point(19, 6.6), point(16.1, 3.6), point(15.1, 6.6)]); ears.closeSubpath()
            context.fill(ears, with: .color(body))
            context.stroke(ears, with: .color(body), style: StrokeStyle(lineWidth: 1.2 * unit, lineJoin: .round))
            context.fill(Path(roundedRect: CGRect(x: 1.5 * unit, y: 6 * unit, width: 21 * unit, height: 16.5 * unit), cornerRadius: 5 * unit), with: .color(body))
            for x in [6.0, 14.6] {
                context.fill(Path(roundedRect: CGRect(x: x * unit, y: 10.6 * unit, width: 2.8 * unit, height: 5 * unit), cornerRadius: 1.4 * unit), with: .color(eye))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
