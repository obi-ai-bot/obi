import SwiftUI

// Sangam's design (design/app) as SwiftUI views the Mac's window and the iPhone both draw: a
// decision's card, pill buttons, chips in rows, what Oby said with its links and code set apart,
// a line being worked on, Oby's small face, a task's mark and the underlined tabs. Not on the
// Watch (its screens are its own).

/// A decision's card (Sangam's AskBlock): its kind in orange (red for a failure), the headline,
/// what happened, the command or file in monospace, the plan, then the choices as pills, the
/// recommended one filled first and Deny in red, and Later. 1 to 4 pick a choice, Return the
/// recommended one (never a Deny, Dismiss or Stop), Esc is Later. A pick shows a spinner on its
/// pill until the runner confirms it; nothing shows as chosen before that.
struct AskCard: View {
    let kind: String
    var failed = false
    /// The job it's from, after its kind.
    var source: String? = nil
    /// Where it came from, as Sangam's `from?: Brand` (Slack, GitHub): its mark before the kind.
    var brand: String? = nil
    /// What a choice acts on, shown whole and as plain text before the choices (a review that
    /// Approve posts): scrolls when long, never cut, never Markdown.
    var shown: String? = nil
    let title: String
    var happened: String? = nil
    /// The asker's own words, behind Details, when the title is Oby's headline instead.
    var behindDetails: String? = nil
    var detail: String? = nil
    var plan: String? = nil
    let options: [CardOption]
    var busy = false
    var answered = false
    var keyboardEnabled = false
    var focusRequest = 0
    /// Under the choices: what your own words do, as a link to type them below.
    var hint: String? = nil
    var onHint: (() -> Void)? = nil
    /// The line under the choices saying what each does; off where Sangam's card has none (GitHub's).
    var explains = true
    let onChoose: (CardOption) -> Void
    var onLater: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    @State private var picked: String?
    @State private var showsDetails = false

    /// The choices said under the pills (what each does, the recommended one marked), none when `explains` is off.
    static func explained(_ options: [CardOption], explains: Bool) -> [CardOption] {
        explains ? options.filter { $0.detail != nil || $0.recommended } : []
    }
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                #if os(macOS)
                if let brand { Image("Brands/\(brand)").resizable().scaledToFit().frame(width: 14, height: 14).accessibilityHidden(true) }
                #endif
                Text(kind).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(failed ? Tokens.danger : Tokens.needsInk)
                if let source, !source.isEmpty { Text(source).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).fadeOut() }
            }
            Text(title).font(Tokens.font(Tokens.textBase, .medium)).foregroundStyle(Tokens.ink).lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            if let happened, !happened.isEmpty {
                Text(happened).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4).textSelection(.enabled)
            }
            if let behindDetails, !behindDetails.isEmpty {
                Button { withAnimation(Tokens.warm) { showsDetails.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text("Details")
                        Image(systemName: "chevron.right").font(Tokens.font(9, .semibold)).rotationEffect(.degrees(showsDetails ? 90 : 0))
                    }
                    .font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.muted).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 8)
                .accessibilityValue(showsDetails ? "Shown" : "Hidden")
                if showsDetails {
                    Text(behindDetails).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 6)
                }
            }
            if let detail, !detail.isEmpty { code(detail) }
            if let shown, !shown.isEmpty {
                ScrollView {
                    Text(verbatim: shown).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).lineSpacing(6)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
                .padding(10)
                // Sangam's `tc-code`: a box apart, so a review cut at 280pt reads as one to scroll.
                .background(Tokens.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 10)
            }
            if let plan, !plan.isEmpty { PlanText(plan: plan).padding(.top, 10) }
            if !answered {
                CenteredFlow(spacing: 8, centred: false) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        OptionPill(option: option, index: index, primary: index == 0 && option.recommended && option.safeOnReturn,
                                   pending: busy && picked == option.answer, disabled: busy) {
                            choose(option)
                        }
                    }
                    if let onLater {
                        OptionPill(option: CardOption(label: "Later", answer: "Later"), index: nil, quiet: true, disabled: busy, action: onLater)
                    }
                }
                .padding(.top, 14)
                // What each choice does, the recommended one marked, and the rule Always allow saves.
                let explained = Self.explained(options, explains: explains)
                if !explained.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(explained.enumerated()), id: \.offset) { _, option in
                            (Text(option.label).foregroundStyle(Tokens.text)
                                + Text(option.recommended ? " · Recommended" : "").foregroundStyle(Tokens.needsInk)
                                + Text(option.detail.map { ": \($0)" } ?? "").foregroundStyle(Tokens.muted))
                                .font(Tokens.font(Tokens.textSm)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            if hint != nil || onOpen != nil {
                HStack(spacing: 14) {
                    if let hint {
                        if let onHint { Button(hint, action: onHint).buttonStyle(.plain).disabled(busy) } else { Text(hint) }
                    }
                    if let onOpen { Button("Open task", action: onOpen).buttonStyle(.plain) }
                }
                .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: busy) { if !busy { picked = nil } }
        .focusable(keyboardEnabled).focusEffectDisabled().focused($focused)
        .onChange(of: focusRequest) { if keyboardEnabled { focused = true } }
        .modifier(TapForKeys(enabled: keyboardEnabled) { focused = true })
        .onKeyPress(phases: .down) { press in
            guard keyboardEnabled, focused, press.modifiers.isEmpty else { return .ignored }
            let key = press.key == .return ? "return" : press.key == .escape ? "escape" : press.characters
            switch DecisionKey.action(key, options: options, busy: busy) {
            case .option(let option): choose(option)
            case .later: onLater?()
            case .words, .none: return .ignored
            }
            return .handled
        }
    }

    private func choose(_ option: CardOption) {
        guard !busy else { return }
        picked = option.answer
        onChoose(option)
    }

    private func code(_ text: String, mono: Bool = true) -> some View {
        Text(text).font(mono ? Tokens.mono(12) : Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).lineSpacing(6)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Tokens.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 10)
    }
}

/// One choice: a pill, filled in ink for the recommended one, red words for a destructive one, no
/// fill for Later; its number (1 to 4) is its key.
struct OptionPill: View {
    let option: CardOption
    let index: Int?
    var primary = false
    var quiet = false
    var pending = false
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if pending { ProgressView().controlSize(.mini) }
                Text(option.label).font(Tokens.font(Tokens.textMd, primary ? .medium : .regular)).lineLimit(2)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(primary ? Tokens.onInk : option.role == .destructive ? Tokens.danger : quiet ? (hovering ? Tokens.ink : Tokens.muted) : hovering ? Tokens.ink : Tokens.item)
            .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 32)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering)
        .help([index.map { "Press \($0 + 1)" }, option.detail].compactMap { $0 }.joined(separator: " · "))
        .accessibilityHint(option.detail ?? "")
    }

    private var background: Color {
        if primary { return hovering ? .white : Tokens.ink }
        if quiet { return hovering ? Tokens.hover : .clear }
        return hovering ? Color.white.opacity(0.13) : Tokens.pill
    }
}

/// A plan to approve, as its markdown says it (headings, lists, code), in at most 220 points that
/// scroll, so the choices under it stay in sight.
struct PlanText: View {
    let plan: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(PlanBlock.blocks(plan).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let text): Text(inline(text)).font(Tokens.font(Tokens.textMd, .semibold)).foregroundStyle(Tokens.ink)
                    case .item(let marker, let text):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(marker).foregroundStyle(Tokens.muted)
                            Text(inline(text))
                        }
                    case .code(let text):
                        Text(text).font(Tokens.mono(12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Tokens.codeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    case .text(let text): Text(inline(text))
                    }
                }
            }
            .font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(Tokens.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func inline(_ text: String) -> AttributedString { Reading.markdown(text, code: Tokens.mono(12)) }
}

/// A click gives a card the keyboard, where it takes keys; else the click goes past it (a task's
/// card opens its page).
struct TapForKeys: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.onTapGesture(perform: action) } else { content }
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

/// A pill button (Sangam's `.tc-option`): white 8% at rest, ink filled for the main one, red
/// words for a destructive one, no fill for a quiet one.
struct PillButton: View {
    let title: String
    var primary = false
    var danger = false
    var quiet = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(Tokens.font(Tokens.textMd, primary ? .medium : .regular)).lineLimit(1)
                .foregroundStyle(primary ? Tokens.onInk : danger ? Tokens.danger : quiet && !hovering ? Tokens.muted : hovering ? Tokens.ink : Tokens.item)
                .padding(.horizontal, 14).frame(height: 32)
                .background(primary ? (hovering ? .white : Tokens.ink) : quiet ? (hovering ? Tokens.hover : .clear) : hovering ? Color.white.opacity(0.13) : Tokens.pill,
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering)
    }
}

/// What Oby (or you) said: paragraphs a blank line apart, lines starting "- " as a list, and
/// links, references, paths and `code` set apart as Sangam's message box does.
struct SaidText: View {
    let text: String
    var color: Color = Tokens.item
    /// Yours: as typed, no paragraphs or lists.
    var plain = false
    /// How far in the last words are, oldest first, while they come in (`ArrivingSaid`).
    var fading: [Double] = []

    var body: some View {
        let blocks = blocks
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { b, block in
                let last = b == blocks.count - 1
                if block.allSatisfy({ $0.hasPrefix("- ") }) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(block.enumerated()), id: \.offset) { l, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(Tokens.muted)
                                Text(faded(Self.styled(String(line.dropFirst(2))), last && l == block.count - 1))
                            }
                        }
                    }
                } else {
                    Text(faded(Self.styled(block.joined(separator: "\n")), last))
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

    /// The words at the end still coming in, as faint as they are in. Only the last line's: a word
    /// fading across a paragraph's break shows whole (ponytail: rare, and gone in 240 ms).
    private func faded(_ styled: AttributedString, _ last: Bool) -> AttributedString {
        guard last, !fading.isEmpty else { return styled }
        var string = styled
        let characters = Array(string.characters)
        var end = characters.count
        for opacity in fading.reversed() {
            while end > 0, characters[end - 1].isWhitespace { end -= 1 }
            var start = end
            while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
            guard start < end else { break }
            let lower = string.characters.index(string.startIndex, offsetBy: start)
            let upper = string.characters.index(string.startIndex, offsetBy: end)
            let runs = string[lower..<upper].runs.map { ($0.range, $0.swiftUI.foregroundColor ?? color, $0.swiftUI.backgroundColor) }
            for (range, tint, back) in runs {
                string[range].foregroundColor = tint.opacity(opacity)
                if let back { string[range].backgroundColor = back.opacity(opacity) }
            }
            end = start
        }
        return string
    }
}

/// Oby's words coming in a word at a time from `since`, each fading in (Sangam's stream.ts): an
/// answer that just came (`ConversationModel.arrived`), or text still streaming in (`text` grows,
/// and a word that came late starts in when it came). With no `since`, Reduce Motion, or once
/// in, it's plain `SaidText`.
struct ArrivingSaid: View {
    let text: String
    var color: Color = Tokens.item
    let since: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When each word came, from `since`, once the text has grown (else all came at the start).
    @State private var came: [TimeInterval] = []
    @State private var done = false

    var body: some View {
        Group {
            if let since, !reduceMotion, !done, Date.now.timeIntervalSince(since) < WordReveal.duration(text, came: came) {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let shown = WordReveal.shown(text, came: came, after: context.date.timeIntervalSince(since))
                    SaidText(text: shown.text, color: color, fading: shown.fading)
                }
                // VoiceOver reads the whole answer, not the half-built sentence on screen.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(WordReveal.duration(text, came: came) - Date.now.timeIntervalSince(since)))
                    if !Task.isCancelled { done = true }
                }
            } else {
                SaidText(text: text, color: color)
            }
        }
        .onChange(of: text) { old, new in
            guard let since else { return }
            if came.isEmpty { came = Array(repeating: 0, count: WordReveal.words(old).count) }
            let now = Date.now.timeIntervalSince(since)
            came += Array(repeating: now, count: max(0, WordReveal.words(new).count - came.count))
            done = false
        }
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
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
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
            let face = Path(roundedRect: CGRect(x: 1.5 * unit, y: 6 * unit, width: 21 * unit, height: 16.5 * unit), cornerRadius: 5 * unit)
            // On a light ground, a hairline round the white face so it holds its shape (`oby-edge`):
            // stroked wide under the fill, so only its outer half shows.
            let edge = StrokeStyle(lineWidth: 1.2 * unit + 1.5, lineJoin: .round)
            context.stroke(ears, with: .color(Tokens.obyEdge), style: edge)
            context.stroke(face, with: .color(Tokens.obyEdge), lineWidth: 1.5)
            context.fill(ears, with: .color(body))
            context.stroke(ears, with: .color(body), style: StrokeStyle(lineWidth: 1.2 * unit, lineJoin: .round))
            context.fill(face, with: .color(body))
            for x in [6.0, 14.6] {
                context.fill(Path(roundedRect: CGRect(x: x * unit, y: 10.6 * unit, width: 2.8 * unit, height: 5 * unit), cornerRadius: 1.4 * unit), with: .color(eye))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A task's one mark at the end of its row (#496, Sangam's StatusDot): an 8-point dot, blue while
/// new, orange when it needs you, grey and pulsing slowly while working; nothing while queued (the
/// spot stays, so rows line up); a small grey check once done.
struct WorkMarkView: View {
    let mark: WorkMark
    var dot: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch mark {
            case .new: Circle().fill(Tokens.unread).frame(width: dot, height: dot)
            case .needs: Circle().fill(Tokens.needs).frame(width: dot, height: dot)
            case .working:
                if reduceMotion {
                    Circle().fill(Tokens.working).frame(width: dot, height: dot).opacity(0.8)
                } else {
                    PhaseAnimator([0.2, 1.0]) { level in
                        Circle().fill(Tokens.working).frame(width: dot, height: dot).opacity(level)
                    } animation: { _ in .easeInOut(duration: 0.8) }
                }
            case .queued: Color.clear
            case .done: Image(systemName: "checkmark").font(Tokens.font(9, .semibold)).foregroundStyle(Tokens.check)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityElement()
        .accessibilityLabel(mark.rawValue)
    }
}

/// Underlined tabs (Sangam's `.line-tabs`): the names alone with their counts, the open one in ink
/// with a 2-point line on the 1-point line under the row, sliding to the tab picked. To do shows
/// only where it's counted (Review PR and Issues).
struct LineTabs: View {
    let tab: WorkList.Tab
    let counts: [WorkList.Tab: Int]
    let onPick: (WorkList.Tab) -> Void
    @Namespace private var line
    @State private var hovered: WorkList.Tab?

    var body: some View {
        HStack(spacing: 24) {
            ForEach(WorkList.Tab.allCases.filter { $0 != .todo || counts[$0] != nil }, id: \.self) { each in
                Button { withAnimation(Tokens.warm) { onPick(each) } } label: {
                    HStack(spacing: 6) {
                        Text(each.rawValue).font(Tokens.font(Tokens.textBase))
                            .foregroundStyle(tab == each ? Tokens.ink : hovered == each ? Tokens.text : Tokens.muted)
                        Text("\(counts[each] ?? 0)").font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                    }
                    .frame(height: 36)
                    .overlay(alignment: .bottom) {
                        if tab == each {
                            Capsule().fill(Tokens.ink).frame(height: 2).offset(y: 1)
                                .matchedGeometryEffect(id: "line", in: line)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? each : hovered == each ? nil : hovered }
                .animation(Tokens.fade, value: hovered)
                .accessibilityAddTraits(tab == each ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Tokens.line.frame(height: 1) }
    }
}

/// Your bubble hugs its words, at most 80% of the column, at its right.
struct BubbleLayout: Layout {
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
