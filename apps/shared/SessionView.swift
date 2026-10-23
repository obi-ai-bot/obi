import SwiftUI

// A job's session, live, read like a conversation (Sangam's SessionView, #786; obi-ai-bot/obi#785):
// rounds as dividers, the agent's words in full by its mark as it writes them, its thinking folded,
// each tool call a quiet line that opens into what it ran and what came back, your words as
// bubbles, its to-do list as a checklist, and values from the vault as chips with their name, never
// the value. Filters with counts over it; pinned to the live end, with Jump to now when you've
// scrolled up while it runs. The Mac shows it as a page in the trail, the iPhone as a full-screen
// sheet (`compact`). Not on the Watch.

struct SessionView: View {
    let session: LiveSession
    /// "claude", "codex" or "cursor": the mark by its words.
    let agent: String
    /// "Claude Code · Opus 5.5 · Personal".
    let meta: String
    /// The job runs (or waits on you): new entries may come.
    let live: Bool
    var compact = false
    /// The Mac's page shows the title; the iPhone's sheet has it in its bar.
    var title = true
    @State private var filter = TranscriptEntry.Filter.all
    @State private var atEnd = true

    var body: some View {
        let entries = session.entries
        let counts = session.counts
        let shown = filter == .all ? entries : entries.filter { $0.kind == "start" || filter.takes($0) }
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    head(counts)
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if session.trimmed {
                            Text("Older entries aren't shown: these are the latest \(LiveSession.most.formatted()).")
                                .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                        }
                        ForEach(shown) { entry in
                            SessionRow(entry: entry, agent: agent, writing: live && entry.n == session.arriving, session: session, compact: compact)
                        }
                        status(entries.isEmpty)
                    }
                    .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: compact ? .infinity : Tokens.column, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, compact ? Tokens.gutter : Tokens.gutter).padding(.top, 8).padding(.bottom, 24)
            }
            // It opens at the live end; content growing below doesn't move what you're reading.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollIndicators(.never)
            // At the live end: within 48 points of the foot, the inset under it (the iPhone's box) left out.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom >= geometry.contentSize.height - 48
            } action: { _, end in atEnd = end }
            // Stays at the live end while you're there, as a conversation does.
            .onChange(of: entries.last?.n) { if atEnd { reader.scrollTo("end", anchor: .bottom) } }
            .onChange(of: entries.last?.words.count) { if atEnd { reader.scrollTo("end", anchor: .bottom) } }
            .overlay(alignment: .bottom) {
                if live && !atEnd {
                    Button { withAnimation(Tokens.warm) { reader.scrollTo("end", anchor: .bottom) } } label: {
                        Label("Jump to now", systemImage: "arrow.down").font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.ink)
                            .padding(.horizontal, 14).frame(height: compact ? 44 : 30)
                            .background(Tokens.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Tokens.surfaceEdge, lineWidth: 1))
                            .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                    }
                    .buttonStyle(.plain).padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
        }
    }

    private func head(_ counts: [TranscriptEntry.Filter: Int]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if title {
                Text("Session").font(Tokens.font(22, .semibold)).foregroundStyle(Tokens.ink).accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 6) {
                Text(meta).foregroundStyle(Tokens.muted)
                if live {
                    HStack(spacing: 6) {
                        WorkMarkView(mark: .working, dot: 8)
                        Text("Live").foregroundStyle(Tokens.text)
                    }
                    .padding(.leading, 8)
                }
            }
            .font(Tokens.font(Tokens.textMd)).padding(.top, title ? 4 : 0).padding(.bottom, 14)
            filters(counts)
        }
        .padding(.bottom, 18)
    }

    @ViewBuilder private func filters(_ counts: [TranscriptEntry.Filter: Int]) -> some View {
        let tabs = TranscriptEntry.Filter.allCases.filter { $0 == .all || counts[$0, default: 0] > 0 }
        if compact {
            ScrollView(.horizontal) { HStack(spacing: 6) { ForEach(tabs, id: \.self) { tab($0, counts[$0, default: 0]) } } }
                .scrollIndicators(.never)
        } else {
            CenteredFlow(spacing: 6, centred: false) { ForEach(tabs, id: \.self) { tab($0, counts[$0, default: 0]) } }
        }
    }

    private func tab(_ tab: TranscriptEntry.Filter, _ count: Int) -> some View {
        let on = filter == tab
        return Button { filter = tab } label: {
            (Text(tab.rawValue) + Text(" \(count)").font(Tokens.font(Tokens.textSm)).foregroundStyle(on ? Tokens.onInk.opacity(0.55) : Tokens.muted))
                .font(Tokens.font(Tokens.textMd, on ? .medium : .regular)).monospacedDigit()
                .foregroundStyle(on ? Tokens.onInk : Tokens.text)
                .padding(.horizontal, 12).frame(height: 28)
                .background(on ? Tokens.ink : Tokens.pill, in: Capsule())
                // 44 points to touch on the iPhone.
                .frame(minHeight: compact ? 44 : 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func status(_ empty: Bool) -> some View {
        if session.unavailable {
            note("This runner doesn't keep this job's session.")
        } else if let failure = session.failure, empty {
            note("The session couldn't be read: \(failure)")
        } else if empty && session.loaded {
            note("Nothing yet.")
        } else if !session.loaded {
            ProgressView().controlSize(.small).padding(.top, 8)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 8)
    }
}

/// One entry of the session.
private struct SessionRow: View {
    let entry: TranscriptEntry
    let agent: String
    /// The words the agent is writing now: a caret at their end.
    let writing: Bool
    let session: LiveSession
    let compact: Bool
    @State private var open = false
    @State private var detail: TranscriptDetail?
    @State private var reading = false

    var body: some View {
        switch entry.kind {
        case "start": start
        case "said": said
        case "thought": thought
        case "you": you
        case "plan": plan
        case "tool": tool
        case "asked": asked
        default:
            Text(entry.words).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted).padding(.leading, 32)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A round begins: a quiet divider with what started and when.
    private var start: some View {
        HStack(spacing: 10) {
            Tokens.divider.frame(height: 1)
            Text(entry.words).layoutPriority(1)
            if let at = entry.at { Text(at.formatted(date: .omitted, time: .shortened)).layoutPriority(1) }
            Tokens.divider.frame(height: 1)
        }
        .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
        .padding(.top, entry.n == session.entries.first?.n ? 0 : 18).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    /// The agent's words, in full, by its mark.
    private var said: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AgentMark(agent: agent).font(Tokens.font(13, .semibold)).foregroundStyle(Tokens.ink).opacity(0.7).frame(width: 22)
            // Its `code` set apart, as in the conversation; nothing in it opens.
            (Text(SessionText.said(entry.words)) + Text(writing ? " " : ""))
                .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .bottomTrailing) { if writing { Caret().offset(x: 9, y: -3) } }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8).padding(.bottom, 4)
    }

    /// Its thinking, folded: "Thought for 9s".
    /// Its thinking: "Thinking…" with the working dot while it goes on (Claude Code says it thinks
    /// but not what, #1328's follow-up), then "Thought for 12s", which opens only when it has words.
    @ViewBuilder private var thought: some View {
        if entry.running {
            HStack(spacing: 6) {
                WorkMarkView(mark: .working, dot: 6)
                Text("Thinking…").font(Tokens.font(Tokens.textMd)).italic().foregroundStyle(Tokens.muted)
            }
            .frame(minHeight: compact ? 44 : 20)
            .padding(.leading, 32)
            .accessibilityElement(children: .combine)
        } else if (entry.text ?? "").isEmpty {
            Text(entry.seconds.map { "Thought for \(JobPageText.took($0))" } ?? "Thought")
                .font(Tokens.font(Tokens.textMd)).italic().foregroundStyle(Tokens.muted)
                .frame(minHeight: compact ? 44 : 20)
                .padding(.leading, 32)
        } else {
            thoughtWithWords
        }
    }

    private var thoughtWithWords: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(Tokens.warm) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(entry.seconds.map { "Thought for \(JobPageText.took($0))" } ?? "Thought")
                    Image(systemName: "chevron.right").font(Tokens.font(9, .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(Tokens.font(Tokens.textMd)).italic().foregroundStyle(Tokens.muted)
                .frame(minHeight: compact ? 44 : 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Open" : "Folded")
            if open {
                Text(entry.words).font(Tokens.font(Tokens.textMd)).italic().foregroundStyle(Tokens.text).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Tokens.line.frame(width: 2) }
            }
        }
        .padding(.leading, 32)
    }

    /// What you told it: a bubble at the right.
    private var you: some View {
        VStack(alignment: .trailing, spacing: 4) {
            BubbleLayout {
                Text(entry.words).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.ink)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Tokens.bubble, in: RoundedRectangle(cornerRadius: Tokens.bubbleRadius, style: .continuous))
            }
            if let at = entry.at { Text(at.formatted(date: .omitted, time: .shortened)).font(Tokens.font(11)).foregroundStyle(Tokens.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.vertical, 10)
    }

    /// Its to-do list, as a checklist.
    private var plan: some View {
        let todos = entry.todos ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Text(todos.isEmpty ? entry.words : "To do · \(todos.count { $0.state == "done" }) of \(todos.count) done")
                .font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.label).padding(.bottom, 4)
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 8) {
                    Group {
                        if todo.state == "pending" || todo.state == nil { Circle().strokeBorder(Tokens.check, lineWidth: 1.5).frame(width: 8, height: 8) }
                        else { WorkMarkView(mark: todo.state == "done" ? .done : .working, dot: 8) }
                    }
                    .frame(width: 12, height: 12)
                    .accessibilityElement()
                    .accessibilityLabel(todo.state == "done" ? "Done" : todo.state == "running" ? "Working" : "To do")
                    Text(todo.text).strikethrough(todo.state == "done", color: Tokens.check)
                        .foregroundStyle(todo.state == "done" ? Tokens.muted : Tokens.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Tokens.font(Tokens.textMd))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Tokens.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
        .padding(.leading, 32).padding(.vertical, 4)
    }

    /// A permission it asked for, and how it was answered.
    private var asked: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.shield").font(Tokens.font(12))
            Text(entry.words + (entry.answer.map { " · \($0)" } ?? "")).fixedSize(horizontal: false, vertical: true)
        }
        .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
        .padding(.leading, 32)
        .accessibilityElement(children: .combine)
    }

    /// A tool call: a quiet line, its verb sweeping while it runs, that opens into its detail once
    /// obid serves detail. One that can't open is plain content, not a button.
    @ViewBuilder private var tool: some View {
        let opens = session.detailServed == true && !entry.running
        VStack(alignment: .leading, spacing: 0) {
            if opens {
                Button { toggle() } label: { toolLine(opens: true) }
                    .buttonStyle(.plain)
                    .accessibilityValue(open ? "Open" : "Folded")
            } else {
                toolLine(opens: false).accessibilityElement(children: .combine)
            }
            if open {
                if let detail { ToolDetail(entry: entry, detail: detail).padding(.leading, 20).padding(.top, 6).padding(.bottom, 10) }
                else if reading { ProgressView().controlSize(.small).padding(.leading, 20).padding(.vertical, 6) }
                else { Text("Its detail couldn't be read.").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.leading, 20).padding(.vertical, 6) }
            }
        }
        .padding(.leading, 32)
    }

    private func toolLine(opens: Bool) -> some View {
        let (verb, target) = entry.verbAndTarget
        return HStack(spacing: 8) {
            // A quiet check once done (Sangam's `.ss-tool-mark`), the working dot, red when it failed.
            Group {
                if entry.failed { Circle().fill(Tokens.danger).frame(width: 8, height: 8).accessibilityElement().accessibilityLabel("Failed") }
                else { WorkMarkView(mark: entry.running ? .working : .done, dot: 8) }
            }
            .frame(width: 12, height: 12)
            HStack(spacing: 4) {
                if entry.running { Sheen(text: verb, size: Tokens.textMd).fixedSize() } else {
                    Text(verb).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted).fixedSize()
                }
                if let target { Text(target).font(Tokens.mono(12)).foregroundStyle(Tokens.item) }
            }
            .fadeOut()
            .frame(maxWidth: .infinity, alignment: .leading)
            if let meta = entry.meta {
                Text(meta).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(entry.failed ? Tokens.danger : Tokens.muted)
            }
            took
            if opens {
                Image(systemName: "chevron.right").font(Tokens.font(9, .semibold)).foregroundStyle(Tokens.muted)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
        }
        .frame(minHeight: compact ? 44 : 26).contentShape(Rectangle())
    }

    @ViewBuilder private var took: some View {
        if entry.running, let at = entry.at {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(JobPageText.took(context.date.timeIntervalSince(at))).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
            }
        } else if let seconds = entry.seconds {
            Text(JobPageText.took(seconds)).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
        }
    }

    private func toggle() {
        withAnimation(Tokens.warm) { open.toggle() }
        guard open, detail == nil, !reading else { return }
        reading = true
        Task {
            detail = await session.detail(entry.n)
            reading = false
        }
    }
}

/// What a call ran and what came back: an edit's diff, else the command or what it was given, the
/// end of its output, how it ended and how much of it there was.
private struct ToolDetail: View {
    let entry: TranscriptEntry
    let detail: TranscriptDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let diff = detail.diff, !diff.isEmpty {
                ForEach(Array(diff.enumerated()), id: \.offset) { _, file in
                    if let path = file.path, diff.count > 1 { Text(path).font(Tokens.mono(12)).foregroundStyle(Tokens.text) }
                    CodeBlock(text: SessionText.diff(file.patch))
                }
            } else {
                if let command = detail.command {
                    CodeBlock(text: AttributedString("$ ", attributes: AttributeContainer().foregroundColor(Tokens.muted)) + SessionText.masked(command))
                }
                ForEach(detail.given, id: \.self) { line in
                    Text(SessionText.masked(line)).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).fixedSize(horizontal: false, vertical: true)
                }
                if let output = detail.output?.text, !output.isEmpty { CodeBlock(text: SessionText.masked(output)) }
            }
            // How a command ended and how much it printed (Sangam's `.ss-foot`), for commands only.
            if detail.command != nil || TranscriptEntry.Filter.of(entry) == .commands, let foot = SessionText.foot(entry: entry, detail: detail) {
                foot.font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
            }
        }
    }
}

/// A block of code or output (`.ss-code`): monospace, scrolling sideways, at most 320 points tall.
private struct CodeBlock: View {
    let text: AttributedString

    var body: some View {
        let lines = text.characters.count(where: { $0 == "\n" }) + 1
        let content = Text(text).font(Tokens.mono(12)).foregroundStyle(Tokens.text).lineSpacing(4)
            .fixedSize().padding(.horizontal, 12).padding(.vertical, 10)
        Group {
            if lines > 16 {
                ScrollView([.horizontal, .vertical]) { content }.frame(height: 320)
            } else {
                ScrollView(.horizontal) { content }
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
        .textSelection(.enabled)
    }
}

/// The caret at the end of words still being written; still with Reduce Motion.
private struct Caret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion { bar } else {
                PhaseAnimator([1.0, 0.0]) { level in bar.opacity(level) } animation: { _ in .linear(duration: 0.01).delay(0.5) }
            }
        }
        .accessibilityHidden(true)
    }

    private var bar: some View { RoundedRectangle(cornerRadius: 1).fill(Tokens.ink).frame(width: 7, height: 14) }
}

/// How the session sets text: masked values as chips, a diff's lines in colour, a call's foot.
enum SessionText {
    /// The agent's words as the conversation sets them (`code`, bold, references), with every link
    /// taken out: what an agent writes never opens anything (a `file://` or `shortcuts://` link would).
    static func said(_ text: String) -> AttributedString {
        var styled = SaidText.styled(text)
        for run in styled.runs where run.link != nil { styled[run.range].link = nil }
        return styled
    }

    /// `[vault: NAME]` and `[redacted: rule]` as chips with their name (Sangam's `.ss-vault`), never the value.
    static func masked(_ text: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(text)
        while let range = rest.range(of: #"\[(vault|redacted): [^\]\n]+\]"#, options: .regularExpression) {
            result += AttributedString(String(rest[..<range.lowerBound]))
            var chip = AttributedString(" \(rest[range].dropFirst().dropLast()) ")
            chip.foregroundColor = Tokens.link
            chip.backgroundColor = Tokens.unread.opacity(0.16)
            chip.font = Tokens.font(11)
            result += chip
            rest = rest[range.upperBound...]
        }
        return result + AttributedString(String(rest))
    }

    /// A unified diff, its added lines green, removed red, hunks quiet.
    static func diff(_ patch: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var piece = masked(String(line))
            if line.hasPrefix("@@") { piece.foregroundColor = Tokens.muted }
            else if line.hasPrefix("+"), !line.hasPrefix("+++") { piece.foregroundColor = Tokens.done; piece.backgroundColor = Tokens.done.opacity(0.08) }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { piece.foregroundColor = Tokens.danger; piece.backgroundColor = Tokens.danger.opacity(0.08) }
            result += (index == 0 ? AttributedString() : AttributedString("\n")) + piece
        }
        return result
    }

    /// "exit 65 · 3m 12s · the last 200 of 1,284 lines", or nil with nothing to say.
    static func foot(entry: TranscriptEntry, detail: TranscriptDetail) -> Text? {
        var parts: [Text] = []
        if let exit = detail.output?.exit ?? entry.exit { parts.append(Text("exit \(exit)").foregroundStyle(exit == 0 ? Tokens.muted : Tokens.danger)) }
        if let seconds = entry.seconds { parts.append(Text(JobPageText.took(seconds))) }
        if let all = detail.output?.lines, let shown = detail.output?.text?.split(separator: "\n", omittingEmptySubsequences: false).count,
           all > shown || detail.output?.truncated == true {
            parts.append(Text("the last \(shown.formatted()) of \(all.formatted()) lines"))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text("   ") + $1 }
    }
}

#if DEBUG
/// Sangam's sample session, live, with its rows able to open.
private struct SessionPreview: View {
    @State private var session = LiveSession(job: "sample", load: { _ in TranscriptPage(entries: SessionFixture.entries()) },
                                             loadDetail: { _ in SessionFixture.detail })

    var body: some View {
        SessionView(session: session, agent: "cursor", meta: "Cursor · Sonnet 5.5 · Deskree", live: true)
            .task { await session.catchUp() }
            .background(Tokens.bg)
    }
}

#Preview("Session") { SessionPreview().frame(width: 700, height: 1200) }
#endif
